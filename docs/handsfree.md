# Driving OpenCane without looking at the screen

The phone is clamped to the cane. You cannot see it and usually cannot reach it. Everything below
is done by **speaking**, or by **one press of the Action button**. Nothing here needs the screen.

> The app is **OpenCane** on the phone and in every spoken phrase; the code, the Xcode project and
> the build product are still called CaneKit (AGENTS.md, "The name split"). Siri phrases interpolate
> the *display* name, so what you say is "… in OpenCane".

If you only read one thing: say **"How is OpenCane doing"** to hear whether the app is actually
working, and set the **Action button** to **Talk to OpenCane** (steps at the bottom).

---

## 0. The voice shell — talking to OpenCane itself

Siri needs the app's name in every phrase. Inside the app you do not: OpenCane has its own short
phone menu (Steps 56–59).

- **Open the app.** It says "OpenCane ready." and then a soft rising two-note: the microphone is
  open. That is all (Step 67 — no menu at launch, not even on the first launch). Say a word from the
  list below, a question, or where you want to go. "help", "menu" or "options" reads the list.
- **Say where you want to go, in your own words** (Step 67). "I want to go to Grainger", "how do I
  get to CIF", "directions to the Union", "can you take me to Siebel please", "I just wanna get from
  here to Granger library" — a travel verb followed by "to" and a place. It is matched on the phone,
  never sent to the network: you hear "Finding a route to …" and then the route intro. "from ISR to
  CIF" with a real starting place walks the indoor script first (§1c). "Grainger please" alone is not
  enough — say a travel verb.
  Everyday verbs — "go to", "get to", "walk to", "going to", "how do I get to" — only work for the
  campus places OpenCane knows (CIF, ISR / Townsend, Grainger, the Union, Siebel, the Main Library,
  the ARC…), so "I need to get to class" or "I have to go to work" never starts a route. Anywhere else
  needs a navigation verb: "take me to Green Street", "navigate to Target", "directions to …", "walk
  me to …", "bring me to …", "get me to …" (review round Steps 67–68).
- **Emergency in any sentence.** "emergency", "there's an emergency", "take me to emergency", "call
  911" all ask "Say yes to call <your contact> at <number>." — it calls your emergency contact after a
  yes, never 911 itself. "Not an emergency", "cancel emergency" and "the emergency exit" do not.
- **Stop politely.** "please stop", "stop please", "stop navigation please" end the route like "stop".
- **Camera Control and the volume buttons** ask "Where am I", but not in the first 5 seconds after
  launch, not while the microphone is open, and not within 2 seconds of the last description they
  started; three presses within 1.5 seconds are a grip and do nothing — a hand gripping the phone used
  to set off descriptions nobody asked for (Step 67). One press during the launch is not lost: the
  description starts once "OpenCane ready." and the listen are over, unless you said something
  meanwhile (review round Steps 67–68).
- **Tap the middle of the screen to talk.** The Guide page is one giant microphone surrounded by
  rings (at least 60 % of the page). The rings ripple while it listens and breathe while it speaks.
  Say one word; it stops listening by itself 1.5 s after you finish.
- **Words and digits both work.** "status" and "four" are the same. "help" reads the numbered list.
- **The eight words never go to the network.** They are matched on the phone, as the whole thing you
  said: "route" starts the route, "the route is long" does not.
- **Quick answers, or an honest wait.** An open question goes to the cloud model: a faint tick at
  1.5 s (and once more at 4 s) while it thinks, and an answer or a low double tap + "No answer." by
  8 s (Step 67; it was 4 s, and the cloud took 6–17 s on every logged question). Ask something new
  at any time — the newest question wins, the old answer is thrown away.
- **What you hear instead of words (Step 65, calm feedback).** Every sound is under 0.18 s, quiet,
  and comes with a soft tap on the cane; none plays over "Head height.".

  | Sound | Means |
  |---|---|
  | soft rising two notes | the microphone is open — talk (quieter after an answer: you *may* talk) |
  | one short high tap | heard you |
  | soft falling two notes | heard nothing (the second time in a row it also says "I did not catch that.") |
  | faint tick | still working — a slow answer, or obstacle detection warming up before a route (at most three) |
  | two soft same taps | still describing the last scene; this one was dropped |
  | gentle bell | a long answer follows, or the route is starting ("Starting.") |
  | low double tap | that did not work — "No answer." |

  A listening window the app opened by itself (at launch, after an answer) that hears nothing closes
  with no sound at all.

## 1b. The eight words

| Say | or | What happens |
|---|---|---|
| **route** | one | Starts the recorded Townsend Hall → CIF route. While walking: says where the route is. ("take me to Grainger" still goes anywhere.) |
| **where am I** | two | Describes what the camera sees ("Looking." first). |
| **describe** | three | The same description. |
| **status** | four | The whole status report: obstacle detection, GPS, audio, haptics, route, battery. |
| **repeat** | five | Says the current instruction again. |
| **quiet** | six | Quiet cues ("Quiet cues."). "standard" and "detailed" switch back. |
| **help** | seven | Reads the list: "One, route. Two, where am I. … Eight, emergency. Or say stop to end the route." |
| **emergency** | eight | Asks first: "Say yes to call <name> at <number>." Only **yes** within 8 seconds calls (the phone leaves OpenCane). "no", "cancel" or silence → "Emergency canceled." It never calls on one word. |

Also: **next** (skip a waypoint), **stop** (end the route — exact phrases only: "stop", "stop route",
"stop navigating", "end route", "cancel route"). Homophones are deliberately not commands: "won",
"to", "for" do nothing, because a false hit acts.

## 1c. Indoors first: from a room to the outdoor route (Step 62)

GPS does not work inside a building, so the walk out of it is a short spoken step script, counted by
the phone's pedometer, and the outdoor GPS route takes over once you are outside.

- **Say "take me from ISR to CIF"** (also "from Townsend to CIF", "go from the lab to CIF", "take me
  to CIF from ISR"). If the place you start from has an indoor route, OpenCane reads its first step
  ("Start in the Townsend first floor south corridor. …"). A route nobody has walked yet begins with
  "Draft route. Use your cane."
  A starting place with no indoor route is an ordinary "take me to CIF".
- **Walk.** Each step's line comes a little before its count is reached (so a turn is announced
  before the turn); landmarks ("The main desk is on your right.") come about two thirds of the way.
- **next** skips to the next step (a door, a lift, a count that ran short); **repeat** says the
  current step again; **status** says "Indoors: step 3 of 5."; **stop** ends it. The watch's Next and
  Repeat, and the Guide's Repeat | Next | Stop route, do the same.
- **At the door** it says "You are at the ISR front doors. Go outside and wait a moment for GPS."
  Step outside: after three good GPS fixes near the door the outdoor route starts by itself (its own
  first line names the doors).
- **Say "I'm outside"** ("I am outside", "we're outside", "outside now") if it has not started. With a
  recent usable fix the outdoor route starts at once; otherwise you hear "Waiting for GPS outside."
  and it starts on the first good fix.
- To CIF the outdoor leg is the recorded route; to anywhere else it is an Apple Maps walking route
  from where GPS finds you.
- ⚠ Keep the screen on for the indoor part: with the phone locked the pedometer and GPS pause, and
  the handover waits until you unlock.

### Recording an indoor route (a sighted teammate, once)

1. Settings → **Record indoor route**. Leave **Route id** as `isr_townsend_to_front_doors` to replace
   the ISR floor-plan draft (its name, spoken origins and exit line are kept), or type a new id.
2. Stand where the walk starts, facing the way to go, phone held (or clamped) as it will be walked.
   Tap **Start recording**.
3. Walk to the exit door at a normal pace. Turns are detected by themselves (a turn you hold for
   1.5 seconds); do not spin the phone to look around.
4. At each thing worth saying, tap **Add landmark** and say it in one sentence ("The personal lab is
   on your left."). It is attached to the step you are on.
5. Step just outside the exit door and tap **Finish at the exit**. Hold still up to 8 seconds while
   it averages the GPS.
6. Tap **Save**. It says "Indoor route saved. N steps." The draft's "not walked yet" warning is gone.
   **Start indoor route** on the same card walks it straight away to check it.



Say them to Siri. Every phrase has to contain the app's name — that is Apple's rule for app
shortcuts, not ours. Several wordings work for each command; the first one listed is the shortest.

| Say this | What happens |
|---|---|
| **"Where am I in OpenCane"** — or "OpenCane describe the scene" | One sentence about what the camera sees: what is there, and whether it is on the left, in the centre or on the right. A measured LiDAR distance is added in front if the sensor has one. |
| **"Ask OpenCane about the scene"** — or "Ask OpenCane a question" | Siri asks **"What do you want to know?"** Say your question ("is there a bench on my left", "what does that sign say"). One sentence back. |
| **"How is OpenCane doing"** — or "OpenCane status", "Is OpenCane working", "Check OpenCane" | The spoken version of the whole screen: obstacle detection, GPS, AirPods, cane haptics, route, battery. Always in that order. |
| **"Take me to Grainger in OpenCane"** (CIF, ISR, Grainger, the Illini Union, Siebel, the Main Library, the ARC) | Walks you there from where you are. |
| **"Take me somewhere in OpenCane"** | Siri asks where; say any place ("Starbucks on Green Street"). |
| **"Talk to OpenCane"** — or "Speak to OpenCane" | Opens the app and starts listening. Ask anything below, or "Take me to CIF", "How is my battery?", "What is in front of me?". This is also the Action button target (section 3). |
| **"Start my route in OpenCane"** — or the legacy phrase "Start the demo route in OpenCane" | The recorded ISR Townsend Hall → CIF route. |
| **"Repeat in OpenCane"** — or "OpenCane say that again" | Says the current instruction again. |
| **"Next waypoint in OpenCane"** | Skips to the next instruction. |
| **"Stop the route in OpenCane"** — or "Stop navigating in OpenCane" | Ends guidance, and cancels a destination search still running. |
| **"Silence the cane in OpenCane"** — or "Silence haptics in OpenCane" | Stops the cane buzzing, and tells you where obstacle cues go instead (the watch, or spoken). Stand still for a few seconds after: the confirmation speaks first and spoken obstacle cues queue behind it. |
| **"Turn cane haptics on in OpenCane"** | Buzzing back on. |

Since Step 68 a route start is short: "Starting.", then "Route to <place>." and the first instruction.
It says a status line only when it changes what you do (the cane cannot buzz, so obstacle cues move to
the watch or to speech). No headphones or an unreachable watch are on the Guide card and in the "status"
answer, not spoken. If the AirPods disconnect during a route you hear "AirPods disconnected." once.
"GPS weak." is said about 10 seconds after GPS goes bad outdoors (never during indoor steps), and again
no sooner than a minute later; "GPS back." after 10 good seconds, at most once every two minutes.
Standing still with good GPS says nothing. When something is right in front of you (the
centre tile turns red) you hear "Close." once.

### Three more commands, in the Shortcuts app

These exist but do not have a Siri phrase of their own — Apple allows an app only **ten** automatic
phrases and the list above uses all ten. They are in the **Shortcuts** app under OpenCane, and you
can put any of them on the Action button (section 3) by first making a one-step shortcut around it:

- **Recenter the beacon** — sets the way you are facing now as the beacon's "straight ahead". The
  watch has a Recenter button, and the app re-zeroes itself after a few seconds of walking
  straight, so you rarely need this.
- **Turn a feature on or off** — drop-off detection, sign reading, the hazard watch, naming people
  ahead, obstacle names, the audio beacon, listening for sirens and horns, or nod to talk (eight
  features, `HandsFreeOption`). It says the new state
  out loud, and turning one **off** always says what stops with it ("Obstacle names off. Obstacles
  are still felt on the cane, but not named."). It reads the state back from the app rather than
  from what you asked for, so a feature that refuses to start — a denied microphone, for instance —
  is never announced as on.
- **Navigate to CIF from here** — walking directions to the CIF east entrance, wherever you start
  (the Guide card button does the same thing). Its Siri phrase moved to "Take me to CIF in
  OpenCane" when its shortcut slot went to "Talk to OpenCane".

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
5. Pick **OpenCane** → **Talk to OpenCane**

That is the whole path.
(Apple Support, ["Run shortcuts with the Action button"](https://support.apple.com/guide/shortcuts/run-shortcuts-with-the-action-button-apdfea15680b/ios).)

Press once: OpenCane opens and starts listening (you feel the tick). Ask ("Take me to CIF",
"How is my battery?", "What is in front of me?"). Press again — or just stop talking — and it
answers. "Talk to OpenCane" is an App Shortcut, so it is in the picker with no setup.

**Which one to bind: "Talk to OpenCane."** It covers everything the other shortcuts do —
status, scene questions, places, posts — conversationally, with no wake word and no screen.
"Where am I" is the second choice if you want one fixed command that never needs the
microphone: it is useful at every moment of a walk, with or without a route running.

All ten OpenCane shortcuts appear in that picker with no setup, because they are App Shortcuts.
The Shortcuts-app-only actions (Recenter, Turn a feature on or off, Navigate to CIF from here)
do **not** appear there directly — to put one of those on the Action button, first make a
one-step shortcut in the Shortcuts app that runs it, then choose that shortcut in step 5.

If **Talk to OpenCane** is missing from the picker after reinstalling: open the Apple Shortcuts
app once (this forces iOS to re-index the app's shortcuts), then repeat step 5. A phone restart
is the last resort — the shortcut list is cached by the system, not by OpenCane.

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

**Latency (Step 57, calm feedback Step 65, Step 67).** A question to the cloud model has an 8-second
budget (4 s until Step 67: every cloud answer on the logged walks took 6–17 s, so 4 s turned almost
every question into "No answer."). Navigation never waits on it: a spoken destination is routed on
the phone (§0). Silence past a second reads as "it did not hear me", so a short tap confirms the
microphone heard you, and a faint tick plays at 1.5 s and once more at 4 s; at 8 s the app gives up with a low double tap
and "No answer." A second question while the first is still thinking cancels the first — its answer,
if it arrives, is never spoken, and makes no sound. The trip log shows each turn with `budget_ms`,
`filler_spoken` (a tick played), `superseded` and `timed_out`, and every tone as `earcon`.

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
