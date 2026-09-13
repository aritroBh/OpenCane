# UX.md — why OpenCane's interface is a conversation, not a screen

Status: **design spec, written 2026-09-13.** It is the argument and the rules for the voice-first
UX; `CHANGELOG.md` Step 62 and the `ux/voice-first` branch are the first implementation of §4.
Numbers marked **[H]** are hypotheses, not measurements — the standing rule in this repo is that a
cue number may only be tuned from a trip log taken on the mounted cane (`AGENTS.md` → "Measure
first"). Nothing here overrides `AGENTS.md`; where they disagree, `AGENTS.md` wins.

Read with: `docs/design.md` (the visual design system, still true — the screen is not going away),
`docs/handsfree.md` (Siri / Action Button), `docs/auditory-load.md` and `docs/cue_design_v2.md` (how
much speech a walking blind person can absorb — the budget this spec spends).

---

## 1. The problem, stated plainly

The walker is blind. One hand holds a cane that is sweeping. The phone is **clamped to the cane
shaft**, screen out, roughly 95 cm off the ground and tilted about 45° — it is not in a hand and it
is not at a comfortable reading angle. The other hand may hold a dog's lead, a coffee, or a door.

A button asks for three things in sequence: know it exists, know where it is, land on it. A sighted
user gets all three from one glance. A blind user gets none of them from the screen, so VoiceOver
substitutes a **serial scan** — swipe, hear a label, swipe, hear a label. That is a reasonable trade
in a mail app. It is a bad trade here, for a specific measurable reason: the Guide page currently
carries eleven controls and the Sense page ten switches, so reaching "Hazard watch" is on the order
of twenty swipes with a thumb on a phone strapped to a moving cane. During those twenty swipes the
walker is either standing still in public or walking while not attending to the path.

The first cane-mounted walk (`canekit-2026-09-13T04-36-32Z.jsonl`) is the evidence that started
this: the app was usable only with eyes. That log is what produced the Step 56–59 voice shell — the
eight-word spoken menu (`VoiceMenu`) and the giant microphone (`VoiceTile`). This document is the
rest of that idea, applied to the whole app rather than the launch screen.

### What is already true (do not rebuild it)

| Shipped | Where |
|---|---|
| Eight spoken words + digit aliases: route, where am I, describe, status, repeat, quiet, help, emergency | `VoiceMenu` (CaneKitLogic) |
| A giant microphone, ≥ 60 % of the Guide page height, tap anywhere on its rings to talk | `VoiceTile` |
| Sub-millisecond on-device command matching before any cloud call | `FastPathIntentClassifier` rule 0 |
| Some settings by voice (haptics, beacon, drop-offs, hazard watch, nod to talk) | `FastPathIntentClassifier` rules 2–5b |
| Siri phrases and the Action Button | `HandsFreeIntents`, `docs/handsfree.md` |
| Wrist taps: Repeat / Next / Describe / Recenter | `ios/CaneKitWatch` |
| One voice for every line, cache → 2.5 s race → system voice | `VoiceEngineChoice`, Step 54 |
| The app never answers its own voice | `SelfHearFilter`, Step 55 |
| Priority bands, clause-accurate resume, a 0.35 s pause between bands | `SpeechQueue`, `SpeechResume` |

## 2. The thesis, and its limits

**Every function of OpenCane must be reachable by one spoken utterance. The screen becomes a
spotter's dashboard and a safety net, never the only way to do something.**

That is the thesis. The rest of this section is what is wrong with it, because a spec that only
argues for its own conclusion is not worth following.

- **A false hit acts.** A misheard button press does nothing; a misheard command starts a route,
  turns off a warning channel, or dials a phone. This is why `VoiceMenu` matches **whole utterances
  only** and refuses homophones ("won" is not "one"). Widening the grammar widens the blast radius,
  so every new command must state what a false hit costs, and anything that costs a lot gets a
  confirmation (`EmergencyConfirm` is the model).
- **Speech is not private.** "Emergency", a home address, a blood type and a family contact's name
  are all things a walker may not want to say on a sidewalk, and the reply is louder still. Voice
  must never become the *only* way to reach private data: the Medical ID edit form stays.
- **Recognition fails exactly when it matters.** Wind, traffic, a bus, a crowd. The failure is
  correlated with the situations where the walker most needs the app. A voice-only app with no
  physical fallback is a worse app, not a better one.
- **The ear is a single channel and it is already busy.** It carries the beacon, the route lines,
  obstacle names and the safety warnings, on the budget measured in `docs/auditory-load.md`. Every
  spoken menu, confirmation and read-back spends from the same budget as a curb warning. The
  microphone also makes the app deaf to itself for the duration (`SelfHearFilter`), and the
  `.voiceInput` lease moves the audio session — which is why hard rule 7 forbids `.voiceChat` and
  Bluetooth HFP, and why the beacon dies if anyone "fixes" that.
- **Latency is real.** On-device matching is sub-millisecond, but the recogniser needs the walker to
  finish the utterance and the natural voice may take a 2.5 s race. A cue must never wait behind
  any of it. `.safety` breaks through everything, including the voice hold, and that stays true.

So the design is **voice-primary, physically-redundant**: every command has a voice form, and the
handful of commands that matter while moving also have a form that needs no speech at all (a wrist
tap, the Action Button, the microphone's own giant target).

## 3. Rules

These are meant to be checkable in review, not aspirations.

1. **Voice completeness.** Every control on every screen has a spoken form. A switch that can only
   be flipped by finding it on the Sense page is a bug, tracked like any other.
2. **Say-what-changed, not "done".** A blind walker cannot see which switch moved, and "the cane
   stopped buzzing because I turned something off" versus "because it broke" is the whole safety
   question. Every state change speaks its consequence, which is what `HandsFreeOption.offConsequence`
   already does. New commands supply the same.
3. **A read-back replaces a settings screen.** "Read my settings" speaks the state of everything, in
   the order the screen shows it. The walker should never have to *look* to find out what is on.
4. **Discovery is spoken.** "Help" reads the numbered list; "what can I say" reads the wider grammar.
   No command exists that is not reachable from one of those two, and both are in
   `SpokenPhrases.shellLines` so they come out in the natural voice.
5. **Whole-utterance matching, no homophones, narrow aliases.** The `VoiceMenu` rules apply to every
   new grammar. A command that must accept free text (a destination) does so only behind an explicit
   prefix ("take me to …").
6. **Destructive or public actions confirm.** Ending a route, dialling a contact, and turning off a
   warning channel each need either a second utterance or a spoken consequence the walker can
   countermand. Never a silent success.
7. **The safety floor is not voice-controlled away.** "Head height.", LiDAR ground hazards and the
   `.head` haptic are not switchable by voice, at any cue level. This is already true of the cue
   levels (`CueProfile`) and stays true here.
8. **The screen stays useful and stays honest.** A sighted teammate reads the instruction over the
   walker's shoulder during the demo, and `make tour` / `make island` are how UI regressions get
   caught. Voice-first means the screen stops being *required*, not that it stops being *correct*.
9. **A voice feature that is not tuned on the cane ships off by default** (hard rule: `AGENTS.md` →
   "Safety beats features"). The owner flips the switch after a walk, not the code.
10. **Accessibility labels remain a test contract** (`AGENTS.md` rule 9). Voice-first work does not
    get to quietly rename a label the XCUITests drive; change them together or not at all.

## 4. The design

### 4.1 One screen, three states

The Guide page is the app. Its centre is the microphone, and everything else is subordinate:

```
        instruction  (the one line a spotter reads)
        distance     (hero number, only with a GPS fix)
        pills        (GPS / dark / beacon — spotter information)
   ┌───────────────────────────────┐
   │                               │
   │      ◉  the microphone        │   ≥ 60 % of page height, one tap target
   │   (rings ripple / breathe)    │
   │                               │
   └───────────────────────────────┘
        "Say route, where am I, or help."
        the last answer
        [ two buttons, situational ]        ← the physical fallback, never the primary path
```

- **Idle** — the microphone, and two buttons: Where am I, Start route to CIF.
- **Guiding** — the microphone, and three: Repeat, Next, Stop route.
- **Voice-only** — the microphone and nothing else (§4.4).

Everything further down the page — Recenter, Simulate walk, Navigate to CIF from here, the
destination field, the beacon and head pills — is *below the fold on purpose*. It is for the sighted
helper and the demo. It is not how a walker works the app.

### 4.2 The grammar, in two tiers

**Tier 1 — the eight words** (`VoiceMenu`, shipped, tuned, do not change): route, where am I,
describe, status, repeat, quiet, help, emergency, each also its digit one to eight. These are the
things a walker needs *while moving*, so they are short, unambiguous and spoken in the launch line.

**Tier 2 — everything else** (`VoiceControlGrammar`, §4.3): the settings, the cue level and place,
the read-backs, the flashlight. These are things a walker sets up *while standing*, so they may be
longer and more conversational, and they are discovered by asking rather than memorised.

The split is the point. A tuned eight-item list stays eight items; the long tail goes somewhere it
cannot dilute the eight.

### 4.3 Tier 2 — what a walker can say

| Say | Effect | Cost of a false hit |
|---|---|---|
| "read my settings", "what is on" | speaks every switch, in screen order | none — read-only |
| "what can I say", "list commands" | speaks the tier-2 grammar | none — read-only |
| "turn on/off <feature>" for each of the eight `HandsFreeOption`s | the switch, plus its spoken consequence | **high** for the four warning channels — always speaks `offConsequence` |
| "standard cues", "detailed cues", "quiet" | `CueLevel` | low — the safety floor is identical at every level |
| "indoors", "outdoors" | `CuePlace` | low |
| "flashlight on/off" | the torch, KVO-confirmed | low, but it is a battery and a burn risk — never persisted |
| "read my medical ID" | speaks the Medical ID paragraph | **privacy** — it is read aloud in public, so it is never automatic |
| "cancel", "never mind" | drops the pending confirmation | none |

Deliberately **not** in tier 2:

- **"stop"** stays `FastPathIntentClassifier` rule 1, ahead of everything, exactly as it is.
- **Anything that edits the Medical ID or family contacts.** Dictating a blood type or an emergency
  contact's phone number on a sidewalk is both a privacy leak and a transcription risk with a
  first-responder consequence. Those stay a form, filled in with a helper.
- **Anything in the safety floor.** See rule 7.
- **"help me"** is not a synonym for "help". A walker in trouble says it, and reading a menu at them
  is the wrong answer.

### 4.4 Voice-only mode

A switch — "Voice-only screen" — that removes the secondary controls and the tab bar and leaves the
microphone, the instruction and the answer. It exists because the honest end state of this argument
is a screen with nothing on it to find, and because it is the layout to hand a walker who has never
used the app.

It ships **off**, per rule 9 and `AGENTS.md`. Not because it is wrong, but because "the walker can
no longer reach Recenter with a finger" is exactly the kind of claim that needs a walk before it is
a default. The owner flips it after one.

The mode is a **layout decision, not a feature flag scattered through the views**: one pure type in
`CaneKitLogic` answers "is this control visible", so the rule is testable without a simulator and
the views stay dumb.

### 4.5 Input redundancy

| Path | Reaches | Needs |
|---|---|---|
| The microphone tile | everything | one tap anywhere near the middle of the phone |
| Action Button / Siri | route, next, describe, status, the gazetteer places | no screen at all |
| Watch: tap and crown | Repeat / Next / Describe / Recenter | no phone at all |
| Nod to talk | starts listening | AirPods; off by default, untuned |
| The two situational buttons | the three or four things needed while moving | a finger, VoiceOver optional |

No single path is load-bearing. That is the answer to "recognition fails in wind".

## 5. What this costs, and what would disprove it

The honest failure modes of shipping §4, and the evidence that would settle each:

- **The ear runs out of budget.** Read-backs and consequences are long lines. `cue_audit.py` already
  reports lines per minute and suppressed lines; if a walk with tier 2 in use pushes those past the
  `docs/auditory-load.md` numbers, tier 2 is too chatty and the read-back needs shortening.
- **Recognition accuracy on a windy sidewalk is unmeasured.** Every accuracy claim in this document
  is **[H]**. What would settle it: a walk log with the recogniser's transcripts beside what was
  said, on the mounted cane, outdoors, with traffic.
- **Nobody discovers tier 2.** If "what can I say" is never spoken in a real walk log, the grammar
  is invisible and the launch line has to name it.
- **Voice-only mode strands the walker.** If a walk in voice-only mode ends with the walker unable
  to recover from a wrong state, the mode is wrong and the two situational buttons come back.
- **A false hit turns off a warning channel.** The one that would matter. It is why every off
  speaks its consequence, and why the trip log records `option_set` — a walk where a channel went
  off without the walker meaning it will be visible there.

## 6. How to verify a change to this surface

`make test` for the grammar (it is pure, so a rule with a phrase in it belongs in `CaneKitLogic`
with a test, exactly like a rule with a number in it), `make sim`, `make uitest` and `make tour` for
the screen, and `make e2e` when the speech path moved. Then, before believing any of it: a walk on
the mounted cane and `make audit` on the log. A handheld log must not tune a distance, and a quiet
room must not tune a recogniser.
