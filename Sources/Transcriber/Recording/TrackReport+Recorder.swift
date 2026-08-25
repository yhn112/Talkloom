import Foundation
import TranscriberCore

extension TrackRecorder.Completion {
    /// What the manifest needs to know about a finished track.
    ///
    /// The manifest lives in TranscriberCore, where it can be tested without a microphone,
    /// and it deliberately does not know that a `TrackRecorder` exists. This is the whole
    /// of the translation: a file name instead of a URL, and an error already turned into
    /// a sentence, because a manifest is read by scripts and by people.
    var report: TrackReport {
        TrackReport(
            file: summary.url.lastPathComponent,
            content: summary.content,
            sampleRate: summary.sampleRate,
            frameCount: summary.frameCount,
            peakAmplitude: summary.peakAmplitude,
            droppedSampleCount: summary.droppedSampleCount,
            spans: summary.spans,
            firstSampleHostTime: summary.firstSampleHostTime,
            failure: failure?.localizedDescription
        )
    }
}
