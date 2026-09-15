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

### Changed

### Fixed
