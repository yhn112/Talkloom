import AVFoundation
import Testing

@testable import Transcriber

@Suite("Microphone capture lifecycle")
struct MicrophoneCaptureTests {
    @Test("voice-processed and raw segments borrow distinct stable engines")
    func modesBorrowDistinctStableEngines() {
        let engines = MicrophoneEngineSet()
        weak var retainedVoiceEngine: AVAudioEngine?
        weak var retainedRawEngine: AVAudioEngine?

        do {
            let voiceEngine = engines.engine(voiceProcessing: true)
            let rawEngine = engines.engine(voiceProcessing: false)
            retainedVoiceEngine = voiceEngine
            retainedRawEngine = rawEngine

            #expect(voiceEngine === engines.engine(voiceProcessing: true))
            #expect(rawEngine === engines.engine(voiceProcessing: false))
            #expect(voiceEngine !== rawEngine)
        }

        // Dropping one segment's borrowed references cannot release either engine. The
        // process-long-lived capture owner still owns the set.
        #expect(retainedVoiceEngine != nil)
        #expect(retainedRawEngine != nil)
    }
}
