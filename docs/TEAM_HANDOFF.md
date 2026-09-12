# Team handoff: read this first after you pull

State of OpenCane / CaneKit after the Step 25 safety interlock and Steps 23–24 voice-assistant
merge, for Aritro, Sagar and Aarav. It says what exists, what is proven, what is not, what each of
us does next, and which decisions are already made so nobody re-litigates them at 2 a.m. Historical
claims below are labelled; current counts and build limitations are in the status table.

> **Latest status, branches in flight and tonight's setup checklist: [`TEAM_BRIEF.md`](TEAM_BRIEF.md)
> → "Status right now". Live checklist: [`todo.md`](todo.md) → "TONIGHT".** AI agents working in this
> repo: read `AGENTS.md` ("How we engineer" is the bar) and `CLAUDE.md` first, then this file, then
> query the graph (`graphify query "…"`); never merge an in-flight branch without its tests, a
> simulator build and a Muse + Antigravity review.

## 0. Start here (5 minutes)

1. `git pull`, then `cd ios && make test` (366 Logic tests with the Swift 6 toolchain).
2. Find your row in §3 and do its first item.
3. **Sagar:** open `hardware/README.md` → quick start. The mount is yours to change; the app needs
   only what §5 lists (phone upright, camera 3–8° down, firm, shaft out of view).
4. **Aarav:** read §6 (what is on/off) and the D2 / D11 tests in `stress_test_plan.md`; you will feel
   the haptic patterns and wear the watch.
5. **Anyone changing code:** read `AGENTS.md` (rules + "How we engineer") and ask the graph where
   things live: `graphify query "…"` (install once: `uv tool install graphifyy`).
6. Stuck? The symptom → fix tables are in `docs/devices_setup.md` and the gotchas in `ios/README.md` §6.

## 1. The one-paragraph version

An iPhone 17 Pro Max (iOS 27) clamped to a 28.75 mm non-metal cane is the only computer. LiDAR
warns about waist-to-head obstacles by shaking the cane (Core Haptics), GPS walks a 9-waypoint route
from ISR Townsend Hall to the CIF east entrance, AirPods Pro play a spatial click from the direction
to walk and speak the instructions, and an Apple Watch taps turns and crossings onto the wrist. New
since Step 11: the camera reads safety signs on the phone, "Where am I" works offline, the LiDAR can
warn about curbs and drop-offs, and every hazard lands on a shareable GeoJSON map. The demo runs
**untethered on the phone**; the Mac only signs and installs. Pitch and hardware: the root
[`README.md`](../README.md).

## 2. What is proven, and what is not

**Historical upstream verification (recorded before the current merge; rerun with Xcode 27):**

| Check | Result | How to rerun (from `ios/`) |
|---|---|---|
| Logic tests (every rule with a number in it) | 366 annotations in the current checkout; the historical green run was 146 | `make test` |
| App + watch + widget build, Swift 6 strict | historical green; current local Xcode 15.1 cannot build the Xcode 27 project | `make sim` |
| UI tests + screenshot tour | historical green; current simulator unavailable in this environment | `make uitest`, `make tour` |
| GPS replay of the whole route through the real app | 4 of 4 pass: clean, missed fence, ±6 m jitter, wrong turn | `make e2e` (~20 min, silent: the app mutes itself) |
| Real `NavigationEngine` in a scratch harness, 72 simulated walks | 0 false "Veer"; an injected 35° veer caught 18/18 | see CHANGELOG Step 11 |
| Street View camera stand-in (Google Street View frames of the route) | see §8 | `make e2e SCENARIO=streetview`, `make uitest-streetview` |

**Proven on the real iPhone 17 Pro Max (iOS 27.0), desk test on Fri 2026-09-11 afternoon** (trip
logs pulled off the phone):

| Check | Result |
|---|---|
| Signed, installed, launched (free Personal Team) | yes; runs unplugged |
| LiDAR depth, Taptic haptics, mesh classification | all available (`start` event) |
| Obstacle names from the mesh | "table ahead, very close", "seat ahead, two meters" |
| Head-height cue | fired and spoken ("Head height.") |
| On-device "Where am I" (no key, no network) | Apple Vision labels + Apple's on-device model, e.g. "Chairs and desks are ahead…" in 0.7 s |
| Depth reports | 30 per second (was 10: a timing bug the phone exposed; fixed) with the 1x camera at 60 fps |
| Heat | nominal during the test |
| Cameras available *with* LiDAR | only the 1x wide camera (up to 60 fps, 1920x1440); no 0.5x ultra-wide, no 120 fps; the front camera can run only as ARKit face tracking |

**Not proven yet (needs walking outdoors / the other devices):** LiDAR distances through the clamp,
how the haptics feel in the hand, the beacon's left/right, wrist-down watch taps, GPS fence timing on
campus, heat and battery over a 20-minute walk, and the new ground-hazard thresholds. That is what
[`stress_test_plan.md`](stress_test_plan.md) is for. Until those pass, **the blindfolded walk is a
no-go**; a sighted demo is always the fallback.

## 3. Who does what next

The hour-by-hour plan is [`stress_test_plan.md` §1.0](stress_test_plan.md#10-the-next-24-hours).
The app tests are D1–D18 and F1–F12 in that plan; the mount's own bench tests are T0–T11 in
[`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md). Do the mount's T-tests before D1. In short:

| Person | Tonight | Saturday |
|---|---|---|
| **Aritro** (software) | Add Apple ID in Xcode, Developer Mode on phone + watch, `make run` (§4). Bench tests D18 first, then D1–D8, D10, D11, D13, D15–D17. | Logs, fixes, code freeze ≥ 3 h before the demo walk, filming. |
| **Sagar** (hardware) | Render and print the mount (`hardware/README.md` quick start). Bench tests D1–D5 and D16 with the clamp. Set the tilt by reading the phone (§5). | Spotter on every walk. Power bank, sun shade, heat checks. |
| **Aarav** (walker) | Feel the haptic patterns (D2), wear the watch (D11). | Survey walk W1, reference walk W2, blindfolded rehearsal W4. |

## 4. Pull, build, install

```sh
git pull
cd ios
make test          # 366 logic tests; requires the Swift 6 toolchain
make gen           # generates CaneKit.xcodeproj (git-ignored) and Secrets.plist from the template
make sim17         # once per Mac: the iPhone 17 Pro Max / iOS 27 simulator
make sim           # simulator build
```

To put it on the phone (full list: [`ios/README.md` §1](../ios/README.md#1-day-0-checklist)):

1. Xcode → Settings → Accounts → add your Apple ID (a free Personal Team; installs last 7 days).
   After `make gen`, open `ios/CaneKit.xcodeproj` once, select the **CaneKit** target →
   **Signing & Capabilities** and pick the Personal Team. That creates the Apple Development
   certificate (before it exists, `security find-identity -v -p codesigning` lists nothing).
   The **Team ID** is shown in Xcode → Settings → Accounts → the team's details, or use the `OU=`
   value from `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`.
   The 10 characters in parentheses of "Apple Development: Name (…)" are **not** the Team ID.
2. Settings → Privacy & Security → **Developer Mode** on, on the iPhone **and** the Watch.
3. Plug the phone in, tap Trust, then `make devices` and create `ios/local.mk`:
   ```make
   TEAM   = ABCDE12345                # the OU= value from step 1
   DEVICE = 00008150-…                # from make devices
   ```
4. Keys (optional) go in `ios/CaneKit/Resources/Secrets.plist` **before** building; it rides inside
   the app. Never commit it. With no keys everything still works: the system voice speaks and
   "Where am I" runs on the phone.
5. `make run`. On the phone: Settings → General → VPN & Device Management → trust the developer
   app, then open OpenCane again.
6. If watch signing or pairing fights you, unblock the phone first: `WATCH=0 scripts/gen.sh`, then
   `make build install launch` (phone-only), and add the watch later ([`ios/README.md`](../ios/README.md)).
7. Follow [`devices_setup.md`](devices_setup.md) for AirPods, the watch, Guided Access and warming
   the voice cache on Wi-Fi (keys must already be in `Secrets.plist`).

## 5. The mount angle (read this, Sagar)

**The mount is yours.** `hardware/` is a starting point drafted on the software side (Apple's
dimensional drawings, a pitch model, an OpenSCAD model, test coupons); change anything with your own
CAD, ideas and printing experience. The app only needs these from any mount:

- the phone **upright (portrait)**, rear camera and LiDAR unobstructed and facing forward;
- the camera aimed **3–8° below the horizon** with the cane held normally (the app shows it live);
- firm enough that the phone's buzz is felt in the grip, and nothing magnetic near the phone's
  compass (bottom edge);
- the screen reachable for Guided Access, and the cane shaft out of the camera's view.

The camera must look **3–8° below the horizon, about 5°, not 10–20°.** The obstacle grid ignores the
bottom quarter of the image as "ground" without correcting for gravity. At 10° down or more the
torso lanes see bare pavement near 2 m and the cane buzzes on an empty sidewalk. Level or tilted
up, the drop-off detector loses its ground reference. The numbers are in
[`hardware/mount/DESIGN.md`](../hardware/mount/DESIGN.md) and `hardware/mount/pitch_model.py`.

You set it by reading the phone: the **Mount** card's first line says
`Camera tilt 5° down, good · N fps` (N is live, about 30). Hold the cane the way Aarav holds it and
click the hinge until it says **good**; chase "good", not the fps. The same number is in every
trip-log `lanes` line as `tilt`.

## 6. What is on, what is off, and why

| Setting (screen) | Default | Why |
|---|---|---|
| Obstacle cues on the cane (Haptics card: "Silence haptics" mutes them) | on | The core product. |
| Phone held upright (portrait) (Mount card) | on | The clamp holds the phone upright; turn off only if it is clamped sideways. |
| Mirror left / right (Mount card) | off | Turn on if a left obstacle buzzes as right (bench test D1). |
| Audio beacon while navigating (Mount card) | on | Plays only into headphones. |
| Write trip log (Mount card) | on | Every test needs a log; Files → On My iPhone → OpenCane. |
| **Detect drop-offs** (Hazards card) | **off** | New, untuned on a real cane. Turn on for bench test D1-style curb checks, then decide. |
| Read signs (Hazards card) | on | On-device, offline, speaks only safety / wayfinding phrases, once a minute each. |
| **Hazard watch** (Hazards card) | **off** | Every 8 s while walking; on-device labels are weak (see §8), the cloud needs a key and network. |
| Live camera view (Hazards card) | off | For a sighted helper and the demo video. |

## 7. Decisions already made (do not re-open without new evidence)

- **Phone-only, buy nothing.** The ESP32 grip, ToF pod (`firmware/`, `cad/`, `ios/stretch/`) are
  stretch only. Why: [`ideas.md` §9](ideas.md).
- **No Gemma / MLX on the phone.** Gemma 4 E2B/E4B would need third-party packages and a 2.5–3.6 GB
  download, and the only Swift port found is macOS-only. "Where am I" uses Apple Vision + Apple's
  on-device language model instead (template sentence when Apple Intelligence is off), with the
  cloud model first when a key is set.
- **Front camera unused.** It faces the walker on the cane, and ARKit owns the capture pipeline.
- **CI is manual-trigger only.** GitHub Actions billing is exhausted; the local `make` gate is
  authoritative ([`ios/README.md` §5](../ios/README.md#5-testing)).
- **Everything that looks like a bug but is deliberate** (fences firing early, veer muted at
  corners, the 30 s curb repeat, the arrival hint, …) is listed in
  [`AGENTS.md`](../AGENTS.md) → "Things that look wrong but are deliberate". Read it before
  "fixing" navigation, speech or hazards.

## 8. Google Street View mock of ISR → CIF

We cannot walk the route from a laptop, so 14 Google Street View captures of the route stand in for
the camera in the simulator (`FrameReplay`, simulator only, inert on the phone). The JPEGs are
**local-only (git-ignored, Google imagery)**; `ios/scripts/streetview/frames.json` lists where each
was taken and [`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md) says how to
capture your own.

| Command (from `ios/`) | What it proves |
|---|---|
| `swift scripts/vision_probe.swift scripts/streetview` | What the on-device camera would say at each corner (labels, text, sign line, hazard line), on the Mac |
| `make uitest-streetview` | "Where am I" answers with a sentence from a real street frame |
| `make e2e SCENARIO=streetview` | The clean route walked with the Street View frames as the camera; the report lists every sign / hazard line spoken |

What it found and fixed (details in `CHANGELOG.md` Step 12 and
[`ios/scripts/streetview/README.md`](../ios/scripts/streetview/README.md)): Vision taxonomy words read
aloud, Apple's on-device model inventing "Distance: zero meters", sign range (now measured: 7.5 cm
letters ≈ 7 m on a flat frontal sign), STOP signs and far storefront words, and a camera path the
log could not see.

**Diagnosed:** scene recognition cannot be tested in the *simulator* at all. Vision's scene
classification fails there with "Failed to create espresso context" (the simulator has no
neural-network context; the new `vision_error` field in the trip log's `describe_result` records
it). That is a simulator limit, not a phone bug: the same frames classify fine on the Mac
(`vision_probe.swift`), and the phone has the Neural Engine. A CPU-only fallback was tried and
removed again: it returned all 1,303 labels at ~0 confidence, so the Street View mock does not
exercise the scene words. Scene words are covered by `ios/scripts/vision_probe.swift` on the Mac,
`SceneVocabularyTests` (logic tests) and the phone. Still, **check "Where am I" on the real phone
first thing** (stress plan D17): it should name what is there ("Ahead: a crosswalk, …").

## 9. How to find anything

- **Install the graph tool once:** `uv tool install graphifyy` (or `pipx install graphifyy`); the
  command is `graphify`. The graph itself is committed in `graphify-out/`, so queries work right after
  a pull.
- **Ask the knowledge graph first:** from the repo root, `graphify query "how does a curb warning reach
  the speech queue"`, `graphify path "HazardScanner" "SpeechQueue"`, `graphify explain "TurnSettle"`.
  Communities are listed in `graphify-out/GRAPH_REPORT.md`; `graphify-out/graph.html` opens in a
  browser. After code changes: `graphify update .`.
- **Every file, type and function:** [`CODE_REFERENCE.md`](CODE_REFERENCE.md).
- **Every doc and when to read it:** [`docs/README.md`](README.md).
- **What landed when, and each step's device test list:** [`CHANGELOG.md`](../CHANGELOG.md).
- **What is still open:** [`todo.md`](todo.md).

## 10. How we work (read before changing anything)

The engineering bar is in [`AGENTS.md` → "How we engineer"](../AGENTS.md): evidence before claims,
test first for every rule with a number in it, adversarial reviews (multi-agent + Muse + Antigravity)
after every chunk with every finding verified before acting, silent end-to-end runs, new untuned
features off by default, and docs + graph updated in the same commit. Refresh the knowledge graph
after code changes with `graphify update .` (seconds, no API cost).

## 11. Known risks going into the walk

- None of Step 11 has run on a real phone. Treat drop-off warnings and the hazard watch as extras
  until D-tests pass; the lanes, haptics, route and watch are the product.
- Ramps steeper than ~11 % can read as a drop-off or step (the price of catching curb faces that
  fall mid-bin). ADA ramps (≤ 8.3 %) stay quiet in tests.
- The screen is exposed on the cane: use Guided Access so a brush cannot hit Stop. To arm it
  (Settings → Accessibility → Guided Access on, passcode set), triple-click the side button in
  OpenCane → Options: **Touch Off, Side Button Off, Volume Buttons Off, Keyboards Off, Motion On** →
  Start. While armed the watch (Repeat / Next / Describe / Recenter) is the only input. "Where am I"
  from the Action button may be blocked too (it is a hardware button; stress plan D16 records
  whether it works), so use the watch's Describe.
- ARKit stops when the screen locks; the app keeps the screen on while open.
- Compass readings on the cane are only trusted when the cane is still; while walking > 0.7 m/s the
  veer decision uses the smoothed GPS course.
- Tree canopy and buildings on Goodwin / Springfield can push GPS past 20 m; the app says "GPS weak"
  and pauses fences rather than guess.
- Reviews: five adversarial review rounds by Claude workflows, Muse and Antigravity. Every finding
  is either fixed or rejected with evidence in `CHANGELOG.md`. A review is not a device test.
