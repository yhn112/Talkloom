import Foundation
import Testing
import TranscriberCore

@Suite("OpenRouter Gemini transcriber")
struct OpenRouterGeminiTranscriberTests {
    enum InvalidSegmentsCase: CaseIterable, Sendable {
        case endBeforeStart
        case unordered
        case emptyText
        case timestampBeyondChunk

        var segments: [[String: Any]] {
            switch self {
            case .endBeforeStart:
                [["start": 2.0, "end": 1.0, "text": "bad", "language": "en"]]
            case .unordered:
                [
                    ["start": 2.0, "end": 3.0, "text": "later", "language": "en"],
                    ["start": 1.0, "end": 1.5, "text": "earlier", "language": "en"],
                ]
            case .emptyText:
                [["start": 0.0, "end": 1.0, "text": "   ", "language": "en"]]
            case .timestampBeyondChunk:
                [["start": 9.0, "end": 10.01, "text": "late", "language": "en"]]
            }
        }
    }

    private actor StubTransport: HTTPTransport {
        private let response: HTTPTransportResponse
        private(set) var requests: [URLRequest] = []

        init(response: HTTPTransportResponse) {
            self.response = response
        }

        func data(for request: URLRequest) -> HTTPTransportResponse {
            requests.append(request)
            return response
        }

        func onlyRequest() throws -> URLRequest {
            try #require(requests.count == 1)
            return requests[0]
        }

        var requestCount: Int { requests.count }
    }

    private func audioFile(bytes: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenRouter-\(UUID().uuidString).wav")
        try Data(bytes).write(to: url)
        return url
    }

    private func response(
        statusCode: Int = 200,
        model: String = "google/gemini-3.7-flash",
        segments: [[String: Any]] = [],
        usage: [String: Any]? = nil
    ) throws -> HTTPTransportResponse {
        let content = try JSONSerialization.data(withJSONObject: ["segments": segments])
        var object: [String: Any] = [
            "model": model,
            "choices": [
                ["message": ["content": String(decoding: content, as: UTF8.self)]]
            ],
        ]
        object["usage"] = usage
        return HTTPTransportResponse(
            statusCode: statusCode,
            data: try JSONSerialization.data(withJSONObject: object)
        )
    }

    private func client(
        response: HTTPTransportResponse,
        maximumAudioBytes: Int = 1_024
    ) throws -> (OpenRouterGeminiTranscriber, StubTransport) {
        let transport = StubTransport(response: response)
        let key = try #require(OpenRouterAPIKey("test-key"))
        let byteLimit = try #require(OpenRouterAudioByteLimit(maximumAudioBytes))
        return (
            OpenRouterGeminiTranscriber(
                apiKey: key,
                maximumAudioBytes: byteLimit,
                transport: transport),
            transport
        )
    }

    @Test("request uses OpenRouter audio input and privacy routing")
    func requestShape() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, transport) = try client(response: response())

        _ = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 0,
                duration: 10,
                source: .microphone))

        let request = try await transport.onlyRequest()
        #expect(request.url == OpenRouterGeminiTranscriber.defaultEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == OpenRouterGeminiTranscriber.defaultModel)
        #expect(object["temperature"] == nil)

        let provider = try #require(object["provider"] as? [String: Any])
        #expect(provider["require_parameters"] as? Bool == true)
        #expect(provider["data_collection"] as? String == "deny")
        #expect(provider["zdr"] as? Bool == true)

        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let audio = try #require(
            content.first(where: { $0["type"] as? String == "input_audio" })?["input_audio"]
                as? [String: Any])
        #expect(audio["format"] as? String == "wav")
        #expect(audio["data"] as? String == Data([1, 2, 3, 4]).base64EncodedString())

        let responseFormat = try #require(object["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
    }

    @Test("response timestamps map to the meeting timeline")
    func responseMapping() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(
            response: response(
                segments: [
                    ["start": 0.25, "end": 1.5, "text": "  Привет  ", "language": "ru"],
                    ["start": 2.0, "end": 3.0, "text": "Hello", "language": "en"],
                ],
                usage: [
                    "prompt_tokens": 10,
                    "completion_tokens": 5,
                    "total_tokens": 15,
                    "cost": 0.001,
                ]))

        let result = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 12,
                duration: 10,
                source: .systemAudio))

        #expect(result.model == "google/gemini-3.7-flash")
        #expect(
            result.segments == [
                TranscriptSegment(
                    startTime: 12.25,
                    endTime: 13.5,
                    text: "Привет",
                    language: .russian,
                    source: .systemAudio),
                TranscriptSegment(
                    startTime: 14,
                    endTime: 15,
                    text: "Hello",
                    language: .english,
                    source: .systemAudio),
            ])
        #expect(
            result.usage
                == TranscriptionUsage(
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15,
                    cost: 0.001))
    }

    @Test("an invalid success response is rejected")
    func invalidSuccessResponse() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(
            response: HTTPTransportResponse(statusCode: 200, data: Data("{}".utf8)))

        await #expect(throws: OpenRouterGeminiTranscriber.TranscriptionError.invalidResponse) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url,
                    startOffset: 0,
                    duration: 10,
                    source: .microphone))
        }
    }

    @Test("an empty provider payload decodes to no segments")
    func emptyProviderPayload() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(response: response())

        let result = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 0,
                duration: 10,
                source: .microphone))

        #expect(result.segments.isEmpty)
    }

    @Test("invalid input does not construct a request")
    func invalidInputDoesNotRequest() async throws {
        #expect(OpenRouterAPIKey("  \n") == nil)
        let url = try audioFile(bytes: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, transport) = try client(response: response())

        await #expect(throws: OpenRouterGeminiTranscriber.TranscriptionError.emptyAudioFile) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url,
                    startOffset: 0,
                    duration: 10,
                    source: .microphone))
        }
        #expect(await transport.requestCount == 0)
    }

    @Test("an oversized input is rejected before transport")
    func oversizedInputDoesNotRequest() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, transport) = try client(response: response(), maximumAudioBytes: 3)

        await #expect(
            throws: OpenRouterGeminiTranscriber.TranscriptionError.audioFileTooLarge(
                actualBytes: 4,
                maximumBytes: 3)
        ) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url,
                    startOffset: 0,
                    duration: 10,
                    source: .microphone))
        }
        #expect(await transport.requestCount == 0)
    }

    @Test("provider errors expose only the provider message")
    func providerError() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try JSONSerialization.data(
            withJSONObject: ["error": ["message": "insufficient credits"]])
        let (client, _) = try client(
            response: HTTPTransportResponse(statusCode: 402, data: data))

        await #expect(
            throws: OpenRouterGeminiTranscriber.TranscriptionError.httpFailure(
                statusCode: 402,
                message: "insufficient credits")
        ) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url,
                    startOffset: 0,
                    duration: 10,
                    source: .microphone))
        }
    }

    @Test(
        "malformed or unordered segments are rejected",
        arguments: InvalidSegmentsCase.allCases)
    func invalidSegments(_ testCase: InvalidSegmentsCase) async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(response: response(segments: testCase.segments))

        await #expect(throws: OpenRouterGeminiTranscriber.TranscriptionError.invalidSegment) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url,
                    startOffset: 0,
                    duration: 10,
                    source: .microphone))
        }
    }
}
