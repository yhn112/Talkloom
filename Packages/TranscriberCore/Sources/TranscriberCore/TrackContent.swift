/// Who is on a track.
///
/// This is a fact about the capture policy that produced the file, not a measurement — no
/// amount of inspecting the audio afterwards recovers it. It has to travel with the
/// recording, because the merge step assigns speakers from the file a segment came from:
/// `local` is "me", `remote` is "everyone else", and `mixed` is neither, so it may not be
/// labelled at all without separating the voices first.
public enum TrackContent: String, Codable, Sendable {
    /// The microphone with echo cancellation on: this machine's user, and nobody else.
    case local

    /// The system output mix: every remote participant, and nothing of this machine's user.
    case remote

    /// The microphone with echo cancellation off, which is what the app falls back to when
    /// the system tap does not start. Whatever the speakers played is in this file too, so
    /// the remote side appears here — quieter, delayed, and sometimes not at all, if the
    /// user was wearing headphones.
    case mixed
}
