import Foundation

/// One concrete producer run and the physical master segment it owns.
struct CaptureRun: Equatable, Sendable {
    let id: UUID
    let segmentIndex: Int
}

/// A failure reported by one concrete producer generation.
struct CaptureRuntimeEvent: Equatable, Sendable {
    enum Retryability: Equatable, Sendable {
        case restartable
        case terminal
    }

    let runID: UUID
    let message: String
    let retryability: Retryability
}

/// The result of asking a capture path to replace one producer generation.
enum CaptureRestartResult: Equatable, Sendable {
    case restarted(CaptureRun)
    case stale
}
