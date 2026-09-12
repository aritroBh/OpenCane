# Auditory load: what the research says, what OpenCane does

Why this file exists: a blind walker navigates by ear — traffic, echolocation, voices —
and every sound OpenCane makes competes with that. Collected 2026-09-12 after a device
report ("it keeps giving me instructions as I'm talking"). Read it before adding any new
automatic (unprompted) sound.

## What the literature says

- **Emit discontinuously, only on critical events.** A real-time visual–auditory
  substitution system for outdoor blind navigation states it as a requirement: signals only
  on danger or trajectory, at a rate adapted to walking speed, "to prevent overloading
  blind people's cognitive systems unnecessarily" (PMC 10781372).
- **Headphone audio masks the primary signal.** Continuous output through headphones
  degrades the use of ambient cues — traffic, echolocation, human voices — which blind
  users employ as primary environmental signals (MDPI, cognitive load-aware navigation
  framework, 2026).
- **Let the walker control the amount.** Blind testers asked to control the distance /
  angular range presented and the amount of auditory detail per situation: coarse in a
  park, detailed in a city (Springer, Journal on Multimodal User Interfaces, 2025).
- **Calibrate frequency, not just content.** Cue frequency and spatial encoding directly
  affect navigation performance (ibid.).

## What OpenCane already does about each point

| Research point | OpenCane answer |
|---|---|
| Discontinuous, critical-only | Speech is event-driven (waypoints, new obstacle class, new sign phrase, safety). Nothing speaks on a timer except the arrival hint. |
| Protect ambient hearing | Beacon + haptics carry continuous guidance; speech is the exception. Every narration channel has an off switch (obstacle names, people, signs, beacon, siren watch). |
| Walker controls the amount | Sense-tab toggles per channel; Silence-haptics routes cues to watch/speech; Repeat recovers anything missed. |
| Don't talk over the walker | Voice input holds the speech channel (`SpeechQueue.setVoiceHold`): everything below `.safety` queues with its TTL while dictating; `.safety` still breaks through. Also keeps the recogniser from hearing the app's own voice. |
| Distance before identity | All warnings lead with time-to-contact ("Two meters ahead, door") — the number decides whether to stop now. |

## Open questions (for walks with a blind / O&M-trained tester, not guesses)

1. Is the 7 s obstacle-name calm window (`SpeechLoadPolicy`) too chatty or too quiet?
   Tune only from trip-log `speech_suppressed` counts + missed-obstacle reports.
2. Does the beacon's continuous presence mask traffic at crossings? The crossing
   silence ("Listen for traffic") is the current answer; verify on a real street.
3. Should sign announcements get a global per-minute cap? **Not done on purpose**: a cap
   could suppress a critical sign ("SIDEWALK CLOSED"). Per-phrase once-a-minute stands.
