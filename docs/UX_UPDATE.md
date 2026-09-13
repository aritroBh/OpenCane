# UX update — OpenCane is a conversation, not a dashboard

Status: **what Step 62 shipped**, written 2026-09-13. The argument lives in [`UX.md`](UX.md). This
file is the walker-facing changelog of that argument: what you can say today, what the screen still
does, and what is still a helper-only form.

Read with: [`UX.md`](UX.md) (the rules), [`handsfree.md`](handsfree.md) §0 / §1c (the phrases),
[`design.md`](design.md) (the visual system — the screen is not going away).

---

## 1. Why buttons are the wrong primary interface

The walker is blind. One hand holds a cane that is sweeping. The phone is **clamped to the cane
shaft**, screen out, about 95 cm off the ground and tilted about 45°. It is not in a hand and it is
not at a reading angle.

A button asks for three things in sequence: know it exists, know where it is, land on it. A sighted
user gets all three from one glance. A blind user gets none of them from the screen, so VoiceOver
substitutes a serial scan — swipe, hear a label, swipe, hear a label. The Guide page used to carry
eleven controls and the Sense page ten switches. Reaching "Hazard watch" is on the order of twenty
swipes with a thumb on a phone strapped to a moving cane. During those twenty swipes the walker is
either standing still in public or walking while not attending to the path.

That is why this update exists. **Every function a walker needs while moving is one spoken
utterance. The screen is a spotter's dashboard and a safety net, never the only way to do
something.**

## 2. What shipped

### Two tiers, not one longer menu

| Tier | What it is | When you use it |
|---|---|---|
| **1 — eight words** | route, where am I, describe, status, repeat, quiet, help, emergency (and the digits one to eight) | While walking. Short, unambiguous, spoken at launch. |
| **2 — everything else** | settings, cue level and place, flashlight, "read my settings", "what can I say", "read my medical ID", voice-only / full screen | While standing. Longer, discovered by asking. |

The split is the point. Mixing thirty settings phrasings into the eight words would dilute the
thing a walker has to remember in traffic.

### The voice-only screen

A Settings switch — **Voice-only screen** — that removes the tab bar and every secondary Guide
control and leaves the microphone, the instruction and the last answer.

It ships **off**. Not because it is wrong, but because "the walker can no longer reach Recenter
with a finger" needs a walk on the mounted cane before it is a default.

Two things survive on purpose, and both are safety:

- **Stop route**, while a route guides. Ending guidance must never depend on a recogniser working.
- **Show buttons.** Voice-only hides the tab bar and the Settings switch with it. A mode whose only
  exit is the phrase "full screen" is a trap the moment the microphone fails. Say **full screen**,
  or tap the button.

### Say-what-changed

Every state change speaks its consequence. "Read my settings" speaks the cue level, the place,
whether cane haptics are silenced, whether the voice-only screen is on, then every switch grouped
on / off, and ends with **"Head-height warnings are always on."** — because there is deliberately
no switch for that, and its absence from a list would otherwise read as off.

## 3. What you can say (the short list)

The full tables are in [`handsfree.md`](handsfree.md) §1b and §1c. The shapes:

- **"route"** / **"where am I"** / **"status"** / **"repeat"** / **"help"** / **"emergency"**
- **"turn on the beacon"**, **"turn off hazard watch"**, **"flashlight on"**
- **"standard cues"**, **"detailed"**, **"indoors"**, **"outdoors"**
- **"read my settings"**, **"what can I say"**, **"read my medical ID"**
- **"voice only"** / **"full screen"**
- **"stop"** still ends a route, and only that. It is never an off-verb for a feature.

A bare noun is **not** a command. "beacon?" is a question. Turning a warning channel off because
someone named it is the failure this grammar exists to avoid.

## 4. What is still a helper-only form

These stay on the screen, on purpose:

- **Editing the Medical ID or a family contact.** Dictating a blood type or an emergency phone
  number on a sidewalk is both a privacy leak and a transcription risk with a first-responder
  consequence.
- **Mount and camera experiments** (portrait, mirror left/right, 60 fps, both cameras, live view,
  head tracking without AirPods). A sighted helper sets these up once. A false hit mid-route pauses
  obstacle detection.
- **Family-alert wiring** (webhook, contact emails). Same privacy argument.
- **The safety floor.** Nothing a walker can say turns off "Head height.", the head haptic, or the
  ground-hazard *warning* path.

`UX.md` rule 1 ("every control has a spoken form") is therefore **not** closed. The first cut
covers everything a walker changes while walking or standing with the cane. Helper-only setup
stays a form. That gap is tracked, not pretended away.

## 5. How to try it

1. Launch OpenCane. Hear "OpenCane ready." and the eight-word menu.
2. Tap the giant microphone, or use the Action Button set to **Talk to OpenCane**.
3. Say **"what can I say"**, then **"read my settings"**.
4. Settings → Voice: **Read my settings** and **What can I say** are the same lines as buttons, for
   a sighted helper. **Voice-only screen** is off. Flip it, then say **full screen** or tap
   **Show buttons**.
5. Do **not** treat a quiet-room recognition rate as evidence. The first walk on the mounted cane
   is what settles whether tier 2 is too chatty (`make audit` on that log).

## 6. What would disprove this

Copied from `UX.md` §5, because it is the part a later agent must not drop:

- A walk with tier 2 in use that pushes lines-per-minute past `docs/auditory-load.md`.
- A walk log where "what can I say" is never spoken — the grammar is then invisible.
- A walk in voice-only mode that ends with the walker unable to recover.
- A trip log where a warning channel went off without the walker meaning it (`option_set`).

A handheld log must not tune a distance. A quiet room must not tune a recogniser.
