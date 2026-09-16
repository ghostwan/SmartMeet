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

### Changed

- The README now includes English screenshots rendered from isolated mock
  profiles and meetings, with no real user data or credentials.

- Confluence destinations are simplified to a default parent page or a
  specific page; the previous current-sprint and per-template space concepts
  are no longer used. Without a configured parent, SmartMeet targets the
  user's personal Confluence space.
### Fixed
