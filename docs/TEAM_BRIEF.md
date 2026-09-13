# Team brief: OpenCane / CaneKit at HEAD `076fcaa` (Sat 2026-09-12 evening)

The short version for Sagar, Tommy, Aarav and Tejas. The full picture is in
[`TEAM_HANDOFF.md`](TEAM_HANDOFF.md); start with its "Start here (5 minutes)" section. AI agents
resume from its §10.

## Status right now — read this first

- **`main` contains Steps 0–37** plus the per-camera rotation fix for Both cameras. The last day on
  the app line added:
  - root tabs Guide / Sense / Settings (27);
  - sound recognition that fails safe to off (28);
  - "Talk to OpenCane" on the Action Button and distance-first warnings (29);
  - speech that holds while you talk (30);
  - instant answers, "set location", Sift / Granger (31);
  - the flashlight (32, fixed in 34);
  - the cue design v2 research and the `make audit` script (35);
  - the **Cues** card (36);
  - "talk floor": a direction cut by "Head height." now resumes from where it was cut (37).
- **Automated gates at `076fcaa`** (CHANGELOG Step 37): `make test` **457/457** Logic tests;
  `make sim` green; `make uitest` **11 run, 10 passed, 1 skipped, 0 failures** (the skip is the
  Street View "Where am I" test, which the code runs only under `make uitest-streetview`);
  `make e2e` **PASS**; `cue_audit.py --selftest` ok. All on the iPhone 17 Pro Max / iOS 27
  simulator with Xcode 27.
- **Proven on the owner's iPhone 17 Pro Max today** (trip logs):
  - Cues level and place switching: each tap logged and spoken (22-20-53Z).
  - Both cameras started upright: back 90, front 0 (22-20-53Z).
  - The Step 34 bugs (flashlight needing two presses, the invisible both-cameras refusal, face
    tracking mid-route) were measured on 20-57-17Z and fixed.
  - Step 37 is installed on the phone.
- **Not yet checked on the phone:** the talk floor (37); Quiet / Indoors behaviour (36); Both
  cameras started sideways or flat; the Step 34 flashlight / caption / face-tracking fixes; and the
  older Step 25, 28–33 device lists. The list with exact steps is `TEAM_HANDOFF.md` §2.4.
- **The one thing that unblocks cue tuning: a walk with the phone ON THE MOUNT.** Every trip log so
  far was handheld (the first one: tilt median 25.8°, only 14 % of frames inside 3–8°), so no
  distance can be tuned from them. Walk 2 minutes mounted, plug in, `cd ios && make audit`; it must
  print "ON THE MOUNT".
- **Open work:** cue design v2 Steps 38–45 in [`todo.md`](todo.md) (head speech episodes, speech
  de-chop, speech budget, torso haptics by level, calm head alerts off by default, hush, "What's
  ahead?", indoor suggestion). None has started.
- Until the phone tests pass, **the blindfolded walk is a no-go**. A sighted demo is always the
  fallback.

## What changed for you

- **Obstacle names are off by default now** (Step 36). Turn on Settings → Haptics → "Speak
  obstacle names" if a test expects "Two meters ahead, door" (stress plan D6 says so).
- **Settings → Cues** is new and first on the Settings tab: **Quiet / Standard / Detailed** and
  **Outdoors / Indoors**, default Detailed + Outdoors. Changing it speaks once ("Quiet cues.",
  "Indoor mode."). Quiet and Indoors name nothing and read only safety signs; Indoors warns about
  head height at 1.2 m instead of 1.5 m. Since Step 41 the level also changes the cane's torso taps:
  Quiet none, Standard one tap at 1.5 m and a strong triple at 0.6 m, Detailed today's loop and
  side taps; head height is the same at every level.
- **Warnings say the distance first:** "Two meters ahead, door", not "door ahead, two meters".
- **"Head height." still cuts in at once.** The direction it cut now continues from its phrase
  after a short pause, instead of starting over.
- **Where things are:** Guide tab (route, Where am I); Sense tab (depth status, Obstacles, Hazards
  card with drop-offs, signs, hazard watch, sirens, live camera, Both cameras, Flashlight); Settings
  tab (Cues, Haptics, Watch, Mount, This phone).
- **A voice command can start a real route**, and a running route refuses Both cameras and head
  tracking without AirPods. Stop the route on the Guide tab first.

## Setup checklist (do these in order)

1. **Pull:** `git pull`, then `cd ios && make test` (457 Logic tests, Swift 6 / Xcode 27). Check the
   command's own exit code; never trust `make test | tail`.
2. **Natural voice (ElevenLabs): the key is not in the repo on purpose.** Open
   `ios/CaneKit/Resources/Secrets.plist` (git-ignored; `make gen` creates it from
   `ios/Secrets.example.plist`) and set `ELEVENLABS_API_KEY` (optionally `ELEVENLABS_VOICE_ID`).
   Rebuild and install after changing it, because the file is baked into the app. Without a key,
   Apple's voice speaks. A build from a git worktree gets an empty `Secrets.plist`.
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
6. **Action Button:** after `make run`, Settings → Action Button → Shortcut → **Talk to OpenCane**.
   If it is missing, open the Shortcuts app once and retry (`docs/handsfree.md`).

## Sagar and Tommy (hardware)

- [`hardware/README.md`](../hardware/README.md) has the quick start, the OpenSCAD models, test prints
  and a bench-test plan. The screwless mount's runbook is `hardware/mount_screwless/PRINTING.md`;
  run `scripts/verify_mount.ps1` after any `.scad` change.
- The prototype shaft is a broom handle measured at **27.65 mm** by the bore rings (28.75 is
  retired as `pole_d` in both mount models). Next prints: `coupons_next` (thread + dovetail clearances), then
  collar + ring, cradle, arm.
- The mount is yours to redesign however you like. The app needs only four things:
  - the phone upright with the back camera and LiDAR clear;
  - the camera aimed **3–8° down, about 5°, not 10–20°**, or the cane buzzes on an empty sidewalk;
  - firm enough that the buzz is felt in the grip, with nothing magnetic near the phone's bottom edge;
  - the cane shaft out of the camera's view.
- Settings tab → **Mount** card shows "Camera tilt N° down, good" live. Adjust until it says good.
- **A working mount is now the blocker for the software too:** cue tuning waits for one mounted walk.

## Aarav (walker)

- The on/off table in [`TEAM_HANDOFF.md`](TEAM_HANDOFF.md) §6 lists every default.
- Feel the haptic patterns and wear the watch: tests D2 and D11 in the stress plan.
- **The next walk that matters:** 2 minutes with the phone on the mount, then `make audit`. Then the
  survey walk, the reference walk and the blindfolded rehearsal.
- When you walk with Step 37 installed: mid-sentence, a "Head height." should be followed by a
  short pause and the rest of the direction, not the direction from the start. Say if it is not.

## If you change code

- Read [`AGENTS.md`](../AGENTS.md), especially "How we engineer": prove it before claiming it, write
  the test first in `ios/Logic`, have independent reviewers check every change (a multi-agent
  review, Muse, and Antigravity on a copy of the repo), keep new features off until they are tested
  on the cane, and update `CHANGELOG.md`, `docs/CODE_REFERENCE.md` and `docs/todo.md` in the same
  commit, with a `test on device:` line at the end of the commit message.
- The step-by-step resume checklist is `TEAM_HANDOFF.md` §10.
- To find anything: install the graph tool once with `uv tool install graphifyy`, then run
  `graphify update .` after any code change (the committed graph was built from `076fcaa`) and
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
7. After a walk: `make audit` copies the newest trip log off the phone (plugged in, unlocked,
   trusted) and prints how loud the walk was and whether it was on the mount.

## Known quirks

- Scene recognition can't be tested in the simulator at all ("Failed to create espresso context";
  a CPU-only attempt returned all 1,303 labels at ~0 confidence and was removed). Scene words are
  covered by `ios/scripts/vision_probe.swift` on the Mac, `SceneVocabularyTests` and the phone, so
  check "Where am I" on the phone first.
- `make tour` and `make uitest` can hang after passing: `xcrun simctl shutdown all` and retry.
- `make uitest` / `make tour` need a simulator location first
  (`xcrun simctl location <udid> set 40.1140,-88.2249`), and never run two simulator jobs at once.
- The CHANGELOG and commit messages call the one skipped UI test "needs a key"; the code skips it
  unless `CANEKIT_FRAME_DIR` is set, which `make uitest-streetview` does.

## Historical: status as written earlier on Sat 2026-09-12 (after Step 28)

Kept for context; superseded by the sections above.

- Main then contained Steps 0–28, including the camera-transition depth interlock, the
  sound-recognition lifetime guard and the merged conversational voice assistant / Action Button
  work, with 372 Logic test annotations.
- The review environment used for Steps 25 and 28 could not rerun the full gates (its Xcode 15.1 /
  Swift 5.9.2 was older than the package's Swift tools 6.0, and XcodeGen / CoreSimulator / Muse /
  Antigravity / graphify were not installed there). Steps 34–37 were verified with Xcode 27 on the
  owner's Mac (above).
- The first physical-phone desk test (Fri 2026-09-11): LiDAR, haptics, mesh object names ("table
  ahead"), the head-height cue, on-device "Where am I" (Apple Vision + Apple's on-device model; no
  key or network needed); depth at 30 reports/s, heat nominal. Fixed after it: a false "Hole ahead"
  while hand-held (ground hazards now need the mount's tilt), a 10 Hz timing bug, and "Where am I"
  mixing two moments.
- The Step 25 camera interlock and the Step 28 microphone guard were not device-validated then, and
  no trip log since has covered them; they are still on the `TEAM_HANDOFF.md` §2.4 list.
