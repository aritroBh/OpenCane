# Team brief: OpenCane / CaneKit, night before the demo (Fri 2026-09-11)

The short version for Sagar and Aarav. The full picture is in
[`TEAM_HANDOFF.md`](TEAM_HANDOFF.md); start with its "Start here (5 minutes)" section.

## Status right now (Fri 2026-09-11, ~15:30 CT) — read this first

- **Main branch is tested and pushed.** 243 logic tests pass; the app builds, installs and runs on
  Aritro's iPhone 17 Pro Max (iOS 27).
- **Proven on the real phone (desk test):**
  - LiDAR, haptics, mesh object names ("table ahead"), the head-height cue, on-device "Where am I"
    (Apple Vision + Apple's on-device model; no key or network needed);
  - depth at 30 reports/s, heat nominal.
- **Fixed after the phone test:**
  - false "Hole ahead" while hand-held (ground hazards now need the mount's tilt);
  - a 10 Hz timing bug;
  - "Where am I" mixing two moments.
- **In progress on branches (not merged yet; merged to main only after tests + reviews pass):**
  - `feat/voice-nav-search`: Siri voice control ("Hey Siri, take me to Grainger in OpenCane",
    "where am I", "repeat", "next", "stop"), a "Navigate to CIF from here" button, better
    destination search (campus place list + nearest result), a trip-log fix;
  - `feat/live-view-gpu`: smooth live camera view;
  - `feat/fm-image-describe`: "Where am I" from the image with Apple's model (iOS 27), off by default;
  - `experiment/gemma-cactus`: Gemma 4 E2B on-device via Cactus — experiment only.
- **The live checklist is `docs/todo.md` → "TONIGHT".** Every item is ticked only after it was
  verified.

## Setup checklist for tonight (do these in order)

1. **Pull:** `git pull`, then `cd ios && make test` (243 tests).
2. **Natural voice (ElevenLabs) — the key is not in the repo on purpose.** Open
   `ios/CaneKit/Resources/Secrets.plist` (git-ignored; `make gen` creates it from
   `ios/Secrets.example.plist`) and set `ELEVENLABS_API_KEY` (optionally `ELEVENLABS_VOICE_ID`).
   Rebuild and install after changing it, because the file is baked into the app. Without a key,
   Apple's voice speaks.
3. **Install on a phone:** see "Installing on the phone" below. Keep `ios/local.mk` values on their
   own lines; a comment after a value broke the first build.
4. **AirPods Pro:**
   - pair them;
   - Settings → Bluetooth → ⓘ → **Spatial Audio Off**, **Head Tracking Off** (OpenCane does its own);
   - allow Motion & Fitness when asked.
   - Full steps: `docs/devices_setup.md` → AirPods.
5. **Apple Watch:**
   - it must be paired with the same iPhone;
   - turn on Developer Mode on the watch (Settings → Privacy & Security; if it is missing, open
     Xcode → Window → Devices and Simulators with the iPhone plugged in until the watch appears);
   - in the iPhone's Watch app: General → **Automatic App Install**, or Available Apps → OpenCane →
     Install;
   - open OpenCane on the watch.
   - Full steps: `docs/devices_setup.md` → Apple Watch.

## State of things

- The app is done and tested on the Mac and simulator: 146 logic tests, UI tests, and replays of
  the ISR → CIF route, including missed turns, noisy GPS and wrong turns.
- **Nothing has run on the real phone yet.** That is tonight's job;
  [`stress_test_plan.md`](stress_test_plan.md) has the checklist and the schedule.
- Until the phone tests pass, the blindfolded walk is a no-go. A sighted demo is always the fallback.

## Sagar (hardware)

- [`hardware/README.md`](../hardware/README.md) has the quick start, the OpenSCAD model, test prints
  and a bench-test plan.
- The mount is yours to redesign however you like. The app needs only four things:
  - the phone upright with the back camera and LiDAR clear;
  - the camera aimed **3–8° down, about 5°, not 10–20°**, or the cane buzzes on an empty sidewalk;
  - firm enough that the buzz is felt in the grip, with nothing magnetic near the phone's bottom edge;
  - the cane shaft out of the camera's view.
- The app's Mount card shows "Camera tilt N° down, good" live. Adjust until it says good.

## Aarav (walker)

- The "on/off" table in [`TEAM_HANDOFF.md`](TEAM_HANDOFF.md) §6 lists which features are on by default.
- Tonight you feel the haptic patterns and wear the watch: tests D2 and D11 in the stress plan.
- Tomorrow: the survey walk, then the reference walk, then the blindfolded rehearsal.

## If you change code

- Read [`AGENTS.md`](../AGENTS.md), especially "How we engineer": prove it before claiming it, write
  the test first, have independent reviewers check every change, keep new features off until
  they are tested on the cane.
- To find anything: install the graph tool once with `uv tool install graphifyy`, then run
  `graphify query "your question"` from the repo root.

## Installing on the phone (Aritro)

1. Add your Apple ID in Xcode: Settings → Accounts.
2. `cd ios && make gen`, open `ios/CaneKit.xcodeproj` once, select the CaneKit target → Signing &
   Capabilities and pick the Personal Team (this creates the Apple Development certificate).
3. Find the Team ID in Xcode → Settings → Accounts → the team's details, or take the `OU=` value
   from `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`. The
   10 characters in parentheses of "Apple Development: Name (…)" are not the Team ID.
4. Turn on Developer Mode on the phone and the watch, plug in, and tap Trust.
5. `make devices`, then put `TEAM` (the Team ID) and `DEVICE` (from `make devices`) in
   `ios/local.mk`.
6. `make run`.

## Known quirks

- Scene recognition can't be tested in the simulator at all ("Failed to create espresso context";
  a CPU-only attempt returned all 1,303 labels at ~0 confidence and was removed). Scene words are
  covered by `ios/scripts/vision_probe.swift` on the Mac, `SceneVocabularyTests` and the phone, so
  check "Where am I" on the phone first.
- `make tour` can hang after passing: `xcrun simctl shutdown all` and retry.
