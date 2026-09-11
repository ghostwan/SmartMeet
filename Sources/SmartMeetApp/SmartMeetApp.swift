import SwiftUI

struct SmartMeetApp: App {
    @State private var session = RecordingSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(session: session)
                .frame(width: 440)
        } label: {
            Image(systemName: session.isRecording ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("Compte rendu", id: "review") {
            ReviewWindow(session: session)
        }
        .defaultSize(width: 720, height: 640)

        Window("Réglages SmartMeet", id: "settings") {
            SettingsWindow(settings: session.settings)
        }
        .windowResizability(.contentSize)
    }
}
