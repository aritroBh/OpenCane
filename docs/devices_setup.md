# AirPods + Apple Watch — setup and what the app does about them

The phone is the computer; AirPods and the watch are optional channels that must *degrade*, never
break the walk. This page is the human checklist plus what CaneKit does on its own.

## AirPods (beacon, speech, head tracking)

**Do once, before the demo**
1. Pair the AirPods to the iPhone (Bluetooth settings). Any AirPods give you the beacon and private
   speech; **head tracking needs AirPods Pro (any gen), AirPods Max or AirPods 3rd gen** — those have
   the motion sensor `CMHeadphoneMotionManager` reads.
2. Settings → Bluetooth → (i) next to the AirPods → **Spatial Audio: Off** and **Head Tracking: Off**
   for the demo. CaneKit does its own spatialisation (HRTF) and its own head tracking; the system
   version fights it and re-centres on its own schedule.
3. Settings → Bluetooth → (i) → **Automatic Ear Detection: On** (default). Taking one AirPod out
   pauses system audio; CaneKit keeps running — put it back in.
4. Motion & Fitness permission: CaneKit asks at route start ("uses motion to … track your head
   direction with AirPods"). Tap **Allow**. If you tapped Don't Allow: Settings → Privacy & Security
   → Motion & Fitness → CaneKit → On.
5. Charge them. The beacon click is continuous while navigating; budget ~4 h.

**What the app does**
- Detects the headphone route (`AudioRouteMonitor`). At route start it says "No headphones. Beacon
  paused until AirPods connect." when you are on the speaker; when they connect mid-route it says
  "<name> connected." and re-arms head tracking; on disconnect: "Headphones disconnected. Beacon
  paused." Speech keeps going out of whatever is connected (the cane speaker if nothing is).
- The beacon only renders into headphones (a spatial click from a speaker on a stick is noise).
- Head tracking is relative: the Guide card shows **Head tracked** when AirPods motion data flows,
  **Compass only** otherwise (still works — the click pans with the phone's compass). **Recenter**
  (phone button, watch button) zeroes "straight ahead"; the app also auto-recenters after 3 s of
  walking straight following each waypoint.
- Phone call or Siri mid-route: speech and beacon resume when the interruption ends.

**Sanity check (AirPods in, standing still)**: Start demo route → click should sit to one side; turn
your body until the click goes silent → you are facing the first leg. Turn your head left with the
body still → click moves right. Press Recenter → silent again.

## Apple Watch (wrist taps, Repeat / Next / Describe / Recenter)

**Do once, before the demo**
1. Watch paired to this iPhone, unlocked, **Wrist Detection: On** (Watch app → Passcode) — haptics
   don't play with wrist detection off.
2. Developer Mode on the watch (Settings → Privacy & Security → Developer Mode) — needed to install
   the CaneKit watch app from Xcode / the Watch app.
3. Install the watch app: it rides inside the phone app. With **Watch app → General → Automatic App
   Install: On** it appears on the watch after `make run`; otherwise Watch app → Available Apps →
   CaneKit → Install.
4. Open **CaneKit on the watch once** and accept the Health permission (it runs a walking workout
   session so haptics work with the wrist down). If you decline, it falls back to a runtime session
   and cues may stop when the screen sleeps.
5. Before the walk: open CaneKit on the watch. The phone's Watch card must say **Reachable** (it says
   **Asleep** when the watch app is not in front, **Not paired** when there is no watch).

**What the app does**
- Turn / crossing / arrival cues go to the wrist (distinct patterns: turnLeft `.directionUp`,
  turnRight `.directionDown`, crossing `.notification`, arrived `.success`). Obstacle cues mirror to
  the wrist automatically when the phone can't buzz (engine down or Silence haptics on) or when
  "Mirror obstacle cues to the watch" is on.
- At route start the phone says "Watch not reachable. Open CaneKit on the watch." if the watch is
  paired but the app is not in front. Status (instruction + distance) is pushed as application context
  so the watch catches up when it wakes.
- Crown: three detents within a second = Next. Buttons: Repeat, Next, Describe, Recenter. A `.retry`
  tap means the phone was unreachable; `.failure` is reserved for head-height obstacles.

**Sanity check**: phone Watch card → Left / Right / Cross / Arrive buttons → four different taps on
the wrist. Lower the wrist for 30 s → tap still arrives.

## Untethered demo (phone only, no laptop)

Nothing in CaneKit talks to the Mac at runtime. The Mac only signs and installs.

1. **Install with the cable, then unplug.** `make run` once (phone + watch app). A free personal team's
   install is valid for **7 days**, so installing Friday covers Saturday. Launch it once while plugged
   in to accept "trust developer" and the permission prompts (Location at launch; Motion and Health at
   the first route start; Health again on the watch).
2. **Warm the voice cache on Wi-Fi.** Start the demo route once indoors with Wi-Fi: every route line
   and common phrase is pre-synthesized with ElevenLabs into the app's Caches folder, so the walk
   plays them instantly even with weak cellular. Warnings ("Head height.") always use the system voice
   the first time rather than wait for the network. No network at all → the system voice for
   everything; guidance still works.
3. **What needs the network during the walk:** only "Where am I" (VLM) and any ElevenLabs line not
   already cached. GPS, LiDAR, haptics, beacon, watch, Live Activity are all on-device.
4. **Phone settings for the walk:** screen stays on by itself while CaneKit is open (the app disables
   auto-lock; ARKit stops if the screen locks). Turn on **Guided Access** (Settings → Accessibility →
   Guided Access; triple-click the side button in CaneKit) so a brush against the clamped screen cannot
   leave the app or hit Stop. Low Power Mode **off** (it throttles GPS and ARKit). Battery > 40 %, power
   bank on the strap.
5. **Secrets ride inside the app.** `ios/CaneKit/Resources/Secrets.plist` is copied into the .app at build
   time, so fill in the ElevenLabs / Muse keys *before* `make run`.

## If something is off

| Symptom | Fix |
|---|---|
| "Compass only" with AirPods Pro in | Motion & Fitness permission denied → Settings → Privacy → Motion & Fitness → CaneKit |
| Click comes from the phone speaker | AirPods not the active route: pick them in Control Center → audio output |
| Beacon direction wrong after a turn | Press Recenter while facing the walking direction |
| Watch says Asleep | Raise wrist / open CaneKit on the watch; check Wrist Detection |
| No wrist taps at all | Watch app not installed (Watch app → Available Apps) or Health permission declined on the watch |
| Voice is the robotic system voice | ElevenLabs key missing in Secrets.plist, or no network (falls back offline) |
