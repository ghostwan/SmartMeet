import AudioCapture
import Foundation
import Testing

@testable import SmartMeetCalendar

@Suite("Détection des réunions")
struct MeetingDetectionTests {
    private let teams = ConferencingApp(
        bundleID: "com.microsoft.teams", name: "Microsoft Teams", isDedicated: true
    )
    private let chrome = ConferencingApp(
        bundleID: "com.google.Chrome", name: "Chrome", isDedicated: false
    )

    private func event(
        id: String = "evt-1",
        title: String = "Point hebdo",
        video: Bool = true,
        attendees: [String] = ["Sandra", "Martin"]
    ) -> CalendarMeeting {
        CalendarMeeting(
            id: id,
            title: title,
            startDate: .now,
            endDate: .now.addingTimeInterval(1800),
            attendees: attendees,
            hasVideoLink: video
        )
    }

    @Test("Aucun signal, aucune proposition")
    func noSignalNoSuggestion() {
        #expect(MeetingSuggestion.decide(apps: [], event: nil) == nil)
    }

    @Test("Une application de visio dédiée suffit, même sans événement")
    func dedicatedAppAlone() throws {
        let suggestion = try #require(MeetingSuggestion.decide(apps: [teams], event: nil))
        #expect(suggestion.trigger == .conferencingApp("Microsoft Teams"))
        #expect(suggestion.title == "Microsoft Teams")
        #expect(suggestion.calendarMeeting == nil)
    }

    @Test("Un navigateur seul ne déclenche rien")
    func browserAloneIsIgnored() {
        // Too ambiguous: could be a mic test, video, dictation…
        #expect(MeetingSuggestion.decide(apps: [chrome], event: nil) == nil)
    }

    @Test("Un navigateur confirmé par le calendrier déclenche")
    func browserWithCalendarTriggers() throws {
        let suggestion = try #require(
            MeetingSuggestion.decide(apps: [chrome], event: event())
        )
        #expect(suggestion.trigger == .both(app: "Chrome"))
        #expect(suggestion.title == "Point hebdo")
    }

    @Test("Les deux signaux concordants donnent titre et participants")
    func bothSignals() throws {
        let suggestion = try #require(
            MeetingSuggestion.decide(apps: [teams], event: event())
        )
        #expect(suggestion.trigger == .both(app: "Microsoft Teams"))
        #expect(suggestion.title == "Point hebdo")
        #expect(suggestion.attendees == ["Sandra", "Martin"])
        // The identifier comes from the event: the same meeting is only suggested once.
        #expect(suggestion.id == "evt-1")
    }

    @Test("Un événement sans lien de visio ne déclenche pas seul")
    func calendarWithoutVideoLink() {
        // Otherwise any in-person meeting or blocked time slot would trigger.
        #expect(MeetingSuggestion.decide(apps: [], event: event(video: false)) == nil)
    }

    @Test("Un événement avec lien de visio déclenche seul")
    func calendarWithVideoLink() throws {
        let suggestion = try #require(MeetingSuggestion.decide(apps: [], event: event()))
        #expect(suggestion.trigger == .calendar)
    }

    @Test("L'application dédiée prime sur le navigateur")
    func dedicatedWinsOverBrowser() throws {
        let suggestion = try #require(
            MeetingSuggestion.decide(apps: [chrome, teams], event: event())
        )
        #expect(suggestion.trigger == .both(app: "Microsoft Teams"))
    }

    @Test("Le motif affiché reflète la provenance du signal")
    func reasonDescribesTrigger() throws {
        let app = try #require(MeetingSuggestion.decide(apps: [teams], event: nil))
        #expect(app.reason == "Microsoft Teams utilise le micro")

        let calendarOnly = try #require(MeetingSuggestion.decide(apps: [], event: event()))
        #expect(calendarOnly.reason == "Réunion à l'agenda")

        let both = try #require(MeetingSuggestion.decide(apps: [teams], event: event()))
        #expect(both.reason.contains("agenda"))
        #expect(both.reason.contains("Microsoft Teams"))
    }

    @Test("Une proposition écartée ne revient pas")
    @MainActor
    func dismissedSuggestionDoesNotReturn() {
        let detector = MeetingDetector()
        // Direct injection: `refresh()` depends on EventKit, unusable in tests.
        detector.applyForTesting(MeetingSuggestion.decide(apps: [teams], event: event()))
        #expect(detector.suggestion != nil)

        detector.dismissCurrent()
        #expect(detector.suggestion == nil)

        detector.applyForTesting(MeetingSuggestion.decide(apps: [teams], event: event()))
        #expect(detector.suggestion == nil)

        // After a recording, suggestions become eligible again.
        detector.resetDismissals()
        detector.applyForTesting(MeetingSuggestion.decide(apps: [teams], event: event()))
        #expect(detector.suggestion != nil)
    }

    @Test("Une réunion différente est proposée même après un refus")
    @MainActor
    func otherMeetingStillProposed() {
        let detector = MeetingDetector()
        detector.applyForTesting(MeetingSuggestion.decide(apps: [], event: event(id: "a")))
        detector.dismissCurrent()

        detector.applyForTesting(MeetingSuggestion.decide(apps: [], event: event(id: "b")))
        #expect(detector.suggestion?.id == "b")
    }
}

@Suite("Applications de visioconférence connues")
struct ConferencingAppTests {
    @Test("Les applications dédiées sont distinguées des navigateurs")
    func dedicatedVersusBrowsers() {
        #expect(ConferencingApp.known["com.microsoft.teams"]?.dedicated == true)
        #expect(ConferencingApp.known["us.zoom.xos"]?.dedicated == true)
        #expect(ConferencingApp.known["com.google.Chrome"]?.dedicated == false)
        #expect(ConferencingApp.known["com.apple.Safari"]?.dedicated == false)
    }

    @Test("Les variantes d'une même application portent le même nom")
    func variantsShareName() {
        #expect(ConferencingApp.known["com.microsoft.teams"]?.name == "Microsoft Teams")
        #expect(ConferencingApp.known["com.microsoft.teams2"]?.name == "Microsoft Teams")
        #expect(ConferencingApp.known["Cisco-Systems.Spark"]?.name == "Webex")
    }
}
