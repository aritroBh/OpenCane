# OpenCane design system

Visual + interaction spec for the iPhone app, the watch companion and the Live Activity.
Code twins: `ios/CaneKit/UI/Theme.swift` (phone tokens + components), `ios/CaneKitWatch/WatchTheme.swift`
(watch), `ios/CaneKit/Speech/SpeechQueue.swift` + `ios/Logic/Sources/CaneKitLogic/NavSupport.swift`
(speech rules), `ios/CaneKit/Haptics/HapticPlayer.swift` + `CueDecider.swift` (haptic patterns).

**Audited against the code on 2026-09-12 (after Step 28); §5 (speech, obstacle, navigation and control
cues), §6 (the Settings page and its Cues card, §6.5) and §9 re-audited after Step 37 (HEAD `076fcaa`:
`SpeechQueue`, `SpeechResume`, `CueRules`, `TorchSwitch`, `HapticsCard`, `HazardsCard`,
`ContentView.SettingsPage`, `CaneKitUITests`); §0, §3, §4, §5.1, §5.3, §6 (four tabs, the inline
per-tab titles, the Family alerts card, the new §6.8 Profile page), §6.3, §6.6, §8 and §9 re-audited
at Step 47 (Sat 2026-09-12 evening: `TabBar`, `ContentView`, `GuideCard`, `ProfilePage`, `Theme`,
`AppModel`'s spoken lines, `AppIntents`, `WatchTheme`, the three XCUITest suites).** Every rule below describes what ships.
Where the original spec (Sep 10) and the Swift disagreed, the Swift won and this file changed; the parts
of the original spec that were never built are kept, marked **Not built**, so nobody "fixes" the code back
toward them by accident. From now on change a rule here and in the Swift in the same commit. Two things
outrank both: `AGENTS.md` hard rule 8 (speech priorities, §5.1) and rule 9 (accessibility labels are a
test contract, §9).

Section numbers are referenced from code comments (`§1`–`§8`, `§6.1`–`§6.8`); keep them stable.

**Added after the audit, from the code:** the hazards layer (`CaneKitLogic/Hazards.swift`,
`Depth/GroundSampler.swift`, `Scene/HazardScanner.swift`, `Scene/OnDeviceVision.swift`,
`Trip/HazardLog.swift`, `UI/HazardsCard.swift`) and `CaneKitLogic/CourseSmoother.swift` (veer
decisions) are now wired into `AppModel` / `ContentView`. Their spoken lines are in §5.1, the ground
hazard taps in §5.2, the veer rules in §5.3 and the "Hazards" card in §6 and §6.5. No test uses a
Hazards label yet (§9). The developer debug footer (`UI/DebugFooter.swift`) was removed; every mention
of it below says so.

---

## 0. Who looks at the screen, and what that forces

| Viewer | Situation | What it forces |
|---|---|---|
| **The blind user** | Never looks. Phone is clamped to the cane; they use speech, the cane's buzz, the watch, or the Action button ("Where am I"). | Every state has words: speech via `SpeechQueue`, and a VoiceOver label / value on screen. VoiceOver order is the selected tab's cards, then the tab bar (Guide / Sense / Settings / Profile). Our own buttons are ≥ 60 pt (big buttons 72 pt). Nothing is colour-only. |
| **The sighted judge / teammate** | Glances at the phone on the cane from ~1 m, in a dark room (demo) or in sunlight (walk). | The Guide instruction, the distance and the depth tiles must be readable at arm's length: tile numerals 28 pt bold, hero distance 64 pt, fills ≥ 6.5:1 against their `ink` text, no thin type, no mid-grey. Dark surfaces for the demo (a bright screen in a dark room blinds the room). |
| **The developer** | Reads engine health, speech backend, watch link and the hazard detections while walking behind. | The debug cards on the **Sense** tab (Hazards) and the **Settings** tab (Haptics, Watch, This phone). There is no debug footer any more (removed): fps is not shown anywhere, and thermal and battery are only in the trip log's `lanes` records. |

**Brand voice.** A safety instrument, not a lifestyle app. Think avalanche beacon or aircraft
standby gauge: calm, terse, trustworthy, legible in the dark. Everything on screen is either a
measurement, a state, or a button. No marketing surfaces.

**The five rules** (the rest of this file is detail):
1. Words first. Speech is the primary channel; the screen mirrors it, never replaces it.
2. Redundancy on every hazard: a depth tile has a fill colour **and** a level word (CLEAR / FAR / NEAR /
   STOP) **and** a number; a pill is always a word on a fill (the SF Symbol is a companion).
3. Big and few. While a route runs the Guide card has seven big buttons in five rows (Where am I +
   Talk to OpenCane, Repeat + Next, Recenter, Simulate walk / Stop simulation, Stop route), never
   more than two per row; everything else lives in the cards below it.
4. Ivory on near-black. The white cane is the brand; the accent is *cane white on ink*, not a hue.
5. Nothing animates that carries meaning. The grid updates at 30 Hz with no transitions.

---

## 1. Typography

Fonts are system only (no bundle, no licensing, full Dynamic Type):

| Face | Used for | Why |
|---|---|---|
| **SF Pro (text design, default)** | Instructions, body, toggles, hints | Highest legibility per point at UI sizes; Dynamic Type native. |
| **SF Rounded** | Hero distance, tile metres, button labels, pills | Wider apertures and rounded terminals hold up better from 1 m and at heavy weights; it is the face Apple uses for glanceable numbers (Fitness, Watch). Only at weights ≥ semibold. |
| **SF Mono** | Nothing on screen today (the developer footer that used it was removed) | `CKFont.mono` stays defined for `accessibilityHidden` developer views. Never for user-facing text. |
| **New York** | *Not used.* | A serif has no job here. Deliberate omission, not an oversight. |

### Scale (text styles, so Dynamic Type just works)

| Token (`CKFont`) | Style | Design / weight | Notes |
|---|---|---|---|
| `hero(_:)` | 64 pt via `@ScaledMetric(relativeTo: .largeTitle)`, **clamped to 80 pt** at the call site (`min(hero, 80)`) | Rounded / heavy, tabular | Distance on Guide (integer metres; the "m" beside it is `button` in `textSecondary`). |
| `tile` | `.title` (28 pt) | Rounded / bold, tabular | Metres in a depth tile; the three trip stats. |
| `instruction` | `.title2` (22 pt) | Text / semibold | Current instruction and the status-card line. **No line limit**: it wraps and never truncates or scales. |
| `button` | `.title3` (20 pt) | Rounded / semibold | Big-button labels. |
| `label` | `.headline` (17 pt) | Text / semibold | Card titles (`textSecondary`, `.isHeader`). |
| `body` | `.body` (17 pt) | Text / regular | Toggle labels, scene description, destination field, Go (semibold). |
| `pill` | `.subheadline` (15 pt) | Rounded / bold, uppercased, kerning 0.9 pt (≈ 0.06 em), tabular | Status pills. One line (`lineLimit(1)`, `minimumScaleFactor(0.8)`), 1–3 short words. |
| `secondary` | `.subheadline` (15 pt) | Text / regular | Hints, error lines, trip-stat labels. Smallest size for sentences. |
| `mono` | `.footnote` (13 pt) | Mono / regular, tabular | Defined, currently unused (the developer footer was removed). Only for `accessibilityHidden` developer views. |

Exceptions the code makes below 15 pt, all on elements that also carry a bigger number or symbol and
whose VoiceOver label carries the full meaning: the position label (`.caption`, 12 pt) and level word
(`.caption2`, 11 pt) inside a depth tile, the captions under the haptic / wrist-cue test buttons
(`.caption`), the watch's compact Describe / Recenter captions (`.caption2`) and its one-line error (`.footnote`), and
the Live Activity route name (`.caption`). Do not add more.

Rules:
- **Tabular numerals everywhere a number can change** (`.monospacedDigit()`): hero distance, tile metres, pills (GPS "±6 M", "BEACON 40%"), Live Activity distance. Proportional digits make "1.2 m → 1.1 m" jitter.
- Dynamic Type: every text uses a text style. The only clamp is the hero (80 pt). `CKBigButton` restacks icon over label at accessibility sizes (`ViewThatFits`) and grows; it never truncates. Tile metres use `minimumScaleFactor(0.5)`, pills 0.8.
- Line height: default. Never tighten. Never letter-space lowercase text.
- Units on screen: a plain space between number and unit. Tiles `"%.1f m"` below 4.5 m, otherwise the word "clear" (∞ is never drawn); hero integer metres; trip distance `"N m"` below 950 m, `"N.N km"` from 950 m; Live Activity `"N m"` / `"N.N km"` from 1000 m; watch title `"N m"`.
- Units spoken: US spelling, words not symbols: "meters", "kilometers", "One and a half meters ahead." (`SpokenDistance.phrase` rounds to half metres: "very close", "half a meter", "one meter", …). Warning lines are distance-first: the time-to-contact ("Two meters ahead") comes before the identity ("door").

---

## 2. Colour tokens

Neutrals are tinted warm (toward the ivory of a cane), never pure grey. Values are sRGB hex. Four
variants per token: light, dark, and increased-contrast light / dark (`Settings → Accessibility →
Increase Contrast`), resolved by UIKit trait collections in `CKColor.dynamic` (phone only; the watch
and the widget use fixed colours, §6.6 / §6.7). Contrast ratios are WCAG 2.x, recomputed 2026-09-11.

### Surfaces and text

| Token | Light | Dark | Light HC | Dark HC | Use |
|---|---|---|---|---|---|
| `background` | `#F4F1EA` | `#0E0D0B` | `#FFFFFF` | `#000000` | Screen ground |
| `surface` | `#FFFFFF` | `#1A1816` | `#FFFFFF` | `#0A0A0A` | Cards |
| `surfaceRaised` | `#EAE6DD` | `#26231F` | `#E3DED3` | `#141210` | Secondary buttons, no-data tiles, neutral pills |
| `border` | `#C9C3B6` | `#3A362F` | `#000000` | `#FFFFFF` | Card hairline 1 pt (3 pt in HC); secondary-button border 2 pt (4 pt in HC) |
| `textPrimary` | `#17140F` | `#F4F1EA` | `#000000` | `#FFFFFF` | 16.3:1 / 17.2:1 on background |
| `textSecondary` | `#5C574D` | `#B5AFA3` | `#3A362F` | `#D9D4C9` | Hints, card titles, the Hazards card's source words. 6.4:1 on light background, 7.2:1 on a light card, 8.1:1 on a dark card |
| `accent` | `#17140F` | `#F4F1EA` | `#000000` | `#FFFFFF` | Primary button fill. **Ink in light, ivory in dark.** |
| `onAccent` | `#F4F1EA` | `#0E0D0B` | `#FFFFFF` | `#000000` | Text on `accent` |
| `ink` | `#17140F` | `#17140F` | `#000000` | `#000000` | Text on every coloured fill (tiles, trusted / warning / danger pills, Stop button). One rule, no exceptions. |

### Lane ladder (same in light and dark; the fill is the signal, so it does not flip)

Thresholds are `CaneKitLogic.TileLevel`, not the view.

| Token | Distance | Normal | HC | Level word on the tile | `ink` contrast (normal vs `#17140F` / HC vs `#000000`) |
|---|---|---|---|---|---|
| `laneClear` | ≥ 2.0 m, or no return | `#4ADE80` | `#22D36B` | CLEAR | 10.5:1 / 10.6:1 |
| `laneFar` | 1.2 – 2.0 m | `#FDE047` | `#FFD500` | FAR | 13.9:1 / 14.8:1 |
| `laneNear` | 0.7 – 1.2 m | `#FB923C` | `#FF7A00` | NEAR | 8.1:1 / 8.0:1 |
| `laneUrgent` | < 0.7 m | `#F87171` | `#FF6B6B` | STOP | 6.6:1 / 7.6:1 |
| `laneNoData` | no depth yet | = `surfaceRaised` | — | NO DATA ("—" instead of metres) | text in `textSecondary` |

Deuteranopia check: far and near are close in hue, which is why the level word and the number are
mandatory on every tile. OKLab lightness is far (0.91) > clear (0.80) > near (0.76) > urgent (0.71), so
the two dangerous states are also the two darkest fills.

### Status

| Token | Normal | HC | Where it appears in the code |
|---|---|---|---|
| `trusted` | = `laneClear` | = HC clear | TRUSTED, ON COURSE, GPS ±N M (≤ 15 m), ENGINE OK, REACHABLE, BEACON N% (running), ElevenLabs voice pill; watch phone-link glyph |
| `warning` | `#FBBF24` | `#FFB000` | SWEEPING, VEER LEFT / RIGHT N°, GPS ±N M (> 15 m), GPS WEAK, the active cue (CENTER / LEFT / RIGHT / HEAD), SPEAKING, NO AIRPODS, BEACON PAUSED |
| `danger` | = `laneUrgent` | = HC urgent | Stop route fill, ENGINE DOWN pill, error lines (as text colour) |
| `neutral` | = `surfaceRaised` | — | GPS SEARCHING / OFF / DENIED, cue CLEAR, QUIET, SYSTEM voice, watch ASLEEP / NOT PAIRED, BEACON OFF / IDLE, HEAD TRACKED / COMPASS ONLY, last watch command. Text in `textPrimary` (the only non-ink pill) |
| `accent` (pill tone) | = `accent` | — | The **CAMPUS** badge on a destination suggestion (§6.3). Not a state: it marks a hand-verified gazetteer entrance. Text in `onAccent`; accent never carries hazard meaning |

### Appearance policy
- The app follows the system appearance (`UIUserInterfaceStyle Automatic`). **For the demo, set the phone to Dark Mode** (dark room; the screen must not light the judges' faces) and run under Guided Access.
- In sunlight the light palette wins: ivory ground, ink text, the same lane fills.
- Accent never carries hazard meaning. Hazard is only ever the lane ladder.
- The watch is always dark (§6.6); the Live Activity is always ink with ivory text (§6.7).

---

## 3. Spacing and radius

4 pt base. Semantic names so layouts read as intent, not numbers.

| `CKSpacing` | pt | Use |
|---|---|---|
| `xs` | 4 | Icon-to-text inside a pill and a stacked button |
| `sm` | 8 | Between pills; grid tile gap; GPS / beacon pill rows |
| `md` | 12 | Inside cards between rows; icon-to-label in a big button |
| `lg` | 16 | Card padding; between two big buttons in a row |
| `xl` | 24 | Between cards on the page |
| `xxl` | 32 | Reserved (defined, currently unused) |
| `gutter` | 20 | Screen edge |

| `CKRadius` | pt | Use |
|---|---|---|
| `tile` | 14 | Depth tiles |
| `button` | 18 | Big buttons (72 pt tall → radius ≈ ¼ height, reads as a slab not a pill) |
| `card` | 20 | Cards |
| `pill` | 999 | Declared for pills; the pill view draws a `Capsule` |

All shapes use `.continuous` corners. Watch buttons use radius 14.

Touch targets (`CKMetrics`): `CKBigButton` is ≥ 72 pt tall (`bigButton`), full width or half width (two per row with
`lg` between them); a `layout: .tile` big button in a two-up pair (the Guide's Where am I / Talk to
OpenCane, Step 47) is ≥ 108 pt tall (`CKMetrics.tile`), and the pair's `HStack` stretches both tiles to
the taller one. Every other button we draw (Go, the four haptic test buttons, the four wrist-cue
buttons, Share hazard map) is ≥ 60 pt tall (`touchTarget`). System `Toggle`s keep their system size (≥ 44 pt, HIG); the destination search field
and every destination suggestion row are `touchTarget` (60 pt) like the buttons beside them. Tiles are not tappable (they are a display). Watch buttons are ≥ 44 pt
(`WKSpacing.touchTarget`: 48 pt pushed the bottom row off a 46 mm screen). Pills are 32 pt tall and not
interactive.

Elevation: none. No shadows — a card is a fill and a hairline. Depth is not a metaphor we need
when the screen is a gauge.

---

## 4. Motion

Motion never carries information. The app owns two animations, and both honour Reduce Motion
(`accessibilityReduceMotion`):

| Event | Normal | Reduce Motion |
|---|---|---|
| Depth grid update (30 Hz) | **None.** Fill, word and number change instantly. | Same |
| Big button press (`CKBigButtonStyle`, also Go and the test buttons) | Scale 0.97 on a 0.12 s spring; `.sensoryFeedback(.impact(weight: .light))` on **press-down** (`trigger: isPressed` with the condition `$0 == false && $1`, i.e. the not-pressed → pressed edge; an earlier revision of this file said "on release" — the code is the truth) | Opacity 0.85 only; haptic kept |
| Root tab switch (`CKTabBar` + `ContentView` page) | Incoming page **fades in** over 0.16 s (`.transition(.asymmetric(insertion: .opacity, removal: .identity))`); the accent capsule slides between icons (`matchedGeometryEffect`, 0.16 s spring) so pill and page land together; `.sensoryFeedback(.selection)` | Instant page swap; capsule jumps; selection haptic kept |
| Everything else (pills, distance, instruction, cards appearing) | Instant | Instant |

Never animate layout of the grid. Never animate colour of a lane tile (a fade through orange
lies about the distance for 150 ms). Tab motion is chrome only: it does not encode a distance
or a hazard. **Pages never slide sideways** — a horizontal slide implies travel through an
ordered set, and it read as "going forward" even when moving back left. Fade-in only — never
a symmetric cross-fade: keeping both pages alive inside the animation dropped frames on device
(two ScrollViews plus Sense's SceneKit preview teardown/setup composing at once).

**Not built** (original spec, deliberately dropped): urgent-tile 2 Hz pulse and 4 pt border, 150 ms pill
cross-fade, `.numericText()` distance transition, sliding obstacle banner, arrival sheet.

---

## 5. Cue mapping: every cue → felt, heard, shown

Sources: `CueDecider` (obstacle cues, CaneKitLogic) → `HapticPlayer` (phone Taptic Engine, felt through
the cane); `CueSpeechPolicy` (which obstacle cues are also spoken); `ObstacleNamer` (mesh names);
`NavigationEngine` (waypoint lines, veer, wrist cues); `BeaconEngine` (spatial click, AirPods);
`WatchModel` (wrist haptics); `GroundHazardDetector` + `GroundHazardPolicy` (LiDAR drop-offs, CaneKitLogic)
and `HazardScanner` (signs, hazard watch). All speech goes through `SpeechQueue`; where a cut line resumes
and how long the pause between bands is are `SpeechResume` (CaneKitLogic, Step 37). How much is said is
the Cues card's level × place, `CueRules` (CaneKitLogic `CueProfile.swift`, Step 36): it gates obstacle
names and sign phrases and sets the head distance. **Step 36 changes speech and the head distance only —
every haptic pattern below is identical at every Cue detail level** (the card's caption says so; torso
taps by level are a later step, `CueLevel` doc comment). The flashlight's spoken outcomes are
`TorchSwitch` (CaneKitLogic, Step 34).

### 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8)

| Priority | What speaks at it (literal lines from the code) | TTL while queued |
|---|---|---|
| `.safety` (3, top) | "Head height." (`CueSpeechPolicy`); LiDAR ground hazards "Two meters ahead, drop-off." / "… hole." / "… step up." / "… low obstacle."; route-start failure "Obstacle detection is not ready. Route did not start. Check the camera and reopen OpenCane."; "Obstacle detection did not restart. Close and reopen OpenCane." (2 s after Both cameras off, only if depth is not delivering); **GPS fallback** (Step 42, `failQueuedRouteStart`) "Obstacle detection warming up. Guiding with GPS." when the depth interlock times out and the route starts on GPS alone (§5.3) | 6 s "Head height.", 3 s ground hazards, 30 s route-start failure and the depth-did-not-restart line, 15 s the GPS fallback |
| `.nav` (2) | Waypoint `say` lines; "Route started. <route>. First: …"; "Passed <place>. <Next place> in N meters." / "Passed one waypoint."; "Veer left." / "Veer right."; "GPS weak. Waypoint cues paused until it recovers." / "GPS back."; "You are close to <place>. Keep going toward it, or press Next to finish."; the arrival trip summary; "Recentered."; "Route stopped."; "Route start canceled."; "No route running."; "OpenCane ready."; "Obstacle detection warming up. Route will start when it is ready."; "Screen locked. Obstacle warnings are paused until you unlock." (ARKit stops with the screen); **family alerts** "Possible fall detected. Telling your family." (`FallWatcher` episode with "Detect the cane falling" and "Send cane events to family" both on) and the webhook spam guard "Just a moment. Try again in N seconds." (`ActionRateLimit`, 10 s between repeats of Save family emails / Send test event); **refusals** "Both cameras cannot run while a route is starting. Wait for obstacle detection to be ready."; "Both cameras cannot run while a route is guiding you. Stop the route first."; "Head tracking without AirPods cannot change while a route is guiding you. Stop the route first." / "… while a route is starting. Wait for obstacle detection to be ready." (all four prefetched in `AppModel.commonLines`); "This phone cannot show two cameras at once."; **Both cameras** "Both cameras on. Obstacle detection, distance warnings and sign reading are paused." / "Both cameras off. Obstacle detection is restarting." / "Obstacle detection is back." / a failed start "<why> Obstacle detection is back on."; **Cues card** "Quiet cues." / "Standard cues." / "Detailed cues." / "Outdoor mode." / "Indoor mode." (`CueLevel` / `CuePlace.spokenLine`, spoken once per change, prefetched via `CueRules.allSpokenLines`); **voice feature switches** (Shortcuts "Turn a feature on or off") "Obstacle names on." plus `CueRules.namesLimitLine` when the level or place limits names ("Quiet cues name nothing." / "Standard cues name only doors, on a route." / "Indoor mode names nothing."), or "<feature> off. <consequence>"; headphone and channel lines ("<AirPods> connected.", "Headphones disconnected. Beacon paused.", "No headphones. Beacon paused until AirPods connect.", "Watch not reachable. Open OpenCane on the watch.", "Haptics unavailable. Obstacle cues will be spoken."); "Phone is hot. Door and wall names and sign reading paused."; "Location access is off. Turn on Location for OpenCane in Settings to navigate."; "Camera access is off, so obstacle warnings cannot work. Turn on Camera for OpenCane in Settings."; MapKit route lines | 12 s waypoint lines and the arrival hint, 30 s arrival summary, 20 s channel, Location and Camera lines, 15 s "Both cameras on…", 12 s failed-start line, 10 s refusals, "Both cameras off…", "…cannot show two cameras…", voice feature switches and "Phone is hot…", 8 s "Obstacle detection is back." / warm-up / default, 6 s Cues card changes, 10 s "Screen locked…" and the fall line, 4 s "Just a moment…" |
| `.obstacle` (1) | Mesh names "Two meters ahead, door" (door / seat / window / table; never "wall"; only with "Speak obstacle names" on **and** `CueRules.allowsName`, and load-limited, see rules); "Left." / "Right." / "One meter ahead." when the phone cannot buzz; signs "Sign: sidewalk closed." (Quiet / Indoors: only `CueRules.safetySignPhrases`); hazard watch "Caution: 3 meters ahead, cones."; **threat watch** (Step 43, `ThreatWatch` over the vision reply) "Careful. The camera described a possible <term> ahead." — it quotes the camera, never asserts, at most one per 2 min | 4 s names, 6 s cue and caution lines, 8 s sign lines and the threat line |
| `.scene` (0, bottom) | "Describing."; the one-sentence description (cloud model, or on-device when there is no key or no network); "Camera warming up. Try again."; "Scene description failed."; flashlight (`TorchSwitch.Outcome.spokenLine`, all six prefetched) "Flashlight on." / "Flashlight off." when the device confirms, "The flashlight did not switch on." / "… off." at the 2 s settle deadline (or at once on a thrown device error), "The flashlight turned on." / "… off." when it changes unasked; "This phone has no flashlight."; **Talk to OpenCane** "Still working on your last question." (a second transcript lands while the first is still processing); **Profile → Announce Medical ID** "<name>. White cane user, legally blind. Blood type <type>. Allergies: <list>. Emergency contact: <name>, <phone>." (`ProfilePage`; moved from `.obstacle` to `.scene` in the Step 47 audit — a user-requested paragraph never sits in the hazard band, so an obstacle name or a route line can cut it and never the reverse) | 3 s "Describing.", 20 s description and the Medical ID summary, 4 s flashlight confirmations, 12 s flashlight failures / device changes (`Outcome.queueSeconds`), 6 s "no flashlight" and "Still working…", 8 s default |

**Low light (Step 49).** Added to the bands above: at `.nav`, 10 s, once per darkness episode
(`LowLightPolicy` confirms dark: smoothed ARKit lux under 40 for 3 s): "Low light. Obstacle
detection still works." — or "Low light. Obstacle detection still works. Flashlight on." when the
app is lighting the torch with it (a route guides, "Flashlight on in the dark (routes)" is on, the
torch exists and is off, battery > 20 %, no thermal backoff); the `TorchSwitch` "Flashlight on."
confirmation is then muted (it would be the same news a second later), "Flashlight off." at the
end of the episode / route is still spoken. At `.safety`, 15 s: "Camera tracking is limited,
probably low light. Obstacle detection is running on LiDAR." — the honest twin of "Obstacle
detection warming up. Guiding with GPS." when the route-start gate timed out with depth live but
ARKit tracking never `.normal` (`DepthReadiness.TimeoutReason.trackingLimitedDepthLive`). At
`.scene`, 20 s (10 s for a question): "It is dark, so this may miss things. " in front of a
"Where am I" answer while dark with no torch lit; the cloud model may itself answer exactly "It is
too dark to see." (`CloudSceneGate.tooDark`), spoken as the answer with the LiDAR line in front.
All three fixed lines are in `AppModel.commonLines` (prefetched).

The flashlight's lines are the lowest band on purpose (it is a convenience, not guidance): a confirmation
that waits behind a long route line for more than 4 s is dropped; the switch itself still settles.

Rules (all in `SpeechQueue`; the numbers in `SpeechResume`, pinned by `SpeechResumeTests`):
- A **strictly higher** priority interrupts the line playing (at a word boundary with the system voice, at once with an ElevenLabs clip); equal or lower queues behind it, FIFO within a priority. "Head height." therefore cuts everything and nothing cuts it (only `stopAll`, the watchdog or a call / Siri stop a `.safety` line).
- **Cut in, then resume** (Step 37, owner decision 2026-09-12): the interrupted line goes back to the front of its band and, after the interrupter, **continues from the start of the clause it was cut in** — "Route started. … First: Leaving Townsend Hall, *Head height.* … then the path west." — never restarted from its first word.
  - Clauses start after `. ! ? , ;` or `:` followed by whitespace, except the period of an abbreviation ("St.", "Dr.", "Ave.", "Prof." … `SpeechResume.abbreviations`) or an initialism ("U.S."). A decimal point ("2.5") is not followed by a space, so it never splits.
  - Progress: the system voice's last `willSpeakRange` word, heard in full (the stop is at a word boundary); an ElevenLabs clip's `currentTime / duration` mapped onto the text and backed off 8 UTF-16 units (≈ 0.5 s, `mp3MarginUTF16`). The system voice then speaks the remainder; a clip seeks the whole cached file to the clause 0.25 s early (`clipLead`). Resuming early may repeat a few words; resuming late would lose an instruction, so the margins lean early.
  - A cut inside the first clause resumes from the top (trip log `resume_from: 0`). Nothing is re-queued when only punctuation or whitespace is left, or when a clip had already finished.
  - A line resumes **at most 3 times** (`maxResumes`) and its resume point never moves backwards (`nextResume`); a fourth cut drops it (Repeat recovers it). On its **first** cut its deadline becomes max(its TTL deadline, 8 s after the cut); later cuts keep that deadline, so a line cut again and again still goes stale.
- A phone call / Siri (`.began`) or the voice hold (the walker dictating to OpenCane; `.safety` skips the hold) re-queues the playing line from its **last resume point** — the top for a line never cut — not from the cut clause: after seconds of something else a clause fragment has no context.
- **Pause between kinds of line** (`SpeechResume.gapSeconds`, 0.35 s): when a line ends and the next queued line is a different band, 0.35 s of silence comes first, so a warning and the direction it cut are heard as two things. No pause before a `.safety` line, between two lines of the same band, or when nothing played before. During the pause `isSpeaking` stays true (the beacon stays ducked). A new `.safety` line — or a new line that needs no pause after the band that just ended and ties or outranks the queue head — ends the pause and speaks at once; anything else queues. **Repeat** speaks at once during the pause unless the line the pause is waiting for outranks it. `stopAll`, a call / Siri and the voice hold end the pause.
- Queued lines expire (TTL above); expired lines are purged whenever a line ends and again after the pause, so a stale "turn left" is never spoken late. A line that starts at once plays in full.
- Coalescing: a line identical to the one playing or already queued is dropped. **Repeat** bypasses this (`sayAgain`): it removes any queued copy, speaks the last line actually spoken plus " Next, <place>, in N meters.", interrupting an equal-or-lower line (which is *not* re-queued) and queuing behind a higher one.
- Load policy (`SpeechLoadPolicy`, Step 30): a mesh name (load class `.ambientObstacleName`) is dropped while anything is speaking, pausing or interrupted, or within 7 s of the last admitted name; a dropped name is logged `speech_suppressed`, never queued. Every other line fails open.
- Phone call / Siri: new lines queue (deduplicated) and nothing plays; on `.ended` (or after 15 s if it never arrives) the session is re-activated — up to 3 attempts, 1 s apart — and the queue drains in priority order.
- Warnings never wait for the network: `.obstacle` and `.safety` lines that are not already cached use the system voice at once (and prefetch the ElevenLabs voice for next time). Other lines use a cached ElevenLabs clip, else fetch it for at most 2.5 s in total, else fall back to the system voice; within 60 s of a natural-voice failure every cache miss goes straight to the system voice.
- Watchdog: 6 s + characters / 6 (the characters actually to be spoken — the remainder of a resumed line) after a line starts, a missing end callback counts as the end.
- Trip log (`AppModel.start` wires the hooks): every line handed to a voice backend is `speech_dispatch {text, priority, replays, resume_from}` — `text` is always the whole line, `replays` how many times it was already resumed, `resume_from` the UTF-16 offset it started from (> 0 = resumed mid-line) — and every natural end (finished or watchdog, not a cut) is `speech_end {priority}`. Dispatched is not the same as heard. `ios/scripts/cue_audit.py` (`make audit`) turns them into `replays_resumed_mid_line`, `replays_from_line_start` and `cross_band_pause_under_0_3s` (should be 0).

Old comments that say "P0 / P1 / P2" refer to the original spec: P0 ≈ `.safety` + `.nav`, P1 ≈ `.obstacle`, P2 ≈ `.scene`. The four levels above are the truth.

### 5.2 Obstacle cues (phone Taptic Engine, felt through the cane)

Decided by `CueDecider` on every trusted depth report (~30 Hz). One cue at a time, priority **head >
centre > left > right**. A zone switches on below its threshold and off only 0.15 m beyond it
(hysteresis); cue *changes* are ≥ 400 ms apart; a discrete cue (left / right / head) re-fires at most
once per second while it stays active. The Cues card changes the head distance here (Place: Indoors),
which names and signs are spoken, and — since Step 41 — which **torso** cues the cane renders
(`TorsoHapticPolicy`, CaneKitLogic, layered over the decider; the head cue is never touched):

| Cue detail × Place | Centre torso (`centerApproach`) | Left / right torso | Head |
|---|---|---|---|
| **Detailed + Outdoors** (default = today) | Geiger loop as below | taps as below, **except** while that side's distance has held within ±0.1 m for ≥ 2 s (shorelining a wall or hedge: `suppressed: shoreline`) | as below |
| **Standard + Outdoors** | **no loop**: one transient (intensity 0.8, sharpness 0.6) when the centre distance is < 1.5 m **and closing**; a strong triple (3 transients 80 ms apart, 1.0 / 0.6) when < 0.6 m — proximity only, closing or not, so a walker inching in at under 0.1 m/s is still told (Muse review); each once per approach, both re-armed by 1.5 s of clear (`playCenterOnset(strong:)`; log `render: center_onset` / `center_strong`) | nothing (`suppressed: standard_side`) | as below |
| **Quiet + Outdoors** | nothing (`suppressed: quiet`) | nothing | as below |
| **Indoors, any level** | nothing (`suppressed: indoors`) | nothing | as below, from 1.2 m |
| **Crossing settle** (standing at a curb, `NavigationEngine.isCrossingSettle`), Standard or Detailed | nothing (`suppressed: crossing_settle`) | nothing | as below |

"Closing" = the centre distance is ≥ 0.1 m less than it was ≥ 1 s earlier over trusted frames. A
suppressed torso cue is neither mirrored to the watch nor spoken (Quiet means nothing for torso, even
with haptics silenced); it is logged as a `cue` record with `suppressed: <reason>` so
`ios/scripts/cue_audit.py` can tell held load from felt load. A Standard onset is mirrored and spoken
like a centre cue. The rows below are the Detailed patterns.

| Cue | Trigger | Felt (`HapticPlayer`) | Heard (`CueSpeechPolicy`, `.obstacle` unless noted) | Shown (phone) | Wrist (mirror) |
|---|---|---|---|---|---|
| `clear` | nothing in range | Nothing; any loop stops | Nothing | Tiles CLEAR; Haptics card cue pill CLEAR (neutral) | — |
| `centerApproach(d)` | torso-centre lane < 2.0 m | Geiger loop: one transient (sharpness 0.6) repeated at 4 / d Hz, clamped 2 Hz @ 2 m → 8 Hz @ 0.5 m; intensity 0.6 @ 2 m → 1.0 @ 0.5 m | Only when the phone cannot buzz: "<distance> ahead." at most every 4 s | Torso-centre tile; cue pill CENTER (warning) | `.click` |
| `left` | torso-left lane < 1.2 m | 2 transients 120 ms apart, intensity 0.9, sharpness 0.5 | Only when the phone cannot buzz: "Left." at most every 4 s | Torso-left tile; cue pill LEFT | `.start` |
| `right` | torso-right lane < 1.2 m | 3 transients 100 ms apart, intensity 0.9, sharpness 0.5 | Only when the phone cannot buzz: "Right." at most every 4 s | Torso-right tile; cue pill RIGHT | `.stop` |
| `head` | any head-row lane < 1.5 m outdoors, **< 1.2 m with Place = Indoors** (`CueRules.headEnterM`, pushed into `CueDecider.thresholds.head`; clears at 1.65 / 1.35 m) | 2 transients 80 ms apart, intensity 1.0, sharpness 1.0; re-fires every second while the obstacle stays — **never suppressed** | Spoken even when the phone can buzz: "Head height." at `.safety`, once per obstacle episode (a new episode starts after the cue clears or another cue is spoken), no more than one per 4 s; identical at every Cue detail level (the safety floor) | Head-row tile; cue pill HEAD | `.failure` (reserved for head height) |
| Mesh name (`ObstacleNamer`) | door / seat / window / table < 3 m at the image centre (`SpokenPhrases.obstacleMaxDistance`); off when thermal ≥ serious. Walls are **never** named: the namer still has a 1.5 m wall limit, but no `CueRules` level allows a wall (the cane trails walls) | — | "Two meters ahead, door" (`.obstacle`, 4 s TTL): only with "Speak obstacle names" on (Haptics card, **off by default since Step 36**) **and** `CueRules.allowsName` — Detailed + Outdoors: every class but wall; Standard + Outdoors: doors only, and only while a route guides; Quiet, or Indoors at any level: nothing. On a class change or ≥ 1 m of movement, at most every 2.5 s, then at most one every 7 s and only while the queue is free (`SpeechLoadPolicy`) | — | — |
| Ground hazard (not `CueDecider`: `GroundHazardDetector`, "Detect drop-offs" toggle, off by default) | drop-off / hole / step up / low obstacle in a 0.9 m wide corridor 1.5–3.5 m ahead: an edge against the near-field ground, confirmed on 3 of the last 5 trusted frames | 4 heavy taps 70 ms apart (intensity 1.0, sharpness 0.3), `playGroundHazard` | Always spoken, `.safety`: "Two meters ahead, drop-off." (`GroundHazardPolicy`: the same hazard in the same place, e.g. a curb you stand at, is said once, then at most every 30 s, and again once it is 1 m closer) | Hazards card LIDAR row; hazard map entry | `.click` when the phone cannot buzz or the mirror toggle is on |
| Sign / hazard watch (`HazardScanner`, camera) | "Read signs" (on by default): on-device text every 3 s, small text down to 1/128 of the frame height (7.5 cm letters from ≈ 7 m, measured); never "STOP" (a drivers' sign); Cue detail Quiet or Place Indoors reads only `CueRules.safetySignPhrases` (SIDEWALK CLOSED, ROAD CLOSED, USE OTHER SIDEWALK, NO PEDESTRIANS, DO NOT ENTER, WET FLOOR, KEEP OUT, WORK ZONE, CONSTRUCTION, DETOUR, DANGER, CAUTION, PUSH BUTTON, CLOSED — i.e. every phrase except EXIT / ENTRANCE / PUSH / PULL; fed to `HazardScanner.signAllowedPhrases`); "Hazard watch" (off by default): one frame to the vision model every 8 s while walking a route | Nothing | "Sign: sidewalk closed." (8 s TTL; each sign at most once a minute — a phrase filtered out by the level is not stamped, so it never silences an allowed one); "Caution: 3 meters ahead, cones." ("NONE" is silent) | Hazards card SIGN / WATCH rows; hazard map entry | — |
| Sweeping | \|ω\| ≥ 0.6 rad/s | No new cue and no stop: the decider freezes, so a running centre loop keeps its last rate until the next trusted frame | Nothing | Obstacles pill SWEEPING (warning, spoken "Sweeping, warnings paused"); tiles keep drawing the latest values | — |
| No depth | before the first depth frame / no LiDAR | Nothing | Nothing (at launch: "OpenCane. This phone has no LiDAR." on a non-LiDAR phone) | Tiles "—" / NO DATA; status card "Waiting for depth…" / "No LiDAR / sceneDepth on this device" | — |

"The phone cannot buzz" = the haptic engine is down **or** "Silence haptics" is on. In that case every
fired cue is also mirrored to the watch; "Mirror obstacle cues to the watch" (off by default) mirrors
them while the phone buzzes too. The mirror is throttled to one message per kind per second.

Hazard watch replies: with a cloud key the cloud gets 2.5 s, then the on-device model answers instead.
A reply about a frame older than about 4 m of walking (min(5 s, 4 m ÷ speed)) is dropped; one older than
2 s keeps its hazard but loses its distance. Every announced hazard (ground, sign, watch) is written to
`Documents/hazards/hazards-<session>.geojson` with the GPS fix and a photo.

### 5.3 Navigation cues

| Cue | Heard (`.nav`) | Wrist (`WatchModel`) | Beacon (AirPods) | Shown (phone) |
|---|---|---|---|---|
| Route start | If LiDAR + camera are available, "Obstacle detection warming up. Route will start when it is ready."; then "Route started. <route name>. First: <WP1 say>" + any channel warnings only after the trusted-depth gate clears. No-LiDAR / camera-denied devices keep the documented GPS-only start with an explicit warning, and since Step 42 a depth interlock that times out (7 s) no longer refuses the route: `failQueuedRouteStart` says "Obstacle detection warming up. Guiding with GPS." at **`.safety`** (15 s), logs `route_readiness {state: timed_out_fallback_gps}` and starts GPS guidance at once (the watch shows "Guiding with GPS"). | — while queued; normal route cues after start | Starts only after 3 fresh same-frame trusted depth reports on the LiDAR path | While queued, the Guide card shows the warm-up / timeout status, keeps Start disabled, and exposes **Cancel route start**; after start, instruction = next waypoint's `say`; Repeat / Next / Recenter / Stop appear |
| Waypoint reached (turn > 30°) | Its `say` line | `.directionDown` (right) / `.directionUp` (left), once | Holds the previous leg's bearing until the turn is made (`TurnSettle`) | Instruction advances to the next `say` |
| Waypoint reached (crossing) | Its `say` line ("… Crossing. … Listen for traffic …") | `.notification` (a crossing beats a turn; a skipped crossing still taps) | **Silent** until you stop at the curb or have turned | Instruction advances |
| Waypoint passed without entering | "Passed <place>. <Next place> in N meters." | none | Live at once | Instruction advances |
| Fences skipped (bad GPS) | "Passed one waypoint." / "Passed N waypoints." then the reached line | as above | as above | |
| Curved leg (`curved: true`) | the waypoint line guides | — | Silent for the whole leg; no veer | Bearing pill hidden |
| Off-bearing > 25° for 3 s | "Veer left." / "Veer right." (then 10 s cooldown) | `.directionUp` / `.directionDown` | Continuous while navigating (except the silent cases above): the click comes from the target bearing, silent inside 10° of error, full volume by 90° | Bearing pill "Veer left N°" (warning) vs "On course" (trusted, ≤ 25°) |
| GPS worse than 20 m for 10 s | "GPS weak. Waypoint cues paused until it recovers." / later "GPS back." | — | — | GPS pill ±N M (warning) + GPS WEAK pill |
| Standing near the destination 20 s without arrival (poor GPS at the door) | "You are close to <place>. Keep going toward it, or press Next to finish." once. Checked by the 10 Hz clock, so it fires while standing still with no new GPS fixes | — | — | — |
| Arrived (two-hit rule, `docs/route_isr_cif.md`) | The last `say`, then the summary "<destination>. 1.0 kilometers, 14 minutes, 1300 steps." | `.success`, once | Stops; head tracking stops | Instruction "Arrived: <say>"; card title "Arrived"; Live Activity shows the arrival glyph and is dismissed 60 s later |
| Stop route | "Route stopped." (queued lines are dropped first) | — | Stops | Back to Start route to CIF / destination field |

Veer cues are muted while a turn is settling, inside the fence of the corner just reached, within 2 ×
radius of an intermediate waypoint, on a curved leg, and on a poor (> 20 m), stale (> 5 s) or slow
(≤ 0.5 m/s) fix. Walking faster than 0.7 m/s, veer is judged on the 15 m smoothed course
(`CourseSmoother`), not the raw heading; that course history is emptied at every waypoint, while inside
the reached corner's fence, and after each veer cue (so a veer already corrected does not fire again
when the 10 s cooldown ends).

Felt on the cane: every wrist cue in this table also plays on the phone (`HapticPlayer.playNav`) as soft
continuous buzzes (intensity 0.75, sharpness 0.15, 0.18 s apart), deliberately unlike the crisp
obstacle taps: turn left or "Veer left." one 0.45 s buzz, turn right or "Veer right." two 0.35 s
buzzes, crossing three 0.3 s buzzes, arrived long-short-long (0.4, 0.12, 0.4 s). Nothing plays while
"Silence haptics" is on or the engine is down.

The beacon: a 40 ms 1.2 kHz decaying tick every 0.4 s, HRTF-spatialised 10 m out at the target bearing,
listener yaw = phone heading + AirPods head yaw, ducked to 30 % while speech plays. It plays **only into
headphones**; until the AirPods reference is re-zeroed after a waypoint (auto when walking straight, or
Recenter) it ignores head yaw.

### 5.4 Controls and system events

| Event | Felt | Heard | Shown (phone) | Watch |
|---|---|---|---|---|
| Where am I (phone button, watch Describe, Action button shortcut, Camera Control if it fires) | light impact on press-down (phone button, §4) | "Describing." then the one-sentence description (`.scene`); without a key or network the on-device describer answers (Vision + Apple's on-device model, or a template). It waits up to 3 s for a camera frame; the frame from before a screen lock or backgrounding is dropped, so after unlocking it waits for a fresh one ("Camera warming up. Try again." if none comes) | Button reads "Describing…" (value "in progress", disabled); result text under it; error line in red | `.click` confirm on send |
| Repeat (phone, watch, "Repeat in OpenCane") | light impact | The last line actually spoken + " Next, <place>, in N meters." | Instruction unchanged | `.click` |
| Next (phone, watch button, crown 3 detents in 1 s) | light impact | The skipped waypoint's own line; "No route running." when idle | Instruction advances | `.click` |
| Recenter (phone, watch) | light impact | "Recentered." | — | `.click` |
| Watch command fails | — | — | — | `.retry` + red line "Phone not reachable"; phone older than watch: `.retry` + "Update the phone app" |
| Headphones connect / disconnect | — | "<name> connected." / "Headphones disconnected. Beacon paused." | Beacon pill BEACON PAUSED + NO AIRPODS (warning) | — |
| Watch not reachable at route start | — | "Watch not reachable. Open OpenCane on the watch." | Watch card pill ASLEEP (neutral) | — |
| Haptic engine down | (cues go to the watch and to speech) | at route start, if the watch is also unreachable: "Haptics unavailable. Obstacle cues will be spoken." | ENGINE DOWN (danger) | obstacle mirror |
| Thermal `.serious` / `.critical` | — | "Phone is hot. Door and wall names and sign reading paused." once per transition into hot (`.nav`) | Mesh classification off (so no mesh names), sign reading and hazard watch paused, the live camera view stops updating; status card "Mesh classification off (thermal)". The thermal state is only in the trip log | — |
| Battery | — | Nothing | Nothing on screen; the trip log only | — |
| Flashlight switch (Sense → Hazards card "Flashlight"; `AppModel.setTorch` + `TorchSwitch`, Step 34) | — | Once per outcome, `.scene`: "Flashlight on." / "Flashlight off." when the device's own `isTorchActive` report (KVO) confirms the request (4 s TTL); "The flashlight did not switch on." / "… off." when the device is not there at the 2 s settle deadline, or at once on a thrown device error (12 s); "The flashlight turned on." / "… off." when the torch changes with no request open, e.g. a thermal cut-out (12 s). A quick off→on speaks one confirmation and never "turned off" (the off's late report lands inside the on's window). "This phone has no flashlight." when there is no torch | The switch shows the request **at once** and holds it through the settle window — no snap-back (the old code read `isTorchActive` on the next line, got the stale value and needed two presses); after the deadline it shows the device state. Works mid-route and while Both cameras runs; never persisted, off at every launch. Trip log: `torch {action: request_on / request_off, active}` per press, then `torch {action: confirmed(on: true) / failed(requested: true) / changedByDevice(on: false), active, text, error?}` per spoken outcome (a silent outcome writes nothing); `unsupported` for no torch | — |
| Low light (Step 49; `LowLightPolicy` in CaneKitLogic over `LaneReport.ambientLux`, `AppModel.updateLowLight` / `lowLightAct`) | — | Once per darkness episode, `.nav`, 10 s: "Low light. Obstacle detection still works." — with " Flashlight on." appended when the app lights the torch (route guiding, Mount "Flashlight on in the dark (routes)" on, torch present and off, battery > 20 %, no thermal backoff); the `TorchSwitch` "Flashlight on." confirmation is muted then, "Flashlight off." when the app releases it (light back for 5 s over 120 lux after the 60 s minimum on-time, Stop, arrival) is spoken | Guide card DARK pill (warning) beside GPS while dark; Details → Scene engine "Light" row (§6.2). Trip log `light {state: unknown / lit / dark, lux, torch, torch_by_app}` on every state change and app-torch release; `torch {…, by_app}` on the request; `scan` / `hazard_watch` gain `light: "dark"` | — |
| Cue detail / Place change (Settings → Cues, Step 36) | — | Once per change, `.nav`, 6 s: "Quiet cues." / "Standard cues." / "Detailed cues." / "Outdoor mode." / "Indoor mode."; re-selecting the current segment says nothing | The segment is selected; the caption under the pickers restates what the level × place does today (§6.5); persisted (`UserDefaults` `cueLevel` / `cuePlace`). Trip log `cue_profile {level, place, text}`; the launch `start` record carries `cue_level`, `cue_place`, `obstacle_names` | — |
| Both cameras on / off (Sense → Hazards card "Both cameras (pauses obstacle detection)") | No obstacle cues while on: ARKit, the haptic loop, the cue decider, sign reading and front-camera head tracking are stopped | On: "Both cameras on. Obstacle detection, distance warnings and sign reading are paused." (said before the cameras change hands). Off: "Both cameras off. Obstacle detection is restarting.", then 2 s later "Obstacle detection is back." only if depth is really delivering, otherwise "Obstacle detection did not restart. Close and reopen OpenCane." at `.safety`. A start that delivers no frames puts everything back and says "<why> Obstacle detection is back on." | Back camera full frame, front camera inset bottom-trailing (a third of the width), **both upright** in the portrait-only UI however the phone was held when it started (upright confirmed on the phone, trip log 2026-09-12T22-20-53Z `back_rotation` 90 / `front_rotation` 0; started flat or sideways is `docs/stress_test_plan.md` D20): a fixed angle per camera, back 90°, front 0° (270° if 0° is unsupported), never a `RotationCoordinator` angle (`DualCameraRotation`; each one-angle-for-both fix broke one feed). The inset is not mirrored, so it agrees with the back feed on left and right. Red caption "Back camera with the front camera inset. Obstacle detection is paused." (VoiceOver reads it; the picture is hidden). Starting a route turns it off first. Trip log `both_cameras {action: start, front_rotation, back_rotation, front_capture_angle, back_capture_angle, front_size, back_size, front_portrait, back_portrait, front_mirrored, …}`, `stop`, `depth_after {depth_fps, depth_running, confirmed}`, `off_for_route` | — |
| Both cameras refused | — | Route guiding: "Both cameras cannot run while a route is guiding you. Stop the route first."; route starting: "Both cameras cannot run while a route is starting. Wait for obstacle detection to be ready."; no multi-cam: "This phone cannot show two cameras at once." (all `.nav`, 10 s) | The switch snaps back off and obstacle detection is never paused. While a route guides, the caption "Both cameras cannot run while a route is guiding you. Stop the route on the Guide tab first." stays on screen for the **whole route**, whatever the switch shows (`BothCameras.state` → `.blockedByRoute`, Step 34); the Guide error line reads "Stop the route before using both cameras". The switch is disabled while a route start waits for depth and on a phone without multi-cam. Trip log `both_cameras {action: refused_route / refused_route_start / unsupported}` | — |
| Head tracking without AirPods refused (Sense → Hazards card) | — | Route guiding: "Head tracking without AirPods cannot change while a route is guiding you. Stop the route first."; route starting: "Head tracking without AirPods cannot change while a route is starting. Wait for obstacle detection to be ready." (`.nav`, 10 s; either direction, on or off) | The switch snaps back to its old value, so the AR session is never re-run mid-route (a re-run costs ~1–2 s of obstacle frames; `FaceTrackingChange`, Step 34). Caption under the switch "Head tracking without AirPods cannot change while a route is guiding you." / "… while a route is starting." while that lasts; the switch is disabled on a phone that cannot run the front camera beside LiDAR. Never persisted. Trip log `face_tracking {action: refused_route / refused_route_start, requested}`; an accepted change logs `face_tracking {enabled, supported}` | — |

**Not built** (original spec): spoken battery warnings and HOT / CRITICAL / battery pills, the
Describe earcon, a "RECENTRED" toast, a crossing banner and "Tap Next when across", turn speech of the
form "In 15 metres, turn left onto Goodwin" (the waypoint lines are recorded sentences), `.directionUp ×2`
/ `×3` and `.stop`-then-`.notification` wrist patterns, `.success ×2` on arrival.

### 5.5 Sound policy and VoiceOver

Sound policy: the only sounds the app makes are speech and the beacon. No earcons, no obstacle sounds
(the cane is the obstacle channel, the ears stay on traffic), no "find my cane" chirp (not built). The
beacon plays only into headphones. Speech follows the audio route: AirPods when connected, otherwise the
phone speaker on the cane (the only way the phone speaker is used). The original spec's bone-conduction /
open-ear rule was superseded by AirPods Pro (docs/ideas.md §7); the app cannot choose the AirPods noise
mode, so keep traffic audible with Transparency (a recommendation, not enforced). The optional
"Listen for sirens and horns" feature is off by default and fails safe for its entire microphone
lifetime: `SoundRecognitionGuard` stops it on an output move, HFP/missing input, analyzer/engine
failure, interruption or permission loss, restores `.playback`, turns the Hazards switch off and says
why through the existing speech/error path. The shared `SpeechQueue` microphone lease rejects
push-to-talk while sound recognition owns the input (and sound recognition while push-to-talk owns
it), so neither feature can replace the other's route observer. Navigation and LiDAR guidance
continue; reconnecting or re-granting permission never silently re-arms it.

Silence is part of the speech channel too (Step 37): the 0.35 s pause between lines of different bands
(§5.1) is deliberate, so "Head height." and the direction it cut do not run together. It is not a stall;
do not remove it to make speech "snappier" without re-running `make audit` on a walk
(`cross_band_pause_under_0_3s`).

**VoiceOver rule.** The `SpeechQueue` is the app's voice. The app posts exactly one
`AccessibilityNotification.Announcement` — the destination suggestion count ("6 results", §6.3), which
is screen state nothing speaks — so a VoiceOver user is never pushed a *cue* twice. Live values
carry `.updatesFrequently` so touching them reads the current state.

---

## 6. Screens

The phone app is **four icon-only pages** (`ContentView`: `NavigationStack` > selected page
`ScrollView` + `CKTabBar`). Tabs are Guide · Sense · Settings · Profile (`RootTab`; Profile since
Step 44). The navigation title is **inline and centred, one per tab** (Steps 41–42:
`.navigationBarTitleDisplayMode(.inline)` plus a bold `.title2` principal `Text`, hidden from
VoiceOver because the bar already reads it): Guide = "OpenCane", Sense = **"Details"**, Settings =
"Settings", Profile = "Profile". Card order *inside the selected page* is the VoiceOver order; the
tab bar is last on every page.

```
OpenCane · Details · Settings · Profile                                       ← inline, centred navigation title, one per tab
Guide page                                Sense page                         Settings page              Profile page
┌ Guide ──────────────────────────────┐   ┌ ✓ Depth OK ─────────────────┐   ┌ Cues ───────────────┐   ┌ EMERGENCY MEDICAL ID ─┐
┌ This trip  |  Arrived ──────────────┐   ┌ Scene engine (MUSE → ON-DEV)┐   ┌ Haptics ────────────┐   ┌ MOBILITY & FITNESS ───┐
  (§6.1 / §6.3 / §6.4; trip only while    ┌ Obstacles ──────── (TRUSTED)┐   ┌ Watch ──────────────┐     (§6.8)
   navigating or after arrival)           ┌ Hazards ────────────────────┐   ┌ Mount ──────────────┐
                                            (§6.2 / §6.5)                     ┌ Family alerts ──────┐
                                                                              ┌ This phone ─────────┐
                                                                              (§6.5)
[ walk ]  [ 3×3 grid ]  [ gear ]  [ person ]   ← CKTabBar, icon-only; VoiceOver "Guide" / "Sense" / "Settings" / "Profile"
```

Card titles are `.isHeader`, so the headings rotor jumps the cards of the *current* page (Guide →
This trip / Arrived on Guide; Scene engine → Obstacles → Hazards on Sense; Cues → Haptics → Watch →
Mount → **Family alerts** → This phone on Settings — `ContentView.SettingsPage`, Cues first since
Step 36 because it is the setting a walker changes most; Emergency Medical ID → Mobility & Fitness on
Profile). Legend for the wireframes: `[ ]` button · `( )` pill · `┌┐` card.

The tab bar is the one icon-only control: the word is the VoiceOver label and the XCUITest key
(§9), never the only cue for a hazard. Hit target ≥ 60 pt. Tab symbols: `figure.walk`,
`square.grid.3x3.fill`, `gearshape.fill`, `person.crop.circle`; each tab also carries a one-sentence
VoiceOver hint (`RootTab.hint`).

**Not built** (original spec): a fourth *Route* tab (the fourth tab that shipped is Profile, §6.8 —
the bar is full, do not add a fifth), a separate Depth screen with Mirror / Export buttons, the route
picker screen, a Settings provider picker and a "Show debug footer" toggle, the obstacle banner on
Guide, the arrival sheet.

### 6.1 Guide

```
While a route runs                                  Idle (before a route / after Stop / after arrival)
┌ Guide ─────────────────────────────────┐          ┌ Guide ─────────────────────────────────┐
│ Goodwin Avenue. Intersection. Turn     │          │ No route                               │
│ right to face north and stay on this   │          │ (⌖ ±5 M)                               │
│ side. No crossing needed. Listen for … │          │ ┌ ◉ ─────────┐ ┌ 🎙 ────────┐          │ ← two-up TILES,
│ 120 m                (↱ VEER RIGHT 40°)│          │ │ Where am I │ │ Talk to    │          │   same height
│ (⌖ ±6 M) (⚠ GPS WEAK)                  │          │ │ Camera ·   │ │ OpenCane   │          │
│ ┌ ◉ ─────────┐ ┌ 🎙 ────────┐          │          │ │ what is    │ │ Voice · ask│          │
│ │ Where am I │ │ Talk to    │          │          │ │ ahead      │ │ or command │          │
│ │ Camera ·…  │ │ OpenCane   │          │          │ └────────────┘ └────────────┘          │
│ └────────────┘ └────────────┘          │          │ [ ⟲ Repeat                           ] │ ← only after arrival
│ [ ⟲ Repeat       ] [ ⏭ Next          ] │          │ [ 🚶 Start route to CIF             › ] │ ← primary, subtitle
│ [ ⌖ Recenter                         ] │          │ [   Campus Demo · Townsend Hall to CIF ] │
│ (BEACON 40%) (HEAD TRACKED)            │          │ [ ◎ Navigate to CIF from here          ] │ ← secondary, subtitle
│ [ ▶ Simulate walk                    ] │          │ [   Live GPS · Apple Maps walking route] │
│ [ ■ Stop route                       ] │          │ [ ▶ Simulate walk                      ] │ ← secondary, subtitle
└────────────────────────────────────────┘          │ [   Indoor demo · walks the route for you] │
                                                    │ [ ⌕ grainger             ⓧ] [ Go ]     │ ← 60 pt field
                                                    │ [ ▣ Grainger Engineering Library      ] │ ← suggestions,
                                                    │ [   On campus · 400 m       (CAMPUS)  ] │   campus first
                                                    │ ⚠ Type a destination first             │ ← only after a
                                                    └────────────────────────────────────────┘   failed attempt
```

- Instruction: the *upcoming* waypoint's `say` ("Arrived: <say>" after arrival, "No route" when idle), `instruction` font, wraps without limit — the spotter reads it over the walker's shoulder.
- Distance row: only with a GPS-derived distance (never in the simulator without a fix): hero integer metres + "m", and the bearing pill when there is a heading and a target (hidden on a curved leg and while silent at a crossing).
- **The two-up pair is a pair of tiles** (`CKBigButton(layout: .tile)`, Step 47): icon over a centred word over a caption ("Camera · what is ahead" / "Voice · ask or command"), both in one `HStack` that is `fixedSize` vertically so they are the same shape and height however their words wrap. Before Step 47 they were row buttons and `ViewThatFits` stacked the long one while the short one stayed a row — one pair, two shapes. While listening the Talk tile turns destructive red, reads "Listening…" with the caption "Tap again to send".
- **Route buttons are full-width rows with a subtitle** (Step 46): Start route to CIF (primary, chevron), Navigate to CIF from here and Simulate walk (secondary). A subtitle wraps to a second line rather than forcing the stacked shape (Step 47: the row's text column is flexible width).
- Button rows while navigating: Repeat (primary) + Next (secondary) share a row; Recenter (secondary) has its own row; the beacon / head pills sit between Recenter and Simulate walk / Stop simulation; **Stop route (destructive, last)**, so Stop is the furthest control from Repeat / Next. Stop has no confirmation — use Guided Access on the walk.
- Where am I and Talk to OpenCane are always present (idle and navigating), above the route controls.

| # | Element | VoiceOver label | Value / hint | Traits |
|---|---|---|---|---|
| 1 | Card title | "Guide" | — | `.isHeader` |
| 2 | Instruction | the instruction text itself | — | `.isHeader`, `.updatesFrequently` |
| 3 | Distance row (combined) | "N meters to the next point" | — | — |
| 4 | GPS pill | "GPS: ±N m" / "GPS: Searching" / "GPS: Denied" / "GPS: Off" | — | `.updatesFrequently` |
| 5 | GPS weak pill | "GPS weak" | — | — |
| 6 | Where am I | "Where am I" ("Describing…" while busy) | value "in progress" while busy; hint "Takes a photo and reads out hazards and landmarks ahead" | button; disabled while busy |
| 6b | Talk to OpenCane | "Talk to OpenCane" ("Listening…" / "Thinking…" while busy) | value "listening" while listening; hint "Tap to speak a command, ask a question, or set a post" | button |
| 7 | Scene text / describer error | "Scene: <description>" / the error text | — | — |
| 8 | Repeat | "Repeat" | hint "Says the current instruction again" ("Says the arrival line again" after arrival) | button |
| 9 | Next | "Next" | hint "Skips to the next instruction" | button |
| 10 | Recenter | "Recenter" | hint "Sets straight ahead as the beacon's forward direction" | button |
| 11 | Beacon pill | "Beacon: Beacon N%" / "Beacon: Beacon paused" / "Beacon: Beacon off" / "Beacon: Beacon idle" | — | `.updatesFrequently` |
| 12 | Headphone pill | "<output name>, head tracking on" / "<output name>, no head tracking" / "No headphones connected; beacon paused" | — | — |
| 12b | Simulate walk / Stop simulation (navigating, between the pills and Stop route) | "Simulate walk" / "Stop simulation" (`AppModel.isSimulatingWalk`) | hint "Simulates walking along the active route indoors" / "Pauses the walk simulation" | button; **no test uses either label** |
| 13 | Stop route | "Stop route" | hint "Ends guidance" | button |
| — | Cancel route start (idle, only while a route start waits for the depth interlock) | "Cancel route start" | hint "Stops waiting for obstacle detection and does not start guidance"; the status line under the route buttons says why the route has not started | button (destructive); **no test uses it** (§9) |
| — | Start route to CIF (idle) | "Start route to CIF" | hint "Starts the recorded ISR Townsend Hall to CIF route" | button |
| — | Destination field (idle) | "Destination" (placeholder "Or type a destination") | hint "Type a place name. Matching places appear below as you type."; return key "Go" submits | text field |
| — | Clear (x), only with text in the box | "Clear destination" | hint "Empties the destination box" | button |
| — | Suggestion row (0–6, campus places first) | "&lt;place>, campus place, 400 meters away, &lt;address>" | hint "Starts walking guidance to this place" | button |
| — | Go (idle) | "Go" | hint "Builds a walking route with Apple Maps to what you typed"; disabled while building | button |
| — | Done (bar above the keyboard) | "Done" | hint "Hides the keyboard" | button |
| — | Error line | the error text ("Type a destination first", "No GPS fix yet", route / location errors); a warning glyph sits beside it, hidden from VoiceOver | — | static text |

Focus order is the visual order. Nothing uses `accessibilitySortPriority`.

### 6.2 Depth: status card + Obstacles grid

```
┌──────────────────────────────────────────┐
│ ✓ Depth OK                               │   status card: icon + depth status, `instruction` font
└──────────────────────────────────────────┘
┌ Obstacles ─────────────────── (✓ TRUSTED)┐
│ Head                                     │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│ │   Left   │ │  Center  │ │  Right   │   │  position, .caption semibold, ink 70 %
│ │  3.1 m   │ │  1.0 m   │ │  clear   │   │  metres, 28 pt rounded bold, ink on fill
│ │  CLEAR   │ │   NEAR   │ │  CLEAR   │   │  level word, .caption2 bold
│ └──────────┘ └──────────┘ └──────────┘   │
│ Torso                                    │
│ │  1.6 m FAR │ 0.5 m STOP │ 2.2 m CLEAR │ │
└──────────────────────────────────────────┘
```

Tiles: 3 × 2, gap 8, radius 14, equal widths, `md` vertical padding. Each tile = fill (`laneX`) + position
label + metres + level word; no glyph. ≥ 4.5 m or no return shows "clear"; before the first depth frame
"—" on `laneNoData` with NO DATA. Sweeping changes only the pill (tiles keep drawing).

| Element | Label | Value | Traits |
|---|---|---|---|
| Status card (combined) | "Status: <depth status>" ("Status: Depth OK") | — | `.updatesFrequently` |
| Card title | "Obstacles" | — | `.isHeader` |
| Trust pill | "Depth trusted" / "Sweeping, warnings paused" | — | `.updatesFrequently` |
| Head row (one element; tiles hidden) | "Head row" | "left one meter, center clear, right 3 meters" or "no depth data" | `.updatesFrequently` |
| Torso row (one element) | "Torso row" | same format | `.updatesFrequently` |

Rows are one VoiceOver element each on purpose: reading three cells is slower than one sentence.

**Scene engine card** (Step 47, `SceneEngineCard`, between the status card and Obstacles). The owner
asked the Details tab to say *when Muse is used* rather than only name the chain. Every string is
`SceneEngineSummary` (CaneKitLogic, tested); the 8 s and 2.5 s in it are the scanner's own constants.

```
┌ Scene engine ────────────────────────────┐
│ (🧠 MUSE → ON-DEVICE)                     │   pill: "ON-DEVICE ONLY" without a cloud key
│ WHERE AM I  Muse answered in 1.9 s        │   or "On-device answered — Muse: The request timed out. (after 18 s)"
│             2 min ago · from the watch    │   secondary; "Not asked yet." before the first run
│ GATE        Muse's sentence passed the gate.  │  only when the cloud answered ("… was edited: dropped count." /
│                                           │   "… was refused: invented distance. On-device spoke instead.")
│ WATCH       Hazard watch off — when on, asks Muse every 8 s while a route guides, on-device after 2.5 s │
│ LIGHT       Light: dark (12 lux) · flashlight on (by OpenCane) │  Step 49; or "Light: lit (640 lux)" /
│                                           │   "Light: dark (12 lux) · flashlight off — cameras may miss things" / "Light: unknown"
│ CUES        Detailed · Outdoors · names off │
└──────────────────────────────────────────┘
```

| Element | Label (VoiceOver) | Traits |
|---|---|---|
| Card title | "Scene engine" | `.isHeader` |
| Chain pill | "Where am I asks Muse first, then the on-device model when Muse fails." / "Where am I uses the on-device model only. No cloud key is set." | — |
| Where am I row (one element) | "Muse answered the last Where am I in 1.9 seconds." / "On-device answered the last Where am I, because Muse failed: The request timed out. It gave up after 18 seconds." / "Where am I has not been asked yet." / "The last Where am I failed: <error>" | — |
| When row | "2 minutes ago, from the watch." | `.updatesFrequently` (a 10 s `TimelineView` redraws the age) |
| Gate row | the sentence as drawn | — |
| Watch row | "Hazard watch is off. When on, it asks Muse every 8 seconds while a route guides, and the on-device model answers if Muse takes more than 2.5 seconds." / "Hazard watch: Muse answered the last check in 1.2 seconds. 30 seconds ago." | — |
| Light row (Step 49) | "Light: lit, 640 lux." / "Light: dark, 12 lux. Flashlight on, switched on by OpenCane." / "Light: dark, 12 lux. Flashlight off, so the cameras may miss things. Obstacle detection still works." / "Light level unknown. No camera light estimate yet." | inside the 10 s `TimelineView` (the lux number refreshes; a state change redraws at once) |
| Cues row | "Cues: Detailed, Outdoors, obstacle names off." | — |

The Guide card also shows a **DARK** pill (`.warning`, `moon.fill`, VoiceOver "Low light; obstacle
detection still works") beside the GPS pill while `LowLightPolicy` says dark — for the sighted
spotter; the walker was told once by voice (§5.1). Warning, not danger: LiDAR, GPS and haptics are
unaffected.

Words, never colour: the card has no tint that carries state. Triggers are `DescribeTrigger.spoken`
("the Guide button", "the watch", "the Action button or Siri", "Camera Control", "a waypoint", "a question").

### 6.3 Route choice (inside the Guide card)

The route picker is three controls in the idle Guide card:

- **Start route to CIF** — the bundled `route_isr_cif.json` (9 waypoints, 3 crossings, ≈ 989 m, see
  `docs/route_isr_cif.md`). No GPS wait, no network.
- **Navigate to CIF from here** — the same destination for a walker who is not at ISR: `MKDirections`
  walking from the live fix to the route file's *last waypoint as a bare coordinate*
  (40.11242, −88.22788, the CIF east entrance). No search, so MapKit can never pick a different "CIF".
- A destination **search field + suggestion list + Go** (`UI/DestinationField.swift`) — the campus
  gazetteer (`CampusPlaces`: CIF, ISR, Grainger, Illini Union, Siebel, Main Library, ARC → entrance
  coordinates) first; only when nothing matches, `MKLocalSearch` (`regionPriority = .required`, points
  of interest + addresses) in a ±3 km region around the walker, and the **nearest** result in range wins
  — names containing every typed word preferred — never MapKit's first answer. Waypoints at each step
  end, 15 m fences, 20 m arrival.

  **The suggestion list** (Step 14). Typing offers up to six rows from two sources, merged by
  `CaneKitLogic.DestinationSuggestions`: campus places (partial-name matching, nearest first when there
  is a fix, at most three) always come **first** and carry a `CAMPUS` badge and a "On campus · 400 m"
  line, because MKLocalSearch answers "Grainger" with an industrial supply store and a blind walker
  cannot see that the wrong row is on top. MapKit rows come from one `MKLocalSearchCompleter`,
  debounced 0.25 s, region-biased to the fix (or the campus centre when GPS is not running), and a row
  that is only another spelling of a campus place is dropped. A **map row never shows a distance**: a
  completer result carries no coordinate, so there is nothing to measure. Tapping a row starts guidance
  at once — no second tap on Go — through `AppModel.navigate(to:)` / `navigate(to place:)`, the same
  entry points Siri uses, so "Walking to \<place>, N meters." is still spoken first and Stop still
  abandons a search in flight. The row count is posted as a VoiceOver announcement whenever it changes
  (§5.5); the field is 60 pt with a magnifying glass, a clear (x) button and the secondary-button fill,
  the keyboard has a **Done** bar, dragging the page or tapping outside dismisses it, and focusing the
  field scrolls the Guide card to the top so nothing is hidden behind the keyboard. The error line
  ("Type a destination first") appears only after a failed attempt and is cleared by the next keystroke.

The last two share `AppModel.buildRoute`. Every MapKit route says **"Walking to \<place>, N meters."**
(`WalkingIntro`: nearest 10 m, tenths of a kilometre above 1 km) before guidance starts, so a blind walker
hears what was chosen and can Stop if it is wrong; **Stop route** also abandons a search still in flight.
An empty field shows "Type a destination first"; with Location off for OpenCane it is refused at once with
"Location is off for OpenCane" and the spoken fix (no wait for a fix); with no GPS fix after ~15 s: "No GPS
fix yet. Try again outside."; nothing within 3 km: "Could not find "…" within walking distance".

Every control here is also a Siri phrase, because the walker this card is for cannot see it
(`AppIntents.swift`): "Start route to CIF / Take me to Grainger / Take me
somewhere / Repeat the last instruction / Next waypoint / Stop the route **in OpenCane**", plus "Where am I
in OpenCane" and "Talk to OpenCane". Seven of the ten App Shortcuts an app may register (`TakeMeToIntent` carries both the "Take me to" and "Take me somewhere" phrases; the other three slots are Status, Ask and Cane haptics, `HandsFreeIntents.swift`), all `.foreground(.immediate)` — ARKit
obstacle warnings only run with the app frontmost, so guidance must never start in the background.
("Navigate to CIF from here" stays a Guide card button and a Shortcuts-app action, but its Siri
phrase moved to "Take me to CIF in OpenCane" — same route-file waypoint via the gazetteer — when
its shortcut slot went to "Talk to OpenCane" for the Action button.)
App Shortcut phrases can only interpolate an `AppEnum`/`AppEntity`, so the phrase form carries the seven
gazetteer places (`CampusDestination`); any other place goes through "Take me somewhere in OpenCane" and
Siri asks "Where do you want to go?" for the free text.

**Not built**: the route cards (Recorded route RECOMMENDED / Any destination), the search sheet, "Use this
route".

### 6.4 Trip / Arrival card

```
┌ This trip  (while walking)  |  Arrived  (after the last waypoint) ┐
│ 988 m          14             1300                                │  28 pt rounded bold
│ walked         minutes        steps                               │  .subheadline, textSecondary
│ Steps from Apple Health (watch + phone)                           │  or "…phone pedometer" / "Steps unavailable"
└───────────────────────────────────────────────────────────────────┘
```

Inline card (not a sheet), inserted under the Guide while navigating and kept after arrival. Distance
switches to "N.N km" at 950 m; steps show "—" until a count exists. VoiceOver: one combined element whose
label is the spoken summary, e.g. "Arrived. 1.0 kilometers, 14 minutes, 1300 steps." ("So far. …" while
walking). After arrival the Guide keeps a Repeat button (the arrival line + summary is the longest line of
the walk). **Not built**: the checkmark hero, "Describe where I am" and "Done" buttons.

### 6.5 Settings and debug cards

Three pages hold the controls. **Settings** (`ContentView.SettingsPage`) is, top to bottom: **Cues**
(two segmented pickers), **Haptics**, **Watch**, **Mount**, **Family alerts** (Step 39), **This phone**.
**Sense** carries the **Hazards** card (`HazardsCard`) under the status card, the Scene engine card and
the Obstacles grid. **Profile** holds the Medical ID editor and the mobility refresh (§6.8). Every switch is a system
`Toggle` (visible label = VoiceOver label, plus a hint; VoiceOver announces "switch button, on / off"
for free). Persistence is per control, in the Default column: the persisted ones are `UserDefaults`
(`Settings` in `AppModel`); the ones marked **not persisted** are off at every launch on purpose (each
can pause obstacle detection, open the microphone or burn the battery, and a launch must never start
there — `AppModel` doc comments). Separately, after a launch that never reported itself healthy,
`LaunchRecovery` resets its `optionalFeatureKeys` to their defaults and says so.

| Card (page) | Control (visible label = VoiceOver label) | Default | Hint (exact, from the code) |
|---|---|---|---|
| Cues (Settings) | "Cue detail" segmented **Quiet / Standard / Detailed** (`CueLevel.title`) | **Detailed**, persisted `cueLevel` (= today's behaviour until a trip log from the mounted cane tunes the calmer levels; owner decision 2026-09-12) | "How much OpenCane says and taps on its own. Quiet names nothing, reads only safety signs and taps only for head height. Standard taps once at 1.5 meters and a strong triple at 0.6, with no side taps. Detailed taps continuously ahead and for the sides. Head height warnings are the same at every level." |
| Cues (Settings) | "Place" segmented **Outdoors / Indoors** (`CuePlace.title`) | **Outdoors**, persisted `cuePlace` | "Indoors warns about head height from 1.2 meters instead of 1.5, names nothing, reads only safety signs and taps only for head height." |
| Haptics (Settings) | "Silence haptics" | off, persisted | "The phone stops vibrating; obstacle cues go to the watch and are spoken instead" |
| Haptics (Settings) | "Speak obstacle names" | **off** since Step 36, persisted (a walker who had turned it on keeps `true`) | "Says door, seat, window or table when one is straight ahead. Off by default. Which names are said depends on Cue detail and Place." |
| Watch (Settings) | "Mirror obstacle cues to the watch" | off, persisted | "Also taps the wrist for every obstacle; automatic when the phone's haptic engine fails" |
| Mount (Settings) | "Phone held upright (portrait)" | on, persisted | "Turn off if the phone is clamped sideways" |
| Mount (Settings) | "Mirror left / right" | off, persisted | "Turn on if left and right warnings feel swapped" |
| Mount (Settings) | "60 fps camera (warmer)" | off, persisted | "Smoother live view; uses more battery and heat. Obstacle cues are the same either way." |
| Mount (Settings) | "Audio beacon while navigating" | on, persisted | "A soft click from the direction to walk, through the AirPods" |
| Mount (Settings) | "Flashlight on in the dark (routes)" (Step 49) | **on**, persisted `autoTorchInDark` — the deliberate exception to "new features ship off" (AGENTS.md → deliberate list; a blind walker cannot see the dark, so an opt-in would never be flipped) | "When the camera sees low light while a route guides, OpenCane turns the flashlight on so the cameras can see and drivers can see you, and off again when the light returns or the route ends. Obstacle detection works in the dark either way." Only ever lights the torch while a route guides, through `AppModel.setTorch(_:byApp:)`; never a torch the walker lit; §5.1 for the spoken line |
| Mount (Settings) | "Write trip log" | on, persisted | "Saves a JSONL log of lanes, cues and location to the Files app" |
| Hazards (Sense) | "Detect drop-offs" | off (until validated on the phone), persisted | "LiDAR warns about curbs, holes and drop-offs 1.5 to 3.5 meters ahead" |
| Hazards (Sense) | "Read signs" | on, persisted | "Reads signs like sidewalk closed or detour, on the phone, offline" |
| Hazards (Sense) | "Hazard watch" | off (until validated on the phone), persisted | "While walking a route, checks the path for cones, barriers and scooters every 8 seconds" |
| Hazards (Sense) | "Name people ahead" | on, persisted | "When you ask where am I, says how many people are ahead, which way and how far" |
| Hazards (Sense) | "Listen for sirens and horns" | off, **not persisted**; disabled without the sound classifier | "Uses the microphone to warn about sirens, horns and vehicle sounds. Needs the microphone, so it is off by default." |
| Hazards (Sense) | "Nod to talk" | off, **not persisted**; disabled without headphone motion | "Nod twice with AirPods on while walking a route to start talking to OpenCane. Off by default." |
| Hazards (Sense) | "Head tracking without AirPods" | off, **not persisted**; disabled when the front camera cannot run beside LiDAR | "Uses the front camera to follow your head direction, so the beacon works without AirPods. Cannot change while a route is guiding you." Refused while a route guides or starts (§5.4) |
| Hazards (Sense) | "Live camera view" | off, **not persisted** | "Shows what the camera sees, for a sighted helper" |
| Hazards (Sense) | "Both cameras (pauses obstacle detection)" | off, **not persisted**; disabled without multi-cam and while a route start waits for depth | "Shows the front and back cameras at the same time for a sighted helper. While it is on, obstacle warnings, depth and hazard detection stop. It cannot be used while a route is guiding you." Refused while a route guides (§5.4) |
| Hazards (Sense) | "Flashlight" | off, **not persisted** (off at every launch) | "Turns the back-camera flashlight on or off. Works while a route guides and while both cameras are on. Off at every launch." Bound to `AppModel.setTorch`: shows the request at once, settles on the device's report (§5.4) |
| Family alerts (Settings) | "Send cane events to family" | **off**, persisted `familyAlertsEnabled` (in `LaunchRecovery.optionalFeatureKeys`); **disabled** without the webhook key, with the red caption "No webhook key. Add OPENCANE_GROKBOT_WEBHOOK_URL and _KEY to Secrets.plist." | "Sends falls, close obstacles, low battery and a position every few minutes to the OpenCane Grok Bot, which decides whether to text your family" |
| Family alerts (Settings) | "Detect the cane falling" | **on**, persisted `fallDetectionEnabled` (Step 43; the thresholds are a guess shipped on — `docs/todo.md`); **disabled** without a motion sensor, grey caption "This device has no motion sensor, so falls cannot be detected." | "Reports to your family when the cane goes over and stays down. Thresholds are not tuned yet, so turn this off if it cries wolf." |
| Family alerts (Settings) | "Add AI context" | **on**, persisted `familyAlertsAIContext`; **disabled** without a model key (grey caption "No model key, so alerts carry facts only."; with one, "Context written by <model>.") | "A small model writes one sentence of context for your family from what the phone knew. The facts are sent either way." |
| Family alerts (Settings) | "Send test event" (`CKBigButton`, secondary) | works while the switch is **off** (checking the wiring is the point); one press per 10 s (`ActionRateLimit`, refusal spoken "Just a moment. Try again in N seconds.", §5.1) | "Posts one sample fall event to the Grok Bot routine and reports what it answered". The line under it is the last answer, read as "Last family alert: <status>" |
| Family alerts (Settings) | **Family emails** (`FamilyContactsEditor`): header, one row per address with a trash button, an add field + "+", an error line, "Save family emails" (`CKBigButton`) | list persisted `familyContactEmails` (`FamilyContacts.normalize`: trim / lowercase / dedupe / cap 10); Save is **primary** while an edit is unregistered (caption "Not registered yet — press Save."), otherwise secondary; disabled without the webhook key; one Save per 10 s | Header reads "Family emails, none yet" / "Family emails, N on the list"; field "Family email", hint "Type an address, then Add. Press Save to register the list."; "Add", hint "Adds the typed address to the list" (disabled until something is typed; no fake address as placeholder); each row's button is "Remove <address>" so four rows never read as four identical "Remove"s; Save's hint "Registers the list with the OpenCane Grok Bot, which emails your family when the cane reports a fall or SOS" |

⚠ **Wording contract for the Family alerts card** (`SettingsPage.familyAlertsCard` and
`FamilyContactsEditor` headers, not decoration): an HTTP 200 from the webhook means the Grok Bot
routine **started a run**, never that anyone was texted or that mail arrived — the bot decides that
afterwards from the event's `severity` and `type`. No string on this card, in `FamilyAlerts.lastStatus`
or in a spoken line may say "family notified" / "family texted"; say what the *bot* did ("Grok Bot
accepted…"). The app sends no email of its own.

**The Cues card** (Step 36, `SettingsPage.cueSettings`). Each picker has a visible `secondary`-font
label above it ("Cue detail", "Place") that is hidden from VoiceOver, and the picker itself is a
VoiceOver container labelled with that word — a segmented `Picker` neither shows nor speaks its own
title on iOS, and without the container a swipe heard "Quiet, button" with no context. Each change is
spoken once by the model at `.nav` ("Quiet cues.", "Indoor mode."; §5.4). Under the pickers a caption
(`cueLevelCaption`) says what the selection does, built from these sentences in order (Step 41 replaced
the closing "Haptics are the same at every level for now." with the true torso-haptic sentence per level):
- the level: "Quiet: no obstacle names; safety signs only. No cane taps for torso obstacles, head height
  only." / "Standard: door names on a route; every sign. One tap at 1.5 meters, a strong triple at 0.6,
  no side taps." / "Detailed: every obstacle name except walls; every sign. Continuous centre taps and
  side taps.";
- with Indoors: "Indoors: head height from 1.2 meters, no names, safety signs only, no torso taps.";
- when "Speak obstacle names" is off and the level is not Quiet and the place is Outdoors: "Names are
  off: turn on Speak obstacle names below to hear them."

What the rules are (`CueRules`, pinned by `CueProfileTests`): names — Detailed + Outdoors every speakable
class but wall, Standard + Outdoors doors only while a route guides, Quiet or Indoors nothing; signs —
Quiet or Indoors only `CueRules.safetySignPhrases`, otherwise every phrase; head distance — 1.5 m
outdoors, 1.2 m indoors (a research hypothesis, `docs/cue_design_v2.md` §3.5). "Head height." and the
ground-hazard warnings are identical at every level. Switching to Indoors while a head cue is active at
1.35–1.5 m clears it (opt-in calming, noted in CHANGELOG Step 36).

Debug controls (sighted teammate / developer):
- **Haptics card**: pills ENGINE OK / ENGINE DOWN (spoken "Haptic engine running" / "… not running") and the active cue (CLEAR / CENTER / LEFT / RIGHT / HEAD, spoken "Active cue: …"); the engine's error line in red; "Silence haptics"; the caption "Test patterns" and four test buttons "Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic" (60 pt, icon + caption, bypass the decider; centre plays the loop for 2 s, hint "Plays the approach loop for two seconds", the others "Plays the pattern once"); "Speak obstacle names"; speech pills SPEAKING / QUIET and SYSTEM / ELEVENLABS (the voice pill follows what actually spoke, so a wrong key reads SYSTEM; spoken "Voice: …" or "System voice; add an ElevenLabs key for the natural voice"); a quiet grey voice-problem line when a natural-voice fetch or playback failed ("Voice problem: …"); a "Speech test" big button (hint "Speaks a scene line, then an obstacle line that interrupts it"; the scene line is cut and, per §5.1, resumes after the obstacle line — from the top here, because it is cut in its first clause); the audio-session error line in red.
- **Hazards card**: two neutral pills, the hazard watch backend (the provider name, e.g. "ON-DEVICE"; spoken "Hazard watch uses …") and "N MAPPED" (spoken "N hazards on the map"); one detection row per source that has spoken, LIDAR / SIGN / WATCH / SOUND in the `pill` font and `textSecondary` followed by the last line in `body` (one VoiceOver element per row); an error line in red; "Share hazard map" (60 pt, secondary style, a `ShareLink` of this session's GeoJSON, shown once the file exists, hint "Shares a GeoJSON map of every hazard found on this walk"); the sound watch's status rows; under "Live camera view" ARKit's own frames on the GPU (`LiveCameraView`, 3:4, at the camera's frame rate — 30, or 60 with the Mount switch; hidden from VoiceOver; captions "Live view paused: phone is hot" / "Camera off"); the front-camera readout while head tracking without AirPods is on ("Front camera is detecting …. Head direction only; no front camera picture."); the two-camera picture and its red caption (§5.4); the grey captions that explain a refused mode, read by VoiceOver. "Both cameras self test" / "Front camera self test" appear only under the `--sensor-selftest` launch flag.
- **Watch card**: link pill REACHABLE / ASLEEP / APP NOT INSTALLED / NOT PAIRED / UNSUPPORTED and the last watch command; the link error in red; "Mirror obstacle cues to the watch"; four buttons "Send left / right / cross / arrive cue to the watch" (disabled when unreachable).
- **Mount card**: first row the live aim, e.g. "Camera tilt 5° down, good · 30 fps" (`MountTilt.status`; "Camera tilt: hold the cane still for a reading" before a trusted frame), then the five switches above.
- **Family alerts card**: the four controls and the emails editor in the table above; no pills. Its captions are the only red text on Settings ("No webhook key…" and an Add refusal), and both are words, never a red border alone (§7).
- **This phone**: "LiDAR depth", "Mesh classification (door / wall / seat)", "Logic package linked", each read as "<name>: available / not available".
- **Debug footer**: removed (`DebugFooter.swift` is gone). Depth fps is only on the Mount card's aim row; thermal and battery are in the trip log's `lanes` records; the log file is found in the Files app.

Where the original Settings rows went: the scene-description provider is `VLM_PROVIDER` in
`Secrets.plist` (no picker); the trip log (`canekit-*.jsonl`) and the hazard map
(`hazards/hazards-<session>.geojson` + photos) are in the Files app under On My iPhone → OpenCane (no
Export button; the hazard map also has the Share button above).

### 6.6 Watch face (42–46 mm)

One screen, no paging and no `ScrollView` (either would take the Digital Crown and "Next" would never
fire). The watch is always dark: black ground (OLED, wrist-down power).

```
┌──────────────────────┐
│ ▯)            120 m  │  inline navigation title = distance ("OpenCane" when unknown);
│                      │  leading toolbar glyph = phone link (green / red iphone.slash)
│ Goodwin Avenue.      │  instruction, .title3 semibold, ≤ 2 lines, scales to 70 %
│ Intersection. Turn…  │
│ [ ⟲ Repeat         ] │  44 pt, ivory fill, ink text (primary)
│ [ ⏭ Next           ] │  44 pt, #26231F fill, ivory text
│ [   ◉    ][   ⌖    ] │  Describe | Recenter: half width, 44 pt,
│ [Describe][Recenter] │  symbol over a .caption2 word (one button each)
│ Phone not reachable  │  error line, .footnote, danger (only when set)
└──────────────────────┘
```

Tokens (`WatchTheme.swift`): `WKColor` background black, surface `#26231F`, text / accent `#F4F1EA`,
ink `#17140F`, trusted `#4ADE80`, danger `#F87171` (warning `#FBBF24` and secondary `#B5AFA3` are defined
but unused); `WKFont` instruction `.title3` semibold, button `.headline` rounded semibold, footnote, plus `distance` (`.title` rounded heavy, tabular digits) and `pill` (`.caption` rounded bold), both defined but unused — the distance is drawn by the inline navigation title in the system font and no pill is drawn on the watch face;
`WKSpacing` 4 / 8 / 12, touch target 44 pt; `WKBigButton` radius 14, roles primary / secondary /
destructive, `compact` = half width.

Crown: `.digitalCrownRotation` on the whole screen (`sensitivity: .low`, system detent haptics on);
3 detents in either direction within 1 s of the first = Next, then a 0.8 s debounce
(`CaneKitLogic.CrownAccumulator`). There is no API for the side button or a crown press.

Wrist haptics (`WatchModel`):

| Incoming | `WKHapticType` |
|---|---|
| turn left / "Veer left." | `.directionUp` |
| turn right / "Veer right." | `.directionDown` |
| crossing | `.notification` |
| arrived | `.success` |
| mirrored obstacle left / right / centre / head | `.start` / `.stop` / `.click` / `.failure` |
| button press sent | `.click` |
| send failed / phone app too old | `.retry` (never `.failure`: that is head height) |

| Element | Label | Value / hint |
|---|---|---|
| Instruction | the instruction text (`.isHeader`) | "N meters to go" when known |
| Phone glyph | "Phone connected" / "Phone not connected" | — |
| Repeat | "Repeat" | "Says the current instruction again" |
| Next | "Next" | "Skips to the next instruction" |
| Describe | "Describe" | "Asks the phone to describe the scene ahead" |
| Recenter | "Recenter" | "Sets straight ahead as the beacon's forward direction" |

The watch never shows the depth grid: at wrist size the tiles and numbers fall below the arm's-length
floor. A long instruction is cut after two lines on the watch; Repeat speaks it in full. The watch keeps
itself frontmost with a walking `HKWorkoutSession` (fallback: extended runtime session) so haptics play
wrist-down. **Not built**: the two-page `TabView`, the TRUSTED pill and the "crown: next" hint line.

### 6.7 Live Activity / Dynamic Island

Redesigned in Step 47 from the first automated pictures of the island (`make island` →
`ios/build/shots/NN-island-*.png`, `CaneKitIslandTour`). Before them, every change to the widget
had been verified by a person looking at a phone, and the owner reported it "weird" three times.

```
Lock screen / banner
┌────────────────────────────────────────────────────────────────┐
│ ↱        Goodwin Avenue. Intersection. Turn right…        120 m │  glyph 30 pt bold over its word ("Turn right");
│ Turn     ● Obstacle 1.2 m   ISR Townsend Hall to CIF    to next │  instruction .headline ≤ 2 lines; glance pill + route
│ right                                                            │  name; distance 28 pt rounded heavy, tabular, "to next"
└────────────────────────────────────────────────────────────────┘
Dynamic Island
  expanded : leading = glyph + word · trailing = distance + "to next · ±5m GPS" · bottom = instruction (full
             width, 2 lines) then one row: [glance pill] + the route progress bar filling the rest; the GPS fact is the trailing caption ("to next · ±5m GPS")
  compact  : leading = glyph + distance · trailing = glance glyph only when clear, glyph + metres /
             HEAD / CURB when not
  minimal  : the glance glyph when not clear, else the manoeuvre glyph — never the distance
```

- **OpenCane owns the island, like Apple Maps / Google Maps — which needs Always location.** On
  When-In-Use authorization a route that runs with the screen locked needs a
  `CLBackgroundActivitySession`, and iOS then draws its blue location pill *in* the island and
  demotes the Live Activity to the minimal bubble (owner's phone, 2026-09-12 21:48: a blue arrow in
  the pill, our head-height glance in a detached circle — "why is the blue location thing the
  main thing"). The first route start now asks for Always
  (`LocationService.requestAlwaysAuthorization`, `NSLocationAlwaysAndWhenInUseUsageDescription`);
  with Always no session is armed (`reconcileBackgroundSession`), no pill is drawn, and the compact
  island is ours. A walker who declines keeps the session (GPS survives the lock) and the pill.
  Trip log: `location_auth {status, background_session}` at route start and on every change.
- **Glyphs never look like the system's location arrow.** Straight = `figure.walk`, turns =
  `arrow.turn.up.left` / `.right`, crossing = `figure.walk.diamond.fill` (yellow), arrived =
  `flag.checkered` (green). `arrow.up` is retired: two arrows side by side read as one broken icon.
- **Progress bar** (the Google Maps reference): a thin ivory bar with the walker's dot, waypoints
  passed over total (`ContentState.progress`, 1 on arrival), under the expanded island's pills and
  the lock-screen row. The metres countdown is the fine grain; the bar is the whole walk.
- **The glance says nothing when there is nothing to say.** Clear = one small green check in the
  compact trailing bubble, no word; the word "Path clear" appears only in the pill of the expanded
  and lock-screen layouts. Obstacle / head / drop-off get a glyph, a tint (orange / red / purple)
  and a word or a distance — never colour alone.
- **The instruction owns the full width.** Expanded bottom region, two lines (a third pushed the pills off the region), `fixedSize`
  vertical; the leading column holds only the glyph and its word, the trailing column the
  distance. (Before: the instruction sat in the leading column and truncated to "Leaving
  Townsend…".) The glance pill has first claim on the pill row (`layoutPriority(1)`); the route
  name is on the lock screen only — beside the pill in the island it truncated both ("Head heig…",
  "ISR Tow…ll to CIF").
- **Stale after 5 minutes** (`LiveActivityCoalescer.staleAfter`, set as `staleDate` on every
  request and update): the distance dims and the caption reads "No update" — an app killed
  mid-route leaves an island iOS keeps up for hours, and a frozen "120 m" must not look live.
- Colours are fixed, not `CKColor`: ink ground (`activityBackgroundTint` ≈ `#171410`) with ivory
  text (≈ `#F5F2EB`); glance tints ≈ `#4ADE80` / `#FB923C` / `#F87171` / `#BF8CFA`.
- Update rate: on every GPS fix, coalesced by `LiveActivityCoalescer` (instruction or glyph
  change, distance bands 2 / 5 / 10 m, hazard transitions at once with a 0.2 s flap guard, 0.8 s
  floor otherwise). The island is a summary, not a gauge.
- Ends on arrival with the arrival glyph and a 60 s lock-screen dismissal; Stop ends it immediately (`end(immediate: true)`); the island
  itself drops an ended activity at once (`04-island-after-stop.png` is empty). `start` ends any
  previous activity immediately (Step 20) and launch ends orphans (Step 42). Tapping opens the
  app. No interactive buttons: "Next" from the lock screen is too easy to hit by accident with
  the phone on a cane.
- VoiceOver reads one sentence per presentation ("OpenCane, on route ISR Townsend Hall to CIF: in
  120 meters, turn right. Goodwin Avenue. Path is clear."), never a raw kind — the old
  "turnLeft" label in §10 is gone.
- **Not built**: the "14 min left · 820 steps" line; a lock-screen picture in `make island` (no
  public API locks the simulator from XCUITest).

### 6.8 Profile (Medical ID + Mobility)

The fourth tab (`ProfilePage.swift`, Step 44; avatar Step 46; real emergency number and the `.scene`
announce band Step 47). Navigation title "Profile". It is for a **first responder or a sighted helper**
reading the phone on the cane, and for the walker hearing it: an Apple Health-style Medical ID plus
today's mobility numbers. Two cards, both titled in **capitals** — the only upper-case card titles in
the app, on purpose: they must read as an emergency document, not a settings group. Data is
`MedicalProfileStore` (persisted on the phone and mirrored to Supabase when the keys are set, Step 45).

```
┌ EMERGENCY MEDICAL ID ──────────────────────┐
│ (◯ 56 pt photo)  Aritro …          [ Edit ] │  photo: bundled `AritroProfile`, accent ring; else person.crop.circle.fill
│                  ✚ EMERGENCY ID             │  `pill` font, danger red
│ ┌ ⛨ WHITE CANE USER / BLIND ─────────────┐  │  banner: raised surface, danger glyph + `pill` word,
│ │   <emergencyNotes>                      │  │  then the notes in `secondary`
│ └─────────────────────────────────────────┘  │
│ 📅 Date of Birth ………………………… <value>          │  seven info rows: Date of Birth, Blood Type,
│ 🩸 Blood Type ……………………………… <value>          │  Height & Weight, Allergies, Medications,
│ …                                           │  Residence, Cane Spec (label secondary, value medium)
│ EMERGENCY CONTACT                           │
│ ┌ <name>                        [📞 Call] ┐  │  `Link(tel:)`, accent capsule, ink text
│ │ <relation> · <phone>                    │  │
│ └─────────────────────────────────────────┘  │
│ [ 🔊 Announce Medical ID                  ] │  CKBigButton secondary
└─────────────────────────────────────────────┘
┌ MOBILITY & FITNESS ────────────────────────┐
│ Today's Cane Mobility                  (⟳) │  refresh glyph button
│ ┌ Steps Today ┐ ┌ Distance     ┐            │  four metric tiles, `hero(28)` numerals on raised
│ │ 4 812       │ │ 3.2 km       │            │  surface (the same 28 pt bold rule as the depth tiles, §0)
│ ┌ Trips Fin.  ┐ ┌ Average Pace ┐            │
│ │ 3           │ │ 1.2 m/s      │            │
│ ┌ ACTIVE ROUTE ── <route name> · N min ──┐  │  only while a route runs
└─────────────────────────────────────────────┘
```

- **Edit** opens `EditMedicalIDSheet`: a system `Form` in a `NavigationStack` titled "Edit Medical ID"
  (inline), sections Identity / Medical Vitals / Emergency Contact / Cane Equipment, one `TextField`
  per profile field, Cancel and a bold Save in the toolbar. Save writes the whole profile back to the
  store; Cancel discards.
- **Call** is a `Link` to `tel:` with the digits (and a leading `+`) of the stored number; nothing else
  in the app dials.
- **Announce Medical ID** speaks one paragraph at **`.scene`, 20 s TTL** (§5.1): "<name>. White cane
  user, legally blind. Blood type <type>. Allergies: <list>. Emergency contact: <name>, <phone>." The
  Step 47 audit moved it down from `.obstacle`: a user-requested paragraph must be cut by an obstacle
  name or a route line, never the reverse (AGENTS.md rule 8).
- **Mobility tiles** read `MobilityStats` (`CMPedometer`, today): steps and distance fall back to the
  live trip's `steps` / `distanceM` when today's totals are zero; average pace shows 1.2 m/s when
  nothing has been measured (a placeholder, not a measurement — do not quote it as one). The refresh
  glyph re-reads the pedometer.
- No switch on this page persists a setting; the page reads the store and the model, nothing else.

| # | Element | VoiceOver label | Value / hint | Traits |
|---|---|---|---|---|
| 1 | Card title | "EMERGENCY MEDICAL ID" | — | `.isHeader` |
| 2 | Photo | "Profile photo of <name>" (the SF Symbol fallback is unlabelled) | — | image |
| 3 | Name, "EMERGENCY ID", banner and notes | the texts themselves | — | static text |
| 4 | Edit | "Edit Medical ID" | — | button; presents the sheet |
| 5 | Info rows | "<label>" then "<value>" (two elements per row, in order) | — | static text |
| 6 | Emergency contact | "EMERGENCY CONTACT", "<name>", "<relation> · <phone>" | — | static text |
| 7 | Call | "Call emergency contact <name>" | — | link |
| 8 | Announce Medical ID | "Announce Medical ID" | hint "Reads emergency medical identification aloud" | button |
| 9 | Card title | "MOBILITY & FITNESS" | — | `.isHeader` |
| 10 | Refresh | "Refresh mobility stats" | — | button |
| 11 | Metric tile (×4) | "Steps Today: 4,812" / "Distance: 3.2 km" / "Trips Finished: 3" / "Average Pace: 1.2 m/s" (`.combine`, one element each) | — | — |
| 12 | Active route block (navigating) | "ACTIVE ROUTE", the route name, "N min elapsed" | — | static text |
| — | Edit sheet | "Edit Medical ID" title; fields by placeholder ("Full Name", "Blood Type", "Phone Number", …); "Cancel" / "Save" | — | text fields, buttons |

**No XCUITest opens this tab** (§9): the "Profile" tab label and every label above are free to
improve, but keep this table in step. Open design gaps: the photo is a bundled asset of one person,
not a picked photo; the info rows are two VoiceOver elements each rather than one combined "Blood
Type, A negative"; the tiles' 1.2 m/s placeholder is indistinguishable from a measurement.

---

## 7. Do not

- No colour-only meaning. Every lane state has a level word and a number; every pill has a word.
- No sentence text under 15 pt for the user; the only smaller text is the listed caption exceptions in §1 (13 pt mono is reserved for `accessibilityHidden` developer views, and none is on screen since the footer was removed).
- No gradient text, no gradient fills, no glass over content that must be read. iOS 26 Liquid Glass stays where the system puts it (navigation bar, keyboard); our cards and tiles are flat.
- No pure grey neutrals and no `#000000` / `#FFFFFF` on the phone outside increased-contrast mode (the card `surface` is `#FFFFFF` in light mode by design; the watch ground is pure black because it is OLED).
- No side-stripe borders on cards. A card is a fill and a hairline.
- No animation on the depth grid. No colour cross-fades on lane tiles.
- No shadows. Elevation is a fill change and a hairline.
- No icon-only **action** buttons. Guide / route / haptic controls still carry a visible word; the
  SF Symbol is a companion (the watch's half-width buttons put the word under the symbol). The
  **root tab bar is the exception**: four icons, words only in VoiceOver (`Guide` / `Sense` /
  `Settings` / `Profile`). A tab never encodes a hazard.
- No custom fonts. SF Pro / SF Rounded / SF Mono only.
- No haptics for decoration. The Taptic Engine is a safety channel; the big-button press confirm,
  the tab-bar `.selection` tick, the watch's `.click` send confirm and the system crown detents
  are the only non-cue haptics.
- No sounds except speech and the beacon. No earcons. The beacon never plays through the phone speaker.
- No `CKBigButton` under 72 pt and no other phone button under 60 pt; no watch button under 44 pt.
- No double-speak: cue speech comes from `SpeechQueue`, never also from a VoiceOver announcement.
- No truncation of an instruction on the phone: it wraps, it is never cut with "…".
- No `accessibilitySortPriority`. The visual order is the focus order; if that's wrong, fix the layout.
- No light-on-dark hero in a dark room brighter than the tokens allow: the ivory is `#F4F1EA`, not white, on purpose.
- No renamed labels without the tests (§9).

---

## 8. Implementation notes for the Swift twin

- `CKColor.*` are `Color(uiColor:)` dynamic providers that read `userInterfaceStyle` and `accessibilityContrast` from the trait collection (`nonisolated` helper: UIKit may resolve them off-main). No phone view constructs a `Color` literal; the watch (`WKColor`) and the widget use fixed colours on purpose.
- Hero distance: `@ScaledMetric(relativeTo: .largeTitle) private var hero = 64`, then `.font(CKFont.hero(min(hero, 80)))`. There is no `.dynamicTypeSize` clamp anywhere.
- Border width: `CKMetrics.border(for: colorSchemeContrast)` returns 1 or 3; secondary buttons add 1.
- `CKBigButton(title:subtitle:systemImage:role:layout:hint:value:action:)` is the big button (Guide, Haptics "Speech test", Family alerts "Send test event" / "Save family emails", Profile "Announce Medical ID"). `subtitle` (Step 46) is the second line under the word on the route rows; `layout` is `.row` (default: icon, word, subtitle and chevron across the button, restacking only at accessibility sizes) or `.tile` (Step 47: icon over a centred word over the subtitle, ≥ `CKMetrics.tile` tall, for a side-by-side pair). The smaller buttons (Go, haptic / wrist test buttons) are plain `Button`s styled with `CKBigButtonStyle` and set their own labels. System `Toggle`s and the `TextField` are unstyled.
- `CKStatusPill(text:tone:systemImage:spoken:updatesFrequently:)` is the only pill: one VoiceOver element, label `spoken ?? text` (use `spoken` when the visible text is terse: "±6 M" → "GPS: ±6 m").
- `CKCard(title:) { }` is a `.contain` container labelled by its title; untitled cards set their own label.
- Watch: `WKBigButton`, `WKFont`, `WKColor`, `WKSpacing` in `WatchTheme.swift`; the watch is always dark.
- Demo checklist: Dark Mode on, Increase Contrast off (the normal ladder is calibrated), Bold Text off, Guided Access on, brightness 60 % in the dark room / 100 % outdoors, AirPods Spatial Audio off (`docs/devices_setup.md`). Reduce Motion only changes tab-switch chrome and the button-press scale — never a distance or a hazard.

---

## 9. Accessibility contract (what the XCUITests depend on)

`ios/CaneKitUITests/CaneKitUITests.swift`, `CaneKitVisualTour.swift` and `CaneKitIslandTour.swift` find
elements by these exact strings. AGENTS.md rule 9: none of them may change without updating the tests in
the same commit. All three suites launch with `CANEKIT_UITEST=1` (skips the launch location prompt and
mutes `SpeechQueue`). Today that is 12 XCUITests (10 in `CaneKitUITests`, `CaneKitVisualTour.testTour`,
`CaneKitIslandTour.testDynamicIsland`); `make uitest` runs the whole `CaneKitUITests` target, so all 12,
while `make tour` and `make island` run one suite each. The Street View "Where am I" test skips itself
unless `make uitest-streetview` passes a frame folder. Set a simulator location first
(AGENTS.md "Commands") or the route tests fail for want of a GPS fix.

| Query | Exact string | Where it comes from | Used by |
|---|---|---|---|
| `buttons[…]` | "Guide", "Sense", "Settings" | `RootTab.title` / `CKTabBar` (icon-only) | labels test (all three); haptics, mount and cue picker tests open Settings; tour |
| `buttons[…]` | "Profile" | `RootTab.title` / `CKTabBar` (the fourth tab, Step 44) | **no test uses it** (`testAccessibilityLabelsExist` asserts only the first three); a free label, listed so nobody assumes it is covered |
| `buttons[…]` | "Start route to CIF" | `GuideCard`, idle | every test waits for it first; tour |
| `buttons[…]` | "Navigate to CIF from here" | `GuideCard`, idle (its label is its text) | `testNavigateToCIFButtonIsOnTheIdleGuide`: exists and is enabled when idle, gone while a route runs, back after Stop (never tapped: it would request real Apple Maps directions) |
| — | "Cancel route start" | `GuideCard`, only while a route start waits for the depth interlock | **no test uses it** (the simulator has no LiDAR, so a route starts at once); a free label, listed so nobody assumes it is covered |
| `buttons[…]` | "Stop route" | `GuideCard`, navigating | route test, tour |
| `buttons[…]` | "Next" | `GuideCard`, navigating | route test (advances to WP2), tour |
| `buttons[…]` | "Repeat" | `GuideCard`, navigating / after arrival | route test (must not change the instruction; must be **absent** after a mid-route Stop), tour |
| `buttons[…]` | "Recenter" | `GuideCard`, navigating | route test, tour |
| `buttons[…]` | "Where am I" | `GuideCard` (becomes "Describing…" while busy) | no-key test, Street View test, labels test, tour |
| `buttons[…]` | "Go" | `GuideCard`, idle | empty-destination test, tour |
| `buttons[…]` | "Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic" | `HapticsCard` (`"Test \(title.lowercased()) haptic"`) | haptics test, tour |
| `switches[…]` | "Silence haptics" | `HapticsCard` toggle | haptics test, tour |
| `buttons[…]` | "Standard", "Detailed", "Indoors", "Outdoors" | Settings → Cues segmented pickers (`CueLevel.title` / `CuePlace.title`, CaneKitLogic; each segment is a button whose `isSelected` is its state) | `testCuePickersChangeAndRestore`: taps Standard and Indoors and waits for `isSelected`, then taps Detailed and Outdoors and asserts both selected; a teardown block registered first puts Detailed / Outdoors back even when an assert fails, so later tests, the tour and e2e never inherit a calmer level ("Quiet" is not queried) |
| `switches[…]` | "Mirror left / right" | Mount toggle | `testMountTogglesPersist` (value must change on a knob tap, then flipped back; persistence across a relaunch is not re-read) |
| `switches[…]` | "Write trip log" | Mount toggle | labels test |
| `otherElements[…]` | "Head row" | `LaneGridView` row label `"\(title) row"` | labels test |
| `staticTexts[…]` (exact) | "Type a destination first" | `AppModel.navigate(to:)` → Guide error line | empty-destination test, suggestion test |
| `textFields[…]` | "Destination" | `DestinationField` search field | suggestion test (types "Grainger") |
| `buttons` label BEGINSWITH … AND CONTAINS … | "Grainger Engineering Library" + "campus place" | `DestinationSuggestion.voiceOverLabel` (CaneKitLogic), "Grainger Engineering Library, campus place, …" — matched on name and kind, not the whole sentence (the row gains a detail line and, with a fix, a distance after it appears) | suggestion test (also: every button whose label contains "Urbana, IL" — a MapKit row — must sit lower on screen, and typing must clear the error line) |
| `staticTexts` label CONTAINS[c] | "Townsend" | WP1 `say` in `route_isr_cif.json`, shown as the instruction | route test |
| `staticTexts` label CONTAINS[c] | "Illinois Street" | WP2 `say` (WP1's line also contains it) | route test |
| `staticTexts` label CONTAINS[c] "camera" OR BEGINSWITH | "camera" / "Scene:" | describer error "No camera frame" (the simulator has no camera) or the scene text's label "Scene: <description>"; then "Where am I" must be back. No key is needed any more (cloud → on-device fallback) | no-key test |

Structural rules the tests rely on: the instruction and error lines are plain `Text`s whose label is
their content; the Mount and Haptics toggles are system `Toggle`s (the tests tap the nested switch, or
the knob at 94 % of the width — a tap on the label centre does nothing); the Head / Torso rows are single
elements; the Cues pickers are `.segmented` `Picker`s whose segments surface as buttons titled by
`CueLevel.title` / `CuePlace.title` (the VoiceOver container labels "Cue detail" / "Place" are not
queried). Settings written by a test persist in the simulator, so every test that changes one puts it
back. Labels outside this table (card titles, pill `spoken` strings, hints) are
free to improve, but keep them in step with §6.

---

## 10. Open design gaps (code ≠ intent, not yet fixed)

- Error lines use `laneUrgent` as text colour: fine on dark cards (6.4:1) but 2.8:1 on the white light-mode card, below WCAG AA. **Fixed for the Guide's route error line** (Step 14: `textPrimary` text plus a `danger` warning glyph); the describer error line on Guide and the Hazards card's error line still use red text.
- The lane-ladder contrast ratios quoted in `Theme.swift` / `CODE_REFERENCE.md` comments (11.4 / 15.2 / 8.9 / 7.1) are overstated; the recomputed values are in §2.
- The watch cuts a long instruction after two lines (≈ 70 % scale) — Repeat is the recovery.
- ~~The Live Activity glyph's VoiceOver label is the raw kind string ("turnLeft", "straight").~~ Fixed in Step 47: every presentation reads one natural sentence (§6.7).
- "GPS: Denied" is a neutral pill; a denied permission arguably deserves `danger`.
- Stop route has no lock or confirmation (Guided Access is the mitigation; `docs/todo.md` open item).
- `.updatesFrequently` pills may be read repeatedly by VoiceOver while focused (`docs/todo.md` open item).
