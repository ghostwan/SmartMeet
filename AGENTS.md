# AGENTS.md

Instructions for any coding agent (Claude, Copilot, opencode…) working on this
repository.

## The project

SmartMeet records a meeting on macOS, transcribes it on-device, generates the
meeting minutes via an LLM, and publishes them to Confluence with action items
turned into Jira tickets. Native menu-bar app, everything stays local (audio and
transcription). See `README.md` for the full architecture and `TODO.md` for the
project's actual state (known bugs, unverified areas, tech debt).

Requirements: macOS 26+, Apple Silicon, Xcode 26, Swift Package Manager.

## Language and style

- **Commits and code comments are written in English.** Identifiers (types,
  functions, variables) are English by Swift convention, and so are comments,
  docs and commit messages.
- Comments explain the **why**, not the what — the repository's source code is
  dense with justifications ("why this order", "why this fallback") rather than
  descriptions of what the code obviously already does.
- JSON decoding is always tolerant: an LLM omits keys, invents out-of-vocabulary
  values, or drifts slightly from the requested schema. The repository's pattern
  (`init(from decoder:)` with `decodeIfPresent` and an explicit fallback instead
  of failing the whole decode) must be reproduced for any new meeting-minutes
  section.

## Essential commands

```sh
swift build                      # build
swift test                       # test suite (Swift Testing, not XCTest)
./Scripts/bundle-app.sh          # assemble and sign SmartMeet.app
open build/SmartMeet.app         # launch — ALWAYS via LaunchServices, never the
                                  # raw binary (TCC silently denies mic/system
                                  # audio capture otherwise)
```

Shipping (checks build + tests + secrets before committing/pushing):

```sh
Scripts/ship.sh "Commit message"
Scripts/ship.sh --no-push "Message"
Scripts/ship.sh --amend
```

Don't use `--skip-tests`: the suite runs in a few tens of milliseconds, there is
no legitimate reason to bypass it.

## Code signing

Identity used for this repository: **ghostwan**
(`Apple Development: ghostwan+apple@gmail.com`). `Scripts/bundle-app.sh` and
`Scripts/bundle-spike.sh` pick it automatically from the keychain (substring
match on `ghostwan`), falling back to the first available identity if it is
missing. `SMARTMEET_SIGN_IDENTITY` still takes priority to override it on a
one-off basis.

Never change the signing identity without a reason: TCC (microphone, system
audio capture) ties permissions to the bundle's exact signature — changing it
makes macOS ask again, or silently revokes permissions already granted.

A `.p12` is never handed to the agent: it is imported into the user's local
keychain (`security import … -k ~/Library/Keychains/login.keychain-db`), never
any other way.

## Git identity for this repository

`user.name` / `user.email` are configured locally (not globally) as
`ghostwan` / `ghostwan@gmail.com`. Every commit in this repository — messages
and authorship alike — uses this identity. Do not change `git config --global`.

## Release notes

`RELEASE_NOTES.md` accumulates the changes destined for the next GitHub release,
sorted into **Added** / **Changed** / **Fixed** sections.

- **For every new feature, fix, or notable change shipped, add a line to the
  matching section of `RELEASE_NOTES.md`**, in the same pass as the commit that
  introduces it. Don't wait for the release to reconstruct it from git history.
- **Never empty this file until a new release has actually been published.** It
  accumulates between two releases; `Scripts/release.sh` uses it to compose the
  GitHub release notes and resets it itself once the release is published — the
  agent must never do this by hand.

## Secrets

No API token, password, or personal identifier may ever appear in code, tests,
fixtures, or commit messages. `Scripts/ship.sh` scans changes before committing
(Atlassian tokens, GitHub tokens, `sk-` keys, Slack tokens). Secrets live in the
macOS keychain (`Sources/Atlassian/KeychainStore.swift`) or in the environment
(`ATLASSIAN_API_TOKEN`, `JIRA_DEFAULT_PROJECT`…), never hardcoded.

## Tests

- **Swift Testing** framework (`@Test`, `#expect`), not XCTest.
- Every test has a descriptive name in quotes that documents the expected
  behaviour rather than describing the test's mechanics.
- Any new field that's tolerant to decoding (new meeting-minutes section, new
  `ActionItem` field…) must be covered by a tolerant-decoding test (missing
  value, out-of-vocabulary value) in addition to the nominal case.
- Before considering a task done: `swift build` with no warnings and
  `swift test` fully green.

## Structural things to know

- **`Sources/Summarization/`** defines the LLM's output contract
  (`MeetingSummary`, `MeetingTemplate`, `SummaryPrompt`). Any new section or new
  field requested from the model must be added to the JSON schema
  (`schemaFragment`), to the fill-in guidance (`guidance(in:)`), and decoded
  tolerantly.
- **`Sources/Atlassian/`** orchestrates Confluence then Jira in this precise
  order (page first without the keys, tickets next with a link back to the
  page, then the page is rewritten with the keys) — see the comment at the top
  of `PublishService.swift` before touching it.
- **`Sources/MeetingStore/`** persists each meeting in its own folder on disk;
  `Meeting` must stay decodable for meetings recorded by an earlier version of
  the model (same tolerance rules as `MeetingSummary`).
- **`Sources/SmartMeetApp/`** is the SwiftUI UI plus orchestration
  (`RecordingSession`). Nothing goes out to Confluence/Jira/Notion without
  passing through the review window (`ReviewWindow`) — don't bypass this
  principle by adding an automatic publication path without explicit
  confirmation, except through a dedicated user setting that's already off by
  default (cf. `autoPublish`, `autoCreateJiraIssues`).

## Don'ts

- Don't commit, amend, push, or open a PR without an explicit request.
- Don't disable `Scripts/ship.sh`'s checks.
- Don't introduce a real name, e-mail, or company identifier in code, fixtures,
  or examples (cf. the history entry "Remove personal name and email traces
  before going public") — keep it generic.
- Don't change the code signing identity or the machine's global git identity.
</content>
