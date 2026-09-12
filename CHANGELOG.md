# CaneKit changelog

Build log for the hackathon. One entry per step; each ends with what to test on the phone.

## Step 17 — App icon (Sat Sep 12, needs install)

Both `AppIcon` sets were empty — the app shipped with no icon. v1 ("Folded Signal", from
`/tmp/icon.py`) was abstract bars; v2 ("White Cane") is a real mobility cane on the navy
field: black grip, gold joint ring, white shaft with two red wraps, red tip leaning
lower-right, faint gold signal arcs. Generator committed as `ios/scripts/appicon.py`
(`python3 ios/scripts/appicon.py` rewrites both 1024 PNGs).

Review: `agy` cannot run in this sandbox (needs localhost bind + log writes), so the user
ran it in their own terminal against a `/tmp` copy. It found 3 real defects, all fixed and
re-verified: (1) red wrap bands clipped flush — strip had no vertical padding so
`alpha_composite` cut the proud 8 px + rounded corners; (2) drop shadow hard-edged — the
blur clamped at the unpadded layer bounds; (3) stale "top-left" comment on the top-right
arcs. Fixes: `PAD` strip padding, `SPAD`-padded shadow layer. My own numeric review before
that caught the v2 tip on the mask boundary (fixed by the 0.88 scale). Final probe: zero
content pixels in the mask cut zone; masked 180 px + 60 px renders confirm tip intact and
cane legible. agy also confirmed asset wiring (both sets, RGB, no alpha) and squircle safety.

test on device: OpenCane icon on the Home Screen after install; red tip intact inside the
squircle at small sizes (check a folder view too).

Installed 2026-09-12 ~01:25 via `make run` (build + `actool` icon compile + devicectl install
all green, incl. the 10 Siri phrases training under the OpenCane name). Auto-launch refused:
phone was locked — unlock and tap the icon by hand.

## Step 16 — Emergency sirens + hands-free integrated (Sat Sep 12, uncommitted)

Both worktrees are now in the main checkout, hand-merged so nothing the renames and fixes
built since is lost:
- Emergency (`cane-wt-emergency`): siren gate 0.50 → 0.60 with three agreeing windows,
  `.emergency` urgency → `.nav` band (never `.safety`), `best(of:)` so traffic noise cannot
  shadow a siren, `speechTTL` per kind. `SoundAlerts.swift` + `SoundAlertsTests.swift` copied
  verbatim (main never touched them); `SoundWatcher` + `AppModel` merged keeping every OpenCane
  rename. Verified: API fully additive (`labels`, `candidateLabels`, `kind(for:)` retained;
  `SensorProbe` only uses `candidateLabels`), `best(of:)` fallback preserves the policy's
  below-gate reset, no force-unwraps, `.nav` exists on `SpeechPriority`.
- Hands-free (`cane-wt-handsfree`): Status / Ask / Silence-haptics shortcuts (list now 10/10),
  `HandsFreeIntents.swift` + `QuestionPrompt` / `StatusSummary` + tests + `docs/handsfree.md`
  copied; `AppIntents` shortcuts block, `VLMClient.cloudPrimary` contract, `SceneDescriber`
  question path and the `describe_result` question field merged. Two corrections while merging:
  spoken strings say OpenCane (the branch predates the rename), and main's newer 18/25 s cloud
  timeouts kept over the branch's 8/12 s. Verified: all four `AppModel` methods the intents call
  exist (as an extension in the intents file), every member they touch exists, sources are globs
  so no `project.yml` change needed. A 4-agent verification wave over the integrated tree
  confirmed all contracts with file:line evidence.
- Deliberately NOT merged as branches (the work is uncommitted in the worktrees); this is the
  merge, done by hand with the rename applied. Commit after the gate, then merge the branches
  only to retire them.

test on device: siren needs ~1.5 s of continuous siren before "Siren. Do not start crossing.";
horns stay passive; "How is OpenCane doing" answers in the fixed six-clause order; "Ask OpenCane
about the scene" answers the question asked, never a generic description.

### Antigravity review of Step 16 (7 findings — 4 fixed, 1 instrumented, 2 rejected with evidence)

1. **Siren expired unheard behind crossing lines — FIXED, real.** 5 s assumed a siren queues
   behind "at most the route line already playing". Wrong: `.nav` queues FIFO behind any `.nav`
   line (crossing 4–8 s, lock warning 10 s, location-denied 20 s) and the queue purges expired
   lines on line end (`SpeechQueue` header). Siren `speechTTL` 5 → 15 (= repeat interval) with
   the test rewritten to pin both bounds.
2. **Siren blocked by long `.nav` lines — same fix; pre-empting obstacle NAMES — REJECTED.**
   Haptic warnings never pass through speech: the cane keeps buzzing under any announcement, so
   nothing safety-critical is delayed. Names resume (interrupted lines re-queue).
3. **Siri invocation may kill the mic permanently — INSTRUMENTED, unproven.** `SoundWatcher` had
   no interruption observer (confirmed by reading the file). No lifecycle change without device
   proof; added a log-only `interruption_began/ended` observer so the trip log can correlate the
   next death. Repro: sirens on → "Ask OpenCane about the scene" → check switch + log.
4. **"SetOption announces on before async validation" — FIXED the overclaim, real.** The
   read-back is synchronous; the 0.25 s format settle can refuse after. Comment now states that;
   behavior kept (the failure line corrects within ~a second).
5. **Silence confirmation delays spoken cues 3–4 s — ACCEPTED as residual, overstated.**
   `SpeechQueue` queues (not suppresses); only a cue arriving in that window AND expiring (4 s
   TTL) is lost, and only when the user just silenced haptics with no watch. `handsfree.md` now
   says to stand still for a few seconds after.
6. **Ask answers go stale while walking — ACCEPTED, bounded.** Question-path answer TTL 20 →
   10 (plain Where-Am-I keeps 20: that walker stands still). Cloud-wait staleness remains;
   bounded by the 18/25 s session budget and auditable via `ms` + `frame` in `describe_result`.
7. **No-cloud downgrade "violates" the ask contract — REJECTED.** The downgrade is announced out
   loud ("needs the cloud model... Describing instead.") and the original question is preserved
   in `lastQuestion` + the trip log. No silent substitution; the contract bans silent ones.

## Step 15 — Front-inset tilt, second attempt (Sat Sep 12, compiled + installed)

The front inset of the both-cameras view still came out tilted with the back feed fine, after the
first fix (0f32282) asked `RotationCoordinator` for `videoRotationAngleForHorizonLevelPreview`.
That connection feeds a video *data output* — a capture connection — and the preview angle follows
the interface orientation while the capture angle follows the horizon, which accounts for exactly a
90° disagreement on a phone clamped to a cane. `connect()` now prefers
`videoRotationAngleForHorizonLevelCapture`, falls back to the preview angle, then to a
per-position portrait default (front 270, back 90) instead of a blind 90, and records the applied
angle per camera. `diagnostics` gains `front_rotation` / `back_rotation` (logged in the
`both_cameras` start record; `-1` = that camera never connected), so the next device run says
whether the coordinator or the fallback is to blame with no further guess-runs. `CODE_REFERENCE.md`
gains the missing `DualCameraSession` section in the same change. Follow-up the same morning:
the upright front inset read backwards (mirrored) — the inset now sets `isVideoMirrored = false`
so it agrees with the back feed on left/right, and logs `front_mirrored` beside the angles.

Reviewed but deliberately **not** merged tonight: the emergency-siren rework
(`cane-wt-emergency`: siren gate 0.50 → 0.60, three agreeing windows, `.emergency` urgency → `.nav`
band, `best(of:)` so traffic noise cannot shadow a siren) and hands-free voice control
(`cane-wt-handsfree`: Status / Ask / Silence-haptics shortcuts taking the list to the 10-shortcut
limit, `QuestionPrompt` / `StatusSummary` in Logic with tests). Both were read end to end: the
siren `best(of:)` fallback path preserves the policy's below-gate reset semantics and introduces no
force-unwrap or crash path, and the Hazards-toggle crash itself is already fixed on main
(`fix/launch-crash` + `fix/sound-watch-hardening`). They stay unmerged because the merge gate needs
`make test` / `make sim` / `make uitest` / `make e2e` green and none of those can run from this
sandboxed session — merging untested the night before the demo would break the gate that protects
the walker.

test on device: turn on Both cameras with the phone clamped in portrait; front inset upright and
mirrored, back feed upright; trip log `both_cameras` start record reads `front_rotation: 270,
back_rotation: 90` with both frame counts climbing. Then run the gate in your own terminal
(`cd ios && make test`, `make sim`, `make uitest`, `make e2e`) before merging anything.

## Step 14 — The night before: what was broken and what is new (Fri Sep 11, simulator only)

Everything below is verified by 303 CaneKitLogic tests, a clean Swift 6 strict build and a green
`make uitest`. The phone left the building partway through, so **the device column is honest: much
of this has never run on hardware.** See the WHERE WE ARE block in docs/todo.md.

### Found broken, fixed

- **The Live Activity has never existed in any installed build.** `scripts/gen.sh` worked around
  XcodeGen issue #1613 with an unanchored `sed` that rewrote *every* copy-files phase from
  `dstSubfolderSpec` 13 to 16. XcodeGen already emits 16 for the watch, so the substitution's only
  live effect was moving the **widget's** embed phase out of `PlugIns/` — and a widget outside
  PlugIns is never loaded, so `Activity.request` failed and the error was swallowed into
  `lastError`. No crash, no log, just no Dynamic Island, while the docs promised one. Confirmed
  before the fix: zero `dstSubfolderSpec = 13` in the pbxproj and no `PlugIns/` inside
  `CaneKit.app`, with `CaneKitWidget.appex` sitting loose beside it. The patch now touches only the
  phase whose `dstPath` is the Watch folder, and `gen.sh` **asserts both phases afterwards** rather
  than hoping — a widget in the wrong folder produces no error at build or run time, which is
  exactly why this survived so long.
- **Muse Spark could not answer at all.** With the key wired, the trip log showed
  `provider: "Muse + On-device"`, `ms: 11066`, and a spoken line that was the on-device LiDAR
  template. `max_tokens` was 120, which one sentence needs — but on that endpoint the budget covers
  **reasoning plus visible output**, and the model spent it thinking and returned `content: null`.
  An empty reply reads as a failure, so the app fell back, silently, after blowing the 8 s timeout.
  A direct probe with `max_tokens: 10` reproduced it in miniature: `finish_reason: "length"`,
  `content: null`, `reasoning_tokens: 7`. Now 1024 tokens and `reasoning_effort: "low"` (Meta's own
  guidance for direct-answer tasks; `"none"` is a documented HTTP 400 on Muse Spark). The field is
  omitted for any other OpenAI-compatible endpoint, because a non-reasoning chat model rejects it.
- **The cloud scene sentence was spoken ungated.** `SceneVocabulary.isFaithful` ran only on the
  on-device path. Measured hallucination classes now refused: street names Vision never read on this
  route's own frames ("S Grand Blvd"), distances that contradict LiDAR, counts (models measure ~53 %
  there), clock-face directions — and, worst, a false all-clear: handed a solid white frame a model
  said *"The path ahead is clear and unobstructed"* four times out of four. Telling a blind walker
  the path is clear when the lens is covered is the worst failure this app has.
- **The voice alternated between Bella and Apple's, line to line.** Warnings never wait for the
  network, so an `.obstacle` / `.safety` cache miss is spoken by AVSpeechSynthesizer at once, while
  nav and scene lines — prefetched per route — played as Bella. `commonLines` only prefetched
  *fixed* strings and warning lines are generated. `SpokenPhrases` now enumerates the whole finite
  warning phrase space and the launch prefetch warms it: **74 lines, 1,722 characters, 17.2 % of the
  monthly free tier**, paid once because every line is cached on disk forever. The safety rule is
  untouched — the cache simply already has the line.
- **VoiceOver read the words on screen instead of the sentence we wrote.** A suggestion row's
  accessibility modifiers sat on the `Button` rather than on its label, so `children: .ignore`
  applied outside it left the composed children exposed: "Grainger Engineering Library, On campus,
  Campus". Both labels were observed on the same row in one test run, which is what made the test
  flaky. (The second "failing" test was not a bug at all — it was simulator contention from a
  concurrent `make e2e`, which also produced a bogus "harness error: No such file or directory".)
- **Tapping Go with an empty box said nothing** — it only drew the error. The person most likely to
  do that is the one who cannot see the box is empty.
- **A self-test paused ARKit for ~13 s at launch**, so pressing "Where am I" in that window answered
  "Camera warming up. Try again." and looked like a broken app. The self-tests are debug buttons now.

### New, all off by default

- **"Both cameras (pauses obstacle detection)"** — the front and back camera on screen at once via
  `AVCaptureMultiCamSession`, with ARKit explicitly paused. ARKit can never deliver both pictures;
  Apple DTS, developer forums 677731: *"There can only be one running capture session at a time,
  ARKit requires a running capture session, and there is no ARConfiguration that will enable you to
  receive both the front and rear camera image, so the functionality that you are looking for is not
  possible."* `ARFrame` structurally has one `capturedImage`. Pausing ARKit is therefore the only
  design. Announced out loud both ways, refused while a route is guiding, torn down on backgrounding.
  **No `AVCaptureVideoPreviewLayer`**: forums 742501 reports LiDAR depth going unreliable once a
  preview layer joins a session producing depth, and depth is the safety channel.
- **"Head tracking without AirPods"** — `userFaceTrackingEnabled` → `ARFaceAnchor` yaw as a second
  source for the beacon and Recenter. This is what lets the beacon work for someone who has only the
  phone, which is the point.
- **"Listen for sirens and horns"** — SoundAnalysis over the microphone, the one feature that leaves
  `.playback`. It never requests HFP, compares the **output route** before and after, and reverts —
  refusing itself — on any change. Measured with no headphones: output stayed `Speaker`, restore
  worked. **The AirPods case is unmeasured**, which is precisely why the revert exists.
- **People and animals named with measured distances** — `DetectHumanRectanglesRequest` and
  `RecognizeAnimalsRequest`, different models from the 1,303-class classifier that returned *zero*
  usable labels on the phone. Distances come from a LiDAR grid read inside each detection's own
  bounding box; outside 0.3–5 m the walker hears the direction with **no** distance rather than a
  made-up one.

test on device: **most of this has not run on hardware.** In priority order: the Dynamic Island now
that the widget is actually embedded; "Where am I" with the Muse key (expect `provider: Muse`, `ms`
well under 8000, and a sentence naming what is really there); that every warning comes out in Bella's
voice; people named with plausible distances; and only then the two-camera mode, whose render path
was rewritten after its only device run and has never been seen to draw.

## Step 13 — Voice control, live camera view, natural voice, nearest-result search (Fri Sep 11, on device)

Everything in this step was driven by the phone itself, not the simulator.

**Voice control (a blind walker cannot use the Guide card).** Seven App Shortcuts — of the ten an app
may register — in `AppIntents.swift`: Where am I · Take me to *\<place\>* · Navigate to CIF from here ·
Start the demo route · Repeat the last instruction · Next waypoint · Stop the route. Each forwards to
one `AppModel` method, so Siri, the Action button, the watch and the on-screen buttons all share one
code path. All are `.foreground(.immediate)` because ARKit obstacle warnings only run frontmost:
guidance must never start silently in the background. App Shortcut phrases cannot interpolate a
`String` (Apple allows only an `AppEnum`/`AppEntity`), so the phrase form carries the seven gazetteer
places as a `CampusDestination` AppEnum and any other destination goes through "Take me somewhere in
CaneKit", where Siri asks for the free text. Verified from the built
`CaneKit.app/Metadata.appintents/extract.actionsdata`: 7 shortcuts, 21 phrase templates.

**"Navigate to CIF from here."** MKDirections walking from the live fix to `route_isr_cif.json`'s last
waypoint as a bare coordinate — no search, so MapKit cannot pick a different "CIF".

**Destination search was bad.** `CampusPlaces` (CIF, ISR, Grainger, Illini Union, Siebel, Main Library,
ARC → entrance coordinates) is now consulted *before* MapKit, because MKLocalSearch answered "Grainger"
with an industrial supply store. On a miss it searches a ±3 km region with `regionPriority = .required`
and `DestinationPicker` takes the **nearest** sensible result rather than MapKit's first. Every MapKit
route now speaks "Walking to Grainger Engineering Library, 750 meters." before guidance starts, so a
wrong pick can be stopped before the walker moves.

**Fixed: route hijack (safety).** A Siri search still in flight when the walker pressed Start demo route
would return later and call `beginRoute` again, swapping them onto the searched route mid-walk with no
indication. Start and Stop now abandon an in-flight build.

**Fixed: trip-log field collision.** Cue and hazard events passed a field named `kind` that overwrote
the record's own, so hazard records came out as `{"kind":"sign"}` and `e2e.py` never saw one. Fields
renamed (`cue`, `type`), and `TripLogRecord` (CaneKitLogic) now makes it structurally impossible: a
colliding field is kept as `field_t` / `field_kind` and can never win.

**Live camera view** (`LiveCameraView`, Hazards card, off by default). An `ARSCNView` bound to the app's
existing `ARSession` — display only, it never runs, pauses or delegates the session — replacing a 3 Hz
JPEG. Drawn at the camera rate, capped at 30 fps so the preview cannot steal frames from obstacle
detection, blank in the background and on the lock screen, and torn down safely. For the sighted spotter
and the demo video; it is off by default because it costs battery and heat and a blind user gains
nothing from it.

**Natural voice (ElevenLabs) made first-run-proof.** The code has existed since Step 7 but had never run
against a real key. Two things would have bitten: prefetch shared the 2.5 s live-speech timeout (nobody
waits on a prefetch — on a slow first connection every one would fail silently, turning each route line
into a live miss that *also* had 2.5 s to fail), and `voiceError` was recorded but never rendered, so a
wrong key looked exactly like no key. Prefetch now gets 15 s and reports its first real failure to the
Haptics card, where a bad key reads "ElevenLabs HTTP 401" seconds after launch. Still blocked on
`ELEVENLABS_API_KEY` in the git-ignored `Secrets.plist` — see docs/todo.md.

Verified: 164 Logic tests pass, `BUILD SUCCEEDED` with no warnings, installed and launched on the phone.

test on device: say each of the seven phrases with the phone locked and AirPods in (the app must come to
the foreground and act); "Take me to Grainger in CaneKit" must reach the Springfield Avenue entrance,
not the supply store; say "Stop the route" while "Finding a route…" still plays and confirm nothing
starts after; turn on Live camera view on the Hazards card and confirm it is smooth and goes blank when
the screen locks; AirDrop the trip log and confirm hazard records read `"kind":"hazard"` with a `"type"`
field and that no line contains `field_kind`.

## Step 12 — Google Street View mock of ISR → CIF: what failed and the fixes (Fri Sep 11, pre-device)
The 14 Street View frames of the route (local-only, `ios/scripts/streetview/`) now drive the camera in
the simulator end to end, and the log shows what the camera saw, not only what was spoken.
- **Found: "Where am I" spoke Vision's taxonomy.** At Green Street the on-device template would say
  "Automobile, machine and vehicle in view.", at Springfield "Conveyance, portal and manhole in view.",
  in the ISR lounge "Furniture, table and conveyance in view." **Fix:** `SceneVocabulary` (CaneKitLogic,
  5 tests built from the real Street View labels) keeps pedestrian nouns only, merges synonyms, drops
  hypernyms and says crossing information first: "Ahead: the street and cars.", "Ahead: a crosswalk,
  a path and the street.", "Ahead: tables, chairs and windows." It feeds both the template and the facts
  given to Apple's on-device model.
- **Found: sign reading range was a guess.** `ios/scripts/sign_probe.swift` pastes a "SIDEWALK CLOSED"
  sign onto every route frame at many sizes and runs the app's exact text request. Measured: the old
  1/80 floor read 7.5 cm letters from ≈ 4.4 m (Vision's default only 1.7 m). **Fix:** 1/128 → 7.5 cm
  letters from ≈ 7 m and 15 cm from ≈ 14 m on every frame, with no measurable extra OCR time
  (~7 ms/frame on the Mac). At walking pace that is two 3 s scans before you reach a sign, not one.
- **Found: STOP signs would be read at every corner.** With the longer range a STOP sign (a drivers'
  sign) reads from across an intersection. **Fix:** "STOP" is no longer a sign phrase; "PUSH BUTTON"
  (a crossing sign a walker can use) is. Test `stopSignsAreForDriversPushButtonIsForWalkers`.
- **Found: the camera path was invisible.** The Street View e2e "passed" with no record of any sign scan
  or description. **Fix:** new trip-log records `scan` (text read, line said, frame), `hazard_watch`
  (raw reply, latency, dropped/why, error) and `describe_result` (what "Where am I" actually said,
  error, ms), useful on the phone too. `make e2e SCENARIO=streetview` now turns on the hazard watch,
  asks "Where am I" at the start and every waypoint (`CANEKIT_DESCRIBE_EVERY_WAYPOINT`), fails unless
  ≥ 8 of 10 corners are described, and reports per-corner sentences.
- **Found: far storefront words would be read** (Muse + Antigravity): with 1/128 text, "EXIT" / "PUSH"
  across the street matches. **Fix:** one-word phrases need the text line ≥ 1/80 of the frame tall
  (close); multi-word safety phrases ("SIDEWALK CLOSED") still read from far (`SignPolicy.SeenText`,
  `shortPhraseMinHeight`, test `farTextReadsSafetySignsButNotStorefrontWords`). The measured range is
  for a flat, frontal sign in good light; expect less on a moving cane.
- **Found: Apple's on-device model invented facts.** On a Street View corner "Where am I" said "No
  hazards detected. Distance: 0 meters." **Fix:** a new prompt (name what is there; numbers only from
  the facts; never "no hazards") and `SceneVocabulary.isFaithful`: the model's sentence is spoken only
  if it names something detected and invents no numbers, else the template speaks (test
  `modelSentencesMustBeFaithfulToTheFacts`). The unguarded Street View e2e showed the model said "No
  hazards detected. Distance: zero meters." at 7 of 10 corners and turned OCR junk ("11", "J.I" off
  road markings) into "11 meters to the edge". Now spelled-out numbers are checked too and only
  word-like text (`SceneVocabulary.readableTexts`) reaches the model; all four real bad sentences are
  test fixtures (`streetViewModelNonsenseIsRejectedAndOCRJunkFiltered`).
- **Found (Muse + Antigravity): people, ice and houseplants.** People were filtered out entirely (a busy
  sidewalk said "nothing"); ice and snow ranked below benches; an indoor "plant" became "bushes".
  Fixed with tests (`peopleIceAndPlantsAreSaidSensibly`). Diagnostics now record the frame that was
  *sent*, not the one current when the reply came back; the arrival corner is described too.
- **Rejected:** refusing to start a route when the camera is off (Antigravity). Guidance works without
  the camera; the app warns loudly and still guides. The on-screen error now survives (it was cleared
  right after being set). Antigravity also edited files during a "read-only" review; its edits were
  audited one by one and reviews now run it on a copy of the repo.
- **Final review of b1c35bd (Muse + Antigravity on a repo copy), all fixed with tests:** the model gate
  now accepts synonyms and plurals ("road", "car", "crossing"), rejects prefix look-alikes
  ("businesses" ≠ "bus"), and compares numbers with spelled facts and decimals kept whole ("two
  meters" allows "2"; "1.4" does not license an invented "4"); far text lines are never joined (a
  distant "ROAD" + a shop's "CLOSED" is not a sign) and missing text heights count as far; the "Where
  am I" template uses sized text too; the camera-denied warning is spoken once, not twice in a row.
  Tests `faithfulnessUnderstandsSynonymsAndSpelledNumbers`, `decimalsInTheFactsStayWhole`,
  `farLinesAreNotJoinedIntoAPhantomSign`.
- **Review of 3efc0b1 (Muse), all fixed with tests:** with nothing detected the model is never
  trusted (a blank wall cannot become "A door ahead."); teens and tens count as numbers; a misread
  "EX1T" still counts as text; a `SeenText` of unknown size is far by default (the tuple overload is
  for test fixtures only); the Street View e2e needs a clean hazard-watch reply, not just a record.
  Tests `blankWallsTeensAndMisreadsAreHandled`, `unknownTextSizeCountsAsFar`.
- **Review of 3efc0b1 (Antigravity, on a repo copy):** "Where am I" still showed the language model
  far lone words; `SignPolicy.mayMention` (close, or several words) now filters the facts too (test
  `onlyCloseOrMultiWordTextMayBeMentioned`).
- **Muse camera review (after 45230fe):** fixed — the retained camera frame is refused after 2 s
  (`DepthFrameProcessor.maxFrameAge`: an ARKit stall no longer describes a corner already left); the
  Mount card judges the tilt it shows (2.6° reads "3°" and is now "good"); a sign scan with no fresh
  frame no longer spends its 3 s slot. Rejected with reasons — gating *cloud* sentences with
  on-device labels (the cloud model sees the image; coarse labels would reject good answers), dropping
  the LiDAR gate on on-device hazard labels (deliberate, AGENTS.md: it stops "fence" chatter along
  railings). Deferred — clamping cloud hazard-watch distances (the watch ships off by default).
- **Antigravity nav review:** fixed — a new route no longer starts from a GPS fix older than 30 s.
  Rejected — stopping the watch keep-alive on "No route" (deliberate: a suspended watch app could not
  restart it for the next route). Deferred to the device session (logged in docs/todo.md): head
  tracker started without AirPods (battery), the launch "Phone is hot" line before the audio session
  is configured, skipped waypoints not announced in the rare passed-by-plus-skip case.
- **Simulator scene recognition, settled:** Vision classification fails in the simulator ("Failed to
  create espresso context"); a CPU-pinned `VNClassifyImageRequest` was tried and returns all 1,303
  labels at ~0 confidence, so it was removed again. Scene words are tested with `vision_probe.swift`
  on the Mac (real labels) and `SceneVocabularyTests`, and on the phone. The trip log's
  `describe_result.vision_error` shows this directly.
- **Antigravity camera review:** fixed — `VLM_PROVIDER` is case-insensitive ("Gemini" no longer
  silently ignored); a hazard-watch reply that lands after the watch was switched off (or paused hot)
  is not spoken; a failed request clears its latency. Rejected with a test — "the tilt sign is
  inverted": the formula moved to `MountTilt.downDegrees` and `tiltSignIsDownPositive` proves down is
  positive. Rejected — ground-hazard "flicker" (a hazard the current frame no longer sees drops out
  by design; the repeat policy prevents re-announcing it).
- **Muse nav review:** fixed — a GPS jump past the destination's fence (passed-by arrival) now gives
  the arrival tap; Repeat after a skip-ahead includes "Passed one waypoint."; a heading-age check that
  could never fail was removed (headings arrive current). Rejected — "Repeat dropped during a call"
  (no caller uses a zero TTL; a 12 s Repeat expiring mid-call matches the queue's staleness rule and
  Repeat works again after the call).
- **Claude review workflow (10 agents, 16 confirmed, 9 rejected), all addressed:** Apple's model
  invented "a crosswalk, then stairs, then a door" from the prompt's own examples (4/4 on the Mac)
  → examples removed, `isFaithful` now rejects any vocabulary object that was not detected, and a
  LiDAR distance is spoken first (test `inventedObjectsAreRejected`); `.prefix(8)` cut the crosswalk
  behind synonyms → removed; far two-line signs ("SIDEWALK" over "CLOSED") are joined when the line
  geometry shows one sign (`SeenText.box`, test `farStackedSignLinesAreJoined`; sign_probe
  re-measured with the same rule: still ≈ 7 m for 7.5 cm letters); a deep drop is reported at the
  end of the last visible ground, not a metre past its hidden edge (test
  `aDeepDropIsReportedAtItsNearEdge`), and long stairs down / ledges over ~0.6 m are documented as
  not detected; a second "Veer" now needs a full 3 s hold after the course reset
  (`OffCourseDetector.endEpisode`, test `endEpisodeRequiresAFullHoldAgain`); sign lines keep 20 s in
  the queue; the first head-height cue after unlock is spoken; the Street View e2e reports "no scene
  labels (simulator limit)" as a warning; docs: the Team ID instructions (the parentheses in a
  certificate name are not the Team ID), the AirPods check order, Guided Access options, stale
  comments.
- **Muse + Antigravity on f5413b8:** fixed — the LiDAR distance is prefixed unless the model's sentence
  states that *number* (`SceneVocabulary.mentionsDistance`; "parking meters" / "kilometers" matched
  the old substring check); words the facts contain (and "sign" when text is visible) count as
  grounded, so "a sign says sidewalk closed" is accepted; sign lines keep 8 s in the queue (20 s could
  play 25 m past the sign); a gated-out veer moment ends the episode (no instant veer after a GPS
  gap). Tests `plainGoodSentencesStillPass`, `factWordsAreAllowedAndDistanceIsANumber`. Rejected —
  "the first head cue after unlock replays a stale cue": the decider is reset on background, so any
  head cue after unlock is a fresh LiDAR detection and should be spoken.
- **First real-phone build (iPhone 17 Pro Max, iOS 27.0):** signed with the free Personal Team,
  installed. Found: a comment after the value in `ios/local.mk` (the format the docs showed) left
  trailing spaces in `DEVICE`, so xcodebuild could not find the phone; the Makefile now strips
  `TEAM` and `DEVICE`. First launch needs Settings → General → VPN & Device Management → Trust.
- **Real-phone desk test (iPhone 17 Pro Max, iOS 27.0) — found and fixed:**
  - *Depth ran at exactly 10 reports/s, not 15*: a `now − last ≥ 1/15` check fails by a hair on the
    second 33.3 ms frame. `PublishGate` (CaneKitLogic, tested with 30 and 60 Hz input) fixes it; the
    cap is now **30 reports/s** (CueDecider is timed in seconds, so no logic change), mesh lookups stay
    ~4 Hz. Measured: 30/s, thermal nominal.
  - *Camera*: ARKit with LiDAR offers only the 1x wide camera on this phone (up to 60 fps; no 0.5x,
    no 120 fps; the front camera only as face tracking), logged in the `start` event. The app now
    runs the full 4:3 frame at 60 fps (was 16:9 at 30).
  - *"Where am I" mixed two moments*: the LiDAR context was read for the facts and again ~0.7 s later
    for the prefix ("…looks like a table. A door is one meter ahead."). One snapshot per description.
  - Proven: LiDAR, haptics, mesh names, head-height cue, on-device Vision + Apple's model.
- **Final Muse + Antigravity reviews (after 33fc636), all addressed with tests:** a closer hazard-watch
  update is not a duplicate; stacked sign lines join across the close/far boundary and close words
  need geometry too; missing depth bins allow for ramp slope (no false drop-off); a drop in the last
  bin waits; invented hazard words ("cone", "barrier") are rejected; the watch slot is refunded
  without a frame; a mid-route screen lock *says* obstacle warnings are paused; a new route clears
  the last drop-off line; haptics failure is always announced; the mount tilt updates every frame;
  a new route forgets the old heading; the hazard watch ignores a stale fix's speed. Rejected —
  waiting for a fresh fix before a typed-destination route (a standing walker's fix is still right
  and iOS may not send a new one). Antigravity again edited and committed in its *copy*; the real
  repo was untouched.
- **Phone follow-up (hand-held false hazards, heat, spam):** ground hazards are judged only with a
  mount-like camera tilt (0-15 deg, `MountTilt.groundUsable`) and a plausible ground 0.5-1.3 m below
  the camera (`groundHeightRange`): every false "Hole ahead" on the phone came at 10-57 deg with the
  phone in the hand, or with a desk as "ground" (tests `aDeskIsNotTheGround`,
  `groundHazardsNeedAMountLikeTilt`). Drop-off and hole frames agree as one hazard (no last-bin wait;
  `dropAndHoleFramesAgreeAsOneHazard`); missing bins get per-reference ramp slack. Camera back to the
  full 4:3 frame at **30 fps by default** with a "60 fps camera (warmer)" switch (both reviewers:
  60 fps + 30 Hz untested for heat over a walk). The screen-lock warning is spoken once per route,
  and the "back" line is gone. Hazard-watch refund retries in 2 s, not every tick. Rejected —
  "tilt on every frame skews lanes/veer" (the tilt feeds only the Mount card and the log).
- **Engineering bar written down:** `AGENTS.md` → "How we engineer" (and `CLAUDE.md`), so every
  contributor, human or AI, works the same way.
- **Found: "CaneKit ready." after "Camera access is off"** (Antigravity docs review): the ready line is
  now skipped when the camera is refused.
- **Teammate handoff:** `docs/TEAM_HANDOFF.md` (read first after a pull), README / docs index / iOS README
  refreshed, doc drift fixed after Muse + Antigravity reviewed the teammate-facing docs.
- Test on device: in airplane mode, "Where am I" at a street corner says plain words ("Ahead: a
  crosswalk…"), never "conveyance" or "portal"; a printed "SIDEWALK CLOSED" sign (7.5 cm letters) is read
  from ~6–7 m; walking past a STOP sign says nothing; the trip log has `scan` and `describe_result` lines.

## Step 11 — Hazards the maps don't know, on-device vision, stress harness (Fri Sep 11, pre-device)
- **LiDAR ground hazards.** `GroundSampler` projects the depth map into the walker's
  gravity-aligned frame; `GroundHazardDetector` (CaneKitLogic) finds drop-offs, holes, curbs up and
  low obstacles 1.5–3.5 m ahead in the walking corridor, ignoring smooth ramps and anything taller
  than 50 cm (the lane grid's job), confirmed on 3 of 5 trusted frames. Spoken at safety priority
  ("Drop-off ahead, two meters.") with 4 heavy taps on the cane.
- **Signs, on-device.** Vision text recognition every 3 s: "Sign: sidewalk closed." / detour /
  construction / stop / exit…, each at most once a minute. Offline.
- **Hazard watch.** While walking a route, one frame every 8 s to the vision model asking only for
  path hazards (cones, barriers, trenches, scooters, low branches); "NONE" is silent.
- **On-device "Where am I".** Apple Vision (scene labels + text) + Apple's on-device language
  model phrase one sentence with the LiDAR facts; a template when Apple Intelligence is off. Cloud
  providers now fall back to it automatically, fail fast (8 s), and a key is no longer required.
- **Hazard map.** Every announced hazard → `Documents/hazards/hazards-<session>.geojson` with GPS and
  a photo; "Share hazard map" on the new Hazards card, which also has a live camera view.
- **Route cues on the cane.** Long soft buzzes (turn left 1, right 2, crossing 3, arrived
  long-short-long) alongside the watch.
- **Review fixes (Muse + Antigravity full-app reviews):** GPS course no longer dropped by the sweep
  gate; location / camera denied are spoken instead of silent; GPS stops after arrival; a second
  route start restarts cleanly; beacon restarts on foreground; natural-voice circuit breaker on weak
  networks; interruption fallback never drains over a live call; AirPods route flaps debounced; head
  tracker stops when AirPods disconnect; watch workout stops after arrival and restarts next route;
  late watch send failures tap `.retry`; heat downgrade is announced; no force-unwrapped URLs from
  Secrets. Rejected with evidence: `@concurrent` and `HKQuantityType(.stepCount)` "don't compile"
  (both valid; the build is green).
- **Jitter-proof veer.** `CourseSmoother` (15 m / 5-fix ends) feeds the veer decision while walking:
  simulated ±6 m jitter produced 28 false veers with per-fix course, zero across 20 runs smoothed.
  An arrival hint is spoken after 20 s near the destination without arrival.
- **Stress harness.** `make e2e`: GPS-replay scenarios through the real app in the simulator
  (clean, missed_fence, gps_jitter, wrong_turn) asserting on the trip log. The debug footer is gone.
- **Round-5 review (22 confirmed findings, all fixed).** A 61-agent adversarial review with
  ray-cast and nav-engine simulations found, and this step fixes:
  - *Curbs warned too late under a real sweep* (confirmed only 1.2–1.7 m ahead at 1.2 m/s): the
    ground path now has its own 1.5 rad/s gate on raw depth, ~7 evaluations/s (simulated: 2.3–2.6 m).
    A curb face landing mid-bin is found (edge vs the previous two bins); the distance is the nearer
    edge; a rise in the last bin waits for a closer look.
  - *False "Veer" after the WP2/WP3/WP6 corners on every clean walk*: the course smoother stays empty
    inside the corner's fence and resets after each veer cue. Nav harness running the real
    NavigationEngine: 0 false veers in 72 walks (clean, ±2 m jitter, ±15°/25° course noise), and an
    injected 35° veer caught once in 18/18 walks.
  - *The 2.5 s voice deadline repeated a finished line in the robot voice*: fetch and deadline are
    now mutually exclusive.
  - *Stale camera after unlock*: the paused frame is dropped; LiDAR context cleared on background.
  - Standing at a curb no longer repeats the warning every 6 s (same hazard: 1 m closer or 30 s);
    partial sign reads ("CLOSED" after "SIDEWALK CLOSED") stay quiet; signs read from farther
    (small text); hazard-watch cloud cut off at 2.5 s, stale replies dropped or lose their
    distance; the on-device LiDAR gate uses the centre lane only; hazards after arrival keep their
    location (null geometry with no fix); arrival hint works while standing still; a typed
    destination with Location off is refused at once; haptic engine retries after non-suspension
    stops; watch keep-alive ignores callbacks from old sessions; live view pauses when hot.
  - e2e: tick-based time budget (gps_jitter could never arrive), per-scenario error isolation, no
    stale report, and an opt-in `streetview` scenario (Street View frames as the camera).
    `make tour` / `make uitest-streetview` never passed their folder to the test runner
    (`TEST_RUNNER_*` was a trailing build setting); it is now in xcodebuild's environment.
- **Round-6 check (Muse + Antigravity on the round-5 fixes).** Muse: the "head height" context line
  now uses the centre lane only too; a hazard is geotagged with the nav engine's last fix only if it
  is under 2 minutes old; the haptic engine is not retried during a call (restarted on the
  interruption's end) and retry loops never stack. Antigravity's "swap max/min in the edge test"
  was rejected: it reverts the mid-bin curb fix (the tests show the fix finds the curb and 10 %
  ramps stay silent); the ~11 % ramp trade-off is documented in AGENTS.md.
- **Phone-to-cane mount (hardware/mount/, for Sagar).** Printed PETG clamp for the 28.75 mm pole with
  a 5°-detent hinge, OpenSCAD model, test coupons, a pitch model and a T0–T11 bench protocol. Its key
  finding: the lane grid has no gravity correction, so the camera must aim 3–8° below the horizon,
  not 10–20°. The Mount card now shows "Camera tilt N° down · N fps" live (`MountTilt`, tested), and
  every `lanes` log line carries `tilt` and `fps`.
- Test on device: Mount card reads "Camera tilt …, good" with the cane held normally and the cane stays
  quiet on an empty sidewalk; turn on "Detect drop-offs", then walk at a curb sweeping normally → the warning
  comes ≥ 2 m before the edge, once, and not again while you stand there; point the cane at a curb 2 m ahead → "Drop-off ahead, two meters." + 4 taps; hold a
  printed "SIDEWALK CLOSED" sign in view → "Sign: sidewalk closed." once; airplane mode + "Where am I" →
  an on-device sentence; walk past a waypoint → cane buzzes as well as the watch; Share hazard map →
  a GeoJSON that opens in geojson.io.

## Step 10 — Two adversarial review rounds, AirPods/Watch presence, XCUITests (Fri Sep 11, pre-device)
Round 1 (full-app review, 65 agents) and round 2 (review of the round-1 fixes, 5 dimensions, 30+
findings) and a Muse review of the result are folded in. Verified by 79 logic tests, a green simulator build, 6 XCUITests and the
screenshot tour on the **iPhone 17 Pro Max / iOS 27** simulator, and a GPS replay with deliberately
missed fences. Every rule with a number in it moved to `CaneKitLogic` with tests
(`NavSupport.swift`: TurnSettle, StraightWalkDetector, CueSpeechPolicy, CrownAccumulator).

- **A missed fence never strands the route.** Skip-ahead over the next two waypoints ("Passed one
  waypoint." + the real line); passed-by detection (2× radius, then receding a radius, 1 m jitter
  tolerance) says "Passed Goodwin Avenue. Green Street in 150 meters." instead of a stale "turn right";
  near a waypoint the beacon follows the recorded leg bearing and veer cues are muted, so nothing points
  back at a missed waypoint. "GPS weak" fires at the same 20 m that pauses the fences.
- **Arrival is plausible, not lucky.** `distance + accuracy/2 ≤ 20 m` on two consecutive fixes; one 30 m
  blob 45 m short of CIF can no longer end the route.
- **No false "Veer" at corners.** The turn settles on distance (6 m, or receding on two good moving
  fixes), on the body heading matching the new leg, or after 25 s of *moving* time — never on a timer,
  never on a standing fix. At a crossing the beacon is silent until you reach the curb. WP1's S-shaped
  path is marked `curved` (no veer, beacon quiet), WP3 is a turn not a crossing, turn fences are 12 m,
  and WP6 now says "Turn left to face west" before the crossing.
- **Beacon honesty.** Plays only into headphones; ignores AirPods yaw until re-zeroed after a turn (no
  double-counted body turn); auto-recenter needs 3 straight fixes and never fires within 15 m of a
  crossing; restarts after a phone call with retries.
- **Speech that is never lost or looped.** Priorities scene < obstacle < route < "Head height.";
  an interrupted line resumes once (then Repeat); "Head height." once per obstacle episode; warnings
  never wait for ElevenLabs; calls/Siri queue lines and drain afterwards; watchdog for stalled backends.
  **Repeat** (phone, watch, "Repeat in CaneKit") says the last line actually spoken + where the next
  waypoint is, even mid-line.
- **AirPods + Watch presence.** New `AudioRouteMonitor`: "<AirPods name> connected." / "Headphones
  disconnected. Beacon paused."; at route start the app says which channel is missing (no headphones,
  watch not reachable, no haptics). Guide card pills show "No AirPods" / "Head tracked" / "Compass only".
  Watch: distance in the title bar, phone-link glyph, Repeat / Next / Describe / Recenter fit a 42–46 mm
  screen, crown = 3 detents within 1 s, "Update the phone app" when the phone is older than the watch.
  Watch gets a status update on every fix (was: only at waypoints). See `docs/devices_setup.md`.
- Silenced or dead haptics mirror obstacle cues to the watch and speak them.
- UI: two-per-row guide buttons (no hyphenated "Recen-ter"), single-line pills, fixed "Go" button,
  full instruction text; Repeat stays after arrival.
- Infra: `make uitest` / `make tour` / `make sim17` / `make sim-grant`; `.github/workflows/ci.yml`
  (logic tests on every push); `AGENTS.md`, `CLAUDE.md`, `docs/CODE_REFERENCE.md` for future agents.
- Test on device: see `docs/devices_setup.md` first (AirPods Spatial Audio off, watch app open). Then:
  walk past WP2 on the far side of the path → "Passed Illinois Street sidewalk…" and no "Veer"; at
  Goodwin keep walking to the corner → no "Veer" until you turn, beacon then swings north; at Green St
  stand at the curb with your head turned → no clicks until you face north; tap Repeat on the watch
  mid-line → the line again + distance to the next waypoint; pull the AirPods out → "Headphones
  disconnected. Beacon paused."; toggle Silence haptics and raise a hand overhead → wrist tap +
  "Head height." once; take a call mid-route → speech and beacon resume.

## Steps 8–9 — Scene description, arrival card, Live Activity (Fri Sep 11, pre-device)
- "Where am I": VLMClient protocol with OpenAI-compatible (Muse 1.3 / OpenAI), Anthropic and Gemini
  transports (bodies + parsing unit-tested), SceneDescriber (waits ≤ 3 s for a camera frame, 1024 px JPEG
  off-main, speaks the sentence or a spoken error), triggers: on-screen "Where am I", watch Describe,
  Camera Control (spike), Action button via the "Where am I" App Shortcut (+ "Start CaneKit route").
- TripTracker: elapsed, GPS-integrated distance (moving fixes only), steps from HealthKit (watch-merged)
  with the phone pedometer running alongside; spoken arrival summary after the count refreshes.
- Live Activity: CaneKitWidget target (Dynamic Island + lock screen glyph/instruction/distance), updates
  coalesced to waypoint changes or ≥ 10 m, ends 60 s after arrival. ArrivalCardView while walking / on arrival.
- Automation: `CANEKIT_DEMO_ROUTE=1` env (or `--demo-route`) starts the demo route at launch.
- Test on device: press "Where am I" → "Describing." then one sentence (needs a key in Secrets.plist; without
  one it says so); Action button → same from the lock screen; walk the route → Dynamic Island shows the
  next instruction + distance; arrival → card + "CIF … meters, minutes, steps".

## Steps 6–7 — Navigation + beacon + natural voice (Fri Sep 11, pre-device)
- LocationService: `CLLocationUpdate.liveUpdates` + compass; GPS course replaces the compass while walking;
  background activity session so guidance survives a screen lock. NavigationEngine: geofence per waypoint
  (speak once, wrist cue crossing/turn, advance), live target bearing (recorded bearing when the fix is poor),
  veer left/right after 3 s off-course with an 8 s settle window after every turn, "GPS weak"/"GPS back".
  RouteSource: bundled Townsend→CIF file or MapKit walking directions to any typed destination.
  **Verified in the simulator with a GPS replay: waypoints 1→4 fire in order with the right lines and cues.**
- BeaconEngine: AVAudioEngine → AVAudioEnvironmentNode (HRTF) soft click at the absolute target bearing,
  listener yaw = −(heading + head yaw), silent < 10° error, full by 90°, ducks while speaking, survives
  AirPods route changes, safe across routes. HeadPoseTracker: AirPods yaw via CMHeadphoneMotionManager,
  Recenter (button / watch / auto 8 s after each turn).
- Natural voice: ElevenLabs TTS (`eleven_flash_v2_5`, warm premade voice by default) with a disk cache;
  route lines + common phrases pre-synthesized at route start; AVSpeech fallback offline / without a key.
  Keys: `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL` in Secrets.plist.
- GuideCard: instruction, hero distance, on-course pill, GPS pill, Next / Recenter / Stop, demo route or
  typed destination. `--demo-route` launch flag for automation.
- Test on device (outside, AirPods in): Start demo route at the ISR doors → route intro; walk west → sidewalk
  line + wrist tap at WP2; at Goodwin → crossing line + wrist notification; turn 45° off for 3 s → "Veer
  right"; beacon clicks from the walking direction and goes quiet when facing it; turn your head, body still
  → click moves the other way; Recenter zeroes it; AirPods out → still pans from the compass; Stop → silence.

## Step 5 — Watch (Fri Sep 11, pre-device)
- PhoneWatchLink (WCSession): nav cues (turn/crossing/arrived), obstacle mirror throttled 1/s per kind when the
  phone haptic engine is unhealthy or "Mirror obstacle cues" is on, status line via application context +
  live message, Next/Describe/Recenter commands in.
- Watch app: WKHapticType map (turnLeft .directionUp, turnRight .directionDown, crossing .notification,
  arrived .success, obstacle .failure; mirrored left .start / right .stop / center .click / head .failure),
  Next/Describe/Recenter buttons, crown = Next after 3 detents (0.8 s debounce), walking HKWorkoutSession
  keep-alive with delegate + WKExtendedRuntimeSession fallback (mindfulness background mode), initial
  application-context read, "Phone not reachable" feedback. HealthKit entitlements on both targets.
- Route: renamed "ISR Townsend Hall to CIF"; Townsend's only Illinois-St door is the ISR front door (WP1
  unchanged, spoken line updated); docs/route_isr_cif.md documents the evidence.
- Test on device (watch app open, wrist up): phone Watch card shows "Reachable"; Left/Right/Cross/Arrive
  buttons → distinct wrist taps; crown three clicks → phone says "Next."; Describe/Recenter buttons → phone
  acknowledges; toggle "Mirror obstacle cues" → obstacle taps on the wrist ≤ 300 ms after the phone buzz;
  lower the wrist for 30 s → cues still arrive (workout keep-alive).

## Step 4 — Speech + obstacle names (Fri Sep 11, pre-device)
- SpeechQueue: one `.playback` session (`.duckOthers`, no Bluetooth options, interruption re-activation),
  priorities scene < nav < obstacle, higher priority interrupts at a word boundary, FIFO within priority,
  TTL drops stale lines, utterance identity guards against the late `didCancel` race, enhanced en-US voice.
- ObstacleNamer: mesh class at the image centre → "door ahead, two meters" (door/wall/seat/window/table;
  walls only < 1.5 m), one line per 2.5 s, re-announces only on class change or a full metre of movement.
- AppModel: "CaneKit ready." on start, obstacle names toggle, speech test button + Speaking pill.
- Test on device (AirPods in): "CaneKit ready" comes out of the AirPods; walk to a door → "door ahead, two
  meters" once, closer → "door ahead, one meter"; a chair → "seat ahead…"; Speech test → the obstacle
  line cuts the scene line at a word boundary; take a phone call → speech resumes afterwards.

## Step 3 — Core Haptics (Fri Sep 11, pre-device)
- HapticPlayer: haptics-only CHHapticEngine, pre-built left (2 taps) / right (3 taps) / head (2 sharp hits)
  players, Geiger approach loop (single-transient player on a Task, 2 Hz at 2 m → 8 Hz at 0.5 m, intensity
  0.6 → 1.0), reset/stopped handlers, `isHealthy` for the watch fallback, silence toggle, test buttons.
- Cue router in AppModel: CueDecider → HapticPlayer; background stops cues and resets the decider.
- TripLogger: JSONL in Documents (lanes at 2 Hz, cues, session events; flushed every 2 s and on background).
- Runs in the iOS 27 simulator (UI verified); haptics + LiDAR need the phone.
- Test on device: clamp the phone; walk at a wall → taps speed up from 2 m to 0.5 m; hand at torso-left →
  2 taps, torso-right → 3 taps, head height → sharp double; back away → cue clears only past +0.15 m;
  "Silence haptics" stops everything; the four test buttons play their patterns; a log file appears in Files.

## Steps 1–2 — project scaffold + depth engine (Fri Sep 11, pre-device)
- Xcode 27 RC (27A266a) installed; XcodeGen 2.46.0; `ios/project.yml`, `scripts/gen.sh` (watch-embed patch,
  `WATCH=0` phone-only mode, Secrets copy), `Makefile`, `scripts/test.sh` (works with CLT alone).
- `ios/Logic` SwiftPM package (Foundation-only): LaneMath, LaneReport/TileLevel, CueDecider + GeigerRate,
  GeoMath (haversine, bearings, OffCourseDetector, GeofenceTracker), Waypoint/Route/RouteBuilder,
  WatchMessage envelope, VLM request/response codecs, SpokenDistance. **49 unit tests green.**
- App: CaneKitApp, AppModel (capabilities, settings, thermal + battery, Camera Control counter),
  DepthEngine (main-actor owner) + DepthFrameProcessor (background ARSessionDelegate, gyro gate, 15 Hz,
  smoothed depth, AsyncStream), MeshClassifier (centre-face lookup, face budget, raw-value guard),
  CameraControlInteraction spike, LaneGridView + DebugFooter, Theme.swift design system (docs/design.md).
- Watch: scaffold app + WatchTheme. Route: `Resources/route_isr_cif.json` (9 OSM-verified waypoints, 989 m).
- Reviews: 4-dimension adversarial workflow on Logic (56 agents) → fixed the 1 s no-repeat bypass on cue
  changes, the geofence speed gate accepting CoreLocation's -1, Anthropic max_tokens; Muse review of the
  diff → idempotent `DepthEngine.start()`, ARError codes surfaced, mesh face budget, CKCard a11y label.
- Builds clean for the iOS Simulator under Swift 6 strict concurrency. Not yet run on a device.
- Test on device: app shows "Depth OK" with six live tiles; wall at 1 m ≈ 1.0 in all tiles; hand at the
  left edge → Left tiles red; raise the hand → Head row; swing the cane → SWEEPING; fps ≈ 15;
  note whether a Camera Control press increments the footer counter.

## Step 0 — phone-only reset (Thu Sep 10)
- Decision: iPhone 17 Pro Max is the only computer. ESP32 grip, ToF pod, buy list → stretch/historical.
- `ios/CaneKit/CaneBLE.swift` moved to `ios/stretch/` (out of the app).
- Docs rewritten for the phone-only build: `README.md`, `ios/README.md`, `docs/ideas.md` §5.1.
- Plan reviewed twice with Muse; spec deviations recorded in `ios/README.md` §2.
- Test on device: nothing yet (no Xcode on the build Mac until the 27 RC download lands).
