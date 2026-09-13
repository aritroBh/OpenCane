# LIVE TRACKER — Sun Sep 13 (updated as work lands; newest first)

- [ ] Steps 67–68 review round (Codex, Muse, Antigravity) — CHANGELOG "Steps 67–68 review round"
  - [x] Logic tests first (new-API tests red on compile): emergency intent, ambiguous travel → gazetteer only, polite stop, Grainger compounds, "Close." `.safety` at every level, GPSAnnouncer ×11 (10 s / 12 s age / 60 s weak / 120 s back / indoor clock), EmergencyContactSeed.effective + log masking, CameraControlGate ×14 (accepted-press debounce, grip burst, one deferred press)
  - [x] Logic source: `FastPathIntentClassifier` (rule 1 `stopKey`, rule 1c `isEmergencyRequest`, `gazetteerOnlyVerbPhrases` / `gazetteerOnlyPrefixes`, nonPlaceWords), `CueSpeechPolicy.closeTier` / `closeAllowed`, `GPSAnnouncer.badOnset`, `EmergencyContactSeed.effective`, `EmergencyConfirm.logSafe`, `CameraControlGate.resolvePending`, CampusPlaces aliases
  - [x] App (read-checked only): NavigationEngine.announceGPS, AppModel ("Close." block, cameraControlPressed + watchPendingCameraControl, start()), MedicalProfileStore.effectiveEmergencyContact (no seed in `profile`), ProfilePage card, ConversationCoordinator (effective contact, `queryGeneration` private(set)), TripLogger number masking
  - [x] Replay 15-48-34Z through the new GPS rule → 0 lines (max fix gap 11.41 s)
  - [x] `swift test --disable-xctest` exit 0: 919 tests in 23 suites, 1 known issue (Step 66)
  - [x] Docs: CHANGELOG, AGENTS rule 8, design §5.1, handsfree §0, test_checklist, CODE_REFERENCE
  - [x] Muse #11: `HeadCoverNotice.line` not in `shellLines` (regression check added) — closes the Step 68 follow-up below
  - [ ] Orchestrator: `make sim uitest e2e` (app files not built here)
  - [ ] Device: emergency sentence → prompt; "I need to get to class" → nothing; "please stop"; Quiet + wall → "Close."; outdoor GPS loss → weak ~15 s; Profile caption; one Camera Control press at launch → one description

- [ ] Step 68 — half the words (owner: "make it talk about fifty percent less. But if something comes close … tell us"; log 15-48-34Z: route 31 lines / 1,086 ch → replayed 5 / 230, −78.8 % characters/min)
  - [x] Logic tests first: `QuietRouteSpeechTests` (GPSAnnouncer ×7 incl. the log's flap pattern, RouteStatusLines, HeadphoneNotice), `NavSupportTests` "Close." ×5, `introNamesTheDestinationNotTheRoute`, `EmergencyContactSeedTests` ×3
  - [x] `GPSAnnouncer` (20 s bad outdoors / 10 s good / one pair per 2 min) wired in `NavigationEngine` (`announceGPS`, `isIndoorActive`); `gpsWeak` / fences unchanged
  - [x] Route start: only the haptics status line; no head-cover line (still logged); "AirPods disconnected." once mid-route; intro "Route to <destination>. <first say>"
  - [x] `CueSpeechPolicy.close` → "Close." at `.obstacle` in `AppModel.handle` (route or indoor, not Quiet)
  - [x] "Screen locked. Obstacle warnings off."; `commonLines` += `RouteStatusLines.allSpokenLines`
  - [x] `EMERGENCY_CONTACT_NAME` / `_PHONE` in Secrets.example.plist + `MedicalProfileStore` seed; local Secrets.plist set (plutil)
  - [x] `cue_audit.py --speech-load` (+ `selftest_speech_load`); CHANGELOG, design §5.1, handsfree, test_checklist §1/§6, CODE_REFERENCE, AGENTS, route_isr_cif.md
  - [x] `swift test --disable-xctest` exit 0: 900 tests in 23 suites passed, 1 known issue (Step 66); `cue_audit.py --selftest` ok
  - [x] Follow-up: drop `HeadCoverNotice.line` from `SpokenPhrases.shellLines` (already absent; pinned in the Steps 67–68 review round)
  - [ ] Orchestrator: `make sim` (NavigationEngine / AppModel / MedicalProfileStore only parse-checked), `make uitest`, `make e2e` (intro wording changed; no e2e assertion depends on it)
  - [ ] Reviews: Muse on the diff, multi-agent, Antigravity
  - [ ] Device: indoor route start without AirPods 2 min still → no GPS lines; wall approach → one "Close."; lock → short line; AirPods out ×2 → one line; Profile shows Aritro; "emergency" → "no"
- [ ] Step 67 — launch says only "OpenCane ready."; spoken destinations route on the phone (owner: "a lot of jargon … It should just be 'OpenCane ready' and then boom. When I say the location it doesn't even do it."; log 15-48-34Z)
  - [x] Logic tests first (red on HEAD behaviour: 45 failing checks; new-API tests did not compile): `CameraControlGateTests` (8), `spokenDestinationsRouteOnThePhone`, `aTravelVerbAnywhereKeepsARealOrigin`, `noTravelIntentIsNotARoute`, `launchSaysOnlyOpenCaneReady`, `theOnlyMenuIsTheOneTheWalkerAsksFor`, budget 8 s, recovery line one sentence, aliases → `swift test` 900 green after the Muse round (1 known issue, Step 66)
  - [x] Launch: no menu (short or full); `VoiceShellPolicy.launchLine`; `listenAfterLaunchLine`; `speechDrainCap`; `voice_launch` log; LaunchRecovery line shortened
  - [x] `CameraControlGate` (5 s grace, 2 s debounce, blocked while listening / launch line) + `AppModel.cameraControlPressed` → `describe_skipped {reason}`
  - [x] `FastPathIntentClassifier` rule 14b travel intent + trailing fillers; CampusPlaces mishearing aliases
  - [x] `ConversationBudget` 8 s, ticks 1.5 / 4 s
  - [x] Docs: handsfree §0 / §5, design §5.1, test_checklist §1, AGENTS trap 1, CODE_REFERENCE, CHANGELOG Step 67
  - [ ] Orchestrator: `make gen` (new Logic file only — SwiftPM, no project change expected) + `make sim` (AppModel edits type-checked by reading only), `make uitest`, `make e2e`
  - [x] Review: Muse on the diff — 6 fixed (14b over-matching, first-verb-wins, dangling "from", going/heading, `noLidarLine` prefetch, `already_listening` log), 5 rejected with reasons (CHANGELOG)
  - [ ] Reviews: multi-agent, Antigravity
  - [ ] Device (test_checklist §1): launch = ready + tone only; squeeze in first 5 s → no description; "I just wanna get from here to Granger library" → route; a slow question answers before 8 s

- [ ] Step 66 — stress campaign (owner: "really really test it"; README `ios/scripts/stress/README.md`)
  - [x] Logic `StressTests` (seeded, run twice, cross-process digests identical) → 869 green, 1 known issue (early arrival, owner tuning)
  - [x] Fixed 2 `CueDecider` bugs (silent returning overhang; onset on a non-finite distance), pinned
  - [x] OSM walks (6) + `CANEKIT_ROUTE_FILE` hook + `e2e.py` stress_* / indoor_isr + `campaign.py`
  - [~] Campaign: stopped by the orchestrator during run 1 (simulator needed for urgent fixes); smoke only: indoor_isr PASS, stress_cif_siebel PASS after a harness fix. Rerun `campaign.py` alone (resumes) for the × 3 determinism table
  - [ ] Reviews (Muse / multi-agent / Antigravity), device walk under an overhang, commit

- [ ] Step 65 — calm feedback (owner: "don't over-stimulate the blind person too much or else they won't listen")
  - [x] Evidence: phone log 08-51-14Z, first 34 s = 301 characters of speech (menu 76, "Still describing…" ×2, "One moment.", timeout 47)
  - [x] Logic tests first: `EarconTests` (14), short menu, thinking ticks + "No answer.", prefetch set, draft caveat → `swift test` 861 green
  - [x] App: `EarconPlayer`, `SpeechQueue.playEarcon` / `perform`, VoiceInputEngine, ConversationCoordinator, SceneDescriber, AppModel (short menu, warm-up ticks, "Starting.") → `make gen` + `make sim` green
  - [x] Docs: design §5.1 earcon table, handsfree, CODE_REFERENCE, test_checklist §1, route_isr_cif, CHANGELOG Step 65
  - [ ] Reviews: multi-agent + Muse + Antigravity (not run)
  - [ ] make uitest / e2e on this build (not run)
  - [ ] Device: listen to every tone on the cane (checklist §1); tune levels from a trip log's `earcon` records
  - [ ] Commit + install

- [x] Step 61 — first launch in Apple's voice: ElevenLabs account has 0 of 10,000 credits (HTTP 401 quota_exceeded); a refused key now keeps the session in one voice (pushed 7b62b0b, on the phone)
- [ ] **Owner action:** top up ElevenLabs (or a paid key in Secrets.plist), then Settings → Voice → System → Natural
- [ ] Step 62 — indoor → outdoor guidance (step script + handover, owner decision)
  - [x] Plan + Muse review (scratchpad plan_indoor.md; Muse: skip ARKit breadcrumbs tonight)
  - [x] ISR indoor draft `indoor_isr.json` from the Housing 1st-floor plan (walked: false) + docs/route_isr_cif.md "Indoor draft"
  - [x] Logic: IndoorScript / IndoorProgress / IndoorHandover / IndoorRecorder + "from A to B" + "I'm outside" + ISR alias fix (799 tests green)
  - [x] App: IndoorGuide (pedometer, speech, handover → CIF route), Guide card, voice actions, recording card in Settings, sim step hook (`make sim` green; simulator walk logged the handover)
  - [x] Locked phone: keep GPS while indoor is active in background (Step 64 merge) + GPS-only handover (review round)
  - [ ] Reviews: Muse, OpenCode, Codex, Antigravity → fixes
  - [ ] Gate: make test / sim / uitest / e2e, install on phone, commit + push
  - [ ] Owner/teammate: record the real lab → doors walk with the recording mode
- [ ] Step 64 — Dynamic Island / widgets
  - [x] Audit (scratchpad island/): activity exists only while a route guides; blue pill was the whenInUse session (Always now granted on the phone); design reads as a system glyph; **safety bug: "Path clear" while locked and depth paused**
  - [x] Safety: sensing live/paused/none in ContentState; never "clear" unless depth is live (CHANGELOG Step 64)
  - [x] Phases: warming (countdown), walking, indoor step i/n, listening/thinking, arrived, stopped card; IslandPhasePolicy + IslandAlertThrottle in Logic with tests
  - [x] Look: OpenCane contour-ring mark, keyline tint, progress ring, expanded layout fixes, StandBy layout, Smart Stack family (StandBy / Smart Stack not pictured — phone)
  - [x] Alerts: escalation-only AlertConfiguration ≤ 1 per 30 s per level (⚠ can only fire while `.inactive`: depth pauses in the background)
  - [x] Extras: Control Center "Talk to OpenCane" control + lock-screen accessory widget (device check pending)
  - [~] make island pictures reviewed (done); Muse / multi-agent / Antigravity reviews, make uitest / e2e, phone — open
- [x] Device test checklist: docs/test_checklist.md (launch/voice, emergency, obstacles, indoor, recording, outdoor, island, other)
- [ ] Pull teammate d2b8efb (their "Step 64"; island becomes Step 64) and merge
- [~] Reviews on the merged Steps 62 + 64: Codex ✅ OpenCode ✅ Antigravity ✅ Muse ✅ → fixes written (CHANGELOG "Steps 62 + 64 review round"; Logic 845 ✅; app code not yet built)
  - [x] 1 landmark hook lets commands through (`isLandmarkText`)
  - [x] 2 GPS-only handover (3 × ≤ 10 m within 15 m) + `paused_background` / `resumed` log — [ ] device: locked walk out of the ISR doors
  - [x] 3 indoor walk requests the Live Activity (`beginIndoor`); outdoor leg reuses it; `endIfIdle`
  - [x] 4 ActivityKit request serialized behind the end chain (generation fence)
  - [x] 5 background request deferred → `flushPendingRequest` on `.active`
  - [x] 6 exit fallback ≤ 30 m and ≤ 20 s old
  - [x] 7 alert throttle keeps the previous level on a throttled escalation
  - [x] 8 / Muse M4 "I'm outside" recent fix must be inside the exit radius; why pre-exit fixes count documented
  - [x] 9 lows (a–e); Muse M3 (every "to B from A" prefix), M8 (stopped figure), M11 (recording refusals)
  - [x] Rejected with evidence: Muse M6, M9, M10
  - [ ] make sim / uitest / e2e on the fixes (orchestrator)
- [ ] Gate after fixes: make test ✅ 845 / sim ✅ / device build + install ✅ / pushed a11ed7e ✅ (rebased on teammate Steps 64a docs) / uitest + e2e (running on the final build)
- [ ] Owner: unlock the phone and run docs/test_checklist.md
- [ ] Commit + push after each step; pull teammates' changes first

# CaneKit — strict build checklist

Legend: `[ ]` open · `[x]` done · `[~]` written, not yet compiled/tested · `[!]` blocked on a person

---

## Historical (Fri 2026-09-11, 19:45) — the "WHERE WE ARE" snapshot

**This block is a dated snapshot, not the current state.** It was last rewritten on Fri 2026-09-11
evening; CHANGELOG Steps 38–47 landed after it (Sat 2026-09-12). For where things stand now read the
newest `CHANGELOG.md` entry (top of file — Step 51 as of Sun 2026-09-13) and the latest numbered
block near the end of this file; where this block and a newer section disagree, the newer one is right.

Demo: Sat 2026-09-12. The app runs untethered on Aritro's iPhone 17 Pro Max (iOS 27), clamped to a
cane, with AirPods Pro.

### What is proven ON THE PHONE (measured, from trip logs in `Documents/`)

| Thing | Evidence |
| --- | --- |
| LiDAR depth, mesh names, haptics, head-height cue | `start` record: `lidar: true, mesh: true, haptics: true`; speech records "window ahead, one and a half meters", "table ahead, half a meter", "Head height." |
| Depth at 30 reports/s | `lanes.fps` median **29.988** (was exactly 10.0 before the `PublishGate` timing fix) |
| Both cameras at once — ⚠ **superseded evidence** | The `both_cameras` records (`supported: true, front: true, back: true, error: ""`, `hardware_cost: 0.26`, and after stopping `depth_running: true, depth_fps: 30, status: "Depth OK"`) were measured against the **preview-layer** version, which no longer exists: the feeds now render from `AVCaptureVideoDataOutput` into `AVSampleBufferDisplayLayer` because a preview layer makes LiDAR depth unreliable (Apple forums 742501). What still carries over is that multi-cam is supported and that ARKit resumes cleanly after the mode stops. **Whether the two feeds actually draw has never been seen on hardware.** |
| Trip-log field collision fixed | zero rows carry `field_kind` / `field_t` |
| ElevenLabs (Bella) reachable | key verified `HTTP 200`, free tier 0/10 000 chars; a real 9 kB mono mp3 at 22.05 kHz came back for the app's exact payload |
| Muse Spark 1.3 reachable + multimodal | key verified `HTTP 200` from `muse-spark-1.3-contributor`; docs confirm `/v1/chat/completions` and image understanding |

### MEASURED ON THE PHONE: both cameras AND depth is possible, without ARKit

The `multicam_depth` probe ran on Aritro's iPhone 17 Pro Max (iOS 27) on 2026-09-12 and answered the
question Apple's documentation could not:

```
multicam_supported:    True
front_plus_depth_sets: 12
device_sets:           front:BuiltInWideAngleCamera + back:BuiltInLiDARDepthCamera  depth 320x240
                       front:BuiltInTrueDepthCamera depth 640x480 + back:BuiltInLiDARDepthCamera
depth_multicam_formats: 33
best_format:           video 640x480, depth 320x240
arkit_depth_size:      256x192
keeps_depth:           True
verdict:               depthAboveARKitResolution
```

**Twelve multi-cam device sets pair the front camera with a depth-capable back camera**, including
the wide-angle front camera with the LiDAR depth camera. Apple's own sources only ever name the rear
Telephoto and Ultra Wide as the second camera (WWDC22 110429; DTS forum 702875), so this had to be
measured. AVFoundation's streaming LiDAR depth is **320×240 — higher than ARKit's 256×192**.

**What this means:** the current design pauses ARKit to show both cameras, because ARKit itself can
never hand over two images (Apple DTS, forum 677731). But a future version could run
`AVCaptureMultiCamSession` with `builtInLiDARDepthCamera` + the front camera, take depth from
`AVCaptureDepthDataOutput`, and have **both feeds and working obstacle detection at once.**

**What it would cost — a real rewrite, not a switch:** no ARKit means no world tracking, no
classified mesh (the source of "door" / "wall" / "table"), no per-pixel `confidenceMap`, and no
gravity-aligned world — gravity would come from `CMDeviceMotion.gravity` instead, and the depth map
would need rectifying with `AVDepthData.cameraCalibrationData` (it is non-rectilinear, unlike
ARKit's). Also: no `AVCaptureVideoPreviewLayer` anywhere near it (forums 742501), and
`systemPressureCost` must stay under 1.0 to run indefinitely.

- [ ] **Post-demo:** prototype the AVFoundation depth pipeline behind a setting and compare it with
      ARKit on the same walk — obstacle-cue parity first, then whether the extra depth resolution
      buys anything a cane user can feel.

### What is NOT proven on the phone yet

- People/animal detection (Vision's neural models cannot run in the simulator — phone-only).
- **That the two camera feeds actually appear.** The render path was rewritten after the only device
  run, so it is unproven; if it shows black, the fallback is Metal or `CIContext`, never a preview
  layer.
- The `.playAndRecord` microphone switch **with AirPods connected**. It was measured only with no
  headphones (output stayed `Speaker`, restore worked). The revert-on-route-change guard exists
  precisely because the AirPods case is unmeasured.
- The `multicam_depth` probe's answer — whether a future version could show both cameras *and* keep
  depth through AVFoundation instead of ARKit. The probe is in the build and has never run.
- The Muse scene sentence end to end after tonight's reasoning-token fix.
- Ground hazards (drop-offs, potholes) on real pavement; still **off by default**.
- Sound recognition (sirens, horns) and front-camera head tracking; both **off by default**.
- The outdoor ISR → CIF walk.

### Honest capability table — what the demo can and cannot claim

| Hazard | Mechanism | Status |
| --- | --- | --- |
| Poles, signs, branches, open doors (waist-to-head) | LiDAR geometry, no model | **Works, verified on device.** The strongest claim we have |
| Drop-offs, potholes, curbs, steps | LiDAR ground geometry | Built + tested, tilt-gated against the false "Hole ahead"; off by default, untested on real pavement |
| People, dogs, cats + direction + measured distance | Apple `DetectHumanRectanglesRequest` / `RecognizeAnimalsRequest` + LiDAR box depth | Built, 206 Logic tests, **never run on hardware** |
| Signs, crosswalk push-buttons | Vision OCR, measured to ≈ 7 m for 7.5 cm letters | Works |
| **Cars, bikes, ice, puddles, construction** | **No Apple detector exists.** Only the 1 303-label classifier — which returned *zero* usable labels on the phone — or a vision-language model | **Needs the Muse key, which is now wired.** Verify on device before claiming it |
| Route guidance, veer, crossings | GPS + MapKit + compass | Works; the veer regression below is being fixed |

**The line to say out loud at the demo:** *the model names things; LiDAR measures them. No number the
sensors did not see is ever spoken.*

### Keys (git-ignored `ios/CaneKit/Resources/Secrets.plist`, never committed)

- `ELEVENLABS_API_KEY` — set. Voice `EXAVITQu4vr4xnSDxMaL` (Bella), model `eleven_flash_v2_5`,
  settings stability 0.4 / similarity 0.75.
- `CUSTOM_*` — set to Meta Model API: `https://api.meta.ai/v1`, `muse-spark-1.3-contributor`,
  `VLM_PROVIDER = custom`. Key format is **pipe**-delimited (`LLM|<digits>|<chars>`).
- Added Sat 2026-09-12 (Steps 39, 43, 45; template `ios/Secrets.example.plist`), each read only from
  the git-ignored plist (the two webhook names also from the process environment first, for e2e):
  - `OPENCANE_GROKBOT_WEBHOOK_URL` / `OPENCANE_GROKBOT_WEBHOOK_KEY` — the Grok Bot routine's webhook
    trigger. Without them **Family alerts is dead**: the "Send cane events to family" switch and
    "Save family emails" are disabled and the card says "No webhook key…" (`ContentView` family card);
    falls, breadcrumbs, test events and the contacts list go nowhere.
  - `ALERT_MODEL` / `ALERT_REASONING_EFFORT` (default `minimal`, measured: 2.1 s vs 7.1 s for `low`) —
    the one-sentence `ai_context` on a family alert. Empty model = the cheapest model of whichever
    provider has a key; no key at all = "Add AI context" is disabled and alerts carry facts only.
  - `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` — the cloud mirror of the Medical ID, mobility days,
    hazards, family alerts and device rows. Without them the app runs entirely on the phone: the
    Profile tab still works from local storage, nothing syncs, nothing fails loudly.
- ⚠ **Rotate both keys after the event** — they were pasted into a chat transcript.
- ⚠ A build made in a git worktree gets an **empty** Secrets.plist (the file is git-ignored), so an
  agent's build silently loses both keys. The keys have been copied into every `cane-wt-*` worktree;
  do the same for any new one, or install only from the main checkout.

### Branch state (updated 2026-09-12 morning)

**Merged into main and verified (316 Logic tests *at the time*; the Logic target holds 575 `@Test`
annotations in 44 files at Step 47 — recount with `grep -rc '@Test' ios/Logic/Tests` before quoting;
simulator build clean, `make uitest` green):**
- the destination-search rework + its accessibility fix
- `fix/cloud-scene-gate` — the cloud sentence is gated, and Muse Spark can actually answer
  (`max_tokens` 120 → 1024 and `reasoning_effort: "low"`; it was spending the whole budget
  reasoning and returning nothing after 11 s)
- `feat/detect-people` — people and animals named with direction and a LiDAR-measured distance
- the widget-embed fix: **the Live Activity had never been in any installed build**
- `fix/voice-consistency` — 74 warning lines prefetched so warnings stop alternating voices
- `fix/veer-gap-regression` — a veer episode is continuous evidence, not continuous samples
- `fix/launch-crash` — no optional feature may keep the app from starting (the Hazards-toggle crash)
- `fix/sound-watch-hardening` — six confirmed microphone defects fixed, incl. the crash
- `feat/all-sensors` + safety fixes — both cameras, front-camera head yaw, danger sounds, all off by default
- `feat/rename-opencane` — the product is OpenCane, the code is still CaneKit
- front-camera rotation, first attempt (0f32282) — coordinator angle, still tilted on device

**Step 16 gate GREEN (2026-09-12 ~01:00):** 347 Logic tests passed, device build + install on
the iPhone 17 Pro Max succeeded. The gate caught one real bug from the hand-merge: `\(.$state)`
in the SilenceHapticsIntent phrases (missing `\` escape — fixed in `99f0a37`). Branches retired.
Still to do on the phone: siren ~1.5 s behavior, "How is OpenCane doing" order, Both-cameras
inset re-check after reinstall.

**Committed in the main checkout:**
- `ios/CaneKit/Depth/DualCameraSession.swift` — per-camera rotation (`DualCameraRotation`: back 90,
  front 0, both fixed for the portrait-only UI; superseded capture-first after the back feed came out sideways, 2026-09-12),
  unmirrored front inset, `front_rotation` / `back_rotation` / `front_mirrored` / `*_capture_angle` /
  `*_size` / `*_portrait` in diagnostics (Step 15).
  Device build green, 316 Logic tests green, front inset verified on the phone.
- Emergency sirens — `SoundAlerts.swift` + tests (verbatim), `SoundWatcher` + `AppModel`
  wireSounds/commonLines (merged, renames kept).
- Hands-free — `HandsFreeIntents.swift`, `QuestionPrompt` / `StatusSummary` + tests,
  `docs/handsfree.md` (new); `AppIntents` 10-shortcut list, `VLMClient.cloudPrimary`,
  `SceneDescriber` ask path, `describe_result` question field (merged).
- Conversational voice assistant — `TalkToOpenCaneIntent`, `VoiceInputEngine` (SFSpeechRecognizer with Hard Rule 7 audio safety), `ConversationCoordinator`, `ConversationModels`, `FastPathIntentClassifier`, `ConversationPrompt`, `WalkMarker` post drops, and rolling context memory (Step 23). **Rerun settled the test-count
  question** (2026-09-12, Step 27): the target held 366 `@Test` annotations and `make test` on
  Xcode 27 reported **366 tests passed in 1 suite**. Step 28 added six lifetime-guard tests, so the
  target then held **372 annotations** (historical: at Step 47 it holds **575 `@Test` annotations in
  44 files**, Step 46's last full run was 538/538, and the number moves every step — recount, do not
  copy); the 359 figure was the last green run *before* the
  Step 25 interlock tests existed; reaching 366 first needed the
  `#expect` + `mutating` compile fix in `DepthReadinessTests` (CHANGELOG Step 27).
- `CHANGELOG.md` (Step 16, 23), `docs/CODE_REFERENCE.md` (DualCameraSession, SoundAlerts,
  QuestionPrompt/StatusSummary, HandsFreeIntents, ConversationModels, VoiceInputEngine, cloudPrimary sections; AppIntents rewritten;
  stale 8/12 s timeouts and stale test-count references fixed; the Step 27 snapshot had 366 `@Test`
  annotations and the Step 28 target 372 — both historical, see the recount note above).

**Committed on a branch, not yet merged:**
- `feat/fm-image-describe` — Apple's on-device model with the image (experiment, off by default).
  **Deliberately held**: it conflicts with the people-detection work in the same files and buys
  nothing for the demo.

**Branches (2026-09-12 cleanup):** 11 merged branches deleted, then `feat/emergency-alerts` +
`feat/handsfree` retired after the Step 16 gate went green (347 Logic tests, device build +
install). Remaining: `main`, `feat/fm-image-describe` (deliberately held, conflicts with
people-detection), `feat/multicam-depth` (worktree has uncommitted DepthEngine changes — triage
separately), `experiment/gemma-cactus` (untracked `CactusCodec` + bench script — triage
separately). New remote branch `feat/screwless-mount` (teammate) — not ours, do not touch.

**Worktrees:** only the 3 kept ones remain (`-emergency`/`-handsfree` backups removed with their
branches after the gate; 11 orphan dirs deleted from `~/Downloads`).

### Open findings from the Muse review of the sensor layer (2026-09-11, xhigh)

Twelve findings; three were fixed on the spot (a failed both-cameras start left the walker with no
obstacle detection; "Obstacle detection is back" was spoken before it was true; the microphone
setting persisted across launches). **Every one below is in a feature that is OFF by default**, so
none blocks the demo — but they are real, and several need the phone to judge.

- [x] **Camera-transition route-start interlock (Step 25).** `beginRoute` now waits for the
      serialized two-camera teardown, then requires three consecutive same-frame reports with
      `.normal` tracking, valid scene depth and the existing sweep trust bit. `DepthReadiness`
      resets on interruption/pause/resume/reconfiguration and times out after 5 s; queued starts
      resume automatically when ready and fail loudly otherwise. The adapter drains the old AR
      delegate queue at every reconfiguration, publishes every frame in 60 Hz mode, rejects
      newest-only stream gaps in pure `DepthFrameContinuity`, and exposes an observable **Cancel
      route start** action. The intentional no-LiDAR and camera-denied degraded paths still guide
      with an explicit obstacle-warning notice.
- [x] **The microphone route guard checks once, synchronously.** `setMicrophoneEnabled` compares the
      output route immediately after `setActive(true)`, but iOS settles the route ~0.5 s later — so
      an AirPods flip to HFP would pass the check. `SpeechQueue` now snapshots both output and input
      ports (UID/name included), watches route changes for the complete microphone lifetime, and
      reverts on every output or input-quality change. Old-device-unavailable notifications are
      treated as a dropout even if the route has recovered by callback delivery. A startup
      `none → usable` input settle is the sole bounded exception; it updates the baseline while the
      one format retry completes. A shared microphone lease rejects push-to-talk overlap. The
      AirPods case is still unmeasured on hardware, so the live route log remains a required device
      check.
- [x] **Analyzer death keeps the microphone session open.** `SoundWatcher` now treats SoundAnalysis,
      AVAudioEngine configuration and engine-stop failures as hard stops: the tap/analyser are torn
      down on their serial queue, the session returns to `.playback`, the switch follows reality and
      the existing speech/UI failure channel says why.
- [x] **Permission race can start the mic after the user turned it off.** The pure
      `SoundRecognitionGuard` fences permission callbacks with a generation token; the adapter also
      polls permission while it owns the session and cancels any pending continuation on Stop.
- [x] **Face tracking re-runs the AR session mid-route with no warning** (~1–2 s without frames).
      The two-camera mode correctly refuses during a route; this path does not. **Step 34:** measured
      on the phone (t = 80.7 s); now refused while a route guides or starts (`FaceTrackingChange`).
- [x] **The mic input format was read synchronously before the route settled.** `SoundWatcher` now
      re-reads it once after the engine/session has had `MicrophoneStart.formatRetryDelay` to settle
      (the bounded retry is < 0.5 s), and the route guard allows only the startup `none → usable`
      transition. If the input is still absent, sound alerts fail loudly and navigation continues.
- [ ] **"Degrades to the back camera alone" remains unimplemented** (`BothCameras.unsupported`;
      confirmed by the Step 34 audit). On a phone without multi-cam the mode shows no picture and
      the card now says so honestly; implement a single-session fallback only as a separately tested
      feature.
- [x] **Backgrounding enqueued the camera teardown.** `AppModel` now requests a short background
      execution budget, serializes `bothCameras.stop()`, and records an expiration if iOS suspends
      before release. The safety path is paused only after the teardown request is queued.
- [ ] **Debug-only:** launching with both the sensor-probe and demo-route flags guides a route for
      ~40 s with no depth, and the probe's 40 s announcement queues ahead of route lines with a 20 s
      TTL.

### The merge gate (nothing lands on main that fails any step)

1. `cd ios && make test` (`scripts/test.sh`; judge it by its own exit code, never through `| tail`)
· 2. `make sim` · 3. `make uitest` (muted; the whole `CaneKitUITests` target, 12 tests), plus
`make tour` for a UI change and `make island` for a Live Activity / Dynamic Island change (the only
visual check the widget has) · 4. `make e2e` (4 scenarios) · 5. two independent adversarial
reviewers over the **merged whole** (Muse plus Codex or Antigravity on a repo copy — Step 46 was
Muse + Codex), every finding verified by hand before acting · 6. install on the phone and confirm
from the trip log.

⚠ Never run two simulator jobs at once — concurrent `make uitest` and `make e2e` produced a bogus
"harness error: No such file or directory" that looks like a real failure. Use
`make uitest SIM="iPhone 18 Pro"` to work alongside someone else's run.

---

## Step 0 — phone-only reset
- [x] Push 3 commits to origin/main
- [x] Docs rewritten (README, ios/README, ideas §5.1), CHANGELOG, .gitignore
- [x] CaneBLE.swift → ios/stretch/, old drafts → ios/drafts/
- [x] Muse review of plan (2 passes) + of the Step 0 diff
- [x] Xcode 27 RC installed (27A266a), license accepted, xcode-select set, XcodeGen 2.46.0
- [ ] Apple ID added in Xcode → Accounts; TEAM id in `ios/local.mk`
- [ ] Developer Mode on iPhone + Watch; `make devices` shows the phone; DEVICE in `ios/local.mk`

## Step 1 — project scaffold
- [x] `ios/Logic` SwiftPM package: LaneMath, LaneReport, CueDecider, GeoMath, Waypoint/RouteBuilder, WatchMessage, VLMCodec
- [x] Unit tests written (6 files, ~45 assertions groups)
- [x] `make test` green (43 tests) — `scripts/test.sh` works around the missing CLT overlay
- [x] project.yml (iOS + watch targets, plist keys, Swift 6 + approachable concurrency)
- [x] scripts/gen.sh (XcodeGen + watch-embed patch + Secrets copy + WATCH=0 mode), Makefile, Secrets.example.plist
- [x] App scaffold: CaneKitApp, AppModel (capability checks, settings), ContentView; watch app scaffold
- [x] Review workflow findings on Logic folded in (3 bugs fixed, 6 tests added → 49 green)
- [x] Muse review of the Steps 1–2 diff (start() idempotent, ARError codes, face budget, CKCard label)
- [ ] `scripts/gen.sh` → `make build` → `make install` on the phone; watch app installs
- [x] Commit "Steps 1–2 (pre-device)" + CHANGELOG entry
- [x] Simulator build green (Swift 6 strict)
- **test on device:** app shows "LiDAR OK — ready" with three green capability rows; watch shows "OpenCane / Waiting for the phone"

## Step 2 — DepthEngine
- [x] DepthFrameProcessor (historical Step 2 baseline: ARSession delegate on a background queue, gyro gate, 15 Hz, AsyncStream; current pipeline is 30 Hz normal / 60 Hz high-rate)
- [x] DepthEngine (main-actor owner: start/pause/resume, video format, thermal hook, fps)
- [x] LaneGridView / DebugView (6 tiles, TRUSTED pill, fps, |ω|, thermal, battery, portrait/mirror toggles)
- [x] CameraControlInteraction spike (AVCaptureEventInteraction) — log whether it fires under ARKit
- [ ] Build, install, run the test list; Muse review; commit
- **test on device (historical Step 2 baseline):** wall at 1 m ≈ 1.0 in all six tiles; hand at left edge → Left tiles red; raise hand → Head row; swing cane → TRUSTED off; fps ≈ 15; Camera Control press shows "CC event" (or not — record which). For the current pipeline use the Step 25 cadence/interlock checklist.

## Step 3 — Core Haptics
- [x] HapticPlayer (CHHapticEngine, pre-built players, Geiger loop, reset/stopped handlers, isHealthy) — compiles, untested on device
- [x] CueRouter in AppModel (CueDecider → player, silence toggle, trip log) + HapticsCard test buttons
- [ ] **Milestone: walk at a wall → the cane shakes** (go/no-go for steps 7–9)

## Step 4 — Speech + obstacle names
- [x] SpeechQueue (priority, interruptible, one audio session), ObstacleNamer, MeshClassifier (≤ 4 Hz) — compiles, Muse-reviewed, untested on device

## Step 5 — Watch
- [x] PhoneWatchLink (WCSession), WatchModel (haptics map, crown, HKWorkoutSession, buttons), cue mirroring — compiles, Muse-reviewed, untested on device

## Step 6 — Navigation
- [x] LocationService, NavigationEngine (GeofenceTracker + OffCourseDetector), route file, MapKit fallback — **verified in the simulator GPS replay**

## Step 7 — Beacon
- [x] BeaconEngine (AVAudioEnvironmentNode, mono click), HeadPoseTracker (CMHeadphoneMotionManager + Recenter) — compiles, Muse-reviewed, needs AirPods on device
- [x] ElevenLabs natural voice with cache + prefetch, AVSpeech fallback (needs key)

## Step 8 — Scene description
- [x] VLM clients (custom/Anthropic/Gemini/OpenAI), Secrets, SceneDescriber, WhereAmI App Shortcut — compiles, Muse-reviewed; needs a key + device

## Step 9 — Arrival, Live Activity, thermal, battery
- [x] TripTracker (HealthKit + pedometer), LiveActivityController + widget target, thermal downgrade (in AppModel since step 2), ArrivalCardView — compiles, Muse-reviewed

## Step 10 — Review fixes + UI tests (pre-device)
- [x] Round-1 full-app adversarial review (65 agents) + fixes
- [x] Round-2 review of the fixes (5 dimensions, 31 findings) + fixes, incl. unverified ones on inspection
- [x] TurnSettle / StraightWalkDetector / CueSpeechPolicy / CrownAccumulator extracted to Logic with tests (79 green)
- [x] Geofence skip-ahead, passed-by wording, leg bearing near waypoints, two-hit plausible arrival
- [x] Speech: priorities, single replay, Repeat bypasses coalescing, interruption queueing, no network wait for warnings
- [x] AirPods route monitor (beacon only in headphones, spoken connect/disconnect), channel check at route start
- [x] Watch: layout fits 42–46 mm, crown window, version-skew reply, status every fix
- [x] XCUITests (6) + screenshot tour on the iPhone 17 Pro Max / iOS 27 simulator; watch screenshot on a paired watchOS 27 sim
- [x] AGENTS.md, CLAUDE.md, docs/devices_setup.md, docs/CODE_REFERENCE.md, CI workflow
- [x] Muse review of the final Step 10 diff folded in (9 of 11 fixed; 2 refuted with evidence)
- [x] Commit "Step 10 (pre-device)" + push (1de6efb)
- **test on device:** see CHANGELOG Step 10 and docs/devices_setup.md

## TONIGHT (live checklist, Fri 2026-09-11 evening; updated with every push)

Phone: iPhone 17 Pro Max (iOS 27.0) connected, signed with the free Personal Team, app installed.

- [x] First real-phone desk test: LiDAR, haptics, mesh names, head-height cue, on-device "Where am I" work
- [x] Depth 10 → 30 reports/s (PublishGate timing bug found on the phone)
- [x] Camera: measured what ARKit allows with LiDAR (1x wide only, ≤ 60 fps, no 0.5x/120); full 4:3 frame
- [x] "60 fps camera (warmer)" switch on the Mount card, off by default (heat untested over a long walk)
- [x] "Where am I" uses one LiDAR snapshot (the phone mixed two moments)
- [x] False "Hole ahead" indoors: ground hazards judged only with a mount-like tilt (0-15 deg) and a
      plausible ground height (0.5-1.3 m below the camera); drop-off and hole frames agree as one hazard
- [x] Screen-lock warning once per route (no spam); Muse + Antigravity final-review fixes
- [!] **ElevenLabs natural voice — waiting on Aritro.** Code is done and merged (cache, prefetch,
      2.5 s timeout, circuit breaker, Apple-voice fallback). It is off only because
      `ELEVENLABS_API_KEY` in `ios/CaneKit/Resources/Secrets.plist` is empty. See "ElevenLabs
      setup" below.
- [x] Voice control: 7 Siri App Shortcuts (start route, take me to <place>, navigate to CIF, where am I,
      repeat, next, stop) — on the phone, needs a spoken test
- [x] "Navigate to CIF from here" (Apple Maps walking directions from the live GPS fix)
- [x] Destination search: campus gazetteer before MapKit, nearest result, spoken "Walking to X, N meters."
- [x] Fixed: a slow Siri search could swap the walker onto another route mid-walk
- [x] Live camera view at the camera's frame rate (GPU view instead of a 3 Hz JPEG), preview capped at 30 fps
- [x] Trip-log fix: cue / hazard records keep their record type (field name collision)
- [ ] A/B: Apple's on-device model *with the image* (iOS 27), every object backed by Vision/LiDAR
- [ ] Experiment branch: Gemma 4 E2B via Cactus, measured on the phone (latency, heat, made-up objects)
- [ ] Experiments, off by default: front camera head direction; microphone sound alerts (sirens, horns)
- [ ] Muse + Antigravity + Claude workflow review of all of the above; fix or reject with evidence
- [ ] Install on the phone, verify each item from the trip log, push
- [ ] **Action Button opens OpenCane and listens (Step 29).** Needs `cd ios && make run` from a
      normal terminal first (the reinstall re-indexes shortcuts), then Settings → Action Button →
      Shortcut → Talk to OpenCane. If it is missing: open the Shortcuts app once, retry, restart
      last. Press → tick → "how is my battery" → press again → answer. Trip log must show
      `voice_toggle {source: actionButton}`.
- [ ] **Distance-first warnings on the phone (Step 29).** Walk past a doorway: "N meters ahead,
      door" — never "door ahead, N meters". Same order for people, drop-offs, approach cues.
- [ ] **Speech governor calm on a real walk.** `speech_suppressed` events in the trip log for
      mesh names only; route, head-height, ground-hazard and directional fallback lines never
      suppressed. Tune the 7 s gap only after measuring with a blind/O&M-trained tester.
- [ ] **Voice hold on the phone (Step 30).** Start a route, press Talk mid-guidance, keep
      talking: no route/obstacle line over the dictation; `.safety` still breaks through;
      after stopping, the answer speaks first, then at most one still-valid held line.
- [ ] **Blindfold walk to Grainger/Siebel (Step 31).** Reinstall FIRST (`make run` — Steps
      29–33 are not on the phone yet). Phrases: "Talk to OpenCane → set location to Sift"
      or "take me to Granger Library". Expect: fast system-voice answer, exit-first clause
      if GPS is weak indoors, distance-first warnings en route. Sighted guide present,
      cane on. Trip log must show `voice_toggle`, `conv_turn` latencies, no `field_kind`.
- [ ] **Flashlight + both cameras (Step 32).** Dark room: Flashlight on/off + spoken
      confirmation; on during a route (allowed); on inside Both cameras mode; trip log
      `torch {active:true}` in all three. Both-cameras refusal line while guiding is
      correct behavior, not a bug.
- [ ] Outdoor walk ISR → CIF (stress plan W1/W2) — needs Aarav, Sagar and daylight

### Hardware tonight (Sagar, Windows machine)
- [x] OpenSCAD on Windows: 2021.01 via winget renders the threaded collar in 6 min 52 s; 2025.09.15
      portable snapshot does it in 0.3 s and is unzipped at `%USERPROFILE%\Tools\`
- [x] `scripts/build_stl.ps1` — one command, all five printables, binary STL, finds the fast OpenSCAD
- [x] `hardware/mount_screwless/` designed and rendering clean: collet clamp (collar + ring), arm,
      cradle, coupons. Zero screws, inserts, nuts or magnets.
- [x] `.gitignore` now covers `stl/`, `*.stl`, `*.3mf`, `*.gcode` — it did not before
- [x] `scripts/slice_gcode.ps1` — headless slicing through Creality Print 7.2 (an Orca fork, so it
      takes Orca's command line). Reproducible, no GUI, and it reads back what it wrote and refuses
      to call a file safe if it cannot confirm the material. See `hardware/mount_screwless/PRINTING.md`.
- [x] **The thread generator never produced a thread.** A twisted `linear_extrude` maps *angle* to
      height; the tooth was drawn as a flat y-offset and came out 0.031 mm thick, so the collar's
      threaded band sliced as a smooth cylinder. Rewritten as an angular sector: 0.62–0.75 mm.
      Both copies had it — `screwless_mount.scad` and the hand-copied one in `coupons.scad`.
- [x] **Print the bore rings and set `pole_d` from them.** DONE 2026-09-12. Printed, and fitted to
      the prototype shaft: 1 notch (27.75) barely went on, 2 and 3 went on decently, both colours
      agreeing. `pole_d = 27.75 - 0.10 = 27.65`, which lands exactly on the dial-caliper reading by
      a completely different method. The rival 28.75 is retired in all four .scad files. Caveat: no
      ring REFUSED to go on, so the shaft is bounded from above but not hard-bounded from below.
      `pole_d = (smallest ring that goes on) − 0.10` — **not −0.35**, which is what `coupons.scad`
      said until 2026-09-12 and was wrong by ~0.25 mm. `bore_clear` is *not* an output of this
      test: the rings are rigid, the collar is a collet that closes, so clearance is a design
      decision and `collet_squeeze` takes it up.
- [ ] Thread + dovetail coupons; set `thr_clear` and `dt_clear`. Exported together as one plate
      (`what="next"`, 11 solids, 149x178 mm, 57.32 cm3) on 2026-09-12. First thread pair printed
      and JAMMED two turns of four at [0.35, 0.25], so the coupon is now a four-nut bracket
      stepping radial and axial clearance separately. The thread coupon is the first
      physical proof the rewritten thread exists — **if the ring will not thread on, do not print
      the collar.**
- [ ] Print the bore rings in PETG too. PLA rings need a shrinkage correction of ~0.06 mm (worst
      case 0.168 mm, which is larger than the clearance the collet has to work with); PETG rings
      need none, because the collar is PETG.
- [ ] Print collar + ring; check the ring actually closes the collet on the real cane
- [ ] Print arm + cradle; T0 fit with the phone in it. **CORRECTION 2026-09-12: the arm now DOES
      depend on `dt_clear`**, via `arm_tip_t = dt_narrow - 2*dt_clear`, added when the fin was
      narrowed to pass the socket mouth. **RE-CORRECTED, Step 25: `arm_tip_t` is gone** — the fin
      no longer passes through the socket mouth at all (it lands on a pad under the cradle's block),
      so the arm's tenons are nominal again and it can be printed before the dovetail coupon. Measured: arm volume 42.865 / 42.656 / 42.448 cm3 at
      dt_clear 0.15 / 0.25 / 0.35. `pole_d` genuinely does not reach it. So the dovetail coupon
      must be read BEFORE the arm is printed — the old "printable first" advice would have wasted
      it. The same wrong claim is in PRINTING.md, CHANGELOG Step 18 and slice_gcode.ps1.
- [x] ~~Pawl release window is ~79% blocked by the arm~~ — moot (Step 25): the collar joint has no
      pawl any more (the ring is its lock, socket open at the top), and the far pawl's window is
      through the cradle's roof just under the phone's bottom edge, open to a fingernail.
- [ ] Remaining unfixed, found by review on 2026-09-12 and not yet addressed: `socket_part()`'s
      "flare" is a flat 90° ledge, not a flare; ball-socket fingers at ~7–9% strain will crack
      (ball joint only — not the demo path). Fixed in Step 25: the far pawl's catch has a 45° lead;
      the rails that now continue up beside the phone stop at z = 2.0, under the buttons (they
      start at z = 3.0), so the overrunning windows cut nothing that matters; the dovetail flanks
      are 45°, which makes `dt_clear` uniform along the flank.
- [x] **Cane diameter SETTLED at 27.65 mm, 2026-09-12.** Was disputed three ways (27.65 dial
      caliper / 28.75 repo+brief / 28.65 = 1.128 in). The bore rings decided it against the real
      shaft and agreed with the caliper to 0.01 mm. `hardware/mount/cane_mount.scad` and
      `test_coupons.scad` moved off 28.75 in the same commit. NOTE: the shaft is a BROOM HANDLE
      standing in for a cane — real long canes are 9.5–13 mm at the tip end (Ambutech published
      figures; Rodgers & Wall Emerson, JVIB 99(11) 2005), so every fit number here is a number for
      the prototype shaft, not for a cane.
- [ ] Ball joint (`joint = "ball"`): print socket + lock, check the clamp actually holds the
      phone through a sweep. Brief and mount/DESIGN.md rejected free ball joints; this one is
      clamped, which answers that but is untested.
- [ ] Decide on the day: `hardware/mount/` (screwed) or `hardware/mount_screwless/`. Record which in
      CHANGELOG.md.
- [ ] T7 shake / T8 drop on whichever is fitted; check the camera still reads 3–8° down afterwards

### Hardware, later that evening (Windows machine) — see CHANGELOG Step 25
- [x] `scripts/verify_mount.ps1` + `hardware/mount_screwless/verify.scad` + `scripts/stl_tools.js`:
      30 model checks (intersections that must be empty, ones that must not, the thread driven
      through its travel, the ring as the arm's lock, shells, overhangs). All green. **Run it after
      any change to the .scad; the preview cannot see overlaps.**
- [x] Step 21's blocking items 1–3 closed: the arm no longer passes through the phone (socket moved
      below the phone's bottom edge, `sock_y`); the top latch (loose island, on the plateau) replaced
      by sprung top-corner caps, phone loads from the front, floor open for USB-C; both sockets have
      stops — the collar joint is locked by the ring (no pawl), the far joint by a leaf pawl on the
      fin's bed face.
- [x] **Why the printed ring would not go fully down:** the cone started 0.75 mm outside the ring's
      thread crests and the ring's own thread hit it 3.8 mm from home (0.165 cm³ at every height
      from 6 mm up, found by lifting the ring in the model). `cone_relief` 0.10, taper 1.6, squeeze
      0.6. Thread cut to nut 3 of the four-nut coupon, [0.45, 0.45]; flank 60°.
- [x] Support was OFF in every headless slice; `slice_gcode.ps1` turns it on for the cradle,
      bridges the socket roof (Orca's default filled the socket — checked in the gcode), refuses a
      cradle file without it.
- [x] Dovetail flanks 67° → 45° (24 / 14 / 5); dovetail coupon tenons lie on their side like the arm's.
- [x] `build_stl.ps1` renders the coupon rows under the names the slicer asks for (`coupons_bore`
      etc. — Step 21's `bore.stl` was never found by `slice_gcode.ps1`).
- [ ] **Print `coupons_next`** (thread row: stub + four nuts; dovetail row) from this geometry. Smallest
      nut that runs the full length → `thr_clear`/`thr_axial`; dovetail that slides and stays →
      `dt_clear`. Rebuild, rerun `verify_mount.ps1`, then collar + ring: with no cane the ring
      reaches the shoulder, with the cane it stops ~3 mm short.
- [ ] Print the cradle; check the corner caps' spread force with the phone (calculated ~2 N each)
      and that the caps clear the plateau; measure `plateau_h` with calipers while the phone is out.
- [ ] Print the arm; check the far pawl clicks into the cradle's window and releases with a nail.
- [!] Step 21's item 4 stands: the collar is a closed bore and goes on over the end of the shaft.
      Fine on the broom handle; on a real cane it needs a split collar or a removable tip. Not designed.

### Scene understanding: the decision, and why (researched 2026-09-11, 65 agents)

**Question asked:** run Gemma 4 2B/4B locally via Cactus so the app can name everything it sees,
instead of the fixed 1,303-label Apple classifier that returned *nothing* on the phone tonight.

**Answer: no local VLM before this demo. Use the cloud client that is already in the repo, gated.**

- **Cactus is disqualified by an open bug, not by taste.** github.com/cactus-compute/cactus issue
  #802 (filed 2026-09-01, still open): `cactus_complete` **with an image never returns** — the Metal
  backend deadlocks in `waitUntilCompleted` during chunked media prefill, on iOS and macOS. Metal is
  the default backend on iPhone; the suggested workaround is CPU. v2.2.0 (2026-09-08) shipped without
  touching it. Separately, an independent iPhone 17 Pro benchmark found the CQ4 build `cactus run`
  ships by default scores **3.0 % on GSM8K** where the build they demoted scores 87 %. Licence is
  source-available (free under $2M funding *and* revenue), not open source.
- **Gemma 4 E2B locally is disqualified by cost and coverage, not capability.** It needs SPM packages
  (AGENTS.md hard rule 2), **~3.0 GB** charged footprint for the 4-bit build on an iPhone 17 Pro —
  text-only, before an image encoder, ARKit, LiDAR and audio — a 1.8–3.6 GB first-run download, and
  **MLX does not run in the iOS simulator**, so `make sim`, `make uitest` and `make e2e` would all
  break. No iPhone vision-encoder latency for Gemma 4 has been published by anyone; we would be
  measuring it for the first time, on the demo phone, the night before.
- **Gemma 3 / 3n:** the LiteRT repos are manually gated on HuggingFace — an approval delay we cannot
  absorb. If we ever do go local, go Gemma 4 E2B (Apache-2.0, ungated), not Gemma 3.
- **Apple FastVLM 0.5B:** right shape, but its model licence is research-only and excludes product
  development.
- **Apple FoundationModels with the image (iOS 27):** the best *future* path — first-party, no
  packages, no key, no network — and already built on `feat/fm-image-describe`, off by default. Not
  the demo path: it needs an iOS 26 availability waiver, and handed a solid white frame it said
  *"The path ahead is clear and unobstructed"* 4 times out of 4.

**What we do instead:** `ios/CaneKit/Scene/VLMClient.swift` already ships a working Gemini client with
cloud-primary / on-device fallback and unit-tested codecs. It needs a key, not code.

- [!] **Gemini key — waiting on Aritro** (optional; the app works without it). See below.
- [x] Gate the cloud reply (done: `CloudSceneGate`, wired in `VLMClient`; Step 34 audit) — `SceneVocabulary.isFaithful` runs on the on-device path **only**, so a
      cloud sentence is currently spoken ungated. Measured hallucinations of exactly this class on our
      own route frames: "S 5th St", "S Grand Blvd". In progress on `fix/cloud-scene-gate`.
- [x] Fix the prompt (describe + Ask paths done: `ScenePrompt`; ⚠ the **hazard watch** prompt still asks for metres — open, Step 34 audit): it asks for clock-face directions and distances in metres. VLMs read clock
      directions from the *image's* frame rather than the walker's, and distance is the one thing they
      are measurably worst at (below chance — GuideDog, ACL 2026). LiDAR supplies every number.
- [ ] Measure the real round trip from the phone on campus cellular and write down p50 and max. Do not
      quote anyone's benchmark at the demo; quote ours.
- [x] Leave the hazard watch **off** for the demo (default off; don't say "turn on hazard watch" to the assistant in rehearsal) (it is the only thing that would call a model in a
      loop).

**The line to say out loud at the demo:** *the model names things; LiDAR measures them. No number the
sensors did not see is ever spoken.*

### Gemini setup (optional, 3 minutes, Aritro only)

1. aistudio.google.com → **Get API key** → **Create API key**. Copy it.
2. In `ios/CaneKit/Resources/Secrets.plist` set `VLM_PROVIDER` to `gemini`, paste `GEMINI_API_KEY`,
   and set `GEMINI_MODEL` to `gemini-3.5-flash-lite` (fastest measured of 53 models: 2.70 s average).
3. ⚠ **Privacy, decide deliberately:** Google's pricing page marks "content used to improve our
   products" as **Yes** on every free-tier row and **No** on every paid row. This app points a camera
   at strangers on the Quad. Attach billing to the project, or accept that free-tier frames may be
   used for training. Either is a choice; making it by accident is not.
4. Kill switch if it misbehaves on stage: turn off Wi-Fi and cellular. `waitsForConnectivity = false`
   means the request fails at once and the on-device describer answers. Nothing else is affected.

### ElevenLabs setup (2 minutes, Aritro only — nobody else can do this)

The natural voice is already written, reviewed and merged (`ios/CaneKit/Speech/ElevenLabsVoice.swift`).
It stays silent for one reason: no key. Every line is cached as an mp3 on disk keyed by
voice + model + text, so a line the app has spoken once replays instantly and costs nothing; a miss
waits at most 2.5 s and then falls back to the Apple voice, and after a failure the app stops trying
for 60 s so a weak network can never stall a cue.

1. Sign in at elevenlabs.io → click your avatar (bottom left) → **API Keys** → **Create API key**.
   Copy it. The free tier's 10,000 characters a month is far more than the demo needs, because the
   route lines are prefetched once and then cached.
2. Pick the voice: **Voices** → play a few → on the voice you like, the **⋮** menu → **Copy voice ID**.
   Skip this to use the default (`21m00Tcm4TlvDq8ikWAM`, a calm premade voice).
3. Open `ios/CaneKit/Resources/Secrets.plist` (git-ignored, never committed) and paste:
   - `ELEVENLABS_API_KEY` → the key from step 1
   - `ELEVENLABS_VOICE_ID` → the ID from step 2, if you picked one
   - `ELEVENLABS_MODEL` → leave as `eleven_flash_v2_5` (lowest latency of the ElevenLabs models)
4. `cd ios && make build install launch`.
5. Verify on the phone: tap **Speech test** on the Haptics card. The pill next to "Speaking" reads
   **System** with no key and flips to **ElevenLabs** once a line has played through the new voice.
   If it stays System, the key is wrong or the network is down — the app still speaks, just in
   Apple's voice, so a bad key can never break the demo.

## Step 11 — Hazards the maps don't know, on-device vision, stress harness (pre-device)
- [x] LiDAR ground hazards (GroundSampler + GroundHazardDetector), 4-tap cane haptic, off by default
- [x] On-device sign reading (Vision text down to 1/128 of the frame, 7.5 cm letters from ≈ 7 m measured, once a minute per phrase)
- [x] Hazard watch (cloud 2.5 s → on-device; stale replies dropped), off by default
- [x] Keyless "Where am I" (Apple Vision + Foundation Models, template fallback)
- [x] Hazard map GeoJSON + photos, Share on the Hazards card; Files app sharing on
- [x] Route cues as long buzzes on the cane; debug footer removed
- [x] CourseSmoother veer (15 m); corner-fence reset; reset after each veer cue
- [x] Muse full-app review fixes (H1–H3, M1–M8, L2/L5/L6)
- [x] Round-4 and round-5 adversarial reviews (28 + 22 findings) fixed; nav harness 0 false veers / 72 walks
- [x] Logic tests (historical 146 green after Step 12), simulator build, 7 XCUITests + tour, `make e2e` (clean, missed_fence, gps_jitter, wrong_turn)
- [x] Street View mock of ISR → CIF: FrameReplay, `make uitest-streetview`, `make e2e SCENARIO=streetview`, vision_probe
- [x] graphify knowledge graph (`graphify-out/`, `graphify query`)
- [x] docs/stress_test_plan.md, docs/README.md, hardware/mount (phone-to-cane mount for Sagar)
- [x] Muse + Antigravity check of the final diff (rounds 6–7 and the docs review)
- [ ] Commit "Step 11 + 12 (pre-device)" + push
- **test on device:** see CHANGELOG Step 11 and docs/stress_test_plan.md

## Step 12 — Google Street View mock of ISR → CIF (pre-device)
- [x] Trip-log `scan`, `hazard_watch`, `describe_result` records; FrameReplay frame names
- [x] Street View e2e: hazard watch on, "Where am I" at start + every waypoint, ≥ 8 of 10 described
- [x] `SceneVocabulary`: plain pedestrian nouns instead of Vision taxonomy words (5 tests)
- [x] `sign_probe.swift`: measured sign range; text floor 1/128 (7.5 cm letters ≈ 7 m); STOP dropped, PUSH BUTTON added
- [x] "OpenCane ready." no longer spoken after "Camera access is off"
- [x] On-device model gate (`isFaithful`: names a detected thing, no invented numbers), OCR-junk filter, new prompt
- [x] One-word sign phrases must be close (`shortPhraseMinHeight` 1/80); people / ice / plants in the vocabulary
- [x] Engineering bar written into AGENTS.md + CLAUDE.md; hardware/ handed to Sagar
- [x] Commit b1c35bd pushed (Steps 11–12); follow-up commit with the model-gate fixes
- [x] docs/TEAM_HANDOFF.md + README / docs index / iOS README refreshed; Muse + Antigravity docs review folded in
- [ ] Deferred from the Antigravity nav review (verify on device, fix if real): head tracker only with
      AirPods connected; move `observeThermalAndBattery()` after the audio session is configured;
      announce skipped waypoints in the passed-by path too
- **test on device:** see CHANGELOG Step 12

## Step 20 — Passed-by slow approach fix, Live Activity overlap prevention, and Watch keep-alive guard (Sat Sep 12)
- [x] Full codebase stress test across Depth, Navigation, Audio, Speech, Watch, and Trip Logging
- [x] `GeofenceTracker.update`: reset `recedingFixes` when approaching waypoint (`d <= minDistance`), tested in `passedByResetsRecedingStreakDuringSlowApproach`
- [x] `LiveActivityController`: added `immediate: Bool = false` dismissal policy; `start()` and `AppModel.endRouteQuietly()` use `immediate: true` to prevent stacked lock screen activities
- [x] `WatchModel.updateKeepAlive`: guarded with `!text.hasPrefix("No route")` to prevent false workout starts on idle status messages
- [x] Dual camera + LiDAR depth architecture audit: verified hardware capabilities on iPhone 17 Pro Max (12 multi-cam sets with front + rear LiDAR depth at 320x240) and ARKit single-camera constraint
- [x] Historical verification: 348/348 unit tests, `make sim` build, 10/10 UITests + visual tour, and clean GPS e2e replay (100% pass, 9/9 waypoints)
- [x] Device install and verification on connected iPhone 17 Pro Max
- **test on device:** see CHANGELOG Step 20

## Step 21 — Bolt: Decouple 30 Hz depth stream from ContentView root (Sat Sep 12)
- [x] Profiled SwiftUI Observation invalidation under high-frequency LiDAR updates (historical 15–30 Hz `model.depth.report`; current normal cadence is 30 Hz, high-rate is up to 60 Hz)
- [x] Extracted `ObstaclesCard` and `MountAimRow` leaf subviews inside `ContentView.swift`
- [x] Preserved pure value semantics on `LaneGridView(report:)` and hoisted `laneNames` static array
- [x] Verified zero concurrency regressions under Swift 6 strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`)
- [x] Muse adversarial review passed, adopting Muse's recommendation for leaf container over environment fallback
- [x] Historical verification: 348/348 Logic tests (`make test`), clean simulator build (`make sim`), 10/10 UITests (`make uitest`), and e2e replay
- **test on device:** see CHANGELOG Step 21

## Step 22 — Rename primary route action to "Start route to CIF" (Sat Sep 12)
- [x] Renamed GuideCard button from the historical "Start demo route" to "Start route to CIF"
- [x] Added "Start route to CIF in OpenCane" to Siri App Shortcuts in AppIntents
- [x] Synchronized test contracts across `AGENTS.md` (Rule 9), `docs/CODE_REFERENCE.md`, `docs/design.md`
- [x] Updated `CaneKitUITests` and `CaneKitVisualTour` and verified all 10 tests pass
- [x] Muse adversarial review passed confirming 1:1 label parity and zero contract regressions
- [x] Built and deployed to physical iPhone 17 Pro Max (`00008150-001A698C1108401C`)
- **test on device:** see CHANGELOG Step 22

## Step 27 — Three icon-only root tabs (Sat Sep 12)
- [x] `RootTab` + `CKTabBar` (`ios/CaneKit/UI/TabBar.swift`): icon-only, sliding accent capsule
      (`matchedGeometryEffect`), 60 pt hit targets, `.sensoryFeedback(.selection)`, Reduce Motion honoured
- [x] `ContentView` split into `GuidePage` / `SensePage` / `SettingsPage`; only the visible page is in
      the tree, so the Step 21 30 Hz depth isolation still holds
- [x] Fixed: the bar filled the screen — a `Capsule` as a `ZStack` sibling takes the whole proposed
      height; it is now the `.background` of a fixed 62 × 36 box (hit area still 60 pt)
- [x] Fixed: pages all slid in from the right, so moving back left looked like moving forward.
      Direction tracking was tried, then dropped for a 0.2 s cross-fade — pages never slide sideways
- [x] VoiceOver labels "Guide" / "Sense" / "Settings" pinned in AGENTS.md rule 9 and design.md §9;
      `CaneKitUITests` + `CaneKitVisualTour` open the matching tab before looking for its controls
- [x] Rebased onto Step 25; the three label conflicts kept both the "Start route to CIF" rename and
      the tab rows. Two stale `docs/CODE_REFERENCE.md` lines (motion summary, 4-tab divergence note) fixed
- [x] Fixed `make test`, which did not compile on Xcode 27: `DepthReadinessTests` called the
      `mutating` `DepthFrameContinuity.accepts` inside `#expect` (immutable closure capture). Six
      calls hoisted into locals, order preserved. ⚠ `#expect(x.update(…) == v)` is fine; the bare
      boolean form is not
- [x] Verified: `scripts/gen.sh`, `make test` **366/366**, `make sim`, installed + launched on the
      booted iPhone 17 Pro Max simulator (compact bar confirmed by screenshot)
- [ ] `make uitest` + `make tour` — needs `xcrun simctl location <udid> set 40.1140,-88.2249` first,
      or the route tests fail for want of a GPS fix (unrelated to the tabs)
- [ ] Muse + Antigravity adversarial review of this diff (AGENTS.md "How we engineer" 3)
- **test on device:** see CHANGELOG Step 27

## Step 39 — Cane events → Grok Bot family alerts (Sat Sep 12)
- [x] `GrokBotEvent.swift` (Logic): `OpenCaneEvent` + `OpenCaneEventType` (open, so an unknown type
      decodes) + `OpenCaneJSON` for `extra`; `CodingKeys` asserted as bytes — they are the bot's contract
- [x] `FamilyAlertPolicy.swift` (Logic): breadcrumb 120 s, obstacle 60 s and ≤ 1.2 m, low battery once
      per discharge re-arming above 30 %; fall/sos never limited; `reset()` keeps battery arming
- [x] `Alerts/GrokBotClient.swift`: bearer POST, 10 s timeout, one retry on transport failure, none on
      non-2xx (a 401 stays a 401; a re-POSTed `fall` would double-text). Logs status + body, never headers
- [x] `Alerts/FamilyAlerts.swift`: main-actor relay, fire-and-forget sends so a POST never delays a cue
- [x] `AppModel` call sites: `location.onFix` breadcrumb, obstacle beside the spoken line,
      `updateBattery()`, `family.reset()` at route start, `sendFamilyTestEvent()`
- [x] Settings → Family alerts: opt-in (default off, in `LaunchRecovery.optionalFeatureKeys`),
      "no webhook key" explanation, "Send test event" that works while the switch is off
- [x] Keys in git-ignored `Secrets.plist` only (`OPENCANE_GROKBOT_WEBHOOK_URL` / `_KEY`), env read
      first; `ios/README.md §4.1` documents both plus a curl example
- [x] Verified: `make test` **383/383**, `make sim` green, webhook answered HTTP 200
      `{"success":true,"runUuid":…}` to the curl sample
- [x] `AlertContext.swift` (Logic): the phone's state → `extra` fields, omitting unknowns and −1
      sentinels; `AlertContextPrompt` with the safety bans (no false reassurance, no invented
      places, no instructions to family), pinned by tests
- [x] `AlertSummarizer.swift`: cheapest model of whichever provider has a key; own session, 6 s
      timeout, every failure → nil so the alert still goes with its facts
- [x] Measured, not guessed: `max_completion_tokens` 4096 (200 and 1024 both returned
      `content: null` silently) and `reasoning_effort` "minimal" (2.1 s vs 7.1 s for "low")
- [x] Settings → Family alerts → "Add AI context" (default on) + the model name
- [x] Verified end to end: facts + `ai_context` POSTed to the live routine, HTTP 200
- [ ] ⚠ No Anthropic key in Secrets.plist — `ai_context` currently comes from the Muse custom
      endpoint. Add `ANTHROPIC_API_KEY` to use Haiku instead (cheaper and faster for this job)
- [x] `FamilyContacts.swift` (Logic): validation, normalise (trim / lowercase / dedupe / cap 10,
      idempotent), `rejected` for the UI, and the `family_contacts` registration event
- [x] Schema: `emails` + `send_test` for that event only; a test pins that a `fall` carries neither
- [x] `FamilyAlerts.registerContacts` — ignores `enabled`, no rate limit, and skips the enrichment
      path so addresses never reach the summarizer model
- [x] Settings → Family emails: add / remove / Save, refusal reasons, "Remove <address>" labels
- [x] `send_test` only on the first accepted Save; flag set on acceptance, so a failed first Save
      still tests next time
- [x] Fired live: registration `runUuid d1b76d16`, then a `fall` `runUuid f5e7f43a`, both HTTP 200
- [ ] Confirm with Aritro that the list stuck and the Gmail alert arrived (bot side)
- [ ] XCUITest for the contacts editor (add / refuse / remove); not written yet
- [ ] **No fall detector.** `FamilyAlerts.fall(…)` is written and tested but nothing calls it. Needs
      CoreMotion + a numeric threshold from real data, in `ios/Logic` with its own tests (hard rule 3)
- [ ] **No SOS control.** `FamilyAlerts.sos(…)` likewise — wants a watch button / Action Button /
      Siri phrase, all three of which already have plumbing
- [ ] Confirm on the phone that a `warn` actually reaches a family member's SMS (bot side, not ours)
- [ ] Muse + Antigravity adversarial review of this diff (AGENTS.md "How we engineer" 3)
- **test on device:** see CHANGELOG Step 39

## Step 43 — Falls, weapons, trip bookends, webhook spam guard (Sat Sep 12)
- [x] `ActionRateLimit` (Logic): 10 s between repeats of a webhook action; a refused tap never
      extends the wait; `secondsRemaining` so the refusal can be spoken
- [x] Contacts editor redesigned: no fake placeholder, card rows + 44 pt trash, `+` disabled until
      you type, Save goes primary while edits are unregistered
- [x] `FallDetector` (Logic) free fall → impact → still-and-tilted + `FallWatcher` (CoreMotion, 20 Hz);
      one alert per episode, re-arms when upright
- [x] `ThreatWatch` (Logic): weapon / attacker nouns in vision replies, whole-word, benign
      collocations and clause-scoped negation; checked on the RAW reply; one per 2 min
- [x] `trip_start` / `trip_end` (warn, so the bot emails); Stop on an idle guide sends nothing
- [ ] ⚠ **Measure the fall thresholds.** Drop a cane from waist height 10+ times with the trip log
      running, read `fall` records and the raw motion, and re-derive freeFallG / impactG / tilt.
      Until then this is a guess shipped on, which AGENTS.md "evidence before claims" does not allow
- [ ] Measure the threat matcher against real hazard-watch replies from a walk: count false
      positives before trusting it on the demo
- [ ] XCUITest for the contacts editor and the rate-limited buttons
- [ ] Grok Bot side (not app code): show reasoning while it works, and send a separate
      "sending test email" message rather than one silent email
- **test on device:** see CHANGELOG Step 43

## Step 40 — Dynamic Island idle state & obstacle radar pill (Sat Sep 12)
- [x] Scoped `.otherNavigation` and `CLBackgroundActivitySession` to active navigation (`setNavigating`)
- [x] `LiveActivityCoalescer.swift` (Logic): non-linear distance bands, 0.2s flap-guard, immediate emergency emissions
- [x] `NavLiveActivity.swift`: leading turn glyph + distance, trailing obstacle radar pill, expanded radar banner
- [x] Surfaced Live Activity errors in `GuideCard`

## Step 41 — Enriched hazard telemetry for Grok Bot & anti-flapping (Sat Sep 12)
- [x] Enriched `HazardRecord` and `HazardGeoJSON` with distance, height delta, direction, heading, speed, route, instruction, source, and severity
- [x] Added `asGrokBotEvent(user:caneID:)` for direct Grok Bot ingestion
- [x] Anti-flapping in `GroundHazardPolicy`: `isSameFamily` suppresses rapid depression toggling (pothole vs drop-off)
- [x] 3-second temporal/spatial debounce in `HazardLog.record`
- [x] Dynamic centered navigation title (`OpenCane`, `Sense`, `Settings` with `.inline` display mode)
- [x] Added startup cleanup of orphaned `CLBackgroundActivitySession` in `LocationService.init()`

## Step 42 — Graceful GPS fallback, activity cleanup & on-device walk simulator (Sat Sep 12)
- [x] Extended depth readiness check to 7.0 s with graceful fallback to GPS guidance ("Obstacle detection warming up. Guiding with GPS.")
- [x] Dynamic Island orphan activity teardown on startup via `liveActivity.endAllOrphanedActivities()`
- [x] On-device walk simulator in `AppModel.swift`: `startSimulatedWalk` and `stopSimulatedWalk` with 1 Hz synthetic GPS/heading injection
- [x] Centered navigation bar titles with `ToolbarItem(placement: .principal)` and `.title2.weight(.bold)`
- [x] Middle tab title updated to "Details"

## Step 44 — Medical ID Profile tab, mobility fitness & streamlined Guide (Sat Sep 12)
- [x] Fixed Dynamic Island idle location arrow by removing `CLBackgroundActivitySession` instantiation from `LocationService.init()`
- [x] Streamlined GuideCard idle buttons: Where am I + Talk paired in HStack; Start route to CIF primary hero; Navigate to CIF + Simulate walk paired in HStack
- [x] Added 4th root tab `.profile` (`ProfilePage.swift`, `RootTab.profile`, `pillWidth = 64`)
- [x] Emergency Medical ID card: white cane / blind safety alert banner, vitals grid, tap-to-call emergency contact, announce medical ID button, edit sheet modal
- [x] Mobility & fitness tracking in `MedicalProfileStore.swift`: daily steps, distance (km), trips completed, average pace via `CMPedometer`
- [x] Configured `OPENCANE_GROKBOT_WEBHOOK_URL` and `_KEY` in `Secrets.plist`; verified HTTP 200 curl response

## Step 60 — Consent-gated Supabase MVP (Sun Sep 13)
⚠ Drafted twice, as "Step 56" and as a second "Step 51"; both drafts are this one section, and
CHANGELOG Step 60 is the entry. "Step 51" already means two other things here.
- [x] Supabase migration `reduce_to_mvp_cloud_schema`: removed `app_launches`, `trip_events`,
  `routes`, `route_waypoints`, `device_settings`, `posts`, `conversation_turns`, `mobility_days`
  and `family_alert_recipients`, plus their non-MVP dashboard views
- [x] Kept the seven records a walker or family needs off-phone: `walkers`, `devices`,
  `medical_profiles`, `family_contacts`, `trips`, `hazards` and `family_alerts` (plus the capped
  `hazard-photos` bucket)
- [x] `CloudSync` preserves explicit cloud consent while making no request to a removed table; the
  retired writers are documented no-op seams so an old call site cannot recreate a write path
- [x] `TripEventRow` / `DeviceSettingsRow` stay in `CaneKitLogic` with their tests (the wire shape is
  the contract with the migrations), but their doc comments now say the app writes neither today
- [ ] Device: opt in, start/stop a route and confirm `trips` gets one summary; edit Medical ID,
  record a hazard and send a family alert, confirming each retained table updates without a cloud
  error; then opt out and confirm no deferred write lands

## Step 46 — Audit of the Supabase mirror (Sun Sep 13)
- [x] Route restart closes the cloud walk (`endRouteQuietly`) — it used to leave the old row open for ever and stamp the new walk's lines with the old trip id
- [x] `CloudBatchPolicy.shiftMark` keeps the trip mark true across a flush, with a test
- [x] `HazardLog.record` returns `HazardRecord?` — a debounced detection no longer re-uploads the previous hazard
- [x] `closeAbandonedTrips` closes walks a killed process left open, as `abandoned` (verified against the live project with a probe row)
- [x] `opencane_07`: a trigger maintains `family_contacts.alerts_sent` / `last_alerted_at`; the phone's PATCH removed
- [x] Superseded by Step 60: settings, telemetry, posts and conversations intentionally remain local, and the MVP device verification is tracked there. `CloudBatchPolicy.shiftMark` went with the queue.
- **test on device:** see CHANGELOG Step 60

## Step 45 — Supabase cloud mirror (Sat Sep 12)
- [x] 16 tables + 4 demo views + 3 RPCs + `hazard-photos` bucket, migrations `opencane_01`…`_06`, every table commented
- [x] PostGIS `geography` generated columns on `hazards` / `posts` / `route_waypoints`, GiST indexed; `hazards_near(lat, lon, radius)`
- [x] RLS on all 16 tables with explicit anon policies; advisors clean on the OpenCane tables
- [x] `CloudSchema.swift` + `CloudSchemaTests.swift` (CaneKitLogic): row types + `CloudBatchPolicy`, 17 tests
- [x] Uniform-key encoding for bulk inserts (avoids PostgREST `PGRST102` mismatched-key rejection)
- [x] `SupabaseClient.swift` (hand-rolled PostgREST + Storage over URLSession, no SDK) and `CloudSync.swift` (queue + 5 s flush)
- [x] Wired: `TripLogger.onRecord`, `recordHazard`, `dropPost`, `FamilyAlerts.onDelivered`, `MedicalProfileStore` hooks, `Settings.onChange`
- [x] Family email list mirrored through `save_family_contacts` only — never in a log payload or an alert row
- [x] Fixed: trip + route opens deferred until `register_cane` returns
- [x] Verified `make test` (555) / `make sim` / `make e2e SCENARIO=clean`, rows queried back out of Postgres
- [x] ~~Device: walk the route on the cane, then check `trip_summary`, `device_settings`, …~~ — not
  runnable as written: Step 60 dropped `device_settings`. The MVP device check is Step 60's.
- [x] ~~Open: conversation turns are wired but `ConversationCoordinator` does not call
  `recordConversationTurn`~~ — moot: transcripts are local-only by decision (Step 60), and
  `recordConversationTurn` is a no-op seam. The publishable-key family-contact policy review is
  still open, tracked in Step 60's device item.
- **test on device:** see CHANGELOG Step 45

## Step 50 — Typing a destination: tab bar collapses with the keyboard, no rows from other countries, torch probe (Sat Sep 12, 23:21)
- [x] Owner's screenshot: iOS 26's floating keyboard "Done" sat on the Profile tab icon; "Oab" listed Australia, Michigan, Rio
- [x] Tab bar collapses (height 0, VoiceOver-hidden, still mounted) while the keyboard is up
- [x] `Locality.plausiblyNearby`: completer rows ending in another country's name dropped (Foundation ISO region names); other US states kept on purpose; walker's country from a reverse geocode, request-stamped, no re-announce
- [x] Torch dead-zone probe (Muse on Step 49): 1 s off once a minute after the minimum on-time; real light ends the episode, otherwise straight back on, confirmations muted
- [x] Muse compact review: 8 findings, 5 taken, rest moot after the rework; 630 / 630 tests
- [ ] On the phone: type "Oab" — no Australia / Rio; tab bar gone while typing, back after Done / Go; walk a torch-lit route into a lit lobby — the torch goes off within a minute; in a dark hallway it blinks off for 1 s once a minute and comes back

## Step 51 — Adversarial safety hardening (Sun Sep 13)
- [x] GPS stream liveness: `NavigationHealth` rejects stale/future fixes after 5 s; `LocationService` reports stream termination or permission revocation; `NavigationEngine` withdraws target/bearing cues and resumes only on a fresh fix.
- [x] Terminal AR failure: retained frames are dropped, `HazardScanner` and face-yaw tracking stop, and late callbacks are generation-fenced. Deferred mesh, frame-rate and face settings apply only after the route ends.
- [x] Audio/haptics lifecycle: runtime haptic errors mark the engine unhealthy; SpeechQueue and VoiceInput clean up in safe order; interruption, route, permission, analyzer and decode failures use the existing speech/watch fallback channels.
- [x] Async race fencing: arrival summaries, HealthKit step refreshes and Live Activity operations cannot write or speak for a replaced route/activity.
- [x] Safety UI and privacy: Stop route is two-tap/three-second confirmed; People detection is off by default and labelled experimental/unverified; Profile starts without seeded PII; cloud mirroring requires explicit consent and can be disabled (queued uploads are dropped, local data remains).
- [x] Profile accessibility and simulator gate: metric tiles use Dynamic Type and combined labels; unavailable hazard controls explain why; `sim-grant` checks boot/privacy failures and seeds GPS.
- [x] Logic gate: **654 tests in 12 suites passed**; simulator build succeeded. New pure coverage includes navigation freshness, People detection, Stop confirmation and trip-generation fencing.
- [ ] Device checks: AirPods HFP/disconnect during sound recognition and push-to-talk; AR interruption/resume; location revocation and stale GPS; forced haptic/audio failure; dark-room and wall proximity; accidental Stop taps; People detection false-positive/false-negative/latency measurements; cloud consent and remote-row deletion policy.

## Step 49 — Low light: notice the dark for the walker, say what still works (Sat Sep 12, late)
- [x] Owner's question 22:50 ("we have the flashlight and LiDAR doesn't need light — what else?"). Honest answer: LiDAR, gyro gate, GPS, compass, haptics unaffected; ARKit tracking, signs, scene words, people, "Where am I", hazard watch degrade silently — and a blind walker cannot tell it is dark
- [x] `LowLightPolicy` (CaneKitLogic, 11 tests): 0.3 s EMA over `ARFrame.lightEstimate.ambientIntensity` (`LaneReport.ambientLux`), dark after 3 s under 40 lux, lit after 5 s over 120, unknown before the first estimate, 60 s minimum on-time for an app-lit torch (the torch raises the reading), 60 s backoff after a thermal cut-out, no auto-torch at ≤ 20 % battery (`FamilyAlertLimits.lowBatteryPct`) — **all [H]**
- [x] `AppModel`: "Flashlight on in the dark (routes)" (Mount card, **default ON — deliberate, AGENTS.md**), torch only while a route guides via `setTorch(_:byApp:)`, off on lit / Stop / arrival / restart, walker's own torch never touched; "Low light. Obstacle detection still works." (+ " Flashlight on.") once per episode at `.nav` 10 s; the duplicate "Flashlight on." confirmation muted; `light {state, lux, torch, torch_by_app}` records
- [x] Vision honesty: "It is dark, so this may miss things. " prefix on "Where am I" / a question when dark with no torch; `ScenePrompt` asks for "It is too dark to see." (`CloudSceneGate.tooDark` passes it, spoken as the answer); `HazardPrompt` asks for NONE in the dark; `scan` / `hazard_watch` carry `light: "dark"`; no mesh name (`centerHit = nil`) while tracking is not `.normal`
- [x] `DepthReadiness.TimeoutReason` (2 tests): a timeout with depth live but tracking never `.normal` speaks "Camera tracking is limited, probably low light. Obstacle detection is running on LiDAR." (`.safety`, 15 s) instead of the false "Guiding with GPS."; `route_readiness {state: timed_out_tracking_limited | timed_out_fallback_gps, reason}`
- [x] Details → Scene engine "Light" row (3 tests): "Light: lit (640 lux)" / "Light: dark (12 lux) · flashlight on (by OpenCane)" / "Light: dark (12 lux) · flashlight off — cameras may miss things" / "Light: unknown"; Guide card DARK pill (warning) next to GPS
- [x] `make test` 626 / 626; simulator build clean; docs (design.md §5.1 / §5.4 / §6.5 / Scene engine, CODE_REFERENCE, AGENTS.md two bullets)
- [ ] **On the phone, dark room, torch off**: start a route → within ~3–4 s the torch comes on and "Low light. Obstacle detection still works. Flashlight on." is spoken **once**; no second "Flashlight on."; the tiles still show obstacles; Stop → "Flashlight off."; Details → Light row reads "dark (N lux) · flashlight on (by OpenCane)"
- [ ] Dark room, no route: the line is spoken without "Flashlight on.", the torch stays off, the Guide card shows DARK; "Where am I" starts with "It is dark, so this may miss things." (or the model answers "It is too dark to see.")
- [ ] Dark hallway route start: does readiness time out with `reason: tracking_limited_depth_live` and speak the LiDAR line (not "Guiding with GPS")? Do obstacle cues run during it?
- [ ] Walker's own Flashlight switch on, then a route in the dark: the app must not switch it off at Stop
- [ ] Lit room → torch cycle check: while the app's torch is on the exit threshold is `litWithTorchLux` (400 lux [H]); read `light` records in a torch-lit hallway and at a lit crossing and tune 400 so the glow never ends the episode but a lit building does
- [ ] Tune 40 / 120 lux and 3 / 5 s from the `light` + `lanes` records of a dusk walk (a street-lamp pool must not end an episode; a doorway shadow must not start one)
- [ ] Battery: at ≤ 20 % the torch must not auto-light (the plain line is spoken); thermal: after "The flashlight turned off." the app must not relight it for 60 s
- [ ] `cloudSettings` / `DeviceSettingsRow` do not carry `autoTorchInDark` yet (Supabase schema change) — add the column with the next cloud step

## Step 48 — Point-blank: a wall against the phone is STOP, never CLEAR (Sat Sep 12, late)
- [x] Root cause from the teammate's photo: inside ~10 cm the LiDAR returns 0 / NaN, `LaneMath` discarded them, the cell went `.infinity` = CLEAR; Step 38 only covered low-confidence finite returns
- [x] `LaneMath` blind share per cell; `NearHold` (7 tests) holds a blind-after-near cell at 0.1 m; `lanes {head_blind, torso_blind, held}` evidence
- [x] Merged onto the teammate's Step 45 cloud commit; 605 / 605 tests; installed on the phone
- [ ] On the phone: wall at 15 cm → push to the wall → STOP + urgent buzz stays; step back → clear; night sky / long corridor → no STOP
- [ ] Tune `NearHoldConfig` (0.5 blind share, 0.6 m arm, cold start 4 cells / 0.8 / 0.8 m) from the `lanes` records of that walk
- [ ] Known gap (Codex): a glossy / absorptive surface at 0.35 m–a few metres returns finite *low-confidence* samples — neither valid nor blind — so the cell can read CLEAR; needs an "unknown" tile state, not a guess (Step 38 boundary)
- [ ] Known gap: toggling "Mirror left / right" mid-session swaps lane indices under the hold's per-lane memory; the next sweep disarms it

## Step 47 — Dynamic Island redesign from its first pictures, Guide tile pair, privacy-safe Medical ID (Sat Sep 12, evening)
- [x] Evidence first: the newest phone logs say `live_activity {action: start, active: true}` — the activity exists; nobody had ever seen what it drew
- [x] `CaneKitIslandTour` + `make island`: compact, expanded, walking, after-Stop pictures of the island from the simulator (before and after)
- [x] `NavLiveActivity.swift` redesigned: manoeuvre glyphs that cannot be mistaken for the OS location arrow (`arrow.up` retired), glance glyph-only when clear, instruction full-width in the expanded bottom region, stale state ("No update"), one VoiceOver sentence per presentation
- [x] `LiveActivityCoalescer.staleAfter` (300 s, `staleAfterOutlivesACrossingWait`) → `staleDate` on every request / update
- [x] `LocationService.setNavigating`: `showsBackgroundLocationIndicator` pinned false; the blue pill during a route is the OS's background-location indicator (design.md §6.7 says so)
- [x] `CKBigButton.Layout.tile` for the two-up "Where am I" / "Talk to OpenCane" pair (equal shapes and heights); row label made flexible so "Simulate walk" no longer stacks alone
- [x] Medical ID: the default profile is privacy-safe (no seeded identity, date of birth, address or phone); older seeded 555 placeholders are cleared. A walker/helper enters real values locally, and cloud mirroring is a separate explicit opt-in (Step 51).
- [x] Cue levels differ on the cane (cue-v2 #41, implementation agent): `TorsoHapticPolicy` + 21 tests; Quiet no torso taps, Standard onset tap (< 1.5 m closing) + strong triple (< 0.6 m, proximity only after Muse), Detailed today minus shoreline re-taps, Indoors / crossing settle hold; Settings caption tells the truth
- [x] Details tab "Scene engine" card (implementation agent): who answered the last Where am I, why, how long, when, from what; hazard-watch plan / last check / failure; cues in effect; `SceneEngineSummary` + 17 tests; `describe_result` / `hazard_watch` carry `trigger` / `source` / `cloud_ms` / `fallback_reason`
- [x] "Announce Medical ID" moved from `.obstacle` to `.scene` (design audit)
- [x] Reviews: Muse + OpenCode (8 fixed, 5 rejected with evidence in CHANGELOG); Codex rerun read-only on a copy after it built in the real repo; Antigravity cannot run headless without auto-approving commands
- [x] Doc drift audit (3 read-only agents) → AGENTS.md, CLAUDE.md, ios/README.md, CODE_REFERENCE.md (~30 sections added), design.md (§6 four tabs, §6.5 Family alerts, §6.8 Profile, §5.1 six lines), todo.md, TEAM_HANDOFF.md, docs/README.md, handsfree.md, devices_setup.md
- [x] docs: design.md §6.7 rewritten, §10 raw-kind gap closed, CODE_REFERENCE, AGENTS.md `make island` + two new traps (no concurrent builders; `--disable-xctest`)
- [x] Second round from the phone pictures: Always location at route start (no blue pill → the Live Activity owns the island like Apple / Google Maps), background session only without Always, `location_auth` log; expanded row de-cramped (route name off the island, pill priority, 3-line instruction) + route progress bar
- [ ] Pre-existing (Codex round 2): a Detailed centre Geiger loop that loses haptics mid-approach (engine down, Silence haptics) sends no wrist / speech fallback until the next decider fire — `.updateCenter` has been haptics-only since Step 3
- [ ] On the phone: first route start → answer **Always** to the location prompt; lock → island shows walking figure + metres and one green check (no blue arrow in the pill); long-press → instruction in full; Profile shows the locally entered Medical ID (blank-safe on a fresh install); Settings → Cues → Standard, walk at a wall: one tap at 1.5 m, strong triple at 0.6 m, no side taps; Quiet: nothing but head height; Details → Scene engine after one Where am I with and without network

## Cross-cutting
- [x] Four icon-only root tabs (Guide / Sense / Settings / Profile; Profile added in Step 44) — `CKTabBar`, VoiceOver labels pinned, XCUITests open the matching tab including Profile and assert its metric tile
- [x] UI design system (docs/design.md, Theme.swift, WatchTheme.swift) applied to grid + root screen
- [x] route_isr_cif.json with OSM-verified coordinates (docs/route_isr_cif.md); re-record Friday on foot
- [x] TripLogger JSONL (Documents folder; AirDrop from Files)
- [x] Simulator build + run on the iOS 27 simulator (now the iPhone 17 Pro Max, the demo phone) — UI verified by screenshot
- [ ] Go/no-go checklist rehearsed before any blindfolded walk
- [ ] Open (not fixed, from the review's unverified list): accidental taps on the clamped screen (Mirror and other
      toggles remain unprotected; phone Stop now requires two taps), the screen-lock safety trade-off (the app now speaks that obstacle warnings are paused, but the ARKit
      path still requires Guided Access + keeping the screen on for a blindfolded walk), compass readings dropped while
      iOS wants calibration (heading is nil until walking > 0.7 m/s), VoiceOver double-speak on frequently-updating
      pills, MapKit route build waits only 15 s for a first fix

## Cue design v2 — items cue-v2 #35–#45 (approved 2026-09-12 evening; talk floor inserted as #37 the same night, later items renumbered +1 — CHANGELOG entries before Step 37 use the old numbers)

⚠ **Numbering.** The item numbers below are the *plan's* numbers, prefixed `cue-v2 #`. They are
**not** CHANGELOG step numbers: CHANGELOG Steps 38–46 are a separate stream of shipped work (38
point-blank wall safety, 39 Grok Bot webhook, 40 Dynamic Island, 41 hazard telemetry, 42 GPS
fallback, 43 falls / weapons, 44 Medical ID Profile tab, 45 Supabase, 46 review fixes) that reused
the same digits. Only #35, #36 and #37 coincide with CHANGELOG Steps 35–37; cue-v2 #41 (torso
haptics) shipped in CHANGELOG **Step 47**. When one of the open items ships, it gets whatever
CHANGELOG step number is next, and the tick here names it.

Research: `docs/cue_design_v2.md` (74 source-checked findings + the field-log addendum). Owner chose
"Full v2", default level **Detailed = today** until a *mounted* trip log tunes the numbers; speech
calming ships on; every new haptic behaviour ships behind a level or a setting that defaults to today.
Plan reviewed by Muse (17 findings, folded in: cell validity before the overhang signature, still =
net displacement not path length, dropped lines stay available to Repeat, ground hazards pinned to
`.safety`, indoor overrides, door names only on a route, steps split, AirPods-stem hush deferred).
Safety floor for every step: head haptic at every onset; "Head height." spoken at a moving onset;
ground hazards (when on) speak their first confirmation; hush never touches any of them.

- [x] **cue-v2 #35** (= CHANGELOG Step 35) `scripts/cue_audit.py` + `make audit` — mounted?, head band wall vs overhang, cues and lines per minute, replays
- [x] **cue-v2 #36** (= CHANGELOG Step 36) `CueProfile` / `CueRules`: Quiet / Standard / Detailed × Outdoors / Indoors; Settings pickers, change spoken once; names default off; door names only on a route in Standard; Detailed's one delta from today: never names walls; indoor overrides (no torso taps, no names, beacon only routing, safety signs only, head 1.2 / 0.8 m)
- [x] **cue-v2 #37** (= CHANGELOG Step 37) Talk floor (owner: "directions and obstacle alerts interrupt each other"): a line cut by a warning resumes from its clause (`SpeechResume`), 0.35 s pause between bands, `speech_end` + `resume_from` logged, `cue_audit` resume / pause metrics. Rejected before building (Muse): holding "Head height." behind a direction (a walker reaches a 1.5 m overhang before the words)
  - [ ] Device: route intro cut by a head cue resumes mid-line in both voices; tune `mp3MarginUTF16` / `clipLead` from `resume_from`
  - [x] Later review: interruption resume retries are generation-fenced and cancelled by a newer `.began`; cached-mp3 resume still uses the measured proportional `SpeechResume.clipTime` approximation and remains a device-tuning item.
- [ ] **cue-v2 #38** (not CHANGELOG Step 38, which is point-blank wall safety) Head speech episode: ends after 2 s of trusted clear frames; no new head speech while still (`MotionState`: net horizontal displacement < 0.3 m in 2 s of a low-passed camera position, so a cane swinging ±0.5 m in place never reads as walking — `swingingInPlaceCountsAsStill`, `vigorousScanAtACurbIsStill`)
- [ ] **cue-v2 #39** Speech de-chop: interrupted `.obstacle` / `.scene` dropped (kept for Repeat), late optional lines dropped (> 1.5 s), cue tier always the system voice, rate follows the user's Spoken Content setting
- [ ] **cue-v2 #40** Speech budget: unsolicited non-safety lines ≥ 8 s apart, none while still or at a crossing; ground hazards pinned to `.safety`; beacon silent when still > 3 s
- [x] **cue-v2 #41** (shipped as CHANGELOG Step 47) Torso haptics by level: Standard onset taps (1.5 m closing, 0.6 m strong triple), Detailed = today + shoreline suppression, Quiet none; no torso taps during a crossing settle — `TorsoHapticPolicy` (CaneKitLogic, 19 tests + `defaultRulesRenderTodaysHaptics`) over an untouched `CueDecider`; `HapticPlayer.playCenterOnset`; `cue` log gains `suppressed` / `render`, `cue_audit` counts them; Settings caption now true per level
  - [ ] Device: feel the Standard onset tap and the strong triple on the cane (the triple shares the right lane's 3-tap count — Standard has no side taps, but confirm it is not mistaken for "right" on the shaft); walk a hedge in Detailed and confirm the shoreline hush; stand at a crossing and confirm no torso taps
- [~] **cue-v2 #42** (mostly shipped as CHANGELOG Steps 51–52, **ON by default** — owner decision 2026-09-13; rig test still owed) "Calm head alerts (test on the cane first)", default off: per-cell sample validity in `LaneMath`, overhang signature (torso ≥ head + 0.5 m or no data), band re-fire (1.0 / 0.6 m), speech closing gate, same-overhang dedup; hanging-sign rig test 10/10 before it can default on
- [ ] **cue-v2 #43** Hush: Watch double tap + app button + Siri, 60 s, non-safety speech and non-head haptics only, soft buzz on, "Cues back." off
- [ ] **cue-v2 #44** "What's ahead?": LiDAR lanes + ARKit mesh class + ground hazard, no vision model; ≤ 3 items (≤ 5 Detailed), nearest first, doors / drop-offs before furniture
- [ ] **cue-v2 #45** Indoor suggestion after 20 s of GPS accuracy > 30 m, once per 10 min, never switches by itself
- Deferred (not scheduled): ~~gravity-corrected metric head band~~ (shipped, Step 51); speed-scaled head distance; route distance updates every 15 m; in-app speech-rate override; AirPods stem-press hush (would take Now Playing from music).

## Step 64 — Cloud docs match the MVP (Sun Sep 13)

- [x] Profile caption, AppModel comments, AGENTS.md / README / design.md / CODE_REFERENCE no longer promise settings, mobility or trip-log uploads

## Step 63 — Audit of Step 61 (Sun Sep 13)

- [x] Persist the refused-key latch (`NaturalVoiceLatch`) so a restart with a warm cache is one voice
- [x] A later prefetch must not wipe the Haptics-card 401
- [x] Lock cancels `SceneDescriber` (same reason as `conversation.cancelForBackground`)
- [ ] Device: quit + relaunch on the empty account — every line Apple's; lock mid "Where am I"

## Voice-first cane — Steps 51–61 (plan `glittery-floating-tiger`, 2026-09-13)

- [x] **Step 56** IVR grammar on the phone: `VoiceMenu` (8 words + digits, whole utterance, help / menu lines, yes / no, next / standard / detailed), classifier rule 0, `ConversationAction` voice-shell cases, rule 12 before rule 8, `SpokenPhrases.shellLines` + completeness test, `StatusSummary.fixedLines`
- [x] **Step 57** `ConversationBudget` + coordinator latest-wins (filler 1.5 s, timeout 4 s, stale results silent, `conv_turn` budget fields)
- [x] **Step 58 (part 1)** `VoiceTile` giant microphone + compact row; `VoiceShellPolicy` / `ScenePhaseReason` pure; `UtteranceEndDetector(maxListen:)`; `scrollTo` in the three UI suites
- [x] **Step 59 (part 1)** `EmergencyConfirm` + coordinator (prompt, 8 s window, yes → flush + `tel:`), `ProfilePage` uses `telDigits`
- [ ] Part 2 (AppModel): `commonLines` += `SpokenPhrases.shellLines` (drop the first pass's two literal shell lines); delete the "Still working on your last question." branch; speak `VoiceMenu.menuLine` after "OpenCane ready." + `VoiceShellPolicy.launchListen`; follow-up window (`followUp`, `awaitingEmergencyAnswer`); prefetch `EmergencyConfirm.promptLine` at launch and on profile save; Settings toggles; `scene_phase` logging
- [ ] `VoiceInputEngine` / `SceneDescriber`: speak `SpokenPhrases.notHeardLine` / `describerBusyLine` instead of their literals
- [ ] Gate: `make test` (once the head-cue conversion compiles), `make uitest` with `scrollTo`, `make tour` pictures of the tile, `make e2e`
- [ ] Device: "help", "four", "emergency" → "no", an open question under 4 s, the rings respond to the finger anywhere on them

## Steps 53–55 — one voice, no self-hear (Sun Sep 13; plan `glittery-floating-tiger.md`)

- [x] Step 51: metric lane bands — `LaneGeometry` (world-up row, cm: camera 95, floor < 25, head ≥ 140, cover 150), `LaneGrid.headCoverage` / `torsoCoverage` / `bandMode` (no cover = `.infinity` + flag), `DepthFrameProcessor` geometry, `TileLevel.noCover` + NO COVER tile, `MountTilt.status(downDeg:headCover:)` + `headCoverLimitDeg` (≈ 19°), `NearHold` covered cold start, `HeadCoverNotice` route-start line, `lanes {bands, head_cover, torso_cover}` + `depth_geometry`, `cue_audit.py head_cover` / `could_not_be_head`; `LaneGeometryTests` (16)
- [x] Step 52: `HeadGate` overhang signature (ON; `Settings.bool("overhangSignature")` valve), head episode in `CueDecider` (onset at once, 1.0 / 0.6 m bands ≥ 1.5 s apart, 2 s after a trusted clear, a sweep freezes the clock; quiet episode lets the centre cue play — review 2026-09-13), `HapticCue.head(distance:onset:)`, `CueSpeechPolicy` onset + once under 0.6 m (no `cleared()`), `cue {distance, onset}`, island + describer through the gate, `cue_audit.py head_gate_replay`
- [ ] Steps 51–52 on the phone: T3 (floor at 5° and 45°: no Geiger; Mount card + NO COVER at 45°), T4 at ≤ 15° (board at 1.7 m: one onset tap + line, ≤ 2 band taps, silence standing under it, wall → no "Head height."), `make audit --pull`: `bands: metric` on every `lanes`, `share_head_cover` ≈ 1 when re-angled; check `depth_geometry.up` orientation (portrait `upX` ≈ −cos θ)
- [ ] Not done in 51–52: camera height calibrated from the ground plane (constant 95 cm); side-lane head threshold; onset closing gate / same-overhang dedup / standing-still rule (cue_design_v2 §3.2); ground detector at steep tilt (still 0–15°)
- [x] Step 53: `VoiceEngineChoice` decided before `onDispatch`; `speech_dispatch {engine, engine_reason}`; `speech_engine` on race resolution; `AppModel.naturalVoiceEnabled` persisted; Settings "Voice" card; `cue_audit.py` engine flips (whole walk / inside route speech)
- [x] Step 54: `immediate:` removed everywhere; session-sticky `VoiceBreaker` (`voice_breaker`); additive prefetch (`VoicePrefetch.merge`, one worker); `WalkingIntro.routeStarted` shared by `NavigationEngine.start` and the route-start prefetch; safety lines first at launch; `StatusSummary` voice clause; Scene engine "Voice" row
- [x] Step 55: hold before the mic lease; `SpeechBufferBox` `Mutex<Bool>` pause + 0.3 s tail via `onSpeakingChanged`; `SelfHearFilter` on the final transcript; `voice_self_hear`
  - [ ] Device: warm-up to "Natural voice ready." on venue Wi-Fi (time it); `make audit` engine flips inside route speech = 0 on a mounted walk
  - [ ] Device: Wi-Fi off mid-walk → one flip, breaker open; Wi-Fi back → closes within ~60 s
  - [ ] Device: "Head height." during dictation never becomes the query (`voice_self_hear`); tune `SelfHearFilter.window` / `tailSeconds` from `pause_ms`
  - [ ] Later: cap `prefetchBacklog` if a long outage with many novel answers ever makes it large (unbounded today, grows only by lines actually spoken)
  - [ ] Later: character budget — novel answers and status clauses now consume ElevenLabs characters (10,000 / month free tier); watch the account

## Step 62 — indoor → outdoor (Sun Sep 13; owner decision: step script + handover, recording mode, ISR floor-plan draft)

- [x] Logic: `IndoorRoute.swift` — `IndoorScript` / `IndoorStep` / `IndoorTurn` / `IndoorExit` schema + `load` + `validate` (aliases, steps, counts > 0, say ≤ 140, radius 10–60)
- [x] Logic: `IndoorProgress` — draft caveat, advance at ceil(0.85·n) on nominal boundaries, landmark once at 0.7·n, `next()`, never backwards, nothing after the exit, a jump ≤ 2 lines
- [x] Logic: `IndoorHandover` — 3 consecutive fixes ≤ 15 m within the radius after the exit; `forced(now:)` at once with a fix ≤ 30 m within the exit radius in 20 s (review round: was 60 m), else the first fix ≤ 20 m within the radius; GPS-only 3 × ≤ 10 m within 15 m (review round)
- [x] Logic: `IndoorRecorder` — turn = |Δyaw| ≥ 60° held 1.5 s, ≥ 150° around, landmarks attach, generated says, stride from a measured distance
- [x] Logic: `FastPathIntentClassifier` rule 13b "from A to B" → `.routeFromTo(from:to:)` ("from here" stays `.startRoute`), rule 1b "I'm outside" → `.indoorOutside`; coordinator placeholder cases
- [x] Logic: `CampusPlaces` ISR alias "Townsend Hall doors" — every place name round-trips through `match`
- [x] Tests: `IndoorRouteTests` + `ConversationLogicTests` (3) + `CampusPlacesTests` (1); `swift test` green
- [x] Data: `ios/CaneKit/Resources/indoor_isr.json` floor-plan draft (`walked: false`, exit = route WP1, radius 25)
- [x] App: `IndoorGuide` (CMPedometer → `IndoorProgress`, LocationService → `IndoorHandover`, `.nav` ttl 20, `indoor {action, index, steps, walked}` logs, handover → `startDemoRoute` via `beginRoute`), next / repeat / Stop route / status clause, Guide card "Indoors · step N of M"
- [x] App: `ConversationCoordinator` `.routeFromTo` / `.indoorOutside` wired; `CANEKIT_INDOOR_SIM_STEPS_PER_S` hook
- [x] App: Settings "Record indoor route" card (Start, Add landmark, Finish at the exit, Save → Documents/indoor/<id>.json)
- [x] Logic for the app half: `IndoorScriptCatalog`, `IndoorExitAverager`, `IndoorStatus`, `IndoorYawUnwrapper`, `IndoorSimSteps`, `StatusFacts.indoorClause` (11 tests, written first)
- [x] CHANGELOG Step 62 entry; CODE_REFERENCE, handsfree.md §1c, design.md §6.1 / §6.5
- [ ] Gate: `make test sim uitest e2e`; reviews (multi-agent + Muse + Antigravity)
- [ ] Device: record the real lab → front doors with a sighted teammate; walk it with the cane; handover at the ISR doors
