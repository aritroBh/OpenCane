# Driving OpenCane without looking at the screen

The phone is clamped to the cane. You cannot see it and usually cannot reach it. Everything below
is done by **speaking**, or by **one press of the Action button**. Nothing here needs the screen.

> The app is **OpenCane** on the phone and in every spoken phrase; the code, the Xcode project and
> the build product are still called CaneKit (AGENTS.md, "The name split"). Siri phrases interpolate
> the *display* name, so what you say is "… in OpenCane".

If you only read one thing: say **"How is OpenCane doing"** to hear whether the app is actually
working, and set the **Action button** to **Where am I** (steps at the bottom).

---

## 1. The ten spoken commands

Say them to Siri. Every phrase has to contain the app's name — that is Apple's rule for app
shortcuts, not ours. Several wordings work for each command; the first one listed is the shortest.

| Say this | What happens |
|---|---|
| **"Where am I in OpenCane"** — or "OpenCane describe the scene" | One sentence about what the camera sees: what is there, and whether it is on the left, in the centre or on the right. A measured LiDAR distance is added in front if the sensor has one. |
| **"Ask OpenCane about the scene"** — or "Ask OpenCane a question" | Siri asks **"What do you want to know?"** Say your question ("is there a bench on my left", "what does that sign say"). One sentence back. |
| **"How is OpenCane doing"** — or "OpenCane status", "Is OpenCane working", "Check OpenCane" | The spoken version of the whole screen: obstacle detection, GPS, AirPods, cane haptics, route, battery. Always in that order. |
| **"Take me to Grainger in OpenCane"** (CIF, ISR, Grainger, the Illini Union, Siebel, the Main Library, the ARC) | Walks you there from where you are. |
| **"Take me somewhere in OpenCane"** | Siri asks where; say any place ("Starbucks on Green Street"). |
| **"Navigate to CIF from here in OpenCane"** | Walking directions to the CIF east entrance, wherever you start. |
| **"Start my route in OpenCane"** — or "Start the demo route in OpenCane" | The recorded ISR Townsend Hall → CIF route. |
| **"Repeat in OpenCane"** — or "OpenCane say that again" | Says the current instruction again. |
| **"Next waypoint in OpenCane"** | Skips to the next instruction. |
| **"Stop the route in OpenCane"** — or "Stop navigating in OpenCane" | Ends guidance, and cancels a destination search still running. |
| **"Silence the cane in OpenCane"** — or "Silence haptics in OpenCane" | Stops the cane buzzing, and tells you where obstacle cues go instead (the watch, or spoken). |
| **"Turn cane haptics on in OpenCane"** | Buzzing back on. |

Before the route starts the app already says out loud which channels are live, and it speaks when
the AirPods connect or disconnect. You do not have to ask for those.

### Two more commands, in the Shortcuts app

These exist but do not have a Siri phrase of their own — Apple allows an app only **ten** automatic
phrases and the list above uses all ten. They are in the **Shortcuts** app under OpenCane, and you
can put either of them on the Action button (section 3):

- **Recenter the beacon** — sets the way you are facing now as the beacon's "straight ahead". The
  watch has a Recenter button, and the app re-zeroes itself after a few seconds of walking
  straight, so you rarely need this.
- **Turn a feature on or off** — drop-off detection, sign reading, the hazard watch, naming people
  ahead, obstacle names, the audio beacon, or listening for sirens and horns. It says the new state
  out loud, and turning one **off** always says what stops with it ("Obstacle names off. Obstacles
  are still felt on the cane, but not named."). It reads the state back from the app rather than
  from what you asked for, so a feature that refuses to start — a denied microphone, for instance —
  is never announced as on.

---

## 2. What the status answer means

"How is OpenCane doing" always answers in the same order, so you can stop listening once your clause
has gone by:

1. **Obstacle detection** — "Obstacle detection on, 9 frames per second." If it says *"running but
   no depth frames are arriving"*, the camera is covered or the session is stuck: **the cane is not
   being watched** even though nothing is warning you.
2. **GPS** — "GPS good, within 8 meters." Over 20 m it says "GPS weak" and tells you the waypoint
   cues are paused. That is the same 20 m at which the route engine stops trusting a fix.
3. **Audio** — "AirPods Pro connected, head tracking on", or "No headphones. Speech is on the phone
   speaker and the beacon is paused."
4. **Cane haptics** — on, silenced, or unavailable. When the cane cannot buzz it always says where
   obstacle cues went instead.
5. **Route** — running (with the current instruction and the metres left), or not.
6. **Battery** — and "Battery low" at 20 % or under.

It never says the path is clear. Nothing in this app ever says the path is clear: only your cane and
the obstacle warnings speak for the ground in front of you.

---

## 3. Putting OpenCane on the Action button

The Action button is the long ridged button above the volume buttons on the left edge of an iPhone
15 Pro or later. Holding it runs one thing. This is the most reliable hands-free trigger on the
phone — it needs no wake word, works in a noisy street, and cannot be set off by the cane knocking
the pavement.

**Steps** (a sighted helper can do this once, or you can do it with VoiceOver):

1. **Settings**
2. **Action Button**
3. Swipe left or right through the list of actions until you reach **Shortcut**
4. Tap **Choose a Shortcut**
5. Pick **OpenCane** → **Where am I**

That is the whole path.
(Apple Support, ["Run shortcuts with the Action button"](https://support.apple.com/guide/shortcuts/run-shortcuts-with-the-action-button-apdfea15680b/ios).)

**Which one to bind: "Where am I."** It is the only command that is useful at every moment of a
walk, with or without a route running, and it is the one you want *now* rather than after a Siri
round trip. "Status check" is the second choice if you are debugging the kit rather than walking
with it.

All ten OpenCane shortcuts appear in that picker with no setup, because they are App Shortcuts. The
two extra actions in section 1 (Recenter, Turn a feature on or off) do **not** appear there
directly — to put one of those on the Action button, first make a one-step shortcut in the
Shortcuts app that runs it, then choose that shortcut in step 5.

### ⚠ The Action button and the lock screen

**A press on a locked phone will ask you to unlock first.** Every OpenCane intent opens the app —
it has to, because obstacle warnings only run while the app is in front — and Apple requires the
device to be unlocked before any app is brought to the foreground, whatever the shortcut is
(Apple DTS, [developer forums 779977](https://developer.apple.com/forums/thread/779977): *"`openAppWhenRun`
requires the customer to unlock the device, because the app is being brought to the foreground."*).

That matters on a cane, because Face ID is looking at the sky, not at you. **So: unlock the phone
and leave OpenCane open before you start walking.** While it is running and frontmost, the Action
button answers in about a second. The app keeps the screen awake during guidance, and the demo
checklist in `docs/devices_setup.md` has the Guided Access setup that keeps it there.

---

## 4. What does *not* work, and why

Worth knowing so you do not waste time on it:

- **AirPods stem press / squeeze.** Not bindable. iOS owns every stem gesture (play/pause, skip,
  noise control, Siri) and there is no public API for an app to claim one; the only thing an app
  ever sees is a standard media transport event, and only while it is the "Now Playing" app
  ([MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)).
  The AirPods Pro head nod / shake is likewise only for answering Siri and notifications. Use the
  Action button or Siri.
- **Back Tap** (Settings → Accessibility → Touch → Back Tap) *can* run a shortcut, and Apple's own
  Magnifier uses a back double-tap for more detail. But it gives no confirmation that it fired, it
  is sensitive to cases and mounts, and nobody has tested it on a phone being struck through a cane
  clamp all day. **Untested here — do not rely on it for the demo.**
- **Voice Control** (the accessibility feature, not Siri) is built around numbered items on a screen
  you can see, and Apple's own support has told users it does not reliably run alongside VoiceOver.
  It is the wrong tool for this.
- **Siri while walking** works, but it is the least reliable of the three: it needs the wake word
  heard over traffic, and it sometimes activates without answering. That is exactly why the Action
  button is the recommended primary trigger and Siri is the backup.

---

## 5. Asking a question — what it will and will not do

"Ask OpenCane about the scene" sends one camera frame and your question to the vision model and
speaks **one sentence**. It is deliberately not a conversation: there are no follow-up questions and
nothing is remembered between asks.

That is a design decision, not a limitation of the plumbing. Blind users studied at CHI 2026
("Say It My Way") reported AI answers running more than ten times longer than their question, to the
point of "can't process at all", and wanted brevity most when they were in a hurry — which is every
moment of a walk. Conversational video assistants are also measurably weakest on moving scenes
([arXiv 2508.03651](https://arxiv.org/abs/2508.03651)). Be My Eyes reached the same conclusion in
their product: fixed "Describe Quickly / Normally / Fully" phrases plus one separate "Ask Question",
not an open chat.

The answer is held to the same rules as "Where am I":

- **No numbers from the model.** If it tries to tell you a distance or a count, that is refused —
  the only distance you ever hear is one the LiDAR measured.
- **No names the camera did not read.** A street name the model invented is refused.
- **Never "it's clear".** The model is not allowed to tell you the way is safe, in any wording.
- If the answer is refused, you hear **"I can't answer that. What I can describe is: …"** — the
  description is labelled, on purpose, so it can never be mistaken for the answer to your question.
  ("I can't answer that. Sidewalk with trees ahead." would sound like *"…because there is no
  bench."*, which is an inference nobody measured.)
- If there is no cloud key set up, it says so and describes the scene instead — the on-device model
  cannot read a question.

An answer is spoken at the lowest priority of anything the app says. An obstacle warning, a route
instruction or "Head height." will cut it off mid-sentence. That is correct.

---

## 6. Still needs the screen

Honest list of what has no spoken equivalent yet, all of it setup rather than walking:

| Control | Where |
|---|---|
| Phone held upright (portrait), Mirror left / right, 60 fps camera | Main screen |
| Write trip log | Main screen |
| Mirror obstacle cues to the watch | Watch card |
| Test haptic patterns (left / centre / right / head), Speech test, send a test wrist cue | Haptics and Watch cards |
| Head tracking without AirPods | Hazards card — it restarts the camera session, so it is a bench setting |
| Both cameras | Hazards card — **it pauses obstacle detection**, so it is deliberately not available by voice |
| Live camera view, the self tests | Hazards card — for a sighted helper |

Set those once with help, before you leave.
