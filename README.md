# The One Ring Planner

**A little less chaos. A little more second breakfast.**

A native macOS planner that brings tasks, routines, Google Calendar and meeting notes into one quiet workspace. Built with Swift, SwiftUI and AppKit, plus a small Objective-C audio bridge, with no third-party package dependencies.

**Current version:** 0.23.2 · Personal desktop application · macOS 14+

![Today’s plan with fictional Hobbit tasks and an Inbox](docs/screenshots/today.jpg)

All screenshots use an isolated, fictional Middle-earth workspace. No personal tasks, calendars, credentials or real meeting recordings are shown.

## What it does

- **Capture and prioritize:** text or voice capture, editable AI cleanup, project tags, and a four-quadrant matrix. Drag tasks between quadrants, change priorities, or expand a quadrant to focus.
- **Plan a realistic day:** work hours, lunch, meetings, routines, transitions, focus blocks and reserve all count toward capacity. Daily review prepares the next working day, skipping weekends: Friday plans target Monday. Choose its tasks before confirming the plan.
- **Find time in Google Calendar:** Q2 suggests an available slot; accept it or choose another on the calendar. Drag or resize scheduled tasks and routines, with changes synced to Google. Tasks are red; routines are green.
- **Build routines:** daily, weekdays, weekends or selected days, with flexible/protected placement and small completion celebrations.
- **Record with The Eye:** system audio, microphone or both; English/Russian transcription, speaker aliases, topics, timecodes and reviewed task extraction. Your “Me” speaker lane stays pink.
- **Keep the history:** complete a task from any quadrant, inspect past work, restore tasks, and re-transcribe meetings with another model while retaining older transcript versions.
- **Stay nearby:** a colored ring in the menu bar, recording controls, global capture shortcuts and optional alerts one minute before events.

In **Today**, click a task’s circle to complete the whole task. Completed tasks appear below the schedule, with an option to mark them incomplete and return them to their priority quadrant. **Task actions → Move to backlog** removes unfinished work from saved schedules while keeping its priority, estimate and details. Completion shows a brief gold check animation with Undo and a soft chime; turn the sound off in **Settings → Completion**. Reduce Motion is respected, and the chime stays quiet during meeting or Inbox recording. Published Google changes still require plan confirmation.

## A quick tour

### Decide what matters

Inbox stays on the right. Drag a task to a quadrant; if duration or other required details are missing, the planner asks before moving it. Each quadrant scrolls independently and can expand to full screen.

![Priority matrix with fictional Fellowship tasks in all four quadrants](docs/screenshots/priority-matrix.jpg)

### See where the day goes

The day/week calendar draws each block in proportion to its duration. Move a task or routine to another time or day, or drag its edges to change its length. Confirmed Google bookings keep the same event identity through edits.

![Weekly calendar showing Fellowship tasks, second breakfast and Shire walks](docs/screenshots/calendar.jpg)

### Let the little things repeat

Create routines, pick repeat days, and give them a suitable window. Editing one scheduled calendar occurrence leaves the repeating template intact.

![Routine settings with fictional Shire activities](docs/screenshots/routines.jpg)

### Turn a conversation into next steps

The Eye combines playback, a topic timeline, searchable timestamped text and task suggestions. Name speakers, mark yourself as “Me”, and review tasks in **Mine → Unassigned → Others** order before adding them to Inbox.

![The Eye with a fictional bilingual Council of Elrond transcript](docs/screenshots/the-eye.jpg)

Use **More → Re-transcribe…** to choose another audio model or rerun the same one. The current result stays available while the new attempt runs. **More → Transcript versions…** restores an earlier result; imported tasks and original audio remain intact. Interrupted processing can resume from saved checkpoints.

## Build and deploy on your Mac

This repository contains source code. There is no web server, database service or hosted backend to deploy; Google Calendar and a LiteLLM gateway are optional connections.

### Requirements

| Requirement | Notes |
| --- | --- |
| Mac | macOS 14 or later; developed and tested on Apple silicon |
| Build tools | Swift toolchain with the macOS 26 SDK, from recent Xcode or Command Line Tools; verified with Swift 6.3.3 |
| Utilities | Git, Python 3, and the macOS tools `codesign`, `security`, `sips`, `iconutil`, `ditto` and `openssl` |
| Optional services | Your own Google Cloud Desktop OAuth client; a LiteLLM-compatible gateway and key for cloud AI |

System audio capture requires macOS 14.2+. Apple’s newer local transcription path requires macOS 26 and installed language assets. Other meeting transcription can use the configured gateway.

### 1. Get the source

```sh
git clone https://github.com/nbnm/the-one-ring-planner.git
cd the-one-ring-planner
```

If build tools are missing, install Command Line Tools with `xcode-select --install`. Check `swift --version` and `xcrun --show-sdk-path` before building. Python 3 must be available as `python3`.

### 2. Check and build

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The application is created at **`build/The One Ring Planner.app`**. The build script creates or reuses a dedicated local signing identity in your login Keychain. macOS may ask you to authorize its creation/use. No API key, Google account or Apple Developer subscription is needed for a local build.

### 3. Install and launch

Save any recording, wait for processing to finish, then quit any running copy with **Command + Q** or **Quit** in the ring menu. Closing the window leaves the app running in the menu bar.

```sh
./scripts/build-app.sh --install
```

This builds, copies the app to **`~/Applications/The One Ring Planner.app`**, and opens it. Installation refuses to replace a running planner. For a copy you already built, you can instead use:

```sh
mkdir -p "$HOME/Applications"
ditto "build/The One Ring Planner.app" "$HOME/Applications/The One Ring Planner.app"
open "$HOME/Applications/The One Ring Planner.app"
```

A normal first launch has an empty Inbox. Set your planning time zone, workday and routine preferences in Settings. Allow microphone, system audio or notifications only when using the related features; the app explains failures and preserves existing recordings.

### 4. Preview with fictional data

Quit the regular app first to avoid overlapping menu bar items and shortcuts, then run:

```sh
open -n "build/The One Ring Planner.app" --args --demo --middle-earth-demo
```

This is the same fixture used for the screenshots: tasks about Hobbits and the Fellowship, Shire routines, and a bilingual example meeting with synthetic test tones. It uses temporary task/meeting folders, separate connection preferences and separate Keychain service names. It does not read your normal task or meeting workspace or connect your real Google calendar. Demo recording creates test tones instead of capturing a call. Quit and launch normally to return to your own workspace.

### 5. Update an existing installation

```sh
git switch main
git pull --ff-only
./scripts/test.sh
./scripts/build-app.sh
```

Quit the installed planner, then install using step 3. Keep the existing local signing identity across builds. macOS may still request Keychain authorization after an update; a stable local signature does not guarantee prompt-free access.

### Distribution to other people

The build script produces a **locally signed personal app**, not a Developer ID signed/notarized distribution. Other Macs should build their own copy using these instructions. Public binary distribution needs a separate Developer ID signing/notarization workflow and an appropriately configured Google OAuth project; neither is automated here. The build targets the current Mac’s architecture.

## Connect Google Calendar

The integration talks directly to Google; it does not use macOS Calendar or EventKit.

1. Create/select your Google Cloud project and [enable the Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
2. Configure Google Auth Platform’s branding, audience and contact details. Use an eligible Workspace **Internal** audience, or **External** with your account as a test user while testing.
3. Create an OAuth client of type **Desktop app** and download its JSON. An API key or web client is insufficient. See [Google’s Desktop OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app).
4. In **Settings → Google Calendar**, choose **Import OAuth credentials…**, then **Sign in with Google**. Complete consent in your browser and select the calendars that should affect availability.
5. For bookings, choose **Enable calendar writing**, approve the additional permission, and select a destination calendar you own.
6. Use **Confirm & add to calendar** for a day plan, or accept an individual Q2 time slot. Merely browsing or saving a draft does not publish it.

The app initially requests `calendar.calendarlist.readonly` and `calendar.events.readonly`; writing adds `calendar.events.owned`. See [Google’s scope definitions](https://developers.google.com/workspace/calendar/api/auth). Tokens and imported credentials are held in Keychain. External apps in Testing can require sign-in again after seven days because of [Google’s refresh-token rules](https://developers.google.com/identity/protocols/oauth2#expiration).

Google time changes are read on activation, manual refresh and every five minutes while the app runs. Calendar edits are queued locally and retried after failure. Concurrent edits require choosing **Use Google time** or **Apply my time**. External title/notes/deletion synchronization is not implemented as a general two-way import.

## Connect LiteLLM and meeting AI

1. Open **Settings → Task cleanup · LiteLLM**.
2. Enter your gateway base URL (for example, `https://your-gateway.example/v1`), its text-model alias, and your key. Save and test the connection. No key belongs in this repository or an `.env` file.
3. In **The Eye → Audio models**, check the gateway catalog and choose a separate audio transcription alias. The gateway must expose `/audio/transcriptions`; the text alias must support `/chat/completions`.
4. Use a diarization-capable model for individual speaker labels. `whisper-1` uses timestamped transcription without individual speaker separation. Catalog names alone do not prove the gateway supports a feature.
5. Choose processing explicitly and review the gateway/model information before uploading. Review extracted tasks before adding them to Inbox.

Meeting audio stays local until cloud processing is chosen. That sends audio to the saved gateway, followed by transcript analysis through its text model. Text-only analysis sends the saved transcript without audio. Task cleanup sends the capture and tag names. Retention and model routing depend on your gateway.

Long meetings are processed in short audio chunks with bounded retries and saved checkpoints. An hour of synthetic audio is covered by local tests; recognition quality and live processing speed depend on the chosen model, gateway and recording. Speaker aliases are per meeting and explicitly assigned.

## Everyday controls

| Action | Control |
| --- | --- |
| Quick capture | **Control + Option + Space** |
| Review capture | **Command + Return** |
| Start/stop Inbox dictation | **Control + Option + R**, or Inbox microphone |
| Record a meeting | Ring menu → **Record meeting…**, or The Eye |
| Stop/save a meeting | Ring menu or recording-only Eye menu |
| Return from expanded quadrant | **Escape** / **Back to matrix** |
| Quit | **Command + Q** / ring menu → **Quit** |

The Eye appears in the macOS menu bar only during recording/saving. Enable optional event alerts in Settings; macOS notification settings and Focus still apply. Automatic launch at login is not implemented.

## Your data and backups

Application data is separate from this source-code repository:

```text
~/Library/Application Support/The One Ring Planner/
├── Data/       # task, capture, routine, plan and completion JSON; local Git history
├── Local/      # workspace identity and recovery state
├── Meetings/   # original audio, transcripts, versions and processing checkpoints
└── Signing/    # public certificate metadata; private signing key is in Keychain
```

Back up this folder while the app is quit, including the hidden `Data/.git` directory. The local data Git history is not automatically pushed to this GitHub repository. Task deletion does not erase older local Git history. Recordings use recoverable macOS Trash when removed through the app.

Keys and Google tokens stay in macOS Keychain and are not part of a file backup. On a new Mac, reconnect the services and create a local signing identity, or deliberately migrate the existing signing identity and its metadata. Do not replace a saved identity with a different certificate while retaining its old metadata.

## Development and verification

```sh
./scripts/test.sh                   # 157 deterministic core checks
./scripts/test-voice.sh             # controlled voice lifecycle checks
./scripts/test-meetings.sh          # 45 generated-audio/playback/capture checks
./scripts/test-audio-input.sh       # 11 native-format, route-recovery and exception-safety checks
swift build                        # compile the native app
```

Optional `./scripts/test-speech-integration.sh` and `./scripts/test-meetings.sh --speech` use generated speech with Apple’s installed language assets; they may download assets and require supported macOS versions. `python3 scripts/test-signing.py` tests the local signing identity against synthetic Keychain items. These are separate from the offline core checks.

| Folder | Purpose |
| --- | --- |
| `Sources/RingCore` | Scheduling, models, persistence, Google API and AI contracts |
| `Sources/RingPlanner` | Native UI, capture, playback, app/menu bar lifecycle |
| `Sources/RingAudioSupport` | Hardware microphone format and native audio exception handling |
| `Tests` | Dependency-free checks and generated audio fixtures |
| `scripts` | App packaging, local signing and verification |
| `docs` | Screenshots, implementation notes and detailed feature reference |

See [the feature reference](docs/feature-reference.md) and [implementation notes](docs/implementation.md) for detailed behavior and limitations. Artwork is AI-generated, with prompts retained under `docs/artwork`. This is an unofficial fan-inspired project and is not affiliated with the creators or owners of The Lord of the Rings.
