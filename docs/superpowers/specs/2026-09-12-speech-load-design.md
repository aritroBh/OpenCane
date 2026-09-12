# OpenCane Speech Load Design

**Status:** Approved for implementation by the user's explicit request to fix the overload while preserving the safety channel.

## Problem

OpenCane currently has two different kinds of voice output sharing one queue:

1. Guidance and safety output that a walker must hear: route, crossing, arrival, veer, head-height, ground hazards, and explicit channel-state failures.
2. Optional environmental narration: mesh obstacle names and the detail in a scene description.

Priority alone does not solve the second problem. The scene fallback can combine a LiDAR line, a people line, up to three scene nouns, and a sign. The model is also told to name the listed facts, so a strong model can produce a truthful but tiring census. Mesh names can then arrive close together and compete with the user's environmental listening.

## Design

### Content selection

The existing `SceneVocabulary` ranking remains the source of truth. Scene narration will use its highest-ranked two scene nouns, while the full classifier vocabulary remains available to the faithfulness gate. People and a measured LiDAR fact remain separately authoritative. A sign remains subject to `SignPolicy`; it is not treated as an arbitrary model object.

The on-device prompt will explicitly select at most two useful scene items and omit background detail. The deterministic fallback will use the same two-item limit, so a model failure cannot expand the spoken output. Scene questions from the conversational Action Button path will use the existing grounded `SceneDescriber` path rather than the generic conversation response path.

### Pacing

`SpeechLoadPolicy` lives in `CaneKitLogic` and contains the only new timing rule. It admits the first optional mesh obstacle-name line, then drops another optional name for seven seconds. The value is a provisional calibration knob, not a claim that seven seconds is a universal human-response interval. A busy queue also drops optional names rather than stacking stale narration behind route speech.

The policy is applied at `SpeechQueue.say` before interruption or queue insertion, but only for a request explicitly marked `.ambientObstacleName`. Existing calls remain fail-open by default. User-requested scene/conversation answers, route guidance, route/device-state acknowledgements, haptic fallback speech, ground hazards, head-height, and sound alerts bypass the governor.

Dropping is intentional for this first pass: it prevents stale optional content from accumulating and does not add a new timer task to the audio queue. Each drop is logged with the content class and reason. Repeat remains an unconditional escape hatch.

### Safety boundaries

- `.safety` and `.nav` behavior is unchanged.
- Directional obstacle speech is tagged separately from obstacle names and is never governed.
- Ground hazards and head-height remain outside the governor.
- Hazard-watch cautions remain advisory safety output and are not paced as ordinary scene narration.
- An explicit user query receives its answer or its existing audible failure path; the seven-second rule never delays it.

## Testing

The Logic tests cover the first optional line, the seven-second boundary, busy-queue suppression, normal-content bypass, invalid timing, and reset. Scene tests cover the two-item selection and fallback wording. Existing safety, route, haptics, sign, people, and cloud-faithfulness tests must remain green.

The simulator remains a structural gate because automation mutes speech. A physical-device walk with AirPods must compare quiet, 7-second, and longer-gap behavior using trip-log `speech_suppressed` records, while checking that route, head-height, ground-hazard, and directional fallback lines are not suppressed. The user should tune the gap only after measuring false silence, repeated requests, environmental-sound interference, and route deviations with a blind/O&M-trained tester.

## Research conclusion

The research does not support a universal seven-second conversational pause. Cross-language turn transitions peak around 0–200 ms; a communication-robot study found preference for roughly one second and leveling by two seconds. Blind-navigation literature instead supports event/distance-triggered instructions, short messages, on-demand detail, user-controlled verbosity, and preserving access to environmental sound. Seven seconds is therefore used here as a reversible experiment for unsolicited optional callouts, not for conversation or safety.
