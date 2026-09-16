<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

- Meeting types can now choose the profile's default destination or a specific
  parent page for either Notion or Confluence. The review window can override
  both service and page for one publication without modifying the type.
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
- One-to-one counterpart field (menu bar and review window) now has a
  magnifying-glass button next to it to search Confluence accounts directly
  by display name, instead of having to know and type their e-mail address.
  Picking a result resolves the `accountId` right away, which is also more
  reliable at publish time than the e-mail search (some Cloud sites restrict
  it for GDPR reasons).
- New *Settings › One-to-one* tab: recurring 1:1 counterparts are configured
  once, each with its own publication destination (a specific Confluence or
  Notion page, overriding the meeting type's own destination) and an e-mail
  to add as a watcher on every Jira ticket created from their action items.
  Recording a one-to-one is now a matter of picking a configured name from a
  list — no more retyping an e-mail or destination page every time.

### Changed

- The README now includes English screenshots rendered from isolated mock
  profiles and meetings, with no real user data or credentials.

- Confluence destinations are simplified to a default parent page or a
  specific page; the previous current-sprint and per-template space concepts
  are no longer used. Without a configured parent, SmartMeet targets the
  user's personal Confluence space.
### Fixed
