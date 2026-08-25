import Foundation

/// A non-empty OpenRouter credential. Requiring this value before the client can exist
/// makes an offline install structurally unable to construct a request.
public struct OpenRouterAPIKey: Sendable {
    fileprivate let value: String

    public init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.value = value
    }
}

/// A positive upper bound supplied by the chunking layer for one inline audio request.
public struct OpenRouterAudioByteLimit: Equatable, Sendable {
    fileprivate let value: Int

    public init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }
}

public struct HTTPTransportResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

/// The small network seam that keeps request construction and response parsing deterministic
/// in tests without teaching the production client about test-only URL protocols.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPTransportResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenRouterGeminiTranscriber.TranscriptionError.invalidHTTPResponse
        }
        return HTTPTransportResponse(statusCode: response.statusCode, data: data)
    }
}

/// Transcribes one bounded speech chunk with Gemini through OpenRouter Chat Completions.
///
/// OpenRouter's documented audio path is inline base64 `input_audio`, not the direct Gemini
/// Files API. A VAD/chunking layer chooses the request size and duration; this type enforces
/// both at its boundary, owns exactly one request, and maps the returned chunk-local timestamps
/// onto the meeting timeline.
public struct OpenRouterGeminiTranscriber: Transcriber {
    public static let defaultModel = "google/gemini-3.7-flash"
    public static let defaultEndpoint = URL(
        string: "https://openrouter.ai/api/v1/chat/completions")!

    public enum TranscriptionError: LocalizedError, Equatable {
        case invalidAudioURL
        case unsupportedAudioFormat
        case emptyAudioFile
        case audioFileTooLarge(actualBytes: Int, maximumBytes: Int)
        case invalidChunkOffset
        case invalidChunkDuration
        case audioReadFailed(String)
        case requestEncodingFailed
        case transportFailed(String)
        case invalidHTTPResponse
        case httpFailure(statusCode: Int, message: String)
        case invalidResponse
        case invalidSegment(index: Int, failure: SegmentFailure)

        public enum SegmentFailure: Equatable, Sendable {
            case nonFiniteTimestamp
            case negativeTimestamp
            case endBeforeStart
            case unorderedStart
            case endBeyondChunk(end: TimeInterval, duration: TimeInterval)
            case emptyText
        }

        public var errorDescription: String? {
            switch self {
            case .invalidAudioURL:
                "The transcription input is not a local file."
            case .unsupportedAudioFormat:
                "The transcription input must be a WAV file."
            case .emptyAudioFile:
                "The transcription input is empty."
            case .audioFileTooLarge(let actualBytes, let maximumBytes):
                "The transcription input is \(actualBytes) bytes; the configured maximum is \(maximumBytes)."
            case .invalidChunkOffset:
                "The transcription chunk offset must be finite and nonnegative."
            case .invalidChunkDuration:
                "The transcription chunk duration must be finite and greater than zero."
            case .audioReadFailed(let message):
                "Could not read the transcription input: \(message)"
            case .requestEncodingFailed:
                "Could not encode the OpenRouter request."
            case .transportFailed(let message):
                "The OpenRouter request failed: \(message)"
            case .invalidHTTPResponse:
                "OpenRouter returned a non-HTTP response."
            case .httpFailure(let statusCode, let message):
                "OpenRouter returned HTTP \(statusCode): \(message)"
            case .invalidResponse:
                "OpenRouter returned an invalid transcription response."
            case .invalidSegment(let index, let failure):
                "OpenRouter returned invalid transcript segment \(index): \(failure.description)."
            }
        }
    }

    private let apiKey: OpenRouterAPIKey
    private let model: String
    private let endpoint: URL
    private let maximumAudioBytes: OpenRouterAudioByteLimit
    private let transport: any HTTPTransport

    public init(
        apiKey: OpenRouterAPIKey,
        model: String = Self.defaultModel,
        endpoint: URL = Self.defaultEndpoint,
        maximumAudioBytes: OpenRouterAudioByteLimit,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.maximumAudioBytes = maximumAudioBytes
        self.transport = transport
    }

    public func transcribe(_ chunk: TranscriptionChunk) async throws -> TranscriptionResult {
        guard chunk.audioURL.isFileURL else { throw TranscriptionError.invalidAudioURL }
        guard chunk.audioURL.pathExtension.lowercased() == "wav" else {
            throw TranscriptionError.unsupportedAudioFormat
        }
        guard chunk.startOffset.isFinite, chunk.startOffset >= 0 else {
            throw TranscriptionError.invalidChunkOffset
        }
        guard chunk.duration.isFinite, chunk.duration > 0 else {
            throw TranscriptionError.invalidChunkDuration
        }

        let fileSize: Int
        do {
            guard let value = try chunk.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else {
                throw TranscriptionError.audioReadFailed("file size is unavailable")
            }
            fileSize = value
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.audioReadFailed(error.localizedDescription)
        }
        guard fileSize > 0 else { throw TranscriptionError.emptyAudioFile }
        guard fileSize <= maximumAudioBytes.value else {
            throw TranscriptionError.audioFileTooLarge(
                actualBytes: fileSize,
                maximumBytes: maximumAudioBytes.value)
        }

        let audio: Data
        do {
            audio = try Data(contentsOf: chunk.audioURL, options: .mappedIfSafe)
        } catch {
            throw TranscriptionError.audioReadFailed(error.localizedDescription)
        }
        guard !audio.isEmpty else { throw TranscriptionError.emptyAudioFile }
        guard audio.count <= maximumAudioBytes.value else {
            throw TranscriptionError.audioFileTooLarge(
                actualBytes: audio.count,
                maximumBytes: maximumAudioBytes.value)
        }

        let body = try requestBody(audio: audio)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: HTTPTransportResponse
        do {
            response = try await transport.data(for: request)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.transportFailed(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(APIErrorEnvelope.self, from: response.data)
            throw TranscriptionError.httpFailure(
                statusCode: response.statusCode,
                message: Self.providerMessage(error?.error.message ?? "request failed")
            )
        }

        return try decode(response.data, for: chunk)
    }

    private func requestBody(audio: Data) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "segments": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "start": [
                                "type": "number",
                                "description": "Seconds from the beginning of this audio chunk.",
                            ],
                            "end": [
                                "type": "number",
                                "description": "Seconds from the beginning of this audio chunk.",
                            ],
                            "text": ["type": "string"],
                            "language": [
                                "type": "string",
                                "enum": TranscriptLanguage.allRawValues,
                            ],
                        ],
                        "required": ["start", "end", "text", "language"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["segments"],
            "additionalProperties": false,
        ]
        let object: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": Self.prompt],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": audio.base64EncodedString(),
                                "format": "wav",
                            ],
                        ],
                    ],
                ]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meeting_transcript",
                    "strict": true,
                    "schema": schema,
                ],
            ],
            "provider": [
                "require_parameters": true,
                "data_collection": "deny",
                "zdr": true,
            ],
            "stream": false,
        ]

        guard JSONSerialization.isValidJSONObject(object) else {
            throw TranscriptionError.requestEncodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw TranscriptionError.requestEncodingFailed
        }
    }

    private func decode(_ data: Data, for chunk: TranscriptionChunk) throws -> TranscriptionResult {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = response.choices.first?.message.content,
            let contentData = content.data(using: .utf8),
            let payload = try? JSONDecoder().decode(TranscriptPayload.self, from: contentData)
        else {
            throw TranscriptionError.invalidResponse
        }

        var previousStart: TimeInterval = 0
        let segments = try payload.segments.enumerated().map { index, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let failure: TranscriptionError.SegmentFailure?
            if !segment.start.isFinite || !segment.end.isFinite {
                failure = .nonFiniteTimestamp
            } else if segment.start < 0 || segment.end < 0 {
                failure = .negativeTimestamp
            } else if segment.end < segment.start {
                failure = .endBeforeStart
            } else if segment.start < previousStart {
                failure = .unorderedStart
            } else if segment.end > chunk.duration {
                failure = .endBeyondChunk(end: segment.end, duration: chunk.duration)
            } else if text.isEmpty {
                failure = .emptyText
            } else {
                failure = nil
            }
            if let failure {
                throw TranscriptionError.invalidSegment(index: index, failure: failure)
            }
            previousStart = segment.start
            return TranscriptSegment(
                startTime: chunk.startOffset + segment.start,
                endTime: chunk.startOffset + segment.end,
                text: text,
                language: segment.language,
                source: chunk.source
            )
        }

        return TranscriptionResult(
            model: response.model ?? model,
            segments: segments,
            usage: response.usage.map {
                TranscriptionUsage(
                    inputTokens: $0.promptTokens,
                    outputTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens,
                    cost: $0.cost)
            }
        )
    }

    private static let prompt = """
        Transcribe every spoken word in this audio chunk. Preserve the spoken language and do not translate Russian or English. Return timestamps in seconds relative to the beginning of this chunk. Remove no meaningful words, invent nothing, and return an empty segments array for silence or non-speech noise.
        """

    private static func providerMessage(_ message: String) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 240 ? String(singleLine.prefix(240)) + "…" : singleLine
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError
    }

    private struct APIError: Decodable {
        let message: String
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let totalTokens: Int?
            let cost: Double?

            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
                case cost
            }
        }

        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    private struct TranscriptPayload: Decodable {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let language: TranscriptLanguage
        }

        let segments: [Segment]
    }
}

extension OpenRouterGeminiTranscriber.TranscriptionError: ClassifiedTranscriptionError {
    /// Whether resending the identical request could plausibly succeed.
    ///
    /// `invalidSegment` is transient by measurement, not by theory: the probe in
    /// `Tests/reports/baseline.md` had one microphone request return an endpoint past the end
    /// of its own chunk, and an identical retry transcribe the same audio correctly. A rejected
    /// structured-output sample says nothing about the audio, so the chunk deserves the retry.
    ///
    /// Everything the client itself decided before sending — the file, its size, the chunk's
    /// bounds — is permanent, because the second attempt would rebuild the same request from
    /// the same finished file. So is an HTTP status that names the request or the credential.
    public var isTransient: Bool {
        switch self {
        case .transportFailed, .invalidHTTPResponse, .invalidResponse, .invalidSegment:
            true
        case .httpFailure(let statusCode, _):
            statusCode == 408 || statusCode == 429 || statusCode >= 500
        case .invalidAudioURL, .unsupportedAudioFormat, .emptyAudioFile, .audioFileTooLarge,
            .invalidChunkOffset, .invalidChunkDuration, .audioReadFailed, .requestEncodingFailed:
            false
        }
    }
}

private extension OpenRouterGeminiTranscriber.TranscriptionError.SegmentFailure {
    var description: String {
        switch self {
        case .nonFiniteTimestamp:
            "a timestamp is not finite"
        case .negativeTimestamp:
            "a timestamp is negative"
        case .endBeforeStart:
            "the end precedes the start"
        case .unorderedStart:
            "the start precedes the prior segment"
        case .endBeyondChunk(let end, let duration):
            "end \(end) exceeds chunk duration \(duration)"
        case .emptyText:
            "the text is empty"
        }
    }
}

private extension TranscriptLanguage {
    static let allRawValues = [russian, english, mixed, unknown].map(\.rawValue)
}
