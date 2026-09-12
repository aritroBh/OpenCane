# OpenCane: the iOS app for the phone-only smart cane

> **The name split.** The product a person sees, hears and says to Siri is **OpenCane** (that is
> `CFBundleDisplayName` in `project.yml`). Everything in the build is still called **CaneKit**: the
> Xcode project, the targets and scheme, `PRODUCT_NAME`, the `CaneKitLogic` module, the
> `ios/CaneKit/…` paths, the Makefile and the frozen bundle ids `com.aritro.canekit*`. That is
> deliberate (AGENTS.md → "The name split"), so every command and path in this file still matches
> the files on disk. Do not rename the code.

This is a native SwiftUI app in Swift 6 with strict concurrency (main-actor default isolation). It
builds against iOS 26 / watchOS 26 and uses Apple frameworks only, with no third-party packages.
The hardware is an iPhone 17 Pro Max on iOS 27 (LiDAR, Action button, Camera Control) clamped to a
non-metal stick (27.65 mm, measured by the bore rings on 2026-09-12; a broom handle stands in for the
cane), plus AirPods Pro and an Apple Watch. For the demo everything runs
**untethered on the phone**. The Mac only signs and installs.

| Target / package | What it is | Bundle ID (frozen) |
|---|---|---|
| **CaneKit** (shown as **OpenCane**) | The iPhone app, and the only computer in the kit | `com.aritro.canekit` |
| **CaneKitWatch** | watchOS companion: wrist taps, Repeat / Next / Describe / Recenter | `com.aritro.canekit.watchkitapp` |
| **CaneKitWidget** | Live Activity (Dynamic Island + lock screen) | `com.aritro.canekit.widget` |
| **CaneKitUITests** | XCUITests + the screenshot tour | `com.aritro.canekit.uitests` |
| **CaneKitLogic** (`Logic/`) | SwiftPM package with every pure decision that has a number in it, plus its Swift Testing tests. Runs without Xcode. | — |

Start with [`AGENTS.md`](../AGENTS.md) (hard rules; it wins every conflict), then
[`docs/CODE_REFERENCE.md`](../docs/CODE_REFERENCE.md), which maps every file, type and function and
has the **data-flow diagram** ([§ Data flow](../docs/CODE_REFERENCE.md#data-flow)). Before the
AirPods, the watch or the untethered demo, read [`docs/devices_setup.md`](../docs/devices_setup.md).
Every other doc is listed in [`docs/README.md`](../docs/README.md).

**Status (HEAD `076fcaa`).** Steps 0–37 have landed; the latest are Step 34 (flashlight switch,
both-cameras refusal), Step 35 (cue design v2 research + `scripts/cue_audit.py`), Step 36 (cue
detail Quiet / Standard / Detailed × Outdoors / Indoors, obstacle names off by default), the
per-camera rotation fix, and Step 37 (talk floor: a direction cut by a warning resumes from its
clause). The Logic package has **457 `@Test` annotations in 34 test files**. Step 37 recorded
`make test` 457/457, `make sim` green, `make e2e` PASS, and `make uitest` 11 run / 10 passed /
1 skipped / 0 failures, and it was installed on the phone. The next steps (38–45) are the rest of
cue design v2 in [`docs/todo.md`](../docs/todo.md); device testing of each step's "test on device"
line is the open work. [`docs/todo.md`](../docs/todo.md) and [`CHANGELOG.md`](../CHANGELOG.md) are
the source of truth.

## Layout

| Path | Contents |
|---|---|
| `CaneKit/` | The phone app: `App/` (`AppModel` owns every engine; App Intents and hands-free intents), `Conversation/` (voice input, conversational assistant), `Depth/`, `Haptics/`, `Speech/`, `Audio/` (beacon, sound watcher), `Navigation/`, `Scene/`, `Trip/`, `Watch/`, `UI/`, `Resources/` (`route_isr_cif.json`, assets, your git-ignored `Secrets.plist`) |
| `CaneKitWatch/`, `CaneKitWidget/`, `CaneKitUITests/` | The targets above |
| `Shared/LiveActivity/` | `NavActivityAttributes`, compiled into the app and the widget |
| `Logic/` | `CaneKitLogic`, 37 source files. Depth and obstacles: `LaneMath`, `LaneReport`, `DepthSnapshot`, `DepthReadiness`, `MultiCamDepth`, `CueDecider`, `PeopleAhead`, `Hazards`. Cues and speech: `CueProfile` (`CueRules`), `SpeechResume`, `SpeechLoadPolicy`, `SpokenPhrases`, `UtteranceEnd`, `VoicePrefetch`. Navigation: `GeoMath`, `CourseSmoother`, `NavSupport`, `Waypoint`, `CampusPlaces`, `DestinationSuggestions`. Scene: `VLMCodec`, `SceneVocabulary`, `CloudSceneGate`. Hands-free and conversation: `ConversationModels`, `ConversationPrompt`, `FastPathIntentClassifier`, `HeadNodDetector`, `QuestionPrompt`, `StatusSummary`. Devices and app state: `WatchMessage`, `HeadYawSources`, `SoundAlerts`, `SoundRecognitionGuard`, `TorchSwitch`, `LiveView`, `LaunchRecovery`, `TripLogRecord`. Plus `Tests/` |
| `project.yml` | XcodeGen spec. `CaneKit.xcodeproj` is generated and git-ignored. |
| `Makefile`, `scripts/` | `gen.sh` (project generation), `test.sh` (logic tests), `e2e.py` (GPS-replay end-to-end), `cue_audit.py` (cue load of one trip log, `make audit`), `vision_probe.swift` / `sign_probe.swift` (on-device Vision and sign-reading range against Street View frames), `streetview/` (`frames.json` + git-ignored JPEGs), `appicon.py` (renders the app icon) |
| `Secrets.example.plist` | Template for `CaneKit/Resources/Secrets.plist` |
| `local.mk` | Git-ignored, and you create it: `TEAM` and `DEVICE` for device builds |
| `stretch/`, `drafts/` | Not in any target (old ESP32 BLE client, iOS 18 starter files). Leave them alone. |

---

## 1. Day-0 checklist

These steps are done once per Mac and per phone. On the build Mac they are done: Xcode 27 RC
(27A266a) and XcodeGen 2.46.0 are installed, `ios/local.mk` exists, and the app has been installed
on the phone with `make run` (CHANGELOG Steps 35 and 37). A second Mac or phone needs all of them.

1. Install **Xcode 27 RC** (developer.apple.com/download; ~15 GB installed). The phone runs iOS 27,
   so Xcode 26 cannot deploy to it. The deployment target stays **iOS 26 / watchOS 26**.
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform watchOS      # separate download; the watch target fails without it
   brew install xcodegen                     # 2.46.0
   ```
2. Open Xcode once → Settings → Accounts → add your Apple ID. A free **Personal Team** appears. An
   install expires after 7 days, and the team gets 10 App IDs per week. We use 3, so never rename
   bundle IDs. Then run `cd ios && make gen`, open `ios/CaneKit.xcodeproj` once, select the
   **CaneKit** target → **Signing & Capabilities** and pick the Personal Team. That creates the
   Apple Development certificate (until it exists, `security find-identity -v -p codesigning`
   lists nothing). Your **Team ID** is shown in Xcode → Settings → Accounts → the team's details,
   or read it from the certificate and use the `OU=` value:
   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```
   The 10 characters in parentheses of an "Apple Development: Name (…)" identity are **not** the
   Team ID.
3. iPhone **and** Watch: Settings → Privacy & Security → **Developer Mode** → on (this reboots).
4. Plug the phone in and open Xcode → Window → Devices. The paired watch shows under the phone,
   which registers its UDID. Watch pairing over Wi-Fi is flaky: if the watch isn't paired within
   30 min, the watch app becomes a day-2 item.
5. Run `cd ios && make devices` and copy the phone's identifier. Then create `ios/local.mk`:
   ```make
   TEAM   = ABCDE12345                # the OU= value from step 2
   DEVICE = 00008150-000A1B2C3D4E5F   # make devices
   ```
6. First install (`make run`), then on the phone: Settings → General → VPN & Device Management →
   trust the developer app.
7. Phone Settings → Action Button → Shortcut → **Where am I**. The shortcut appears after the first
   launch.
8. Settings → Bluetooth → (i) next to the AirPods → **Spatial Audio: Off** and **Head Tracking: Off**.
   System head-tracking would re-spatialize the beacon. The rest of the AirPods and watch list is in
   `docs/devices_setup.md`.

## 2. Verified spec deviations (don't "fix" these back)

| Spec said | Reality (Apple docs, checked Sep 10) | What CaneKit does |
|---|---|---|
| `AVAudioEnvironmentNode.isListenerHeadTrackingEnabled` | Needs the **Head Pose** capability, which is paid-team only | `CMHeadphoneMotionManager` yaw (relative, drifts) drives `listenerAngularOrientation`. **Recenter** comes from the phone or watch button, or auto-recenter when walking straight (`StraightWalkDetector`: 3 steady fixes, never within 15 m of a crossing). The beacon ignores head yaw until the first recenter after a turn. |
| Watch side button = "next" | There is no API for the side button or a crown *press* | Crown rotation (3 detents within 1 s of the first) + big on-screen Repeat / Next / Describe / Recenter |
| Camera Control press = describe | `AVCaptureEventInteraction` only fires for apps "actively performing capture". Unverified with ARKit owning the camera. | Spike built (`Scene/CameraControlInteraction.swift`; the debug footer counts presses). The Action button, the watch and the on-screen button are the guaranteed paths. |
| Watch haptics on demand | `WKInterfaceDevice.play` no-ops unless the watch app is frontmost, and `sendMessage` needs reachability | The watch runs a walking `HKWorkoutSession` (HealthKit on the watch target) so cues play wrist-down, with a `WKExtendedRuntimeSession` fallback |
| Haptic rate ∝ 1/distance | `sendParameters` can't retime events | Geiger loop: one pre-built transient player fired on a timer, 2 Hz at 2 m → 8 Hz at 0.5 m |
| One audio session | Mixing `.playback` / `.playAndRecord` / HFP flips AirPods routes | `.playback`, mode `.default`, `[.duckOthers]`, no Bluetooth options. TTS uses the app session. Haptics use `CHHapticEngine(audioSession: nil)`. |
| XcodeGen project | 2.46.0 embeds the watch app in `Watch/` (bug #1613, Xcode 26+) | `scripts/gen.sh` patches the pbxproj after generating. `WATCH=0 scripts/gen.sh` gives a phone-only project. |

Also: mesh classification ("Two meters ahead, door") is an **indoor** feature. LiDAR range is ~5 m and
sunlight kills it. Outdoors the product is the lanes (distance only). Demo doors are at the ISR
lobby and the CIF entrance.

## 3. Build, install, launch

Everything runs from `ios/` on the command line. You don't need the Xcode GUI after day 0.
`TEAM` and `DEVICE` come from `local.mk`, and you can override either on the command line
(`make build DEVICE=…`).

| Command | What it does |
|---|---|
| `make gen` | `scripts/gen.sh`: `xcodegen generate` + the watch-embed patch, and it copies `Secrets.example.plist` → `CaneKit/Resources/Secrets.plist` if missing. Run it only after `project.yml` or the file list changes. `WATCH=0 scripts/gen.sh` gives a phone-only project. |
| `make test` | `scripts/test.sh`: the 457 `CaneKitLogic` tests (Swift Testing). Works with the Swift 6 toolchain / Command Line Tools; never touches the simulator or xcodebuild. Extra arguments pass through to `swift test` only when you call `scripts/test.sh` directly (e.g. `scripts/test.sh --filter SpeechResume`). |
| `make build` | Device build, automatic signing, personal team (needs `TEAM` + `DEVICE`) |
| `make install` | `xcrun devicectl device install app` onto the phone |
| `make launch` | `xcrun devicectl device process launch com.aritro.canekit` |
| `make run` | `gen` + `build` + `install` + `launch`. Use this for the phone. |
| `make sim` | Build for the iOS simulator (no LiDAR, haptics or watch there) |
| `make sim17` | Create the **iPhone 17 Pro Max / iOS 27** simulator (`xcrun simctl create`). Run it once: Xcode 27 does not create that device by default. |
| `make sim-grant` | Boot the simulator and pre-grant location + motion so no system alert races a test's first tap. `uitest`, `tour` and `e2e` run it for you. |
| `make uitest` | The whole `CaneKitUITests` target (both XCTest classes, 11 tests) on the iPhone 17 Pro Max simulator. Set a simulator location first (below). |
| `make uitest-streetview` | Only `testWhereAmIDescribesAStreetViewFrame`, with `TEST_RUNNER_CANEKIT_FRAME_DIR` pointing at `STREETVIEW` (default `scripts/streetview`), so Street View frames stand in for the camera. Needs the git-ignored JPEGs. |
| `make tour` | Screenshot every screen state (`CaneKitVisualTour`) → PNGs in `SHOTS` (default `build/shots/`) |
| `make e2e` | Runs `sim` and `sim-grant`, then GPS-replay end-to-end through the real app (`scripts/e2e.py`). `SCENARIO=all` (default, ~20 min: `clean`, `missed_fence`, `gps_jitter`, `wrong_turn`), one of those four, or `streetview` (not in `all`; needs the local JPEGs). It asserts on the app's JSONL trip log. The report and logs go to `build/e2e/`. Always muted. Run it alone: it is a real-time replay. |
| `make audit` | `scripts/cue_audit.py --selftest`, then the cue load of one walk: `make audit LOG=path/to/canekit-….jsonl`, or with no `LOG` it pulls the newest trip log off the phone named by `DEVICE` in `local.mk` (plugged in, unlocked, trusted). Read-only; no simulator. Reports mounted vs handheld, head band wall vs overhang, cues and spoken lines per minute, replays and resumes. |
| `make devices` | `xcrun devicectl list devices` (to find `DEVICE`) |
| `make clean` | Delete `build/`, `CaneKit.xcodeproj` and `Logic/.build` |

Make variables: `SIM ?= iPhone 17 Pro Max` (simulator targets), `SCENARIO ?= all` (`e2e`), `LOG`
(`audit`), `SHOTS ?= build/shots` (`tour`), `STREETVIEW ?= scripts/streetview`
(`uitest-streetview`), `CONFIG ?= Debug`, `SCHEME ?= CaneKit`. Override any of them per call or in
`local.mk`.

**Simulator location.** `make uitest` and `make tour` need a GPS fix on the simulator, or the route
tests fail for want of one (AGENTS.md, Commands). Set it on the booted simulator before the run:

```sh
xcrun simctl list devices | grep "iPhone 17 Pro Max"      # the UDID in parentheses
xcrun simctl location <udid> set 40.1140,-88.2249
```

`make e2e` does not need this: `scripts/e2e.py` sets and clears the location itself for every
scenario.

The watch app rides inside the phone app and installs through the Watch app on the phone
(Automatic App Install on, or Available Apps → **OpenCane** → Install — the Watch app lists the
display name, not the target name).

## 4. Secrets and permissions

`Secrets.example.plist` is the template for `CaneKit/Resources/Secrets.plist`, which is
**git-ignored**. `make gen` copies it if missing. Never commit the real file. It is bundled into the
.app at build time, so fill in the keys *before* `make run`.

| Key | Meaning |
|---|---|
| `VLM_PROVIDER` | `custom` \| `anthropic` \| `gemini` \| `openai` \| `ondevice`. If empty, the first provider with a key is used (on-device when there is none). `ondevice` uses the phone only, even with a cloud key set. |
| `CUSTOM_BASE_URL` / `CUSTOM_API_KEY` / `CUSTOM_MODEL` | Any OpenAI-compatible chat endpoint (Muse 1.3). The base URL goes without `/chat/completions`. |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL`, `GEMINI_API_KEY` / `GEMINI_MODEL`, `OPENAI_API_KEY` / `OPENAI_MODEL` | The other "Where am I" providers |
| `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL` | Natural voice. The defaults are a warm premade voice and `eleven_flash_v2_5`. |
| `OPENCANE_GROKBOT_WEBHOOK_URL`, `OPENCANE_GROKBOT_WEBHOOK_KEY` | Family alerts (§4.1). Copied from the Grok Bot routine's webhook-trigger panel. Empty = the feature is off and says so in Settings. |
| `ALERT_MODEL`, `ALERT_REASONING_EFFORT` | Optional. Which cheap model writes `extra.ai_context` on a family alert, and how hard it thinks. Empty model = cheapest of whichever provider has a key (Anthropic → custom → OpenAI). |

With no ElevenLabs key the app uses the system voice. With no VLM key (or `VLM_PROVIDER` =
`ondevice`), "Where am I" answers on the phone: Apple Vision plus Apple's on-device model, or a
template sentence when Apple Intelligence is off. A cloud key adds the cloud model first, with the
on-device describer as the fallback. The no-key UI test checks that "Where am I" never hangs or
crashes. Keys ship in plaintext inside the .app, which is fine for a local install; rotate them
after the event.

### 4.1 Family alerts (Grok Bot)

Cane detections are POSTed as one JSON event to the Grok Bot routine **"OpenCane cane events"**
(folder `opencane-cane-events`), which decides whether to text family. Copy the **Webhook URL** and
**key** from that routine's panel in Grok Bot into `Secrets.plist`:

```xml
<key>OPENCANE_GROKBOT_WEBHOOK_URL</key>
<string>https://…</string>
<key>OPENCANE_GROKBOT_WEBHOOK_KEY</key>
<string>…</string>
```

Both names are also read from the **process environment first**, so an e2e or CI run can point at a
throwaway endpoint without touching the plist:

```sh
export OPENCANE_GROKBOT_WEBHOOK_URL="https://…"
export OPENCANE_GROKBOT_WEBHOOK_KEY="…"
```

The switch is **Settings → Family alerts → "Send cane events to family"**, off by default (it sends
the walker's position off the phone). **"Send test event"** posts one sample `fall` event and speaks
what came back; it works even while the switch is off, which is how you check the chain before a
walk.

What each detection becomes — thresholds in `FamilyAlertPolicy` (CaneKitLogic, unit-tested):

| Detection | Event | Severity | Rate limit |
|---|---|---|---|
| Periodic GPS | `location` | `info` (chat-only) | one per 120 s |
| Close obstacle (≤ 1.2 m) | `obstacle` | `warn` | one per 60 s |
| Phone battery ≤ 20 % | `low_battery` | `warn` | once per discharge (re-arms above 30 %) |
| Fall | `fall` | `critical` | never limited |
| SOS | `sos` | `critical` | never limited |

#### Who gets alerted

The bot emails a saved list of addresses; the **app never sends mail**. Register the list in
**Settings → Family alerts → Family emails**: add addresses, then press **Save family emails**.
Saving POSTs one event to the same webhook:

```json
{
  "type": "family_contacts",
  "emails": ["mom@example.com", "dad@example.com"],
  "cane_id": "opencane-01",
  "user": "Tejas",
  "timestamp": "2026-09-12T23:20:00Z",
  "send_test": true
}
```

`send_test` is sent **only on the first list the bot accepts**, so each address gets one "you are on
the OpenCane alert list" email rather than one per edit. Cane events (`fall`, `sos`, `obstacle`, …)
are posted separately and unchanged afterwards — they never carry `emails`, because the bot already
has the list and every copy is one more place it could leak.

Addresses are trimmed, lowercased, de-duplicated and capped at 10 (`FamilyContacts`); an invalid
entry is refused in the UI with the reason, never silently dropped. An empty list is a valid Save —
it tells the bot to stop emailing anyone.

⚠ Registering ignores the "Send cane events to family" switch (you fill the list in before turning
alerts on) and never goes near the summarizer — a family's addresses are not context for a sentence.

Every event also carries what the phone knew at that moment, in `extra`:

| Field | Example |
|---|---|
| `navigating`, `has_fix` | `true`, `true` |
| `destination`, `instruction`, `distance_to_next_m` | `"ISR to CIF"`, `"Cross Springfield Avenue"`, `42.4` |
| `speed_mps`, `heading_deg` | `0.0`, `272` |
| `battery_pct`, `thermal_state` | `18`, `"fair"` |
| `active_cue`, `last_ground_hazard` | `"clear"`, `"Two meters ahead, drop-off."` |
| `ai_context` | one sentence written by a cheap model from the fields above |

`ai_context` is what makes an alert readable — "Possible fall detected on the route from ISR to CIF
at Cross Springfield Avenue, 42 metres to the next waypoint … battery 18%" instead of bare
coordinates. It is **best effort**: no key, a timeout or an HTTP error costs the event its sentence
and nothing else, and the facts above are sent either way. Switch it off in Settings → Family alerts
→ **Add AI context**.

⚠ **The model never writes `note`.** A language model is not allowed to be the only factual line in
a safety alert, so its sentence sits in `extra.ai_context` beside the facts it was given and can
always be checked against them. The prompt also forbids the failure a small model reaches for
unprompted: never say the walker is safe or that help is coming, never invent a street or an injury.

⚠ **No fall detector and no SOS control exist yet.** `FamilyAlerts.fall(…)` / `.sos(…)` are written
and tested, but nothing calls them except the test button — see `docs/todo.md`.

⚠ **HTTP 200 means the bot accepted the call and started a run — not that an SMS was sent.** The bot
decides who to text afterwards, from `severity` and `type`. No string in the app says "family
notified", and none should.

Verify the webhook by hand:

```sh
curl -X POST "$OPENCANE_GROKBOT_WEBHOOK_URL" \
  -H "Authorization: Bearer $OPENCANE_GROKBOT_WEBHOOK_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "fall",
    "severity": "critical",
    "timestamp": "2026-09-12T20:30:00Z",
    "lat": 40.1106,
    "lng": -88.2284,
    "note": "Possible fall detected",
    "cane_id": "opencane-01",
    "user": "Tejas"
  }'
```

A success looks like `{"success":true,"runUuid":"…"}`.

Permissions are declared in `project.yml` and prompted on first use:

- **Location** is requested at launch, so have a sighted helper present. `CANEKIT_UITEST=1` skips
  the request.
- **Motion** and **HealthKit** are requested at route start.
- **Health** is requested again on the watch.
- **Camera + LiDAR** are used for obstacles.
- **Speech recognition + microphone** are requested the first time voice input is used
  (`VoiceInputEngine`: Action button / "Talk to OpenCane"); the **microphone** alone is also
  requested when "Listen for sirens and horns" is turned on (`SoundWatcher`).

Every purpose string names the app **OpenCane**, because that is the name the system shows next to
it in the prompt and in Settings ("Turn on Camera for OpenCane"). They live in `project.yml`; edit
them there and re-run `make gen`.

Background modes are `audio` and `location` on the phone and `workout-processing` and `mindfulness`
on the watch. `NSSupportsLiveActivities` is on for the Dynamic Island.

## 5. Testing

The **commit gate** (from `AGENTS.md` rule 10): `make test` and `make sim` must be green. For UI
changes, also run `make uitest` and `make tour` on the iPhone 17 Pro Max / iOS 27 simulator. Run
`make e2e` for navigation or speech changes. Then run the Muse review of the diff.

- **Unit tests (`Logic/`, no device):** 457 Swift Testing `@Test` annotations in 34 files under
  `Logic/Tests/CaneKitLogicTests/`. By layer, file names without the `Tests.swift` suffix (count per
  file in parentheses):
  - Depth and obstacles: `LaneMath` (15), `DepthSnapshot` (14), `DepthReadiness` (7, the bounded
    route-start LiDAR gate), `MultiCamDepth` (8), `CueDecider` (14, hysteresis / rate limit / Geiger),
    `PeopleAhead` (28), `Hazard` (46, ground profile, signs, hazard watch, GeoJSON map).
  - Cues and speech: `CueProfile` (15), `SpeechResume` (15), `SpeechLoadPolicy` (7), `SpokenPhrases`
    (12), `UtteranceEnd` (7), `VoicePrefetch` (5), `NavSupport` (19, turn settling, straight-walk,
    spoken-cue policy, crown gesture).
  - Navigation: `GeoMath` (26, skip-ahead, passed-by, arrival gate), `CourseSmoother` (3), `Route`
    (4, MapKit steps → waypoints and the shipped route file), `CampusPlaces` (11),
    `DestinationSuggestions` (14).
  - Scene: `VLMCodec` (11), `SceneVocabulary` (16), `CloudSceneGate` (15).
  - Hands-free and conversation: `ConversationLogic` (13), `NodToTalkFastPath` (2), `HeadNodDetector`
    (7), `QuestionPrompt` (6), `StatusSummary` (12).
  - Devices and app state: `WatchMessage` (3), `HeadYawSources` (18), `SoundAlerts` (38),
    `TorchSwitch` (16), `LiveView` (22), `LaunchRecovery` (6), `TripLogRecord` (2).

  Count them yourself with `grep -rhoE "^\s*@Test" Logic/Tests | wc -l`. Verify a run by its exit
  code and `error:` lines, never through `tail` (AGENTS.md, Step 27 trap).
- **UI (`make uitest`):** 11 XCTest methods. `CaneKitUITests` has 10: start, Next, Repeat, Recenter
  and Stop on the demo route; Where am I without a key; Where am I on a Street View frame (skipped
  unless `make uitest-streetview`); the haptic test buttons and the Silence toggle; mount toggles
  persist; the Cues pickers change and restore; VoiceOver labels; the Navigate-to-CIF button on the
  idle Guide; the empty-destination error; and campus suggestions while typing. `CaneKitVisualTour`
  has 1 (`testTour`). The last recorded run (Step 37): 11 run, 10 passed, 1 skipped, 0 failures.
  Accessibility labels are a test contract (`AGENTS.md` rule 9).
- **Visual (`make tour`):** one PNG per screen state in `build/shots/`, for review by eye.
- **End-to-end (`make e2e`):** replays the ISR → CIF route in the simulator with
  `xcrun simctl location`. The app auto-starts the route under `CANEKIT_DEMO_ROUTE=1`. Assertions
  run on the trip log: waypoint order, wrist cues, veer cues, "Passed …" lines and arrival. The
  four scenarios are a clean walk, a missed fence, ±6 m GPS jitter and a wrong turn at Goodwin.
  Manual replay: `SIMCTL_CHILD_CANEKIT_DEMO_ROUTE=1 xcrun simctl launch booted com.aritro.canekit`,
  then `xcrun simctl location booted start --speed=4 --interval=1 <lat,lon> …` with the waypoints
  from `CaneKit/Resources/route_isr_cif.json`. The log is `Documents/canekit-*.jsonl` under
  `xcrun simctl get_app_container booted com.aritro.canekit data`.
- **CI (`.github/workflows/ci.yml`) is manual-trigger only** (Actions → CI → Run workflow). GitHub
  Actions billing on the account is exhausted, so pushes don't run it. When run, it does logic tests
  on Linux and an informational phone-only simulator build on macOS. **The local gate above is
  authoritative.**
- **Device only (manual, following each step's "test on device" line in `CHANGELOG.md`):** LiDAR
  scale, haptic feel through the clamp, beacon left/right and head-tracking sign, wrist-down watch
  taps, geofence timing, VLM latency and thermal.
- **Reproducibility:** `TripLogger` writes one `canekit-<ISO 8601 stamp>.jsonl` per session to the
  app's Documents folder (lanes with `tilt`, cues, GPS, heading, thermal, battery, speech dispatches
  and ends, `cue_profile`, hazards). The hazard map is `Documents/hazards/hazards-<session>.geojson`.
  Film every outdoor test with a second phone. Get the log off the phone in any of three ways:
  - Files app → On My iPhone → OpenCane (`UIFileSharingEnabled`), then AirDrop.
  - `make audit` pulls the newest log and measures it (it prints where it saved the copy).
  - By hand, with the phone plugged in, unlocked and trusted (`DEVICE` from `make devices`):
    ```sh
    xcrun devicectl device info files --device <DEVICE> \
      --domain-type appDataContainer --domain-identifier com.aritro.canekit --subdirectory Documents
    xcrun devicectl device copy from --device <DEVICE> \
      --domain-type appDataContainer --domain-identifier com.aritro.canekit \
      --source Documents/canekit-<stamp>.jsonl --destination ./canekit-<stamp>.jsonl
    ```
  In the simulator the same files are under
  `$(xcrun simctl get_app_container booted com.aritro.canekit data)/Documents/`.
- **Go / no-go before a blindfolded ISR → CIF walk.** Any miss means a sighted demo only.
  - GPS accuracy ≤ 20 m for 30 s at the ISR door. Fences and veer cues pause above 20 m, and the
    app says so.
  - A wall at 1 m reads 0.8–1.2 m in all six tiles.
  - The head cue re-fires with a hand overhead, and "Head height." is spoken.
  - Beacon left/right is correct after Recenter.
  - The watch tap is felt wrist-down.
  - Repeat on the watch re-speaks the last line.
  - Arrival fires at CIF east within 20 m.
  - Battery is > 40 % and thermal is nominal or fair.
  - A route start speaks the warm-up state and waits for trusted LiDAR depth; on a fast healthy
    session, the three-frame bar clears in well under a quarter second after the first good reports.
  - A spotter is assigned and the kill-word ("stop") is rehearsed.

### Automation environment variables

The app reads these at launch (`ProcessInfo.processInfo.environment`). In the simulator pass them
with the `SIMCTL_CHILD_` prefix (`SIMCTL_CHILD_CANEKIT_MUTE=1 xcrun simctl launch booted
com.aritro.canekit`); for XCUITests set them in `app.launchEnvironment`, or as `TEST_RUNNER_…` in
xcodebuild's environment (the Makefile does this). None of them is set on a normal launch.

| Variable | Effect | Set by |
|---|---|---|
| `CANEKIT_MUTE=1` | `SpeechQueue.muted`: speech keeps its timing and trip-log records but makes no sound, and the beacon stays silent. Automation must never make noise on the Mac (AGENTS.md "How we engineer" 4). | `scripts/e2e.py` |
| `CANEKIT_UITEST=1` | Everything `CANEKIT_MUTE` does, plus `AppModel.start()` skips the location permission request. | `CaneKitUITests`, `CaneKitVisualTour` |
| `CANEKIT_DEMO_ROUTE=1` (or the `--demo-route` argument) | Starts the bundled ISR → CIF route at launch. The argument exists because `devicectl` launches on a device sometimes dropped environment variables. | `scripts/e2e.py`, manual replays |
| `CANEKIT_FRAME_DIR=<dir>` | Simulator only: `FrameReplay` uses the Street View frame nearest the GPS position as the camera (needs `frames.json` in `<dir>`). | `make uitest-streetview`, `e2e.py --scenario streetview` |
| `CANEKIT_HAZARD_WATCH=1` | Turns the hazard watch on without touching the UI. | `e2e.py --scenario streetview` |
| `CANEKIT_DESCRIBE_EVERY_WAYPOINT=1` | Asks "Where am I" at the start and at every waypoint. | `e2e.py --scenario streetview` |
| `CANEKIT_SHOTS=<dir>` | Where `CaneKitVisualTour` writes its PNGs (test runner side). | `make tour` |
| `CANEKIT_SENSOR_PROBE=1` (or `--sensor-probe`) | Debug: a one-shot "what can run with LiDAR" measurement before `DepthEngine` starts; results are `probe_*` trip-log records. | by hand |
| `CANEKIT_SENSOR_SELFTEST=1` (or `--sensor-selftest`) | Debug: shows the sensor self-test buttons on the Hazards card. Never in the demo build. | by hand |

## 6. Gotchas

- **Depth map orientation.** `sceneDepth.depthMap` is 256×192 landscape in sensor orientation.
  With the phone upright, the buffer is the scene rotated 90° CCW: `bufferX = sceneY`,
  `bufferY = (H-1) - sceneX`. The Mount toggles "Phone held upright (portrait)" and "Mirror left /
  right" exist for this. Verify with a hand at the left edge.
- **CVPixelBuffer.** Lock before reading, unlock in `defer`, and use `CVPixelBufferGetBytesPerRow`
  (rows are padded). Retain exactly one camera buffer for the snapshot. Retaining `ARFrame`s makes
  ARKit drop frames.
- **Ground and mount tilt.** The bottom 25 % of the upright image is skipped (`LaneMath`
  `groundSkipFraction`) so pavement isn't a permanent obstacle. There is no gravity correction, so
  the mount must aim the camera 3–8° below the horizon: the Mount card shows "Camera tilt N° down"
  live. Fix the mount before touching `groundSkipFraction`.
- **Sweep gate.** Frames with |gyro| ≥ 0.6 rad/s are untrusted. The cue decider freezes and emits
  nothing, and the grid pill reads SWEEPING.
- **Foreground only.** ARKit stops when the app is backgrounded or the screen locks. The app sets
  `isIdleTimerDisabled = true`. Use Guided Access for the demo (how to arm it:
  `docs/devices_setup.md`, untethered demo step 4). Keep
  a power bank on the strap, since ARKit + LiDAR run ≈ 3–4 h.
- **Thermal.** `.serious` or worse turns off mesh classification, and with it the obstacle names.
  Lanes and haptics never stop. (Obstacle names are also off by default since Step 36, and the cue
  level decides which ones are spoken when they are on.)
- **xcodebuild hangs after "Test Suite … passed".** Seen with `make tour` / `make uitest-streetview`
  when old test-runner processes were left on the simulator (hours old). The tests themselves had
  passed. Fix: `xcrun simctl shutdown all`, then rerun. `make e2e` relaunches the app itself and is
  not affected.
- **Fence radii come from the route file.** Most waypoints use 15 m, turns (WP3, WP6, WP8) use
  12 m and arrival (WP9, CIF) uses 20 m. Before you touch a fence, veer or speech rule, read
  `AGENTS.md` → "Things that look wrong but are deliberate".
