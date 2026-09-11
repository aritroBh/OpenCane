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
| `docs/` | `design.md` (UI/cue design system), `route_isr_cif.md` (route evidence), `todo.md`, `ideas.md`, `CODE_REFERENCE.md` |

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
   Stop route, Repeat, Next, Recenter, Where am I, Go, Test left/center/right/head haptic, Silence
   haptics, Mirror left / right, Write trip log, Head row, Type a destination first) must not change
   without updating the tests in the same commit.
10. **Every commit**: `cd ios && make test` green (Logic), `make sim` green, and for UI changes
    `make uitest` + `make tour` on the **iPhone 17 Pro Max / iOS 27** simulator (`make sim17` creates
    it once). Run the Muse review (`muse exec`, read-only, from a scratch dir) on the diff. Commit message
    ends with a one-line `test on device: …` note. Add a `CHANGELOG.md` entry and tick `docs/todo.md`.

## Commands

```sh
cd ios
make test            # CaneKitLogic unit tests (Swift Testing; works with Command Line Tools alone)
make sim             # build the app for the iOS simulator (no LiDAR / haptics / watch there)
make uitest          # XCUITests on the iPhone 17 Pro Max simulator
make tour            # screenshot every screen state → ios/build/shots
make sim17           # create the iPhone 17 Pro Max (iOS 27) simulator once
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
- Auto-recenter of the AirPods head reference: `StraightWalkDetector` (3 fixes > 0.9 m/s, steady
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

## Where the plan and history live

`~/.claude/plans/phone-is-king-glittery-bee.md` (approved plan, deviations, test strategy) — outside
the repo. `CHANGELOG.md` has one entry per step with its device test list.
