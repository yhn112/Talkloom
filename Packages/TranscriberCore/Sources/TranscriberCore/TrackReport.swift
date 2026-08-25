import Foundation

/// One finished track, as the manifest needs to see it.
///
/// This is the seam between capture and storage. The recorder that produced the file lives
/// in the app target, next to CoreAudio; the manifest lives here, where it can be tested
/// without a microphone. Passing a plain value across that line keeps the manifest from
/// having to know what a `TrackRecorder` is — which is what it used to know, for no reason
/// beyond the two types having grown up in the same target.
public struct TrackReport: Sendable {
    /// One uninterrupted run of real samples in the master file.
    ///
    /// `fileFrameOffset` locates those samples after any native-rate silence the recorder
    /// inserted. `startHostTime` independently says where the same samples belong on the
    /// machine clock. Together consecutive spans distinguish a real hole from a short file
    /// that silently compressed its timeline.
    public struct Span: Equatable, Sendable {
        public let fileFrameOffset: Int
        public let frameCount: Int
        public let startHostTime: UInt64

        public init(fileFrameOffset: Int, frameCount: Int, startHostTime: UInt64) {
            self.fileFrameOffset = fileFrameOffset
            self.frameCount = frameCount
            self.startHostTime = startHostTime
        }
    }

    /// File name, not a path: the manifest sits in the same directory as the tracks it
    /// describes, and a recording that can be moved is worth more than one that cannot.
    public let file: String

    /// Who is on this track — the capture policy's answer, not a measurement.
    public let content: TrackContent

    public let sampleRate: Double
    public let frameCount: Int
    public let peakAmplitude: Float
    public let droppedSampleCount: Int

    /// Uninterrupted sample runs, or `nil` when their anchors were never measured.
    ///
    /// An empty array is different from `nil`: it says the timeline was measured and no
    /// real samples reached the file. A recovered or legacy track has audio but no measured
    /// span boundary, so it carries `nil` instead of inventing one.
    public let spans: [Span]?

    /// Mach host time represented by frame zero of the master, or `nil` if it was never
    /// measured. It can precede the first real span when the recorder replaced an initial
    /// dropped block with silence.
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
        self.init(
            file: file,
            content: content,
            sampleRate: sampleRate,
            frameCount: frameCount,
            peakAmplitude: peakAmplitude,
            droppedSampleCount: droppedSampleCount,
            spans: firstSampleHostTime.map {
                [Span(fileFrameOffset: 0, frameCount: frameCount, startHostTime: $0)]
            },
            firstSampleHostTime: firstSampleHostTime,
            failure: failure
        )
    }

    public init(
        file: String,
        content: TrackContent,
        sampleRate: Double,
        frameCount: Int,
        peakAmplitude: Float,
        droppedSampleCount: Int,
        spans: [Span]?,
        firstSampleHostTime: UInt64?,
        failure: String? = nil
    ) {
        self.file = file
        self.content = content
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.peakAmplitude = peakAmplitude
        self.droppedSampleCount = droppedSampleCount
        self.spans = spans
        self.firstSampleHostTime = firstSampleHostTime
        self.failure = failure
    }
}
