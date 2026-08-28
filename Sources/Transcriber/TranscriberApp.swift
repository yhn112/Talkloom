import SwiftUI

@main
struct TranscriberApp: App {
    @State private var controller = RecordingController()

    init() {
        // At notice level so it survives into the persistent log store: debug and info
        // messages are memory-only, and a menu-bar app with no window needs some
        // durable evidence that it actually started.
        AppLog.app.notice("Transcriber launched")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            // The icon is the only recording indicator: LSUIElement hides the Dock icon,
            // so a running capture must be visible from the menu bar alone.
            Image(controller.isRecording ? "MenuBarRecordingIcon" : "MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityLabel(
                    controller.isRecording ? "Transcriber is recording" : "Transcriber")
        }
        .menuBarExtraStyle(.window)
    }
}
