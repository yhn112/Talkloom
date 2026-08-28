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

        let body = try requestBody(audio: audio, duration: chunk.duration)
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

    private func requestBody(audio: Data, duration: TimeInterval) throws -> Data {
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
                        ["type": "text", "text": Self.prompt(duration: duration)],
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

        var segments: [TranscriptSegment] = []
        var repairedTimings = 0
        var previousEnd: TimeInterval = 0

        for segment in payload.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A segment with no words is not a timing problem; there is simply nothing to
            // place on the timeline.
            guard !text.isEmpty else { continue }

            let placed = Self.place(
                start: segment.start,
                end: segment.end,
                after: previousEnd,
                within: chunk.duration)
            if placed.repaired { repairedTimings += 1 }
            previousEnd = placed.end

            segments.append(
                TranscriptSegment(
                    startTime: chunk.startOffset + placed.start,
                    endTime: chunk.startOffset + placed.end,
                    text: text,
                    language: segment.language,
                    source: chunk.source
                ))
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
            },
            repairedTimingCount: repairedTimings
        )
    }

    /// Places one returned segment inside the chunk that was sent.
    ///
    /// The chunk's bounds are a measurement this project made from its own recording; the
    /// provider's timestamps are the model's estimate of where inside them the words fall, and
    /// the model does not measure time — it infers it. So a timestamp outside the chunk is a
    /// bad estimate, never evidence that the words are wrong, and the words are what the user
    /// came for. Estimates are therefore folded into the measured bounds instead of being
    /// allowed to discard a transcript. `repairedTimingCount` keeps that from being silent.
    /// A non-finite timestamp needs no handling here: JSON has no such literal, and an
    /// overflowing exponent is refused by `JSONDecoder` before this is reached, which surfaces
    /// as `invalidResponse` and is retried.
    static func place(
        start: TimeInterval,
        end: TimeInterval,
        after previousEnd: TimeInterval,
        within duration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval, repaired: Bool) {
        var repaired = false

        var placedStart = start
        if placedStart < previousEnd {
            placedStart = previousEnd
            repaired = true
        }
        if placedStart > duration {
            placedStart = duration
            repaired = true
        }

        var placedEnd = end
        if placedEnd > duration {
            placedEnd = duration
            repaired = true
        }
        if placedEnd < placedStart {
            placedEnd = placedStart
            repaired = true
        }

        return (placedStart, placedEnd, repaired)
    }

    /// The chunk's exact length is stated because the model does not measure it: it is handed
    /// tokenized audio and guesses where the recording ends, overshooting past it often enough
    /// that segment validation rejected whole correct transcripts. The anchor is what keeps the
    /// returned timestamps inside the audio they describe. Measured in `Tests/reports/baseline.md`.
    private static func prompt(duration: TimeInterval) -> String {
        """
        Transcribe every spoken word in this audio chunk. Preserve the spoken language and do not translate Russian or English. This chunk is exactly \(statedDuration(duration)) seconds long; return timestamps in seconds relative to its beginning, and let no timestamp exceed its length. Remove no meaningful words, invent nothing, and return an empty segments array for silence or non-speech noise.
        """
    }

    /// The chunk length as the prompt states it, rounded **down** to the millisecond.
    ///
    /// A model given a bound tends to end its last segment exactly on it, so a bound rounded
    /// up is one the audio does not have: a 17.2436875 s chunk printed as `17.244` comes back
    /// ending at 17.244, a millisecond past the recording. Stating slightly less audio than
    /// exists costs at most a millisecond of the final word's timestamp, and keeps a rounding
    /// artefact out of `repairedTimingCount`, which is meant to report the model's estimates
    /// being wrong rather than this function's arithmetic.
    static func statedDuration(_ duration: TimeInterval) -> String {
        let milliseconds = (duration * 1000).rounded(.down)
        // A chunk shorter than a millisecond would be stated as zero, which is worse than
        // useless in a prompt; such a chunk cannot carry speech and is described as it is.
        guard milliseconds >= 1 else { return String(format: "%.6f", duration) }
        return String(format: "%.3f", milliseconds / 1000)
    }

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
    /// A response that could not be parsed at all says nothing about the audio, so the chunk
    /// deserves the retry. Everything the client itself decided before sending — the file, its
    /// size, the chunk's bounds — is permanent, because the second attempt would rebuild the
    /// same request from the same finished file. So is an HTTP status that names the request or
    /// the credential.
    public var isTransient: Bool {
        switch self {
        case .transportFailed, .invalidHTTPResponse, .invalidResponse:
            true
        case .httpFailure(let statusCode, _):
            statusCode == 408 || statusCode == 429 || statusCode >= 500
        case .invalidAudioURL, .unsupportedAudioFormat, .emptyAudioFile, .audioFileTooLarge,
            .invalidChunkOffset, .invalidChunkDuration, .audioReadFailed, .requestEncodingFailed:
            false
        }
    }
}

private extension TranscriptLanguage {
    static let allRawValues = [russian, english, mixed, unknown].map(\.rawValue)
}
