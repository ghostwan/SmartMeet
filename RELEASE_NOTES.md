<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

- The app UI (menu bar, settings, review window, notifications) and all
  user-facing error messages are now localized in French, English, Spanish,
  Portuguese and Italian, following the system language. macOS permission
  prompts (microphone, system audio, calendar, speech recognition) are
  localized too.
- The meeting type is now guessed from the meeting's title (calendar event
  or conferencing app), e.g. "Daily" or "standup" selects the Daily template,
  "retro"/"rétrospective" the Retrospective one, "sync"/"synchro" the Sync
  one — including custom templates, matched by name. Only applies as long as
  the picker hasn't already been changed by hand.
- Added `SpikeAX`, a diagnostic spike (`Scripts/bundle-spike.sh SpikeAX`) that
  dumps Microsoft Teams' accessibility tree, to assess whether per-speaker
  names could be derived from Teams during transcription.
- New "One to One" meeting type: picking it prompts for who the 1:1 is with
  (suggested from calendar attendees or known people), and the published
  Confluence page is restricted to only the current user and that person
  (best effort — restricting the other person specifically requires their
  email to resolve to a Confluence account, which isn't guaranteed on every
  site; the page always stays at least private to the current user).
- SmartMeet now notices when the tracked conferencing app (Teams, Zoom…) has
  stopped using the microphone for a while during a recording, and proposes
  — via a notification, never automatically — to stop and generate the
  minutes. A 90 s grace period absorbs brief interruptions (network hiccup,
  muting the app on purpose) so a short cut doesn't end the recording on
  your behalf; dismissing the suggestion snoozes it for 5 minutes. New
  setting to disable it (on by default): *Settings › Meeting detection*.

### Changed

### Fixed
