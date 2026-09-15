# Remaining work

Sorted by what's most expensive to ignore. See the git history for progress:
fixed points are removed as they go, not just checked off here.

---

## 1. Resolved — notifications not working

**Root cause identified and fixed on 09/13**: three stacked problems.

1. The Apple intermediate certificate (WWDR G3) present in the development
   machine's keychain had **expired in 2023**. Result: even a freshly
   generated "Apple Development" certificate via Xcode (Accounts → Manage
   Certificates) stayed `CSSMERR_TP_NOT_TRUSTED` (`security find-identity -v -p
   codesigning` returned 0 valid identities despite a certificate being
   present). Fixed by reinstalling an up-to-date WWDR G3 (valid until 2030):
   `curl -sL -o AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer`
   then `security add-certificates -k ~/Library/Keychains/login.keychain-db AppleWWDRCAG3.cer`.
2. **The app must be signed with that real identity**, not ad hoc:
   `codesign --force --sign "Apple Development: <email> (<TEAMID>)" --options runtime
   --entitlements Sources/SmartMeetApp/SmartMeet.entitlements --timestamp=none
   build/SmartMeet.app`. An ad hoc identity (`--sign -`), unstable from one
   build to the next, seems to prevent macOS from durably remembering a
   permission grant.
3. **The initial refusal stays remembered per bundle ID** even after fixing
   the two points above: `requestAuthorization` still failed for
   `com.smartmeet.app` after all these changes. It had to be authorized once
   manually in System Settings → Notifications → SmartMeet → turn the toggle
   on. Once done, `requestAuthorization` works normally and notifications are
   delivered.

Diagnostic (rerun it if any doubt comes back — **always via `open`, never by
running the binary directly**, otherwise LaunchServices doesn't register the
app):

```sh
open build/SmartMeet.app --args --check-notifications /tmp/report.txt
```

**Point to watch going forward**: this project's usual rebuild script uses
`codesign --sign -` (ad hoc). If notifications start failing again, check
first that the build was actually signed with a stable identity (`Apple
Development: <your Apple ID email> (<TEAMID>)`) and not ad hoc.

---

## 2. Identified bugs

### Search to extend to new content

`Meeting.matches` now covers title, summary, transcript, attendees and
decisions (the transcript is read from `MeetingStore` at filtering time). If
new text fields are added to the minutes, remember to include them in
`RecordingSession.filteredMeetings`'s haystack.

---

## 3. Planned then forgotten

### Model download onboarding

Language asset downloads happen silently in `TrackTranscriber.start()`,
behind a simple "Preparing models…". On first launch, over a slow
connection, the user sees no progress and may think it's stuck. A welcome
screen with a progress bar was planned.

### Re-transcription from the retained audio

`Meeting.trackStartOffsets` is persisted **exactly for this** — realigning a
transcript recomputed after the fact — but nothing uses it yet. Both `.caf`
tracks are kept regardless. Would allow re-transcribing with a better model,
another language, or after fixing domain vocabulary.

---

## 4. Unverified — open risks

In decreasing order of likely bad surprises:

| Area | What has never been exercised |
|---|---|
| **Real meeting** | No real recording with several humans. Everything is validated against text-to-speech and hand-written fixtures, so too clean and too well structured. |
| **Long meeting** | The map-reduce path (> 48,000 characters) is unit-tested, never exercised end to end. |
| **Confluence rendering of new sections** | `sprintWeather` and `fourL` are only validated by unit tests. A single real publication happened and was deleted. |
| **Detection under real conditions** | The Core Audio primitive is proven, the decision logic tested, but no real video call has ever triggered a suggestion. |
| **Audio device change** | Plugging in headphones mid-meeting rebuilds the converter and causes a discontinuity, never measured. |
| **Deleted Confluence page** | The `AtlassianError.pageNotFound` fallback (see `PublishService.resolveDestination`) has only been exercised by reading the code, never against an actually deleted page. |
| **Consent reminder** | The banner shown while recording (`MenuBarContent.consentReminder`) has never been seen by a real participant; its placement and wording deserve an outside opinion. |
| **Editing built-in types** | The four base types (`Daily`, `Sync`, `Retrospective`, `Generic`) are now directly editable (stored as an override in `customTemplates`, resettable). Never tested beyond compilation and existing unit tests — no test dedicated to this override mechanism. |
| **End-of-meeting detection** | `RecordingSession.observeMeetingEnd()` polls `ConferencingDetector.activeApps()` during recording and proposes stopping after a 90 s absence. The grace period, the "still active" match by app name, and the snooze delay are all guesses, never checked against a real Teams/Zoom call with a real network hiccup or a deliberately muted app. |

---

## 5. Known quality issues, to improve

### Cross-talk

`CrossTalkFilter` relies on empirical thresholds (3 s tolerance, 50 % overlap)
calibrated on test cases, not on real meetings. To be tuned on real
hardware.

Hardware echo cancellation remains unusable: `setVoiceProcessingEnabled(true)`
deprives the system tap of its source. Software echo cancellation — the
system track is known, hence subtractable from the microphone track — hasn't
been explored and would be the real solution.

### Domain proper nouns

"Crowdin migration" comes out as "coronal migration" despite vocabulary
injection into `AnalysisContext.contextualStrings`. To be re-assessed on a
human voice before investing further: text-to-speech mispronounces proper
nouns, the problem might be overestimated.

### Weather icon

The icon picked by the model is an interpretation: "clearing up" came out as
a rainbow in one trial. Fixable in one click during review, but not
reliable.

### Local models

`ollama` resolves relative dates less reliably — "next Tuesday" landed on a
Wednesday. Acceptable as a fallback, not for primary use.

### Speaker identification

The system track groups every remote participant under a single label.
Names come only from the calendar, and it's the model that attributes
statements. Real intra-track diarization would noticeably improve dailies
and retrospectives.

These five points share the trait of only being settleable on real hardware
(real voices, real network, real accent): no hand-written fixture will
settle them. Don't reopen them until a real meeting has been recorded (see
section 4).

---

## 6. Debt and tooling

- No continuous integration. The repository is personal, but `ship.sh`
  already runs everything that would need to.
- No version management or distribution: no notarization, no updates.

---

## 7. Ideas not committed to

- Choosing the minutes' language **after the fact** and regenerating, rather
  than only before recording.
- Generating both languages at once for mixed-audience meetings.
- Detecting the end of a meeting — the video app releases the microphone —
  and offering to stop recording.
- Automatically attaching minutes to the sprint page *matching the meeting's
  date* rather than the current page, useful for delayed publication.
- Searching for a parent page by title in settings, instead of pasting a URL.

---

## 8. Picking this up on another machine

What does **not** live in the repository and will need to be redone:

| Item | Where it lives | To redo |
|---|---|---|
| Signing identity | Keychain | An Apple development identity is enough. `bundle-app.sh` automatically picks the first one found; otherwise `SMARTMEET_SIGN_IDENTITY="…"`. |
| Atlassian/Notion API tokens | Keychain (`com.smartmeet.atlassian`/`com.smartmeet.notion`), one account per profile ID | Settings › Services, under the active profile. Atlassian is picked up from `ATLASSIAN_API_TOKEN` on first launch if present in the environment. |
| Space, Jira project, epic parent, sprint page, Notion workspace | `defaults` of `com.smartmeet.app`, keyed by profile ID | Settings › Services, under the active profile. |
| Profiles (Work, Personal…), each with its own vocabulary, meeting types, behavior toggles and default service | `defaults` of `com.smartmeet.app` (`profiles` key) | Settings › Profiles. |
| Custom meeting types, including overrides of built-in types | `defaults`, scoped per profile | Settings › Meeting Types. The built-in types stay in the code, but a local edit takes priority as long as it exists (see `AppSettings.upsert`/`remove`). |
| Microphone, audio capture, calendar, notification permissions | TCC | Requested again on first launch. **The bundle must be launched through LaunchServices** (`open build/SmartMeet.app`), never from a terminal, otherwise system audio capture silently returns silence. |
| `SpeechTranscriber` language models | System | Downloaded on first recording. |
| Recorded meetings | `~/Library/Application Support/SmartMeet/Meetings/` | Not versioned. Copy the folder if needed. |

Requirements: macOS 26, Apple Silicon, Xcode 26. Then `opencode` or `ollama`
for generating the minutes.

Checking everything is in place:

```sh
swift test                                   # 154 tests
./Scripts/bundle-app.sh && open build/SmartMeet.app
open build/SmartMeet.app --args --check-notifications /tmp/report.txt
```
</content>
