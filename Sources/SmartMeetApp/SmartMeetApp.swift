import SwiftUI

struct SmartMeetApp: App {
    @State private var session = RecordingSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(session: session)
                .frame(width: 440)
        } label: {
            // Vue d'étiquette : toujours instanciée tant que l'icône est dans la
            // barre de menus. C'est le seul point de l'application où `openWindow`
            // est disponible en permanence, donc là que les demandes d'ouverture
            // venues des notifications sont honorées.
            MenuBarLabel(session: session)
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

private struct MenuBarLabel: View {
    @Bindable var session: RecordingSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .onChange(of: session.windowToOpen) { _, requested in
                guard let requested else { return }
                openWindow(id: requested)
                NSApp.activate(ignoringOtherApps: true)
                session.windowToOpen = nil
            }
    }

    /// Trois états lisibles d'un coup d'œil : au repos, réunion détectée,
    /// enregistrement en cours.
    private var symbol: String {
        if session.isRecording { return "record.circle.fill" }
        if session.suggestion != nil { return "waveform.badge.exclamationmark" }
        return "waveform"
    }
}
