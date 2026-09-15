<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

- New summary provider: `Apple Intelligence (local)`, using Apple's on-device
  `FoundationModels` framework (macOS 26+). Fully local, with a smaller context
  window handled by provider-specific map-reduce chunking.
- New summary provider: `copilot (ACP)`, talking to GitHub Copilot CLI through
  the Agent Client Protocol with structured responses and exact token counts.
- New summary provider: `Claude Code`, using the official `claude` CLI in
  non-interactive JSON mode and reporting Anthropic token/cache usage.
- The app UI, permission prompts, notifications and user-facing errors are
  localized in French, English, Spanish, Portuguese and Italian.
- Meeting types are inferred from calendar/conferencing titles, including
  custom template names.
- Added `SpikeAX`, a Microsoft Teams accessibility-tree diagnostic spike.
- New One-to-One meeting type with participant selection and best-effort
  Confluence page restriction to the two participants.
- End-of-meeting detection proposes stopping after the conferencing app has
  stopped using the microphone for 90 seconds, with a five-minute snooze.
- Profiles scope meeting types, vocabulary, known people, transcription and
  output languages, behavior preferences, publication services, credentials,
  automatic publication and task/ticket settings.
- Each profile can now choose which minutes languages appear in the picker.
  New profiles offer English only by default; 13 more common spoken languages
  can be added under *Settings › Minutes*.
- Each publication service can now independently include or omit the raw
  transcript. When enabled, it is appended at the bottom in a collapsed
  native accordion on both Confluence and Notion.
- Notion can now publish selected action items as tasks in an existing data
  source or in a task database created directly from SmartMeet. Tasks carry
  compatible owner, due-date and type properties plus a backlink to the
  meeting minutes.
- Each meeting type can now select its publication service or inherit the
  profile default. Confluence-specific parent/space options only appear for
  Atlassian destinations, while Notion uses the profile's configured parent.

### Changed

- The neutral **Generic meeting** is the sole type in a fresh profile and is
  always displayed first. Other supplied templates are added explicitly from
  the `+` menu, alongside blank custom templates.
- Built-in type names are localized in the five UI languages, while custom and
  user-renamed names remain verbatim.
- Meeting-type settings now show only types added to the active profile.
  Supplied types can be removed and re-added without losing edits; resetting
  an override is a separate action.
- Known people are now scoped per profile rather than shared globally.
- Automatic publication now follows the meeting type's service, then the
  profile default or its only configured service when unambiguous. Jira
  creation remains specific to Atlassian profiles.

### Fixed

- Release builds no longer emit an unsafe-pointer warning from the Core Audio
  scalar-property helper.
- Notion's connection-test button enables immediately after entering a token,
  even when Notion is the profile's only publication service.
- Automatic and notification-triggered publication now route through the
  meeting type/profile service instead of remaining hard-coded to Atlassian.
