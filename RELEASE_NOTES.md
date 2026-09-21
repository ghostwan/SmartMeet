<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

- One-to-one minutes can now also be saved as a markdown file to a local
  folder, in addition to wherever they're published — a default folder for
  the whole profile, overridable per person in Settings > One-to-one.

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
- The review window now offers "Supprimer le local" once a meeting has been
  published (Confluence and/or Notion): unlike the existing audio/transcript
  cleanup, this also removes the generated minutes and metadata from this
  machine entirely — the already-published page is unaffected and stays the
  sole remaining copy.
- The review window now lets you confirm who was actually present before
  generating the minutes (and correct it before regenerating): the
  transcript itself only ever carries audio-track labels ("Moi"/
  "Participants") or generic diarization clusters ("Locuteur 2"), never real
  names, which was the root cause of decisions and action items sometimes
  getting attributed to the wrong person. The confirmed roster is now
  passed to the model as a closed, explicit list to attribute statements
  against.
- Any meeting type (not just the "One to One" one) can now restrict who is
  allowed to view its published Confluence page beyond its author, on top of
  whatever the type itself already enforces. A default list of people is
  configured per meeting type in *Settings › Types de réunion*, and stays
  editable per meeting from the review window before publication, using the
  same Confluence search picker as the one-to-one counterpart.

### Changed

- The README now includes English screenshots rendered from isolated mock
  profiles and meetings, with no real user data or credentials.

- Confluence destinations are simplified to a default parent page or a
  specific page; the previous current-sprint and per-template space concepts
  are no longer used. Without a configured parent, SmartMeet targets the
  user's personal Confluence space.
### Fixed

- Settings window: the tab bar no longer collapses tabs behind a "More"
  overflow button (macOS 26's default tab style adapts to a sidebar past a
  handful of tabs, and the traffic lights ate into the leftmost tab when the
  window's toolbar and title bar shared the same row). Fixed with
  `.tabViewStyle(.grouped)` and `.windowToolbarStyle(.expanded)`.
- The Confluence account search picker (magnifying-glass button next to the
  one-to-one counterpart or e-mail fields) only ever searched by display
  name, so typing a full e-mail address into it — the very thing the field
  sits next to and looks like it should accept — silently returned no
  result. It now also matches on `user.emailAddress` and merges both result
  sets.
- Restricting a published page (one-to-one, or the new default/per-meeting
  visibility list) only ever restricted the `read` operation, leaving
  `update` untouched — which Confluence treats as "nobody can edit", not
  "unrestricted". The page's own author, unless they happened to be the
  account behind the Atlassian API token, could end up locked out of
  editing their own published minutes. Both `read` and `update` are now
  restricted to the same accounts.


