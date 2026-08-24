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
                unknownHint: "checked when recording starts"
            )

            if let message = controller.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            controls
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("Transcriber").font(.headline)
            Spacer()
            if let session = controller.currentSession {
                Text(session.startedAt, style: .timer)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(controller.isRecording ? "Stop recording" : "Start recording") {
                Task { await controller.toggle() }
            }
            .keyboardShortcut("r")

            if let session = controller.currentSession {
                Button("Reveal recording folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                }
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
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
