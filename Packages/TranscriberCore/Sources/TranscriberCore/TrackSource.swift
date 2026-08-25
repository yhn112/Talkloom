/// The capture path that owns one logical meeting track.
///
/// A path may produce more than one native-rate master file when its producer has to be
/// rebuilt. `TrackContent` says whose voices a segment contains; this identity says which
/// segments belong to the same timeline.
public enum TrackSource: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio
}
