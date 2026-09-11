import AudioCapture
import Foundation
import Observation

/// Une réunion détectée, proposée à l'enregistrement.
public struct MeetingSuggestion: Sendable, Equatable, Identifiable {
    /// Origine de la détection, qui détermine la confiance qu'on lui accorde.
    public enum Trigger: Sendable, Equatable {
        /// Une application de visioconférence capte le micro : la réunion a commencé.
        case conferencingApp(String)
        /// Un événement de calendrier vient de commencer.
        case calendar
        /// Les deux signaux concordent.
        case both(app: String)
    }

    public let id: String
    public let title: String
    public let attendees: [String]
    public let trigger: Trigger
    public let detectedAt: Date
    /// Événement de calendrier associé, s'il y en a un.
    public let calendarMeeting: CalendarMeeting?

    public var appName: String? {
        switch trigger {
        case .conferencingApp(let name), .both(let name): name
        case .calendar: nil
        }
    }

    public var reason: String {
        switch trigger {
        case .calendar:
            "Réunion à l'agenda"
        case .conferencingApp(let app):
            "\(app) utilise le micro"
        case .both(let app):
            "Réunion à l'agenda · \(app) utilise le micro"
        }
    }
}

/// Surveille l'arrivée d'une réunion et propose de l'enregistrer.
///
/// Deux signaux, délibérément combinés : le calendrier dit ce qui *devrait* avoir
/// lieu, l'application de visio qui capte le micro dit ce qui a *réellement*
/// commencé. Le calendrier seul déclenche sur des réunions annulées ou décalées ;
/// l'audio seul ne connaît ni le titre ni les participants.
@MainActor
@Observable
public final class MeetingDetector {
    public private(set) var suggestion: MeetingSuggestion?

    /// Suggestions écartées par l'utilisateur, pour ne pas le relancer en boucle.
    private var dismissedIDs: Set<String> = []
    private var monitorTask: Task<Void, Never>?

    private let calendar: CalendarService
    private let interval: Duration

    public init(calendar: CalendarService = CalendarService(), interval: Duration = .seconds(20)) {
        self.calendar = calendar
        self.interval = interval
    }

    public func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(20))
            }
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        suggestion = nil
    }

    /// Écarte la suggestion courante sans la refaire apparaître pour la même réunion.
    public func dismissCurrent() {
        if let suggestion { dismissedIDs.insert(suggestion.id) }
        suggestion = nil
    }

    /// Marque la suggestion comme traitée : l'enregistrement a démarré.
    public func acceptCurrent() {
        if let suggestion { dismissedIDs.insert(suggestion.id) }
        suggestion = nil
    }

    /// Réarme les suggestions, par exemple après un arrêt d'enregistrement.
    public func resetDismissals() {
        dismissedIDs.removeAll()
    }

    /// Applique une suggestion sans passer par EventKit. Réservé aux tests : la
    /// logique de décision est pure, mais la boucle de surveillance ne l'est pas.
    func applyForTesting(_ candidate: MeetingSuggestion?) {
        guard let candidate else {
            suggestion = nil
            return
        }
        guard !dismissedIDs.contains(candidate.id) else { return }
        if suggestion?.id != candidate.id { suggestion = candidate }
    }

    func refresh() {
        let candidate = MeetingSuggestion.decide(
            apps: ConferencingDetector.activeApps(),
            event: calendar.currentMeeting()
        )

        guard let candidate else {
            // La réunion s'est terminée : la proposition disparaît d'elle-même.
            suggestion = nil
            return
        }
        guard !dismissedIDs.contains(candidate.id) else { return }
        // Ne pas réémettre la même suggestion à chaque cycle, ce qui relancerait une
        // notification toutes les vingt secondes.
        if suggestion?.id != candidate.id { suggestion = candidate }
    }
}

public extension MeetingSuggestion {
    /// Combine les deux signaux en une proposition, ou rien.
    ///
    /// Règles, par ordre de confiance décroissante :
    /// - une application dédiée à la visio capte le micro : la réunion a commencé, on
    ///   propose même sans événement au calendrier ;
    /// - un navigateur capte le micro : trop ambigu seul (test de micro, vidéo), on
    ///   n'y croit que si le calendrier confirme ;
    /// - un événement seul : on ne propose que s'il porte un lien de visio, sinon
    ///   toute réunion physique déclencherait une proposition.
    static func decide(apps: [ConferencingApp], event: CalendarMeeting?) -> MeetingSuggestion? {
        let dedicated = apps.first(where: \.isDedicated)
        let browser = apps.first(where: { !$0.isDedicated })

        if let app = dedicated ?? (event != nil ? browser : nil) {
            if let event {
                return MeetingSuggestion(
                    id: event.id,
                    title: event.title,
                    attendees: event.attendees,
                    trigger: .both(app: app.name),
                    detectedAt: .now,
                    calendarMeeting: event
                )
            }
            return MeetingSuggestion(
                id: "app-\(app.bundleID)",
                title: app.name,
                attendees: [],
                trigger: .conferencingApp(app.name),
                detectedAt: .now,
                calendarMeeting: nil
            )
        }

        guard let event, event.hasVideoLink else { return nil }
        return MeetingSuggestion(
            id: event.id,
            title: event.title,
            attendees: event.attendees,
            trigger: .calendar,
            detectedAt: .now,
            calendarMeeting: event
        )
    }
}
