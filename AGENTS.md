# AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit

Read this before touching the repo. `docs/CODE_REFERENCE.md` is the map of every file, type and
function; `CHANGELOG.md` is the build log; `docs/todo.md` is the strict checklist;
`docs/devices_setup.md` is the AirPods + Apple Watch checklist; `docs/TEAM_HANDOFF.md` §10 is where
an agent resumes the open work. When you change code, update its module section in
`docs/CODE_REFERENCE.md` in the same commit — agents rely on it being true. When this file and the
shipped code disagree, the code is the truth: fix this file (and say so in `CHANGELOG.md`).

## What this is

OpenCane is a native iOS 26 app (Swift 6, SwiftUI, no third-party packages) that guides a blind cane
user along GPS waypoints and warns about waist-to-head obstacles. The **phone is the only computer**:
an iPhone 17 Pro Max (iOS 27) clamped to a non-metal cane shaft — for the prototype a 27.65 mm broom
handle, measured by the bore-ring coupons (CHANGELOG hardware "Step 21 — The bore rings were printed"; the old 28.75 figure is retired) —
plus AirPods Pro (beacon + speech + head yaw) and an Apple Watch (wrist taps, Repeat / Next / Describe / Recenter). No ESP32, no
external sensors. The demo route is ISR Townsend Hall → CIF on the UIUC campus
(`ios/CaneKit/Resources/route_isr_cif.json`), but any destination works via MapKit walking directions.
For the demo everything runs **untethered on the phone**; the Mac only signs and installs.

## The name split — OpenCane to a human, CaneKit in the code (deliberate, do not "fix")

Added 2026-09-11. The two names are **not** a half-finished rename; keeping them apart is the point.

| | Name | Where it is set |
|---|---|---|
| What a person **sees and hears** | **OpenCane** | `CFBundleDisplayName` on all three targets (`ios/project.yml` → `make gen`); the nav title on the Guide tab in `ContentView` (Sense / Settings / Profile carry their own titles "Details" / "Settings" / "Profile"); the watch nav title; every spoken line (`AppModel`, `SoundWatcher`, `AppIntents`); the `NS*UsageDescription` purpose strings; the Siri App Shortcut phrases, which interpolate `\(.applicationName)` and therefore follow the display name with no edit |
| What the **code** is called | **CaneKit** | Xcode project and `CaneKit.xcodeproj`, target names, scheme, `PRODUCT_NAME` (so the build product is `CaneKit.app`), the `CaneKitLogic` SwiftPM module, every `ios/CaneKit…/` path and file name, `Makefile` targets, the `CANEKIT_*` environment variables, the `canekit-*.jsonl` trip-log filenames |
| Frozen either way | `com.aritro.canekit`, `.watchkitapp`, `.widget` | hard rule 6 |

Why the code keeps the old name:

- **The bundle id must not move.** iOS keys the installed app, its permission grants, its
  `UserDefaults`, its Documents folder (trip logs, hazard GeoJSON) and the ElevenLabs mp3 voice
  cache off the bundle id. A new id installs a *second* app beside the old one, orphans all of it,
  and burns another of the 10 App IDs a free personal team gets per week.
- **`PRODUCT_NAME` names the build product.** `CaneKit.app` is referenced by `ios/Makefile`,
  `ios/scripts/gen.sh` and `ios/scripts/e2e.py`.
- **Renaming targets, the module and the paths buys nothing a user can see** and would touch
  hundreds of files, `docs/CODE_REFERENCE.md` and every XCUITest, for a rename with no user-visible
  effect.

So: when you add a **spoken or visible** string, say OpenCane. When you touch a type, file, module,
target, path, scheme or bundle id, it is CaneKit. Two traps worth knowing:

1. ⚠ `AppModel.commonLines` prefetches the ElevenLabs audio for fixed spoken lines and matches them
   **by bytes**. "OpenCane ready." appears both there and at the `speech.say` in `AppModel.start()`;
   change one without the other and that line silently falls back to Apple's system voice.
2. ⚠ Changing `CFBundleDisplayName` changes **what the walker must say to Siri**: the phrase is
   "… in OpenCane" now, not "… in CaneKit". `docs/design.md` §6.3 and `docs/handsfree.md` list the current phrases.

## Layout

| Path | What lives there |
|---|---|
| `ios/Logic/` | `CaneKitLogic` SwiftPM package: pure, Foundation-only decisions (lane math, cue state machine, geofences, route schema, watch message codec, VLM request/response codec) + Swift Testing tests |
| `ios/CaneKit/` | The iOS app: `App/` (AppModel = owner of every engine), `Depth/`, `Haptics/`, `Speech/`, `Watch/`, `Navigation/`, `Audio/`, `Scene/`, `Conversation/` (voice assistant: `ConversationCoordinator`, `VoiceInputEngine`, `PostStore`), `Alerts/` (family alerts, Steps 39/43: `FamilyAlerts`, `GrokBotClient`, `FallWatcher`, `AlertSummarizer`), `Trip/` (trip log + tracker, `LiveActivityController`, `MedicalProfileStore` (Step 44), `SupabaseClient` (Step 45)), `UI/` (incl. `ProfilePage`, the 4th tab), `Resources/` |
| `ios/CaneKitWatch/` | watchOS app |
| `ios/CaneKitWidget/` | Live Activity widget (Dynamic Island / lock screen) |
| `ios/Shared/` | Types compiled into more than one target (Live Activity attributes) |
| `ios/CaneKitUITests/` | XCUITests + the screenshot tour (`CaneKitVisualTour`, `make tour`) + the Dynamic Island tour (`CaneKitIslandTour`, `make island`) |
| `ios/project.yml`, `ios/scripts/gen.sh`, `ios/Makefile` | XcodeGen project + CLI build/test/install |
| `ios/scripts/` | `test.sh` (`make test`), `e2e.py` (`make e2e`, asserts on the trip log), `cue_audit.py` (`make audit`, cue load of one walk), `sign_probe.swift` / `vision_probe.swift` (measure what Vision reads), `streetview/` (`frames.json` + git-ignored JPEGs for `SCENARIO=streetview`), `streetview_stim.py` (run by hand: a demo / dataset visualiser over the Street View frames with its own nav approximation and template narration — runs no CaneKit code, no Makefile target, no tests), `appicon.py`, `gen.sh` |
| `ios/stretch/`, `ios/drafts/` | Not in any target. Old ESP32 BLE code and iOS 18 drafts. Leave alone. |
| `docs/` | `README.md` (index of every doc), `CODE_REFERENCE.md`, `design.md` (UI/cue design system), `cue_design_v2.md` (cue research, Step 35), `auditory-load.md` (speech-load research, Step 30), `handsfree.md` (Siri / Action Button use), `route_isr_cif.md` (route evidence), `stress_test_plan.md`, `devices_setup.md`, `todo.md`, `ideas.md` (history), `TEAM_BRIEF.md` / `TEAM_HANDOFF.md` (dated status snapshots), `superpowers/` (speech-load plan + spec) |
| `hardware/mount/` | Phone-to-cane mount, screwed: design brief + parametric OpenSCAD (Sagar) |
| `hardware/mount_screwless/` | Same job, **zero bought hardware**: collet clamp + dovetail modularity. `PRINTING.md` is the operator runbook — read it before sending anything to a printer (Sagar) |
| `hardware/3d_print_files/` | What to print: sliced `gcode/` (Creality SPARKX i7) and `stl/` for the screwless mount |
| `hardware/cane_tip/` | `ball_tip.scad`, a printed rolling ball tip (sized for the 27.65 mm prototype shaft) |
| `scripts/` (repo root) | Windows mount pipeline: `verify_mount.ps1` (model checks), `build_stl.ps1` (renders), `slice_gcode.ps1` (slices headlessly), `stl_tools.js` (volume / shells / overhang measurements) |
| `cad/`, `firmware/` | Legacy ESP32-era grip drafts and BLE grip firmware. Not part of the phone-only build; do not print or flash for the demo |
| `.github/workflows/ci.yml` | CI, **manual trigger only** (Actions billing exhausted); the local `make` gate is authoritative |
| `graphify-out/` | Knowledge graph of the repo: `graphify query "<question>"`, `GRAPH_REPORT.md`, `graph.html` |

## Hard rules

1. **Swift 6 strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`.** Everything is main-actor
   unless marked `nonisolated`. Framework delegates (ARSession, WCSession, AVSpeechSynthesizer,
   AVAudioPlayer, HKWorkoutSession, CMHeadphoneMotionManager) are `nonisolated` relay classes that
   extract Sendable values and hop with `Task { @MainActor in … }`. `MainActor.assumeIsolated` only
   inside closures provably on main (`NotificationCenter … queue: .main`, `CMMotionManager … to: .main`).
   Never add `@unchecked Sendable` to a main-actor class to silence the compiler.
2. **iOS 26 / watchOS 26 APIs only.** The phone runs iOS 27 but the deployment target is 26; no iOS 27-only
   API. No third-party packages, ever.
3. **Decisions go in `ios/Logic`, effects go in the app.** If a rule has a number in it (metres, seconds,
   degrees, Hz) it belongs in `CaneKitLogic` with a test. `NavigationEngine`, `SpeechQueue`, `HapticPlayer`
   are thin owners of state + timing around those pure types.
4. **Secrets never enter git.** Keys live only in `ios/CaneKit/Resources/Secrets.plist` (git-ignored;
   `ios/Secrets.example.plist` is the template). `Secrets` returns nil for missing keys and the app
   speaks a graceful line; it must never crash without a key.
5. **`CaneKit.xcodeproj` is generated and git-ignored.** Edit `ios/project.yml`, then run
   `ios/scripts/gen.sh` (it also applies the XcodeGen watch-embed patch and, only when
   `Secrets.plist` is missing, creates it from the example — it never overwrites real keys). Never
   hand-edit the pbxproj, never regenerate unless `project.yml` or the file list changed.
6. **Bundle IDs are frozen**: `com.aritro.canekit`, `.watchkitapp`, `.widget` (free personal team, 10
   App IDs per week).
7. **Audio session is one `.playback` session**, mode `.default`, `[.duckOthers]`, no Bluetooth options
   (HFP drops AirPods to phone-call quality). `CHHapticEngine(audioSession: nil)`. `.HRTF`, mono click.
   Do not "fix" the deviations listed in `ios/README.md §2` back to the original spec.
   One exception exists: an audio *input*, for "Listen for sirens and horns" (off by default, owner
   `.soundRecognition`) or push-to-talk "Talk to OpenCane" (one utterance, owner `.voiceInput`).
   `SpeechQueue.setMicrophoneEnabled(_:owner:)` moves the session to `.playAndRecord` with
   `[.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker]` — never `.allowBluetoothHFP` — and reverts to
   `.playback` the moment the **output** route changes at all, refusing the feature instead. No other
   shipping code may call `setCategory` (the only other call is the debug `SensorProbe`, which runs only
   under `CANEKIT_SENSOR_PROBE=1` / `--sensor-probe` and restores `.playback`).
8. **Cue priorities** (speech, `SpeechPriority`): `.scene` (Where am I, answers, flashlight lines) <
   `.obstacle` (obstacle names, signs, hazard watch) < `.nav` (route lines, refusals) < `.safety`
   ("Head height.", LiDAR ground hazards). The `.head` haptic is never suppressed; its spoken line is
   once per episode (`CueSpeechPolicy`). A line cut by a higher band is re-queued and resumes from the
   clause it was cut in (`SpeechResume`, Step 37 — never restarted from the first word after a warning);
   lines of different bands are separated by a 0.35 s pause that a safety line never waits for. Keep
   `docs/design.md §5.1` and `SpeechQueue` in sync.
9. **Accessibility labels are a test contract.** The strings in `CaneKitUITests` (Start route to CIF,
   Navigate to CIF from here, Stop route, Repeat, Next, Recenter, Where am I, Go, Test
   left/center/right/head haptic, Silence haptics, Mirror left / right, Write trip log, Head row,
   Type a destination first, Destination, Simulate walk (`CaneKitIslandTour`), the root tabs Guide / Sense /
   Settings / Profile (`RootTab.title`; the tests drive the first three), the Cues picker
   segments Quiet / Standard / Detailed / Indoors / Outdoors (`CueLevel.title` / `CuePlace.title`), and a campus
   suggestion's label "Grainger Engineering Library, campus place" —
   `DestinationSuggestion.voiceOverLabel`) must not change without updating the tests in the same
   commit.
10. **Every commit**: `cd ios && make test` green (Logic), `make sim` green, and for UI changes
    `make uitest` + `make tour` on the **iPhone 17 Pro Max / iOS 27** simulator (`make sim17` creates
    it once). Run the Muse review (`muse exec`, read-only, from a scratch dir) on the diff. Commit message
    ends with a one-line `test on device: …` note. Add a `CHANGELOG.md` entry and tick `docs/todo.md`.

## How we engineer (the bar for every change, human or AI)

This is how CaneKit was built, and it is the standard for anyone who touches it. A blind person
walks on this code; "it compiled" is not done.

1. **Evidence before claims.** Never say something works, is fixed or is safe without a command
   whose output proves it (test run, build log, e2e report, harness numbers, trip log). Measure
   before assuming: the sign-reading range, the curb-warning distance and the false-veer count all
   came from a probe or a simulation, not a guess. When you cannot verify something, say so.
2. **Test first for every rule with a number in it.** The decision goes in `ios/Logic` (pure, no
   UIKit/ARKit) with a Swift Testing test written *before* or *with* the fix, ideally from real
   data (the SceneVocabulary tests use the labels Vision returned on the route; the veer fix was
   proven by a harness that runs the real NavigationEngine over 72 simulated walks). A bug fix
   starts with a failing test that reproduces it.
3. **Adversarial review, several independent reviewers, every round.** After each chunk of work:
   a multi-agent review (finders + skeptics who try to refute each finding; Steps 34 and 36 ran 31- and
   35-agent workflows, Step 37 a 4-lens workflow with a verifier per finding), **plus Muse** (`muse exec --prompt-file <file> --provider meta
   --reasoning-effort high --workspace <scratch>`, run from the scratch dir, "do not edit files") **plus
   Antigravity** (`agy -p …`, pointed at a *copy* of the repo — it has edited files despite a read-only
   prompt). Review the *plan* with Muse too before building a large or risky change (Step 37's first
   plan was rejected there). Keep review prompts small
   and focused on the diff; broad prompts time out. Then **verify every finding yourself** before
   acting: fix what is real, and reject what is not *with evidence* in `CHANGELOG.md` (e.g. the
   "swap max/min" proposal that would have reverted the mid-bin curb fix).
4. **Verify end to end, silently.** `make test`, `make sim`, `make uitest`, `make e2e` (and
   `SCENARIO=streetview` when the camera path changed) on the iPhone 17 Pro Max simulator. All
   automation runs muted (`CANEKIT_MUTE=1` / `CANEKIT_UITEST=1`); never make noise on the Mac.
5. **Make the invisible visible.** If a test cannot see why something passed, it is not a test:
   log what the system saw, not only what it said (`scan`, `hazard_watch`, `describe_result`,
   `tilt`, `fps` in the trip log). A green e2e with no evidence of the camera path was a failure.
6. **Safety beats features.** Anything new and untuned on the real cane ships **off by default**
   (drop-offs, hazard watch). Never trade guidance away for a stricter check (a refused camera
   warns loudly but still guides). Never speak something the sensors did not see (model
   sentences must pass `SceneVocabulary.isFaithful`).
7. **Document in the same commit.** Every file has a header, every type and function a doc
   comment that says what, why, who calls it and what pins it (⚠ lines name the tests). Update
   `docs/CODE_REFERENCE.md`, `CHANGELOG.md` (with a "test on device" line) and `docs/todo.md` with
   the code. Refresh the knowledge graph (`graphify update .`). The code wins over any doc; fix the doc.
8. **Small, reviewable steps, strict to-do lists.** Write the plan as a checklist, tick it as you
   go, commit per step with a message that ends in `test on device: …`.

## Commands

```sh
cd ios
make test            # CaneKitLogic unit tests (Swift Testing; works with Command Line Tools alone)
make sim             # build the app for the iOS simulator (no LiDAR / haptics / watch there)
make uitest          # XCUITests on the iPhone 17 Pro Max simulator
make tour            # screenshot every screen state → ios/build/shots
make island          # photograph the Live Activity in the Dynamic Island (compact, expanded, walking,
                     #   after Stop) → ios/build/shots/NN-island-*.png (CaneKitIslandTour, Step 47)
make sim17           # create the iPhone 17 Pro Max (iOS 27) simulator once
make e2e             # GPS-replay end-to-end scenarios through the real app (SCENARIO=all = clean, missed_fence,
                     #   gps_jitter, wrong_turn; streetview is opt-in); report + logs in ios/build/e2e/
make audit           # cue load of one walk: cue_audit.py --selftest, then LOG=path or --pull the newest
                     #   trip log off the phone in local.mk (read-only, no simulator)
make gen             # regenerate CaneKit.xcodeproj (only when project.yml or the file list changed)
make devices         # find DEVICE for ios/local.mk
make run             # gen + build + install + launch on the phone (needs TEAM/DEVICE in ios/local.mk)
```
Simulator GPS replay: launch with `SIMCTL_CHILD_CANEKIT_DEMO_ROUTE=1` and feed
`xcrun simctl location <udid> start --speed=4 --interval=1 <lat,lon> …`; read the JSONL trip log in the
app container's Documents folder.

Traps that have already cost a run (the first two produced a false green in Step 27):

- ⚠ **Never verify a command through `tail`.** `make test | tail -8` printed a passing test summary
  and reported exit 0 while the build was failing — the exit status was `tail`'s, and the errors were
  at the *head* of the log. Redirect to a file, check the command's own exit code, then grep `error:`.
- ⚠ **`#expect` cannot call a `mutating` member.** The macro expands its argument into a closure that
  captures the value immutably, so `#expect(continuity.accepts(11))` fails to compile
  ("cannot use mutating member on immutable value: '$0' is immutable"). `#expect(d.update(…) == v)` is
  fine — a comparison expands differently. Hoist the call into a local first (`DepthReadinessTests`).
- ⚠ **"Operation not permitted" from swift-frontend / xcodebuild / git on files under the repo is
  macOS, not the code.** The repo lives in `~/Downloads`, a folder guarded by Privacy & Security →
  Files and Folders. On Sat 2026-09-12 ~21:30 Xcode's grant for the Downloads folder was lost (a
  prompt raised by concurrent agent builds went unanswered): Xcode-signed tools (`swift-frontend`,
  `xcodebuild`, `/usr/bin/git` → Xcode's git) could no longer open files they had not created
  themselves — incremental builds failed on their own `.swiftmodule` / `.swiftdeps`, `swift test`
  could not load the xctest bundle, and `git status` said "unable to access '.git/config'" while
  `head .git/config` worked. Fix: `tccutil reset SystemPolicyDownloadsFolder com.apple.dt.Xcode`
  (then Allow), or System Settings → Privacy & Security → Files and Folders → Xcode → Downloads.
  Workaround meanwhile: `make sim DERIVED=/private/tmp/…/dd` (a derived-data dir outside Downloads).
- ⚠ **Never run two builders in the same tree.** The same evening a Codex review ran `make test` /
  `make sim` in the real repo (48 times) while the gate ran. Point external reviewers (Codex,
  Antigravity) at a *copy* with a read-only sandbox, and give subagents their own `-derivedDataPath`.
- ⚠ `scripts/test.sh` passes `--disable-xctest`: on a fresh `Logic/.build` under Xcode 27, `swift test`
  passes all Swift Testing suites and then fails "No test bundle found" in the (empty) XCTest pass.
  Add an XCTest test and you must remove the flag on purpose.
- ⚠ `make uitest` / `make tour` / `make island` need a location on the simulator first
  (`xcrun simctl location <udid> set 40.1140,-88.2249`), or the route tests fail for want of a GPS fix.

## Hardware / OpenSCAD — traps that have already cost us a night

Everything here was paid for with a real mistake on 2026-09-12. Read it before touching a `.scad`.

**Never trust an exit code or `Status: NoError`.** OpenSCAD exits **non-zero for EMPTY geometry**,
which at the shell is indistinguishable from a failed `assert()`. It also exits **zero, reporting
`NoError`, while exporting disconnected floating solids**. A sweep script that reads exit codes will
report empty results as failures and failures as successes — that happened twice in one evening, in
opposite directions. Always: check the STL exists, has positive volume, and parse stdout for `ssert`.

**Count connected components on every export.** A part that exports as N>1 solids has a floating
piece that prints as loose debris. The cradle shipped for days as 2 components with its phone latch
severed. `stl/` artefacts and slicer previews both hide this. Make component count a pass/fail on
every part, not an occasional check.

**`circle(r)` is an inscribed polygon.** Its true radius dips ~0.010 mm below `r` between facets
(sagitta at `$fa=4`). Geometry placed inside that dip produces zero-volume sheets that still report
`NoError` — the ring exported 20 of them until `thr_sink = 0.05` pushed the root arc clear.

**`linear_extrude(twist=)` maps ANGLE to height, not distance.** A thread tooth must be drawn as an
angular SECTOR. Related and separate: interpolate a thread flank in **polar** space. A straight
Cartesian chord from the crest corner to the root corner passes *inside* `circle(minor)` whenever the
root half-angle is large, and `union()` silently swallows the outer half of every tooth. Ours was
0.738 mm where `thr_duty` asked for 1.500.

**A twisted extrude's facet error is radial, not just axial.** At 24 slices/turn the twist is 15° per
slice, so the crest's true radius dips `r·(1−cos 7.5°)` = **0.156 mm** — 78% of a layer, taken
straight off the thread's engagement diameter. Reasoning only about axial error will miss this.

**Sweep the parameter, do not trust the comment.** Several parameters here turned out to be *inert*
or *inverted* — moving geometry opposite to what their comment claimed. `dt_stand` is documented as
buying clearance and makes interference monotonically worse. If a comment states a measured number,
re-measure it: a large fraction of ours were stale or from a different configuration.

**An `assert()` must guard the feature that actually fails first.** `assert(pad_t > dt_depth)` guards
the socket, but the pawl window breaches the bore 0.8 mm sooner. `assert(arm_t >= dt_wide)` guards the
fin root, and did not notice when a taper at the *far end* cut bed contact to 0.30 mm. Assert on the
measured quantity, and make the message describe the same limit the expression tests.

**Print orientation is part of the model, not a slicer decision.** Lay every exported part flat on
z = 0 in the orientation it must print in. Check **first-layer area** (volume of a 0.2 mm slab at
z-min ÷ 0.2): a symmetric taper about the build axis rests on a *line*. Healthy parts here are
450–820 mm²; the arm regressed to 0.30 mm² and nobody noticed because it still rendered fine.

**Coupons must bracket, not sample.** A single-value fit coupon can only ever say "too tight" or
"too loose", never how much — one nut at `[0.35, 0.25]` jammed and taught us nothing. Give every fit
test at least three values, and when a symptom implicates two different axes (radial vs axial
clearance), step them **separately** so the result is diagnostic.

**The header table is the part of a coupon file a human actually reads**, with parts in hand and a
paint pen. It has now been wrong twice — once for the bore rings, once for the thread nuts — both
times because the array changed and the comment did not. If you edit a `*_tests` array, edit its table
in the same keystroke. A fitter who records the wrong number poisons a parameter permanently.

**Re-render and re-measure after every layout change.** Wrapping a coupon row to fit the bed pushed it
into another row; the plate rendered as 14 solids instead of 16 and the merge was completely silent.

**"Unknown, need to measure" is the correct answer** and outranks a plausible number. A value the
bench has *disproved* must never sit in the file as though it were settled — mark it a placeholder.

## Things that look wrong but are deliberate

- Fences fire up to `radius_m` before the corner. `TurnSettle` (Logic) holds the previous leg's bearing
  and mutes veer cues until the turn is made: within 6 m of the corner, or receding max(6 m, radius/2)
  on two consecutive good moving fixes (+4 s grace), or the body heading within 30° of the new leg, or
  25 s of *moving* time. At a crossing the beacon is silent while settling ("Listen for traffic") and two
  stationary fixes (the curb) release it. A fixed timer here caused spurious "Veer" cues.
- `GeofenceTracker` looks ahead two waypoints and detects passed-by (1 m jitter tolerance). Near the
  current waypoint (2 × radius) the target bearing is the recorded leg bearing and veer cues are muted.
  Arrival needs `distance + accuracy/2 ≤ radius` on two consecutive fixes (no speed gate) — arrival is
  irreversible. Intermediate fences need ≤ 20 m and > 0.5 m/s; "GPS weak" is spoken at the same 20 m.
- Passed-by never speaks the passed waypoint's own line (its "turn right…" would be wrong by then):
  it says "Passed <place>. <next place> in N meters." Skip-ahead says "Passed one waypoint." + the real line.
- `"curved": true` on a waypoint (WP1) = the next leg is not straight: no veer, beacon silent.
- Repeat speaks the last line actually spoken (not the upcoming waypoint) and bypasses queue coalescing.
- Auto-recenter of the AirPods head reference: `StraightWalkDetector` (3 fixes > 0.6 m/s, steady
  course, still head), never within 15 m of a crossing, never on a timer. Until it happens the beacon
  ignores head yaw (the old reference would double-count the body turn).
- The beacon only plays into headphones (`AudioRouteMonitor`); connect/disconnect is spoken.
- Silencing haptics routes obstacle cues to the watch and to speech. "Head height." is spoken once per
  obstacle episode (≥ 4 s apart), never every second. Warnings never wait for the ElevenLabs network.
- An interrupted speech line resumes at most 3 times (`SpeechResume.maxResumes`), never from an
  earlier point than last time, then is dropped (Repeat recovers it). Its TTL is extended to ≥ 8 s
  on the *first* cut only, so a line cut again and again still goes stale. Lines said during a
  call / Siri queue and drain on `.ended` (15 s fallback). Steps 34–37 below have more speech rules.
- Watch crown "Next" = 3 detents within 1 s of the first. `.failure` haptic is reserved for head-height;
  send failure and "phone app too old" use `.retry`.
- The route file's WP3 (Goodwin) is a turn, not a crossing; turn waypoints use 12 m fences.
- `SpeechQueue` has a watchdog (6 s + text length / 6) that unsticks a stalled backend.
- Location permission is requested at launch (with a sighted helper present; skipped under
  `CANEKIT_UITEST=1`); Motion and HealthKit at route start.

- Hazards the maps do not know about (Step 11): LiDAR ground hazards (drop-off / hole / curb /
  low obstacle) need a near-field ground reference, an edge jump against the previous *two* 30 cm
  bins (a curb face mid-bin splits its jump), and 3 of 5 frames agreeing on the hazard's position in
  the world (distance + metres walked). Comparing with the previous *two* bins means ramps steeper
  than ~11 % (7 cm over 60 cm) can read as a drop-off or step; ≤ 10 % (ADA ramps are ≤ 8.3 %) stay
  silent (tested). Do not swap `max`/`min` there: that reverts to adjacent-bin only and a curb face
  landing mid-bin is missed again (Antigravity round 6 proposed it; rejected with the tests). The ground path has its own looser gyro gate (1.5 rad/s, raw
  depth, ≤ 10 Hz) because a 1 Hz sweep leaves too few 0.6 rad/s frames to warn before the cane tip
  gets there. A rise in the last scan bin is not classified yet (step vs low obstacle is a guess).
  Drops need their lower ground visible within the 3.5 m scan: a long flight of stairs down or a
  ledge deeper than ~0.6 m is **not detected** (occlusion); the cane tip and the walker's own
  caution cover those. A deep drop is reported at the end of the last visible ground.
  Spoken at `.safety` with 4 heavy cane taps; the same hazard (same kind, within 1 m) is repeated
  only when 1 m closer or after 30 s, so standing at a curb does not nag. **Off by default**
  ("Detect drop-offs") until tuned on the real cane. Signs are read on-device every 3 s, text down to
  1/128 of the frame height (7.5 cm letters from ≈ 7 m, measured by `ios/scripts/sign_probe.swift`),
  and each phrase, with every phrase inside it, is spoken at most once a minute. "STOP" is
  deliberately not a phrase (a STOP sign faces drivers and would be read at every corner). The hazard watch (**off by default**) asks the vision model every 8 s only while
  walking a route; the cloud gets 2.5 s, then on-device answers; a reply older than ~4 m of walking
  is dropped and one older than 2 s loses its distance; "NONE" is silent. Every announced hazard is
  written to Documents/hazards/*.geojson with GPS (the nav engine's last fix after arrival; null
  geometry with no fix) + photo.
- The lane grid has no gravity correction (a fixed bottom `groundSkipFraction` is ground), so the
  mount must aim the camera 3–8° below the horizon (`MountTilt`; hardware/mount/DESIGN.md). The
  Mount card shows the live tilt and fps; do not "fix" a buzzing-on-empty-sidewalk report in code
  before checking that line.
- The retained camera frame is dropped when ARKit pauses: after a lock/unlock "Where am I" and the
  sign scan wait for a fresh frame rather than describing where the walker used to be.
- "Where am I" never needs a key: cloud provider → on-device fallback (Vision + Apple's on-device
  model, template when Apple Intelligence is off). On-device scene words go through
  `SceneVocabulary`: Vision identifiers not in its table ("conveyance", "portal", "machine") are
  dropped on purpose and synonyms merge; add a group, never pass raw identifiers to speech. The front camera is not used for *scene* work: it faces the
  walker on the cane, and ARKit owns the capture pipeline. It has two opt-in jobs of its own (both off
  by default): "Head tracking without AirPods" (`userFaceTrackingEnabled` → `ARFaceAnchor` yaw, no
  picture) and "Both cameras (pauses obstacle detection)", which is an `AVCaptureMultiCamSession` with
  ARKit paused. ARKit can never give both pictures at once (Apple DTS, forums 677731; `ARFrame` has one
  `capturedImage`), so pausing it is the only way — see `DualCameraSession`.
- Veer decisions use a 15 m course smoother while walking; the beacon keeps the raw heading.
  The gyro gate applies to the compass only, never to the GPS course. The smoother is kept empty
  while the fix is inside the fence of the corner just reached (its first course would be a diagonal
  across the corner) and is reset after every veer cue (so a corrected walker is not told again).
- The arrival hint ("You are close to …, press Next to finish") is clock-driven from the 10 Hz
  ticker (`NavigationEngine.tick`), because CoreLocation stops sending fixes while you stand still.
- The destination box suggests places as you type (Step 14): the campus gazetteer first, *always*
  above MapKit's rows and badged CAMPUS, because `MKLocalSearchCompleter` answers "Grainger" with an
  industrial supply store and the walker cannot see that. Campus rows match partial text; the
  gazetteer's own `CampusPlaces.match` stays whole-alias only on purpose (a partial name must reach
  MapKit). Completer rows whose subtitle ends in another **country** are dropped before ranking
  (`Locality.plausiblyNearby`, Step 50 — "Oab" on campus returned Australia and Rio despite a 6 km
  `.required` region); another US state is deliberately NOT dropped (a state line is not a
  distance — Vancouver WA → Portland OR); the walker's country comes from a reverse geocode of the
  fix, the campus until then. The tab bar collapses (stays mounted) while the keyboard is up (iOS
  26's floating Done capsule sat on the Profile icon). Completer rows never show a distance — a completion carries no coordinate, so there is
  nothing to measure. Tapping a row does not open a new code path: it calls the same
  `AppModel.navigate(to:)` / `navigate(to place:)` Siri uses, so "Walking to <place>, N meters." is
  still spoken before guidance. The row count is the app's only VoiceOver announcement (design.md §5.5).
- "Take me to …" (typed field or Siri) checks the campus gazetteer (`CampusPlaces`: CIF, ISR,
  Grainger, Illini Union, Siebel, Main Library, ARC) before MapKit, then walks to the *nearest*
  MKLocalSearch result within 3 km (a name containing every typed word preferred), never MapKit's
  first answer; "Walking to <place>, N meters." is said before guidance so a wrong pick can be
  stopped, and Stop also abandons a search still in flight. Siri phrases can only carry the
  gazetteer places ("Take me to Grainger in OpenCane"; App Shortcut phrases cannot hold a String);
  any other place goes through "Take me somewhere in OpenCane" and Siri asks where. Gazetteer
  entrances other than CIF / ISR are OSM entrance nodes, not yet walked.
- "Navigate to CIF from here" routes with Apple Maps to the route file's last waypoint as a bare
  coordinate (no search), so it can never pick a different "CIF". Starting the demo route also
  abandons an in-flight search, so a slow "Take me to …" cannot swap the walker onto another route
  mid-walk.
- A trip-log line's `t` and `kind` always belong to the record: a caller's field of the same name is
  written as `field_t` / `field_kind` (`TripLogRecord`, CaneKitLogic), never dropped and never
  allowed to win. Cue events therefore name their field `cue` and hazard events `type`; `field_kind`
  appearing in a log is an app bug and `ios/scripts/e2e.py` fails the run on it.
- Route cues are felt on the cane as long soft buzzes (turn left 1, right 2, crossing 3, arrived
  long-short-long) — deliberately unlike the crisp obstacle taps.
- "Head tracking without AirPods" (`faceHeadTrackingEnabled`) is **not persisted** (the property
  never reads its old `UserDefaults` key), and a recovered launch (`Settings.launchMode`: the
  previous launch's marker was still there) removes that key with the rest of
  `LaunchRecovery.optionalFeatureKeys`: a persisted `true` crashed the app inside ARKit warm-up
  on every launch (trip logs `canekit-2026-09-12T02-40-53Z` / `02-41-13Z`), with the off switch on a
  screen the app never reached. The flashlight (`torchEnabled`) is not persisted either (a pocketed
  torch is a dead battery and a burn risk).
- **"Flashlight on in the dark (routes)" ships ON** (Step 49, `AppModel.autoTorchInDark`) — the one
  deliberate exception to "new and untuned ships off by default". A blind walker cannot see that it
  is dark, so an opt-in nobody knows to flip would never be flipped; the light gives the cameras
  (ARKit tracking, signs, scene words, "Where am I") something to see and makes the walker visible
  to drivers. What keeps it safe: `LowLightPolicy` (CaneKitLogic) needs the smoothed ARKit lux under
  40 for 3 s; the torch is lit **only while a route guides** (never in a pocket), never at ≤ 20 %
  battery, not for 60 s after a thermal cut-out, only through the KVO-confirmed `setTorch(_:byApp:)`,
  and it goes off when the light returns, the route ends or the walker touches the switch; a torch
  the walker lit is never touched. The numbers are [H] until a dark-room walk (`light` records). Do
  not flip the default off in code; the owner flips the switch.
- **Vision says it is dark instead of guessing** (Step 49). When `LowLightPolicy` says dark and no
  torch is lit, "Where am I" prefixes "It is dark, so this may miss things.", the cloud prompt asks
  for exactly "It is too dark to see." on a black frame (`CloudSceneGate.tooDark` passes it), the
  `scan` / `hazard_watch` records carry `light: "dark"`, and `DepthFrameProcessor` publishes no mesh
  *name* (`centerHit = nil`) while ARKit tracking is not `.normal` — a world-anchored mesh under a
  drifting pose is the one path that could say "door" with confidence about a wall. Distances,
  cues, GPS and haptics are untouched: LiDAR does not need light. A readiness timeout with depth
  live but tracking limited now says "Camera tracking is limited, probably low light. Obstacle
  detection is running on LiDAR." instead of the false "Guiding with GPS."
  (`DepthReadiness.TimeoutReason`).

- **A blind lane cell right after a near reading is a wall, not a clear path** (Step 48,
  `NearHold`): inside ~10 cm the LiDAR returns 0 / NaN, not a low-confidence distance, so `LaneMath`
  reports the blind share per cell and `DepthFrameProcessor` holds such a cell at 0.1 m (STOP)
  until it measures again. It never arms without a prior reading under 0.6 m — the deliberate
  trade against painting STOP over a blind sky. Do not "simplify" the blind share into a plain
  no-data clear, and do not arm it without history without a night-sky test.
- **Always location is asked at the first route start, and the background session is armed only
  without it** (Step 47, `LocationService.requestAlwaysAuthorization` / `reconcileBackgroundSession`).
  A When-In-Use app keeps GPS through the screen lock only via `CLBackgroundActivitySession`, and
  that session puts iOS's blue location pill *in* the Dynamic Island, demoting our Live Activity to
  the minimal bubble; Apple Maps and Google Maps own the island because they hold Always. Do not
  "simplify" back to always-arm-the-session, and do not remove the session either: a walker who
  declines Always still needs fixes with the screen locked. `location_auth` records are the evidence.

### Steps 34–37 and the rotation fix (Sat 2026-09-12) — do not "simplify" these

- **The flashlight switch trusts KVO, never a read right after setting.** `AppModel.setTorch` sets
  the torch and deliberately does **not** read `AVCaptureDevice.isTorchActive` on the next line: iOS
  updates it asynchronously, that read was the old state, and every change took two presses (trip log
  `canekit-2026-09-12T20-57-17Z`, t = 106–120 s). The switch shows the request at once
  (`TorchSwitch`, CaneKitLogic), KVO on `isTorchActive` confirms it (each main-actor hop *re-reads*
  the device, since hops are not FIFO), and a 2 s settle deadline decides failure; the deadline task
  ticks with `now: .infinity` (comparing `systemUptime` with a `ContinuousClock` sleep could leave the
  window open forever). Pinned by `TorchSwitchTests` (`quickReversalSpeaksOnce`,
  `infiniteTickAlwaysResolves`). The torch is device-level, so it is never refused mid-route.
- **Both cameras is refused for the whole route, and the reason stays visible.**
  `BothCameras.state` (CaneKitLogic `LiveView.swift`) returns `.blockedByRoute` whenever
  `navigating`, *whatever the switch shows*: `setBothCameras` snaps a refused switch back to off at
  once, so keying on `enabled` hid the caption ("…Stop the route on the Guide tab first.",
  `HazardsCard`). A spotter's picture must not pause obstacle detection mid-route. Pinned by
  `bothCamerasExplainTheRefusalForTheWholeRoute`.
- **Face tracking is refused mid-route and during route start.** Changing
  `userFaceTrackingEnabled` either way makes `DepthEngine.setFaceTracking` re-run the AR session
  (~1–2 s with no obstacle frames). `FaceTrackingChange.decide` refuses while a route guides
  (`refused_route`) or waits for depth (`refused_route_start`): the `didSet` writes the old value
  back, speaks why at `.nav`, logs `face_tracking {action: refused_*}` and does **not** set
  `routeError` (nothing would clear it). The debug self test refuses too and its 15 s restore waits
  for the route to end. Pinned by `LiveViewTests.faceTracking*`.
- **`speech_dispatch` is a separate trip-log kind from `speech`.** `speech` records are written by
  *callers* (what the app decided to say) and are what `ios/scripts/e2e.py` asserts on;
  `speech_dispatch {text, priority, replays, resume_from}` is written from `SpeechQueue.onDispatch`
  for every line handed to a voice backend, whoever called `say`, muted automation included, so a
  resumed line appears twice. Dispatched is not heard. Folding them into one kind would double-count
  e2e's spoken lines; `speech_end {priority}` (natural line ends) is separate for `cue_audit.py`'s
  pause metric.
- **Obstacle names default off** (`obstacleNamesEnabled`, `Settings.bool(…, default: false)`, Step 36,
  research #2 in `docs/cue_design_v2.md`). A walker who never touched the switch hears no names until
  turning it on; `docs/stress_test_plan.md` D6 says so.
- **Cue level Detailed + place Outdoors is the default and equals today's behaviour**
  (`CueRules.default`, owner decision 2026-09-12) until a trip log from the *mounted* cane tunes the
  calmer levels. Its one delta from before: **Detailed never names walls**
  (`CueRules.allowsName`: `cls != .wall`) — the cane trails walls. Quiet and Indoors name nothing and
  read only `CueRules.safetySignPhrases`; Standard names doors only while a route guides; Indoors
  shortens the head distance to 1.2 m [H]. Head-height and ground-hazard warnings are identical at
  every level (the safety floor). Since Step 41 the levels also change the **torso** haptics
  (`TorsoHapticPolicy`, layered over an untouched `CueDecider`): Quiet none, Standard two centre onset
  taps (< 1.5 m closing, strong triple < 0.6 m, once per approach), Detailed today's loop and side taps
  minus shoreline re-taps (known blind spot: a post standing at exactly the hedge's distance is masked until the reading moves — the cane tip covers it); Indoors and a crossing settle hold every torso cue; the head cue is never
  gated (`headIsNeverSuppressed`). The raw values
  persisted under `cueLevel` / `cuePlace` must never be renamed (`rawValuesAreStable`). Pinned by
  `CueProfileTests`.
- **Two-camera rotation is fixed per camera, for the portrait-only UI — never unify it.**
  `DualCameraRotation.angle` (CaneKitLogic `LiveView.swift`, called from `DualCameraSession.connect`)
  gives the back camera a fixed 90 and the front camera a fixed 0 (270 fallback), and uses no
  `RotationCoordinator` angle for either. Every earlier attempt to use one coordinator angle for both
  cameras fixed one feed and broke the other (preview-for-both left the back sideways, trip log
  `2026-09-12T22-02-03Z` `back_rotation: 0`; capture-for-both, `103d548`, tilted the front). The
  capture angle follows the phone's physical orientation and the preview angle is sampled once at
  connect, so both are wrong when Both cameras starts with the phone sideways or flat. The UI is
  portrait-only (`UISupportedInterfaceOrientations` in `ios/project.yml`), so a fixed angle is right;
  "re-apply the angle on every orientation change" was rejected. The applied `*_rotation`, the
  coordinator's *capture* angle (`front_capture_angle` / `back_capture_angle`; the preview angle is
  passed in but not logged) and `front_size` / `back_size` / `*_portrait` are still logged as evidence. Pinned by `LiveViewTests`
  (`backCameraIsPortraitUpWhateverThePhoneReads`, `frontCameraIsPortraitUpWhateverThePhoneReads`).
- **A line cut by a warning resumes from its clause; a call, Siri or dictation restarts it.** A
  pre-emption (`say` of a higher band) re-queues the playing line at the front of its band from the
  start of the clause it was cut in (`SpeechResume.resumeOffset`; clause starts are `. ! ? , ; :` +
  space, not after "St." / "Dr." / "U.S."). An interruption `.began` or `setVoiceHold(true)` calls
  `requeueCurrent(fromClause: false)`: after seconds of a call or dictation a fragment has no context,
  so the line restarts from its last resume point (0 for a line never cut). The text stays whole as
  the coalescing, cache and Repeat key. mp3 progress is proportional and backed off
  (`mp3MarginUTF16`); the seek starts `clipLead` (0.25 s) early. Pinned by `SpeechResumeTests`.
- **The 0.35 s pause between bands bumps the generation.** `SpeechQueue.startNext` sets `inGap`
  and increments `generation` before sleeping `SpeechResume.crossBandGap`, so a stray second end
  callback from the line that just ended (still holding the old generation) cannot cut the pause
  short (Antigravity, Step 37). `isSpeaking` stays true during the pause (the beacon stays ducked);
  `.safety`, or a same-band line that ties or outranks the queue head, ends it; `gapSeconds` is 0
  for `.safety`, and the safety band is passed in from `SpeechPriority.safety.rawValue`, never copied.
- **"Head height." is never delayed behind a direction.** The first Step 37 plan held it behind a
  playing direction (buzz and chirp now, words later); Muse rejected it because a walker reaches a
  1.5 m overhang in about 1.5 s, before the words. The owner chose "Cut in, then resume": the warning
  pre-empts at once and the direction resumes. Walls still get "Head height." (owner: "Leave as is").
  Do not reintroduce a hold, a talk-floor wait or a gap in front of `.safety`.

## Where the plan and history live

- **Original plan:** `~/.claude/plans/phone-is-king-glittery-bee.md` (approved plan, deviations, test
  strategy) — outside the repo, on the owner's Mac only.
- **Build log:** `CHANGELOG.md`, one entry per step (newest first; Step 47 is this evening's — island redesign, torso haptics by level, scene engine card; Step 46 at `891f558`, Step 37 at `076fcaa`), each with
  why, what changed, every review finding fixed or rejected with evidence, verification output, and a
  `test on device:` list. Entries before Step 37 use the old cue-v2 step numbers (the talk floor was
  inserted as 37 and later steps renumbered +1).
- **Open work:** `docs/todo.md` — "Cue design v2 — Steps 35–45" is the cue plan (its item 41, torso haptics by level, shipped in CHANGELOG Step 47; items 38–40 and 42–45 are open). ⚠ Those item numbers are **not** CHANGELOG step numbers: CHANGELOG Steps 38–46 are a separate stream (point-blank wall, Grok Bot family alerts, Dynamic Island, hazard telemetry, GPS fallback + walk simulator, falls / weapons, the Medical ID Profile tab, Supabase, review fixes);
  `docs/TEAM_HANDOFF.md` §10 is how an agent resumes it. Both status blocks are dated snapshots.
- **Cue design research:** `docs/cue_design_v2.md` (Step 35: 4 researchers + 4 source fact-checkers,
  74 kept findings, [H] marks hypotheses, not measurements; §3 is the design, §4 the ranked change
  list). Speech-load research: `docs/auditory-load.md` (Step 30) and
  `docs/superpowers/{plans,specs}/2026-09-12-speech-load*.md`.
- **Measure first — `ios/scripts/cue_audit.py` via `cd ios && make audit`.** Before tuning any cue
  number: it runs `--selftest`, then reads `LOG=path` or `--pull`s the newest `canekit-*.jsonl` off
  the phone named by `DEVICE` in `ios/local.mk`. It says whether the walk was ON THE MOUNT (tilt
  inside 3–8°), head band wall vs overhang, cues and lines per minute, suppressed lines,
  `speech_dispatch` replays (mid-line vs from line start), cross-band pauses < 0.3 s, and any
  `field_kind` / `field_t` app bug. A handheld log must not tune a distance. It mirrors app constants
  by hand (`HEAD_ENTER_M = CueThresholds.head`, `MountTilt.aim`): move them together. Not part of
  `make test`.
- **Trip-log evidence:** trip logs are not in git. The app writes `canekit-<ISO time>.jsonl` to its
  Documents folder ("Write trip log", on by default; Files → On My iPhone → OpenCane); `make audit`
  pulls the newest, and `make e2e` keeps simulator logs in `ios/build/e2e/`. Cite a log by its
  timestamp name and `t` in code comments and `CHANGELOG.md`. The logs behind Steps 34–37:
  `2026-09-12T20-57-17Z` (torch, both-cameras, face tracking, first *handheld* cue baseline),
  `22-02-03Z` (`back_rotation: 0`), `22-20-53Z` (per-camera rotation confirmed, cue profile taps,
  5 of 58 lines restarted), `22-27-00Z` (37-minute handheld walk, 45 "Head height."). No log so far
  was recorded on the mount; `docs/TEAM_HANDOFF.md` §2.3 has the table.
- **Review and workflow expectations per step:** plan as a checklist in `docs/todo.md` (Muse on the
  plan when large or risky) → test first in `ios/Logic` → build → adversarial multi-agent review +
  Muse + Antigravity on the diff, every finding verified by hand and recorded in `CHANGELOG.md` as
  fixed, rejected with evidence, or deferred to `docs/todo.md` → `make test`, `make sim`, `make uitest`
  (+ `make tour` for UI), `make e2e` → `docs/CODE_REFERENCE.md`, `CHANGELOG.md`, `docs/todo.md`,
  `graphify update .` in the same commit → commit message ending `test on device: …`. Say what is
  not verified on the phone.
