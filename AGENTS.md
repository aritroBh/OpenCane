# AGENTS.md — rules for anyone (human or AI) editing OpenCane / CaneKit

Read this before touching the repo. `docs/CODE_REFERENCE.md` is the map of every file, type and
function; `CHANGELOG.md` is the build log; `docs/todo.md` is the strict checklist;
`docs/devices_setup.md` is the AirPods + Apple Watch checklist. When you change code, update its
module section in `docs/CODE_REFERENCE.md` in the same commit — agents rely on it being true.

## What this is

CaneKit is a native iOS 26 app (Swift 6, SwiftUI, no third-party packages) that guides a blind cane
user along GPS waypoints and warns about waist-to-head obstacles. The **phone is the only computer**:
an iPhone 17 Pro Max (iOS 27) clamped to a non-metal 28.75 mm cane, plus AirPods Pro (beacon +
speech + head yaw) and an Apple Watch (wrist taps, Repeat / Next / Describe / Recenter). No ESP32, no
external sensors. The demo route is ISR Townsend Hall → CIF on the UIUC campus
(`ios/CaneKit/Resources/route_isr_cif.json`), but any destination works via MapKit walking directions.
For the demo everything runs **untethered on the phone**; the Mac only signs and installs.

## Layout

| Path | What lives there |
|---|---|
| `ios/Logic/` | `CaneKitLogic` SwiftPM package: pure, Foundation-only decisions (lane math, cue state machine, geofences, route schema, watch message codec, VLM request/response codec) + Swift Testing tests |
| `ios/CaneKit/` | The iOS app: `App/` (AppModel = owner of every engine), `Depth/`, `Haptics/`, `Speech/`, `Watch/`, `Navigation/`, `Audio/`, `Scene/`, `Trip/`, `UI/`, `Resources/` |
| `ios/CaneKitWatch/` | watchOS app |
| `ios/CaneKitWidget/` | Live Activity widget (Dynamic Island / lock screen) |
| `ios/Shared/` | Types compiled into more than one target (Live Activity attributes) |
| `ios/CaneKitUITests/` | XCUITests + the screenshot tour |
| `ios/project.yml`, `ios/scripts/gen.sh`, `ios/Makefile` | XcodeGen project + CLI build/test/install |
| `ios/stretch/`, `ios/drafts/` | Not in any target. Old ESP32 BLE code and iOS 18 drafts. Leave alone. |
| `docs/` | `README.md` (index), `CODE_REFERENCE.md`, `design.md` (UI/cue design system), `route_isr_cif.md` (route evidence), `stress_test_plan.md`, `devices_setup.md`, `todo.md`, `ideas.md` |
| `hardware/mount/` | Phone-to-cane mount, screwed: design brief + parametric OpenSCAD (Sagar) |
| `hardware/mount_screwless/` | Same job, **zero bought hardware**: collet clamp + dovetail modularity, `scripts/build_stl.ps1` (Sagar) |
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
   `ios/scripts/gen.sh` (it also applies the XcodeGen watch-embed patch and copies Secrets). Never
   hand-edit the pbxproj, never regenerate unless `project.yml` or the file list changed.
6. **Bundle IDs are frozen**: `com.aritro.canekit`, `.watchkitapp`, `.widget` (free personal team, 10
   App IDs per week).
7. **Audio session is one `.playback` session**, mode `.default`, `[.duckOthers]`, no Bluetooth options
   (HFP drops AirPods to phone-call quality). `CHHapticEngine(audioSession: nil)`. `.HRTF`, mono click.
   Do not "fix" the deviations listed in `ios/README.md §2` back to the original spec.
8. **Cue priorities** (speech): scene < obstacle names < route lines < "Head height." The `.head` cue is
   never suppressed. Interrupted lines are re-queued. Keep `docs/design.md §5` and `SpeechQueue` in sync.
9. **Accessibility labels are a test contract.** The strings in `CaneKitUITests` (Start demo route,
   Navigate to CIF from here, Stop route, Repeat, Next, Recenter, Where am I, Go, Test
   left/center/right/head haptic, Silence haptics, Mirror left / right, Write trip log, Head row,
   Type a destination first) must not change without updating the tests in the same commit.
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
   a multi-agent review (finders + skeptics who try to refute each finding), **plus Muse**
   (`muse exec … --workspace <scratch>`, read-only) **plus Antigravity** (`agy -p …`, pointed at a
   *copy* of the repo — it has edited files despite a read-only prompt). Keep review prompts small
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
make sim17           # create the iPhone 17 Pro Max (iOS 27) simulator once
make e2e             # GPS-replay end-to-end scenarios through the real app (SCENARIO=clean …)
make devices         # find DEVICE for ios/local.mk
make run             # gen + build + install + launch on the phone (needs TEAM/DEVICE in ios/local.mk)
```
Simulator GPS replay: launch with `SIMCTL_CHILD_CANEKIT_DEMO_ROUTE=1` and feed
`xcrun simctl location <udid> start --speed=4 --interval=1 <lat,lon> …`; read the JSONL trip log in the
app container's Documents folder.

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
- An interrupted speech line resumes once, then is dropped (Repeat recovers it). Lines said during a
  call / Siri queue and drain on `.ended` (15 s fallback).
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
  dropped on purpose and synonyms merge; add a group, never pass raw identifiers to speech. The front camera is deliberately unused: it
  faces the walker on the cane, and ARKit owns the capture pipeline.
- Veer decisions use a 15 m course smoother while walking; the beacon keeps the raw heading.
  The gyro gate applies to the compass only, never to the GPS course. The smoother is kept empty
  while the fix is inside the fence of the corner just reached (its first course would be a diagonal
  across the corner) and is reset after every veer cue (so a corrected walker is not told again).
- The arrival hint ("You are close to …, press Next to finish") is clock-driven from the 10 Hz
  ticker (`NavigationEngine.tick`), because CoreLocation stops sending fixes while you stand still.
- "Take me to …" (typed field or Siri) checks the campus gazetteer (`CampusPlaces`: CIF, ISR,
  Grainger, Illini Union, Siebel, Main Library, ARC) before MapKit, then walks to the *nearest*
  MKLocalSearch result within 3 km (a name containing every typed word preferred), never MapKit's
  first answer; "Walking to <place>, N meters." is said before guidance so a wrong pick can be
  stopped, and Stop also abandons a search still in flight. Siri phrases can only carry the
  gazetteer places ("Take me to Grainger in CaneKit"; App Shortcut phrases cannot hold a String);
  any other place goes through "Take me somewhere in CaneKit" and Siri asks where. Gazetteer
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

## Where the plan and history live

`~/.claude/plans/phone-is-king-glittery-bee.md` (approved plan, deviations, test strategy) — outside
the repo. `CHANGELOG.md` has one entry per step with its device test list.
