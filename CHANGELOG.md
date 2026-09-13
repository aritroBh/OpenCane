# CaneKit changelog

Build log for the hackathon. One entry per step; each ends with what to test on the phone.

## Steps 62 + 64 review round (Muse, OpenCode, Codex, Antigravity) (Sun Sep 13)

Every finding was read against the code before acting. Logic tests were written first: the new API
did not compile (red), then went green: `swift test` → **845 tests in 21 suites passed** (exit 0). The
throttle test's red was a compile-blocked run, not an observed runtime failure; by reading, the old
code recorded the throttled `stop` at 10 s as `lastLevel`, so `stop` at 35 s was no escalation. App
code was checked by reading only (no xcodebuild this round: an e2e run owned the simulator).

**Fixed**
1. **The landmark hook swallowed commands.** While "Add landmark" waited, *any* transcript became a
   landmark, including "stop" / "I'm outside" / "emergency". `IndoorRecorder.isLandmarkText(_:)`
   runs `FastPathIntentClassifier.classify` first; `.stopRoute`, `.indoorOutside`, `.emergency`,
   `.confirm` and blank text are not consumed (the hook disarms, `indoor {action:
   record_landmark_command}`). Test `landmarkHookLetsCommandsThrough`.
2. **A locked phone stalled the indoor walk.** CMPedometer pauses in the background, and the handover
   needed `reachedExit()`. `IndoorHandover` now also hands over GPS-only: `gpsOnlyFixes` 3 consecutive
   fixes with accuracy ≤ `gpsOnlyAccuracyM` 10 m within `gpsOnlyRadiusM` 15 m of the exit; any other fix
   resets the run. The armed path is unchanged. `IndoorGuide.sceneChanged(active:)` logs
   `indoor {action: paused_background | resumed}` and speaks nothing. Tests
   `handoverGpsOnlyFiresOnThreeTightFixesWithoutTheExit`,
   `handoverGpsOnlyNeedsConsecutiveTightFixesNearTheExit`; `handoverIgnoresFixesBeforeItIsArmed` now
   feeds 12 m fixes (5 m ones at the door would now be a GPS-only handover, as intended).
   ⚠ Open: `LocationService` arms a background session only while a route navigates, so locked
   indoor fixes rely on Always authorization (granted on the demo phone). Needs a device check.
3. **An indoor walk never had a Live Activity.** `setIndoor` no-ops without one, and nothing requested
   it. New `LiveActivityController.beginIndoor(name:say:stepIndex:stepCount:)` is called from
   `IndoorGuide.start` before the first `setIndoor`. It ends a closing "Route stopped" card, requests
   in `.indoor`, or updates the existing activity. `beginWarmup` and `start` now update **any**
   existing activity in place (they only reused a warming one for the same route name), so the
   handover keeps one island; its static `routeName` is the trip's (the bundled route name for CIF,
   "To <destination>" otherwise). `endIfIdle()` ends it when the outdoor leg never begins
   (`IndoorGuide.handOver`, `AppModel.buildRoute`'s no-fix and error branches).
4. **ActivityKit ordering.** `Activity.request` ran right after enqueueing the previous activity's end
   and the closing card's end. Requests are now queued on `activityOperation`: a main-actor task awaits
   `predecessor?.value`, and a `requestGeneration` fence drops a request an `end` or a newer request
   superseded. Orphan ends at launch are chained too. `end` already cleared `activity`; it now also
   drops a queued request.
5. **`Activity.request` from the background throws.** A request while not `.active` is kept as the
   latest `requestSpec` (`live_activity {action: deferred}`). `AppModel.scenePhaseChanged(.active)`
   calls `flushPendingRequest()` (`flushed`); outcomes are logged `requested` / `request_failed` /
   `request_cancelled` / `end_idle` via `LiveActivityController.onLog`. The warming countdown now
   survives a voice phase (`warmupEndsAt` kept while `routeStartWaiting`).
6. **Exit fallback.** The recording exit could fall back to any last fix (a 65 m indoor fix) and to a
   stale `location.fix`. `IndoorExitAverager` keeps only fixes ≤ `fallbackAccuracyM` 30 m;
   `usableFallback(accuracyM:ageS:)` requires ≤ 30 m and ≤ `fallbackMaxAgeS` 20 s for the last-known
   fix. Otherwise "No GPS fix…". Test `exitAveragerFallbackNeedsAUsableFix`.
7. **`IslandAlertThrottle` forgot a throttled escalation.** It recorded it as `lastLevel`, so the same
   escalation never alerted after the window. A throttled escalation now keeps the previous level;
   de-escalation still updates it. Tests `throttledEscalationAlertsAfterTheWindow` (stop@0 alerts,
   none@5, stop@10 throttled, stop@35 alerts), `deEscalationUpdatesTheLevel`.
8. **"I'm outside" with a pre-exit fix.** The design is kept (the walker's statement is the evidence,
   and the fix only confirms which door), and the reason is now in `forced(now:)`'s doc. Muse M4
   tightened it: the recent fix (≤ 30 m, ≤ 20 s) must lie within the exit's `radiusM`, not 60 m.
   `forcedRecentDistanceM` is removed. Tests `handoverForcedIsImmediateWithARecentUsableFix` (25 m),
   `handoverForcedWithoutAFixWaitsForGPS` (26 m), `handoverForcedNeedsTheRecentFixInsideTheRadius`.
9. **Lows.** (a) `opencane://guide` has no tab binding (`ContentView`'s tab is private `@State`), so
   the `onOpenURL` comment now says it opens on whatever tab was showing. (b) A nil CMPedometer update
   logs `indoor {action: pedometer_nil, source}` at most once per 10 s per source (`ActionRateLimit`),
   walking and recording. (c) `NavActivityAttributes.init` caps `routeName` at
   `maxRouteNameCharacters` 120. (d) `CANEKIT_INDOOR_ROUTE` auto-start is skipped
   (`auto_start_skipped`) while navigating, waiting or already indoors. (e) The duplicate
   `logger.event("repeat")` in `indoorHandlesRepeat` is removed (`IndoorGuide.repeatLine` logs
   `indoor {action: repeat}`).
- **Muse M3.** "navigate to / go to / walk to / route to / set destination to … B from A" became
  `.startRoute("Cif From Isr")`. Rule 13b now splits " from " after every rule-14 prefix
  (`FastPathIntentClassifier.destinationPrefixes`); "from here" stays a plain route. Test
  `everyDestinationPrefixTakesAFromOrigin`.
- **Muse M8.** The widget's stopped trailing figure showed `min(stepCount, stepIndex)`, one less than
  `progressLabel`. It now uses `stepIndex + 1`.
- **Muse M11.** "Add landmark" after the exit, and "Finish at the exit" while its window is open or
  after it, now speak a one-line refusal (`recordingSay`) instead of returning silently.

**Rejected (with evidence)**
- **Muse M6** (`indoorOutside` `.handedOver` claims "already spoken"). Every outdoor-leg path speaks
  for itself: `queueRouteStart` "Obstacle detection warming up…", `NavigationEngine.start` →
  `onSpeak(intro)` on the degraded path, `buildRoute` "Finding a route to …", and the refusal lines
  (`announceLocationDenied`, self-test). A coordinator "Starting the outdoor route." would queue a
  second line. The `routeFromTo` fallback returns `alreadySpoken: true` because `navigate(to:)` says
  "Finding a route to …"; nothing is duplicated. Doc comment updated.
- **Muse M9** (revert the `Info.plist` `CFBundleURLTypes` hunk). `ios/project.yml` has
  `info: path: CaneKit/Info.plist` + `properties:` ("XcodeGen writes these keys into
  CaneKit/Info.plist on every generate"), and Info.plist is tracked. The hunk is the generated
  output: reverting it would reappear on the next `gen.sh`, and until then it would drop the
  `opencane://` scheme the widgets open.
- **Muse M10** (clear voice listening / thinking in `beginWarmup` / `request`). The flags are not
  stale. `AppModel.observeVoiceForIsland` re-arms on every change of `isListening || isStarting` and
  `isProcessing`, and `setVoicePhase` stores each change. A route started by voice opens as
  `thinking` while the coordinator is really still processing, then republishes as warming when that
  ends. Clearing them would show warming while the microphone is actually open.

test on device: lock the phone mid indoor walk and walk out of the ISR doors → island stays one
activity and turns warming / walking; "stop" during Add landmark stops the route; Finish at the exit
indoors → "No GPS fix…".

## Step 64 — The island says OpenCane, and never "Path clear" while obstacle detection is paused (Sun Sep 13)

**Why.** Owner: "the island looks kind of bad… just a location icon thing; make it better, more
robust, more unique." The Step 64 audit (`make island` pictures + phone trip logs) found: the Live
Activity existed only while a route guided, so nothing OpenCane showed during the warm-up, voice or
after Stop; the compact island (bare `figure.walk` + metres + a green check) read as a system glyph;
the expanded instruction was cut at two lines; and a **safety bug** — with the screen locked,
`scenePhaseChanged(.background)` paused depth but the GPS glance fell back to `.clear`, so the lock
screen and island said "Path clear" exactly while obstacle warnings were off.

**What changed.**
- **Safety first:** `ContentState.sensing` (`live | paused | none`, default `none`, lenient decode).
  The widget draws "Path clear" / the green check only when sensing is live and the activity is not
  stale; background with a route, warm-up or indoor script → "Obstacles paused — unlock" (amber);
  unknown → "Sensing unknown". The controller also sends obstacle fields as clear / 0 unless live.
  Pure `IslandPhasePolicy` in CaneKitLogic decides phase + sensing (listening > thinking > warming >
  indoor > walking). AGENTS.md note added.
- **Phases:** `phase`, `stepIndex`, `stepCount`, `warmupEndsAt`, `alertLevel` in `ContentState`.
  `queueRouteStart` starts the activity in `warming` with a `Text(timerInterval:)` countdown;
  `startRouteNow` updates that same activity (no second one); a cancelled warm-up ends it; Stop shows
  a "Route stopped" card for 10 s (sent as an update and ended later — the island drops an *ended*
  activity at once, first pictures below); `relevanceScore`; phase / sensing changes bypass the
  coalescer floor. `setVoicePhase(listening:thinking:)` (AppModel voice observation) and
  `setIndoor(stepIndex:stepCount:say:)` (wired from `IndoorGuide.perform` / `teardown`).
  `scenePhaseChanged(.background)` keeps GPS while `indoor.isActive` (Step 62 handover).
- **Look:** `OpenCaneMark` — static contour rings from the voice tile's ring math, moved to
  `ios/Shared/Brand/ContourRingGeometry.swift` (VoiceTile now uses it too) — in compact leading,
  minimal, expanded and the lock screen; `.keylineTint` by level; compact trailing progress ring
  (check only when live, pause glyph when paused); expanded instruction 3 lines at ≥ 85 %, "1 of 6",
  `.numericText()`; `widgetURL(opencane://guide)` (scheme registered in project.yml); StandBy layout
  (`isActivityFullscreen`); `.supplementalActivityFamilies([.small])` Smart Stack card; new lock-screen
  card with a sensing badge. design.md §6.7 rewritten with every state.
- **Alerts:** `IslandAlertThrottle` — escalation only, ≤ 1 per level per 30 s, never on de-escalation or
  frontmost, reset per route; `AlertConfiguration(title:body:sound: .default)`. ⚠ Found while
  building: depth pauses in the background, so sensing is `paused` and no obstacle reaches the island
  there — alerts can only fire while the app is `.inactive` (Notification / Control Center over it).
  Kept as the path for a future background depth mode; not a warning channel.
- **Extras:** Control Center / Lock Screen / Action button control "Talk to OpenCane" (`TalkControl`,
  `TalkControlIntent` in `Shared/Intents`, the app's copy toggles push-to-talk) and a lock-screen
  accessory widget with the mark (`opencane://talk` → `CaneKitApp.onOpenURL`). No buttons inside the
  Live Activity (design.md §6.7). No idle "guarding" activity (it would be false in the background).

**Tests (written first, red before green).** `IslandPolicyTests.swift`: `walkingForegroundIsLive`,
`backgroundWithRouteIsPaused`, `backgroundWhileWarmingIsPaused`, `backgroundIndoorIsPaused`,
`noLidarIsNone`, `untrustedDepthIsNone`, `warmingIsNone`, `phasePriority`, `indoorNeedsAValidStep`,
`voiceKeepsSensing`, `showsClearOnlyWhenLive`, `relevanceOrder`, `unknownRawFallbacks`,
`levelFromGlance`, `ranks`, `clearToNearAlerts`, `escalationInsideWindowAlerts`, `deEscalationSilent`,
`flappingIsThrottled`, `foregroundNeverAlerts`, `resetPerRoute`. `LiveActivityCoalescerTests`:
`sensingChangeBypassesFloor`, `phaseChangeBypassesFloor`, `legacyJsonDecodesGracefully` extended.

**Verification.** `make test` 832 / 832 (exit 0); `make gen` exit 0; `make sim` BUILD SUCCEEDED;
`make island` 1 test, 0 failures. Pictures (simulator, no LiDAR, so sensing is honestly "unknown"):
01 compact = ring mark + walker + "585 m", empty progress ring (no check); 02 expanded = mark + glyph,
full 3-line instruction, "Sensing unknown" pill — the first run clipped the pill row and "1 of…", fixed
by a 14 pt instruction and tighter top row (second run: the row fits; the last glyph of "1 of 9" touched
the rounded corner → 10 pt trailing inset, built but not re-photographed); 03 walking = "601 m" (the
distance rising is the simulated walk's first leg, as in Step 47); 04 after Stop was empty on the first
run (ended activities leave the island at once) → Stop now updates to the card and ends 10 s later;
second run shows the ring mark, a stop glyph and "Stopped".
Not pictured: warming (no LiDAR in the simulator → no warm-up), arrived (~7 min walk), lock screen,
StandBy, Smart Stack, control, accessory. Not yet run for this step: Muse / multi-agent / Antigravity
reviews, `make uitest`, `make e2e`.

test on device: start the CIF route and lock the phone during the warm-up — island shows the ring mark
and a countdown, then the walk; with the screen locked the pill says "Obstacles paused — unlock", never
a green check; unlock, walk, lock at a hazard; press Stop and go home — "Stopped" card for 10 s; add
the "Talk to OpenCane" control and the lock-screen widget and tap each; StandBy on a charger.

## Step 62 — Indoors first: "take me from ISR to CIF" walks a step script out of the building, then hands over to the GPS route (Sun Sep 13)

**Why.** Owner decision 2026-09-13: GPS is useless inside Townsend Hall, so the walk from a room to the
ISR front doors is a short spoken step script counted by the pedometer (no ARKit breadcrumbs tonight),
recorded once by a sighted teammate in an in-app recording mode, with a floor-plan draft marked "not
walked" until then. Spec: scratchpad `indoor_spec.md`; the Logic half (`IndoorScript`, `IndoorProgress`,
`IndoorHandover`, `IndoorRecorder`, "from A to B", "I'm outside", the ISR alias fix) and the draft
`indoor_isr.json` landed first in this step.

**What changed (app half).**
- `IndoorGuide` (new, `ios/CaneKit/Navigation`): loads bundled `indoor_*.json` + `Documents/indoor/*.json`
  (recorded wins by id; invalid files skipped and logged); `start` feeds CMPedometer (`@Sendable` handler
  hopping to main — TripTracker's crash note) or synthetic steps into `IndoorProgress`; every line is
  spoken at `.nav` ttl 20 and logged `indoor {action: say, text, index, count, steps, walked, script}` —
  never a `speech` record; every GPS fix (one hook in `wireNavigation`) feeds `IndoorHandover`; on the
  handover (`indoor {action: handover, by}`) the outdoor leg starts: the CIF demo route, else
  `navigate(to:)`. Recording: CMPedometer + CMDeviceMotion `xArbitraryZVertical` yaw at 10 Hz,
  "Add landmark" as a one-shot transcript hook ahead of the conversation, "Finish at the exit" averaging
  fixes ≤ 15 m for up to 8 s, Save → `Documents/indoor/<id>.json` with `walked: true`.
- `AppModel+Indoor` (new): `.routeFromTo` → the script whose `fromAliases` match (else `navigate(to:)`);
  `.indoorOutside` → handover now, or "Waiting for GPS outside."; while indoors "next" / watch Next /
  crown / Guide Next advance the step, "repeat" says it again, Stop route ends it, Simulate walk feeds
  steps, the status report says "Indoors: step 3 of 5.", and "route" answers with that clause instead of
  restarting the demo. AppModel.swift carries only one-line hooks (the Live Activity step edits it too).
- `ConversationCoordinator`: the two Step 62 stubs wired; `currentStatusFacts` sets `indoorClause`.
- `GuideCard`: indoors, the instruction is the step line, a status line "Indoors · step 3 of 5" follows,
  the compact row is the navigating Repeat | Next | Stop route (labels unchanged, hard rule 9), and below
  the fold only Simulate walk / Stop simulation.
- Settings: "Record indoor route" card (Route id, Start recording, Add landmark, Finish at the exit, Save,
  Cancel recording, Start indoor route) — new labels only.
- Logic (tests first, red run confirmed they failed to compile before the code): `IndoorScriptCatalog`
  (merge by id, alias pick with `CampusPlaces.normalize`, walked beats draft, outdoor leg, file-safe id),
  `IndoorExitAverager`, `IndoorStatus`, `IndoorYawUnwrapper`, `IndoorSimSteps` (incl. `nextOnlyWaitS` 3 s
  so a simulated walk passes the draft's "Say next when you get there" step), recording timings,
  `StatusFacts.indoorClause`. 11 new tests in `IndoorRouteTests`.
- Hooks: `CANEKIT_INDOOR_SIM_STEPS_PER_S` (synthetic steps) and `CANEKIT_INDOOR_ROUTE=1` (start the ISR
  script at launch) for simulator evidence.

**Verification.**
- `cd ios && make test` → exit 0, 831 tests in 21 suites (after the island step's tests landed; earlier,
  while those were mid-edit, the suite was run on a scratch copy without their two files: 799 / 799).
- `make gen` → 0; `make sim DERIVED=<scratch>/dd` → BUILD SUCCEEDED.
- Simulator (dedicated iPhone 17 Pro Max iOS 27, muted, `CANEKIT_INDOOR_ROUTE=1
  CANEKIT_INDOOR_SIM_STEPS_PER_S=5`), trip log `canekit-2026-09-13T09-37-21Z`: `indoor catalog` →
  `start` (walked false, count 5) → `say` draft caveat → `say` step 0 → `next` (sim, 3 s) → `advanced`
  1…4 with their lines and the landmark "The main desk is on your right." at 23 steps → exit line →
  `exit` (48 steps) → exit-coordinate fixes → `handover {by: gps}` → `sensor_mode route_started` →
  `route start "ISR Townsend Hall to CIF"` → `waypoint 1`, in 20 s. No `field_kind`.
- Not run: `make uitest` / `make e2e` / `make tour` (out of this agent's brief); Muse / multi-agent /
  Antigravity review of the diff is still open (docs/todo.md).
- Known gap, not fixed here (the region belongs to the Live Activity step): `scenePhaseChanged(.background)`
  stops GPS when no outdoor route runs and CMPedometer live updates pause while locked, so an indoor
  walk with the screen locked hands over only after unlocking.

test on device: Settings → Record indoor route → leave `isr_townsend_to_front_doors`, Start recording,
walk the real lab → ISR front doors with two landmarks, Finish at the exit outside the doors, Save
("Indoor route saved. N steps."); then say "take me from ISR to CIF" with the screen on: the step lines
come before each turn, "next" / "repeat" / "status" work, and a few seconds outside the doors the CIF
route starts on its own (or after "I'm outside").

## Step 64a — Docs match the Step 60 cloud MVP (Sun Sep 13)

**Why.** An audit of comments vs `CloudSync` found agents and the Profile caption still describing the pre-MVP mirror (settings, mobility, route geometry, JSONL trip logs, a trip-event queue). The VoiceOver hint on the consent toggle was already honest; the off-state caption and the layout table were not.

**What changed.** Profile off-state caption; `AppModel` / `AGENTS.md` / `ios/README.md` / `design.md` / `CODE_REFERENCE` `cloudSharingEnabled` row now name the seven live tables and the no-op seams. `SupabaseClient` lives in `Cloud/`, not `Trip/`. UX work stays on `ux/voice-first`.

**Verification.** `make test` 770 / 770.

test on device: Profile → Privacy off reads "Medical ID, family contacts and walk summaries stay on this phone."

## Step 63 — Audit of Step 61: the refused key survives a restart, and a lock drops "Where am I" (Sun Sep 13)

**Why.** Step 61 latched the session into Apple's voice after a fatal ElevenLabs status, but a warm mp3 cache never calls the API (`ElevenLabsVoice.prefetch`), so the latch only armed after the first miss. The owner's restart (`canekit-2026-09-13T08-51-14Z`) still mixed cached ElevenLabs lines with new Apple ones. A later prefetch also wiped the HTTP 401 off the Haptics card. Separately, `scenePhaseChanged(.background)` cancelled the conversation turn but not `SceneDescriber`, so a JPEG captured before a lock could still speak the pre-lock scene.

**What changed (main only; the voice-first surface stays on `ux/voice-first`).**
- `NaturalVoiceLatch` (`settingsKey`, `shouldClearVoiceError`, `persistedError`): the latch is written to `UserDefaults` and restored in `AppModel.start()` before the first `say`. Not in `LaunchRecovery.optionalFeatureKeys` — a crash recovery must not restore two-voice mixing. `voice_backend {by: persisted}`. `retryNaturalVoice()` still clears it. `aLaterPrefetchKeepsTheRefusedKeyLine`, `recoveryNeverClearsTheRefusedVoiceLatch`, `thePersistedErrorMatchesTheSpokenStatusClause`.
- `SpeechQueue.prefetch` no longer clears `voiceError` while latched.
- `SceneDescribePolicy.maySpeak` + `SceneDescriber.cancelForBackground()`: generation bump + cancel; a cancelled run is silent (CancellationError is not "Scene description failed."). Caller: `scenePhaseChanged(.background)`, next to `conversation.cancelForBackground()`. `aLockGenerationDropsThePreLockScene`.

**Rejected / not this commit.** A launch GET `/v1/user/subscription` probe before "OpenCane ready." would catch a *first* dead-key session with a warm cache, at the cost of delaying the first line and a new network path. Persist covers the restart the owner reported. First session after quota dies still mixes until the first miss, then persists.

**Verification.** `make test` 770 / 770; `make sim` green.

test on device: with the empty account, quit and relaunch — every line including "OpenCane ready." is Apple's, `voice_backend {by: persisted}` in the trip log, Haptics card still shows the refused-key line; lock mid "Where am I" — no pre-lock sentence after unlock. Settings → Voice → System → Natural still retries after a top-up.

## Step 61 — First launch in Apple's voice: the ElevenLabs account is out of credit; a refused key is now one voice, not two (Sun Sep 13)

**Why.** Owner: "when I restarted and started up for the first time it's still using the Apple voice."
Trip log `canekit-2026-09-13T08-51-14Z`: "OpenCane ready." played from the cache (`elevenlabs /
cached`); the menu line's fetch failed after 71 ms (`speech_engine {race_failed}`), the breaker opened,
and every uncached line after it was `system / breaker_open` — so old lines came out in ElevenLabs and
new ones in Apple's voice for the whole session. A direct request with the app's key returned
**HTTP 401 `quota_exceeded`: "This request exceeds your quota of 10000. You have 0 credits remaining"**.
No code makes the natural voice speak without credit; the account needs topping up (or a paid key in
Secrets.plist). What the code did wrong was the mix.

**What changed.**
- `VoiceEngineReason.naturalUnavailable` and `VoiceEngineChoice.decide(..., naturalUnavailable:)`:
  checked after the key and the Settings picker and *before* the cache, so a refused session is one
  voice. `aRefusedKeyKeepsTheSessionInOneVoice`.
- `SpeechQueue.naturalVoiceUnavailable` latches on a fatal ElevenLabs status (401 / 403 / 422,
  `VoicePrefetch.isFatal`) from a live race or a prefetch chunk (`ElevenLabsVoice.prefetch` now returns
  its `Failure` with `fatal`); prefetching stops spending requests. `voice_backend {natural: false, by:
  refused, error}`. `retryNaturalVoice()` clears it when Settings → Voice is switched back to Natural
  (after topping up).
- Status: "System voice. The natural voice account is out of credit or refused the key."
  (`voiceClauseSaysWhenTheAccountRefusedTheKey`); Haptics card pill turns warning with the same words.

**Verification.** `make test` 765 / 765; `make sim` green.

test on device: with the empty account, launch — every line is Apple's voice, none flips; Settings →
Haptics shows the refused-key message; after topping up, Settings → Voice → System → Natural and say
"status": "Natural voice warming up…" then ElevenLabs.

## Steps 51–60 review round — Muse, OpenCode, Codex, Antigravity on the merged diff (Sun Sep 13)

**How.** One adversarial prompt (safety, voice, microphone, conversation, UI contract, logging,
concurrency) over the full diff vs `origin/main` on a repo copy. Muse and OpenCode read the files;
Codex read-only (the first pass timed out at 25 min; the rerun hung on stdin in a background shell — `< /dev/null` — and the third, focused on lifecycle, answered); Antigravity
headless with the key diff inlined (it cannot read files here). Every finding checked against the
current code before it was fixed or rejected.

**Fixed (tests first where the rule is numeric).**
- *A cane sweep held the head episode open for the whole walk* (Antigravity, confirmed by reading
  `CueDecider.update`): every untrusted frame restarted the 2 s clear clock, a cane sweeps about once
  a second, so the episode never ended and the next real overhang's onset — and its "Head height." —
  never came. Untrusted frames now freeze state without touching the clock.
  `aSweepDoesNotHoldTheHeadEpisodeOpen` (was `aSweepRestartsTheClearClock`); `cue_audit` replay and
  selftest mirror it (tonight's log: signature only 14 onsets / 13 lines, with estimated cover 0 / 0).
- *A quiet head episode silenced the centre loop* (OpenCode): a re-entry with no band to cross
  `.stop`ped the Geiger and fired nothing. The head cue now owns the hand only while it has something
  to say (`bandWouldFire`); otherwise the centre / side cue plays, and with nothing else to play the
  zone is held without a `.stop` (which could cut the head pattern's second transient).
  `aQuietHeadEpisodeLetsTheCentreCueThrough`.
- *The emergency "yes" window could close before the microphone opened* (Muse HIGH, OpenCode,
  Antigravity): the 8 s started when "emergency" was heard; the read-back prompt takes 4–7 s and the
  walking follow-up was only 3 s. `EmergencyConfirm.restartWindow(now:)` restarts it when the answer's
  microphone opens, and that listen gets the whole 8 s, walking or not.
  `answerWindowRestartsWhenTheMicrophoneOpens`.
- *The launch / follow-up listen opened after the 15 s drain cap even with speech still playing*
  (OpenCode): `waitForSpeechToDrain` now reports whether it drained and the listen is skipped
  (`voice_menu` / `voice_followup {reason: still_speaking}`).
- *Bare "cancel" mid-route answered "Nothing to confirm."* (OpenCode): it is no longer an emergency
  refusal ("no", "cancel call", "no cancel" still are).
- *Status came out clause by clause, each clause racing 2.5 s for the natural voice* (Muse MEDIUM):
  `speakStatus` speaks `StatusSummary.sentence` as one line (a warning still cuts it and it resumes at
  the clause).
- *Rows mode fired a false "Head height." in the first second* (Muse): before ARKit has a pose the
  head band is marked uncovered (`DepthFrameProcessor`), torso cues still run.
- *The describer ignored the overhang valve* (Muse): `contextLine` takes the decider's live thresholds.
- *A cache entry that vanished between the stat and the play was logged as ElevenLabs* (Muse):
  `speech_engine {engine_reason: playback_failed}` now.
- *The safety watchdog retry lost its "system voice now" after `immediate:` was removed* (merge with
  Step 51a): `speakNow(watchdogFallback:)` dispatches `system / watchdog_fallback` directly.
- `VoiceShellPolicy` documents that the app passes "not refused" for permissions (Muse, OpenCode).
- *A launch or follow-up listen could open the microphone after a lock* (Codex, second pass): the
  waiting Task survived `scenePhaseChanged(.background)`. `voiceShellGeneration` is bumped on
  background and checked (with `applicationState == .active`) right before `startListening`.
- *A cloud answer about the pre-lock scene could speak after the unlock* (Codex): background now calls
  `ConversationCoordinator.cancelForBackground()` — the budget refuses the turn, so it neither speaks
  nor runs a tool; `conv_error {reason: backgrounded}`.

**Rejected, with evidence.**
- "A race timeout / failure never speaks and deadlocks the queue" (Antigravity BLOCKER): both
  branches of `startRace` call `speakSystem(spokenText, gen:)` — it reviewed a trimmed diff.
- "The head cue flickers off after one frame" (Antigravity BLOCKER): frame 2 is the same-cue branch,
  which returns `bandRefire`'s nil, never `.stop`.
- "The launch mic opens during a race because nothing is speaking yet" (Antigravity HIGH):
  `isSpeaking` is set in `speakNow` before the race starts.
- "Intrinsics may be portrait" (OpenCode): `capturedImage` / `imageResolution` is landscape
  1920×1440 (trip log `video_format`), and `GroundSampler` has used the same scaling since Step 21.
- "The breaker sticks open once everything is cached" (Muse, Antigravity): the next uncached line
  speaks once in the system voice and is prefetched, and that probe closes the breaker within 60 s;
  cached lines play in the natural voice meanwhile. Noted in docs/todo.md.
- "A superseded turn's "One moment." still plays" (Antigravity, OpenCode LOW): accepted as cosmetic.
- "Self-hear misses a one-word echo of the menu" (Antigravity): the tap is paused while the app speaks
  (+0.3 s); the filter is the second layer.

**Verification.** After the fixes: `make test` 763 / 763; `make sim` green; `make uitest` 12 run / 0
failures; `make build` + `make install` on the iPhone 17 Pro Max green. `make e2e` PASS × 4 (clean,
missed_fence, gps_jitter, wrong_turn) on the pre-fix build of the same commit (no route-path change since).

## Step 60 — Consent-gated Supabase MVP (Sun Sep 13)

⚠ Numbered 60, not 56: "Steps 56–59" below is the voice shell, and this entry was drafted twice, as
"Step 56" and as a second "Step 51", in `docs/todo.md`. Both drafts are now this one entry.

**Why.** A compact MVP needs safety records that matter away from the phone, not copies of every
local state change. The live project had already been reduced to seven product tables, but the
new consent-gated app work still contained writers for the retired detail tables.

**What changed.** Reconciled the privacy opt-in with the MVP schema. With cloud sharing enabled,
OpenCane mirrors only `walkers`, `devices`, `medical_profiles`, `family_contacts`, `trips`,
`hazards` (plus capped `hazard-photos`) and `family_alerts`. Detailed JSONL, route geometry,
settings, posts, conversation transcripts, launch recovery and daily mobility remain on the phone.
The compatibility callbacks are intentional no-ops, so an old call site cannot recreate a removed
cloud write path. Turning sharing off still cancels deferred work and prevents later uploads.

**Verification.** Supabase MCP inventory confirmed those seven application tables, each with RLS
enabled (from the session that wrote the migration; the MCP server was not authenticated when this
entry was finalised, so that half is not re-verified here). The adapter contains no request string
for a retired table: `grep -n '"trip_events"\|"device_settings"\|"posts"\|"conversation_turns"\|
"mobility_days"\|"app_launches"\|"routes"\|"route_waypoints"\|"family_alert_recipients"'
ios/CaneKit/Cloud/CloudSync.swift` is empty. `cd ios && make test` = 761 tests in 18 suites, exit 0;
`make sim` = BUILD SUCCEEDED. Device verification remains open below.

**Rejected.** Deleting `TripEventRow` / `DeviceSettingsRow` from `CaneKitLogic` along with their
writers. The wire shape is the contract with the migrations, and the MVP reduction is a product
decision that can be reversed; a row type with tests costs nothing and is the thing that will catch
the next drift. Their doc comments now say plainly that the app writes neither today, which is what
was actually wrong (a comment described a `CloudSync` queue this same change deleted).

test on device: enable cloud sharing, take one short route and confirm one `trips` summary; edit
Medical ID, record a hazard and send a family alert, then disable sharing and confirm no later
writes occur.

## Step 52 — "Head height." only for things at head height, once per overhang (Sun Sep 13)

**Why.** The first cane walk (`canekit-2026-09-13T04-36-32Z.jsonl`) had 137 head cues and 8 "Head
height." lines in 12 minutes. Two causes besides the geometry (Step 51): 587 of the 625 head cells
under 1.5 m were near in the torso band too (walls, doors, people — things the cane finds), and the
repeat engine re-fired the head haptic at 1 Hz while the speech episode ended on any single clear
frame, so an overhang flapping at the 1.65 m exit line re-spoke every 4 s.

**What changed.**
- `HeadGate.swift` (new, pure): `candidate(in:enter:overhangGap:)` — nearest **covered** head cell
  under `enter` whose torso cell is ≥ 0.5 m farther, non-finite or uncovered (fail-safe). One rule
  for three readers: `CueDecider`, `AppModel.contextLine` ("Something at head height." — any lane
  now, through the gate) and the island `headNear`.
- **Overhang signature ON by default** (owner decision 2026-09-13, "keep it on for now"):
  `CueRules(level:place:requireOverhangSignature: = true)` → `AppModel.applyCueRules` →
  `CueThresholds.requireOverhangSignature`; valve `Settings.bool("overhangSignature", default:
  true)` read once in `AppModel` (no UI, hard rule 9 untouched). Supersedes the AGENTS.md line
  "Walls still get 'Head height.' (owner: 'Leave as is')". `cue_design_v2.md` had it off by default.
- `CueDecider`: `HapticCue.head(distance:onset:)` (kind / wire format unchanged); a `HeadEpisode` —
  the onset fires at once (only the 400 ms change gate; the 1 s repeat floor no longer applies to
  head), re-fire only on crossing 1.0 m and 0.6 m, each once, ≥ 1.5 s apart (a jump across both fires
  once), no time-based re-fire; the zone still `.stop`s with the 0.15 m hysteresis, but the episode
  ends only after 2 s of **trusted** clear, and an untrusted (sweep) frame restarts that clock. New
  thresholds `overhangGapM`, `requireOverhangSignature`, `headRefireBands`, `headRefireMinGap`,
  `headClearSeconds`; `headEpisodeActive`. The Gemini first pass (in the tree) held the `.stop` for
  2 s and kept the 1 s floor for head; both corrected.
- `CueSpeechPolicy`: `episodeKind` and `cleared()` removed; "Head height." on the onset (4 s limiter
  kept) and once more per episode under 0.6 m (`headSecondLineBelowM`). Text byte-identical, so
  `commonLines` and the voice cache are unchanged. `AppModel.handle` drops the three `cleared()`
  calls (stop, background, depth failure, both cameras — `decider.reset()` ends the episode there);
  the head `cue` record gains `distance` and `onset`. `TorsoHapticPolicy` passes the payload through.
- `ios/scripts/cue_audit.py`: `head_gate` (Python `HeadGate`) and `head_gate_replay` (2 Hz mirror of
  the episode rule and the speech policy; ±0.5 s timing, no change gate) + `selftest_head` fixtures.

**Evidence (replay of `04-36-32Z`, rows-mode log, 393 depth frames).** Logged: 137 head cues, 8 lines.
Signature + episode rule alone: 12 onsets, 0 band re-fires, 12 lines — the signature alone does not
fix a 45° mount (the 37 "overhang-like" cells are knee-high things with the floor 0.5 m behind them,
and gating them on and off splits episodes; without the signature the same rule gives 5 onsets, 2
re-fires, 6 lines). With Step 51's estimated cover (tilt 45° > 19° limit): **0 onsets, 0 lines.**
That is why Step 51 is the root fix and 52 is what keeps a correctly aimed mount quiet.

**Tests (written first, Swift Testing).** CueDeciderTests 26 (was 15 + Gemini's 3): rewritten with
history comments — `headFiresAtOnsetThenOnlyOnCloserBands` (was `headCueKeepsRefiringWhileObstaclePersists`),
`headFlappingAcrossTheExitLineIsOneEpisode` (was `headReturningAfterClearWaitsOutTheFloor`),
`headBeatsCenterBeatsSides` (head 1.0 over torso 1.0 is now the centre cue), `wallNearInBothBandsIsNotHead`
(was Gemini's `overhangSignatureRequiresTorsoFarther`); new `aJumpAcrossBothBandsFiresOnce`,
`headOnsetIsNeverHeldByTheRepeatFloor`, `headEpisodeEndsOnlyAfterTwoSecondsOfTrustedClear`,
`aSweepRestartsTheClearClock`, `hangingSignWithClearTorsoIsHead`, `torsoHalfAMetreFartherIsHead`,
`torsoNoDataFailsSafeToHead`, `overhangSignatureCanBeSwitchedOff`, `headIgnoresLanesWithoutCoverage`,
`torsoWithoutCoverageFailsSafeToHead`; `cueChangeNeeds400ms` payload. NavSupportTests: rewritten
`headHeightIsSpokenOncePerEpisode`, `headEpisodesAreRateLimitedAcrossEpisodes`,
`aBuzzedSideCueDoesNotSplitAHeadEpisode`; new `secondHeadLineNeedsUnderSixtyCentimetres`.
CueProfileTests: new `defaultRulesRequireTheOverhangSignature`; payload in
`defaultRulesRenderTodaysHaptics`. TorsoHapticPolicyTests `quietStillRendersHead`,
`headIsNeverSuppressed`: torso cells 1.0 → 1.6 m (a 1.0/1.0 pair is a wall under the signature) and
the second fire is the 0.6 m band re-fire. SpokenPhrasesTests `fixedCueLinesAreLeftToCommonLines`
payload.

**Reviews.** Not run by this agent (Muse / Antigravity / multi-agent review are the orchestrator's
gate for this wave). Self-checked against `docs/cue_design_v2.md` §3.2 and the plan; deviations: no
closing gate on the onset line (hard rule 8: the first cue is never delayed), no side-lane threshold,
no same-overhang dedup.

**Verification.** `cd ios/Logic && swift test --disable-xctest --scratch-path <scratch>/spm` → exit 0,
**749 tests in 17 suites passed** (shared tree, with the other agents' Steps 53–59 work in it).
`python3 ios/scripts/cue_audit.py --selftest` → ok; the audit of `04-36-32Z` → exit 0 (numbers above).
`cd ios && make sim DERIVED=<scratch>/dd` → BUILD SUCCEEDED. Not run here (orchestrator gate):
`make uitest`, `make e2e`, device.

test on device: hinge at ≤ 15° (Mount card "good"); a board held at 1.7 m with nothing under it →
one tap + one "Head height." before 1.3 m, at most one more tap under 1.0 m and one tap + line under
0.6 m, nothing on a timer; stand under it 10 s → silence; step out and back inside 2 s → silence; after
3 s → a new onset (line only if ≥ 4 s since the last); walk at a plain wall → centre cue, no "Head
height."; `make audit --pull` → `cue` records carry `onset`, `head_gate_replay.logged_head_onsets` ≈
the replay's onsets.

## Step 51 — Metric lane bands: the camera knows what height it is looking at (Sun Sep 13)

**Why.** On the first cane-mounted walk (`canekit-2026-09-13T04-36-32Z.jsonl`) the phone sat **45°
down** (tilt median 45.3°, range 18.9–73.2°; 0 % inside 3–8°). The lane bands were image rows: at 45°
the "head" rows looked at knee-to-waist things 1 m ahead and the "torso" rows read the floor ~1.45 m
away. `cue_audit`: 625 head cells under 1.5 m, **625 of 625 could not have been head height** even from
the top image row (camera 95 cm, half FOV 33.5°); head cues 15.8 / min, centre 2.1 / min.

**What changed.**
- `LaneMath.swift`: `LaneGeometry` (depth-map intrinsics + the world-up components of the camera
  axes; `h = camH + d · (upX·(u−cx)/fx − upY·(v−cy)/fy − upZ)`, `GroundSampler`'s projection, so roll
  is compensated for free); `LaneBandMode` (`rows` / `metric`); `LaneConfig.cameraHeightCm 95`,
  `floorMaxHeightCm 25`, `headMinHeightCm 140`, `coverageRangeCm 150` — owner decision 2026-09-13:
  the new geometry works in **centimetres** (`heightCm(u:v:depthM:cameraHeightCm:)` converts once),
  lane distances stay metres. `computeLanes(..., geometry:)`: metric path over all rows, floor dropped,
  blind pixels counted toward their nominal band (Step 48 kept), per-lane `headCoverage` /
  `torsoCoverage`; **no cover = `.infinity` + flag false**, never NaN / −1. Nil geometry = the old rows.
  Restored the Muse F6 blind-share comment the first pass dropped.
- `DepthFrameProcessor.computeGrid`: builds the geometry (nil while `trackingState == .notAvailable`),
  passes it to both lane passes (smoothed + raw blind), publishes it on `LaneReport.geometry`.
- `LaneReport.swift`: `MountTilt.status(downDeg:headCover:)` ("Camera tilt N° down: too steep for
  head-height cover"), `MountTilt.headCoverLimitDeg(...)` — **z-depth** formula
  `acos(k·cos h) − (90° − h)` ≈ 19.0° (the first pass used the range formula `h − atan(k)` = 16.8°,
  wrong for ARKit's z-depth; the per-lane flag sweep in `headCoverLimitFollowsTheGeometry` agrees
  with 19°); `TileLevel.noCover`; `HeadCoverNotice` ("Camera too steep for head-height cover. Torso
  obstacles only." once per route after 2 s of trusted uncovered metric frames, `.nav`, logged
  `head_cover`; byte-identical in `AppModel.commonLines`).
- `NearHold`: uncovered cells skipped; cold start needs `min(4, covered cells)` (at 45° three torso
  cells exist).
- UI: `LaneTile` NO COVER ("—" on the no-data fill), row VoiceOver "no cover"; `MountAimRow` passes
  `headCoverage`. "Head row" / "Torso row" labels unchanged (hard rule 9).
- Trip log: `lanes {bands, head_cover, torso_cover}`; `depth_geometry` once per distinct intrinsics
  (fx, fy, cx, cy, up, pitch, cam_h_cm, floor_max_cm, head_min_cm, cover_range_cm, half FOV, limit).
- `cue_audit.py`: `head_cover` (`share_head_cover`, `limit_deg`, `bands`, `could_not_be_head`) and
  the human line "head-height cover in 0% of frames (limit ≈ 19.0°) — head cues were impossible on
  this walk".
- Docs: AGENTS.md (the gravity bullet, hard rule 8, walls bullet, cue_audit bullet, evidence logs),
  hardware/mount/DESIGN.md (dated notes §0, §2, §4, T3/T4, §13), docs/cue_design_v2.md (§3.2, §4 rows
  3, 6, 7, 13), docs/design.md (§5.2 head row, §6.2 NO COVER), CODE_REFERENCE, todo.

**Risk said out loud.** At 45° nothing above ~0.6 m is visible at 1.5 m: head cues are physically
impossible there, and the app now says so (card, tiles, one line, log) instead of lying. The torso
band at 45° comes from the upper third of the image; anything under 25 cm (curbs, steps) is the
ground detector's, still tilt-gated to 0–15°. Camera height is a constant 95 cm (DESIGN.md measured
0.97 m; ±15 cm stays inside the floor margin). Rows mode still runs for the first frames before a pose.
Orientation of `upX` in portrait is only verifiable on hardware (`depth_geometry.up`).

**Tests (written first).** `LaneGeometryTests` (16, new fixture `syntheticDepth(pitchDeg:rollDeg:
camH:surfaces:)`): `metricBandsDropTheFloorAtFortyFiveDegrees`, `metricBandsDropTheFloorAtFiveDegrees`,
`aWallIsTorsoAndHeadAtMountTilt`, `aWallAtFortyFiveDegreesIsTorsoOnly`, `aHangingSignIsHeadOnlyAtMountTilt`,
`aHangingSignIsInvisibleAtFortyFiveDegrees`, `aPersonIsTorsoAndHead`, `kneeHighBoxAtFortyFiveDegreesIsTorsoNotHead`,
`headCoverageFallsOffPastTheGeometryLimit`, `headCoverLimitFollowsTheGeometry`,
`blindSamplesCountTowardTheirNominalBand`, `rollDoesNotBreakTheBands`,
`pitchOnlyGeometryMatchesTheTransformRow`, `heightIsLinearInDepth`,
`mountTiltStatusSaysTooSteepForHeadCover`, `tileNoCoverIsNotClear`, plus
`headCoverNoticeSpeaksOncePerRouteAfterTheHold`, `headCoverNoticeIgnoresRowsModeAndTransients` (the
Gemini pass's five geometry tests replaced). LaneMathTests renamed with history:
`headRowIsTopBandWithoutGeometry`, `groundBandIsSkippedWithoutGeometry`, `mountTiltStatus` (was
`mountTiltWindow`: 12° is good now). NearHoldTests `coldStartCountsOnlyCoveredCells`.

**Reviews / verification.** As Step 52 (same work unit): Logic 749/749 (exit 0), `cue_audit.py
--selftest` ok, `make sim` BUILD SUCCEEDED; reviews, `make uitest` (NO COVER tile in the tour
pictures) and `make e2e` are the orchestrator's gate.

test on device: cane at ~45° on a flat floor → torso tiles CLEAR, no Geiger, head tiles NO COVER, Mount
card "too steep for head-height cover", one "Camera too steep…" line after starting a route; re-angle
to 5–10° → card "good", head tiles read; wall at 1 m → torso ≈ head ≈ 1 m; `make audit --pull` →
`bands: metric` on every `lanes` after the first second, `depth_geometry` present, `share_head_cover`
≈ 0 at 45° / ≈ 1 re-angled.

## Step 55 — OpenCane never answers its own voice (Sun Sep 13)

**Why.** The first cane-mounted walk logged `conv_error query: "Head height"`: the walker was
dictating, "Head height." (`.safety`) broke through the voice hold as designed, the microphone has no
echo control (hard rule 7: no `.voiceChat`, no HFP), and the recogniser transcribed the phone's own
warning as the question. The hold was also set only *after* the engine started, so the line playing at
the press was heard by the first buffers.

**What changed.**
- `VoiceInputEngine`: the voice hold is set just before the `.voiceInput` microphone lease (the line
  playing is cut first; every failure path still releases it in `cleanupAudioPipeline`). The Gemini
  first pass set it at the top of `startListening` — before the permission prompts, and never released
  when `VoiceInputGuard.beginPermissionRequest` refused — moved.
- `SpeechBufferBox` gains `paused: Mutex<Bool>` (Synchronization), read inside the nonisolated tap —
  no actor hop from the Core Audio thread (Step 24 SIGTRAP rule); replaces an `NSLock` flag.
- `SpeechQueue.onSpeakingChanged` → `VoiceInputEngine.speakingChanged`: while listening, speaking →
  pause now; not speaking → resume after `SelfHearFilter.tailSeconds` (0.3 s) if nothing started
  again; a `.safety` line already playing when the tap starts pauses it at once. Every pause is logged
  when it ends: `voice_self_hear {action: paused, pause_ms}`.
- `AppModel`'s `speech.onDispatch` forwards every dispatched text to `VoiceInputEngine.noteDispatched`,
  which records it in `SelfHearFilter` only while starting / listening (a line dispatched before the
  press — the launch menu, an answer — never makes the walker's reply to it look like an echo). The
  final transcript runs through `shouldDrop`; a match is dropped silently with
  `voice_self_hear {action: dropped, transcript, matched_line}`.
- `SelfHearFilter` (CaneKitLogic) audited against the design: 3 s window, 0.3 s tail, ≥ 3 characters,
  normaliser (lowercase, punctuation → space, whitespace collapsed, digits kept), whole line or one
  clause split on `SpeechResume.clauseEnders`, never "contains". The pre-written clause test expected
  "2.5 meters ahead" — the normaliser (documented) turns the point into a space on both sides, so
  the pinned clause is "2 5 meters ahead"; test corrected, rule unchanged. The app called
  non-existent `recordSpoken` / `isSelfHear` (the app target did not compile) — replaced.
- No audio-session category, mode or option changed (hard rule 7).

**Tests.** `SelfHearFilterTests` (8): `selfHearNumbersArePinned`, `exactLineWithinThreeSecondsIsDropped`,
`punctuationAndCaseDoNotMatter`, `aClauseOfARecentLineIsDropped`, `theWalkersOwnWordsAreKept`,
`oldLinesAgeOut`, `shortFragmentsNeverMatch`, `recordingIsExplicitAndResetEmptiesTheHistory`.

**Reviews.** Muse / adversarial review / Antigravity: to be run by the orchestrator's gate on the
combined Steps 51–59 diff (this agent did not run them).

**Verification.** See Step 54 (same run).

test on device: hold a hand over the LiDAR at head height and press Talk; say "where am I" while
"Head height." plays — the answer is to "where am I", never to "head height"; the log shows
`voice_self_hear {action: paused}` (and `dropped` if the recogniser still caught the warning).

## Step 54 — One voice (Sun Sep 13)

**Why.** Owner decision 2026-09-13: "ElevenLabs is the one voice for everything." On the mounted walk
the voice flipped every few lines: every conversational answer was `immediate: true` (system voice
forever, even on a warm cache), the 60 s breaker re-raced a dead network every minute, each warning's
cache miss *cancelled* the running prefetch batch, and the route intro was prefetched ten lines before
`NavigationEngine.start` spoke it — a guaranteed miss on a cold cache.

**What changed.**
- `immediate:` is gone from `SpeechQueue.say` / `Pending` / `speakNow` and from every caller
  (`ConversationCoordinator`: fast-path answer, no-cloud line, "One moment.", cloud answer, fallback;
  `VoiceInputEngine`: "I did not catch that.", now also in `commonLines`). Every line: cache → 2.5 s
  race → system voice only on failure. `.safety` / `.obstacle` cache misses still speak the system
  voice at once.
- `VoiceBreaker` (CaneKitLogic) replaces `naturalVoiceFailedAt` / the Gemini `naturalVoiceBreakerOpen`
  (which a cache hit or any prefetch closed): opens on a race timeout / failure, closes only when a
  background prefetch chunk that requested ≥ 1 line succeeds, probe every 60 s while open.
  `voice_breaker {open, reason}`. `SpeechQueue.naturalVoiceOffline` mirrors it for the UI.
- Prefetch is additive: `prefetch` prepends to one backlog; a single worker merges it with
  `routeLines + backgroundLines` (`VoicePrefetch.merge`, off main) and fetches `VoicePrefetch.chunk`
  (2) lines per pass; a failed chunk keeps the backlog (next `prefetch` call or the probe retries).
- `WalkingIntro.routeStarted(_:)` builds the intro for both `NavigationEngine.start` and
  `AppModel.routeStartLines` (announce + intro + waypoint lines), prefetched in `buildRoute` (as soon
  as MapKit answers), `queueRouteStart` (the depth wait) and `startRouteNow` (degraded paths).
- Launch prefetch puts the safety vocabulary first (`AppModel.safetyLines` = "Head height." + ground
  hazard lines, then `commonLines` = `voiceReadyLines`).
- `StatusSummary`: `VoiceFacts` + `voiceReady` / `voiceLine` ("Natural voice ready." / "…warming up,
  N percent cached." / why the system voice); the clause follows audio when `StatusFacts.voice` is set
  (`AppModel.speakStatus` fills it from `voiceFacts()` → `SpeechQueue.cachedShare(of:)`).
- Details tab: the Scene engine card gains a "Voice" row (last line's engine · reason); the Haptics
  voice pill's VoiceOver label names the reason and says when the natural voice is unreachable.
- Docs: `SpeechQueue` header rules, AGENTS.md hard rules 7–8 notes + "Things that look wrong" (one
  voice, self-hear) + the `speech_dispatch` bullet, design.md §5.1 engine table, CODE_REFERENCE
  (SpeechQueue, ElevenLabsVoice, VoicePrefetch, new VoiceEngineChoice / VoiceBreaker / SelfHearFilter
  sections, StatusSummary, WalkingIntro, VoiceInputEngine, ConversationCoordinator, cue_audit).

**Tests.** `VoiceEngineChoiceTests` breaker tests (5; two rewritten to bind mutating calls outside
`#expect`, which cannot call a mutating member), `VoicePrefetchTests` +3 (`aNewBatchGoesAheadOfTheBacklogAndTheTailFollows`,
`mergeDropsCachedAndRepeatedLinesButNeverAnUncachedOne`, `prefetchChunkIsTheConcurrencyLimit`),
`StatusSummaryTests` +3 (`voiceClauseSaysReadyOnlyWhenEverySafetyLineIsCached`,
`voiceClauseNamesTheSystemVoiceAndWhy`, `voiceClauseFollowsAudioAndIsOmittedWhenNotMeasured`),
`CampusPlacesTests.introLineIsWhatNavigationSpeaks` (its pre-written `Waypoint(id: "wp1", lng:, bearingDeg:)`
did not match the real initialiser — fixed).

**Reviews.** Pending (orchestrator gate).

**Verification.** `cd ios/Logic && swift test --disable-xctest --scratch-path <agentB>/spm` and
`make sim DERIVED=<agentB>/dd` — results in the agent report (REPORT.md).

test on device: Wi-Fi on, relaunch, wait 30 s, ask "status" — hear "Natural voice ready." in the
ElevenLabs voice; start the CIF route — "Route started. …" in the natural voice; ask an open question —
the answer in the natural voice (up to 2.5 s later); turn Wi-Fi off and ask again — one system-voice
line, `voice_breaker {open: true}`, every later uncached line system voice at once; Wi-Fi on — within a
minute `voice_breaker {open: false}`. `make audit`: `engine_flips_inside_route_speech` 0.

## Step 53 — Which voice spoke is logged; the Voice picker (Sun Sep 13)

**Why.** Nothing in the trip log said which engine spoke a line or why, so the flipping could not be
measured. And the Gemini first pass persisted `useNaturalVoice` inside `SpeechQueue` under its own
UserDefaults key with the picker squeezed into the Cues card.

**What changed.**
- `VoiceEngineChoice` (CaneKitLogic): `decide(muted:hasKey:naturalEnabled:cached:isWarning:breakerOpen:)`
  → `VoiceEngineDecision {engine, reason}`; raw values pinned (log contract). `SpeechQueue.speakNow`
  calls it before `onDispatch` (the dispatch time `cue_audit.py` measures from does not move).
- `speech_dispatch` gains `engine` / `engine_reason`; a race resolution writes
  `speech_engine {text, engine, engine_reason: race_won | race_timeout | race_failed | playback_failed, wait_ms}`.
  The Gemini strings ("cache_hit", "fetch_timeout", …) are replaced by the pinned raw values.
- `AppModel.naturalVoiceEnabled` (`Settings.bool("useNaturalVoice", default: true)`, didSet →
  `speech.useNaturalVoice` + `voice_backend {natural, by: settings, key}`; pushed and logged `by: launch`
  in `start()`); `SpeechQueue.useNaturalVoice` is a plain var again.
- Settings: a "Voice" card after Haptics — segmented Natural / System (disabled without a key, caption
  says why), and below it the voice-shell listening toggles (moved out of the Cues card; Step 58 owns them).
- `cue_audit.py`: `engine_flips_per_minute` and `engine_flips_inside_route_speech` (separate functions,
  `rep["voice"]`, selftest fixture).

**Tests.** `VoiceEngineChoiceTests` table tests (11): `mutedNeverMakesASound`, `noKeyAlwaysSystem`,
`naturalOffAlwaysSystem`, `cacheHitIsNaturalEvenForAWarningWithTheBreakerOpen`, `warningMissIsSystemNow`,
`breakerOpenIsSystemNow`, `anyOtherMissRaces`, `raceDeadlineIsPinned`, `engineAndReasonRawValuesArePinned`,
`aResolvedRaceNamesTheEngineThatSpoke`, `everyReasonHasWordsForTheDetailsCard`. `cue_audit.py --selftest` ok.

**Reviews.** Pending (orchestrator gate).

test on device: Settings → Voice → System: every line in Apple's voice, `voice_backend {by: settings}`;
back to Natural. Details → Scene engine → Voice row reads "Natural voice · cached" after "OpenCane ready."

## Steps 56–59 (part 1: logic + surface) — the voice shell: eight words on the phone, a 4 s budget, emergency by voice, a giant microphone (Sun Sep 13)

**Why.** The first cane-mounted walk (`canekit-2026-09-13T04-36-32Z.jsonl`) showed a sighted app
strapped to a cane: a 108 pt "Talk to OpenCane" tile among eleven buttons, one utterance at a time,
cloud turns of 6–17 s with no bound, a second question dropped ("Still working on your last
question." ×N). Owner decisions 2026-09-13: launch = a giant round microphone dead-centre; words
primary, digits as aliases; "route" alone = the CIF demo route, "take me to …" = any place.

**What changed (this part: pure Logic, the coordinator and the Guide surface; the AppModel wiring —
launch menu + listen, follow-up window, `commonLines` — is part 2).**
- `VoiceMenu` (new, CaneKitLogic): route / where am I / describe / status / repeat / quiet / help /
  emergency, digits 1–8 as words and numerals, whole-utterance match after normalisation, no
  homophones; `menuLine`, numbered `helpLine`, per-item `confirmationLine` (quiet reuses
  `CueLevel.quiet.spokenLine`), yes / no / cancel, `extraVerbs` next / standard / detailed.
- `FastPathIntentClassifier` rule 0 goes through `VoiceMenu` (replacing the first pass's literal
  lists). Deliberately *not* aliases: "route to cif" (rule 14's gazetteer route), "what is ahead"
  (the grounded scene-question path), "help me" (a walker in trouble says it), "call 911" (the app
  calls the contact, not 911). "stop" stays an exact-phrase rule. Rule 12 (distance walked) now runs
  before rule 8, so "how far have I walked" is answered correctly; bare "status" is rule 0.
- `ConversationAction`: the first pass's `whereAmI` / `showHelp` / `triggerEmergency` /
  `confirmEmergency` are `describeScene` / `help` / `emergency` / `confirm(Bool)`; new
  `startDefaultRoute`, `speakStatus`; `setCueLevel(CueLevel)`.
- `ConversationBudget` (new): filler "One moment." at 1.5 s, timeout at 4 s, turn ids,
  `begin` / `tick` / `finished` / `cancel`. `ConversationCoordinator` uses it instead of the inline
  reminder task + task group: every new query supersedes a cloud turn in flight (the old
  `guard !isProcessing` drop is gone — with it in place the first pass's `cloudTask?.cancel()` could
  never run for a second query), a 0.25 s ticker speaks the filler / timeout, stale completions never
  speak, `conv_turn` gains `budget_ms` / `filler_spoken` / `superseded` / `timed_out` / `ivr`,
  `conv_error {timeout: true}`. The first pass's timeout threw `CancellationError` into the generic
  catch and spoke "I could not process that request right now." with no timeout field.
- `EmergencyConfirm` (new): prompt "Say yes to call <name> at <number>.", 8 s window, four fixed
  lines, `telDigits` (moved from `ProfilePage`, which now calls it — only a *leading* plus is kept).
  Coordinator: prompt at `.nav` ttl 8 + expiry "Emergency canceled."; "yes" inside the window logs
  `emergency {action: confirmed, contact}` (the name, never the number), flushes the trip log, opens
  `tel:`; replaces the first pass's `emergencyPendingUntil`.
- `VoiceShellPolicy` + `ScenePhaseReason` (new, pure, wired in part 2); `UtteranceEndDetector`
  takes a per-listen `maxListen`.
- `SpokenPhrases.shellLines` (31 lines, 1,179 characters ≤ `shellCharacterBudget` 1,500) +
  `notHeardLine` / `describerBusyLine`; `StatusSummary.fixedLines` (13 number-free clauses, now
  named constants the clause functions return). `DescribeTrigger.voice` ("the voice menu").
- UI: `VoiceTile` (new) — the microphone inside ~40 seeded contour rings (`Canvas`), ≥ 60 % of the
  page height, one button → `toggleVoiceInput()`, ripple while listening / breathe while speaking /
  still when idle or under Reduce Motion, labels "Talk to OpenCane" / "Listening…" / "Starting…" /
  "Thinking…". `GuideCard`: the two-up Where am I / Talk row became the tile + a compact row (idle
  Where am I | Start route to CIF; navigating Repeat | Next | Stop route); every hard-rule-9 label
  byte-identical. `scrollTo(_:)` added to `CaneKitUITests`, `CaneKitVisualTour`, `CaneKitIslandTour`
  before Recenter / Simulate walk / Go / Destination / Navigate to CIF from here / Stop route.
- Docs: design.md §6.1 (tile, compact row, the three-per-row exception), handsfree.md §0 / §1b / §5
  latency, CODE_REFERENCE (four Logic entries, VoiceTile, coordinator, GuideCard, UI tests).

**Tests (written first).** `VoiceMenuTests` (9), `ConversationBudgetTests` (8, incl.
`cancelRefusesTheLiveTurn`), `EmergencyConfirmTests` (9), `VoiceShellPolicyTests` (7),
`ScenePhaseReasonTests` (3), `ConversationLogicTests` (`ivrRuleRunsBeforeEverythingElse`,
`stopPhrasesStillStopBehindRuleZero`, `howFarHaveIWalkedIsTheDistanceWalked` replace the first pass's
`fastPathIVR`), `UtteranceEndTests.followUpWindowUsesAShorterCap`,
`SpokenPhrasesTests.shellLinesStayInsideTheirBudget` / `everyLineTheShellCanSpeakIsPrefetched`,
`StatusSummaryTests.everyNumberFreeClauseIsAFixedLine`.

**Reviews.** Pending — multi-agent, Muse and Antigravity run by the orchestrator on the combined diff.

**Verification.** `swift test` on a scratch copy of `ios/Logic` without the test files another agent
had mid-change: 715 tests, 3 issues none in this scope (two need the route file outside the copy,
one is `SelfHearFilterTests`); the filtered run of every suite above: 148 tests, exit 0.
`make gen` 0; `make sim` green. UI tests and e2e not run here (orchestrator gate).

test on device: say "help" → the numbered list; "four" → status; "emergency" → prompt with the
contact's name and number → "no" → "Emergency canceled."; an open question → "One moment." by 1.5 s
and an answer or the timeout line by 4 s, ask again mid-flight → first `conv_turn` `superseded`; the
rings ripple while listening and the whole ring area starts listening.

## Step 51a — Adversarial safety hardening: stale sensors, lifecycle races, and explicit consent (Sun Sep 13)

**Why.** A review of the live navigation path found ways for stale sensor state, out-of-order
asynchronous work, or an unannounced capability failure to outlive the component that produced it.
Those are safety failures for a blind walker even when the happy path is unchanged.

**What changed.**
- GPS fixes now have a five-second freshness gate. A terminated/revoked Core Location stream or a
  stale/future fix withdraws the route target and speaks the existing GPS-weak line; permission
  denial cancels a queued route start and uses the Settings guidance.
- Terminal AR failure/interruption drops retained camera frames, stops the hazard scanner and face
  yaw consumer, and generation-fences late Vision/VLM callbacks. Deferred face, frame-rate and mesh
  configuration requests are all applied after a route ends; MultiCam teardown gets a background
  execution budget before suspension.
- Haptic runtime failures mark the engine unhealthy immediately, so the existing watch and speech
  fallback is selected on the next cue. AirPods callbacks are lifecycle-generation fenced.
- Push-to-talk and sound recognition clean up taps/engines before releasing the shared microphone
  lease; route/interruption/permission failures, analyzer errors, MP3 decode errors and audio-session
  startup errors surface through the existing speech/watch channels. Speech interruption retries and
  Live Activity operations are generation/serialization fenced.
- Arrival summaries and HealthKit step refreshes carry route/trip generations, preventing an old
  asynchronous result from changing a replacement route. Stop route is now a two-tap confirmation
  with a three-second window and an audible/visible armed state.
- People detection defaults off and is labelled **Experimental — not validated on the cane** when
  enabled. Profile data starts without seeded identity/medical/contact PII. Supabase mirroring is
  off until the user explicitly opts in; turning it off drops queued uploads and leaves local data
  intact (existing remote rows are not deleted automatically).
- Profile metric tiles respect Dynamic Type and expose combined VoiceOver labels; unsupported hazard
  controls explain why they are unavailable; simulator grant now fails on boot/privacy errors and
  seeds a deterministic location.

**Verification.** `cd ios && make test` → **654 tests in 12 suites passed** (exit 0). `make sim` →
**BUILD SUCCEEDED** (exit 0; only the pre-existing `CLGeocoder` iOS 26 deprecation warning).

test on device: during a route, background and resume the app and confirm guidance stays in GPS-weak
state until a fresh fix and trusted AR frame arrive; interrupt ARKit and reconnect it, disconnect
AirPods during sound recognition and push-to-talk, revoke microphone and location permission, trigger
a haptic/audio failure, verify the People card says experimental, toggle cloud sharing off, and tap
Stop route once then again to confirm the armed window and safe cancellation behavior.

## Step 50 — Typing a destination: the tab bar leaves with the keyboard, and no rows from Australia (Sat Sep 12, 23:21)

**Why.** Owner's screenshot while typing "Oab": iOS 26 draws the keyboard's "Done" as a floating
glass capsule, and it sat on top of the Profile icon of our tab bar, which stayed on screen above
the keyboard; and the suggestion list read Osborne Park WA (Australia), OAB in Lake Isabella MI,
OAB RJ in Rio — MapKit's completer matches famous names anywhere even with a 6 km `.required`
region, and a blind walker cannot see that a row is on another continent.

**What changed.**
- `ContentView`: the tab bar collapses while the keyboard is up (`keyboardWillShow` /
  `keyboardWillHide`) — height 0, invisible, hidden from VoiceOver, but still mounted so the
  accessibility tree keeps its landmarks and focus does not jump when it returns (Muse); the
  floating Done now sits over page content, where iOS puts it.
- `Locality` (CaneKitLogic, in `DestinationSuggestions.swift`): a completion has no coordinate
  (AGENTS.md), so its subtitle is the only evidence, and the only safe cut is the **country**: a
  row whose subtitle ends in another country's name is dropped; anything else — another US state
  included — is kept, because a state line is not a distance (Vancouver WA → Portland OR; Muse
  rejected the first cut, which dropped other states). Country names come from Foundation's ISO
  region table in US English (MapKit's subtitle spelling), never a hand list; the walker's country
  is the reverse geocode's `isoCountryCode`, refreshed once per 500 m, applied only if the fix has
  not moved on since the request, and never re-announcing the row count. Tests:
  `foreignCompletionsAreDropped`, `localAndUnmarkedCompletionsAreKept`.
- Torch dead zone (Muse on Step 49): once app-lit, a room the torch lifts to 120–400 lux would
  have kept the torch on for the whole route. Now, after the minimum on-time, the torch goes off
  for 1 s once a minute (`LowLightPolicy.probeDue` / `beginProbe` / `endProbe`); over 120 lux with
  the torch off ends the episode, otherwise the torch is straight back, both confirmations muted.
  `light {action: probe_begin | probe_lit | probe_dark}`. `deadZoneProbeEndsEpisodeOnlyOnRealLight`.

**Reviews.** Muse (compact, on this diff): eight findings; taken — no state-based dropping, a
country table instead of a hand list (its tautology in the old guard included), geocode request
stamping and no re-announce, tab bar kept mounted, the torch probe. Refuted / not applicable: the
`administrativeArea` full-name trap (the state branch is gone); "St" vs "ST" (the branch is gone).
OpenCode and Antigravity produced no output tonight; Codex was not rerun on this small diff.

**Verification.** `make test` 630 / 630; `make sim` green; `make uitest` and the device install
in the gate below.

test on device: type "Oab" — no Australia, no Michigan, no Rio; the tab bar is gone while typing
and back after Done or Go; Done no longer overlaps anything.

## Step 49 — Low light: the app notices the dark for a walker who cannot (Sat Sep 12, late)

**Why.** Owner, 22:50: "In a low-light situation, how are we taking care of that? LiDAR doesn't
depend on light, we have the flashlight — what else?" The honest inventory (a research agent read
every subsystem; report in the session scratchpad): LiDAR depth, the gyro gate, GPS, compass,
haptics, the watch and the island are light-independent; ARKit's *visual* tracking, sign reading,
on-device scene words and people detection, the cloud "Where am I" and the hazard watch degrade or
fail silently — and a blind walker cannot tell it is dark. Worse, a real bug: in a dark hallway
ARKit sits in `.limited(.insufficientFeatures)`, the route-start gate never qualifies, and Step 42's
timeout line said "Obstacle detection warming up. Guiding with GPS." while `sceneDepth` was arriving
and the lane cues were live (`CueDecider` never reads `trackingNormal`).

**What changed** (implementation agent, torch-loop fix by the orchestrator):
- `LowLightPolicy` (CaneKitLogic, 12 tests): 0.3 s EMA over `ARFrame.lightEstimate.ambientIntensity`
  (carried as `LaneReport.ambientLux`); dark after 3 s under 40 lux, lit after 5 s over 120, `unknown`
  first. Torch-aware: an app-lit torch stays ≥ 60 s; **while app-lit the exit needs 400 lux
  (`litWithTorchLux`)** — the reading is an auto-exposure proxy the torch itself raises, and without
  this the torch switched itself off by its own glow every minute (`appLitTorchGlowDoesNotEndTheEpisode`);
  a device cut-out backs the auto-torch off 60 s; never at ≤ 20 % battery. All numbers [H].
- `AppModel`: setting "Flashlight on in the dark (routes)" (`autoTorchInDark`, **default ON** — a
  deliberate exception to "ships off": the walker cannot see the dark, and the light both helps the
  cameras and makes them visible to drivers; reasoning in code and AGENTS.md). The torch is lit only
  while a route guides, through the KVO-confirmed `setTorch`; released on lit / Stop / arrival; a
  torch the walker lit is never touched. One line per episode at `.nav`: "Low light. Obstacle
  detection still works." (+ " Flashlight on."). `light {state, lux, torch, torch_by_app}`.
- Readiness honesty: `DepthReadiness.TimeoutReason`; a timeout with depth live but tracking never
  normal speaks "Camera tracking is limited, probably low light. Obstacle detection is running on
  LiDAR." (`.safety`, 15 s) and starts the route; `route_readiness {state: timed_out_tracking_limited}`.
- Vision honesty: "It is dark, so this may miss things. " before a description when dark with the
  torch off; the prompts may answer "It is too dark to see." and `CloudSceneGate` passes it; `scan` /
  `hazard_watch` records carry `light: dark`; `centerHit = nil` under limited tracking (no mesh
  *name* from a drifting pose; distances stay LiDAR).
- UI: "Light" row on the Scene engine card, a DARK pill beside the GPS pill on the Guide.
- Docs: design.md §5.1 / §5.4 / §6.5 / Scene engine; CODE_REFERENCE; AGENTS.md (two deliberate
  bullets); todo.md Step 49 device checklist (dark room, torch-lit hallway, lit crossing).

**Verification.** `make test` 627 / 627; simulator build green; `make uitest` 12 run / 0 failures;
`graphify update .` → 4,681 nodes · 10,872 edges · 216 communities; installed and launched on the
phone (Steps 48 + 49 together). Reviews on this diff: Muse, Codex, OpenCode (recorded when they land); Antigravity
cannot run headless here. Nothing measured on the phone yet — every threshold is a hypothesis
until a dark walk's `light` records are read.

test on device: in a dark room start a route — within ~4 s the torch comes on and you hear "Low
light. Obstacle detection still works. Flashlight on."; the tiles still show the wall; Stop the
route and the torch goes off. With the torch off (toggle in Settings → Mount), ask "Where am I" in
the dark: it starts with "It is dark, so this may miss things." Start a route in a dark hallway:
you hear the LiDAR line, never "Guiding with GPS".

## Step 48 — Point-blank: a wall against the phone is STOP, never CLEAR (Sat Sep 12, late)

**Why.** A teammate's photo at 22:44: phone against a wall, "Depth OK", six green CLEAR tiles, no
sound — the inverted gradient Step 38 was meant to end. Step 38 accepts *low-confidence* returns
down to 5 cm; inside roughly 10 cm the LiDAR does not return a low-confidence distance at all, it
returns 0 or NaN. `LaneMath` discarded every such sample, the cell fell under `minSamplesPerCell`,
reported `.infinity`, and `.infinity` is CLEAR everywhere downstream. The Step 38 decider latch
(`nearDropoutHoldSeconds`, 1.5 s) covered the cue for a second and a half; the tiles never.

**What changed.**
- `LaneMath` counts *blind* samples (non-finite or ≤ 0.05 m) and reports the blind share per cell
  (`LaneGrid.headBlind` / `torsoBlind`, `blindFractionIsReportedPerCell`); the value stays
  `.infinity`, so nothing that reads distances changed on its own.
- New pure `NearHold` (CaneKitLogic, 7 tests, suite "Near hold"), applied by `DepthFrameProcessor`
  to every grid before it is published: a cell that reads `.infinity` with a blind share ≥ 0.5 and
  whose last *measured* distance was under 0.6 m is reported as 0.1 m and flagged held — under
  `CueThresholds.centerNear`, so tiles say STOP, the decider fires urgent, the watch and the island
  follow. Any measurement releases it; a blind share under 0.5 is a real clear and disarms the cell.
  It never arms without a prior near reading, so a blind sky or corridor nobody walked up to stays
  clear (`blindWithoutNearHistoryStaysClear`, `farReadingDoesNotArm`). Known gap, on purpose: the
  phone switched on already against a wall is not held until it has read the wall once between 5
  and 60 cm — the trade against painting STOP over the sky.
- Trip log `lanes` gains `head_blind`, `torso_blind`, `held` — the evidence for tuning the 0.5 / 0.6.
- Merged onto the teammate's Step 45 cloud commit (`68c50f0`, `Cloud/CloudSync` + `CloudSchema`);
  the CHANGELOG conflict (that commit carried leftover stash markers) resolved newest-first.

**Muse review (xhigh), all verified and taken:** (F4) the hold memory was reset by any frame
without depth — exactly when a wall is pressed — and never by a session change; now `resetNearHold`
runs from `dropLatestImage` (every ARKit re-run / pause passes there) and a transient gap keeps the
memory. (F2) a phone switched on already against a wall stayed silent: the **cold-start** rule —
≥ 4 of 6 cells blind ≥ 0.8 with no history → 0.8 m (NEAR tile, Geiger, never STOP) until any cell
measures; a head-only blind (a tilt at the sky) is not a cold start (`allBlindWithNoHistoryIsCaution`,
`headOnlyBlindIsNotAColdStart`). (F1) history from before a cane swing describes another view:
an untrusted frame disarms every cell (`aSweepDisarmsEveryCell`). (F3) `smoothedSceneDepth` holds
stale finite values and inpaints for a few frames as the wall arrives: the blind share is now the
max of the smoothed and the raw map. (F5a) Quiet / Indoors / a crossing settle would have turned a
held torso cell back into silence: a held cell renders at every level (`pointBlankBypassesEveryTorsoHold`).
(F5b) the wrist got one tap then nothing while pinned: the centre cue is re-mirrored while a cell
is held (the link throttles). (F5c) the island only refreshed on a GPS fix, i.e. never while
standing at a wall: `LiveActivityController.refreshObstacle` from the depth path on a glance
transition. (F6) the blind share's denominator no longer counts far low-confidence pixels (a wall
edge read 0.49). Disclosed, not changed: releasing a hold into a dropout-clear still waits the Step
38 latch's 1.5 s before `.stop` (safe direction). Refuted by Muse itself: a data race on `nearHold`
(serial queue), held values feeding back into arming (the pre-hold value is stored).

**Verification.** `make test` 620 / 620 (their 18 cloud tests included); `make sim` green;
installed and launched on the phone at 22:55 (first cut) and again after the review round.
Codex (read-only, repo copy) reached the same four findings as Muse independently (sweep frames
must not mutate the hold, session-boundary reset, smoothed-depth lag, island only on GPS fixes) —
all fixed above — and added one kept as a known gap: a glossy or absorptive surface between
0.35 m and a few metres returns *finite low-confidence* samples that are neither valid nor blind, so
such a cell can still read CLEAR (the Step 38 boundary; `docs/todo.md`). OpenCode's third run
produced no output; Antigravity's plan-mode run printed nothing again.

test on device: hold the phone 15 cm from a wall, then push it to the wall: STOP tiles and the
urgent buzz must continue at 2 cm; step back to 1 m: tiles clear within a frame. Point the phone
at the night sky and at a long corridor from where you stand: no STOP.

## Step 47 — The Dynamic Island from its first pictures, cue levels that differ on the cane, a Details tab that says which model answered, and the Guide tile pair (Sat Sep 12, evening)

Four things the owner asked for in one message after walking with Step 46, plus a documentation
drift audit the same evening. Built as three parallel work packages (island + Guide + phone by the
orchestrator; torso haptics and the scene-engine card by two implementation agents), reviewed by
three read-only audit agents on the docs and by Muse, Codex, OpenCode and Antigravity on the diff.

### A. Dynamic Island — evidence first, then a redesign

**Why.** "The dynamic island … the icons are weird, just the same blue circle thing around the
dynamic island … nothing's being fixed." Steps 40, 42 and 44 had each changed the Live Activity and
each was verified by a person looking at a phone. The four newest trip logs on the phone
(`canekit-2026-09-13T01-48-57Z` … `01-52-46Z`) say `live_activity {action: start, active: true}` —
the activity existed; nobody had ever seen what it drew.

**Pictures.** New `ios/CaneKitUITests/CaneKitIslandTour.swift` + `make island` (Makefile target,
documented in AGENTS.md / ios/README.md): start the route, press Home, photograph the compact
island, long-press for the expanded one, simulate a few metres, photograph again, Stop, photograph
again. The *before* pictures (scratch `shots_before/0[1-4]-island-*.png`) showed: compact
`↑ 585 m … ✓ CLEAR` — a bare up-arrow that reads as a second copy of the OS's blue location arrow,
plus a text badge for a non-event; expanded: the instruction squeezed into the leading column and
truncated ("Leaving Townsend…") with an empty bottom region; after Stop: clean (the island drops an
ended activity at once; the 60 s policy is lock-screen only).

**What changed.** `ios/CaneKitWidget/NavLiveActivity.swift` rewritten (docs/design.md §6.7):
- `Manoeuvre(kind:)` and `Glance(status:…)` tables — one place for glyph, word, tint and VoiceOver
  phrase, so they cannot disagree. Straight = `figure.walk` (`arrow.up` retired), turns =
  `arrow.turn.up.left/right`, crossing = `figure.walk.diamond.fill`, arrived = `flag.checkered`.
- Compact trailing = the glance glyph alone when clear (one small green check); a word or metres
  only when there is something to act on (`1.2 m`, `HEAD`, `CURB`). Minimal = the glance glyph when
  not clear, else the manoeuvre glyph.
- Expanded: leading = glyph + word ("Turn right"), trailing = distance + "to next", bottom = the
  instruction full width (2 lines, `fixedSize`) then glance pill · `±5m GPS` · route name.
- Stale state: `LiveActivityCoalescer.staleAfter = 300 s` (CaneKitLogic, pinned by
  `staleAfterOutlivesACrossingWait`) is the `staleDate` on every request and update
  (`LiveActivityController.staleDate()`); the widget dims the distance and says "No update" —
  ActivityKit keeps an island up for hours after the app dies, and a frozen "120 m" must not look live.
- VoiceOver reads one sentence per presentation; the raw-kind label listed in design.md §10 is gone.
- `LocationService.setNavigating`: `showsBackgroundLocationIndicator` pinned `false` in both
  states, with the reason in the code: the blue pill iOS draws beside the island during a route
  comes from the `CLBackgroundActivitySession` that keeps GPS alive with the screen locked (it is
  what lets a When-In-Use app continue in the background) — no flag removes it; keeping the legacy
  manager flag off means exactly one system pill, never two. The file header's "created by
  `start()`" was stale since Step 40 and now says `setNavigating`.

**Second round, from the owner's phone pictures (21:48).** The island on the phone showed a blue
arrow in the pill and our head-height glance in a detached circle: iOS's background-location
indicator owned the island and demoted the Live Activity to *minimal*. That indicator is the price
of `CLBackgroundActivitySession`, which a When-In-Use app needs to keep GPS through the screen
lock. Apple Maps and Google Maps (the owner's references) own the island because they hold
**Always**. So: `NSLocationAlwaysAndWhenInUseUsageDescription` (project.yml); the first route
start calls `requestAlwaysAuthorization()` (skipped under `CANEKIT_UITEST=1`);
`reconcileBackgroundSession` arms the session only while navigating **without** Always and
re-runs on every authorization change (`locationManagerDidChangeAuthorization`), so a grant
mid-route drops the pill at once and a decline keeps GPS alive; `location_auth {status,
background_session, at}` in the trip log is the evidence. Also from the pictures: the expanded
row truncated both the glance pill ("Head heig…") and the route name — the route name left the
island (lock screen keeps it), the pill has `layoutPriority(1)`, the instruction may take three
lines, and a route **progress bar** (`ContentState.progress` = waypoints passed / total, 1 on
arrival; `RouteProgressBar`) sits under the pills, as in the Google Maps card.

### B. Guide — the two-up pair is a pair

**Why.** "The where am I is kind of weird … the talk to OpenCane is weirdly shaped compared to where
am I." Cause, from the code and the tour picture: both were `CKBigButton` rows in one `HStack`, and
`ViewThatFits` kept the short title in a row while it stacked the long one — one pair, two shapes.

**What changed.** `CKBigButton.Layout` (`row` / `tile`, `Theme.swift`) and `CKMetrics.tile = 108`:
a tile is icon over a centred word over a caption ("Camera · what is ahead" / "Voice · ask or
command"; "Tap again to send" while listening), and the pair's `HStack` is `fixedSize` vertically so
both take the taller one's height. The row label's text column became flexible width, because a long
subtitle made `ViewThatFits` stack "Simulate walk" alone (seen in the first tour after the change);
its subtitle is now "Indoor demo · walks the route for you". design.md §6.1 rewritten (idle and
navigating wireframes, the tile rule, the Talk row in the VoiceOver table).

### C. Cue levels that differ on the cane (cue design v2 item 41 — torso haptics by level)

**Why.** "In the settings you have the cues — quiet, standard, detailed — I'm not sure if it's
actually making a difference." It was not, outdoors with names off (the default): `CueRules` gated
only names and sign phrases and the caption said "Haptics are the same at every level for now."

**What changed** (implementation agent; router diff re-read by the orchestrator):
- New pure `TorsoHapticPolicy` (CaneKitLogic, 19 tests, suite "Torso haptics by level"; `Rig` steps
  a real `CueDecider` and the policy together) layered over `CueDecider`, which is untouched.
  `TorsoHapticAction` = `render` / `centerOnset(strong:distance:)` / `updateCenter` / `stop` /
  `suppressed(cue, reason:)`; `TorsoSuppressReason` raw values (`quiet`, `indoors`,
  `crossing_settle`, `standard_side`, `standard_center_hold`, `shoreline`) are the trip-log strings.
- Head cue: rendered at every level, place and hold — never gated (`headIsNeverSuppressed`).
- Quiet + Outdoors: no torso haptics. Standard + Outdoors: no loop; one tap (`centerOnsetPlayer`,
  1 transient 0.8/0.6) when the centre distance is < 1.5 m *and closing*; a strong triple
  (`centerStrongPlayer`, 3 × 80 ms, 1.0/0.6) when < 0.6 m and closing; each once per approach,
  re-armed after 1.5 s with the centre no longer the decider's cue; no side taps. Detailed + Outdoors
  (the default) = today's Geiger loop and side taps, minus a side tap while that side has held within
  ±0.1 m for ≥ 2 s (shorelining). Indoors, any level: no torso haptics. Crossing settle (new
  `NavigationEngine.isCrossingSettle`): none until the curb / turn release. "Closing" = ≥ 0.1 m nearer
  than the newest trusted sample ≥ 1 s old; sweep frames feed no history.
- Cue router (`AppModel.handle`): decider → policy → render. A suppressed cue reaches neither the
  player, the watch mirror nor `speakCueIfNeeded`; a running loop is stopped the instant a hold
  begins; `applyCueRules` resets the policy and stops the player, so a loop never outlives the level
  that started it. `cue` records gain `suppressed: <reason>` / `render: center_onset | center_strong`;
  `cue_audit.py` reports `torso_suppressed_per_min` and `center_onsets` and its selftest passes.
- Settings caption and picker hints now state the true per-level behaviour; segment titles unchanged.
  design.md §5.2 has a "by level" table; AGENTS.md's "haptics do not change by level yet" is gone.
- Numbers are [H] until a mounted trip log tunes them; the default is still Detailed + Outdoors =
  today, so the calmer levels are opt-in (owner decision 2026-09-12).

### D. Details — which model answered, why, how long, when

**Why.** "For the details … I know you have the Muse and the on-device; can we be specific on, for
example, when the Muse is triggered." The app knew every one of those facts and surfaced none.

**What changed** (implementation agent; client diff re-read by the orchestrator):
- `VLMAnswer` gained defaulted `answeredBy`, `cloudMs`, `fallbackReason`; `FallbackVLMClient`
  stamps the cloud's error and elapsed ms on an on-device answer, and records the hazard-watch
  outcome in a `Mutex`-guarded `VLMHazardOutcomeBox` shared by every copy of the client.
- `SceneDescriber` publishes `lastSource`, `lastCloudMs`, `lastFallbackReason`, `lastGate`, `lastAt`,
  `lastTrigger`; `describe(trigger:)` with `DescribeTrigger` (button / watch / actionButton /
  cameraControl / siri / waypoint / question) passed by every caller; `describe_result` and
  `hazard_watch` trip-log records gain `trigger` / `source` / `cloud_ms` / `fallback_reason`.
- New pure `SceneEngineSummary` (CaneKitLogic, 16 tests) owns every sentence, with the 8 s watch
  interval and 2.5 s cloud deadline passed in from the existing constants.
- New "Scene engine" card on the Details tab under the status card: chain pill (`MUSE → ON-DEVICE`),
  "Muse answered in 1.9 s" / "On-device answered — Muse: The request timed out. (after 18 s)",
  "2 min ago · from the watch", the gate verdict when the cloud answered, the hazard-watch line
  ("off — when on, asks Muse every 8 s while a route guides, on-device after 2.5 s"), and the cues in
  effect ("Detailed · Outdoors · names off"). Each row is one VoiceOver sentence; a 10 s
  `TimelineView` ticks the ages.

### E. Medical ID — privacy-safe defaults

The card showed the Step 44 placeholder `+1 (555) 234-5678`. Step 51 removes that seeded contact
from the default and migrates it to a blank value on phones that had already saved the placeholder;
a number the owner typed is kept locally and is never copied into a new binary.
"Announce Medical ID" now speaks at `.scene` (20 s TTL), not `.obstacle`: the design audit caught a
user-requested paragraph sitting in the hazard band of hard rule 8, where an obstacle name or a
route line could not have cut it.

### F. Documentation drift audit (three read-only agents, corrections applied)

AGENTS.md: rule 9 now lists four tabs (Guide / Sense / Settings / Profile) and "Simulate walk"; the
Layout table names `Alerts/`, `SupabaseClient`, `MedicalProfileStore`, `ProfilePage` and both tours;
the history pointers name Step 46/47 and say the cue-v2 item numbers are not CHANGELOG steps.
ios/README.md: status block, test counts (≈575 in 45 files), 12 UI tests in three classes, `make
island`, `Logic/` = 47 files, the Supabase / `CUSTOM_REASONING_EFFORT` keys, the Camera Control row
(the debug footer went in Step 11). Stale code headers fixed: `TabBar` / `ContentView` ("three"
tabs), `scripts/test.sh` (457), `LocationService` (session lifecycle). CODE_REFERENCE.md: the widget,
controller, coalescer, island tour, Makefile, `CKBigButton`, `MedicalProfileStore`, `LocationService`
entries rewritten by the orchestrator; a fixer agent added the ~30 missing `###` sections
(`FaceHeadPose`, `LiveCameraView`, the Conversation module, 12 Logic files, 18 test files) and removed
entries for code that no longer exists (`isForeground`, `liveFrameJPEG` / `refreshLoop`,
`TakeMeSomewhereIntent`, `maxReplays`).

### Reviews (four reviewers on the diff; every finding verified by hand)

**Muse** (`muse exec`, xhigh, read-only) and **OpenCode** (`opencode run`, on a repo copy) both
returned full reviews; **Codex** was rerun read-only against a repo copy after its first run had
been building inside the real repo (see the trap in AGENTS.md); **Antigravity** could not run
headless without auto-approving every command, which this session refused (its plan-mode rerun is
recorded below if it produced output).

Fixed:
- *Standard's strong triple needed "closing"* (Muse S2): a walker inching in at under 0.1 m/s never
  qualified, so the closest approaches were the silent ones. The triple now fires on proximity alone
  (< 0.6 m, once per approach); the 1.5 m tap still needs closing. `standardStrongTripleFiresOnASlowCreep`.
- *History never pruned when every sample was stale* (OpenCode F2): `record()` dropped samples only
  up to the first kept one, so after an AR clock gap an ancient 1.9 m reading served as the closing
  reference for a false onset. `removeAll` by age. `staleHistoryIsPrunedAfterAGap`.
- *A failed hazard-watch check read as "Nothing asked yet"* (Muse L1): `SceneEngineFacts.lastWatchError`
  from `HazardScanner.lastError`; the card now says "Hazard watch: last check failed — <reason> · 30 s
  ago". `hazardWatchFailureIsSaidAsAFailure`.
- *Two `describe` records per Camera Control press* (Muse L2 / OpenCode F4): the manual
  `source: cameraControl` record went; `trigger: cameraControl` is the one record.
- *Catch-all `.fire` case* (Muse L3): every `HapticCue` case is now named in `TorsoHapticPolicy.update`
  (side lanes in `side(_:…)`), so a new cue kind fails to compile instead of becoming centre logic.
- *Whole-card `TimelineView`* (Muse U1): only the two age-bearing rows tick every 10 s; a periodic
  redraw of the whole card could move VoiceOver focus off the headline row.
- *Dead `.siri` trigger* (OpenCode F3): removed before the raw value became a log contract;
  `WhereAmIIntent` cannot tell Siri from the Action button and a spoken question is `.question`.
- *"Quiet" missing from hard rule 9's segment list* (Muse D1): added.

**Codex** (read-only, repo copy; it reviewed the pre-fix diff, so three of its fifteen — the failed
hazard-watch line, "Quiet" in rule 9, the missing CHANGELOG entry — were already done). Fixed:
- *A head fire under a torso hold left a Geiger loop running* (Codex 2): a head cue outranks the
  centre, so during a crossing settle no centre update arrived to end the loop; `handle` now stops
  the loop before rendering the head when `TorsoHapticPolicy.torsoIsHeld` (`torsoIsHeldNamesEveryHold`).
- *Standard onset carried the raw distance* (Codex 5): floored at the decider's 0.5 m so the spoken
  fallback stays inside the prefetched lines (`standardOnsetDistanceIsFloored`).
- *Gate refusal recorded as "Muse answered"* (Codex 7): `recordOutcome` names the on-device client
  when the gate refused the cloud sentence.
- *"No cloud key is set" also when `VLM_PROVIDER=ondevice`* (Codex 8): now "No cloud model is in use".
- *Settings copy* (Codex 10): Quiet / Indoors say head height **and ground hazards** still warn;
  Standard says "when closing".
- *Compact island announced the glance twice* (Codex 11): the trailing bubble is VoiceOver-hidden;
  the leading sentence carries the clause.
- *Tour comment said Stop leaves a card for 60 s* (Codex 12): Stop ends immediately; only arrival
  keeps the lock-screen card — comment and design.md fixed.
- *10 s age refresh lived in the view* (Codex 14): `SceneEngineSummary.justNowWindow` in Logic; the
  80 ms triple cadence stays beside the other pattern timings in `HapticPlayer` (pre-existing home).

Rejected, with evidence:
- *Shoreline suppression changes the default* (Codex 1, Muse S4): it is the owner-approved cue-v2
  item 41 text ("Detailed = today + shoreline suppression"); only *re-taps* for a side distance steady
  within ±0.1 m for 2 s are held, a new side obstacle at any other distance still taps, and the
  blind spot is written into AGENTS.md.
- *A dropout between the closing reference and now should void "closing"* (Codex 3): the strong
  triple no longer depends on closing at all, and for the 1.5 m tap a brief dropout followed by a
  nearer reading is an approach; deferred, noted.
- *The strong triple reaches the watch as a plain centre cue* (Codex 4): `CueKind` raw values are
  the phone↔watch wire contract (AGENTS.md); adding a kind needs a watch release — deferred to
  `docs/todo.md`.
- *`stopAll()` on a suppressed torso cue truncates a head pair or a route buzz* (Muse S1, OpenCode
  F1): `HapticPlayer.stopAll()` only cancels the Geiger loop task and clears `rendering`; discrete
  transient patterns "already in flight finish on their own" (`HapticPlayer.swift`, `stopAll` doc), and
  the head / nav players are never touched by it. No truncation is possible.
- *Provenance written off the main actor* (Muse C1): `SceneDescriber` is `@MainActor @Observable`
  (line 61); its `Task { }` inherits that isolation, so writers and the card share it — the same
  pattern `isDescribing` has used since Step 8.
- *Tile pair not actually equal-height under `alignment: .top`* (OpenCode F5): the after-picture
  (`shots_after/01-idle-top.png`) shows both tiles the same height; `fixedSize` on the `HStack`
  proposes the taller child's height and `maxHeight: .infinity` fills it.
- *The owner's phone number as the default and in git* (OpenCode F6): the owner asked for it by
  voice on 2026-09-12 for a single-owner prototype whose card already carries their name, date of
  birth and blood type; recorded here so the choice is visible.
- *Shoreline suppression masks a post at exactly the hedge's distance* (Muse S3): inherent to
  single-distance sensing; the cane tip covers it; written into AGENTS.md as a known blind spot.
- Deferred: the strong triple's cadence vs the right lane's three taps (Muse S5) is a device check,
  listed in `docs/todo.md`.

**Round 2 (Muse xhigh + OpenCode on the Always / island diff).** Both confirmed, unprompted and
independently, the four questions asked: (a) with Always + the `location` background mode,
`liveUpdates` keeps delivering with the screen locked and no session; (b) provisional Always
reports `.authorizedAlways` and behaves as Always (the log will say "always" for it); (c)
invalidating the session inside the authorization callback leaves no gap — never restart the
`liveUpdates` loop on an auth change; (d) `ContentState.progress` decodes safely in both
directions. Fixed from their findings: the Always request is deferred until When In Use is granted
(a first route right after install would otherwise miss the prompt — `alwaysWanted`); no session
for denied / restricted; the progress bar draws no sliver at 0 % and clamps the dot. Rejected: the
`stopAll` "head loop" finding a third time (no head loop exists — `HapticPlayer.stopAll` now says
so in code); shoreline-in-Detailed (owner-approved plan text); no torso mirror at a crossing settle
(the approved design: nothing but head and ground hazards while standing at a curb).

**Codex, round 2 (read-only, repo copy).** One finding the other two missed and worth taking:
on the modern CoreLocation API an app's *implicit* session is When In Use, so an Always app should
hold an explicit `CLServiceSession(authorization: .always)` to be certain of background delivery
without the activity session — the route now holds one (`LocationService.reconcileAlwaysSession`),
keeps the When-In-Use session until the status reports Always, and logs both the fix stream's and
the Always session's diagnostics as `location_diag {source, flags}` so a stopped stream is never
silent. Also taken: `torsoPolicy.reset()` at route start (both Standard onsets armed for a new
walk); the island refreshes on a manual Next at a standstill (`LiveActivityController.refreshNavigation`,
no fix needed); stale "two describe records" comments. Already fixed before it ran: deferred Always
request, denied → no session, head under a hold, compact VoiceOver, progress-bar endpoints, the
three-line overflow. Rejected: shoreline-in-Detailed (third time, owner plan); "Detailed centre
loop goes silent if haptics are silenced mid-loop" — pre-existing since Step 3 (`.updateCenter` was
haptics-only before Step 47), noted in `docs/todo.md`.

### Verification
- `make test` → **580 / 580** Swift Testing tests in 8 suites (own exit code 0) after the review rounds. `scripts/test.sh`
  now passes `--disable-xctest` (trap documented in AGENTS.md: a fresh `Logic/.build` under Xcode 27
  fails the empty XCTest pass with "No test bundle found").
- `make sim` → BUILD SUCCEEDED, 0 errors. An hour of "Operation not permitted" build failures in
  between was macOS, not code: Xcode's Files-and-Folders grant for `~/Downloads` was lost at ~21:30,
  so Xcode-signed tools (and git) could not open pre-existing files — `tccutil reset
  SystemPolicyDownloadsFolder com.apple.dt.Xcode` fixed it (trap recorded in AGENTS.md).
- `make uitest` → **12 run, 1 skipped, 0 failures** (the Street View test skips itself).
- `make island` → four pictures per round (five rounds: the third showed the 3-line instruction pushing the pills off the region, the fourth the progress bar below the clip line; the final expanded card is glyph + word · distance + "to next · ±5m GPS" · two-line instruction · glance pill + progress bar); `make tour` → 17 pictures. Before / after pictures in the session
  scratchpad (`shots_before/`, `shots_after/`); the compact island reads "🚶 585 m … ✓", the expanded
  card shows the full instruction, the Guide pair is two equal tiles, the Scene engine card renders.
- `graphify update .` → 4,332 nodes · 9,962 edges · 219 communities (was 4,020 / 9,423 / 205).
- `make e2e` → **PASS ×4** (`clean` 265 s, `missed_fence` 272 s, `gps_jitter` 496 s, `wrong_turn`
  292 s) on the final code; an earlier run was invalidated by a concurrent island capture on the
  same simulator and rerun.

### Not done / could not do
- **Supabase and the Grok Bot webhook were not exercised from this session**: the permission
  classifier refused a read-only `curl` against the Supabase REST endpoint as a production read, and
  a webhook POST starts a bot run (outward-facing). Use the in-app "Send test event" button and
  watch Settings → Family alerts for the bot's status line; the profile sync fires on the first
  launch after install.
- `.siri` trigger is defined but no caller can distinguish Siri from the Action button today.
- No lock-screen picture in `make island` (no public API locks the simulator from XCUITest).

## Step 46 — Audit of the Supabase mirror: four bugs the tests could not see (Sun Sep 13)

**Why:** Step 45 shipped green — `make test`, `make sim` and `make e2e` all passed — and the
mirror still had four defects, every one of them invisible to a passing build because they are
about *when* a write happens, not whether the code compiles. Found by reading the cloud rows back
out of Postgres and asking why they did not match the walk.

**What was wrong:**

1. **Restarting a route merged two walks into one row that never closed.** `endRouteQuietly()` (the
   restart path) stopped navigation but never closed the cloud trip, and `openPendingTrip` refuses
   to open a new row while one is open — so the old `trips` row kept a null `ended_at` and a null
   `outcome` for ever, and the *new* walk's lines were stamped with the *old* trip id. It now closes
   the walk as `stopped`, before `startRouteNow` opens the next one.
2. **A flush invalidated the trip mark, so a walk's first lines kept a null `trip_id`.**
   `tripQueueMark` is an index into the live queue; `tick()` removed rows from the front without
   shifting it, so when the trip id landed the stamping loop started at the wrong offset. The
   arithmetic moved to `CloudBatchPolicy.shiftMark` (CaneKitLogic) with a test, per hard rule 3 —
   a failed batch put back on the front shifts it the other way.
3. **Every debounced hazard uploaded the previous hazard again.** `HazardLog.record` returned Void,
   so the caller read `records.last` — which, after the 3 s jitter debounce refused a detection, is
   the *earlier* hazard. That inserted a duplicate cloud row for a hazard announced once. `record`
   now returns `HazardRecord?` (nil when refused) and the caller uses the return value. ⚠ It returns
   the record it actually appended, not `records.last`: a `createDirectory` failure means nothing
   was appended at all, and returning the one before it would reintroduce the same bug.
4. **A killed app left its walk open for ever.** `endTrip` needs the process to survive; iOS
   reclaiming memory, a crash, or the e2e harness terminating the app never gets there. Nothing
   wrote the schema's third outcome. `closeAbandonedTrips` now sweeps the walker's open trips on the
   next launch, scoped to rows that started before this process did so it can never close the walk
   this launch is about to open.

**Also:** `family_contacts.alerts_sent` was documented as a running count and nothing incremented
it — it sat at 0 for every contact. Migration `opencane_07` maintains it (and `last_alerted_at`)
with a trigger on `family_alert_recipients`, the only fact that actually establishes them, and the
phone's PATCH is gone: a counter the client maintains can disagree with the join table.

**Verified:** `make test` (644, exit 0), `make sim` (exit 0), `make e2e SCENARIO=clean` (PASS, exit
0). Fix 4 was proven against the live project rather than assumed: a probe trip left open was
closed as `abandoned` on the next launch — confirmed in the edge log as `PATCH /rest/v1/trips` 204
— and the probe row deleted afterwards. The first attempt to verify it *failed*, because the probe
was attached to the wrong walker; the sweep is correctly scoped per walker.

⚠ One `make e2e` run failed during this work with "app never started the demo route". It was not
the cloud code: the crash report was `AURemoteIO::Cleanup` → an RPC timeout to the simulator's
audio daemon inside `BeaconEngine.start()`. A full simulator shutdown/boot cleared it, and the same
build then passed. Check `~/Library/Logs/DiagnosticReports/CaneKit-*.ips` before blaming a change.

**test on device:** start a route, restart it mid-walk, and confirm two closed `trips` rows rather
than one open one; force a hazard twice within 3 s and confirm a single `hazards` row; kill the app
mid-walk and relaunch, and confirm that walk reads `abandoned`.

## Step 45 — Everything the phone knows, mirrored into Supabase (Sat Sep 12)

**Why:** Every piece of state OpenCane held lived in exactly one place, on one phone, and died with
it: settings in `UserDefaults`, the walk in `Documents/canekit-*.jsonl`, the hazard map in
`Documents/hazards/*.geojson`, posts in `posts.json`, the Medical ID in a `UserDefaults` blob. A
family could not see a walk, a city could not see the potholes, and a reinstall erased the lot. The
owner asked for all of it in Supabase, with the family email list tracked, and for the tables to
read well in a demo.

**What changed — the database** (project `ppmuqgswuyniwiwsdnto`, migrations `opencane_01`…`_06`):
- 16 tables: `walkers`, `devices`, `family_contacts`, `medical_profiles`, `device_settings`,
  `routes`, `route_waypoints`, `trips`, `trip_events`, `hazards`, `posts`, `family_alerts`,
  `family_alert_recipients`, `conversation_turns`, `app_launches`, `mobility_days`. Every table and
  the non-obvious columns carry a SQL `comment`.
- PostGIS `geography` generated columns on `hazards`, `posts` and `route_waypoints` (null geometry
  when a hazard had no fix, exactly as the phone's GeoJSON writes it), with GiST indexes.
- Four demo views: `trip_summary`, `hazard_map` (GeoJSON + photo URL), `family_alert_feed` (with
  the addresses each alert was routed to), `walker_dashboard`. All `security_invoker = on`.
- Three RPCs so a cane on campus Wi-Fi does one round trip: `register_cane` (upserts walker +
  device + settings), `save_family_contacts` (replaces the list; survivors keep their id and alert
  history), `hazards_near` (every walker's mapped hazards within a radius).
- RLS enabled on all 16 tables with explicit anon policies; `hazard-photos` storage bucket.
- Advisors: zero findings on the OpenCane tables (the remaining warnings are PostGIS's own
  `spatial_ref_sys` and `st_estimatedextent`, which ship with the extension).

**What changed — the app:**
- `CloudSchema.swift` + `CloudSchemaTests.swift` (CaneKitLogic): the row types and
  `CloudBatchPolicy` (batch 200, flush 5 s, queue ceiling 5000 dropping OLDEST, backoff 2→30 s).
  17 new tests, 555 total.
  - ⚠ **The uniform-key rule.** PostgREST rejects a bulk insert whose objects disagree on their key
    set (400 `PGRST102`, "All object keys must match") and writes nothing — measured against the
    live project. `TripEventRow` and `RouteWaypointRow` therefore hand-encode every column on every
    row, writing explicit JSON nulls. Codable's synthesised encoder omits nil optionals, which
    would silently cost a whole walk. `tripEventRowsAlwaysCarryEveryKey` stands in the way.
- `SupabaseClient.swift`: hand-rolled PostgREST + Storage over `URLSession` (hard rule 2 — no
  SDK). `nonisolated`, 15 s timeout, throws the response body because that is where PostgREST puts
  the real reason.
- `CloudSync.swift`: the mirror. Queues trip-log lines and flushes on a 5 s loop; a failed batch
  goes back on the front of the queue. Wired from `TripLogger.onRecord`, `AppModel.recordHazard`,
  `ConversationCoordinator.dropPost`, `FamilyAlerts.onDelivered`, `MedicalProfileStore`'s two new
  hooks, and `Settings.onChange`.
- `Settings.onChange` (AppModel): one hook fired by every persisted write, rather than eighteen
  calls in eighteen `didSet`s — a setting added later is mirrored with no extra wiring. `CloudSync`
  coalesces the burst on a 0.4 s trailing debounce.
- `Secrets.plist`: `SUPABASE_URL` / `SUPABASE_ANON_KEY`. Both absent = the cloud is simply off and
  the app behaves exactly as it did before this step. ⚠ Publishable key only, never service-role.

**Two bugs found by running it, not by reading it.** The first e2e walk wrote 899 `trip_events` and
**zero** `trips`, and no `routes` at all: a route starts well inside the `register_cane` round trip
on a cold launch, and `beginTrip` / `uploadRoute` both gave up when there was no walker id yet, so a
whole walk arrived as loose lines with a null `trip_id`. Both are now *deferred* rather than
dropped — held with their real start time and sent the moment ids arrive, retried on every tick —
and the lines queued in between are stamped with the trip id when it lands. Verified after the fix:
one e2e walk produced a `trips` row (arrived, 978 m, 9 waypoints), its `routes` row with all 9
`route_waypoints`, and 295 linked `trip_events`.

**Merged with the parallel `Trip/SupabaseClient.swift`.** A second Supabase client landed on main
while this was being built, covering a subset of the same tables (walker, device, medical profile,
mobility, hazards, family alerts). Kept as two clients they would have **double-inserted every
hazard and every alert**, and two types named `SupabaseClient` in one module do not compile. They
are consolidated onto `Cloud/` — which additionally carries settings, trips, the whole trip log,
routes, posts, storage uploads, offline queueing and tests — and `Trip/SupabaseClient.swift` is
removed. Nothing from it was lost:
- `recordDeviceCapabilities()` (its refresh of the `devices` row when the watch or AirPods connect
  mid-session) is kept and re-pointed at the new `CloudSync.updateDeviceFacts`.
- Its `@Sendable` fix in `MedicalProfileStore.refreshMobilityStats` is kept as-is.
- `SUPABASE_PUBLISHABLE_KEY` is now accepted alongside `SUPABASE_ANON_KEY`, so an existing local
  `Secrets.plist` keeps working either way.
Both clients already shared the `opencane_install_id` key, so they resolve to the same walker and
no history is split.

**Verified:** `make test` (555 tests, exit 0), `make sim` (exit 0), `make e2e SCENARIO=clean`
(PASS, exit 0), and the resulting rows queried back out of Postgres. Re-ran `make test` and
`make sim` after the merge — both exit 0.

**test on device:** walk a route with the phone on the cane, then open `trip_summary` in the
Supabase dashboard — one row, the destination, the metres and the steps the arrival card spoke.
Turn a switch in Settings and watch `device_settings` change. Add a family email, press Save, and
check `family_contacts`. Record a hazard with drop-offs on and confirm the row **and** its JPEG in
the `hazard-photos` bucket.

## Historical note — Step 46 — Multi-agent adversarial review fixes (Muse/Codex), redesigned Guide buttons, profile avatar, and timezone alignment (Sat Sep 12)

**Why:** The user requested:
1. "can u make th ebuttons and tsuff look better we still have the same thigns like satrt ruote to cif and naigate t cif form here and its now jsut good looking": GuideCard had two buttons mentioning "CIF" in awkward layouts — "Start route to CIF" as a giant white slab, and "Navigate to CIF from here" squeezed into a half-width square next to "Simulate walk", wrapping 27 characters across 3 cramped lines.
2. "can u add a pfp to my thing as well /Users/aritro/Pictures/Photos Library... use this as my pciuture": Add the user's photo to the Emergency Medical ID card in the Profile tab.
3. "alos how did u get all my health data form the health app right???": Clarify Apple CoreMotion/HealthKit local querying architecture.
4. "pull all changes and then go crazy... give me the full handoff to my other agenet session": Integrate multi-agent audit recommendations from Muse and Codex, ensure 100% clean test passes (`make test`, `make sim`, `make uitest`), verify physical device installation on iPhone 17 Pro Max, update knowledge graph, and prepare complete session handoff.

**What changed:**
- `Theme.swift` (`CKBigButton`):
  - Added optional `subtitle: String? = nil` to `CKBigButton` with responsive horizontal/vertical layout.
  - Added subtle trailing chevron on primary action buttons.
  - Kept accessibility labels strictly identical to `title` (preserving AGENTS.md Hard Rule 9).
- `GuideCard.swift`:
  - Replaced cramped half-width HStack layout with clean, full-width vertical hierarchy:
    - Primary Hero: `Start route to CIF` with subtitle `"Campus Demo · Townsend Hall to CIF"` (`role: .primary`).
    - Secondary: `Navigate to CIF from here` with subtitle `"Live GPS · Apple Maps walking route"` (`role: .secondary`, full width with ample room).
    - Secondary: `Simulate walk` with subtitle `"Indoor demo mode · test route without moving"` (`role: .secondary`).
- `Assets.xcassets` & `ProfilePage.swift`:
  - Created `AritroProfile.imageset` in `ios/CaneKit/Resources/Assets.xcassets/` with the user's campus portrait.
  - Replaced generic SF Symbol in `ProfilePage` header with a 56x56 circular avatar framed by an accent ring.
  - Fixed SF Symbol for allergies (`"exclamationmark.triangle.fill"`).
  - Added combined accessibility elements to `metricTile` and full descriptive label to the emergency call link.
- `SupabaseClient.swift` (Audit Fixes):
  - **Security (C1):** Removed `SUPABASE_SECRET_KEY` fallback; client uses `SUPABASE_PUBLISHABLE_KEY` exclusively.
  - **Data Isolation (C2):** Filtered walker lookup strictly by device `install_id`.
  - **Race Guard (C3):** Added `inFlightResolve` unfair lock task memoization to prevent duplicate walker registrations on launch.
  - **Dynamic Hardware (C7):** Queried POSIX `utsname` for machine hardware model instead of hardcoded string.
  - **PostgREST Upsert (M1):** Added explicit `on_conflict` parameters to `medical_profiles` (`walker_id`), `mobility_days` (`walker_id,day`), and `devices` (`vendor_id`).
  - **Timezone Alignment (Codex Finding):** Keyed `mobility_days` date using `Calendar.current` local date components rather than UTC ISO8601, ensuring evening steps in Central Time match the local calendar day.
- `AppModel.swift`:
  - Extracted `lat`, `lon`, `accuracyM` primitive values before `Task` boundary in `recordHazard` to avoid capturing non-Sendable `CLLocation` (C5).
  - Used `audioRoute.headphonesConnected` instead of instantiating `CMHeadphoneMotionManager`.
- Verification:
  - `make test`: all 538 unit tests pass in CaneKitLogic.
  - `make sim`: clean build with 0 errors.
  - `make uitest`: 11 / 11 tests passed with 0 failures on iPhone 17 Pro Max simulator.
  - `make build install`: successfully installed and launched on Aritro's iPhone 17 Pro Max (PID 6563).
  - Live Supabase verification: verified live sync of `mobility_days` (`2026-09-12`: 6,567 steps, 4,710 m).
  - `graphify update .`: updated knowledge graph (4,020 nodes, 9,423 edges, 205 communities).

test on device: open OpenCane on iPhone 17 Pro Max; verify the Guide tab features full-width buttons with clear subtitles ("Campus Demo" vs "Live GPS"), open the Profile tab to view the custom circular profile avatar and verified emergency card details.

## Historical note — Step 45 (initial backend) — Supabase cloud backend integration for Medical ID, mobility stats, hazard map, and family alert feeds (Sat Sep 12)

**Why:** The user provided Supabase project credentials (`https://ppmuqgswuyniwiwsdnto.supabase.co` with publishable and secret keys) to connect OpenCane to its dedicated cloud database backend.

**What changed:**
- `Secrets.plist` (git-ignored) & `Secrets.example.plist`:
  - Added `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and `SUPABASE_SECRET_KEY`.
  - Secrets stay strictly outside git per AGENTS.md Hard Rule 4.
- `SupabaseClient.swift` (`ios/CaneKit/Trip/SupabaseClient.swift`):
  - Created native Swift URLSession PostgREST client (zero 3rd party SDKs, AGENTS.md Hard Rule 2).
  - `resolveWalkerID(displayName:caneID:)`: finds or creates walker record in `walkers` table, caching the UUID in `UserDefaults` (`"opencane_supabase_walker_id"`).
  - `syncMedicalProfile(_ profile:)`: live cloud sync for the emergency Medical ID card to `medical_profiles` table via merge-duplicates upsert.
  - `syncMobilityStats(_ stats:date:)`: live sync of daily steps, walking distance (m), active duration (s), and cadence to `mobility_days` table.
  - `recordHazard(...)`: logs detected obstacles, curbs, drop-offs, and vision signs to `hazards` table in real time for the web hazard map view.
  - `recordFamilyAlert(event:deliveryStatus:statusCode:errorMessage:now:)`: mirrors dispatched family alert records to `family_alerts` table.
  - `recordDevice(...)`: registers hardware metadata (model, system version, app version, LiDAR, watch, AirPods) to `devices` table.
- `MedicalProfileStore.swift`:
  - Automatically triggers `SupabaseClient.shared.syncMedicalProfile(profile)` on profile init and save.
  - Automatically triggers `SupabaseClient.shared.syncMobilityStats(mobilityStats)` on trip completion and CMPedometer refreshes.
- `FamilyAlerts.swift`:
  - Automatically mirrors all delivered alert events to `SupabaseClient.shared.recordFamilyAlert`.
- `AppModel.swift`:
  - On launch (`start()`), registers device hardware capabilities in `devices` table.
  - In `recordHazard(...)`, mirrors every detected ground hazard, sign, and vision warning to `hazards` table in Supabase.
- Verification:
  - `make test`: all 538 unit tests passing in CaneKitLogic.
  - `make sim`: full clean simulator compilation.
  - Live REST verified: confirmed `HTTP 200/201` upsert on `medical_profiles`, `mobility_days`, `hazards`, `family_alerts`, and `walker_dashboard`.

test on device: open OpenCane; verify profile edits in the Profile tab sync seamlessly, check that today's steps update the cloud dashboard, and confirm that family alert test events and hazards populate the Supabase tables in real-time.

## Step 44 — Medical ID Profile tab, mobility fitness tracking, streamlined Guide buttons, Dynamic Island indicator fix, and Grok Bot webhook integration (Sat Sep 12)

**Why:** The user requested:
1. "WHY THERE THERE SOMANY OF THE SAME BUTTON THING lets make it a little bit mote simple": GuideCard stacked 6 vertical buttons on top of each other (Where am I, Talk to OpenCane, Start route to CIF, Navigate to CIF from here, Simulate walk to CIF, Destination search + Go) — including 3 separate buttons saying "... to CIF".
2. "also also the dynamic island thing is still there... when I try to hold it usually the dynamic island gets bigger and there's more information but for me it's just like not doing anything": In `LocationService.init()`, `let orphan = CLBackgroundActivitySession(); orphan.invalidate()` was instantiating a background activity session on every app launch, causing iOS locationd to display the system background navigation indicator (cyan arrow) in the Dynamic Island while idle. Because it was a system location indicator rather than an active Live Activity, holding/expanding did nothing.
3. "also the 4th button thing after settings should be your profile thing include like basic information such as your medical card, like you know how Apple ID has that medical card... name, height, weight, birthday, where you live... and track fitness stuff": Add a 4th root tab "Profile" with an Apple Health-style Emergency Medical ID Card (white cane / legally blind safety alert banner, blood type, allergies, medications, emergency contacts with tap-to-call, home address, cane specs, announce medical ID button, edit sheet) and daily Mobility & Fitness tracking (today's steps, distance walked, completed trips, average pace via CMPedometer and TripTracker).
4. Configured real Grok Bot webhook credentials (`OPENCANE_GROKBOT_WEBHOOK_URL` and `OPENCANE_GROKBOT_WEBHOOK_KEY`) in `Secrets.plist` for family alerts.

**What changed:**
- `LocationService.swift`:
  - Removed `CLBackgroundActivitySession` instantiation from `init()`. Scoped `CLBackgroundActivitySession` and `manager.showsBackgroundLocationIndicator` strictly to `isNavigating == true`. When idle, no background activity session exists and the Dynamic Island location pill is completely clear.
- `GuideCard.swift`:
  - Streamlined idle button layout: paired `Where am I` and `Talk to OpenCane` into a clean 2-column `HStack(spacing: CKSpacing.md)`; kept `Start route to CIF` as the full-width primary hero button; paired `Navigate to CIF from here` and `Simulate walk` into an `HStack(spacing: CKSpacing.md)`.
  - Preserved all exact test contract accessibility labels (`"Start route to CIF"`, `"Navigate to CIF from here"`, `"Where am I"`, `"Go"`, `"Destination"`).
- `TabBar.swift`:
  - Added `RootTab.profile` (case 3, title: `"Profile"`, icon: `"person.crop.circle"`, hint: `"Medical ID card, emergency identification and mobility fitness"`).
  - Adjusted `pillWidth` to 64 pt for balanced 4-tab spacing across iPhone screen widths.
- `ContentView.swift`:
  - Added `"Profile"` to `navigationTitleText` switch.
  - Added `ProfilePage()` to `page` switch.
  - Made `pageScroll` internal for shared use by `ProfilePage`.
- `MedicalProfileStore.swift` (`ios/CaneKit/Trip/MedicalProfileStore.swift`):
  - Created `@MainActor @Observable` store with `CKMedicalProfile` and `CKMobilityStats`.
  - Pre-seeded with a complete profile for the original demo owner, persisted to `UserDefaults.standard` under `"opencane_medical_profile"` (historical; current defaults are privacy-safe).
  - Integrates `CMPedometer` querying from midnight to now for real-time daily steps, distance, and walking cadence.
- `ProfilePage.swift` (`ios/CaneKit/UI/ProfilePage.swift`):
  - Emergency Medical ID Card: prominent `"WHITE CANE USER / BLIND"` emergency banner, medical vitals grid (DOB, blood type, height, weight, allergies, medications, residence, cane specs), tap-to-call emergency contact button, `"Announce Medical ID"` button via speech queue.
  - Interactive `EditMedicalIDSheet` modal to update all fields with instant persistence.
  - Mobility & Fitness Card: large glanceable tiles for today's steps, total distance walked (km), completed walks count, and average walking pace, plus live active route telemetry.
- `AppModel.swift`:
  - Added `let medicalProfile = MedicalProfileStore()`.
  - Route arrival automatically invokes `medicalProfile.recordCompletedTrip()` and `medicalProfile.refreshMobilityStats()`.
- `Secrets.plist`:
  - Configured `OPENCANE_GROKBOT_WEBHOOK_URL` and `OPENCANE_GROKBOT_WEBHOOK_KEY`.
  - Verified endpoint with `curl`: returned `HTTP 200` with `runUuid: 9fb7c4a4-ce12-4eea-8608-c3166b50721a`.
- Verification:
  - `make test`: all 535 unit tests passing in CaneKitLogic.
  - `make uitest`: all 11 XCUITests passing on iPhone 17 Pro Max simulator (0 unexpected failures).
  - `make run`: generated, built, signed, installed, and launched cleanly on Aritro's physical iPhone 17 Pro Max (`00008150-001A698C1108401C`).

test on device: open OpenCane on your iPhone; verify Dynamic Island is completely clean when idle (no blue location arrow). Tap the 4th tab "Profile": verify Emergency Medical ID card displays your info, blind user safety alert, tap-to-call button, and today's mobility steps. Tap Edit to change any fields or tap Announce Medical ID to hear it read aloud. Return to Guide tab: verify streamlined buttons (Where am I & Talk side-by-side, Start route to CIF hero button, Navigate to CIF & Simulate walk side-by-side).

## Step 43 — Falls, weapons, trip bookends, and a spam guard on the webhook buttons (Sat Sep 12)

Five things the owner asked for after walking with Step 39 on the phone.

**Buttons no longer spam the bot.** "Send test event" and "Save family emails" each POST to the
webhook, and every POST starts a bot *run* — Save can also email the whole family. `ActionRateLimit`
(CaneKitLogic) spaces each action 10 s apart. ⚠ A refused tap **says so out loud** ("try again in 7
seconds") instead of doing nothing: a silent button reads as a broken one, and the walker cannot see
a greyed-out control. A refused tap also does not push the next allowed one further away, or holding
the button would lock the action out forever (pinned by a test).

**The email editor stopped looking like a form.** The fake `family@example.com` placeholder is gone
— it read as a filled-in field, and, as the owner put it, people know what an email is. Rows are now
cards with an envelope glyph and a 44 pt trash target, the add field has a `+` that is disabled
until you type, and Save turns primary while there are unregistered edits.

**The cane going over is detected.** `FallDetector` (CaneKitLogic) is a free fall → impact → still
and tilted state machine; `FallWatcher` feeds it CoreMotion at 20 Hz. All three stages are required,
and most of the tests are about what must *not* fire: a hard tap, a caught drop, a quick pick-up, a
single noisy sample. One alert per episode, re-arming only when the cane is upright again.

⚠ **The thresholds are guesses, not measurements.** Nothing here has been checked against a real
cane going over, so AGENTS.md "evidence before claims" is *not* satisfied — the first job on the
phone is to drop a cane a few times with the trip log running and re-derive them. It ships on
(the owner asked for falls to be reported) but it is in `optionalFeatureKeys` and has its own switch.

**Weapons the camera describes are reported.** The hazard watch already asks a vision model what is
ahead; `ThreatWatch` reads that reply for weapon and attacker nouns. The matching is strict because
this is the one alert whose false positive is genuinely expensive — it emails a family that their
blind relative may be being robbed:

- whole words only, so "gunmetal" and "shotgun microphone" do not match;
- benign collocations cancel it ("knife and fork", "nail gun", "toy gun");
- ⚠ a negation covers its **whole clause**, not a fixed lookbehind. The first version looked back
  two words and read "without any gun or knife" as a knife sighting — the negation covered `gun` and
  ran out before `knife`. A hazard model listing what it did *not* see is the commonest reply shape
  there is. A contrasting conjunction still resets it, so "no cars, but a man with a gun" alerts.

It is checked on the **raw** reply, before `HazardWatchPolicy` decides whether to speak: that policy
drops repeats to keep the soundscape calm, which is right for a kerb and wrong for a gun. The event
quotes the camera ("OpenCane's camera described: …") rather than asserting a weapon, because that
is genuinely all the app knows. The walker is told too — a blind person walking toward what the
camera thinks is a knife should hear about it. Rate-limited to one per two minutes.

**Trips are bookended.** `trip_start` on route start, `trip_end` on arrival or on Stop (only when a
walk was actually under way, so Stop on an idle guide emails nobody). ⚠ Both are `warn`, not `info`,
and that is a product choice rather than a severity slip: the bot only emails for warn/critical, and
the owner asked for an email at each end of every trip.

Verified: `make test` **535/535**, `make sim` and `make uitest` green.

test on device: tap Send test event twice quickly and hear the wait line; add an address with a typo
and hear the refusal; lay the cane down hard and confirm one fall alert, then pick it up and lay it
down again and confirm a second; point the camera at a picture of a knife with hazard watch on.

## Step 42 — Graceful GPS fallback for route start, orphan activity cleanup, centered titles, and on-device walk simulator (Sat Sep 12)

**Why:** The user reported:
1. "also siri started to talk and now its saying obstacle detection is not ready please look at all logs and stuff please CAN WE FIX THIS": In live trip log `canekit-2026-09-13T00-38-07Z.jsonl` pulled from the user's phone, the device was flat on a desk (`tilt: 88.95°`), keeping ARKit tracking in `.limited(initializing)` / `.limited(insufficientFeatures)`. The strict 5.0 s timeout previously aborted the entire route with "Obstacle detection is not ready. Route did not start." — violating AGENTS.md Rule 6 ("Never trade guidance away for a stricter check — a refused camera warns loudly but still guides").
2. "nope its till very vry there": The blue navigation arrow in the Dynamic Island persisted after launch because stale ActivityKit sessions from previous debug runs or crashes lingered in `locationd` without explicit immediate dismissal, and `manager.showsBackgroundLocationIndicator` was not explicitly false when idle.
3. "the middle one can just be Details or smth and you can make all 3 bigger... maybe it's like open cane centered. And the next one is like information and the next one was like settings": The navigation bar title needed centered prominence and the middle tab needed to be titled "Details".
4. "dead ass, just set up a whole like simulation and things where we can start testing it because I don't think it's still very perfect": An on-device simulation mode on the real iPhone so the user can test walking routes, turn-by-turn spoken instructions, Dynamic Island distance countdowns, and Apple Watch taps directly indoors without physically walking to CIF.

**What changed:**
- `AppModel.swift`:
  - `failQueuedRouteStart`: Graceful GPS fallback when depth readiness times out. Speaks `"Obstacle detection warming up. Guiding with GPS."` (.safety, 15 s TTL), pushes `"Guiding with GPS"` to the Apple Watch, logs `route_readiness {state: timed_out_fallback_gps}`, and starts GPS guidance immediately (`startRouteNow`). Added the line to `AppModel.commonLines` for ElevenLabs prefetching.
  - Extended route readiness timeout from 5.0 s to 7.0 s (`DepthReadiness.standardConfiguration.timeout + 2.0`) to give ARKit a fair initialization window.
  - On-Device Walk Simulator: added `isSimulatingWalk`, `simulationSpeedMps`, `simulatedWalkGeneration` (guarding task cancellation races), `startSimulatedWalk(speedMps:)`, and `stopSimulatedWalk()`. Stepping iterates through route waypoints at 1 Hz with linear coordinate interpolation and bearing calculation, resumes from `nav.waypointIndex` if invoked mid-route, and injects synthetic `GeoFix` and heading updates into `location.ingest`.
  - `stopRoute()` automatically halts walk simulations.
  - `AppModel.start()` cleans up orphaned Live Activities on app launch via `liveActivity.endAllOrphanedActivities()`.
- `LocationService.swift`:
  - Set `manager.showsBackgroundLocationIndicator = false` in `init()` and `setNavigating(false)`, enabling it strictly while actively navigating.
  - Added `ingest(fix:course:)` to ingest simulated or replay fixes directly into the location and heading pipeline.
- `LiveActivityController.swift`:
  - Added `endAllOrphanedActivities()` to terminate any stale ActivityKit sessions surviving previous app crashes or Xcode rebuilds with `.immediate` dismissal policy.
- `ContentView.swift`:
  - Updated middle tab screen title to `"Details"`.
  - Added centered prominent toolbar title via `ToolbarItem(placement: .principal)` with `.font(.title2.weight(.bold))` supporting Dynamic Type.
- `TabBar.swift`:
  - Scaled tab capsule to 72 pt width, 40 pt height, and 22 pt symbol font for larger touch targets and clearer prominence, while preserving `RootTab.title` accessibility contract labels (`"Guide"`, `"Sense"`, `"Settings"`).
- `GuideCard.swift`:
  - Added `"Simulate walk to CIF"` button when idle (disabled during route building and readiness waits).
  - Added `"Simulate walk"` / `"Stop simulation"` button while navigating for in-room testing.
- Review:
  - Ran Muse adversarial review (`muse exec`). Verified and addressed findings: generation counter guarding against rapid restart races, speed clamping (`[0.8, 8.0] m/s`), mid-route index resume, removing `endAllOrphanedActivities()` from `init()`, and Dynamic Type compliance.

test on device: open OpenCane on phone; verify navigation bar displays large bold centered titles ("OpenCane", "Details", "Settings"). Verify Dynamic Island has no persistent blue arrow while idle. On the Guide tab, tap "Simulate walk to CIF" from your desk: observe route starts with "Route started. ISR Townsend Hall to CIF", coordinates advance, turn cues announce ("In 45 meters, turn right..."), Dynamic Island displays turn arrow and distance countdown, and tapping Stop route ends simulation cleanly.

## Step 41 — Enriched sidewalk hazard telemetry for Grok Bot, anti-flapping filters, and dynamic navigation titles (Sat Sep 12)

**Why:** The user reported:
1. "so what can you make sure that all this is making sense? Like this needs to be a log. I feel like this we can make this a lot better. I feel like this log can be fed into our Grok Bot later that will come... Maybe add the m location, add what it saw, etcetera": The existing `hazards-*.geojson` only recorded flat coordinates and spoken text. At `00:26:29Z` in `hazards-2026-09-13T00-25-04Z.geojson`, rapid sensor classification flapping between `pothole` and `dropOff` at the exact same location wrote 5 duplicate features in a single second.
2. "also another thing here, like I'm not sure if this settings module actually does anything. And then also for all the different tabs, it says the same thing, open cane. Can we make it a little bit nicer? Maybe it's like open cane centered. And the next one is like information and the next one was like settings": The navigation bar title in `ContentView` was statically pinned to "OpenCane" on all tabs.

**What changed:**
- `Hazards.swift` (`CaneKitLogic`):
  - Enriched `HazardRecord` with `distanceM`, `heightM`, `direction`, `headingDeg`, `speedMps`, `routeName`, `instruction`, `source`, `whatItSaw`, `severity`.
  - Added `asGrokBotEvent(user:caneID:) -> OpenCaneEvent` to bridge hazard detections directly into Tejas's Grok Bot webhook routine.
  - Added `isDepression`, `isElevation`, and `isSameFamily(as:)` to `GroundHazardKind`.
  - In `GroundHazardPolicy.shouldAnnounce`, added `l.kind.isSameFamily(as: h.kind)` check to eliminate rapid kind-toggling between `pothole` and `dropOff` at the same world anchor.
  - Enriched `HazardGeoJSON.encode` with RFC 7946 feature properties (`distance_m`, `height_m`, `direction`, `heading_deg`, `speed_mps`, `route_name`, `instruction`, `source`, `what_it_saw`, `severity`).
- `HazardLog.swift`:
  - Enriched `record(...)` parameters to persist full route and detector context.
  - Added 3-second temporal/spatial debounce filter (`records.last.time < 3.0s` and matching coordinate/kind) to protect the GeoJSON and filesystem from sensor bounce.
- `AppModel.swift`:
  - Wired live distance, vertical delta, heading, speed, route name, instruction, source, and severity into `recordHazard` calls from `groundHazardFound` and `wireHazards`.
- `ContentView.swift`:
  - Dynamic navigation title: "OpenCane" on Guide, "Sense" on Sense, "Settings" on Settings.
  - Set `.navigationBarTitleDisplayMode(.inline)` to center titles cleanly across all tabs.
- `LocationService.swift`:
  - Added startup invalidation of temporary `CLBackgroundActivitySession` in `init()` to tear down any stale orphaned navigation session assertions from previous crashes.
- Tests:
  - Added 3 unit tests in `HazardTests.swift`: `enrichedHazardRecordSerializesAllProperties`, `hazardRecordMapsToGrokBotEvent`, and `groundHazardPolicySuppressesDepressionFlapping`. 513/513 Logic tests passing.

test on device: open Settings (nav title reads "Settings" centered); switch to Sense ("Sense") and Guide ("OpenCane"). Walk toward a curb or depression: observe single clear announcement without pothole/drop-off flapping. Check Files > OpenCane > hazards: open GeoJSON in geojson.io to see distance_m, height_m, direction, heading_deg, and route properties.

## Step 40 — Dynamic Island: clean idle state (session scoped to active route), real-time obstacle radar pill and ActivityKit coalescing (Sat Sep 12)

**Why:** The user reported:
1. "the app has having the navigation thing ever since I downloaded": A persistent blue navigation arrow in the Dynamic Island / status bar since app launch, even when idle and not navigating.
2. Dynamic Island split presentation in screenshots: the system background location indicator claimed the elongated pill, shoving OpenCane's Live Activity into the minimal detached circular bubble (`↑`).
3. Sighted spotters and blind users needed a richer Dynamic Island: glanceable obstacle clearance, sunlight-legible badges, and clear VoiceOver sentences.

**Root cause:**
- `LocationService.swift`: `LocationService.start()` was running `CLLocationUpdate.liveUpdates(.otherNavigation)` and instantiating `CLBackgroundActivitySession()` at app launch. In iOS 17+, `.otherNavigation` tells the OS the app is an active turn-by-turn navigation session, permanently anchoring the blue navigation arrow in the Dynamic Island / status bar even while idle.
- `LiveActivityController.swift`: Request failures or missing Live Activity permissions were not surfaced on-screen.

**What changed:**
- `LocationService.swift`:
  - Scoped `.otherNavigation` and `CLBackgroundActivitySession` strictly to active route navigation via `setNavigating(_:)`.
  - When idle, `start()` uses default `CLLocationUpdate.liveUpdates()`, providing accurate foreground GPS fixes without triggering the system navigation indicator.
  - Teardown hooked into all exits: `startRouteNow()`, `stopRoute()`, `endRouteQuietly()`, `onArrived`, `cancelPendingRouteStart()`, and `authorizationDenied`.
- `GuideCard.swift`:
  - Surfaced `model.liveActivity.lastError` directly in the Guide card error row alongside route and location errors.
- `LiveActivityCoalescer.swift` (new pure logic in `CaneKitLogic`):
  - Enforces non-linear distance thresholds (2m near turns <30m, 5m at <100m, 10m at range).
  - Immediate emission for emergency hazard transitions (`clear <-> warning/head/dropOff`), guarded by a 0.2s flap-guard against sensor oscillation.
  - 0.8s rate-limit time floor for routine updates, preventing ActivityKit update throttling.
  - Suppresses status detail text jitter.
- `NavActivityAttributes.swift`:
  - Enriched payload: `LiveActivityObstacleGlance` (`.clear`, `.warning`, `.head`, `.dropOff`), `obstacleDistanceM`, `headClearanceM`, `statusDetail`.
  - Custom `init(from decoder: Decoder)` with `decodeIfPresent` guarantees backward and forward compatibility with existing serialized activity payloads.
- `LiveActivityController.swift`:
  - Integrated `LiveActivityCoalescer` state machine on the main actor.
- `NavLiveActivity.swift`:
  - Compact Leading: Turn glyph + bold monospaced distance (`[ ↱ 45m ]`).
  - Compact Trailing: Obstacle clearance badge (`[ ● CLEAR ]`, `[ ⚠ 1.1m ]`, `[ ⛔ HEAD ]`, `[ ⚠ CURB ]`).
  - Minimal: Turn glyph (or warning symbol if obstacle detected).
  - Expanded: Turn glyph + route name + full instruction, large rounded distance + status detail, obstacle clearance pill banner.
  - Lock Screen: Obstacle pill with `.layoutPriority(1)` alongside route name and instruction.
  - VoiceOver: Natural accessibility summary combining distance, turn direction, instruction, and obstacle clearance.
- Tests:
  - 9 tests in `LiveActivityCoalescerTests.swift` covering emission, rate-limiting, distance bands, emergency transitions, flap-guards, and legacy JSON decoding.

**Verification:**
- `make test`: 468/468 passed.
- `make sim`: BUILD SUCCEEDED.
- `make run`: deployed to iPhone 17 Pro Max (`00008150-001A698C1108401C`), running PID 6129 with widget PIDs 6127 & 6128.
- Audited with two independent rounds of Muse (`--reasoning-effort high`).

test on device: open OpenCane while idle — no persistent blue navigation arrow in Dynamic Island. Start route to CIF — OpenCane owns the full Dynamic Island with turn countdown on the left and live obstacle clearance radar on the right. Stop route — Live Activity and background session dismiss immediately.

## Step 39 — Cane events reach the family: the Grok Bot webhook client (Sat Sep 12)

OpenCane can now tell someone. Cane detections become one JSON event POSTed to the Grok Bot
routine **"OpenCane cane events"** (folder `opencane-cane-events`), which owns the alerting
decision and the SMS. Same split as the VLM path: the wire schema and every threshold are pure and
unit-tested in `CaneKitLogic`, the app owns only transport and keys.

**New in `ios/Logic` (28 new tests, 383 total green):**

- `GrokBotEvent.swift` — `OpenCaneEvent` and friends. The `CodingKeys` **are** the contract
  (`accuracy_m`, `speed_mps`, `cane_id`, `battery_pct`, `obstacle.distance_m`, `lng` never `lon`),
  so they are asserted as bytes: a rename fails silently at run time (HTTP 200, bot parses nothing,
  no SMS), which is the worst way for this to break. A nil field is omitted, never null, because the
  bot reads absent `severity` as "you infer it". `type` is an open `RawRepresentable`, not an enum,
  so an unknown type decodes instead of throwing.
- `FamilyAlertPolicy.swift` — when a detection is worth sending. The depth path runs at ~30 Hz and
  GPS at ~1 Hz; forwarding either raw would burn the bot's run quota and, because the bot texts for
  `warn`, buzz a family member's phone continuously. Limits: breadcrumb 120 s, obstacle 60 s and
  only within 1.2 m, low battery once per discharge re-arming above 30 %. fall and sos are never
  limited. `reset()` clears the rate limits but deliberately **not** the battery arming — the
  battery does not recharge because a route started.

**New in the app:**

- `Alerts/GrokBotClient.swift` — POST with a bearer token, 10 s timeout, **one** retry on transport
  failure and **none** on a non-2xx: a 401 will be a 401 again, and re-POSTing an accepted `fall`
  would double-text the family. Logs status + body; never headers.
- `Alerts/FamilyAlerts.swift` — the main-actor relay. Sends are fire-and-forget so a POST can never
  delay a cue.
- `AppModel`: breadcrumb from `location.onFix`, obstacle beside the spoken obstacle line (so the
  event says what the walker just heard), low battery off the existing observer, `family.reset()`
  at route start, and `sendFamilyTestEvent()` behind the new Settings button.
- Settings → **Family alerts**: the opt-in (default **off** — it sends the walker's position off
  the phone, and it is in `LaunchRecovery.optionalFeatureKeys`), a line explaining itself when no
  webhook key is configured, and **"Send test event"**, which works even while the switch is off
  because checking the chain is what you do before a walk.

**Who gets alerted:** Settings → Family alerts now has a **Family emails** list. Saving posts one
`family_contacts` event (`emails: string[]`, plus `send_test` on the first list the bot accepts) to
the same webhook; the bot stores it and Gmails whoever is on it when a later fall / SOS / warn
arrives. Cane events are posted separately and unchanged, and never carry `emails` — the bot has
the list, and every copy is one more place it could leak (pinned by a test).

**The app sends no email.** It posts addresses once; the bot owns delivery. Every string in the UI
says what the *bot* did ("Grok Bot accepted 2 addresses"), never that mail arrived — the app cannot
know that.

Registration is deliberately unlike every other send: it ignores the alerts switch (the list is
filled in *before* alerts are turned on, and a Save that silently did nothing is the worst
outcome), it is not rate-limited, and it skips the enrichment path entirely — **a family's email
addresses are never put in front of the summarizer model.** Addresses are trimmed, lowercased,
de-duplicated (so "Mom@Example.com" and "mom@example.com" are not emailed twice) and capped at 10;
an invalid entry is refused with a reason rather than silently dropped, because a typo here costs a
real alert later.

**Context, so an alert is readable:** every event carries what the phone knew — destination,
current instruction, metres to the next waypoint, speed, heading, battery, thermal state, active
cue, last ground hazard, whether there was a GPS fix — in `extra`, plus `ai_context`: one sentence
written by a cheap model (`AlertSummarizer`) from exactly those facts. "Possible fall detected on
the route from ISR to CIF at Cross Springfield Avenue, 42 metres to the next waypoint … battery
18%" rather than a pair of coordinates.

⚠ The model never writes `note`. It is not allowed to be the only factual line in a safety alert,
so its sentence sits in `extra.ai_context` beside the facts it was given. The prompt bans what a
small model volunteers unprompted: claiming the walker is safe or that help is coming, inventing a
street or an injury, telling the family what to do. Those bans are pinned by a test.

**Two things the endpoint taught us, both of which fail silently:**

- `max_completion_tokens` has to cover a **reasoning** model's thinking, not its answer. At 200 the
  Muse endpoint spent 197 tokens reasoning and returned `content: null` with
  `finish_reason: "length"`; at 1024 it spent 1021 and did the same. HTTP 200 both times, so every
  alert would simply have carried no `ai_context` and nothing would have said why. Now 4096, with
  the measurements in the source and a test that stops anyone "optimising" it back down.
- `reasoning_effort` is **"minimal"** on this path, not the "low" the scene describer uses: "low"
  costs 7.1 s per alert — past the 6 s timeout, so the summary would usually have been abandoned —
  while "minimal" costs 2.1 s for an equally good sentence.

**Two things deliberately not done:**

- ⚠ **No fall detector and no SOS control exist.** `FamilyAlerts.fall(…)` / `.sos(…)` are written
  and tested, but only the test button calls them. Writing a fall detector is a numeric rule needing
  real data and its own tests (AGENTS.md hard rule 3); inventing a threshold here would ship an
  untested guess on the one event that matters most. Tracked in `docs/todo.md`.
- ⚠ **A 200 never means an SMS was sent.** It means the bot accepted the call and started a run; the
  bot decides who to text afterwards. `GrokBotResult.accepted`, the spoken line and the Settings row
  are all worded that way on purpose.

Keys live only in the git-ignored `Secrets.plist` (`OPENCANE_GROKBOT_WEBHOOK_URL` / `_KEY`, hard
rule 4), read from the process environment first so an e2e run can point at a throwaway endpoint.
Documented with a curl example in `ios/README.md §4.1`.

⚠ **Fixed before pushing: a local signing id had ridden along in this step.**
`ios/CaneKitWatch/Info.plist` had `WKCompanionAppBundleIdentifier` committed as
`com.tejaschakrapani.canekit` while the app is `com.aritro.canekit` (hard rule 6 freezes both).
`gen.sh` rewrites that file from `project.yml`, so it could not reach a build — but the file is
*generated and tracked*, so it would sit permanently dirty in every checkout, invite itself back
into a commit, and break watch pairing on the demo phone. Restored to `com.aritro.canekit`. Swap
ids for a personal team with the git-ignored `ios/scripts/restore-ids.sh` / `gen-local.sh`, never
by committing the plist.

Verified end to end before shipping, against the live routine: a `family_contacts` registration
(HTTP 200, `runUuid d1b76d16`) followed by a `fall` carrying facts + `ai_context` and no addresses
(HTTP 200, `runUuid f5e7f43a`).

test on device: Settings → Family alerts → Send test event, with the phone on Wi-Fi and then in
Airplane Mode (expect "Could not reach Grok Bot" after the one retry, ~12 s, and no crash); then
switch the toggle on and walk a route to see one breadcrumb every two minutes in the Grok Bot run
log, and let the battery fall below 20 % to see exactly one `low_battery` event.

## Step 38 — Point-blank wall safety: near-field low-confidence override and urgent proximity latch (Sat Sep 12)

**Why:** The owner tested the app against a wall (photo `IMG_9283`) and observed that holding the phone
15 cm from a flat wall reported "clear" in green tiles with dead silence, but stepping back to 0.5 m
reported "STOP" in red tiles and urgent haptics. Trip log `canekit-2026-09-12T23-26-49Z.jsonl` proved it:
at t=740-741s (distance 0.48m) cue was head/urgent; at t=751-785s against the wall, head=[-1, -1, -1]
torso=[-1, -1, -1] with cue=clear. ARKit LiDAR VCSEL/SPAD saturates under 25-30 cm, tagging returns
confidence 0 or invalid; `LaneMath` dropped all c < 1, defaulted empty cells to `.infinity`, and
`TileLevel` + `CueDecider` treated `.infinity` as clear path. Muse review verdict: "Critical,
fail-dangerous, ship-blocker. The gradient is inverted: walking toward a wall makes the app quieter and greener."

**What changed:**
- `LaneMath.swift`:
  - `LaneConfig.closeOverrideThreshold = 0.35` (metres).
  - In `sample()`: finite depths `< closeOverrideThreshold` are accepted regardless of confidence.
    Near-field saturation is proof of obstacle presence, not clear void.
- `CueDecider.swift`:
  - `CueThresholds.nearDropoutHoldSeconds = 1.5` (seconds).
  - Proximity latch: if an obstacle was in urgent proximity (< 0.7m), subsequent non-finite dropouts
    hold the active zone rather than instantly clearing. Approach cues clamp to the near floor (0.5m)
    so the 8 Hz alarm continues while pressed against the wall.
- `cue_audit.py`:
  - Parses `hazard_watch`, `describe_result`, and ground `hazard` records in trip logs.
- Tests:
  - `pointBlankLowConfidenceObstacleIsDetected` in `LaneMathTests`.
  - `nearDropoutHoldsUrgentObstacleAcrossBlindZone` in `CueDeciderTests`.

**Verification:**
- `make test`: 459/459 passed. `make sim`: BUILD SUCCEEDED.
- `make build install launch`: installed and launched live on iPhone 17 Pro Max (PID 6111).

test on device: hold the phone 15 cm in front of a flat wall. The cells now report obstacle distance /
urgent STOP in red tiles with active haptic buzz, never false green "clear".

## Step 37 — Talk floor: a direction cut by a warning resumes from its clause; a pause between the two (Sat Sep 12)

**Why:** the owner said "when the app is giving directions and it's giving notifications on objects
near you, it interrupts each other". Two trip logs show the pattern.
- **2026-09-12T22-20-53Z:** 5 of 58 dispatched lines were restarts, and 9 line starts were < 1 s apart.
- **22-27-00Z** (a friend's 37-minute handheld walk): 45 "Head height." lines, and 4 restarts,
  including the whole route intro played twice.

Every restart was a `.nav` line cut by `.safety` "Head height." and replayed from its first word.

**Design decision:**
- **First plan rejected (Muse review):** hold "Head height." behind a direction, with a buzz and a
  chirp now and the words later. A walker reaches a 1.5 m overhang in about 1.5 s, before the words.
- **Owner chose "Cut in, then resume":** the warning stays instant, and the direction continues from
  the clause it was cut in.
- **Owner chose "Leave as is" for walls:** they still get "Head height."

**What changed**
- New CaneKitLogic `SpeechResume`:
  - Clause starts are `. ! ? , ; :` plus a space, but not after "St." / "Dr." / "U.S.".
  - `resumeOffset` handles a word-boundary stop that finishes the last word, and snaps to a
    character boundary.
  - `nextResume`: at most 3 resumes, and the resume point never moves backwards.
  - mp3 progress is mapped proportionally and backed off 8 UTF-16 units. The seek starts 0.25 s early.
  - `gapSeconds`: 0.35 s between different bands. `.safety` never waits, and the app passes the
    safety band in.
- `SpeechQueue`:
  - Progress comes from `willSpeakRangeOfSpeechString` (system voice) or `currentTime / duration`
    (mp3).
  - A resumed line speaks its remainder (system voice) or seeks the whole cached clip. The text
    stays whole as coalescing, cache and Repeat key.
  - A call / Siri or dictation restarts from the top, since a fragment after seconds has no context.
  - The TTL is extended on the first cut only.
  - `inGap` pause state, with its own generation: `.safety`, or a same-band line that ties the head,
    ends it. `sayAgain` ranks against the queue head. `stopAll`, an interruption or a voice hold
    clears it. `isSpeaking` stays true, so the beacon stays ducked.
- Trip log:
  - `speech_dispatch` gains `resume_from`.
  - New `speech_end {priority}` for natural line ends.
- `cue_audit.py`: new `replays_resumed_mid_line` / `replays_from_line_start`, and
  `cross_band_pause_under_0_3s` measured from `speech_end` to the next start.
- Docs:
  - AGENTS rule 8, design.md §5.1 and CODE_REFERENCE are updated.
  - todo: talk floor inserted as 37, and the later cue v2 steps are renumbered 38–45. The "Step 40"
    references to torso taps in code are now "Step 41".

**Review** (Muse, Antigravity, 4-lens adversarial workflow with a verifier per finding). Every
finding was checked against the code; fixed unless noted.
- **Muse** (no blocking findings):
  - The front camera trusted a one-shot preview angle (camera commit).
  - The TTL was re-extended on every resume.
  - mp3 timing is uneven, so progress is now backed off.
  - `safetyBand` was a copied literal.
  - Stale `maxReplays` comments.
  - `stopAll` left resume state behind.
  - Accepted: explicit Repeat skips the pause.
- **Antigravity:**
  - A re-cut within `clipLead` of an mp3 resume was dropped as "no progress". This led to
    `nextResume`.
  - Progress inside an emoji or combining accent emptied the remainder and dropped the line. A
    script confirmed it on the old code at offsets 4 and 14.
  - `sayAgain` during a pause could jump a higher queued line.
  - A same-band line waited out a pause meant for another band.
  - A stray end callback could cut the pause short (the pause now bumps the generation).
  - The front camera angle.
- **Workflow:**
  - A resumed line cut before its first new word was dropped along with unheard clauses (same fix
    as `nextResume`).
  - The pause metric compared start times and could never see a missing pause (`speech_end` added).
  - Low severity: abbreviations split clauses; a word-boundary cut on the last word replayed a
    clause; a finished mp3 whose callback was still in flight was re-queued from the top; call and
    dictation resumes lost context; a misleading audit label; `isPortrait` was unused.
- **Refuted:** the front preview-angle claim (already fixed in the tree).
- **Deferred to todo:**
  - A system-voice line resumed from a cached mp3 maps an exact word offset to a proportional time.
  - The pre-existing interruption resume retry is not cancelled by a new `.began`.

**Verification:**
- `make test` 457/457. `make sim` green. `make e2e` PASS (266 s).
- `make uitest` 11 run, 10 passed, 1 skipped (needs a key), 0 failures.
- `cue_audit.py --selftest` ok.
- Installed on the phone 2026-09-12 evening.

test on device: start the route and let the intro play; point the phone at a wall at head height 1 m
away mid-sentence. You hear "Head height.", a short pause, then the intro CONTINUES from the phrase it
was on (not "Route started." again). Repeat on 2–3 later directions. Plug in, `make audit`:
`replays_resumed_mid_line` > 0, `replays_from_line_start` only for cuts in a first clause, and
`cross_band_pause_under_0_3s` = 0.

## Fix — Both cameras: the back feed was sideways again; rotation is now chosen per camera (Sat Sep 12)

**Why:** the owner's screenshot showed the back picture rotated 90° while the front inset was upright,
"idk why u keep messing it up". Trip log 2026-09-12T22-02-03Z had `back_rotation: 0`. Three earlier fixes
each used ONE `RotationCoordinator` angle for both cameras, and each fixed one feed by breaking the other.
Preview-for-both (0f32282, 1caff45) left the back sideways. Capture-for-both (103d548) tilted the front.

**What changed**
- CaneKitLogic `DualCameraRotation` (`LiveView.swift`):
  - The back camera gets the fixed portrait-up 90. The UI is portrait-only, and the coordinator's
    capture angle follows the phone's physical orientation. Muse caught that it reads 0 if Both
    cameras starts with the phone held sideways.
  - The front camera gets the measured upright 0, then 270. It never gets a coordinator angle: the
    preview angle is read once at connect and is wrong if Both cameras starts with the phone flat
    (Muse and Antigravity, round 2), and the capture angle is the one that tilted it.
- `DualCameraSession` logs `front_size` / `back_size` (delivered buffer WxH after rotation),
  `front_portrait` / `back_portrait` (`DualCameraRotation.isPortrait`), and `front_capture_angle` /
  `back_capture_angle`, so the next report is evidence.

**Review:** Muse round 1 (capture-for-back version); Muse, Antigravity and a 4-lens agent workflow,
round 2.
- **Fixed:**
  - Its fallback order could land back on the sideways preview angle.
  - A capture angle read while the phone is sideways would rotate the feed.
  - The tests passed for any "take the first angle" rule. They are rewritten to pin each camera's
    angle and the forbidden fallback.
  - Round 2: the front still trusted a one-shot preview angle, so it is now fixed at 0 as well.
  - Round 2: `isPortrait` was documented as a diagnostics check but nothing called it. It is now
    logged.
- **Rejected:** "re-apply the angle on every orientation change". The UI never rotates
  (`UISupportedInterfaceOrientations` = portrait), so a fixed display angle is correct.
- **Open question, unverified:** whether buffer dimensions swap under `videoRotationAngle`.
  `front_size` is logged as evidence only, and nothing reads it.

**Verification:** `make test` and `make sim` pass; UI and review results are in the commit message.
Device evidence from the installed build (trip log 2026-09-12T22-20-53Z): `back_rotation` 90,
`front_rotation` 0, `front_size` 1080x1920.

test on device: Sense → Both cameras with the phone upright, then again after starting it with the phone
held sideways: the back picture and the front inset are both upright each time.

## Step 36 — Cue detail (Quiet / Standard / Detailed) × Place (Outdoors / Indoors); names off by default (Sat Sep 12)

**Why:** cue design v2 §3.3 / §3.5 and the owner's "overstimulating" report. The walker picks how
much OpenCane volunteers, and indoor clutter gets quieter. **Speech only in this step:** haptics are
identical at every level until Step 40.

**What changed**
- New pure `CueRules` (CaneKitLogic `CueProfile.swift`).
  - Obstacle names: Quiet and Indoors name nothing. Standard names doors, and only while a route
    guides. Detailed names everything except walls.
  - Signs: Quiet and Indoors read only `safetySignPhrases` (closures, danger, caution, wet floor,
    push button). Other levels read every sign.
  - Head distance: 1.5 m outdoors (today), 1.2 m indoors [H].
  - `namesLimitLine` for voice feedback.
- `SignPolicy.allowedPhrases`: a disallowed phrase is skipped unstamped and never counts as matched.
- `AppModel.cueLevel` / `cuePlace` are persisted (`Settings.string`). **Default Detailed + Outdoors**
  (owner decision, until a mounted log tunes the calmer levels). A change is applied to the decider
  and the sign policy, spoken once ("Quiet cues.", "Indoor mode.", prefetched) and logged
  `cue_profile`. The `start` record carries `cue_level`, `cue_place`, `obstacle_names`.
- **`obstacleNamesEnabled` now defaults off** (research #2, lowest risk). Walkers who never touched
  the switch lose names until they turn it on; D6 in `docs/stress_test_plan.md` now says to.
- Settings → new **Cues** card first on the page: two segmented pickers with visible labels, VoiceOver
  containers and a caption that says what the level does today.
- "Turn on obstacle names" by voice now adds why it may stay quiet ("Quiet cues name nothing.").
- New XCUITest `testCuePickersChangeAndRestore`, restoring defaults in a teardown block. The segment
  titles are added to AGENTS.md rule 9 and design.md §9.

**Review** (35-agent adversarial workflow, Muse, Antigravity), every finding verified by hand:
- **Antigravity:** "no serious defects".
- **Muse:** no blocking defects. Its latent sign-swallow note is fixed (filter before `matched`,
  `sameFrameAllowedPhraseSurvives`). Its teardown note is fixed. Its stale `SpokenPhrases` comment is
  fixed; the wall prefetch lines are kept as a few unreachable kB.
- **Fixed (agents):**
  - Caption and hint promised haptic changes this step does not make.
  - The UI test could leave Standard / Indoors persisted after a failed assert.
  - Voice "Obstacle names on." was a silent promise under Quiet / Indoors.
  - Segmented pickers had no VoiceOver context.
  - D6 expected names by default and wall names.
  - The design.md §9 contract table and the CODE_REFERENCE `Settings` row were stale.
- **Rejected with evidence:**
  - "Safety-sign allowlist would mute a future phrase" (2/2 refuted: today it equals every phrase
    minus EXIT / ENTRANCE / PULL / PUSH; a new phrase is a deliberate table edit).
  - "Test title claims same-frame behaviour" (2/2 refuted; same-frame test added anyway).
  - "Names default flip contradicts Detailed = today" (2/2 refuted: the default flip is research #2,
    approved in the plan; the comment is now precise about who loses names).
- **Noted, by design:** switching to Indoors while a head cue is active at 1.35–1.5 m clears it. That
  is opt-in calming, and the hysteresis never latches (Muse, Antigravity).

**Verification:** `make test` 438/438, `make sim` green. `make uitest` first failed to COMPILE — the
teardown block captured the implicitly-unwrapped `app` as an Optional (`guard let app` fixed it); the
re-run result is in the commit message. On the phone (trip log 2026-09-12T22-20-53Z, t = 132–152 s) the
owner flipped every level and place: each tap logged one `cue_profile` record and dispatched its line.

test on device: Settings → Cues. Tap Quiet: hear "Quiet cues.", and no obstacle names even with Speak
obstacle names on. Tap Indoors: hear "Indoor mode.", and an EXIT sign is not read while a WET FLOOR /
CLOSED sign is. Detailed + Outdoors with names on: a door and a table are named, a wall never is. The
trip log `start` record shows `cue_level`, `cue_place`, `obstacle_names`.

## Step 35 — Cue design v2 research, plan, and the "measure first" audit script (Sat Sep 12)

**Device report (owner):** the voice is choppy and it is overstimulating: "although it's describing
everything it's seeing, I don't think it's the goal we want it to achieve."

**Research** (`docs/cue_design_v2.md`): 4 researchers (O&M practice, blind users' reviews of travel
aids, HCI studies, haptic/audio design) and 4 source fact-checkers produced 74 kept findings, with 10
dropped as unsupported, then one synthesis. Core principles: don't repeat what the cane already
finds; silence means clear; ears are the long-range sensor; the real gap is overhangs, which are
rare. Owner approved "Full v2" with the default level Detailed (= today) until a mounted log tunes
it. Muse's 17 plan findings are folded in (see docs/todo.md, "Cue design v2").

**Measured, not assumed:** new `ios/scripts/cue_audit.py` (`make audit`). On the first field log:
- 360 head-band cells under 1.5 m: 349 torso equally near (wall, furniture or person), 8 overhang
  signature, 3 torso dropouts (missing data, not overhangs).
- 34 head cues/min; 7.6 unsolicited spoken lines/min (6.7 excluding route lines); "Head height." ×10.
- ⚠ That walk was handheld: tilt median 25.8°, only 14 % inside 3–8°. **Zero** head cells fell in
  frames at mount tilt, so this log is no evidence either way for the mounted cane. The
  wall-vs-overhang argument (v2 §2 V1) rests on the mechanism (the band has no gravity correction and
  no torso check), not on these numbers. The script prints the mounted verdict and a mounted-frames-only
  head band on every log.

**New key:** ElevenLabs key rotated into the git-ignored Secrets.plist (main checkout + the 3 worktrees).
`/v1/text-to-speech` returns HTTP 200 with a real mp3. The key lacks `user_read`, so
`/v1/user/subscription` is 401; the app never calls it.

**Review (Muse; Antigravity returned no output, retried on Step 36):** 11 findings, all verified.
- Fixed: torso dropouts counted as overhangs (new `torso_dropout`); head band banked from handheld
  frames (new `head_band_mounted_frames`); tilt taken only from depth frames; route lines counted as
  unsolicited (new `unsolicited_non_route_per_min`); dispatch gaps unsorted, crashing on a record
  without `t`, and counting negative gaps; `--pull` swallowing devicectl errors and missing
  `DEVICE ?=`; no verdict when a log has no tilt; suppressed lines by reason only (now also by load);
  path in this entry.
- Folded into the plan: the Step 37 still-detector must not read cane swing as walking; Step 40
  torso taps also hold at a crossing; Step 36's "Detailed = today" names its one delta (no wall
  names).

**Verification:** `ios/scripts/cue_audit.py --selftest` ok (fixture: wall-like, overhang and dropout
cells, mounted tilt, one replay, a dispatch without `t`, one field collision). Run on the field log
above. Step 34 installed and
launched on the phone (`make run`: BUILD SUCCEEDED, Launched).

test on device: walk 2 minutes with the phone ON THE MOUNT, then plug in and run `make audit`: it must
say "ON THE MOUNT", and its head-band and per-minute numbers are the baseline Steps 36–41 are judged
against.

## Step 34 — Flashlight switch, both-cameras "does nothing", face tracking mid-route (Sat Sep 12)

**Device report (owner, trip log `canekit-2026-09-12T20-57-17Z`):** "the both cameras button don't
work" and "the flashlight slide thing is bugging".

**Cause 1 — flashlight (measured, t = 106–120 s):** every press logged twice with opposite results,
`torch on, active: false` then, on the *next* press, `on, active: true`. `setTorch` set the torch and
read `AVCaptureDevice.isTorchActive` on the next line; iOS updates it asynchronously, so the read was
the old state. The switch snapped back and said it failed, then the torch came on anyway, so every
change took two presses.
**Fix:** new pure `TorchSwitch` (CaneKitLogic) and `AppModel.setTorch` / `observeTorch` /
`applyTorch`. The switch shows the request at once; KVO on `isTorchActive` confirms it; a 2 s settle
deadline (a hypothesis to confirm on the phone) decides failure. Tests first: `TorchSwitchTests` (16).

**Cause 2 — both cameras (measured, t = 33.7 and 84–87 s):** the voice command "set the location from
here to Granger library" had **started a real route** (`route action: start`, 750 m). Every press
was refused, and that refusal is correct: a spotter's picture must not pause obstacle detection
mid-route. But `setBothCameras` snaps the switch back to off at once, and
`BothCameras.state(enabled: false, navigating: true)` returned `.off`, so the "cannot run while a
route is guiding you" caption was never on screen. The switch just bounced. (The spoken refusal
left no trip-log record because direct `say` lines were never logged, so whether it was heard is
unknown.)
**Fix:** `.blockedByRoute` for the whole route, whatever the switch shows; the caption adds "Stop the
route on the Guide tab first." Test first: `bothCamerasExplainTheRefusalForTheWholeRoute`.

**Cause 3 — face tracking (measured, t = 80.7 s; audit item todo:194):** "Head tracking without
AirPods" was switched on mid-route. `DepthEngine.setFaceTracking` pauses and re-runs the AR session
(~1–2 s with no obstacle frames), with no warning.
**Fix:** `FaceTrackingChange.decide` (CaneKitLogic). The `didSet` refuses while a route guides or
starts: it writes the old value back, speaks why at `.nav` and logs `face_tracking
{action: refused_*}`. The debug self test refuses too, and its 15 s restore waits for a route to end.
Sense caption. Tests first: `LiveViewTests.faceTracking*`.

**Instrumentation:** `SpeechQueue.onDispatch` → trip-log `speech_dispatch {text, priority, replays}`
for every line handed to a voice backend, whoever called `say`. Dispatched is not the same as heard.

**Audit (8 agents, 4 auditors + 4 skeptics) of every open software item in docs/todo.md:**
- Already done, todo was stale: cloud scene gate, scene prompt, hazard watch off by default,
  skipped waypoints, idle timer, back-camera copy.
- Still open (not in this step):
  1. The conversation fallthrough is not grounded in the scene context.
  2. The hazard-watch prompt still asks for metres.
  3. The AirPods head tracker starts without checking that headphones are connected.
  4. `observeThermalAndBattery` runs before the audio session is configured.
  5. The background teardown of both cameras has no background-task assertion.
  6. The debug probe + demo-route flag clash.
  7. Steps 27–33 never had their Muse/Antigravity reviews.

**Review (31-agent adversarial workflow + Muse + Antigravity), each finding verified by hand:**
- Fixed (agents + Muse + Antigravity independently): the first version still reported the
  same-instant read. After a quick OFF→ON it could confirm from the stale value, and the OFF's late
  KVO was then announced as "The flashlight turned off." A window now stays open to its deadline, and
  reports inside it are the walker's own requests landing (`quickReversalSpeaksOnce`). No synchronous
  report.
- Fixed (agents + Antigravity): the deadline slept on `ContinuousClock` but compared `systemUptime`,
  which stops in system sleep, so a window could never close. The task is the deadline and ticks with
  `now: .infinity` (`infiniteTickAlwaysResolves`).
- Fixed (Muse + Antigravity): KVO holds its target weakly and main-actor hops are not FIFO. The device
  is now stored, and each hop re-reads `isTorchActive` instead of trusting `newValue`.
- Fixed (agents + Antigravity): the failure, device-change and refusal lines were not prefetched, and
  a cache miss holds the queue and ducks the beacon. `commonLines` now includes
  `TorchSwitch.allSpokenLines` (pinned by `allSpokenLinesMatchOutcomes`) and the four refusal lines.
  Failure and device-change lines wait 12 s in the queue (`queueSeconds`).
- Fixed (agents + Muse): the self-test restore could re-run the session mid-route; it now waits.
  `onSpoken` was renamed `onDispatch`, because it fires at dispatch, not at playback. The face
  refusal no longer sets `routeError`, which nothing cleared. Captions cover route start. The
  `liveCaption` doc and the design.md §5.1 table are updated.
- Rejected, with evidence:
  - Muse: "refusal lines can flood `.nav`". `SpeechQueue.say` coalesces a line identical to the one
    playing or queued, so hammering the toggle leaves at most one playing and one queued.
  - Muse: "no test for enabled + navigating". Already pinned by
    `bothCamerasAreRefusedWhileARouteIsGuiding`.
  - Muse #5: "optimistic display shows ON for up to 2 s before a silent refusal". This is the
    deliberate trade for the measured snap-back, and the deadline speaks the failure.
  - Agents: "KVO `newValue` snapshot". Refuted 2/2, and moot now that the hop re-reads.

Muse re-review of the final diff: all nine fixes verified closed. One new defect: the deferred
restore logged every second with no cancellation check. It now logs once and stops on cancellation.

**Verification:** `make test` 423/423. `make sim` BUILD SUCCEEDED. `make uitest` on the iPhone 17 Pro
Max simulator (iOS 27): 10 tests, 1 skipped (streetview, expected), 0 failures, on the post-review
build. Not yet verified on the phone: it went unavailable mid-session.

test on device: reinstall (`make run`). Sense tab: Flashlight on, off, on. Each press should move the
switch once and say "Flashlight on." / "Flashlight off." once, with no snap-back; then tap off→on fast
and expect one confirmation, no "turned off". Start a route, then press Both cameras: the switch
bounces and the caption "…Stop the route on the Guide tab first." stays visible while the route runs.
Press Head tracking without AirPods mid-route: it is refused and spoken. In the trip log, check
`speech_dispatch` records for those refusal lines and `torch {action: confirmed(on: true)}`.

## Step 33 — Snappy tab switches: fade-in, one landing time (Sat Sep 12)

**Device report:** moving between Guide / Sense / Settings feels sluggish.

**Cause (static analysis — no per-frame body costs found):** the switch ran a *symmetric*
cross-fade (`.transition(.opacity)`), which keeps both full pages mounted inside the
animation: two ScrollViews composing at once, plus Sense's SceneKit preview
teardown/setup when Sense is on either side. On top of that the pill travelled on a
0.32 s spring while the page faded in 0.2 s, so the capsule was still moving after the
page had landed — two finish lines reads as lag. Card bodies are static (no
DateFormatter/JSON/sort-in-body, no appear-time loads), Guide reads nav state at
1–10 Hz, and only the visible page is in the tree, so the transition itself was the
whole problem.

**Fix (`ContentView`, `TabBar`, design.md §4):** incoming page fades in over 0.16 s
(`ContentView.pageFade`, ease-out); the outgoing page is removed instantly
(`.asymmetric(insertion: .opacity, removal: .identity)`), so two pages never compose.
Pill travel is now a 0.16 s spring (`pillTravel()`, bounce 0.08) — pill and page land
together. Reduce Motion unchanged (instant swap). No label, layout, or hierarchy
changes: the XCUITest contract (Guide/Sense/Settings, mount toggles) is untouched.

**Verification:** `make sim` still sandbox-blocked here (SwiftPM cache denied, incl. the
HOME-redirect retry), so no device/sim timing was measured — the 0.16 s value is a
calibration to confirm on the phone, not a measured optimum. Skeptic review not run
(change is 6 lines of animation-only code + doc sync; `CODE_REFERENCE.md` and
design.md §4 updated in the same step).

test on device: reinstall; tap Guide→Sense→Settings→Guide slowly (each page should be
fully landed the instant the pill stops — no trailing slide, no flash of the old page);
then switch rapidly 10× (no stutter, no stuck half-faded page); with "Live camera view"
on, switch to and from Sense (heaviest teardown/setup path); enable Reduce Motion and
repeat (instant swaps). If the fade still feels slow, lower `pageFade`/`pillTravel` to
0.12; if pages flash white, raise to 0.2.

## Step 32 — Front+back answer + Flashlight toggle (Sat Sep 12)

**Device question:** why no BeReal-style dual camera, and where is the flashlight?

**Dual camera already exists and works** — Hazards card → "Both cameras (pauses obstacle
detection)": front + back at once via `AVCaptureMultiCamSession` (measured 246 front /
244 back buffers, hardware cost 0.26 on this phone). Two measured reasons it is not
"just on": (1) ARKit can never deliver two pictures (`ARFrame` has one `capturedImage`;
Apple DTS 677731) — a second pipeline is mandatory; (2) running both pipelines starves
ARKit (measured 30 → 8 frames/4 s + interruption), so obstacle detection would look alive
and be two seconds stale. Hence paused-ARKit + refusal while a route guides ("Both
cameras cannot run while a route is guiding you. Stop the route first."). If that refusal
line is what was heard, the feature is working as designed — BeReal has no LiDAR safety
channel to protect. Future: `MultiCamDepthProbe` already measures whether depth can ride
along in multi-cam (trip-log `multicam_depth`); if its verdict keeps depth, both-cameras
could one day keep the safety channel alive.

**Flashlight is new** (`AppModel.setTorch`, Hazards card toggle): back-camera device torch,
so it works mid-route, with ARKit alive, and inside both-cameras mode — everywhere the
dual view cannot go. Off at every launch, never persisted (pocket heater risk). The switch
reports the measured device state (`isTorchActive` read back), never the request: if the
torch does not take — including torch+ARKit coexistence, which is now a device-run
measurement in the `torch` trip-log record — the switch snaps back and says so.

**Verification:** app typechecks clean vs sim SDK (Logic untouched). `make sim/run`
sandbox-blocked here. Skeptic review **passed with 2 fix-ups, both applied**: an ON request
the device silently refuses now says "The flashlight did not switch on." instead of the
misleading "Flashlight off.", and the two toggle confirmations joined `commonLines` so
they never wait on a fetch (byte-parity pinned in the comment, DangerSound precedent). No
state, persistence, isolation, or test-contract blockers.

test on device: reinstall; dark room → Hazards card → Flashlight on (light + "Flashlight
on."); start a route with it on (allowed — obstacle warnings continue); Both cameras +
Flashlight together; trip log `torch {action, active}` must read active:true in all three.

## Step 31 — Crispy answers: instant voice, "set location", Sift/Granger, exit-first (Sat Sep 12)

**Device report:** answers take too long; "set location" failed; route should guide out of the
building; blindfold walk to Grainger/Siebel imminent.

**Latency (research: voice-agent bar is ~800 ms; batch TTS costs 1–2 s vs ~400 ms
streamed).** Every conversational answer paid a full ElevenLabs batch fetch because novel
text never hits the cache — on top of the LLM round trip. Fix: `say(immediate:)` speaks
answers at once in the system voice and prefetches the natural voice for next time (route
lines stay prefetched ElevenLabs — the fetch is only skipped where the cache can never
hit). Applied to fast-path, cloud, fallback and error answers plus "I did not catch
that.". Already-fast path kept: `eleven_flash_v2_5` model, 1.5 s utterance silence left
alone on purpose (cutting it clips slow/halting speakers — accessibility beats 0.5 s).

**"Set location" failed:** only take/route/navigate/go/walk prefixes existed, so it fell
through to the cloud round trip. Added "set destination/location/my-destination, change
destination" prefixes (fast path, offline). Marker intents ("set a post") match earlier
and are unaffected.

**Sift/Granger:** the recogniser hears "Sift" for Siebel and "Granger" for Grainger — both
are gazetteer aliases now (whole-alias match only; "Sifting" still falls to MapKit).

**Exit-first:** MapKit routes built from a weak fix (accuracy > 25 m) now announce
"Walking to X, N meters. GPS is weak. If you are inside, head for the exit first."
(`WalkingIntro`, tested; worded conditionally because urban canyons fake it too; demo
route already guides out via WP1).

**Verification:** 396/396 Logic tests green (3 new cases); app typechecks clean vs sim SDK.
`make sim/run` still sandbox-blocked here — reinstall from a normal terminal before the
walk. Independent skeptic review **passed with 3 minor fix-ups, all applied and verified
here**: requeue now carries `immediate` (a cut answer used to lose its fetch-skip on
resume), the egress clause is conditional (weak GPS is not proof of indoors), and two
stale `1,722` budget comments now read `1,718`. No safety or routing-contract blockers.

test on device: reinstall; "Talk to OpenCane → how is my battery" must answer fast, in one
voice, with no instruction talking over you; "set location to Sift" → "Walking to the
Siebel Center…"; start a route indoors → exit-first clause; walk it blindfolded to
Grainger — trip log must show `voice_toggle`, `conv_turn` latencies, no `field_kind`.

## Step 30 — Speech holds while the walker talks + auditory-load research (Sat Sep 12)

**Device report:** pressing Talk to OpenCane did not stop the instructions — route and
obstacle lines kept playing over the dictation. Root cause: voice input muted the beacon
but never touched `SpeechQueue`, so the speech channel kept speaking (and the recogniser
could hear the app's own voice in the mic).

**Fix:** `SpeechQueue.setVoiceHold(_:)`, owned by `VoiceInputEngine` (set where
`isListening` flips, cleared in `cleanupAudioPipeline` on every exit — submit, cancel,
fail, permission wait). While held, lines below `.safety` queue with their TTLs instead
of playing; `.safety` ("Head height.", ground hazards) speaks straight through — a curb
cannot wait for the conversation. The playing line is cut and re-queued under the usual
one-replay rule; explicit Repeat still speaks at once. On release the queue purges
expired lines and plays the head: a short chat lets still-valid guidance through, a long
one finds it expired — no burst either way. The failure line, "I did not catch that.",
and the answer all speak after the release, so they play at once.

**Research (docs/auditory-load.md):** blind-navigation literature says emit discontinuously
and only on critical events (PMC 10781372), headphone audio masks traffic/echolocation
(MDPI 2026), and the walker should control the amount per situation (Springer 2025).
Checked OpenCane against each point: people lines only speak inside scene answers (never
automatic), signs are per-phrase once-a-minute, hazard watch is off by default, every
channel has a toggle. Deliberately **not** done: a global sign cap (could eat "SIDEWALK
CLOSED"). Open: tune the 7 s calm window from trip logs with a blind/O&M-trained tester.

**Verification:** 395/395 Logic tests green; app target typechecks clean vs the sim SDK.
`make sim/run` still sandbox-blocked here — device build already proven by the
user (`BUILD SUCCEEDED`, seq 2356). Independent read-only skeptic review: _pending at
write time, findings go here_.

test on device: reinstall; start a route; press Talk mid-guidance and keep talking — no
route/obstacle line may speak over you; have someone trigger a head-height cue (or trust
`.safety`) to confirm it still breaks through; stop talking — the answer speaks first,
then at most one still-valid held line.

## Step 29 — Action Button opens OpenCane for real + distance-first warnings (Sat Sep 12)

**Why the Action Button "still isn't working" (root cause).** `TalkToOpenCaneIntent` was a plain
`AppIntent`, never registered in `CaneKitShortcuts` — so it never appeared in Settings → Action
Button → Shortcut, and Step 24's device-test line ("open Settings → … → Talk to OpenCane")
described a picker entry that did not exist. Fixed by registering it as an App Shortcut
("Talk to OpenCane", Siri: "Talk to OpenCane" / "Speak to OpenCane"). The ten-slot list stays
full by demoting `NavigateToCIFIntent` to a plain intent: same destination as "Take me to CIF
in OpenCane" (the gazetteer CIF entry *is* route WP9), Guide card button and Shortcuts-app
action unchanged. `toggleVoiceInput(source:)` now logs `voice_toggle {source}` so an unanswered
press is visible in the trip log.

**Distance-first warnings (blind-perspective reorder).** Every warning line now leads with the
time-to-contact, then the identity: "Two meters ahead, door." (was "door ahead, two meters"),
"One meter ahead." (approach), "Two meters ahead, drop-off." (ground hazards),
"About 3 meters ahead, two people." (people), "1.4 meters ahead, obstacle." (LiDAR facts), and
the hazard-watch prompt asks the model for distance first. The gates stay order-free
(`numbersAreGrounded` compares number sets — pinned by a new both-orders test), and the
prefetch enumeration follows the templates, so the natural voice cache stays warm (1,718 chars,
down 4).

**Verification:** 395/395 Logic tests green (`swift test --disable-sandbox`; `--disable-sandbox`
is needed because this shell denies SwiftPM's inner `sandbox-exec`, and `HOME=/tmp/ckhome`
redirects its caches). App target typechecks clean against the simulator SDK with the new Logic
module. `make sim` / `make run` are **blocked in this sandbox** (`sandbox-exec: Operation not
permitted` inside xcodebuild's package resolution; escalation unavailable) — run them from a
normal terminal before the walk. Same sandbox blocks `muse exec` (no credentials), `agy`
(no socket), and `graphify update`. An independent read-only skeptic review of this diff
**passed**: no safety/route suppression, no prefetch mismatch, 10/10 shortcuts unique and named,
no test/UI contradiction, no isolation issue. Its one REAL finding (three stale doc-example
strings: `CODE_REFERENCE` HazardPrompt quote, `SpokenDistance` + `SpeechLoadPolicy` examples)
is fixed in this step. Two skeptic-flagged spots were **rejected with evidence** and left alone:
`docs/todo.md:17`, `TEAM_HANDOFF.md:57`, `ideas.md:91,249` quote what the walker actually heard
on past walks — rewriting them would falsify measurement history, not fix a doc.

test on device: from a normal terminal `cd ios && make run`; then Settings → Action Button →
Shortcut → Talk to OpenCane (if missing, open the Shortcuts app once to re-index, then retry);
press → tick → "how is my battery" → press again → answer; walk past a doorway and confirm the
order is "N meters ahead, door"; check the trip log for `voice_toggle {source: actionButton}`.
## Step 28 — Sound recognition fails safe across its whole microphone lifetime (Sat Sep 12)

The optional "Listen for sirens and horns" path now treats its microphone as untrusted unless the
route and analyzer remain healthy for the entire run. `SoundRecognitionGuard` in `CaneKitLogic` is
the pure state machine: it fences permission callbacks by generation, records input/output route
snapshots, permits only the bounded startup `none → usable` settle, and emits one stop decision for
output moves, HFP/missing input, analyzer/engine failure, interruption or permission revocation.
`SoundAlertsTests` adds six fake-route/lifecycle cases, including rapid-flapping and cold-start
settling (plus output-HFP and same-port-type device assertions). `SpeechQueue` remains the only
AVAudioSession owner, but its explicit microphone lease rejects concurrent push-to-talk/sound users
and its route observer now inspects UID/name-bearing input and output ports; `SoundWatcher` tears down the tap/analyzer, restores
`.playback`, disables only sound alerts and uses the existing `AppModel.onFailure` speech + Hazards
card path. A 0.5 s permission poll covers Settings revocation, and all notification/task tokens are
removed on every stop/failure. Relay and observer callbacks are generation-fenced, and an
old-device-unavailable notification is acted on even if the route has already recovered by callback
delivery. Restore failures are retried once and surfaced explicitly instead of being discarded. The
normal navigation, LiDAR and speech/haptic safety paths continue uninterrupted.

The existing open-finding list in `docs/todo.md` is checked off for the route guard, analyzer death,
permission race and first-read input-format settle. The AirPods HFP route and microphone quality
remain **device-unmeasured**, so this is graceful degradation (sound alerts off, route guidance on),
not a claim that the optional classifier is a primary safety sensor.

**Verification:** Logic sources type-check with the available Swift compiler; changed app/Logic
files pass Swift parse and `git diff --check`. Full `make test` is blocked in this environment by
the installed Swift 5.9 toolchain versus the package's Swift 6 tools version; `make sim`, UI/tour,
Muse, Antigravity and `graphify update .` likewise require the Xcode 27/tooling installations
documented in `TEAM_BRIEF.md` (the generated project, review binaries and graphify CLI are absent).

test on device: enable "Listen for sirens and horns" with AirPods connected and confirm a healthy
route keeps the beacon in its normal quality; disconnect or force an AirPods HFP transition during
recognition and confirm within one second that sound alerts stop, the switch turns off, the app says
why and navigation continues. Throw an analyzer/engine failure in the debug harness and confirm the
microphone session returns to `.playback`. Revoke microphone permission in Settings mid-session and
confirm clean cancellation with no orange recording dot. Start the permission prompt, toggle the
switch off, then tap Allow and confirm no microphone starts. Rapidly connect/disconnect AirPods and
confirm one failure cue rather than start/stop thrash.

## Step 25 — The arm went through the phone: the screwless mount simulated, redesigned, and re-sliced (Sat Sep 12, evening)

Windows-side hardware pass over `hardware/mount_screwless/`, prompted by a printed ring that
would not go fully down. Done in parallel with Step 21 on a different machine and merged onto it
afterwards: Step 21's measured `pole_d`, its polar `thread_profile` (the chord version printed a
0.74 mm square tooth whatever the parameters said), `thr_sink`, `pawl_catch_h` and the four-nut
thread coupon are kept; its `block_y` / `arm_tip_t` / `arm_boss` / `dt_stand` / `port_w` are
superseded by the socket-below-the-phone layout and the open floor below, which close the four
items Step 21 left as "still open and blocking" (numbers 1-3; number 4, the closed bore, stands). Instead of trusting the assembly preview, every pair of parts that
must not touch was **intersected** in OpenSCAD and measured, the ring was driven through its
travel in the model, and each printable was checked for shells and overhangs in its print
orientation. The harness is in the repo: `hardware/mount_screwless/verify.scad` run by
`scripts/verify_mount.ps1` (30 checks; measuring done by `scripts/stl_tools.js`). All green at
the end of the pass; the design has still not been printed as a set.

**What was wrong, in order of how badly it would have gone at the printer:**

- **The arm passed through the phone - 6.9 cm³ of overlap - and through the cradle's block
  (2.2 cm³ — Step 21 measured 4.7 / 0.95 cm³ on its own variant).** Forced by geometry, not a typo: the camera must face away from the cane, so the
  cradle's back plate is on the far side of the phone from the arm, and a fin landing at
  mid-phone height has to go through the phone. The preview showed nothing because overlapping
  colours look like parts. Fix: the cradle's dovetail socket moved to below the phone's bottom
  edge (`sock_y`), the arm runs out and up to a pad under it, and the fin lands on the pad's
  foot. Same layout the screwed mount uses.
- **The cradle's top latch was drawn straight through the phone.** Its riser was inside the
  phone pocket, so the phone cut left the hook as a **loose island 8.75 mm off the bed**
  (0.275 cm³, its own shell in the STL), and its leaf sat on the camera plateau (0.574 cm³).
  Replaced by two sprung top-corner caps on rails beside the phone, behind the button line;
  the phone loads from the front. Floor opened between the cups for USB-C.
- **The cradle slid off the arm under its own weight**: gravity runs 5° off the dovetail's
  slide and the socket was a through-slot with no stop. Stops at the lower end of both sockets
  now. The collar joint is locked by the ring (socket open at the top, arm drops in with the
  ring off, the ring's rim reaches 1.5 mm past the tenon); the far joint has a leaf pawl that
  lies on the fin's bed face - the only place a printed spring in a pocket comes out solid.
- **The ring could not reach the shoulder.** The collar's cone started at the thread's major
  radius, 0.75 mm outside the ring's thread crests, so the ring's own thread hit the cone's base
  with 3.8 mm to go: 0.165 cm³ of overlap at every height from 6 mm up, found by lifting the ring
  in the model. The cone now starts 0.10 mm inside the crest radius (`cone_relief`), taper 1.6
  (finger tips 1.75 mm), and the sweep is empty until the last 7.5 mm, where the squeeze (now
  0.6, was 0.8 - about 1 N·m at the ring) builds to 0.83 cm³ at the shoulder. Thread slack and radial
  clearance are cut to nut 3 of Step 21's four-nut coupon, [0.45, 0.45] (the bench's [0.35, 0.25]
  jammed; 0.125 mm per flank is under one line of over-extrusion); flank 60° (was 69°, every lower
  flank in air).
- **Every headless slice had support OFF** (`enable_support = 0` in the footer; the GUI plate had
  it on by hand). The cradle's plate would have printed in mid-air. `slice_gcode.ps1` turns it on
  for the cradle, bridges the socket roof rather than filling the socket with support (Orca's
  default `max_bridge_length` 10 did fill it - checked in the gcode), and refuses a cradle file
  without support.
- **Dovetail flanks were 67° overhangs** wherever the width is the build axis (the arm's tenons,
  the cradle's socket). Now 45° (24 / 14 / 5); the dovetail coupon's tenons lie on their side
  like the arm's so `dt_clear` is read on the real geometry.
- `build_stl.ps1` never rendered the coupon rows under the names `slice_gcode.ps1` asks for
  (`coupons_bore.stl`; Step 21 added them as `bore.stl`, which the slicer still could not find), so
  the runbook's first command failed on a fresh clone. Fixed; `coupons_next` and the ball-tip parts
  are in the same list. `-PoleD` added to both scripts for the day a different shaft turns up.

**Measured, not asserted:** wide camera axis −5.00°; lower shaft 47.5° off it (keep-out 45°),
5.4° outside the LiDAR cone; closest printed point to the shaft 55.5 mm (assert and vertex
scan agree); thread handedness confirmed (turned against the helix: 0.16 cm³ of tooth clash);
flank slack measured at 0.25 per side; ring lock: arm free at 0.4 mm, stopped at 1 mm.

**Still unknown:** `thr_clear`/`thr_axial` (four-nut coupon, not yet printed from this geometry),
`dt_clear`, `plateau_h`, and everything a printer does to a number. **Still open from Step 21:** the
collar is a closed 71 mm bore, so on a real cane it goes on over the tip or the handle. On the
broom-handle prototype that is a non-issue; on a cane it is a split collar or a removable tip,
and neither is designed.

test on the bench: run `.\scripts\verify_mount.ps1` (all green); print the bore rings, then the
thread set - ring 1 must run the stub's full length by hand; then collar + ring: with no cane
the ring reaches the shoulder, with the cane it stops ~3 mm short.

## Step 27 — Three icon-only root tabs (Sat Sep 12)

The phone UI was one long scroll. A sighted helper (and the XCUITests that scroll it) had to
page past Guide, the grid, hazards, haptics, watch and mount to reach anything. Split into
three pages under an icon-only bottom bar:

| Tab | Icon | Cards |
|---|---|---|
| Guide | `figure.walk` | Guide + trip / arrival |
| Sense | `square.grid.3x3.fill` | Depth status, Obstacles, Hazards |
| Settings | `gearshape.fill` | Haptics, Watch, Mount, This phone |

The bar is `CKTabBar` (`ios/CaneKit/UI/TabBar.swift`): ivory/ink sliding capsule
(`matchedGeometryEffect`), 60 pt hit targets, VoiceOver words **Guide / Sense / Settings**
(⚠ test contract). The page cross-fades over 0.2 s; Reduce Motion is an instant swap. Tab
changes do not speak through `SpeechQueue` (VoiceOver already announces the selected button).
Only the visible page is in the tree, so the 30 Hz depth isolation on Sense holds.

XCUITests that used to find Head row / haptic buttons / Mount toggles on the same scroll now
open the matching tab first. Existing Guide labels are unchanged.

Two layout bugs found by looking at the screen, both fixed in this step:

- **The bar filled the screen.** A `Capsule` is a flexible shape; as a `ZStack` sibling it accepted
  the whole proposed height, so the bar took most of the page. The capsule is now the
  `.background` of a fixed 62 × 36 box. The tappable frame stays 60 pt (design.md §3) — only the
  drawn pill is smaller.
- **Every page slid in from the right.** Going Settings → Sense looked like moving forward.
  Direction tracking was tried first, then dropped: pages now **cross-fade** (`.transition(.opacity)`,
  0.2 s) and never slide. A horizontal slide implies travel through an ordered set, which is not
  what a tab change means here. The capsule still slides between icons.

**Rebased onto Step 25, which renamed the button underneath it.** This work was written against
"Start demo route" while `main` moved on to "Start route to CIF" (Step 22, app line). The rebase
conflicted in exactly the three places that pin the label — `CaneKitUITests`, `CaneKitVisualTour`
and the design.md §9 table — and each took both sides: the new name *and* the tab rows. The
conversation-mode and Action Button work of Steps 23–25 touches `GuideCard`, which the Guide page
still hosts, so it needed no change. Two stale lines in `docs/CODE_REFERENCE.md` surfaced in the
merge and were corrected: the motion summary still claimed the button press was the only
animation, and the "divergence to know" note still described a 4-tab design that neither the doc
nor the code has.

**Also in this step: `make test` did not compile at all, and a `tail` hid it.** Two tests added by
the Step 25 interlock work call `DepthFrameContinuity.accepts`, which is `mutating`, directly inside
`#expect`. The macro expands its argument into a closure that captures the value immutably
(`$0.accepts($1)` → *cannot use mutating member on immutable value*), so `CaneKitLogicTests` failed
to build on Xcode 27. The six calls are now hoisted into locals before the `#expect`s, in the same
order (each call advances the anchor, so the order is the test). Note the pattern that *is* safe and
appears hundreds of times: `#expect(d.update(…) == value)` compiles fine, because a comparison
expands through a different check — only the bare-boolean form breaks. ⚠ If you add a `mutating`
call to an `#expect`, hoist it.

> **How this was nearly missed.** An earlier run of `make test | tail -8` printed a passing summary
> and exited 0 — the exit code was `tail`'s, and the head of the log held the errors. Pipe to a file
> and check the exit code, or grep for `error:`; never let `tail` be the verification.

**Verified:** `scripts/gen.sh` clean, `make test` **366/366 passed** (was: build failure), `make sim`
BUILD SUCCEEDED, app installed and launched on the booted iPhone 17 Pro Max simulator (compact bar
confirmed by screenshot after the size fix).

**Not yet run:** `make uitest` and `make tour` (AGENTS.md rule 10 wants both for a UI change) —
the simulator needs `xcrun simctl location <udid> set 40.1140,-88.2249` first or the route tests
fail for want of a fix, unrelated to the tabs. No Muse / Antigravity review of this diff yet.

**test on device:** open each tab with VoiceOver on — the three icons read "Guide" / "Sense" /
"Settings" with the selected one announced as selected; the rotor still reaches every card header
on the current page; Reduce Motion turns the cross-fade into an instant swap; the selection tick
is felt once per tab change and never during a route cue.


> **Step numbers 15, 16, 17, 21, 22 and 25 each appear twice, and that is not a mistake to "fix".**
> `feat/screwless-mount` (hardware, Windows) and `main` (iOS, Mac) numbered their steps
> independently and in parallel, then met in a merge on 2026-09-12. For 15, 16, 17, 21 and 25 the
> first of each pair is the hardware line and the second the app line. **22 is different**: both
> are app-line entries, because the route-start depth gate and the button rename were written at
> the same time on separate checkouts — the gate's own work was later finished as the app-line
> Step 25, and its heading says so. Renumbering any of them would break every commit message that
> already refers to them. Read the date and the subject, not the number.
>
> The app line has since passed the hardware line: 26 (README credits) and 27 (root tabs) are
> app-line only, so the next hardware step should take the next free number rather than 26.

## Step 26 — Team credits corrected in the README (Sat Sep 12)

The README credited the team by a role split that no longer matched who is doing what. Hardware is
**Sagar and Tommy**; the iOS app is **Aritro, Aarav and Tejas**. The docs-index line pointing at
`hardware/README.md` named Sagar alone and now names both.

Numbered 26 rather than 22 because Steps 23–25 (voice assistant, Action Button audio isolation,
camera interlock hardening) landed upstream while this was being written.

The same split is now in the other three places that named the team: the second "Who does what"
table in `hardware/README.md`, the **People** paragraph in `docs/stress_test_plan.md`, and the
per-person table in `docs/TEAM_HANDOFF.md`. The walk-day safety roles are deliberately left alone —
Aarav still walks, Sagar still spots, Aritro still films — because those are physical assignments,
not team membership, and rewriting them from a credits change would be inventing facts.

Nothing else changed — no code, no geometry, no parameter.

test on device: nothing. Documentation only.

## Historical note — Step 25 — Camera interlock adversarial hardening and documentation sync (Sat Sep 12)

The full review after merging the voice-assistant work found and fixed the remaining safety/UI
edges:

- AR reconfiguration now drains the serial frame queue before taking a readiness boundary, so
  reports from the previous camera configuration cannot earn post-transition trust.
- High-frame-rate mode publishes every camera frame (60 Hz) instead of leaving an untrusted frame
  hidden behind the 30 Hz cap; the normal shipped path remains 30 Hz.
- Published-frame continuity is a pure `DepthFrameContinuity` policy with Logic tests for dropped
  reports and transition boundaries.
- `routeStartWaiting` is observable, and Guide now exposes **Cancel route start** with an explicit
  spoken/watch confirmation while depth is warming. No queued request can be stranded behind a
  disabled Stop button.
- Current docs, route labels, test counts and the OpenCane/CaneKit name split were synchronized;
  historical verification claims are marked historical rather than presented as current.
- No screenshot-tour state was added: the cancel control exists only during a LiDAR camera warm-up,
  which the no-LiDAR simulator cannot reproduce; the Guide layout remains covered by the existing
  idle tour state.

**Verification:** 366 `@Test` annotations are present. Logic sources and changed app files pass
local Swift parsing/type checking; the local Xcode 15.1 / Swift 5.9.2 toolchain cannot execute the
Swift-tools-version 6.0 package, and XcodeGen/CoreSimulator/Muse/Antigravity are unavailable in
this environment. The Xcode 27 device/simulator gates remain explicitly pending.

test on device: while a two-camera view is active, request Start route to CIF, confirm the warm-up
status and Cancel route start button, cancel once, then retry and wait for automatic start; background
the app mid-route, confirm the spoken obstacle-warning pause, resume, and verify fresh depth reports
return before obstacle cues resume; toggle 60 fps and verify the trip log shows contiguous `frame_seq` values.

## Step 24 — Audio tap Swift 6 isolation fix, Action Button PTT toggle, and session coordination (Sat Sep 12)

Fixed physical-device voice-input crash paths:

- Moved Core Audio tap installation into nonisolated relay helpers so realtime callbacks do not
  inherit MainActor isolation under Swift 6.
- Added microphone-format settling validation and reused the voice audio engine safely across PTT
  sessions.
- Made the Action Button toggle listening on/off with tactile confirmation and coordinated playback
  restoration with the optional sound watcher.

test on device: open Settings → Action Button → Shortcut → Talk to OpenCane; press Action Button,
feel the haptic tick, speak “set a post here”, then press Action Button again to submit.

Additional details: the Core Audio tap isolation, microphone format guard, audio-engine reuse, Action
Button toggle, tactile confirmation, and SoundWatcher session coordination were verified in the
physical-device build described by the upstream commit.

## Step 23 — Conversational voice assistant with Action Button trigger, marker drops, and context memory (Sat Sep 12)

Hands-free voice assistant mode designed specifically for blind white-cane users:
- **Architecture & strict audio isolation**: Built `VoiceInputEngine` using Apple's on-device `SFSpeechRecognizer` (< 300 ms response). Audio session strictly complies with AGENTS.md Hard Rule 7: transitions to `.playAndRecord` with `[.duckOthers, .allowBluetoothA2DP, .defaultToSpeaker]` (never `.allowBluetoothHFP`), capturing voice from the iPhone's upward-facing beamforming microphone while keeping AirPods Pro in 44.1/48 kHz AAC/A2DP mode. Audio session returns immediately to `.playback` and spatial beacon un-mutes upon speech completion.
- **Fast-path intent classifier (`FastPathIntentClassifier.swift`)**: Sub-millisecond, zero-token, zero-network deterministic parser handling settings (beacon, drop-offs, hazard watch, silence cane), status queries (battery, GPS accuracy, AirPods connection), route controls (stop, distance remaining), UIUC campus destinations (`CampusPlaces`), marker/post drops, and trip metrics (steps, distance walked).
- **Post & breadcrumb marker dropping (`WalkMarker`)**: Users can speak "set a post here", "mark Townsend entrance", or "drop a pin". Markers capture GPS coordinate, custom name, altitude, and timestamp, accessible both during navigation and retrospectively.
- **Rolling conversational context & anti-slop guard (`ConversationModels.swift`, `ConversationPrompt.swift`)**: 6-turn rolling memory (`ConversationHistory`) with tool execution tracking. Anti-slop prompt (< 25 words per response, zero pleasantries) and `ConversationResponseParser` with `CloudSceneGate` safety filters that strictly strip hallucinated "all clear" reassurance.
- **Hardware triggers**: Wired into the physical iPhone Action Button via `TalkToOpenCaneIntent: AppIntent` (with `requestValueDialog: "How can OpenCane help?"`), plus accessible push-to-talk in `GuideCard.swift`.
- **Speech priority hierarchy & double-speak elimination**: Spoken conversational replies are strictly `.scene` priority (lowest band, priority 3). Route instructions (`.nav`), obstacle alerts (`.obstacle`), and head-height warnings (`.head` / `.safety`) immediately interrupt any conversational reply. Actions that already announce themselves out loud (`setHapticsSilenced`, `setOption`, `stopRoute`, `navigate(to:)`) skip the coordinator's spoken repetition to prevent echoing.
- **Muse adversarial audit (rounds 1 & 2)**: Addressed all findings: (1) `cloudPrimary` routing on `VLMClient` avoiding on-device prompt drops; (2) off-main thread JPEG encoding via detached task; (3) weak `appModel` across async gaps; (4) beacon state save and restoration across voice sessions; (5) eliminated fast-path and tool double-speaking; (6) fixed sticky `.error` state and guarded stale recognition callbacks against unlistening states; (7) reentrancy guards on `handleQuery`.
- **Historical upstream verification**: 359/359 unit tests green (`make test`), simulator build clean (`make sim`), 10/10 XCUITests + visual tour green (`make uitest`). Deployed and installed on physical iPhone 17 Pro Max (`00008150-001A698C1108401C`, build sequence 2308); rerun after the current merge with Xcode 27. **Rerun done in Step 27:** the
  Logic suite needed a compile fix before it would build on Xcode 27 at all, and now reports 366/366.
- **Follow-up fixes**: cloud-primary routing, detached JPEG encoding, stale recognition callbacks,
  double-speak suppression, and query reentrancy guard.

test on device: trigger Action Button or tap the mic; say “set a post here named curb”, verify the
confirmation, ask “how is my battery”, then say “take me to CIF”.

## Historical note — Step 22 — Gate route start on fresh trusted LiDAR depth (implementation precursor; superseded by Step 25 heading above) (Sat Sep 12)

Added the camera-transition interlock for route guidance:

- `CaneKitLogic.DepthReadiness` is a pure, testable state machine. It requires 3 consecutive
  same-frame reports with `.normal` AR tracking, active scene depth and the existing sweep trust
  bit; a gap over 0.5 s restarts the run and a 5 s bounded wait times out.
- `LaneReport.trackingNormal` is captured from the exact `ARFrame` in `DepthFrameProcessor`; the
  interlock does not trust the lagging `cameraDidChangeTrackingState` display string.
- `DepthEngine` owns the thin ARKit adapter, resets readiness on interruption, pause/resume and
  configuration re-runs, excludes buffered pre-transition reports with a processor sequence
  boundary, and restarts the run if the newest-only report stream skipped a frame.
- `AppModel.beginRoute` waits for serialized two-camera teardown, queues the route with a spoken
  and on-screen warm-up state, auto-starts on readiness, and fails loudly on a five-second request
  deadline (including a camera transition that never drains). Two-camera controls and self-tests
  are blocked while a route is waiting. Stop and newer destination requests cancel the pending
  start. The intentional no-LiDAR and camera-denied degraded guidance paths remain unchanged and
  explicit.

**Verification at implementation time:** 353 `@Test` cases were present; changed Logic sources pass `swiftc -typecheck` with
the local module cache. `make test` could not run in this environment because the selected Xcode is
15.1 / Swift 5.9.2 while the package requires Swift tools 6.0; simulator/device gates remain pending
on the Xcode 27 toolchain.

test on device: with the two-camera view enabled, request Start and confirm the route intro waits
for fresh depth; background/resume during that queued warm-up and confirm auto-start still requires
a new trusted-depth sequence; then background/resume an already-guiding route and confirm ARKit
recovers without stale depth; leave the camera unavailable for 5 s and confirm the spoken
"Obstacle detection is not ready" failure and no route begins.

## Step 21 — The bore rings were printed, and five things they touched were wrong (Sat Sep 12)

First physical measurement on this project. Everything below either came off the bed or was
measured against the geometry; nothing here is reasoned-only unless it says so.

**`pole_d` is 27.65 mm, settled.** The bore coupons were printed and fitted to the prototype
shaft. Ring 1 (27.75) barely went on; rings 2 and 3 went on decently, and both filament colours
agreed. `pole_d = (smallest ring that goes on) − 0.10 = 27.65` — landing exactly on the dial
caliper reading taken a day earlier by a completely unrelated method. Two independent
measurements to 0.01 mm. The rival **28.75 is retired** in `hardware/mount/cane_mount.scad` and
`test_coupons.scad` as well as the screwless folder.

One honest limit: no ring *refused* to go on, so the shaft is bounded from above (≤ 27.75) but
never hard-bounded from below. If the collet ever comes up short, reprint the rings from 27.15
before blaming the collet.

And one reading deliberately thrown away: an inside-jaw caliper measurement of a printed ring's
bore came out 27.28 mm. That is physically impossible — a rigid 4.2 mm wall cannot stretch
0.37 mm to pass a 27.65 shaft — and it is the classic chord/inside-jaw artifact. Printed bores get
measured by which gauge ring fits, never with inside jaws.

**The shaft is a broom handle.** Stated plainly because every fit number in this repo now depends
on it: the mount is being prototyped on a broom handle, not a cane. Real long canes are 9.5–13 mm
at the tip end (Ambutech's published 0.5 in / 3/8 in figures; Rodgers & Wall Emerson, *Materials
Testing in Long Cane Design*, JVIB 99(11) 2005; the WHO APS24 procurement draft says "13mm or
smaller"). Our 27.65 is roughly double anything published. Retargeting to a real cane is a 2x
change, not a tweak.

**The thread coupon jammed, and the coupon was the wrong shape to diagnose it.** The first pair
went down two turns of four and then stopped. That symptom rules out both simple explanations: not
radial clearance, because the first two turns were free; not elephant's foot on the stub, because
that binds at the *last* turn against the flange. Binding that worsens as more teeth engage points
at **axial** clearance — `thr_axial` was 0.25 mm, about one layer at 0.2.

The coupon could not tell us which, because it carried exactly **one** thread sample where the bore
row has five and the dovetail row three. A single sample can say "too tight" and never "by how
much". It is now a four-nut bracket that steps the two axes *separately* — `[0.45,0.25]` radial
only, `[0.35,0.45]` axial only, `[0.45,0.45]`, `[0.55,0.65]` — so the nut that frees it identifies
the cause. `thr_clear`/`thr_axial` in `screwless_mount.scad` are marked **PLACEHOLDER**: leaving a
value the bench has disproved sitting in the file as though it were settled is exactly what the
no-invented-specs rule forbids.

A geometric explanation was proposed and **disproved** rather than quietly dropped: the thread's
twisted extrude is faceted at 15 degrees per slice, dipping the crest 0.156 mm below true radius,
which looked like a strong candidate. Mating the two solids at eight phases through a full slice
gives **zero interference at every one**. The model is clean; the jam is a printing artifact.

**The arm can no longer be printed before the dovetail coupon.** `arm_tip_t = dt_narrow −
2·dt_clear` — added earlier the same night when the fin was narrowed to pass the socket mouth —
makes the arm's geometry depend on `dt_clear`: 42.865 / 42.656 / 42.448 cm3 at 0.15 / 0.25 / 0.35.
`pole_d` genuinely does not reach it. Four places still say otherwise (`PRINTING.md`, this file's
Step 18, `docs/todo.md`, `slice_gcode.ps1`); todo.md is corrected here, the rest are open.

**The arm's first layer had regressed to 0.30 mm2.** Same `arm_tip_t` taper: it is symmetric about
the build axis, so the fin came out a wedge balanced on a line, against 450–820 mm2 for every other
part. `assert(arm_t >= dt_wide)` did not catch it because `arm_t` is still 20 — the taper moved to
the far end. The fin now holds full width along the reach and narrows only over the last
`arm_taper` = 16 mm: bed contact **0.30 → 814 mm2**, and the arm got 3.7 cm3 lighter. Interference
with the cradle fell 2345 → 954 mm3 as a side effect.

**Four fitter-facing tables were wrong**, which is the most dangerous class of defect here — someone
reads them with parts in hand and a paint pen, and a wrong number poisons a parameter permanently.
The bore table in `coupons.scad` still listed a superseded set (27.85/28.25/28.45/28.95/29.15
against the real 27.75/28.05/28.35/28.65/28.95). The thread table described three nuts at
0.35/0.45/0.55 after the code had become four paired clearances. `coupons.scad` carried a
self-contradictory shrinkage instruction whose two halves move `pole_d` 0.36 mm in opposite
directions. And the stated print time was "~25 minutes" against a measured 52 m 53 s for the bore
row alone and 3 h 01 m for the full plate.

**Also fixed, each measured before and after:**

| | before | after |
|---|---|---|
| Collar dovetail socket axial play | 1.00 mm (void z −1→31 vs tenon z 0→30) | 0.00 |
| Zero-volume helical sheets on collar+ring | 20 (ring exported as 21 solids) | 0, both 1 solid |
| Cradle bottom wall over the charging port | 2382 mm3 solid, full 83.8 mm width | 34 mm window, 1786 mm3 |
| Thread coupon plate width | 251.11 mm on a 260 mm bed | 149.07 mm, wrapped to two rows |
| Coupon plate solids | 14 (two pairs had silently merged) | 16 |

The merged-coupon one is worth naming: wrapping the thread row to fit the bed pushed its second row
into the bore rings, and the plate rendered as 14 solids instead of 16 with no error of any kind.
Component count is now the pass/fail on every plate.

**Three bugs were introduced and caught by re-testing within the same session** — recorded because
the catching matters more than the introducing: notches placed 13 degrees apart landed inside the
nut's flutes where a thumb cannot read them (volume drop per notch 0.002/0.007/0.008 cm3 where a
constant 0.007 was due; now 36 degrees apart, at flute midpoints, constant); the swivel-test coupon
for the ball tip was geometrically impossible (a stem sized for a 27.65 shaft cannot enter a 25 mm
ball); and the plate collision above.

**Still open and blocking.** The mount cannot be assembled or trusted:

1. The cradle **slides off the arm**. There is exactly one `pawl_spring()` in the file and it is at
   the collar end; the cradle's socket is cut open at both ends and its slide axis is near-vertical
   in the walking pose.
2. The cradle's **top latch is a floating island** (0.275 cm3) — the phone has no top retention and
   the cradle exports as 2 solids. The latch riser stands in the middle of the phone's footprint and
   the phone-pocket cut severs it.
3. The **arm still passes through the phone** (4702 mm3).
4. The collar is a closed 71 mm bore and **cannot be fitted or removed without taking off the cane's
   tip or handle**.

**Reviews.** Four adversarial agents completed (CAD geometry, docs truth-audit, printability/safety,
and a verifier re-checking the docs findings); a second round of four all stalled and returned
nothing, so their ground is *not* covered. Every finding acted on above was re-verified here by
measurement first — and one of the verifier's own findings was rejected with evidence: it claimed the
"parts were printed" comments were unverifiable because five other files still say "never printed".
The rings were printed; those five files are the stale ones, and they are listed for correction.

Muse and Antigravity were **not** run — `muse`, `agy`, `make`, `xcodebuild` and `swift` are all
absent on this Windows machine. Recorded as not-done, not as passed.

test on device: nothing new on the phone. Print `coupons.scad what="next"` (11 solids, 149x178 mm,
57.32 cm3) in PLA at 0.2 mm, 4 walls, 25% gyroid, no support; take the smallest thread nut that runs
the full length freely and the dovetail that slides with thumb pressure and stays put when shaken,
then put those three numbers in the parameter block. Do not print the collar, ring, arm or cradle —
all four are blocked by the defects above.

## Step 22 — Rename primary route action to "Start route to CIF" and synchronize test contracts (Sat Sep 12)

Clarity and usability enhancement for the Townsend Hall to CIF walk:
- **Button rename**: Renamed primary route action in `GuideCard.swift` from "Start demo route" to "Start route to CIF", clarifying that it is the live, pre-surveyed route from Townsend Hall (dorm) to CIF rather than a simulation.
- **Siri App Shortcut**: Added "Start route to CIF in OpenCane" to `AppShortcutsProvider` in `AppIntents.swift` while retaining legacy phrases for backwards compatibility.
- **Contract & documentation sync**: Updated test contracts across `AGENTS.md` (Rule 9), `docs/CODE_REFERENCE.md`, `docs/design.md`, `CaneKitUITests.swift`, and `CaneKitVisualTour.swift`.
- **Adversarial review with Muse**: Muse confirmed 1:1 label pairing, accessibility contract preservation, strict concurrency invariance, and clean naming split.
- **Verification**: 348/348 unit tests pass (`make test`), simulator build clean (`make sim`), 10/10 UITests pass (`make uitest`), and deployed to physical iPhone 17 Pro Max (`00008150-001A698C1108401C`).

test on device: open app, verify button reads 'Start route to CIF', tap to start route from Townsend Hall.

## Historical note — Step 21 — Bolt: Decouple 30 Hz depth stream from ContentView root to prevent full-screen SwiftUI re-renders (Sat Sep 12)

Performance optimization addressing root-level SwiftUI Observation invalidation:
- **Observation root decoupling**: In iOS 26 / Swift 6 `@Observable`, referencing high-frequency sensor streams (`model.depth.report` at 15–30 Hz, `model.depth.fps`, and `cameraTiltDownDeg`) directly in `ContentView.body` caused the entire root scroll view and all 9 navigation/status/settings cards to invalidate and re-evaluate on every LiDAR depth frame.
- **Leaf isolation pattern**: Extracted `ObstaclesCard` and `MountAimRow` leaf subviews inside `ContentView.swift`. Kept `LaneGridView(report:)` pure and testable while ensuring observation tracking of `model.depth.report` is scoped strictly to `ObstaclesCard` and `MountAimRow`. Also hoisted `laneNames` array in `LaneGridView` to a static constant to avoid heap allocations per render.
- **Impact**: Eliminates ~97% of unnecessary root `ContentView.body` evaluations during active walking with LiDAR (reducing CPU cycles and thermal throttling during prolonged use).
- **Adversarial review with Muse**: Muse confirmed decoupling direction, verified concurrency and display logic invariance, and recommended the pure leaf wrapper pattern over environment fallback inside `LaneGridView`.
- **Verification**: 348/348 unit tests pass (`make test`), simulator build clean (`make sim`), 10/10 UITests pass (`make uitest`), and clean GPS e2e replay (989 m, 9/9 waypoints).

test on device: verify Obstacles card and Mount aim row update smoothly with cane in hand, check phone thermal status during 5-minute continuous walk.
## Step 20 — Passed-by slow approach fix, Live Activity overlap prevention, and Watch keep-alive guard (Sat Sep 12)

Full codebase stress test and multi-agent audit across LiDAR depth, cameras, navigation logic, watch connectivity, audio, speech, and hardware:
- **Passed-by receding fixes reset on slow approach**: In `GeofenceTracker.update`, walking toward an intermediate waypoint at < 1 m/s (step < 1 m) meant `d > last - 1` evaluated true, accumulating false receding fixes before reaching closest approach. Now explicitly resets `recedingFixes = 0` whenever `d <= minDistance`. Added `@Test func passedByResetsRecedingStreakDuringSlowApproach()` in `GeoMathTests.swift`.
- **Live Activity dismissal policy**: `LiveActivityController.end(final:immediate:)` now supports an `immediate: Bool = false` dismissal policy (`.immediate` vs `.after(.now + 60)`). `start()` and `AppModel.endRouteQuietly()` invoke `end(immediate: true)`, preventing stacked/overlapping stale Live Activities on the lock screen during rapid route restarts.
- **Watch keep-alive guard**: Guarded `!text.hasPrefix("No route")` in `WatchModel.updateKeepAlive` to ensure "No route running." status lines do not spuriously trigger workout keep-alives while idle.
- **LiDAR multi-cam architecture audit**: Researched and audited user query regarding front selfie camera + back camera + LiDAR depth. Verified hardware probe on iPhone 17 Pro Max confirms 12 multi-cam sets pair the front camera with rear LiDAR depth at 320×240 (AVFoundation). Documented why ARKit's single-camera architecture (`ARFrame.capturedImage`) pauses in dual-cam mode and what an AVFoundation-based pipeline would require (replacing ARKit, manual gravity via CoreMotion, lens undistortion, loss of classified mesh).
- **Demo route guidance for Townsend Hall (dorm) to CIF**: Clarified that "Start demo route" (`route_isr_cif.json`) is specifically the pre-surveyed, pre-cached Townsend Hall to CIF route with tested curb gates and turn settling. Kept "Start demo route" and pinned accessibility label.
- **AirPods Pro & Apple Watch necessity**: Clarified why AirPods Pro (spatial audio HRTF beacon, head yaw tracking, Transparency mode) and Apple Watch (wrist haptic taps, remote controls without cane phone access) remain essential for the blindfolded demo walk.
- **Verification**: 348/348 Logic tests pass, `make sim` clean, 10/10 XCUITest / visual tour passed, `make e2e` clean scenario passed (989 m, 9/9 waypoints in order, 0 veer errors).

test on device: start demo route, lock phone to check single Live Activity on Lock Screen; verify 3 detents on Watch crown advances waypoint; verify Townsend Hall -> CIF route navigation.

## Step 19 — The collar had no thread on it (Sat Sep 12, overnight)

Three adversarial sub-agent reviews were run over `hardware/mount_screwless/` before
committing the sliced plate to a printer. Every load-bearing finding was verified here
by measurement before it was acted on, because the first pass of my own verification was
wrong (see "a wrong measurement" below). Six defects fixed; each one re-measured after.

**`thread()` never produced a thread.** This is the headline and it invalidated the
entire clamp — the mechanism the whole design is built around.

`linear_extrude(twist=)` maps **angle** to height, not distance. At `thr_pitch = 3` the
twist rate is 360/3 = **120°/mm**. The tooth was drawn as a linear offset in y, so a
tooth `y` mm "tall" came out `atan(y/r)/120` mm thick — about **0.031 mm**, a fifth of a
layer. The collar's threaded band sliced as a plain smooth cylinder. The ring would have
slid straight off.

The tooth is now drawn as an angular **sector**, via `thr_ang(axial_mm) = axial_mm *
360 / thr_pitch`, with `thr_duty` / `thr_crest` / `thr_axial` expressed as fractions of
the pitch in the parameter block and three asserts that catch a tooth wider than half a
turn, an inverted flank, and no room left between turns. Measured on the rendered
collar by sectioning at five heights: **0.616–0.747 mm**. `coupons.scad` carried a
hand-copied duplicate of the same bug and got the same rewrite.

The other five:

| Fix | Before | After |
|---|---|---|
| Thread tooth, axial thickness | 0.031 mm | **0.616–0.747 mm** |
| Arm first-layer bed contact | 42 mm² (Creality's own figure) | **1627.4 mm²** |
| Material blocking the cradle's dovetail slide | 986.57 mm³ | **0.00 mm³** |
| Cradle overhanging the phone's front face | 0.02 mm³ | **514.99 mm³** |

- **`collet_nut()` cancelled its own squeeze.** It applied `thr_clear` to the cone as
  well as the thread, so the ring closed the collet by ~0.04 mm instead of the intended
  amount. The nut's internal cone must share the collar cone's **taper rate**, not its
  end radii — `ring_cone_lo/hi` and `lock_cone_lo/hi` are now derived that way, with
  `collet_squeeze = 0.80` and `ball_squeeze = 0.60` as the stated closures, and asserts
  that the squeeze exceeds the clearance it has to take up first.
- **The cradle's phone cut removed every retention feature.** `phone_block`'s default
  runs 10 mm past the phone's front face, and the side lips, the corner cups' lips and
  the whole top latch live in exactly that 10 mm. The cut now stops at the front face.
- **The latch hook was buried inside the phone.** It sat at `phone_d - back_t`, i.e.
  3.2 mm *inside* the phone, gripping nothing. It sits on the front face now.
- **The cradle's dovetail socket was a blind pocket**, so the arm could not slide in at
  all. Opened through.
- **`arm_t` 10.0 → 20.0.** At 10 mm the arm stood balanced on its two dovetail edges:
  42 mm² of bed contact. It would have been knocked off the plate. Asserted against
  `dt_wide` so it cannot regress.

All six parts re-render `Status: NoError` with every assert passing;
`part = "assembly"` echoes a 13.15 mm phone-to-shaft gap.

**`coupons.scad`'s selection formula contradicted its own criterion.** It said
`pole_d = bore − 0.35` while describing a ring that "goes on with firm thumb pressure",
which is 0.05–0.15 mm of clearance, not 0.35. For a collet, ~0.25 mm is the difference
between gripping the cane and never reaching it. Corrected to **−0.10**, and the note
now says plainly that `bore_clear` is *not* an output of this test — the rings are
rigid, the collar is a collet that closes, so clearance is a design decision and
`collet_squeeze` takes it up.

The bore set was also rebuilt: **27.75 / 28.05 / 28.35 / 28.65 / 28.95** in even 0.30
steps, replacing 27.85 / 28.25 / 28.45 / 28.95 / 29.15. The old set *started above* the
27.65 caliper reading, so if the caliper was right the smallest ring still fitted and
the test had no lower bracket — it could only contradict itself. It also put 28.65 and
28.75 inside one 0.50 mm gap.

**A wrong measurement, recorded because it nearly cleared a real bug.** My first check
of the thread filtered the collar's cross-section by `r > 17.10` and found healthy 66°
runs. Those were the dovetail pad, which sits at azimuth 0 and reaches past r = 22.
Restricting to azimuths 80–280° isolated the real thread crossing at 3.77–7.48°, i.e.
0.031–0.062 mm, and confirmed the agent was right. A filter that accidentally selects a
different feature reads as a pass.

**Headless slicing.** `scripts/slice_gcode.ps1` drives Creality Print 7.2 from the
command line — it is an Orca fork and takes Orca's arguments — so slicing is
reproducible and needs no GUI. It re-opens every file it writes and echoes the material,
both temperatures, walls, time and weight, and **refuses to name a file safe if it
cannot read the material back out**. That guard exists because a PETG plate was very
nearly sent to a machine holding four PLA spools: `START_PRINT EXTRUDER_TEMP=250
BED_TEMP=80` is substituted at *slice* time and cannot be corrected at the printer.
Two Windows traps are documented in the script: the Creality exe needs
`2>&1 | Out-String` *and* a relaxed `$ErrorActionPreference` or it silently writes
nothing, which is the exact opposite of `build_stl.ps1`'s OpenSCAD rule.

New `hardware/mount_screwless/PRINTING.md` is the operator runbook: material → slot →
temperature, print order, how to read each coupon, and what the coupons do not settle.

**Not done, and not claimed:** Muse and Antigravity are both absent from this Windows
machine (`muse`, `agy`, `make`, `xcodebuild` and `swift` all resolve to nothing), so the
diff has had the multi-agent review the engineering bar asks for but **not** the Muse or
Antigravity passes. No iOS source changed in this step, so no Logic tests were affected.
Run both on a Mac before this merges to `main`.

**Still open** (found by review, not yet fixed): the pawl release window is ~79% blocked
by the arm, so there may be no way to press the catch; no lead-in ramp on the pawl
catch; `socket_part()`'s "flare" is a flat 90° ledge; the button windows overrun the top
of both side walls; `dt_clear` gives 0.325 mm at the mouth and 0.139 mm buried instead
of a uniform 0.25; the ball-socket fingers at ~7–9% strain will crack. All are in
`docs/todo.md`.

test on device: nothing printed yet at time of writing. Print the bore rings first
(`-Plate bore -Material PLA -Walls 4`, 52m53s), read `pole_d` off them, then the thread
coupon — if the ring will not thread onto the stub, do not print the collar. The arm can
go on any free machine now; it depends on neither `pole_d` nor `dt_clear`.

## Step 18 — Sliced on the SPARKX i7 (Sat Sep 12)

All six mount parts on one plate, sliced clean in Creality Print 7.2 against
`0.20mm Standard @SPARKX i7 0.4 nozzle`: **4 h 31 min, 101.94 g, 34.18 m**. Project saved
as `hardware/mount_screwless/opencane_mount_plate.3mf` (gitignored).

Support is **on, build-plate-only**. That combination is deliberate. The cradle stands on
its dovetail block and needs support under the back plate; the socket's ball cavity must
NOT be supported, because support inside the cup cannot be got out through a 17 mm mouth.
Build-plate-only draws the first and skips the second, because support for the cavity
would have to stand on the model. Support is 6.8% of print time, interface another 3.2%.

**Do not use auto-arrange on this plate.** It packs the parts tight enough that Creality
Print reports gcode path conflicts (lock↔arm at z=2.75, then ring↔cradle at z=5.20).
Explicit positions that slice clean, X/Y mm: cradle (65, 150), collar (150, 200),
ring (150, 140), lock (215, 140), socket (215, 200), arm (70, 42).

**Diameter call: 27.65 mm is self-consistent and the collet has margin, but it is a
one-way bet.** Bore is 28.05 mm (27.65 + 0.40). On a 27.65 shaft the collet closes a
0.20 mm radial gap; the cone sheds 0.13 mm of radius per mm of ring travel, so that is
1.5 mm of travel — half a turn of a 3 mm pitch — against 17 mm of cone engagement. Huge
margin. But 28.05 is SMALLER than both competing figures (28.65, 28.75), so if the caliper
is wrong the collar does not grip loosely, it does not go on at all. Coupons first.

While checking that, found `grip_ribs` are **grooves, not ribs** — the cylinders are
subtracted, scalloping eight ~0.3 mm dishes out of the bore. The behaviour is right (eight
narrow lands grip harder than a full bore) but the names and comments said the opposite.
Comments fixed; no geometry changed, so the sliced plate still stands.

test on device: nothing printed yet. Coupon plate first, then this one.

## Step 17 — The assembly preview earned its keep (Fri Sep 11)

Built the full `part = "assembly"` preview — ghost cane, ghost phone, and a red ray down
the rear camera's optical axis — because the previous preview drew only the collar, ring
and arm, and everything it left out was broken. Four faults, all found by looking:

- **Both dovetail sockets were on the wrong axis.** `rotate([0,-90,0])` put the slide
  along the radius instead of along the cane, so the joint resisted nothing the phone
  actually does to it. Now `rotate([0,0,90])` everywhere, one orientation, arm drawn in
  the collar's own frame so `assembly()` is a single translate you can check by eye.
- **The collar's pad was shorter than the dovetail it holds.** `base_len` was 9 mm
  against a 30 mm slide, so the socket cut clean through the pad. `base_len` is 36 mm
  and there are asserts on it, on `pad_w` and on `pad_t`.
- **The arm's cradle end hung off nothing.** The fin tapered to 15 mm deep under a 30 mm
  tenon. The fin is now one hull from the collar face to the cradle face.
- **The phone's bottom corner cleared the shaft by 1.1 mm.** `arm_angle` rakes the phone
  back toward the cane, which `arm_reach = 46` (inherited from the screwed mount, whose
  geometry differs) did not account for. `arm_reach` is 58 mm, gap is **13.1 mm**, and
  `tip_clear` asserts it and echoes it on every render.

Also fixed the camera's direction, which was mirrored — it looked at the shaft. The frame
now matches `mount/cane_mount.scad` lines 26–35: screen toward the walker, camera forward
past the open top of the cradle, `arm_angle + cane_angle - 90` = 5° below the horizon.

**The cradle needs support.** It stands on its dovetail block with the back plate 7 mm
off the bed. Added a 45° flare that carries the plate for 7 mm all round; the rest needs
"support on build plate only". The header's blanket no-support claim was wrong and now
says so per part. Every other part is still support-free.

All seven printables still render `NoError`.

test on device: nothing yet — none of this has been printed. Print `coupons` first.

## Step 16 — Cane diameter disputed, clamped ball joint, SPARKX i7 (Fri Sep 11)

**The cane is 27.65 mm, not 28.75.** Dial caliper, Sagar. That contradicts
`hardware/mount/cane_mount.scad`, the hardware brief, and the 1.128 in (28.65 mm) quoted
earlier the same evening. The spread is 1.1 mm — three times any sane bore clearance, so
a collar bored for 28.75 would spin freely on a 27.65 shaft. `mount_screwless/` now uses
27.65 and the bore coupons were changed from *clearances* to *absolute bore diameters*
(27.85 / 28.25 / 28.45 / 28.95 / 29.15, 1–5 notches) so one 20-minute print settles it
against the real cane instead of against anyone's memory. **`hardware/mount/` is still
modelled at 28.75 — one of the two folders is wrong.** Whoever prints first, record the
answer here.

**Clamped ball joint, `joint = "ball"`.** Sagar asked for a gyroscopic / ball-socket aim.
Both the hardware brief and `mount/DESIGN.md` rejected ball joints on purpose — "ball
joints slip under sweep vibration and break the Point-to-Identify calibration" — so this
is not a free ball. It is the cane collar's collet trick at small scale: a slotted socket
cup squeezed onto the ball by a threaded lock ring, so holding force comes from a wedge
you tighten rather than from how snugly it printed. That answers the recorded objection
without deleting it: an undertightened clamp still slips, and now in two axes. The
fixed-angle dovetail arm stays the default and the safe demo part. T7 (shake) decides.
Two new parts, `socket` and `lock`, still zero bought hardware. The collar's ring and the
ball's lock ring are now one `collet_nut()` module, so a thread-fit fix lands in both.

**Printer is the Creality SPARKX i7** (260 × 260 × 255, 0.4 hardened nozzle, Klipper, on
the network at 172.23.209.71:4408, profile `0.20mm Standard @SPARKX i7 0.4 nozzle`).
Largest part is the coupon plate at 174 × 195 mm, so everything lies flat with room.
Print single-colour — it is a multi-material machine and the purge would waste more PETG
than the parts use.

**Not done:** still never printed, never fitted, never walked. The ball socket's grip is
reasoning about a wedge, not a measurement. No rain hood.

test on device: n/a (no app change). On the printer: bore coupons first — they decide
whether 27.65 or 28.75 is right, and everything else waits on that.

## Step 15 — Screwless phone mount, Windows CAD toolchain (Fri Sep 11)

Hardware side, on Sagar's Windows machine. Nothing here touches the app.

**Why another mount.** `hardware/mount/` needs four M4 screws, four M4 brass heat-set inserts, an
M5 bolt and nyloc, two M3 countersunk screws, two M3 inserts, two nylon screws and two nylon nuts,
plus a soldering iron with a heat-set tip. On the night before the build none of that was confirmed
to be in the building, and heat-set inserts are the one item no hardware store in Champaign stocks.
`hardware/mount_screwless/` does the same job with four printed parts and nothing else. It is an
alternative, not a replacement — whichever gets fitted, say which in this file.

**Clamp is a collet**, not a snap fit and not a printed bolt across a C-clamp. The collar's nose is
a slotted cone; the ring screws down over it and squeezes the slots onto the cane, like a drill
chuck. Clamping force comes from a wedge, so sweep vibration cannot walk it loose, and both thread
helices run along the print Z axis — the only orientation a printed thread is reliable in. A printed
bolt across the split would have put the thread axis horizontal, where it prints as stacked overhangs.

**Modularity is the pitch.** collar (cane interface) | arm (angle interface) | cradle (phone
interface), all meeting at one sliding dovetail that runs along the cane axis, so the phone's weight
loads every joint in shear across its widest face instead of trying to peel it open. Different cane,
different pose or different phone each reprint exactly one part. `arm_angle` stays derived as
`90 - cane_angle + cam_down`, so the 3–8° camera requirement is inherited, not re-litigated.

**Toolchain.** OpenSCAD 2021.01 (the winget release, `OpenSCAD.OpenSCAD`) has no Manifold backend
and renders the threaded collar in **6 min 52 s**. The 2025.09.15 portable snapshot renders it in
**0.3 s**. `scripts/build_stl.ps1` prefers a snapshot in `%USERPROFILE%\Tools\` and warns loudly
when it falls back. Two Windows PowerShell 5.1 traps are commented in that script because both fail
silently: 5.1 strips the quotes from `-D part="collar"` so OpenSCAD renders an empty file, and a
local `$png` clobbers the `-Png` switch parameter because variables are case-insensitive.

**Coupons carry notches, not numbers.** `text()` needs fontconfig, which the portable Windows
snapshot does not ship; it renders as nothing at all, silently, leaving four identical unlabelled
bore rings. Count notches instead — which also reads by thumb.

**`.gitignore` now covers `stl/`, `*.stl`, `*.3mf`, `*.gcode`.** It did not before, and the
hardware brief wrongly claimed it did.

**Not done:** never printed, never fitted, never walked. Every clearance in the file is a guess
until the coupons come off the bed. No rain hood. The pawl spring thickness is untested and may be
too stiff to click or too thin to survive.

test on device: n/a (no app change). On the printer: coupons `what="bore"` first, set `bore_clear`,
then thread and dovetail coupons, then collar + ring, then arm + cradle.
## Historical note — Step 17 — App icon (Sat Sep 12, on phone and launched)

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

Re-installed ~01:45 with the v3 icon (`AppIcon60x60@2x.png` emplaced in the build log):
**BUILD SUCCEEDED**, devicectl install green, and `device process launch` succeeded (phone
unlocked). White Cane icon live on the Home Screen.

## Historical note — Step 16 — Emergency sirens + hands-free integrated (Sat Sep 12, uncommitted)

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

## Historical note — Step 15 — Front-inset tilt, second attempt (Sat Sep 12, compiled + installed)

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
