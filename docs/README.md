# Docs index

Every document in the repo, with when to read it. New here, or just pulled? Read these in order:
[`TEAM_BRIEF.md`](TEAM_BRIEF.md) (2 minutes), [`TEAM_HANDOFF.md`](TEAM_HANDOFF.md), the root
[`README.md`](../README.md), then [`AGENTS.md`](../AGENTS.md), then [`ios/README.md`](../ios/README.md).
Open [`CODE_REFERENCE.md`](CODE_REFERENCE.md) when you need a specific file or function, and check
the top of [`CHANGELOG.md`](../CHANGELOG.md) for what landed most recently (newest first; at the time
of writing Step 46 is commit `891f558` and Step 47 is the entry above it, Sat 2026-09-12 evening — the
pin goes stale every push, so trust the file, not this sentence).

**AI agents:** `AGENTS.md` first (hard rules + "How we engineer"), then `TEAM_HANDOFF.md` §10 ("How an
agent resumes"), then `CODE_REFERENCE.md`, then ask the knowledge graph (`graphify query "<question>"`,
see the last row of "Where do I find…"). Every status block names the date or commit it was written
at; the top of `CHANGELOG.md` and the code are the newest truth, and the block at the top of
`docs/todo.md` is headed "Historical (Fri 2026-09-11)" for that reason.

**Precedence:** when documents disagree with each other, `AGENTS.md` wins over
`docs/CODE_REFERENCE.md`. When any document disagrees with the shipped code, the code wins and the
doc gets fixed in the same commit. For design tokens, `docs/design.md` is the
spec: when it and `Theme.swift` / `WatchTheme.swift` disagree, fix the Swift. The exception is
screen layout and button labels, where the shipped code (and the tests that pin it) is what's real.

## Every doc

Tracked Markdown (`git ls-files "*.md"`: 31 files) plus the one other hand-written doc in the repo
(`opencane-hardware-brief.html`). Nothing else in the repo is documentation; source files document
themselves in their headers (AGENTS.md "How we engineer" 7).

### Repo root

| Doc | Read it when |
|---|---|
| [`README.md`](../README.md) | You want the pitch, the demo, the hardware list, the repo map and the quick start. |
| [`AGENTS.md`](../AGENTS.md) | **Before your first edit, human or AI.** It has the hard rules (concurrency, iOS 26 APIs only, logic lives in `ios/Logic`, secrets, frozen bundle IDs, audio session, speech priorities (rule 8), accessibility-label contract (rule 9), per-commit gate (rule 10)), "How we engineer", the commands, the two false-green traps, the OpenSCAD traps and the "looks wrong but is deliberate" list. It wins every conflict. |
| [`CLAUDE.md`](../CLAUDE.md) | You are Claude Code. It is the short version of `AGENTS.md`, loaded automatically. |
| [`CHANGELOG.md`](../CHANGELOG.md) | You need to know what landed in each build step, why, how it was reviewed and verified, and its "test on device" list. Newest first. Step numbers 15, 16, 17, 21, 22 and 25 each appear twice, on purpose (see the note under Step 27). Steps 38–46 also share their digits with the cue-v2 *plan* items in `docs/todo.md`, which are written "cue-v2 #38" … "#45" for that reason — a CHANGELOG "Step 41" is hazard telemetry, "cue-v2 #41" is torso haptics (shipped in Step 47). |
| [`.jules/bolt.md`](../.jules/bolt.md) | You are touching SwiftUI views that observe the 30 Hz depth stream. One learning (Step 21): keep high-frequency observed properties in leaf views, not in `ContentView.body`. |
| [`opencane-hardware-brief.html`](../opencane-hardware-brief.html) | You want the one-page hardware brief in a browser (added in the Step 21 bore-ring commit). For current print instructions use `hardware/3d_print_files/README.md` instead. |

### iOS app

| Doc | Read it when |
|---|---|
| [`ios/README.md`](../ios/README.md) | You are setting up a Mac, building, signing, installing or testing. It has the day-0 checklist, the Apple spec deviations you must not "fix" (§2, cited by `AGENTS.md` rule 7), every `make` target, secrets and permissions, the automation environment variables, the test layers and counts, how to pull a trip log off the phone, and the depth-map gotchas. |
| [`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md) | You want to test the camera features (sign reading, hazard watch, "Where am I") against Google Street View frames of the route, or you need to recapture the git-ignored JPEGs. |
| [`ios/drafts/README.md`](../ios/drafts/README.md) | Rarely. It explains the old iOS 18 starter files, which are not part of any target. |

### `docs/`

| Doc | Read it when |
|---|---|
| [`docs/TEAM_BRIEF.md`](TEAM_BRIEF.md) | **The 2-minute version, first after every pull** (Sagar, Tommy, Aarav, Tejas): status right now, what changed for you, the setup checklist, each person's tasks, installing on the phone, known quirks. |
| [`docs/TEAM_HANDOFF.md`](TEAM_HANDOFF.md) | **Second after every pull.** Start here (5 minutes), what is proven and what is not, who does what next, pull / build / install, the mount angle, what is on or off by default and why, the decisions that are final, the Street View mock, how to find anything, how an agent resumes (§10), known risks. |
| [`docs/CODE_REFERENCE.md`](CODE_REFERENCE.md) | You need to find or change code. It maps every file, type and function by module, with the data-flow diagram and the ⚠ invariants that tests pin. **Update the module's section in the same commit as the code change.** |
| [`docs/design.md`](design.md) | You are changing UI, colours or type, or how a cue feels, sounds or shows. §5 maps every cue to its haptic, speech and screen output (§5.1 is speech priorities and the Step 37 talk floor). §6 describes the shipped four-tab layout (Guide / Sense / Settings / Profile; §6.8 is the Profile tab, §6.5 has the Family alerts card). §9 is the accessibility-label contract table. |
| [`docs/cue_design_v2.md`](cue_design_v2.md) | **Before changing when OpenCane buzzes or speaks.** The Step 35 research (4 researchers + 4 fact-checkers, 74 kept findings): what blind travellers need (§1), where OpenCane violated it (§2), the proposed v2 (§3), the ranked change list (§4), open questions for a blind tester (§5), sources, and an addendum measured on the first field log. Numbers marked **[H]** are hypotheses. The approved plan (items cue-v2 #35–#45 — plan numbers, not CHANGELOG steps) is in `docs/todo.md` → "Cue design v2". |
| [`docs/auditory-load.md`](auditory-load.md) | You are adding or tuning any automatic sound. The Step 30 short research note on blind auditory overload, what OpenCane does about each point, and the open questions for tester walks. `cue_design_v2.md` is the later, fuller research. |
| [`docs/handsfree.md`](handsfree.md) | **You are the walker, or setting the phone up for one.** Every spoken command, what the status answer means, the Settings path for the Action button (and why a locked phone asks to unlock first), what the AirPods stem and Back Tap cannot do, asking a question, and what still needs the screen. |
| [`docs/devices_setup.md`](devices_setup.md) | Before touching the AirPods or the Apple Watch, and before the untethered demo: pairing, Spatial Audio off, the watch app, the voice cache, Guided Access, on-device vision and a symptom → fix table. |
| [`docs/route_isr_cif.md`](route_isr_cif.md) | You are editing `route_isr_cif.json` or re-recording the route on foot. It covers the evidence for every waypoint, OSM node IDs, and which points are still unverified. |
| [`docs/stress_test_plan.md`](stress_test_plan.md) | You are planning device and field tests: facts from the code that change how you test (§0), test levels, the device test matrix (D-tests), failure injection (F-tests), the blindfolded go/no-go checklist and the demo run sheet. |
| [`docs/todo.md`](todo.md) | You want to know what is still open. The strict build checklist, including the "Cue design v2 — items cue-v2 #35–#45" plan and one "## Step N" block per shipped step; tick it in the same commit. Its top block is a historical snapshot dated Fri 2026-09-11 and says so. |
| [`docs/ideas.md`](ideas.md) | You want the reasoning: the verdict, the pushbacks, the pitch script, prior art and the numbers. **§9 is the decision that stands (phone-only, buy nothing).** The rest is history, with inline status markers. |
| [`docs/superpowers/specs/2026-09-12-speech-load-design.md`](superpowers/specs/2026-09-12-speech-load-design.md) | You are touching optional speech (obstacle names, scene detail) and want the approved design for `SpeechLoadPolicy`: what may be suppressed and what never is. |
| [`docs/superpowers/plans/2026-09-12-speech-load.md`](superpowers/plans/2026-09-12-speech-load.md) | Same topic, as the task-by-task implementation plan. It landed in commit `6bac446` (Steps 29–33: `SpeechLoadPolicy.swift` + `SpeechLoadPolicyTests.swift`); its checkboxes were never ticked, so read it as history, not as open work. |
| [`docs/README.md`](README.md) | This file. |

### Hardware (the printed mount)

| Doc | Read it when |
|---|---|
| [`hardware/README.md`](../hardware/README.md) | You are working on the physical kit (Sagar, Tommy): the four things the app needs from any mount, which of the two designs is live (`mount_screwless/`), the screwed design's files, quick start and bill of materials. |
| [`hardware/3d_print_files/README.md`](../hardware/3d_print_files/README.md) | **You are standing at a printer.** The committed G-code (Creality SPARKX i7) and STLs, the print order, which filament slot, how to read step 1, assembly, what is not settled. |
| [`hardware/mount_screwless/README.md`](../hardware/mount_screwless/README.md) | You are changing the live, no-hardware mount: how it works, build, printer, what to measure before trusting it, the known-unknowns. |
| [`hardware/mount_screwless/PRINTING.md`](../hardware/mount_screwless/PRINTING.md) | Operator runbook for the screwless mount: print list, the one rule, slicing commands, reading the bore rings / thread set / dovetail pair, fitting, calibration. |
| [`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md) | You are working on the screwed mount (an unrendered draft) or need the reasoning both mounts share: Apple dimensions, the camera-tilt derivation (3–8° down), concepts, print settings, assembly, test protocol T0–T11. |
| [`cad/README.md`](../cad/README.md) | Stretch / legacy only. The OpenSCAD drafts for the ESP32 grip and sensor pod; they assume a 12.7 mm shaft and are not part of the phone-only demo. |
| [`firmware/README.md`](../firmware/README.md) | Stretch / legacy only. The ESP32 BLE grip firmware, not used for the hackathon. |

### Generated

| Doc | Read it when |
|---|---|
| [`graphify-out/GRAPH_REPORT.md`](../graphify-out/GRAPH_REPORT.md) | You want to know which parts of the repo cluster together, or what a `graphify query` answer is built on. Generated by graphify, never hand-edited. Its "Graph Freshness" line names the commit it was built from (rebuilt at Step 47, Sat 2026-09-12 evening: 4,681 nodes, 10,872 edges, 216 communities); run `graphify update .` after code changes. |

### Outside Markdown

| Where | What |
|---|---|
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | CI. It is **manual-trigger only** (`workflow_dispatch`; Actions tab → CI → Run workflow) because the account's GitHub Actions billing is exhausted. Jobs: Logic tests on Linux, an informational simulator build on macOS. The local `make` gate is authoritative. |
| `ios/Makefile` header | The one-line list of make targets (the full table is `ios/README.md` §3). |
| `scripts/*.ps1`, `scripts/stl_tools.js` (repo root) | Windows mount toolchain: `build_stl.ps1` (render every printable), `slice_gcode.ps1` (headless slicing + verification), `verify_mount.ps1` (the screwless-mount checks), `stl_tools.js` (the STL/G-code measurements they use). Each has a usage header. |
| `~/.claude/plans/phone-is-king-glittery-bee.md` | The approved build plan, on Aritro's Mac only (it is not in the repo). |

## Where do I find…

| I need… | Look here |
|---|---|
| **Build / run commands** | [`ios/README.md` §3](../ios/README.md#3-build-install-launch) (table of every `make` target) and the header of `ios/Makefile`. Run everything from `ios/`. |
| **Signing setup (team, device)** | `ios/local.mk`, which is git-ignored and holds `TEAM = …` and `DEVICE = …`. See [`ios/README.md` §1](../ios/README.md#1-day-0-checklist). |
| **The route file** | `ios/CaneKit/Resources/route_isr_cif.json` (9 waypoints, 989 m). Evidence is in [`route_isr_cif.md`](route_isr_cif.md). The schema is `ios/Logic/Sources/CaneKitLogic/Waypoint.swift`, pinned by `RouteTests.swift`. Other destinations use MapKit via `ios/CaneKit/Navigation/RouteSource.swift`; campus names ("take me to Siebel") resolve through `CampusPlaces.swift`. |
| **Navigation rules (fences, veer, arrival, turn settling)** | `ios/Logic/Sources/CaneKitLogic/GeoMath.swift` (`GeofenceTracker`, `OffCourseDetector`), `CourseSmoother.swift` and `NavSupport.swift` (`TurnSettle`, `StraightWalkDetector`). The engine is `ios/CaneKit/Navigation/NavigationEngine.swift`. The reasons are in `AGENTS.md` → "Things that look wrong but are deliberate". |
| **Speech rules (priorities, interruption, resume, Repeat)** | `AGENTS.md` rule 8 and its deliberate-behaviour list. The code is `ios/CaneKit/Speech/SpeechQueue.swift`, `CueSpeechPolicy` in `NavSupport.swift`, `SpeechLoadPolicy.swift` (optional-speech calm window), `SpeechResume.swift` (Step 37: a cut line resumes from its clause; 0.35 s pause between bands) and `ElevenLabsVoice.swift` (natural voice + cache). The cue table is [`design.md` §5](design.md#5-cue-mapping-every-cue--felt-heard-shown). |
| **Cue detail levels (Quiet / Standard / Detailed × Outdoors / Indoors)** | `CueRules`, `CueLevel`, `CuePlace` in `ios/Logic/Sources/CaneKitLogic/CueProfile.swift` (Step 36; tested in `CueProfileTests.swift`). Persisted as `AppModel.cueLevel` / `cuePlace`, default Detailed + Outdoors; the Settings → Cues card. Research: [`cue_design_v2.md`](cue_design_v2.md). |
| **Haptic patterns** | Phone: `ios/CaneKit/Haptics/HapticPlayer.swift` (obstacles: left 2 taps, right 3, head 2 hard hits, centre Geiger loop 2 Hz at 2 m → 8 Hz at 0.5 m; route: long buzzes, turn left 1, right 2, crossing 3, arrived long-short-long; ground hazard: 4 heavy taps). *When* a cue fires: `CueDecider.swift` + `GeigerRate` in `ios/Logic`. Wrist: the `WKHapticType` map in `ios/CaneKitWatch/WatchModel.swift`. |
| **Watch messages (phone ↔ watch)** | The wire contract is `ios/Logic/Sources/CaneKitLogic/WatchMessage.swift` (JSON under key `"m"`, tested in `WatchMessageTests.swift`). The phone side is `ios/CaneKit/Watch/PhoneWatchLink.swift` and the watch side is `ios/CaneKitWatch/WatchModel.swift`. |
| **Voice commands, Siri, Action button, conversation** | `ios/CaneKit/App/AppIntents.swift`, `App/HandsFreeIntents.swift`, `ios/CaneKit/Conversation/` (`ConversationCoordinator`, `VoiceInputEngine`, `PostStore`), and the Logic side `ConversationModels.swift` / `FastPathIntentClassifier.swift` / `ConversationPrompt.swift` / `QuestionPrompt.swift` / `StatusSummary.swift`. The walker's view is [`handsfree.md`](handsfree.md). |
| **Flashlight / both cameras** | `TorchSwitch.swift` and `LiveView.swift` (`BothCameras`, `FaceTrackingChange`) in `ios/Logic` (Step 34). |
| **Secrets / API keys** | The template is `ios/Secrets.example.plist`. Real keys go only in `ios/CaneKit/Resources/Secrets.plist`, which is git-ignored: never commit or print it. The reader is `ios/CaneKit/Scene/Secrets.swift`. The key list is in [`ios/README.md` §4](../ios/README.md#4-secrets-and-permissions). |
| **Testing** | See [`ios/README.md` §5](../ios/README.md#5-testing). Logic tests are in `ios/Logic/Tests/CaneKitLogicTests/` (`make test`; 575 `@Test` annotations in 44 files at Step 47 — Step 46's recorded run was 538/538; recount before quoting). UI tests, the screenshot tour and the Dynamic Island tour are in `ios/CaneKitUITests/` (`make uitest` runs all 12, `make tour` and `make island` one suite each). GPS-replay end-to-end runs through `ios/scripts/e2e.py` (`make e2e`). Automation is silent under `CANEKIT_MUTE=1` / `CANEKIT_UITEST=1`. |
| **Accessibility labels the tests depend on** | `AGENTS.md` rule 9 lists them. The details are in `CODE_REFERENCE.md` → module `ui-tests-build` and `design.md` §9. |
| **UI tokens and components** | `ios/CaneKit/UI/Theme.swift` (`CKColor`, `CKFont`, `CKBigButton`, …) and `ios/CaneKitWatch/WatchTheme.swift`. The spec is [`design.md`](design.md), which wins on token values. |
| **Trip log (what happened on a walk)** | `ios/CaneKit/Trip/TripLogger.swift` writes `canekit-<stamp>.jsonl` to the app's Documents folder. Get it with the Files app (On My iPhone → OpenCane), with `cd ios && make audit` (pulls the newest log off the phone in `local.mk` and measures its cue load), or with the `xcrun devicectl … --domain-type appDataContainer --domain-identifier com.aritro.canekit` commands in [`ios/README.md` §5](../ios/README.md#5-testing). |
| **Cue-load numbers for a walk** | `ios/scripts/cue_audit.py` (`make audit`, or `make audit LOG=path`): mounted vs handheld, head band wall vs overhang, cues and spoken lines per minute, replays and resumes. |
| **Hazards (drop-offs, signs, hazard watch, hazard map)** | Decisions: `ios/Logic/Sources/CaneKitLogic/Hazards.swift` (tested in `HazardTests.swift`). App side: `ios/CaneKit/Depth/GroundSampler.swift`, `ios/CaneKit/Scene/HazardScanner.swift`, `OnDeviceVision.swift`, `ios/CaneKit/Trip/HazardLog.swift`, `ios/CaneKit/UI/HazardsCard.swift`. |
| **Mount angle** | `MountTilt` in `ios/Logic/Sources/CaneKitLogic/LaneReport.swift`; live on the Mount card; derivation in `hardware/mount/DESIGN.md`. |
| **Street View mock** | `ios/CaneKit/Depth/FrameReplay.swift`, `ios/scripts/streetview/`, `ios/scripts/vision_probe.swift`, `ios/scripts/sign_probe.swift`, `make uitest-streetview`, `make e2e SCENARIO=streetview`. Not the app: `ios/scripts/streetview_stim.py` (commit `d775d4b`, run by hand) is a stand-alone visualiser over the same frames with its own approximate navigation and template narration. |
| **Project / targets / Info.plist / entitlements** | `ios/project.yml` (XcodeGen). Regenerate with `make gen` only when `project.yml` or the file list changed. Never hand-edit `CaneKit.xcodeproj`. |
| **What's left to do** | [`todo.md`](todo.md) (the "Cue design v2 — items cue-v2 #35–#45" section is the live plan; the "## Step N" blocks near the end hold each shipped step's unticked device checks). The latest `CHANGELOG.md` entry lists its device checks; older entries keep their historical test notes. |
| **The knowledge graph** | `graphify-out/` at the repo root (`GRAPH_REPORT.md` lists the communities; `graph.html` opens in a browser; `graph.json` is the data). Ask it from the repo root with `graphify query "<question>"`, `graphify path "A" "B"` or `graphify explain "X"`. After code changes, refresh it with `graphify update .` (code only) or `/graphify . --update` in Claude Code. Install once with `uv tool install graphifyy` (the build Mac has graphifyy 0.9.44). |
