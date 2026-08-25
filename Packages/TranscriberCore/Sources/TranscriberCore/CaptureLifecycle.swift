import Foundation

/// One concrete producer run and the physical master segment it owns.
public struct CaptureRun: Equatable, Sendable {
    public let id: UUID
    public let segmentIndex: Int

    public init(id: UUID, segmentIndex: Int) {
        self.id = id
        self.segmentIndex = segmentIndex
    }
}

/// A failure reported by one concrete producer generation.
public struct CaptureRuntimeEvent: Equatable, Sendable {
    public enum Retryability: Equatable, Sendable {
        case restartable
        case terminal
    }

    public let runID: UUID
    public let message: String
    public let retryability: Retryability

    public init(runID: UUID, message: String, retryability: Retryability) {
        self.runID = runID
        self.message = message
        self.retryability = retryability
    }
}

/// The result of asking a capture path to replace one producer generation.
public enum CaptureRestartResult: Equatable, Sendable {
    case restarted(CaptureRun)
    case stale
}
