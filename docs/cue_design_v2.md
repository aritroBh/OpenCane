<!-- Research workflow output, 2026-09-12. 4 researchers + 4 source fact-checkers (74 findings kept, 10 dropped as unsupported) + synthesis. Numbers marked [H] are hypotheses, not measurements. -->

# OpenCane cue design v2: what blind travellers need, and how to make the cane calmer

*Grounded in the repo at `d636232`. I read AGENTS.md, docs/design.md §5 and §7, hardware/mount/DESIGN.md, LaneMath.swift, CueDecider.swift, NavSupport.swift (`CueSpeechPolicy`), SpeechLoadPolicy.swift, ObstacleNamer.swift, AppModel.swift (`handle`, `speakCueIfNeeded`) and the tests that pin them. Every number marked **[H]** is a hypothesis to tune on the real cane. None of them has been measured.*

---

## 1. What blind travellers actually need

**P1. Don't tell me what my cane already tells me.**
- **Blind users:** One participant said: *"If there's something in my way on the ground as long as it's cane level I don't mind hitting it… But the overhead stuff is a different story."* Another stopped using a sonar cane because it kept telling her things she already knew, such as that a wall was near. (Williams et al., ASSETS 2014: https://dl.acm.org/doi/10.1145/2661334.2661380, https://hcc629branham.wordpress.com/wp-content/uploads/2015/02/p217-williams.pdf)
- **Researchers, summarising 13 cane users:** poles, hydrants and pedestrians got the lowest usefulness scores "since they can acquire it with their cane" (https://pmc.ncbi.nlm.nih.gov/articles/PMC9491388/).
- **Researchers:** a skilled cane user gets most obstacle and surface information directly from the cane, and needs "substantial additional input" before an aid is worth using (NRC 1986, https://www.ncbi.nlm.nih.gov/books/NBK218025/).

**P2. The real gap is overhangs. They are rare, so an alert has to mean a real overhang.**
- **Researchers, reporting self-reports from 300+ blind people:** 13% hit something at head level at least once a month. 86% of those accidents were outdoors. Indoor causes were doors and cabinets left ajar, shelves and tables, and staircases hit from the side (https://users.soe.ucsc.edu/~manduchi/papers/MobilityAccidents.pdf).
- **Blind reviewer Jonathan Mosen, on WeWALK:** used indoors, "the thing isn't going to stop vibrating", and it could not tell high returns from low ones (https://mosen.org/malp0166transcript/).
- **Blind UltraCane buyer:** head detection was worth having, but the cues were indistinguishable next to a wall (https://www.digitaldarragh.com/2012/06/20/review-of-the-ultracane/).
- **Blind participants:** overhead detection is wanted, as an alert (https://arxiv.org/pdf/2504.06379).

**P3. Silence means all clear, so every cue must mean "act now".**
- **Blind user of Biped:** "When Biped doesn't generate sounds, I feel safe." (https://bioalps.org/intelligent-harness-facilitate-mobility-blind-people/)
- **Researchers, iPhone LiDAR aid tested with 14 blind users:** Corridor-Walker stays silent on a clear path, vibrates once when it first detects something, and speaks only when an action is needed (https://wotipati.github.io/projects/other_papers/MobiQuitous2021_Corridor-Walker/MobiQuitous2021_Corridor-Walker_preprint.pdf).
- **Researchers:** a risk gate that skips speech in low-risk scenes reduces redundant output (https://arxiv.org/html/2508.16070).

**P4. My ears are my long-range sensor. Every word covers traffic and echoes.**
- **All 14 blind participants:** frequent audio while walking "was not usable because it interfered with… footsteps of other pedestrians and echoes from walls". Speech distracted more than beeps (Kayukawa et al. 2020, https://wotipati.github.io/projects/IMWUT2020/paper/IMWUT4_3_85_preprint.pdf).
- **Researchers, summarising 10 blind users:** audio aids must not block natural hearing, and spatial cues should be rendered sparsely (https://arxiv.org/pdf/2504.19345).
- **Researchers (abstract only):** even open-ear audio subtly pulls where people locate real sounds (https://www.sciencedirect.com/science/article/abs/pii/S0003687017300170).

**P5. Stay quiet at the curb, and never tell me when to cross.**
- **Blind author:** crossings are timed by listening for parallel traffic to start moving. Verbal directions at that moment "are not helpful at all" (https://chicagolighthouse.org/sandys-view/crossing-the-street/).
- **Researchers and O&M practice:** the crossing starts on the surge of parallel traffic (http://www.apsguide.org/chapter2_travel.cfm).

**P6. Speak once, early, about facts that change what I do next.**
- **Blind participants:** they want to know whether stairs go up or down, the type of entrance, and the type of intersection, so they can slow down in time (https://pmc.ncbi.nlm.nih.gov/articles/PMC9491388/).
- **Researchers and O&M practice:** the useful questions are which street this is and what shape the intersection has, not whether a curb is present (http://www.apsguide.org/chapter2_travel.cfm).

**P7. Treat objects as landmarks, not obstacles. Permanent things matter more than temporary ones.**
- **O&M textbook:** landmarks are constant and permanent; clues are temporary (https://umaine.edu/vemi/wp-content/uploads/sites/220/2024/11/Giudice-Long-Ch2-in-Foundations-of-OM-Establishing-and-Maintaining-Orientation-Tools-Techniques-and-Technologies.pdf).
- **O&M text:** a wall being trailed with the cane is a guide, not a hazard (https://tech.aph.org/omwc/xhtml/chapter-05.xhtml).
- **Researchers:** sighted describers get this backwards (https://pmc.ncbi.nlm.nih.gov/articles/PMC9491388/).

**P8. Let me pull information. Give the short answer first.**
- **11 blind participants:** AI answers ran far longer than their questions ("gives way too much information"), and they asked for a "hurry mode" (https://pmc.ncbi.nlm.nih.gov/articles/PMC13227612/).
- **Company:** Soundscape's "Ahead of Me" returns five items, on request (https://www.microsoft.com/en-us/research/product/soundscape/features/).
- **AFB review:** BlindSquare puts "where am I" on a shake gesture (https://afb.org/aw/15/7/15555).
- **Blind cane user:** stressed actively probing with the cane when you choose to (https://www.myeyemyway.com/2024/12/my-thoughts-on-glidance.html).

**P9. One channel, one meaning, few levels, and don't fight the cane's own vibration.**
- **Researchers, 13 BVI participants:** no one preferred BuzzClip. Its vibrations were "often uninformative and confused with the cane feedback". Both aids slowed walking compared with the cane alone (https://pmc.ncbi.nlm.nih.gov/articles/PMC12909938/).
- **Blind participants:** vibration from the device's own handle drowned out alerts on rough floors, and two nearly collided (Kayukawa 2020, above).
- **Company:** Biped keeps all feedback in audio so that touch belongs to the cane (https://mosen.org/malp0166transcript/).
- **Company:** Apple HIG says a haptic can "become tiresome when it plays frequently" (https://developer.apple.com/design/human-interface-guidelines/playing-haptics).

**P10. Quiet by default, verbosity I can change, and tell me when the mode changes.**
- **Blind participants** asked for customizable verbosity levels (https://arxiv.org/pdf/2504.06379).
- **Researchers, 13 blind participants:** needs differ with ability and route familiarity (https://doi.org/10.1145/3315002.3317561).
- **Blind participant in NavCog3:** less guidance would be safer, so they could also build a mental map (https://publications.ri.cmu.edu/resolve/2018/01/p270-sato.pdf).
- **Blind reviewer:** also wanted a way to get *more* information (https://equalentry.com/microsoft-soundscape-a-user-review-by-sofia-gallo/).
- **Blind Sunu Band owner:** complained about indoor/outdoor mode switches with no indication (https://blindadventuresblog.wordpress.com/2018/07/20/the-sunu-band-a-review/).

**P11. I should be able to hold a conversation, and hush it with one gesture.**
- **Soundscape's blind product lead:** "You minimize the use of language." With attention-grabbing GPS instructions, "I can't hold a conversation" (https://www.microsoft.com/en-us/research/podcast/soundscaping-the-world-with-amos-miller/).
- **Company:** Soundscape hushes with a single tap on the headset's play/pause (https://www.microsoft.com/en-us/research/articles/getting-fresh-air-with-microsoft-soundscape/).

**P12. Whole, brisk speech at my own rate. Not slow, not clipped.**
- **Blind users:** most set speech faster than the default. Slower is "aggravating" (https://jonggi.github.io/papers/TACCESS2020-speech.pdf).
- **Blind participants:** valued short advice "without unnecessary fillers" (https://arxiv.org/pdf/2602.13233). That study mixed sighted and VI participants, and its "event-only preferred" framing did not hold up.

---

## 2. Where OpenCane violates them today

| # | Violation | Code or design | Field symptom | Principles |
|---|---|---|---|---|
| V1 | **"Head height" is not measured as head height.** The top band is image rows, not a metric height. `LaneMath` skips the bottom 25% of the image and splits the rest in half, with no gravity correction. From DESIGN.md (camera ≈0.97 m, 5° down, half vertical FOV 33.5°), the band covers roughly **1.05–1.8 m at 1–1.5 m range** by my estimate: hip to crown. `CueDecider` takes `min(head[0], head[1], head[2])` below 1.5 m, so the side lanes count too (each lane is about 0.5 m wide at 1.5 m). Any wall, door frame, person, shelf unit or fridge within 1.5 m fires `.head`. The code's own comment calls the band "waist-to-head". | `LaneMath.swift` (`groundSkipFraction` 0.25, `band == 0`); `CueDecider.update` L141–146; `CueThresholds.head = 1.5` | "Head height." 10× in 2 min indoors. Real overhangs are a few-a-month event (P2), so nearly all of these were tall things the cane would find anyway. Same failure as WeWALK. | P1, P2, P3 |
| V2 | **The head haptic re-fires at 1 Hz** for as long as the zone is active. | `CueThresholds.repeatInterval = 1.0`; design.md §5.2 ("re-fires every second"); pinned by `headCueKeepsRefiringWhileObstaclePersists` | ~1 Hz head cue | P3, P9 |
| V3 | **Head speech episodes are fragile.** `cueSpeech.cleared()` runs on any decider `.stop`, meaning one report with every zone beyond threshold + 0.15 m. The only other limit is `headInterval = 4 s`, which allows up to 30 lines in 2 min. | `AppModel.handle` (`case .stop`); `CueSpeechPolicy.line`; pinned by `headHeightIsSpokenOncePerEpisode`, `headEpisodesAreRateLimitedAcrossEpisodes`, `aBuzzedSideCueDoesNotSplitAHeadEpisode` | 10 spoken episodes, about one every 12 s | P3 |
| V4 | **Obstacle names are on by default and are the lowest-value content.** "Two meters ahead, door/wall/seat/window/table". The 7 s calm window drops lines after they are generated instead of fixing what gets generated. | `AppModel.obstacleNamesEnabled` default `true` (AppModel.swift:193); `ObstacleNamer` (2.5 s, ≥1 m change); `SpeechLoadPolicy` 7 s | 9 names suppressed. The generator produces a candidate every few seconds. | P1, P7, P8 |
| V5 | **Choppy voice** (likely causes, to confirm from `speech_dispatch` records): (a) `.safety` "Head height." cuts any lower line at a word boundary, and the cut line resumes once ("Two meters ahead— Head height. —Two meters ahead, door"); (b) uncached `.obstacle`/`.safety` lines use the system voice while other lines use ElevenLabs, so the voice flips; (c) the beacon ducks to 30% on every line and comes back; (d) short TTLs (4 s names, 6 s head) expire queued lines mid-sequence. | `SpeechQueue` (interrupt plus `maxReplays` resume, backend choice); design.md §5.1 and §5.3 (beacon duck) | "Voice felt choppy" | P4, P12 |
| V6 | **A continuous Geiger loop runs through the cane** (2–8 Hz while the centre torso lane is < 2 m), and the side taps (2 or 3) fire whenever you trail a wall. Both share a path with the tip's own vibration. | `GeigerRate`, `CueThresholds.center = 2.0`, `side = 1.2`; `HapticPlayer` | Constant buzzing near furniture and along corridors | P1, P7, P9 |
| V7 | **Nothing holds speech or taps at a crossing or while standing still.** `TurnSettle` silences only the beacon at crossings. Obstacle speech and taps continue. | `NavSupport.TurnSettle`; `AppModel.handle` has no stationary or crossing gate | Standing and listening still produces cues | P5, P11 |
| V8 | **No verbosity levels, only per-feature toggles.** Sign reading is on by default (a scan every 3 s). I did not find a one-gesture speech hush in the files I read ("Silence haptics" covers haptics only, and re-routes cues *to* speech). | `AppModel` settings (`signsEnabled` default true); design.md §5.4 | Everything is on at once | P8, P10, P11 |
| V9 | **Speech rate is fixed** at default × 1.05 and ignores the user's VoiceOver rate. | `SpeechQueue.rate` (SpeechQueue.swift:250) | Adds to the "slow and clipped" feel | P12 |

**What is already right (keep):**
- "Where am I" is on demand.
- Ground hazards and hazard watch ship off by default. Ground hazards repeat at most every 30 s.
- "STOP" signs are never read.
- The beacon is silent within 10° of course and during crossing settle.
- Route buzzes are deliberately unlike obstacle taps.
- The wrist `.failure` pattern is reserved for head height.
- No earcons.
- Obstacle names never cut route lines.

---

## 3. Proposed cue design v2

### 3.1 Design rules

1. Silence is the default state. A cue fires on an **onset** (something new), a **closing** approach, or a **user request**. Presence alone never fires a cue.
2. **One meaning per channel.**
   - Cane haptic: overhang, or imminent contact.
   - Watch: route turns, plus a mirror of the head alarm.
   - Beacon: direction.
   - Speech: rare facts that change what the user does, and answers to requests.
3. **Safety floor (AGENTS.md hard rule 8).** Every overhang episode always gets its haptic and one "Head height." at onset, at every verbosity level. The hush gesture does not affect it.
4. **Numbers live in `CaneKitLogic`.** New pure types: `HeadGate`, `CueProfile`, `SpeechBudget`, `MotionState`.

### 3.2 Head height: much calmer, never suppressed

| Stage | Rule | Numbers [H] |
|---|---|---|
| **What counts as head** | A lane is an *overhang candidate* when `head[i] < enter` **and** its torso cell is either invalid (fail-safe) or at least `gap` farther than the head cell. Things that are near in both bands (walls, doors, people, shelf units) go to torso logic; the cane finds them. Needs a validity or sample count per cell, because `LaneGrid` currently uses `.infinity` for both "clear" and "too few samples". | centre `enter` 1.5 m outdoors / 1.2 m indoors; side lanes 1.0 m / 0.8 m; `gap` 0.5 m |
| **Episode start** | Haptic head pattern + Watch `.failure` + "Head height." (`.safety`) at the first candidate frame. The speech needs *closing* (head distance fell ≥ 0.25 m over the last 1 s of trusted frames) **or** distance < 0.9 m. The haptic needs neither. | 0.25 m / 1 s; 0.9 m |
| **Within an episode** | No time-based re-fire. The haptic re-fires only on crossing a closer band, each band once. A second "Head height." is allowed only when < 0.6 m and still closing. | bands 1.0 m and 0.6 m, ≥ 1.5 s apart |
| **Episode end** | No candidate for ≥ 2.0 s of *trusted* frames. Untrusted sweep frames do not count toward clearing. A decider `.stop` no longer ends the episode by itself. | 2.0 s |
| **Same overhang again** | A new onset in the same lane within 1.0 m of camera travel since the last onset (ARKit camera position, to be added to `LaneReport`) continues the old episode. Same pattern as `GroundHazardPolicy`. | 1.0 m; 30 s cap |
| **Standing still** | No new head speech. The haptic still fires at onset. | still = < 0.3 m of travel in 2 s |
| **Later (L effort)** | Gravity-corrected height using `cameraTiltDownDeg` and the row of the nearest sample, so "head" means ≥ 1.2 m above ground in metres. |  |

**Target for the same 2-minute indoor walk:** ≤ 2 "Head height." lines, ≤ 6 head haptics. **Must not regress:** on a taped rig (a cardboard sign hung at 1.5–1.7 m, a wall cabinet door ajar, the underside of a stair approached from the side), 10 of 10 approaches cue at ≥ 1.0 m.

**Tests that pin today's behaviour and must be deliberately rewritten:**
- `CueDeciderTests.headCueKeepsRefiringWhileObstaclePersists` (1 Hz)
- `headReturningAfterClearWaitsOutTheFloor`
- `headBeatsCenterBeatsSides`: its fixture is head 1.0 / torso 1.0, which under v2 becomes a centre obstacle
- `NavSupportTests.headHeightIsSpokenOncePerEpisode`, `headEpisodesAreRateLimitedAcrossEpisodes` and `aBuzzedSideCueDoesNotSplitAHeadEpisode`
- `SpokenPhrasesTests` L87 (the exact line text)
- The ⚠ comment on `AppModel.speakCueIfNeeded` requires an on-device head-height test before any new gating path.

Because of AGENTS.md "How we engineer" rule 6, the overhang signature ships behind a setting that is **off by default** until the rig test passes on the cane. The founder decides when to flip it.

### 3.3 Everything else, by verbosity level

Defaults: **Quiet** for daily travel; **Standard** for the demo if the founder wants the taps to be visible.

| Cue | Quiet | Standard | Detailed / Explore (≈ today) |
|---|---|---|---|
| Head overhang (§3.2) | haptic + speech at onset | same | same |
| Centre torso | nothing (the cane covers it) | **two levels, onset only:** 1 tap when < 1.5 m and closing; 1 strong triple tap at < 0.6 m and closing; re-arms after 1.5 s clear. No loop. | Geiger loop |
| Side torso | nothing | nothing | taps, except when the side distance holds steady (±0.1 m over 2 s = shorelining) |
| Mesh names | off (pull only) | "Door" only, when on a route | all classes, never "wall" |
| Ground hazards (setting still off by default) | speak once at first confirm (≥ 1.5 m), short: "Drop-off." / "Step up."; drop the "1 m closer" speech, repeat by haptic only; never speak "low obstacle" | same | + distance in the line |
| Signs | safety phrases only (closed / detour / construction) | + everything else, once a minute | current |
| Route lines | at decision points; "Passed X" | same | + distance updates every 15 m |
| Beacon | off-course only (already silent within 10°), silent when still > 3 s | same | current |
| "What's ahead?" (Watch / voice, pull) | ≤ 3 items, nearest first, doors, stairs and signs before furniture, "Door, 2 o'clock, 3 meters" (format is a setting) | same | ≤ 5 items |
| "Where am I" | first sentence ≤ 12 words: place type + nearest landmark or exit; "More" for detail | same | same |

### 3.4 Speech budget (`SpeechBudget`, generalising `SpeechLoadPolicy`)

- **Unsolicited non-safety, non-route lines:** at least 8 s apart while moving [H]. None while still. None during a crossing settle (reuse `TurnSettle.isCrossing` plus stationary).
- **Length:** ≤ 4 words for unsolicited cue lines [H].
- **Drop, don't delay:** if a line would start > 1.5 s after its event, drop it [H]. Interrupted `.obstacle` and `.scene` lines are **dropped, not resumed**; only `.nav` keeps its one resume (Repeat still recovers lines).
- **One voice for cue lines:** "Head height." and the ground lines come only from the prefetched ElevenLabs clip or only from the system voice, never mixed.
- **Rate:** `AVSpeechUtterance.prefersAssistiveTechnologySettings = true` follows the user's VoiceOver/Spoken Content rate, with an in-app override.
- **Hush:** AirPods stem press or Watch double tap silences all non-safety speech and non-head haptics for 60 s [H], confirmed by one soft buzz. Head and ground hazards still fire. This is a remote command on the existing `.playback` session; verify it on the device.

### 3.5 Indoor and outdoor

- **Profile switching:** manual from Watch or Settings. Suggest Indoor automatically when GPS accuracy stays > 30 m for 20 s [H]. Every switch is announced once ("Indoor mode.").
- **Indoor:** head centre 1.2 m, side 0.8 m; torso taps off; names off; beacon off unless routing; safety signs only.
- **Outdoor:** head centre 1.5 m, side 1.0 m. Head `enter` scales with walking speed, `clamp(0.9 + 0.5·v, 1.0, 1.6)` m [H], with v from ARKit travel.
- **AirPods:** the app cannot set the noise mode (design.md §5.5). The setup checklist and route start should recommend Transparency or Adaptive, never Noise Cancellation.

### 3.6 What the cane tip already covers, so we drop it

- The centre Geiger loop and the side taps (moved to Detailed).
- "Left." / "Right." / "One meter ahead." (kept only as the haptics-down fallback).
- The names wall, table, seat and window.
- Repeating a curb or step once it is within cane reach (< 1.2 m).
- Speaking "low obstacle".

**Kept:** overhangs, advance notice (≥ 1.5 m) of drop-offs and stairs down, route decision points, safety signs.

**Success metrics for every field test:**
- Walking speed with OpenCane compared with cane alone (Pittet 2026).
- Unsolicited lines per minute.
- `replays > 0` count in `speech_dispatch`.
- Whether the user can hold a conversation while walking.

---

## 4. Ranked change list

| # | Change | Files | Logic tests first | Demo risk | Effort |
|---|---|---|---|---|---|
| 1 | **Measure first:** from the field-test trip log, count `cue: head` events by which lane's head value was < 1.5 m, and whether torso was ≈ head; count `speech_dispatch` replays and backends. This confirms or refutes V1 and V5. | read-only: trip log JSONL, `ios/scripts/` | none (a script) | none | S |
| 2 | Obstacle names default **off**; move defaults into a `CueProfile` | `AppModel.swift`, new `CueProfile.swift`, design.md §5.2 | `quietProfileHasNoObstacleNames`, `quietProfileReadsOnlySafetySigns` | low | S |
| 3 | Head **speech** episode ends only after 2 s of trusted clear frames, plus a closing requirement | `NavSupport.swift` (`CueSpeechPolicy`), `AppModel.handle` | `headSpeechDoesNotRestartAfterABriefClear`, `headSpeechRestartsAfterTwoSecondsClear`, `untrustedFramesDoNotCountTowardClear`, `stationaryOnsetBuzzesButDoesNotSpeak`; rewrite `headEpisodesAreRateLimitedAcrossEpisodes` | low (speech only; haptic unchanged) | S |
| 4 | Speech de-chop: drop interrupted `.obstacle`/`.scene` lines, one voice for cue lines, drop-if-late 1.5 s | `SpeechQueue.swift`, new `ReplayPolicy.swift` | `interruptedObstacleLineIsDropped`, `navLineResumesOnce`, `lateOptionalLineIsDropped` | low–med (touches the queue) | M |
| 5 | Follow the user's speech rate | `SpeechQueue.swift` | none (no number; the override rate lives in a `CueProfile` test) | low | S |
| 6 | Head **haptic** re-fires on distance bands, not 1 Hz | `CueDecider.swift`, design.md §5.2 | `headRefiresOnlyWhenCrossingACloserBand`, `headDoesNotRefireWhileDistanceHolds`; rewrite `headCueKeepsRefiringWhileObstaclePersists` | **med** (safety rule; needs the rig test) | S–M |
| 7 | **Overhang signature** (head < torso − 0.5 m; invalid torso fails safe), behind a setting off by default | `LaneMath.swift` (cell validity), `LaneReport.swift`, new `HeadGate.swift`, `CueDecider.swift` | `wallNearInBothBandsIsNotHead`, `hangingSignWithClearTorsoIsHead`, `invalidTorsoCellFailsSafeToHead`, `sideLaneHeadUsesShorterThreshold`; rewrite `headBeatsCenterBeatsSides` | **high** if on by default; low while off | M |
| 8 | Crossing and stationary hold for non-safety speech and torso taps | new `MotionState.swift`, `SpeechBudget.swift`; `AppModel.handle`; `DepthFrameProcessor` (camera travel into `LaneReport`) | `noOptionalSpeechWhileStill`, `crossingSettleHoldsObstacleTier`, `safetyPassesDuringCrossingHold` | med | M |
| 9 | Centre torso: two-level onset taps replace the Geiger loop (Standard); side taps only in Detailed with shoreline suppression | `CueDecider.swift`, `HapticPlayer.swift` | `centerTapsOnceOnClosingOnset`, `centerStrongTapBelowSixtyCentimetres`, `steadySideDistanceIsShoreline` | med (changes how the demo feels) | M |
| 10 | Verbosity levels + Indoor/Outdoor profile with an announced switch | `CueProfile.swift`, `AppModel.swift`, Settings UI, Watch | `indoorProfileThresholds`, `autoIndoorSuggestionNeedsTwentySecondsPoorGPS`, `profileChangeProducesOneLine` | med (UI labels are a test contract, hard rule 9) | M–L |
| 11 | Hush gesture (AirPods stem / Watch double tap, 60 s, safety exempt) | `AppModel.swift`, `WatchModel`, `WatchMessage.swift` | `hushExemptsHeadAndGround`, `hushExpiresAfterSixtySeconds` | low–med | M |
| 12 | "What's ahead?" pull query, ≤ 3 items, clock face | `HandsFreeIntents.swift`, `FastPathIntentClassifier.swift`, new `AheadSummary.swift` | `aheadListsAtMostThreeNearestFirst`, `clockFaceFromLane`, `doorsRankAboveFurniture` | low | M |
| 13 | Gravity-corrected metric head band | `LaneMath.swift`, `DepthFrameProcessor` | `headBandUsesMetricHeightAtTenDegreePitch` | high | L |

**For today's demo:** do #1–#5 and nothing more. #6 and #7 need a hanging-object rig test on the cane first.

---

## 5. Open questions only a blind tester can answer

1. On the cane handle, can you tell the head pattern apart from tip vibration on tile, grout, tactile paving and gravel? Would you rather have head alarms on the Watch only?
2. Is one "Head height." per overhang enough, or do you want a second one at arm's length? Is a spoken word better than a distinct haptic alone?
3. With the centre and side taps off, does anything feel missing indoors? Outdoors?
4. Is advance notice of curbs and steps at ≥ 1.5 m useful, or noise that your cane already covers? Does that differ between two-point touch and constant contact?
5. Which categories would you switch on: doors, stairs, signs, benches, people? Clock face or left/right? Metres or steps?
6. Is 8 s between unsolicited lines too chatty or too sparse? At your own speech rate, does "Head height." ever mask traffic?
7. Beacon: only when off course, or continuous? Does it bother you in Transparency mode?
8. What should the hush gesture be, given one hand is on the cane?
9. Does wearing a phone that talks draw unwanted attention? Would haptic-only be preferable in public?
10. Walking speed and confidence with OpenCane compared with cane alone, over the same route. Discount the first minutes, when testers explore the device instead of walking.

**Finding testers quickly (Champaign-Urbana).** I did not check any of these contacts during this research. Confirm each before reaching out.
- **UIUC Disability Resources & Educational Services (DRES):** ask its accessibility staff to circulate a paid 45-minute session to students who are blind or low vision.
- **National Federation of the Blind of Illinois:** its Champaign-Urbana-area chapter and student division (state affiliates are listed via nfb.org).
- **Illinois Council of the Blind** (the ACB affiliate).
- **Chicago Lighthouse** and the **Illinois Center for Rehabilitation and Education (ICRE-Wood)**, for experienced travellers and for **certified O&M specialists** (ACVREP directory) who can run a structured cane-plus-device session.
- **AppleVis forums and r/Blind**, for remote feedback on the cue vocabulary through recorded audio samples.

Pay testers. Have a sighted spotter present. Always run a cane-only baseline first. A blindfolded sighted tester is not a substitute: one unverified abstract reports that audio load differs sharply between cane users and blindfolded users.

---

## Sources

**Blind users**
- Williams et al., ASSETS 2014: https://dl.acm.org/doi/10.1145/2661334.2661380, https://hcc629branham.wordpress.com/wp-content/uploads/2015/02/p217-williams.pdf
- Mosen, WeWALK review and Biped interview: https://mosen.org/malp0166transcript/
- Ó Héiligh, UltraCane review: https://www.digitaldarragh.com/2012/06/20/review-of-the-ultracane/
- Sunu Band review: https://blindadventuresblog.wordpress.com/2018/07/20/the-sunu-band-a-review/
- Murillo, Chicago Lighthouse: https://chicagolighthouse.org/sandys-view/crossing-the-street/
- Gallo, Soundscape review: https://equalentry.com/microsoft-soundscape-a-user-review-by-sofia-gallo/
- Biped user quote: https://bioalps.org/intelligent-harness-facilitate-mobility-blind-people/
- Dixon, Meta Ray-Ban review: https://www.timdixon.net/blog/2025/04/blind-meta-ray-ban-review-2025/
- Consumer Reports (Lachi): https://www.consumerreports.org/electronics/emerging-technology/can-ray-ban-meta-ai-glasses-guide-the-blind-a6400488928/
- My Eye My Way (Glidance): https://www.myeyemyway.com/2024/12/my-thoughts-on-glidance.html
- Miller, Microsoft Research podcast: https://www.microsoft.com/en-us/research/podcast/soundscaping-the-world-with-amos-miller/
- Miller, ATU370: https://www.eastersealstech.com/2018/06/29/atu370-microsofts-soundscape-with-amos-miller/
- Soltani et al. 2025: https://arxiv.org/pdf/2504.06379
- Say It My Way (CHI 2026): https://pmc.ncbi.nlm.nih.gov/articles/PMC13227612/
- Kayukawa et al., IMWUT 2020: https://wotipati.github.io/projects/IMWUT2020/paper/IMWUT4_3_85_preprint.pdf
- Sato et al., NavCog3: https://publications.ri.cmu.edu/resolve/2018/01/p270-sato.pdf
- Hong et al., TACCESS 2020: https://jonggi.github.io/papers/TACCESS2020-speech.pdf

**Researchers and O&M**
- Manduchi & Kurniawan: https://users.soe.ucsc.edu/~manduchi/papers/MobilityAccidents.pdf
- Hoogsteen et al., TACCESS 2022: https://pmc.ncbi.nlm.nih.gov/articles/PMC9491388/
- Varshney et al. 2025: https://arxiv.org/pdf/2504.19345
- APS Guide: http://www.apsguide.org/chapter2_travel.cfm
- Giudice & Long: https://umaine.edu/vemi/wp-content/uploads/sites/220/2024/11/Giudice-Long-Ch2-in-Foundations-of-OM-Establishing-and-Maintaining-Orientation-Tools-Techniques-and-Technologies.pdf
- APH O&M text: https://tech.aph.org/omwc/xhtml/chapter-05.xhtml
- Thaler 2013: https://pmc.ncbi.nlm.nih.gov/articles/PMC3647143/
- Kim, Wall Emerson & Curtis 2009: https://pmc.ncbi.nlm.nih.gov/articles/PMC3013510/
- Pittet et al., Scientific Reports 2026: https://www.nature.com/articles/s41598-026-37578-9, https://pmc.ncbi.nlm.nih.gov/articles/PMC12909938/
- NRC 1986: https://www.ncbi.nlm.nih.gov/books/NBK218025/
- Klatzky et al. 2006: https://pubmed.ncbi.nlm.nih.gov/17154771/ (sighted, blindfolded participants)
- Cognitive load summary: https://umaine.edu/vemi/resource/cognitive-load-navigating-without-vision-guided-virtual-sound-versus-spatial-language/
- Loomis et al. 2005: https://pubmed.ncbi.nlm.nih.gov/20054426/
- Ahmetovic et al. 2019: https://doi.org/10.1145/3315002.3317561
- GuideDog (ACL 2026): https://arxiv.org/html/2503.12844
- WalkVLM-LR: https://arxiv.org/html/2508.16070
- Hersh 2022: https://pmc.ncbi.nlm.nih.gov/articles/PMC9324285/
- May & Walker 2017: https://www.sciencedirect.com/science/article/abs/pii/S0003687017300170 (abstract only)
- MIT CSAIL 2017: https://news.mit.edu/2017/wearable-visually-impaired-users-navigate-0531
- Kim & Cho 2013: https://www.ijdesign.org/index.php/IJDesign/article/view/1209/559
- BBeep: https://wotipati.github.io/projects/BBeep/BBeep.html (the collision reduction came from a speaker nearby pedestrians could hear; alerts to the user alone were not shown to help)
- Skulimowski/Strumillo group: https://pmc.ncbi.nlm.nih.gov/articles/PMC7304791/
- Corridor-Walker: https://wotipati.github.io/projects/other_papers/MobiQuitous2021_Corridor-Walker/MobiQuitous2021_Corridor-Walker_preprint.pdf
- van Erp et al. 2017: https://www.frontiersin.org/journals/ict/articles/10.3389/fict.2017.00023/full (the rate-coded distance result came from sighted participants)
- Wortmann et al. 2026: https://arxiv.org/pdf/2602.13233 (mixed VI and sighted participants)
- Walker & Lindsay 2006: https://journals.sagepub.com/doi/10.1518/001872006777724507 (1.5 m radius is supported; the sonar beacon was not best overall)
- Spearcons: https://journals.sagepub.com/doi/10.1177/0018720812450587
- Martínez et al. 2014: https://www.researchgate.net/publication/295261468_Cognitive_Evaluation_of_Haptic_and_Audio_Feedback_in_Short_Range_Navigation_Tasks (**unverified**)
- Shinohara & Wobbrock, CHI 2011: https://dl.acm.org/doi/10.1145/1978942.1979044
- O&M specialist on GPS apps: https://www.exceptionaleducators.us/blog/Testing-Top-Rated-GPS-Apps-as-an-Orientation-and-Mobility-Specialist-Part-2
- Tabb, Paths to Literacy: https://www.pathstoliteracy.org/location-literacy-art-knowing-defining-and-communicating-where-you-are-where-you-want-go-and/

**Company and other**
- AFB AccessWorld, Soundscape: https://afb.org/aw/19/8/15067
- AFB AccessWorld, BlindSquare: https://afb.org/aw/15/7/15555
- Microsoft Soundscape features: https://www.microsoft.com/en-us/research/product/soundscape/features/
- Microsoft Soundscape article: https://www.microsoft.com/en-us/research/articles/getting-fresh-air-with-microsoft-soundscape/
- Guide Dogs UK, Soundscape: https://www.guidedogs.org.uk/getting-support/information-and-advice/how-can-technology-help-me/apps/soundscape/
- AbilityNet, Door Detection: https://mcmw.abilitynet.org.uk/how-to-detect-doors-around-you-using-the-magnifier-app-in-ios-17-on-your-iphone-pro-or-ipad-pro
- Sunu Band quick start: https://independentliving.com/content/142411-Sunu-Quickstart.pdf
- Apple HIG, Playing haptics: https://developer.apple.com/design/human-interface-guidelines/playing-haptics

**Repo files cited** (read-only, nothing edited):
- /Users/aritro/Downloads/54FoundersHack/AGENTS.md
- /Users/aritro/Downloads/54FoundersHack/docs/design.md
- /Users/aritro/Downloads/54FoundersHack/hardware/mount/DESIGN.md
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Sources/CaneKitLogic/LaneMath.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Sources/CaneKitLogic/CueDecider.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Sources/CaneKitLogic/NavSupport.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Sources/CaneKitLogic/SpeechLoadPolicy.swift
- /Users/aritro/Downloads/54FoundersHack/ios/CaneKit/Speech/ObstacleNamer.swift
- /Users/aritro/Downloads/54FoundersHack/ios/CaneKit/Speech/SpeechQueue.swift
- /Users/aritro/Downloads/54FoundersHack/ios/CaneKit/App/AppModel.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Tests/CaneKitLogicTests/CueDeciderTests.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Tests/CaneKitLogicTests/NavSupportTests.swift
- /Users/aritro/Downloads/54FoundersHack/ios/Logic/Tests/CaneKitLogicTests/SpeechLoadPolicyTests.swift
## Addendum: measured on the field log (trip log canekit-2026-09-12T20-57-17Z)



- Of 360 head-band cells under 1.5 m, 349 also had the torso cell within 0.5 m (wall, furniture or person), 8 had the overhang signature (torso at least 0.5 m farther or clear), and 3 were torso dropouts (whole torso row missing: no data, not overhangs). This is consistent with V1, but see the caveat: none of these cells came from frames at mount tilt.

- Caveat: tilt had a median of 25.8° (range −2.6° to 75.3°), only 14 % of frames inside 3–8°, and head distances were 0.1–0.25 m. The phone was handheld and pointed at a table, not cane-mounted. **Zero** head cells came from frames at mount tilt, so V1 rests on the mechanism, not on this log. Re-measure on the mount (`make audit`) before tuning numbers.

- 72 head cues and 13 centre cues in ~2 min; 10 "Head height." lines; 10 obstacle names suppressed.
