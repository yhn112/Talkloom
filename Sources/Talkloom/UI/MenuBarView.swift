import AppKit
import SwiftUI

/// The panel shown when the menu-bar icon is clicked.
struct MenuBarView: View {
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            permissionRow(
                title: "Microphone",
                status: controller.permissions.microphone
            )
            permissionRow(
                title: "System audio",
                status: controller.permissions.systemAudio,
                unknownHint: "not verified"
            )

            if let track = controller.lastMicrophoneTrack {
                trackRow(
                    track,
                    silentHint:
                        "The track is silent — check the input device and the microphone permission."
                )
            }
            if let track = controller.lastSystemTrack {
                trackRow(
                    track,
                    silentHint:
                        "The track is silent — nothing played, or Audio Recording access is missing."
                )
            }

            if let warning = controller.warning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = controller.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controller.recoveredSessions.isEmpty {
                recoveryRow
            }

            Divider()

            controls
        }
        .padding(14)
        .frame(width: 280)
        // The first time the menu is opened, before anything can be recorded over the top
        // of a session the previous run left half-written. The controller runs it once.
        .task { await controller.recoverInterruptedSessions() }
    }

    private var header: some View {
        HStack {
            Text("Talkloom").font(.headline)
            Spacer()
            if let session = controller.currentSession {
                Text(session.startedAt, style: .timer)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the previous run left behind. Worth saying out loud once: the audio came back,
    /// the alignment between the two tracks did not, and only this line explains why a
    /// recording the user remembers making now describes itself as interrupted.
    private var recoveryRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "Repaired \(controller.recoveredSessions.count) recording(s) a previous run never finished: the audio is readable again, but the two tracks are no longer aligned."
            )
            .foregroundStyle(.orange)
            ForEach(controller.recoveredSessions, id: \.directory) { outcome in
                Button(outcome.directory.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([outcome.directory])
                }
                .buttonStyle(.link)
                if let failure = outcome.failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(controller.isRecording ? "Stop recording" : "Start recording") {
                Task { await controller.toggle() }
            }
            .keyboardShortcut("r")
            .disabled(controller.isTransitioning)

            if let session = controller.currentSession {
                Button("Reveal recording folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                }
            }

            Button("Quit") {
                // Stop first. Quitting mid-recording would leave the WAV header still
                // claiming zero bytes — a file that opens and plays as silence — and the
                // tap's aggregate device behind in the user's audio system.
                Task {
                    await controller.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
            .disabled(controller.isTransitioning)
        }
    }

    /// The result of the last recording, peak amplitude included. A track of the right
    /// duration and a peak of zero is the failure this project has to be able to see at a
    /// glance, so it is called out rather than left to a log line.
    private func trackRow(_ track: TrackRecorder.Summary, silentHint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(track.label)
                Spacer()
                Text(
                    "\(track.duration, format: .number.precision(.fractionLength(1))) s · peak \(track.peakAmplitude, format: .number.precision(.fractionLength(3)))"
                )
                .foregroundStyle(track.isSilent ? .red : .secondary)
            }
            if track.isSilent {
                Text(silentHint)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if track.content == .mixed {
                Text("Echo cancellation was off, so this track carries both sides of the call.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if track.isClipped {
                Text("The input clipped — lower the input volume in System Settings › Sound.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if track.isTooLoud {
                Text(
                    "The input came within a decibel of clipping — consider lowering the input volume."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if track.droppedSampleCount > 0 {
                Text(
                    "\(track.droppedSampleCount) samples were lost and replaced with silence to preserve timing."
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func permissionRow(
        title: String,
        status: PermissionManager.Status,
        unknownHint: String? = nil
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch status {
            case .granted:
                Label("granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.iconOnly)
            case .denied:
                Text("denied").foregroundStyle(.red)
            case .notDetermined:
                Text(unknownHint ?? "not requested").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
