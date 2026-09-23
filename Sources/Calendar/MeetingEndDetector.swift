import Foundation

/// Decides whether a recording session looks like it should be paused
/// because the meeting seems to be over.
///
/// Two independent signals, either one sufficient on its own:
/// - the tracked video-conferencing app has stopped picking up the
///   microphone for a while (see `appAbsenceGracePeriod`) — the usual case
///   (the call was hung up, the app was quit);
/// - the calendar event's scheduled end time has passed by more than
///   `calendarOverrunGracePeriod` — catches the case the app-absence signal
///   misses: a network drop that leaves the conferencing app appearing
///   active (still marked as capturing the microphone by Core Audio) well
///   after the other participants are actually gone, or the app simply
///   staying open past the meeting's end.
///
/// Pure and stateless: `RecordingSession` is the one tracking *since when*
/// the app has been absent and re-arming after a snooze: this only answers
/// "given what's true right now, should it fire?".
public enum MeetingEndDetector {
    public static func shouldPause(
        appAbsenceDuration: TimeInterval?,
        appAbsenceGracePeriod: TimeInterval,
        calendarEndDate: Date?,
        now: Date = .now,
        calendarOverrunGracePeriod: TimeInterval
    ) -> Bool {
        if let appAbsenceDuration, appAbsenceDuration >= appAbsenceGracePeriod {
            return true
        }
        if let calendarEndDate, now.timeIntervalSince(calendarEndDate) >= calendarOverrunGracePeriod {
            return true
        }
        return false
    }
}
