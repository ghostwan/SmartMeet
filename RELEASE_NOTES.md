<!--
Release notes being accumulated — do NOT clear or restart this between two
releases: every shipped feature is added here as it lands (see AGENTS.md).

`Scripts/release.sh` reuses this file's content to compose the GitHub release
notes, then resets it to this template once the release is published.
-->

## Unreleased

### Added

### Changed

### Fixed

- The Notion "Test connection" button now enables immediately after entering
  a token when it is the profile's only publication service; token changes
  now invalidate the SwiftUI view instead of waiting for an unrelated refresh.
