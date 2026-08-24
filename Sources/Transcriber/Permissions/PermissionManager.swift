import AVFoundation
import Observation

/// Tracks the permissions the app needs before it can record.
///
/// Two separate grants are involved and they are easy to confuse: the microphone
/// (`kTCCServiceMicrophone`) and system audio capture (`kTCCServiceAudioCapture`). They are
/// granted independently, so one can be present while the other is missing — which
/// presents as exactly one of the two tracks coming out silent.
@MainActor
@Observable
final class PermissionManager {
    enum Status: Equatable {
        case notDetermined
        case granted
        case denied

        var isUsable: Bool { self == .granted }
    }

    private(set) var microphone: Status = .notDetermined

    /// State of system audio capture.
    ///
    /// macOS exposes no pre-flight query for this one: the only way to learn the answer is
    /// to create a process tap and see whether it produces audio. It therefore stays
    /// `notDetermined` until the first recording attempt reports back.
    private(set) var systemAudio: Status = .notDetermined

    init(microphone: Status? = nil, systemAudio: Status = .notDetermined) {
        self.systemAudio = systemAudio
        if let microphone {
            self.microphone = microphone
        } else {
            refreshMicrophone()
        }
    }

    func refreshMicrophone() {
        microphone = Self.status(for: AVCaptureDevice.authorizationStatus(for: .audio))
        // privacy: .public throughout this type. os_log redacts interpolated values by
        // default, which would reduce these lines to "permission is <private>" — useless
        // for the exact diagnosis they exist to support. A permission state is not
        // sensitive data.
        AppLog.permissions.debug("microphone permission is \(String(describing: self.microphone), privacy: .public)")
    }

    /// Presents the system prompt if the user has not answered it yet.
    func requestMicrophone() async {
        guard microphone == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
        AppLog.permissions.notice("microphone permission answered: \(granted ? "granted" : "denied", privacy: .public)")
    }

    /// Records what an actual capture attempt discovered about system audio access.
    func setSystemAudio(_ status: Status) {
        guard systemAudio != status else { return }
        systemAudio = status
        AppLog.permissions.notice("system audio permission is now \(String(describing: status), privacy: .public)")
    }

    private static func status(for status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
