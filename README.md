# OpenCane (54FoundersHack) — retrofit smart-cane kit

Clip a phone onto the white cane you already own. The iPhone (LiDAR + ARKit) is the brain and the haptic
engine; the Apple Watch carries turn cues; AirPods Pro carry the audio beacon and speech. "Phone-only" means
no ESP32 grip and nothing to buy — the Watch and AirPods Pro the team already owns are part of the demo.

- `docs/ideas.md` — the plan: verdict, pushbacks, form factor, software architecture, ISR→CIF demo, pitch.
  **§9 is the current decision: phone-only, buy nothing.** §3–4 (ESP32 grip, buy list) are historical.
- `ios/` — **CaneKit**, native iOS 26 app + watchOS companion (Swift 6, SwiftUI). See `ios/README.md`
  for the build/sign/install workflow and the step-by-step build log in `CHANGELOG.md`.
- `ios/stretch/` — CoreBluetooth client for the ESP32 grip. Not in any target. Stretch only.
- `firmware/`, `cad/` — ESP32 grip firmware and OpenSCAD drafts. Stretch only; ignore for the hackathon.

Owners: Aritro = software. Sagar = 3D printing + cane hardware.

Hackathon: Sat Sep 12 – Sun Sep 13 2026, Champaign-Urbana.
