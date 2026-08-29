import ASREvalSupport
import Foundation
import TalkloomCore

/// A local-only probe for measuring the real OpenRouter boundary before it is wired into
/// the app. The credential comes from this process's environment and is never persisted.
@main
struct OpenRouterASREval {
    private enum Failure: LocalizedError {
        case usage
        case missingCredential
        case invalidCredential
        case credentialReadFailed(String)
        case unsafeCredentialFile(String)
        case invalidSource(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: OpenRouterASREval [--validate-only] [--raw] AUDIO.wav [microphone|systemAudio]"
            case .missingCredential:
                "Neither OPENROUTER_API_KEY nor .openrouter.apikey is available."
            case .invalidCredential:
                "The OpenRouter credential is empty."
            case .credentialReadFailed(let message):
                "Could not read .openrouter.apikey: \(message)"
            case .unsafeCredentialFile(let message):
                "Refusing to read .openrouter.apikey: \(message)"
            case .invalidSource(let source):
                "Unknown track source '\(source)'; use microphone or systemAudio."
            }
        }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            let message = "OpenRouterASREval: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(Failure.usage.localizedDescription)
            return
        }
        let validateOnly = arguments.first == "--validate-only"
        if validateOnly { arguments.removeFirst() }
        let echoRawResponse = arguments.first == "--raw"
        if echoRawResponse { arguments.removeFirst() }
        guard arguments.count == 1 || arguments.count == 2 else { throw Failure.usage }

        let audioURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let source = try trackSource(arguments.count == 2 ? arguments[1] : nil)

        let audio = try EvaluationAudio(validating: audioURL)
        guard let byteLimit = OpenRouterAudioByteLimit(audio.byteCount) else {
            throw EvaluationAudio.Failure.fileSizeUnavailable
        }
        if validateOnly {
            print(
                "valid 16 kHz mono Int16 WAV: \(audio.url.lastPathComponent), \(audio.duration)s, \(audio.byteCount) bytes"
            )
            return
        }

        let apiKey = try apiKey()

        let transcriber = OpenRouterGeminiTranscriber(
            apiKey: apiKey,
            maximumAudioBytes: byteLimit,
            transport: echoRawResponse
                ? EchoingTransport(wrapped: URLSessionHTTPTransport())
                : URLSessionHTTPTransport())
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await transcriber.transcribe(
            TranscriptionChunk(
                audioURL: audio.url,
                startOffset: 0,
                duration: audio.duration,
                source: source))

        try EvaluationReport(
            audio: audio,
            elapsedSeconds: evaluationSeconds(start.duration(to: clock.now)),
            result: result
        ).write()
    }

    private static func trackSource(_ rawValue: String?) throws -> TrackSource {
        guard let rawValue else { return .microphone }
        guard let source = TrackSource(rawValue: rawValue) else {
            throw Failure.invalidSource(rawValue)
        }
        return source
    }

    private static func apiKey() throws -> OpenRouterAPIKey {
        if let rawKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] {
            guard let apiKey = OpenRouterAPIKey(rawKey) else { throw Failure.invalidCredential }
            return apiKey
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let repositoryRoot = try gitRepositoryRoot()
        guard currentDirectory == repositoryRoot else {
            throw Failure.unsafeCredentialFile("run the evaluator from the repository root")
        }
        guard try gitIgnoresCredential(in: repositoryRoot) else {
            throw Failure.unsafeCredentialFile("the file is not ignored by git")
        }

        let credentialURL =
            repositoryRoot
            .appending(path: ".openrouter.apikey")
        guard FileManager.default.fileExists(atPath: credentialURL.path) else {
            throw Failure.missingCredential
        }
        let rawKey: String
        do {
            rawKey = try String(contentsOf: credentialURL, encoding: .utf8)
        } catch {
            throw Failure.credentialReadFailed(error.localizedDescription)
        }
        guard let apiKey = OpenRouterAPIKey(rawKey) else { throw Failure.invalidCredential }
        return apiKey
    }

    private static func gitRepositoryRoot() throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.unsafeCredentialFile(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unsafeCredentialFile("the current directory is not a git repository")
        }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw Failure.unsafeCredentialFile("git returned no repository root")
        }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func gitIgnoresCredential(in repositoryRoot: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ignore", "-q", "--", ".openrouter.apikey"]
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.unsafeCredentialFile(error.localizedDescription)
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Writes the provider's reply to stderr on its way through, so a response that strict
/// validation is about to reject can still be read. It exists because the interesting
/// question about a rejected response is what the text was, and the client — correctly —
/// keeps no rejected payload.
private struct EchoingTransport: HTTPTransport {
    let wrapped: any HTTPTransport

    func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        let response = try await wrapped.data(for: request)
        FileHandle.standardError.write(Data("--- provider response ---\n".utf8))
        FileHandle.standardError.write(response.data)
        FileHandle.standardError.write(Data("\n--- end ---\n".utf8))
        return response
    }
}
