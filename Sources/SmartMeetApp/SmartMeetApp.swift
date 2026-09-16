import SwiftUI

struct SmartMeetApp: App {
    @State private var session = RecordingSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(session: session)
                .frame(width: 440)
        } label: {
            // Label view: instantiated for as long as the icon is present in the
            // menu bar. This is the only place in the app where `openWindow` is
            // always available, so it's where window-opening requests coming
            // from notifications get honored.
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
        // The default unified toolbar style shares its row with the title
        // bar's traffic lights: with `.grouped`'s tab bar rendered as that
        // toolbar, the leftmost tabs end up partly hidden behind the
        // traffic lights instead of starting at the window's left edge.
        // `.expanded` gives the title bar its own row, so the tab bar below
        // it gets the window's full width to itself.
        .windowToolbarStyle(.expanded)
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

    /// Three states readable at a glance: idle, meeting detected,
    /// recording in progress.
    private var symbol: String {
        if session.isRecording { return "record.circle.fill" }
        if session.suggestion != nil { return "waveform.badge.exclamationmark" }
        return "waveform"
    }
}
