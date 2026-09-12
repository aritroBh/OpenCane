# Docs index

Every document in the repo, with when to read it. New here, or just pulled? Read these in order:
[`TEAM_HANDOFF.md`](TEAM_HANDOFF.md), the root [`README.md`](../README.md), then
[`AGENTS.md`](../AGENTS.md), then [`ios/README.md`](../ios/README.md). Open [`CODE_REFERENCE.md`](CODE_REFERENCE.md) when you need
a specific file or function.

**Precedence:** when documents disagree with each other, `AGENTS.md` wins over
`docs/CODE_REFERENCE.md`. When any document disagrees with the shipped code, the code wins and the
doc gets fixed in the same commit. For design tokens, `docs/design.md` is the
spec: when it and `Theme.swift` / `WatchTheme.swift` disagree, fix the Swift. The exception is
screen layout and button labels, where the shipped code (and the tests that pin it) is what's real.

## Every doc

### Repo root

| Doc | Read it when |
|---|---|
| [`README.md`](../README.md) | You want the pitch, the demo, the hardware list, the repo map and the quick start. |
| [`AGENTS.md`](../AGENTS.md) | **Before your first edit, human or AI.** It has the hard rules (concurrency, iOS 26 APIs only, logic lives in `ios/Logic`, secrets, frozen bundle IDs, audio session, cue priorities, accessibility-label contract, per-commit gate) and the "looks wrong but is deliberate" list. It wins every conflict. |
| [`CLAUDE.md`](../CLAUDE.md) | You are Claude Code. It is the short version of `AGENTS.md`, loaded automatically. |
| [`CHANGELOG.md`](../CHANGELOG.md) | You need to know what landed in each build step and its "test on device" list. |

### iOS app

| Doc | Read it when |
|---|---|
| [`ios/README.md`](../ios/README.md) | You are setting up a Mac, building, signing, installing or testing. It has the day-0 checklist, the Apple spec deviations you must not "fix" (§2, cited by `AGENTS.md` rule 7), every `make` target, secrets, the test layers and the depth-map gotchas. |
| [`ios/drafts/README.md`](../ios/drafts/README.md) | Rarely. It explains the old iOS 18 starter files, which are not part of any target. |

### `docs/`

| Doc | Read it when |
|---|---|
| [`docs/TEAM_BRIEF.md`](TEAM_BRIEF.md) | **The 2-minute version** for Sagar and Aarav: state, their tasks, the mount's four requirements, install steps, known quirks. |
| [`docs/TEAM_HANDOFF.md`](TEAM_HANDOFF.md) | **First, after every pull.** What is proven vs not, who does what next, the mount angle, the default settings and why, the decisions that are final, the Street View mock, known risks. |
| [`docs/CODE_REFERENCE.md`](CODE_REFERENCE.md) | You need to find or change code. It maps every file, type and function by module, with the data-flow diagram and the ⚠ invariants that tests pin. **Update the module's section in the same commit as the code change.** |
| [`docs/handsfree.md`](handsfree.md) | **You are the walker, or setting the phone up for one.** Every spoken command, what the status answer means, the exact Settings path for the Action button (and why a locked phone asks to unlock first), what the AirPods stem and Back Tap cannot do, and what still needs the screen. |
| [`docs/devices_setup.md`](devices_setup.md) | Before touching the AirPods or the Apple Watch, and before the untethered demo: pairing, Spatial Audio off, the watch app, the voice cache, Guided Access and a symptom → fix table. |
| [`docs/design.md`](design.md) | You are changing UI, colours or type, or how a cue feels, sounds or shows. §5 maps every cue to its haptic, speech and screen output. §6 describes the shipped three-tab layout (Guide / Sense / Settings) and records the original fourth-tab proposal as not built. |
| [`docs/route_isr_cif.md`](route_isr_cif.md) | You are editing `route_isr_cif.json` or re-recording the route on foot. It covers the evidence for every waypoint, OSM node IDs, and which points are still unverified. |
| [`docs/todo.md`](todo.md) | You want to know what is still open. This is the strict build checklist; tick it in the same commit. |
| [`docs/stress_test_plan.md`](stress_test_plan.md) | You are planning device and field tests: the next-24-hours schedule, bench tests D1–D18, failure injection F1–F12, the go/no-go checklist and the demo run sheet. |
| [`docs/ideas.md`](ideas.md) | You want the reasoning: the verdict, the pushbacks, the pitch script, prior art and the numbers. **§9 is the current decision (phone-only, buy nothing).** §3–4 (ESP32 grip, buy list) are history. |

### Hardware

| Doc | Read it when |
|---|---|
| [`hardware/README.md`](../hardware/README.md) | You are working on the physical kit (Sagar): files, quick start, bill of materials. |
| [`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md) | You are printing or changing the phone mount that clamps the iPhone to the 28.75 mm shaft: Apple dimensions, the camera-tilt derivation (3–8° down), concepts, print settings, assembly, test protocol T0–T11. |
| [`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md) | You want to test the camera features against Google Street View frames of the route (local-only JPEGs). |
| [`cad/README.md`](../cad/README.md) | Stretch goal only. It covers the OpenSCAD drafts for the ESP32 grip and sensor pod, which are not part of the phone-only demo. |
| [`firmware/README.md`](../firmware/README.md) | Stretch goal only. It covers the ESP32 BLE grip firmware, which is not used for the hackathon. |

### Outside `docs/`

| Where | What |
|---|---|
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | CI. It is **manual-trigger only** (Actions tab → CI → Run workflow) because the account's GitHub Actions billing is exhausted. The local `make` gate is authoritative. |
| `~/.claude/plans/phone-is-king-glittery-bee.md` | The approved build plan, on Aritro's Mac only (it is not in the repo). |

## Where do I find…

| I need… | Look here |
|---|---|
| **Build / run commands** | [`ios/README.md` §3](../ios/README.md#3-build-install-launch) (table of every `make` target) and the header of `ios/Makefile`. Run everything from `ios/`. |
| **Signing setup (team, device)** | `ios/local.mk`, which is git-ignored and holds `TEAM = …` and `DEVICE = …`. See [`ios/README.md` §1](../ios/README.md#1-day-0-checklist). |
| **The route file** | `ios/CaneKit/Resources/route_isr_cif.json` (9 waypoints, 989 m). Evidence is in [`route_isr_cif.md`](route_isr_cif.md). The schema is `ios/Logic/Sources/CaneKitLogic/Waypoint.swift`. Other destinations use MapKit via `ios/CaneKit/Navigation/RouteSource.swift`. |
| **Navigation rules (fences, veer, arrival, turn settling)** | `ios/Logic/Sources/CaneKitLogic/GeoMath.swift` (`GeofenceTracker`, `OffCourseDetector`) and `NavSupport.swift` (`TurnSettle`, `StraightWalkDetector`). The engine is `ios/CaneKit/Navigation/NavigationEngine.swift`. The reasons are in `AGENTS.md` → "Things that look wrong but are deliberate". |
| **Speech rules (priorities, interruption, Repeat)** | `AGENTS.md` rule 8 and its deliberate-behaviour list. The code is `ios/CaneKit/Speech/SpeechQueue.swift`, `CueSpeechPolicy` in `NavSupport.swift`, and `ElevenLabsVoice.swift` (natural voice + cache). The cue table is [`design.md` §5](design.md#5-cue-mapping-every-cue--felt-heard-shown). |
| **Haptic patterns** | Phone: `ios/CaneKit/Haptics/HapticPlayer.swift` (obstacles: left 2 taps, right 3, head sharp double, Geiger loop; route: long soft buzzes, left 1, right 2, crossing 3, arrived long-short-long; ground hazard: 4 heavy taps). *When* a cue fires: `CueDecider.swift` + `GeigerRate` in `ios/Logic`. Wrist: the `WKHapticType` map in `ios/CaneKitWatch/WatchModel.swift`. |
| **Watch messages (phone ↔ watch)** | The wire contract is `ios/Logic/Sources/CaneKitLogic/WatchMessage.swift` (JSON under key `"m"`, tested in `WatchMessageTests.swift`). The phone side is `ios/CaneKit/Watch/PhoneWatchLink.swift` and the watch side is `ios/CaneKitWatch/WatchModel.swift`. |
| **Secrets / API keys** | The template is `ios/Secrets.example.plist`. Real keys go only in `ios/CaneKit/Resources/Secrets.plist`, which is git-ignored: never commit or print it. The reader is `ios/CaneKit/Scene/Secrets.swift`. The key list is in [`ios/README.md` §4](../ios/README.md#4-secrets-and-permissions). |
| **Testing** | See [`ios/README.md` §5](../ios/README.md#5-testing). Logic tests are in `ios/Logic/Tests/CaneKitLogicTests/` (`make test`, 372 current `@Test` annotations). UI tests and the screenshot tour are in `ios/CaneKitUITests/` (`make uitest`, `make tour`). GPS-replay end-to-end runs through `ios/scripts/e2e.py` (`make e2e`). |
| **Accessibility labels the tests depend on** | `AGENTS.md` rule 9 lists them. The details are in `CODE_REFERENCE.md` → module `ui-tests-build`. |
| **UI tokens and components** | `ios/CaneKit/UI/Theme.swift` (`CKColor`, `CKFont`, `CKBigButton`, …) and `ios/CaneKitWatch/WatchTheme.swift`. The spec is [`design.md`](design.md), which wins on token values. |
| **Trip log (what happened on a walk)** | `ios/CaneKit/Trip/TripLogger.swift` writes `canekit-<stamp>.jsonl` to the app's Documents folder, which you can reach from the Files app or AirDrop. |
| **Project / targets / Info.plist / entitlements** | `ios/project.yml` (XcodeGen). Regenerate with `make gen`. Never hand-edit `CaneKit.xcodeproj`. |
| **The knowledge graph** | `graphify-out/` at the repo root (`GRAPH_REPORT.md` lists the communities; `graph.html` opens in a browser). Ask it questions from the repo root with `graphify query "<question>"`, `graphify path "A" "B"` or `graphify explain "X"`. After code changes, refresh it with `graphify update .` (code only) or `/graphify . --update` in Claude Code. Install once with `uv tool install graphifyy` (or `pipx install graphifyy`). |
| **Hazards (drop-offs, signs, hazard watch, hazard map)** | Decisions: `ios/Logic/Sources/CaneKitLogic/Hazards.swift` (tested in `HazardTests.swift`). App side: `ios/CaneKit/Depth/GroundSampler.swift`, `ios/CaneKit/Scene/HazardScanner.swift`, `OnDeviceVision.swift`, `ios/CaneKit/Trip/HazardLog.swift`, `ios/CaneKit/UI/HazardsCard.swift`. |
| **Mount angle** | `MountTilt` in `ios/Logic/Sources/CaneKitLogic/LaneReport.swift`; live on the Mount card; derivation in `hardware/mount/DESIGN.md`. |
| **Street View mock** | `ios/CaneKit/Depth/FrameReplay.swift`, `ios/scripts/streetview/`, `ios/scripts/vision_probe.swift`, `make uitest-streetview`, `make e2e SCENARIO=streetview`. |
| **What's left to do** | [`todo.md`](todo.md). The latest `CHANGELOG.md` entry (Step 28) lists the sound-recognition and camera-interlock device checks; older step entries retain their historical test notes. |
