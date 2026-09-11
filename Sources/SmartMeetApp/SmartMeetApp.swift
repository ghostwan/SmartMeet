import SwiftUI

struct SmartMeetApp: App {
    @State private var session = RecordingSession()

    private var menuBarSymbol: String {
        if session.isRecording { return "record.circle.fill" }
        if session.suggestion != nil { return "waveform.badge.exclamationmark" }
        return "waveform"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(session: session)
                .frame(width: 440)
        } label: {
            // Trois états lisibles d'un coup d'œil : au repos, réunion détectée,
            // enregistrement en cours.
            Image(systemName: menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("Compte rendu", id: "review") {
            ReviewWindow(session: session)
        }
        .defaultSize(width: 720, height: 640)

        Window("Réglages SmartMeet", id: "settings") {
            SettingsWindow(settings: session.settings, session: session)
        }
        .windowResizability(.contentSize)
    }
}
