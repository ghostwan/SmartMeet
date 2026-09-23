import Foundation
import Testing

@testable import SmartMeetCalendar

@Suite("Détection de fin de réunion")
struct MeetingEndDetectorTests {
    @Test("Aucun signal ne déclenche rien")
    func noSignalDoesNothing() {
        #expect(!MeetingEndDetector.shouldPause(
            appAbsenceDuration: nil,
            appAbsenceGracePeriod: 90,
            calendarEndDate: nil,
            now: .now,
            calendarOverrunGracePeriod: 300
        ))
    }

    @Test("Une absence encore courte de l'application ne déclenche rien")
    func shortAppAbsenceDoesNothing() {
        #expect(!MeetingEndDetector.shouldPause(
            appAbsenceDuration: 30,
            appAbsenceGracePeriod: 90,
            calendarEndDate: nil,
            now: .now,
            calendarOverrunGracePeriod: 300
        ))
    }

    @Test("Une absence de l'application au-delà du délai de grâce déclenche")
    func longAppAbsenceTriggers() {
        #expect(MeetingEndDetector.shouldPause(
            appAbsenceDuration: 91,
            appAbsenceGracePeriod: 90,
            calendarEndDate: nil,
            now: .now,
            calendarOverrunGracePeriod: 300
        ))
    }

    @Test("Un événement calendrier pas encore terminé ne déclenche rien")
    func calendarNotYetOverDoesNothing() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!MeetingEndDetector.shouldPause(
            appAbsenceDuration: nil,
            appAbsenceGracePeriod: 90,
            calendarEndDate: now.addingTimeInterval(60),
            now: now,
            calendarOverrunGracePeriod: 300
        ))
    }

    @Test("Un événement calendrier dépassé au-delà de la marge déclenche, même sans signal applicatif")
    func calendarOverrunTriggersAloneEvenIfAppLooksActive() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(MeetingEndDetector.shouldPause(
            appAbsenceDuration: nil,
            appAbsenceGracePeriod: 90,
            calendarEndDate: now.addingTimeInterval(-301),
            now: now,
            calendarOverrunGracePeriod: 300
        ))
    }

    @Test("Un léger dépassement du calendrier, sous la marge, ne déclenche pas seul")
    func smallCalendarOverrunAloneDoesNothing() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!MeetingEndDetector.shouldPause(
            appAbsenceDuration: nil,
            appAbsenceGracePeriod: 90,
            calendarEndDate: now.addingTimeInterval(-60),
            now: now,
            calendarOverrunGracePeriod: 300
        ))
    }
}
