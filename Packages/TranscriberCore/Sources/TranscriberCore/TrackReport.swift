import Foundation

/// One finished track, as the manifest needs to see it.
///
/// This is the seam between capture and storage. The recorder that produced the file lives
/// in the app target, next to CoreAudio; the manifest lives here, where it can be tested
/// without a microphone. Passing a plain value across that line keeps the manifest from
/// having to know what a `TrackRecorder` is — which is what it used to know, for no reason
/// beyond the two types having grown up in the same target.
public struct TrackReport: Sendable {
    /// File name, not a path: the manifest sits in the same directory as the tracks it
    /// describes, and a recording that can be moved is worth more than one that cannot.
    public let file: String

    /// Who is on this track — the capture policy's answer, not a measurement.
    public let content: TrackContent

    public let sampleRate: Double
    public let frameCount: Int
    public let peakAmplitude: Float
    public let droppedSampleCount: Int

    /// Mach host time of this track's first sample, or `nil` if it never received one.
    /// Tracks are aligned against each other on this, not on the moment the user pressed
    /// record.
    public let firstSampleHostTime: UInt64?

    /// What went wrong with this track, already turned into a sentence. The manifest is
    /// read by scripts and by people, and neither can do anything with an error type.
    public let failure: String?

    public init(
        file: String,
        content: TrackContent,
        sampleRate: Double,
        frameCount: Int,
        peakAmplitude: Float,
        droppedSampleCount: Int,
        firstSampleHostTime: UInt64?,
        failure: String? = nil
    ) {
        self.file = file
        self.content = content
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.peakAmplitude = peakAmplitude
        self.droppedSampleCount = droppedSampleCount
        self.firstSampleHostTime = firstSampleHostTime
        self.failure = failure
    }
}
