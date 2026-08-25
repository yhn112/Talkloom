import Foundation
import Testing
import TranscriberCore

@Suite("OpenRouter Gemini transcriber")
struct OpenRouterGeminiTranscriberTests {
    /// A malformed timing the provider can return, and where the words end up on a 10-second
    /// chunk once it has been folded into the bounds this project measured.
    enum MalformedTimingCase: CaseIterable, Equatable, Sendable {
        case endBeforeStart
        case unordered
        case emptyText
        case beyondChunk
        case farBeyondChunk
        case negative

        var segments: [[String: Any]] {
            switch self {
            case .endBeforeStart:
                [["start": 2.0, "end": 1.0, "text": "backwards", "language": "en"]]
            case .unordered:
                [
                    ["start": 2.0, "end": 3.0, "text": "later", "language": "en"],
                    ["start": 1.0, "end": 1.5, "text": "earlier", "language": "en"],
                ]
            case .emptyText:
                [
                    ["start": 0.0, "end": 1.0, "text": "   ", "language": "en"],
                    ["start": 1.0, "end": 2.0, "text": "kept", "language": "en"],
                ]
            case .beyondChunk:
                [["start": 9.0, "end": 10.01, "text": "late", "language": "en"]]
            case .farBeyondChunk:
                // The shape the first real-recording probe produced: an endpoint far past the
                // end of its own chunk, with the transcript itself perfectly good.
                [["start": 54.4, "end": 105.8, "text": "misplaced", "language": "en"]]
            case .negative:
                [["start": -1.0, "end": 1.0, "text": "early", "language": "en"]]
            }
        }

        /// Text, start and end after placement. Nothing here is ever dropped for its timing.
        var expected: [(String, TimeInterval, TimeInterval)] {
            switch self {
            case .endBeforeStart: [("backwards", 2, 2)]
            case .unordered: [("later", 2, 3), ("earlier", 3, 3)]
            case .emptyText: [("kept", 1, 2)]
            case .beyondChunk: [("late", 9, 10)]
            case .farBeyondChunk: [("misplaced", 10, 10)]
            // A negative start is pulled up to where the previous segment ended, which for
            // a first segment is the beginning of the chunk.
            case .negative: [("early", 0, 1)]
            }
        }

        var expectedRepairs: Int {
            switch self {
            case .emptyText: 0
            case .unordered: 1
            default: 1
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

    /// For payloads `JSONSerialization` cannot build. JSON has no NaN literal, so a non-finite
    /// timestamp can only reach the client as an overflowing exponent.
    private func response(rawContent: String) throws -> HTTPTransportResponse {
        let object: [String: Any] = [
            "model": "google/gemini-3.7-flash",
            "choices": [["message": ["content": rawContent]]],
        ]
        return HTTPTransportResponse(
            statusCode: 200,
            data: try JSONSerialization.data(withJSONObject: object))
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

    @Test(
        "the prompt states the chunk's length without ever overstating it",
        arguments: [
            (10.0, "10.000"),
            (3.8124375, "3.812"),
            (67.4, "67.400"),
            // Rounding to the nearest millisecond would print 17.244 here, and a model that
            // ends its last segment on the bound it was given would then be rejected for
            // exceeding the real 17.2436875.
            (17.2436875, "17.243"),
            (0.9999, "0.999"),
            // Below a millisecond, printing three decimals would state that the chunk has no
            // duration at all.
            (0.0005, "0.000500"),
        ])
    func promptStatesDuration(duration: TimeInterval, expected: String) async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, transport) = try client(response: response())

        _ = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 0,
                duration: duration,
                source: .microphone))

        // The model does not measure the audio; without this anchor it guesses the end and
        // overshoots, and the overshoot is what the segment validation then rejects.
        let body = try #require(try await transport.onlyRequest().httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let text = try #require(
            content.first(where: { $0["type"] as? String == "text" })?["text"] as? String)
        #expect(text.contains("\(expected) seconds long"))
    }

    @Test("the stated length never exceeds the real one")
    func statedDurationNeverOverstates() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Durations chosen to land on both sides of a millisecond boundary, including the
        // frame counts a 16 kHz derived track actually produces.
        for frames in stride(from: 1, through: 4_001, by: 7) {
            let duration = Double(frames * 61) / 16_000
            let (client, transport) = try client(response: response())
            _ = try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url, startOffset: 0, duration: duration, source: .microphone))

            let body = try #require(try await transport.onlyRequest().httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            let text = try #require(
                content.first(where: { $0["type"] as? String == "text" })?["text"] as? String)

            let stated = try #require(
                text.split(separator: " ").first(where: { Double($0) != nil }).map(String.init))
            let statedValue = try #require(Double(stated))
            #expect(
                statedValue <= duration,
                "stated \(stated) exceeds real duration \(duration)")
        }
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
        "a malformed timing is folded into the chunk and never costs the words",
        arguments: MalformedTimingCase.allCases)
    func malformedTimings(_ testCase: MalformedTimingCase) async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(response: response(segments: testCase.segments))

        let result = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 0,
                duration: 10,
                source: .microphone))

        #expect(result.segments.map(\.text) == testCase.expected.map(\.0))
        #expect(result.segments.map(\.startTime) == testCase.expected.map(\.1))
        #expect(result.segments.map(\.endTime) == testCase.expected.map(\.2))
        #expect(result.repairedTimingCount == testCase.expectedRepairs)
    }

    @Test("an overflowing timestamp fails the whole response, which is retryable")
    func overflowingTimestamp() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(
            response: response(
                rawContent: """
                    {"segments":[{"start":0.0,"end":1e400,"text":"endless","language":"en"}]}
                    """))

        // JSON has no non-finite literal, so this is the only way one can arrive, and
        // `JSONDecoder` refuses the number before any placement can happen. The words are lost,
        // but the failure is classified transient and the runner will ask again.
        await #expect(throws: OpenRouterGeminiTranscriber.TranscriptionError.invalidResponse) {
            try await client.transcribe(
                TranscriptionChunk(
                    audioURL: url, startOffset: 0, duration: 10, source: .microphone))
        }
        #expect(OpenRouterGeminiTranscriber.TranscriptionError.invalidResponse.isTransient)
    }

    @Test("placement is relative to the chunk's offset on the meeting timeline")
    func placementRespectsOffset() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let (client, _) = try client(
            response: response(
                segments: [["start": 1.0, "end": 99.0, "text": "spilled", "language": "en"]]))

        let result = try await client.transcribe(
            TranscriptionChunk(
                audioURL: url,
                startOffset: 30,
                duration: 10,
                source: .systemAudio))

        let segment = try #require(result.segments.first)
        #expect(segment.startTime == 31)
        // Folded to the end of the chunk, which is 40 s on the meeting timeline, not 129 s.
        #expect(segment.endTime == 40)
        #expect(result.repairedTimingCount == 1)
    }
}
