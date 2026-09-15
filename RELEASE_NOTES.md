<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

- New summary provider: `Apple Intelligence (local)`, using Apple's on-device
  `FoundationModels` framework (macOS 26+). Fully local, no external binary or
  network call — but with a much narrower context window (~4096 tokens,
  measured empirically), so `SummaryGenerator` now lets a provider advertise
  its own map-reduce chunk-size limit (`maxPromptCharacters`) instead of
  always using the generic 48 000-character threshold.
- New summary provider: `copilot (ACP)`, talking to the `copilot` CLI
  (GitHub Copilot CLI) over the Agent Client Protocol (`copilot --acp`,
  JSON-RPC over stdio) instead of the `opencode` client. Gives an exact
  token count per completion without depending on `opencode`'s NDJSON
  output format.
- New summary provider: `Claude Code`, using the official `claude` CLI in
  non-interactive JSON mode (`claude -p --output-format json`). It reuses the
  Claude subscription authenticated by Claude Code and reports Anthropic's
  input, output and prompt-cache token counts back to SmartMeet.
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
- New **Profiles** (*Settings › Profiles*): switch between usage contexts
  (e.g. "Work" and "Personal") from the menu bar. Each profile has its own
  vocabulary, its own set of visible/default meeting types, its own default
  publication service, its own behavior preferences (auto-record, auto-
  publish, meeting detection, spoken/output language, microphone-track
  diarization…), and its own publication services with independent
  credentials (a different Confluence site or Notion workspace per
  profile). Publication services (Notion, Confluence) are now a dynamic,
  addable list per profile (*Settings › Services*) instead of two tabs
  always shown regardless of configuration. Upgrading from an earlier
  version migrates all existing settings into a single seed "Work" profile
  automatically — nothing is reset.

### Changed

- The generic, no-frills meeting type (used as the universal fallback) is
  now named "Réunion générique" and is the sole meeting type a freshly
  created profile starts with; the former "Réunion générique" (the
  work-oriented default template) is now named "Réunion de travail" and,
  like every other built-in type, is opt-in per profile.

### Fixed

- Release builds no longer emit an unsafe-pointer warning from the generic
  Core Audio scalar-property helper.
