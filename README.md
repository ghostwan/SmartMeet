# SmartMeet

Records a meeting on macOS, transcribes it on-device, generates the meeting
minutes, and publishes them to Confluence with action items turned into Jira
tickets.

Native menu-bar app. No audio ever leaves the machine: capture and
transcription are entirely local.

## What sets it apart

**Diarization by physical separation.** The microphone and system audio are
captured on two distinct tracks, via a Core Audio *process tap* — no virtual
driver like BlackHole. Whatever comes from the microphone is you, whatever
comes from the system is a remote participant. No diarization model is
needed.

**Meeting types.** The minutes don't follow a single format. A daily opens
with blockers and details each person's update; a retrospective opens with
the team's nominative mood, then groups the discussion by topic without
attributing any statement. The chosen type drives the schema requested from
the model, the rendering order, the page title, and its destination.

**Sprint page.** Set it once at the start of a sprint; every sprint meeting's
minutes then attach to it automatically, with nothing left to reconfigure.

**Output language.** The minutes are produced in French or English,
independently of the language spoken. The choice is made before recording: it
drives the prompt, not just the formatting.

**Meeting detection.** When a meeting starts, SmartMeet offers to record it
through an actionable notification. Detection cross-references two signals:
the calendar, which says what *should* be happening, and the video
conferencing app capturing the microphone, which says what has *actually*
started.

## Requirements

macOS 26 or later, Apple Silicon, Xcode 26.

For generating the minutes, pick one:

- [`opencode`](https://opencode.ai) — uses a GitHub Copilot subscription;
- [GitHub Copilot CLI](https://github.com/features/copilot/cli) — exposed through
  its structured ACP interface;
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — uses the
  subscription authenticated in the official `claude` CLI;
- Apple Intelligence — built into macOS, fully local, best suited to shorter
  meetings because of its smaller context window;
- [`ollama`](https://ollama.com) — fully local, no data ever leaves.

## Installation

```sh
./Scripts/bundle-app.sh
open build/SmartMeet.app
```

The bundle is signed with the first development identity found in the
keychain. To force another one:

```sh
SMARTMEET_SIGN_IDENTITY="Apple Development: …" ./Scripts/bundle-app.sh
```

> The bundle **must** be launched through LaunchServices (`open`), not from a
> terminal. Run directly, the responsible process is the terminal: TCC does
> not grant the audio capture permission and the tap silently returns
> silence, with no error at all.

## Usage

When a meeting is detected, a notification offers to record it: *Record* or
*Not now*. Title and attendees are picked up from the calendar. Otherwise,
pick a meeting type from the menu and click **Record**.

### Detection

Two signals, deliberately cross-referenced:

| Signal | What it brings | What it's missing |
|---|---|---|
| Calendar (EventKit) | title, attendees | fires on cancelled or rescheduled meetings |
| Microphone captured by a video conferencing app (Core Audio) | proof the meeting actually started | knows neither title nor attendees |

Rules applied:

- a dedicated app (Teams, Zoom, Webex, Slack, Meet…) capturing the microphone
  is enough on its own, even without a calendar event;
- a **browser** capturing the microphone is too ambiguous — mic test, video,
  dictation — and is only retained if the calendar confirms it;
- an event alone only triggers if it carries a video conferencing link,
  otherwise any physical meeting or blocked time slot would produce a
  suggestion.

A dismissed suggestion doesn't come back for the same meeting, and
suggestions re-arm once a recording ends.

Automatic start without confirmation exists in the settings but stays
**disabled by default**: recording people without warning them is not a
behaviour to turn on on their behalf.

The rest of the time: pick a meeting type from the menu, click **Record**.
The transcript streams live. On stop, the minutes are generated, then
reviewable and editable before publication.

Each meeting is a self-contained folder:

```
~/Library/Application Support/SmartMeet/Meetings/<uuid>/
    meeting.json     metadata and minutes
    segments.json    structured transcript
    transcript.md    readable transcript
    summary.md       minutes formatted per meeting type
    microphone.caf   user's track
    system.caf       participants' track
```

### Built-in types

| Type | Sections, in order | Title | Destination |
|---|---|---|---|
| Generic meeting | summary, decisions, action items, topics, open questions, next steps | `{summary} — {date}` | default space |
| Daily | **blockers**, per-person update, action items, summary | `Daily {Weekday} {date}` | sprint page |
| Sync | summary, decisions, action items, topics, open questions, next steps | `{summary} — {Weekday} {date}` | sprint page |
| Retrospective | **sprint weather**, depersonalized 4L, action items, decisions | `{type} — {date}` | sprint page |

They're duplicated and edited in *Settings › Meeting Types*: sections,
order, writing guidance, title format, and destination.

### Retrospective: sprint weather and 4L

The retrospective produces two parts of opposite nature.

**Sprint weather** — nominative, meant to be shared with managers. Each
member picks one or more weather icons (☀️ 🌤️ ☁️ 🌧️ ⛈️ 🌫️ ❄️ 🌈 💨 🔥) to
illustrate their sprint, explains their choice, then talks about their
sprint. The minutes restitute their words with their nuances rather than
smoothing them out — it's the only way a manager gets something other than a
sanitized summary out of it. Only what's said out loud counts: sticky notes
and the board are not in the transcript.

**4L** — depersonalized. *Liked*, *Learned*, *Lacked*, *Longed for*. Remarks
are grouped by theme and no statement is attributed to anyone, which allows
sensitive topics to be raised without putting anyone on the spot.

### Page titles

The title produced by the model varies from one meeting to the next, which
makes the Confluence tree unreadable. The format takes over from there:

| Token | Rendered as |
|---|---|
| `{summary}` | title proposed by the model |
| `{type}` | meeting type name |
| `{Weekday}` / `{weekday}` | `Monday` / `monday` |
| `{date}` | `September 7, 2026` |
| `{shortDate}` | `09/07/2026` |
| `{isoDate}` | `2026-09-07` |
| `{time}` | `14:30` |

Since Confluence refuses two pages with the same title in a space, a
collision is resolved with a `(2)`, `(3)`… suffix.

The literal parts of the format are not translated: it's a naming
convention, not content. Only the date tokens follow the language of the
minutes.

### Destination

Each type publishes to one of these targets:

- **current sprint page** — set in *Settings › Services*, by pasting the
  page's URL. The space is inferred from the page. As long as no page is
  set, the minutes go to the space's home page instead of failing;
- **fixed page** — Confluence identifier or URL;
- **space home page**.

The effective destination is shown in the menu and before publishing.

### Headless mode

Useful for diagnostics and end-to-end testing.

```sh
# record 30 s, transcribe, generate the minutes
open -W build/SmartMeet.app --args --headless 30 /tmp/report --summarize

# generate minutes from an existing transcript
./build/SmartMeet.app/Contents/MacOS/SmartMeet \
    --summarize-file Fixtures/transcript-daily.md \
    --template builtin.daily --publish
```

## Profiles

*Settings › Profiles* switches between usage contexts (e.g. "Work" and
"Personal") from the menu bar. Everything else in Settings — vocabulary,
which meeting types are visible and which is the default, publication
services and their credentials (a different Confluence site or Notion
workspace per profile), behavior toggles (auto-record, auto-publish, meeting
detection, spoken/output language, microphone-track diarization…) — is scoped
to the active profile. A fresh profile starts blank: no service configured,
only the generic meeting type enabled. Upgrading from a version without
profiles migrates every existing setting into a single seed "Work" profile
automatically.

## Configuration

*Settings › Services* lists publication services as a dynamic, addable list
(rather than fixed tabs always shown) — add Notion and/or Confluence per
profile, each with its own credentials:

*Confluence*: site, e-mail, API token, Confluence space, Jira project. The
token is kept in the keychain. On first launch, it is picked up from
`ATLASSIAN_API_TOKEN` if present in the environment.

Some Jira projects require an epic parent through a workflow validator that
the `createmeta` API doesn't declare. The *Epic parent* field covers that
case.

## Architecture

```
Sources/
├── AudioCapture/     Core Audio process tap, microphone, shared clock
├── Transcription/    SpeechAnalyzer, track fusion, cross-talk filter
├── Summarization/    meeting types, prompts, LLM providers
├── Atlassian/        Confluence, Jira, storage rendering
├── Calendar/         detection: calendar and video conferencing apps
├── MeetingStore/     on-disk persistence
└── SmartMeetApp/     menu-bar interface
Spikes/               technical validation test benches
```

## Known limitations

- **Cross-talk.** Without headphones, the speakers feed back into the
  microphone and both tracks transcribe the same speech. Hardware echo
  cancellation (`setVoiceProcessingEnabled`) is unusable here: Apple's voice
  processing takes over the output device and deprives the system tap of its
  source. The fix therefore happens on the text (`CrossTalkFilter`), with
  empirical thresholds.
- Domain-specific proper nouns are approximated by transcription, despite
  vocabulary injection. Headphones noticeably improve the result.
- Switching audio device mid-meeting causes a discontinuity.
- Local models (`ollama`) resolve relative dates less reliably.
- The weather icon picked by the model is an interpretation: "clearing up"
  can come out as a rainbow. It's fixed with one click in the review window.

## Development

```sh
swift build
swift test
```

To ship — checks, commits and pushes in one go:

```sh
Scripts/ship.sh "Commit message"
Scripts/ship.sh --no-push "Message"   # local commit only
Scripts/ship.sh --amend               # fixes the last unpublished commit
```

The commit is rejected if the build fails, if a compiler warning remains, if
a test fails, or if an API token shows up in the changes.

The icon is drawn in code (`Scripts/make-icon.swift`) and regenerated on
every bundle assembly: it stays editable and readable in diffs, rather than
being an opaque binary in the repository.
</content>
