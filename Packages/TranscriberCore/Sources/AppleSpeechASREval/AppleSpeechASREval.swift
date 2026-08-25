import ASREvalSupport
import AVFoundation
import Foundation
import Speech
import TranscriberCore

/// A local-only probe for measuring Apple's on-device recogniser on the same fixtures, in the
/// same report shape, as the cloud engine.
///
/// `SpeechTranscriber` is deliberately not the module used here: it has no Russian.
/// `DictationTranscriber` does, and it is paired with `SpeechDetector` because the framework
/// refuses to run the detector alone — see `docs/speech-framework.md`.
@main
struct AppleSpeechASREval {
    private enum Failure: LocalizedError {
        case usage
        case unsupportedSystem
        case unsupportedLocale(String)
        case assetsNotInstalled(String)
        case analysisFailed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: AppleSpeechASREval [--install-assets] AUDIO.wav [locale]"
            case .unsupportedSystem:
                "Apple's SpeechAnalyzer needs macOS 26 or later."
            case .unsupportedLocale(let identifier):
                "DictationTranscriber does not support \(identifier)."
            case .assetsNotInstalled(let identifier):
                """
                The on-device model for \(identifier) is not installed. \
                Re-run with --install-assets to download it.
                """
            case .analysisFailed(let message):
                "The on-device analysis failed: \(message)"
            }
        }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            let message = "AppleSpeechASREval: \(error.localizedDescription)\n"
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
        let installAssets = arguments.first == "--install-assets"
        if installAssets { arguments.removeFirst() }
        guard arguments.count == 1 || arguments.count == 2 else { throw Failure.usage }

        guard #available(macOS 26.0, *) else { throw Failure.unsupportedSystem }

        let audio = try EvaluationAudio(validating: URL(fileURLWithPath: arguments[0]))
        let locale = Locale(identifier: arguments.count == 2 ? arguments[1] : "ru_RU")

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await Engine.transcribe(
            audio: audio, locale: locale, installingAssets: installAssets)

        try EvaluationReport(
            audio: audio,
            elapsedSeconds: evaluationSeconds(start.duration(to: clock.now)),
            result: result
        ).write()
    }

    @available(macOS 26.0, *)
    private enum Engine {
        static func transcribe(
            audio: EvaluationAudio,
            locale: Locale,
            installingAssets: Bool
        ) async throws -> TranscriptionResult {
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale)
            else {
                throw Failure.unsupportedLocale(locale.identifier)
            }

            let transcriber = DictationTranscriber(
                locale: supported, preset: .timeIndexedLongDictation)
            // The detector is what turns a whole meeting file into utterances. It cannot run
            // on its own, so this is also the only configuration in which it is available.
            let detector = SpeechDetector(
                detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .medium),
                reportResults: false)
            let modules: [any SpeechModule] = [detector, transcriber]

            if await AssetInventory.status(forModules: modules) != .installed {
                guard installingAssets else {
                    throw Failure.assetsNotInstalled(supported.identifier)
                }
                try await install(modules: modules, locale: supported)
            }

            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: audio.url)
            } catch {
                throw Failure.analysisFailed(error.localizedDescription)
            }

            let collector = Task {
                var segments: [TranscriptSegment] = []
                for try await result in transcriber.results where result.isFinal {
                    segments.append(
                        contentsOf: timedSegments(of: result, language: language(of: supported)))
                }
                return segments
            }

            let analyzer = SpeechAnalyzer(modules: modules)
            do {
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                collector.cancel()
                throw Failure.analysisFailed(error.localizedDescription)
            }

            let segments = try await collector.value
            return TranscriptionResult(
                model: "apple/DictationTranscriber(\(supported.identifier))",
                segments: segments.sorted { $0.startTime < $1.startTime })
        }

        private static func install(modules: [any SpeechModule], locale: Locale) async throws {
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules)
                {
                    FileHandle.standardError.write(
                        Data("installing on-device model for \(locale.identifier)…\n".utf8))
                    try await request.downloadAndInstall()
                }
            } catch {
                throw Failure.analysisFailed(
                    "asset installation failed: \(error.localizedDescription)")
            }
        }

        /// One segment per run of text that carries its own audio time range, which is the
        /// finest timing this engine exposes. A result whose text carries no ranges collapses
        /// to a single segment spanning the result, so the report always shows the real
        /// granularity rather than an invented one.
        private static func timedSegments(
            of result: DictationTranscriber.Result,
            language: TranscriptLanguage
        ) -> [TranscriptSegment] {
            var segments: [TranscriptSegment] = []
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        startTime: range.start.seconds,
                        endTime: range.end.seconds,
                        text: text,
                        language: language,
                        source: .microphone))
            }
            if segments.isEmpty {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return [] }
                segments.append(
                    TranscriptSegment(
                        startTime: result.range.start.seconds,
                        endTime: result.range.end.seconds,
                        text: text,
                        language: language,
                        source: .microphone))
            }
            return segments
        }

        private static func language(of locale: Locale) -> TranscriptLanguage {
            switch locale.language.languageCode?.identifier {
            case "ru": .russian
            case "en": .english
            default: .unknown
            }
        }
    }
}
