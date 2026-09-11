# OpenCane: a smart-cane kit that clips an iPhone onto the cane you already own

OpenCane clamps an iPhone to a white cane and turns the phone into the only computer in the kit.
Its LiDAR sees obstacles between waist and head height, which the cane tip misses. Its Taptic
Engine shakes the cane to warn about them. GPS and a waypoint engine guide the walk. AirPods Pro
play a spatial beacon that clicks from the direction to walk, and speak instructions. An Apple Watch
taps turns and crossings onto the wrist and carries Repeat / Next / Describe / Recenter. Nothing
needs to be bought (the phone mount is 3D-printed), and the kit runs **untethered on the phone**.

**CaneKit** is the app: native iOS 26 SwiftUI, Swift 6 strict concurrency, Apple frameworks only.
It lives in [`ios/`](ios/).

Hackathon (54FoundersHack): Champaign-Urbana, Sat Sep 12 – Sun Sep 13 2026. Team: **Aritro** (software),
**Sagar** (hardware, 3D printing, CAD), **Aarav**.

> **Teammates: after `git pull`, read [`docs/TEAM_BRIEF.md`](docs/TEAM_BRIEF.md) (2 minutes), then
> [`docs/TEAM_HANDOFF.md`](docs/TEAM_HANDOFF.md).** It says
> what is proven, what is not, who does what next, the mount angle, and which decisions are final.

## The demo

A cane user walks from **ISR Townsend Hall to CIF** on the UIUC campus. The route is 9 waypoints,
989 m, with three street crossings: out the ISR front doors, west on Illinois St, north on Goodwin,
west on Springfield, then to the CIF east entrance. On the way:

- Wrist taps come before every turn and crossing.
- The beacon keeps the heading between waypoints.
- Veer cues fire if the user drifts off course.
- The cane buzzes for obstacles ahead and at head height.
- "Where am I" describes the scene: a cloud vision model when a key is set, otherwise on the phone
  (Apple Vision + Apple's on-device language model), so it works offline.
- The camera reads safety signs ("Sign: sidewalk closed.") on the phone, the LiDAR can warn about
  curbs and drop-offs (off by default until tuned on the cane), and every hazard lands on a
  shareable GeoJSON map.
- On arrival the phone speaks a summary of distance, minutes and steps.

Any other destination works through MapKit walking directions. The route and its evidence are in
[`docs/route_isr_cif.md`](docs/route_isr_cif.md). Go / no-go criteria for a blindfolded walk are in
[`ios/README.md` §5](ios/README.md#5-testing).

## Hardware

| Part | Role |
|---|---|
| iPhone 17 Pro Max (iOS 27) | The only computer. LiDAR depth, Core Haptics through the cane, GPS + compass, camera for "Where am I" |
| Non-metal stick, 28.75 mm shaft | The cane |
| Printed phone mount | Clamps the phone to the shaft. See [`hardware/mount/DESIGN.md`](hardware/mount/DESIGN.md) and [`hardware/README.md`](hardware/README.md). |
| AirPods Pro | Spatial-audio beacon, speech, head yaw for the beacon |
| Apple Watch | Wrist taps for turns / crossings / arrival, Repeat / Next / Describe / Recenter, crown = Next |
| Power bank on the strap | ARKit + LiDAR run ≈ 3–4 h on the phone battery |
| Mac with Xcode 27 RC | Signs and installs only. Nothing talks to it at runtime. |

The ESP32 haptic grip and ToF sensor pod (`firmware/`, `cad/`, `ios/stretch/`) were cut on Sep 10
and are stretch goals only.

## Repo map

| Path | What |
|---|---|
| [`docs/TEAM_HANDOFF.md`](docs/TEAM_HANDOFF.md) | **Read first after a pull.** State of the project, what is proven, who does what, final decisions. |
| [`AGENTS.md`](AGENTS.md) | **Read before editing.** Hard rules and the deliberate behaviours that look like bugs. `CLAUDE.md` is its short form. |
| [`docs/README.md`](docs/README.md) | Index of every doc, plus a "Where do I find…" table |
| [`docs/CODE_REFERENCE.md`](docs/CODE_REFERENCE.md) | Map of every file, type and function, with the data-flow diagram |
| [`CHANGELOG.md`](CHANGELOG.md) | Build log, one entry per step, each with its "test on device" list |
| [`ios/`](ios/) | CaneKit: iPhone app, watch app, Live Activity widget, `Logic/` SwiftPM package with the unit tests, UI tests, XcodeGen spec, Makefile. See [`ios/README.md`](ios/README.md). |
| [`docs/`](docs/) | Design system, device setup, route evidence, todo checklist, stress-test plan, ideas and pitch |
| [`hardware/`](hardware/) | Physical kit: phone mount design and print notes |
| `firmware/`, `cad/`, `ios/stretch/` | ESP32 grip firmware and OpenSCAD drafts. Stretch only. |
| `graphify-out/` | Knowledge graph of the repo (code + docs, ~1,860 nodes; `GRAPH_REPORT.md`, `graph.html`). Query it with `graphify query "<question>"`; refresh with `graphify update .` after code changes. |

## Quick start

**Mac.** You need Xcode 27 RC with the watchOS platform, plus `brew install xcodegen`. The full
day-0 list is in [`ios/README.md` §1](ios/README.md#1-day-0-checklist).

```sh
cd ios
make test      # 146 logic tests; works with the Command Line Tools alone
make gen       # generate CaneKit.xcodeproj; creates the git-ignored Secrets.plist from the template
make sim17     # once: create the iPhone 17 Pro Max / iOS 27 simulator
make sim       # simulator build
make uitest    # XCUITests on that simulator
make tour      # one screenshot per screen state → ios/build/shots
make e2e       # GPS replay of the demo route through the real app (~20 min; SCENARIO=clean for one)
```

**Phone.** Turn on Developer Mode on the iPhone and the Watch, and add your Apple ID in Xcode
(Settings > Accounts; a free Personal Team). After `make gen`, open `ios/CaneKit.xcodeproj` once,
select the CaneKit target > Signing & Capabilities and pick the Personal Team: that creates the
Apple Development certificate. The Team ID is shown in Xcode > Settings > Accounts > the team's
details, or read it from the certificate: the `OU=` value printed by
`security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`. (The 10
characters in parentheses of an "Apple Development: Name (…)" identity are not the Team ID.) Then:

```sh
cd ios
make devices                       # find the phone's identifier
# create ios/local.mk (git-ignored):
#   TEAM   = ABCDE12345            # the OU= value from the Apple Development certificate
#   DEVICE = 00008150-…            # from make devices
make run                           # gen + build + install + launch
```

Put API keys (ElevenLabs voice, "Where am I" model) in `ios/CaneKit/Resources/Secrets.plist`
**before** `make run`, because the file is bundled into the app. Never commit it. Without keys the
app uses the system voice and describes scenes on the phone. Then follow
[`docs/devices_setup.md`](docs/devices_setup.md) for the AirPods, the watch and the untethered demo
(warm the voice cache on Wi-Fi, turn on Guided Access, battery above 40 %).

## Links

- [`docs/TEAM_HANDOFF.md`](docs/TEAM_HANDOFF.md): start here after a pull
- [`AGENTS.md`](AGENTS.md): rules for anyone editing the repo
- [`ios/README.md`](ios/README.md): build, sign, secrets, testing, gotchas
- [`docs/README.md`](docs/README.md): every doc, and where to find things
- [`docs/devices_setup.md`](docs/devices_setup.md): AirPods + Apple Watch + untethered demo checklist
- [`docs/design.md`](docs/design.md): UI and cue design system
- [`docs/todo.md`](docs/todo.md): what's still open
- [`docs/stress_test_plan.md`](docs/stress_test_plan.md): device tests, failure injection, go/no-go, demo run sheet
- [`hardware/README.md`](hardware/README.md): the printed phone mount (Sagar)
- [`docs/ideas.md`](docs/ideas.md): why phone-only (§9), pitch, prior art
