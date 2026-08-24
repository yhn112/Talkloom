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
    /// macOS exposes no pre-flight query for this one. Successful process-tap creation and
    /// device start do not establish access, and zero-valued buffers do not reveal whether
    /// the cause is permission or genuine silence. `granted` therefore means only that this
    /// process has observed non-silent system audio, while `notDetermined` means the current
    /// capture has not proved that.
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

    /// Starts a new evidence check. There is no system API that can pre-fill its result.
    func beginSystemAudioCheck() {
        systemAudio = .notDetermined
    }

    /// Records only what capture proved: this process received a non-silent system signal.
    func markSystemAudioWorking() {
        guard systemAudio != .granted else { return }
        systemAudio = .granted
        AppLog.permissions.notice("system audio capture produced a non-silent signal")
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
