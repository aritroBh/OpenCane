# OpenCane design system

Visual + interaction spec for the iPhone app, the watch companion and the Live Activity.
Code twins: `ios/CaneKit/UI/Theme.swift` (phone tokens + components), `ios/CaneKitWatch/WatchTheme.swift`
(watch), `ios/CaneKit/Speech/SpeechQueue.swift` + `ios/Logic/Sources/CaneKitLogic/NavSupport.swift`
(speech rules), `ios/CaneKit/Haptics/HapticPlayer.swift` + `CueDecider.swift` (haptic patterns).

**Audited against the code on 2026-09-11 (after Step 10).** Every rule below describes what ships.
Where the original spec (Sep 10) and the Swift disagreed, the Swift won and this file changed; the parts
of the original spec that were never built are kept, marked **Not built**, so nobody "fixes" the code back
toward them by accident. From now on change a rule here and in the Swift in the same commit. Two things
outrank both: `AGENTS.md` hard rule 8 (speech priorities, §5.1) and rule 9 (accessibility labels are a
test contract, §9).

Section numbers are referenced from code comments (`§1`–`§8`, `§6.1`–`§6.7`); keep them stable.

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
| **The blind user** | Never looks. Phone is clamped to the cane; they use speech, the cane's buzz, the watch, or the Action button ("Where am I"). | Every state has words: speech via `SpeechQueue`, and a VoiceOver label / value on screen. The page is one linear VoiceOver list in visual order. Our own buttons are ≥ 60 pt (big buttons 72 pt). Nothing is colour-only. |
| **The sighted judge / teammate** | Glances at the phone on the cane from ~1 m, in a dark room (demo) or in sunlight (walk). | The Guide instruction, the distance and the depth tiles must be readable at arm's length: tile numerals 28 pt bold, hero distance 64 pt, fills ≥ 6.5:1 against their `ink` text, no thin type, no mid-grey. Dark surfaces for the demo (a bright screen in a dark room blinds the room). |
| **The developer** | Reads engine health, speech backend, watch link and the hazard detections while walking behind. | The debug cards below the Guide (Haptics, Hazards, Watch, This phone). There is no debug footer any more (removed): fps is not shown anywhere, and thermal and battery are only in the trip log's `lanes` records. |

**Brand voice.** A safety instrument, not a lifestyle app. Think avalanche beacon or aircraft
standby gauge: calm, terse, trustworthy, legible in the dark. Everything on screen is either a
measurement, a state, or a button. No marketing surfaces.

**The five rules** (the rest of this file is detail):
1. Words first. Speech is the primary channel; the screen mirrors it, never replaces it.
2. Redundancy on every hazard: a depth tile has a fill colour **and** a level word (CLEAR / FAR / NEAR /
   STOP) **and** a number; a pill is always a word on a fill (the SF Symbol is a companion).
3. Big and few. While a route runs the Guide card has five big buttons (Where am I, Repeat, Next,
   Recenter, Stop route), never more than two per row; everything else lives in the cards below it.
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
- Units spoken: US spelling, words not symbols: "meters", "kilometers", "Ahead, one and a half meters." (`SpokenDistance.phrase` rounds to half metres: "very close", "half a meter", "one meter", …).

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

Touch targets (`CKMetrics`): `CKBigButton` is ≥ 72 pt tall, full width or half width (two per row with
`lg` between them). Every other button we draw (Go, the four haptic test buttons, the four wrist-cue
buttons, Share hazard map) is ≥ 60 pt tall (`touchTarget`). System `Toggle`s keep their system size (≥ 44 pt, HIG); the destination search field
and every destination suggestion row are `touchTarget` (60 pt) like the buttons beside them. Tiles are not tappable (they are a display). Watch buttons are ≥ 44 pt
(`WKSpacing.touchTarget`: 48 pt pushed the bottom row off a 46 mm screen). Pills are 32 pt tall and not
interactive.

Elevation: none. No shadows — a card is a fill and a hairline. Depth is not a metaphor we need
when the screen is a gauge.

---

## 4. Motion

Motion never carries information. The app owns exactly one animation, and it honours Reduce Motion
(`accessibilityReduceMotion`):

| Event | Normal | Reduce Motion |
|---|---|---|
| Depth grid update (30 Hz) | **None.** Fill, word and number change instantly. | Same |
| Big button press (`CKBigButtonStyle`, also Go and the test buttons) | Scale 0.97 on a 0.12 s spring; `.sensoryFeedback(.impact(weight: .light))` on release | Opacity 0.85 only; haptic kept |
| Everything else (pills, distance, instruction, cards appearing) | Instant | Instant |

Never animate layout of the grid. Never animate colour of a lane tile (a fade through orange
lies about the distance for 150 ms).

**Not built** (original spec, deliberately dropped): urgent-tile 2 Hz pulse and 4 pt border, 150 ms pill
cross-fade, `.numericText()` distance transition, sliding obstacle banner, arrival sheet, tab switches.

---

## 5. Cue mapping: every cue → felt, heard, shown

Sources: `CueDecider` (obstacle cues, CaneKitLogic) → `HapticPlayer` (phone Taptic Engine, felt through
the cane); `CueSpeechPolicy` (which obstacle cues are also spoken); `ObstacleNamer` (mesh names);
`NavigationEngine` (waypoint lines, veer, wrist cues); `BeaconEngine` (spatial click, AirPods);
`WatchModel` (wrist haptics); `GroundHazardDetector` + `GroundHazardPolicy` (LiDAR drop-offs, CaneKitLogic)
and `HazardScanner` (signs, hazard watch). All speech goes through `SpeechQueue`.

### 5.1 Speech priorities (`SpeechQueue`, AGENTS.md hard rule 8)

| Priority | What speaks at it (literal lines from the code) | TTL while queued |
|---|---|---|
| `.safety` (3, top) | "Head height."; LiDAR ground hazards "Drop-off ahead, two meters." / "Hole ahead, …" / "Step up ahead, …" / "Low obstacle ahead, …"; route-start failure "Obstacle detection is not ready. Route did not start. Check the camera and reopen OpenCane." | 6 s "Head height.", 3 s ground hazards, 30 s route-start failure |
| `.nav` (2) | Waypoint `say` lines; "Route started. <route>. First: …"; "Passed <place>. <Next place> in N meters." / "Passed one waypoint."; "Veer left." / "Veer right."; "GPS weak. Waypoint cues paused until it recovers." / "GPS back."; "You are close to <place>. Keep going toward it, or press Next to finish."; the arrival trip summary; "Recentered."; "Route stopped."; "No route running."; "OpenCane ready."; "Obstacle detection warming up. Route will start when it is ready."; "Both cameras cannot run while a route is starting. Wait for obstacle detection to be ready."; headphone and channel lines ("<AirPods> connected.", "Headphones disconnected. Beacon paused.", "No headphones. Beacon paused until AirPods connect.", "Watch not reachable. Open OpenCane on the watch.", "Haptics unavailable. Obstacle cues will be spoken."); "Phone is hot. Door and wall names and sign reading paused."; "Location access is off. Turn on Location for OpenCane in Settings to navigate."; "Camera access is off, so obstacle warnings cannot work. Turn on Camera for OpenCane in Settings."; MapKit route lines | 12 s waypoint lines and the arrival hint, 30 s arrival summary, 20 s channel, Location and Camera lines, 10 s "Phone is hot…", 8 s warm-up/default |
| `.obstacle` (1) | Mesh names "door ahead, two meters" (door / wall / seat / window / table); "Left." / "Right." / "Ahead, one meter." when the phone cannot buzz; signs "Sign: sidewalk closed."; hazard watch "Caution: cones ahead, 3 meters." | 4 s names, 6 s cue, sign and caution lines |
| `.scene` (0, bottom) | "Describing."; the one-sentence description (cloud model, or on-device when there is no key or no network); "Camera warming up. Try again."; "Scene description failed." | 3 s "Describing.", 20 s description, 8 s default |

Rules (all in `SpeechQueue`):
- A **strictly higher** priority interrupts the line playing (at a word boundary with the system voice, at once with an ElevenLabs clip); equal or lower queues behind it, FIFO within a priority. "Head height." therefore cuts everything and nothing cuts it.
- The interrupted line goes back to the front of its band and resumes after the interrupter, **once**; cut a second time it is dropped (Repeat recovers it). Its validity is extended to ≥ 8 s from the cut.
- Queued lines expire (TTL above); expired lines are purged whenever a line ends, so a stale "turn left" is never spoken late.
- Coalescing: a line identical to the one playing or already queued is dropped. **Repeat** bypasses this (`sayAgain`): it speaks the last line actually spoken plus " Next, <place>, in N meters.", interrupting an equal-or-lower line and queuing behind a higher one.
- Phone call / Siri: the current line is re-queued, new lines queue (deduplicated) and nothing plays; on `.ended` (or after 15 s if it never arrives) the session re-activates and the queue drains in priority order.
- Warnings never wait for the network: `.obstacle` and `.safety` lines that are not already cached use the system voice at once (and prefetch the ElevenLabs voice for next time). Other lines use a cached ElevenLabs clip, else fetch it, else fall back to the system voice.
- Watchdog: 6 s + characters / 6 after a line starts, a missing end callback counts as the end.

Old comments that say "P0 / P1 / P2" refer to the original spec: P0 ≈ `.safety` + `.nav`, P1 ≈ `.obstacle`, P2 ≈ `.scene`. The four levels above are the truth.

### 5.2 Obstacle cues (phone Taptic Engine, felt through the cane)

Decided by `CueDecider` on every trusted depth report (~30 Hz). One cue at a time, priority **head >
centre > left > right**. A zone switches on below its threshold and off only 0.15 m beyond it
(hysteresis); cue *changes* are ≥ 400 ms apart; a discrete cue (left / right / head) re-fires at most
once per second while it stays active.

| Cue | Trigger | Felt (`HapticPlayer`) | Heard (`CueSpeechPolicy`, `.obstacle` unless noted) | Shown (phone) | Wrist (mirror) |
|---|---|---|---|---|---|
| `clear` | nothing in range | Nothing; any loop stops | Nothing | Tiles CLEAR; Haptics card cue pill CLEAR (neutral) | — |
| `centerApproach(d)` | torso-centre lane < 2.0 m | Geiger loop: one transient (sharpness 0.6) repeated at 4 / d Hz, clamped 2 Hz @ 2 m → 8 Hz @ 0.5 m; intensity 0.6 @ 2 m → 1.0 @ 0.5 m | Only when the phone cannot buzz: "Ahead, <distance>." at most every 4 s | Torso-centre tile; cue pill CENTER (warning) | `.click` |
| `left` | torso-left lane < 1.2 m | 2 transients 120 ms apart, intensity 0.9, sharpness 0.5 | Only when the phone cannot buzz: "Left." at most every 4 s | Torso-left tile; cue pill LEFT | `.start` |
| `right` | torso-right lane < 1.2 m | 3 transients 100 ms apart, intensity 0.9, sharpness 0.5 | Only when the phone cannot buzz: "Right." at most every 4 s | Torso-right tile; cue pill RIGHT | `.stop` |
| `head` | any head-row lane < 1.5 m | 2 transients 80 ms apart, intensity 1.0, sharpness 1.0; re-fires every second while the obstacle stays — **never suppressed** | Spoken even when the phone can buzz: "Head height." at `.safety`, once per obstacle episode (a new episode starts after the cue clears or another cue is spoken), no more than one per 4 s | Head-row tile; cue pill HEAD | `.failure` (reserved for head height) |
| Mesh name | door / seat / window / table < 3 m, wall < 1.5 m at the image centre (indoors; off when thermal ≥ serious) | — | "door ahead, two meters": on a class change or ≥ 1 m of movement, at most every 2.5 s; "Speak obstacle names" toggle (on by default) | — | — |
| Ground hazard (not `CueDecider`: `GroundHazardDetector`, "Detect drop-offs" toggle, off by default) | drop-off / hole / step up / low obstacle in a 0.9 m wide corridor 1.5–3.5 m ahead: an edge against the near-field ground, confirmed on 3 of the last 5 trusted frames | 4 heavy taps 70 ms apart (intensity 1.0, sharpness 0.3), `playGroundHazard` | Always spoken, `.safety`: "Drop-off ahead, two meters." (`GroundHazardPolicy`: the same hazard in the same place, e.g. a curb you stand at, is said once, then at most every 30 s, and again once it is 1 m closer) | Hazards card LIDAR row; hazard map entry | `.click` when the phone cannot buzz or the mirror toggle is on |
| Sign / hazard watch (`HazardScanner`, camera) | "Read signs" (on by default): on-device text every 3 s, small text down to 1/128 of the frame height (7.5 cm letters from ≈ 7 m, measured); never "STOP" (a drivers' sign); "Hazard watch" (off by default): one frame to the vision model every 8 s while walking a route | Nothing | "Sign: sidewalk closed." (each sign at most once a minute); "Caution: cones ahead, 3 meters." ("NONE" is silent) | Hazards card SIGN / WATCH rows; hazard map entry | — |
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
| Route start | If LiDAR + camera are available, "Obstacle detection warming up. Route will start when it is ready."; then "Route started. <route name>. First: <WP1 say>" + any channel warnings only after the trusted-depth gate clears. No-LiDAR / camera-denied devices keep the documented GPS-only start with an explicit warning. | — while queued; normal route cues after start | Starts only after 3 fresh same-frame trusted depth reports on the LiDAR path | While queued, the Guide card shows the warm-up / timeout status and keeps Start disabled; after start, instruction = next waypoint's `say`; Repeat / Next / Recenter / Stop appear |
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
| Where am I (phone button, watch Describe, Action button shortcut, Camera Control if it fires) | light impact on release (phone button) | "Describing." then the one-sentence description (`.scene`); without a key or network the on-device describer answers (Vision + Apple's on-device model, or a template). It waits up to 3 s for a camera frame; the frame from before a screen lock or backgrounding is dropped, so after unlocking it waits for a fresh one ("Camera warming up. Try again." if none comes) | Button reads "Describing…" (value "in progress", disabled); result text under it; error line in red | `.click` confirm on send |
| Repeat (phone, watch, "Repeat in OpenCane") | light impact | The last line actually spoken + " Next, <place>, in N meters." | Instruction unchanged | `.click` |
| Next (phone, watch button, crown 3 detents in 1 s) | light impact | The skipped waypoint's own line; "No route running." when idle | Instruction advances | `.click` |
| Recenter (phone, watch) | light impact | "Recentered." | — | `.click` |
| Watch command fails | — | — | — | `.retry` + red line "Phone not reachable"; phone older than watch: `.retry` + "Update the phone app" |
| Headphones connect / disconnect | — | "<name> connected." / "Headphones disconnected. Beacon paused." | Beacon pill BEACON PAUSED + NO AIRPODS (warning) | — |
| Watch not reachable at route start | — | "Watch not reachable. Open OpenCane on the watch." | Watch card pill ASLEEP (neutral) | — |
| Haptic engine down | (cues go to the watch and to speech) | at route start, if the watch is also unreachable: "Haptics unavailable. Obstacle cues will be spoken." | ENGINE DOWN (danger) | obstacle mirror |
| Thermal `.serious` / `.critical` | — | "Phone is hot. Door and wall names and sign reading paused." once per transition into hot (`.nav`) | Mesh classification off (so no mesh names), sign reading and hazard watch paused, the live camera view stops updating; status card "Mesh classification off (thermal)". The thermal state is only in the trip log | — |
| Battery | — | Nothing | Nothing on screen; the trip log only | — |

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
mode, so keep traffic audible with Transparency (a recommendation, not enforced).

**VoiceOver rule.** The `SpeechQueue` is the app's voice. The app posts exactly one
`AccessibilityNotification.Announcement` — the destination suggestion count ("6 results", §6.3), which
is screen state nothing speaks — so a VoiceOver user is never pushed a *cue* twice. Live values
carry `.updatesFrequently` so touching them reads the current state.

---

## 6. Screens

The phone app is **one scrolling page** (`ContentView`: `NavigationStack` > `ScrollView`, large title
"OpenCane", `gutter` padding, `xl` between cards). There is no tab bar. Card order is the VoiceOver order:

```
OpenCane                                  ← large navigation title
┌ Guide ──────────────────────────────┐   §6.1 / §6.3  GuideCard
┌ This trip  |  Arrived ──────────────┐   §6.4  ArrivalCardView (only while navigating or after arrival)
┌ ✓ Depth OK ─────────────────────────┐   §6.2  status card (untitled)
┌ Obstacles ──────────────── (TRUSTED)┐   §6.2  LaneGridView
┌ Haptics ────────────────────────────┐   §6.5  HapticsCard
┌ Hazards ────────────────────────────┐   §6.5  HazardsCard
┌ Watch ──────────────────────────────┐   §6.5  WatchCard
┌ Mount ──────────────────────────────┐   §6.5  Mount toggles
┌ This phone ─────────────────────────┐   §6.5  capability rows (last; the debug footer was removed)
```

Card titles are `.isHeader`, so the headings rotor jumps Guide → This trip / Arrived → Obstacles →
Haptics → Hazards → Watch → Mount → This phone. Legend for the wireframes: `[ ]` button · `( )` pill · `┌┐` card.

**Not built** (original spec): the four-tab bar (Guide · Depth · Route · Settings), a separate Depth
screen with Mirror / Export buttons, the route picker screen, the Settings screen with a provider picker
and a "Show debug footer" toggle, the obstacle banner on Guide, the arrival sheet.

### 6.1 Guide

```
While a route runs                                  Idle (before a route / after Stop / after arrival)
┌ Guide ─────────────────────────────────┐          ┌ Guide ─────────────────────────────────┐
│ Goodwin Avenue. Intersection. Turn     │          │ No route                               │
│ right to face north and stay on this   │          │ (⌖ OFF)   GPS runs only during a route │
│ side. No crossing needed. Listen for … │          │ [ ◉ Where am I                       ] │
│ 120 m                (↱ VEER RIGHT 40°)│          │ [ ⟲ Repeat                           ] │ ← only after arrival
│ (⌖ ±6 M) (⚠ GPS WEAK)                  │          │ [ ▶ Start route to CIF               ] │
│ [ ◉ Where am I                       ] │          │ [ ⌕ grainger             ⓧ] [ Go ]     │ ← 60 pt field
│ [ ⟲ Repeat       ] [ ⏭ Next          ] │          │ [ ▣ Grainger Engineering Library      ] │ ← suggestions,
│ [ ⌖ Recenter                         ] │          │ [   On campus · 400 m       (CAMPUS)  ] │   campus first
│ (BEACON 40%) (HEAD TRACKED)            │          │ [ ◎ Grainger Industrial Supply        ] │
│ [ ■ Stop route                       ] │          │ ⚠ Type a destination first             │ ← only after a
└────────────────────────────────────────┘          └────────────────────────────────────────┘   failed attempt
```

- Instruction: the *upcoming* waypoint's `say` ("Arrived: <say>" after arrival, "No route" when idle), `instruction` font, wraps without limit — the spotter reads it over the walker's shoulder.
- Distance row: only with a GPS-derived distance (never in the simulator without a fix): hero integer metres + "m", and the bearing pill when there is a heading and a target (hidden on a curved leg and while silent at a crossing).
- Button rows while navigating: Repeat (primary) + Next (secondary) share a row; Recenter (secondary) has its own row (three-up hyphenated "Recenter" on a 17 Pro Max); the beacon / head pills sit between Recenter and **Stop route (destructive, last)**, so Stop is the furthest control from Repeat / Next. Stop has no confirmation — use Guided Access on the walk.
- Where am I is always present (idle and navigating), above the route controls.

| # | Element | VoiceOver label | Value / hint | Traits |
|---|---|---|---|---|
| 1 | Card title | "Guide" | — | `.isHeader` |
| 2 | Instruction | the instruction text itself | — | `.isHeader`, `.updatesFrequently` |
| 3 | Distance row (combined) | "N meters to the next point" | — | — |
| 4 | GPS pill | "GPS: ±N m" / "GPS: Searching" / "GPS: Denied" / "GPS: Off" | — | `.updatesFrequently` |
| 5 | GPS weak pill | "GPS weak" | — | — |
| 6 | Where am I | "Where am I" ("Describing…" while busy) | value "in progress" while busy; hint "Takes a photo and reads out hazards and landmarks ahead" | button; disabled while busy |
| 7 | Scene text / describer error | "Scene: <description>" / the error text | — | — |
| 8 | Repeat | "Repeat" | hint "Says the current instruction again" ("Says the arrival line again" after arrival) | button |
| 9 | Next | "Next" | hint "Skips to the next instruction" | button |
| 10 | Recenter | "Recenter" | hint "Sets straight ahead as the beacon's forward direction" | button |
| 11 | Beacon pill | "Beacon: Beacon N%" / "Beacon: Beacon paused" / "Beacon: Beacon off" / "Beacon: Beacon idle" | — | `.updatesFrequently` |
| 12 | Headphone pill | "<output name>, head tracking on" / "<output name>, no head tracking" / "No headphones connected; beacon paused" | — | — |
| 13 | Stop route | "Stop route" | hint "Ends guidance" | button |
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
(`AppIntents.swift`): "Start the demo route / Navigate to CIF from here / Take me to Grainger / Take me
somewhere / Repeat the last instruction / Next waypoint / Stop the route **in OpenCane**", plus "Where am I
in OpenCane". Seven of the ten App Shortcuts an app may register, all `.foreground(.immediate)` — ARKit
obstacle warnings only run with the app frontmost, so guidance must never start in the background.
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

There is no Settings screen; the settings are system `Toggle`s inside cards (label + VoiceOver hint;
VoiceOver announces "switch button, on / off" for free). All persist in `UserDefaults` except "Live
camera view", which is off at every launch.

| Card | Control (visible label = VoiceOver label) | Default | Hint |
|---|---|---|---|
| Mount | "Phone held upright (portrait)" | on | "Turn off if the phone is clamped sideways" |
| Mount | "Mirror left / right" | off | "Turn on if left and right warnings feel swapped" |
| Mount | "Audio beacon while navigating" | on | "A soft click from the direction to walk, through the AirPods" |
| Mount | "Write trip log" | on | "Saves a JSONL log of lanes, cues and location to the Files app" |
| Haptics | "Silence haptics" | off | "The phone stops vibrating; obstacle cues go to the watch and are spoken instead" |
| Haptics | "Speak obstacle names" | on | "Says door, wall, seat, window or table when one is straight ahead" |
| Hazards | "Detect drop-offs" | off (until validated on the phone) | "LiDAR warns about curbs, holes and drop-offs 1.5 to 3 meters ahead" |
| Hazards | "Read signs" | on | "Reads signs like sidewalk closed or detour, on the phone, offline" |
| Hazards | "Hazard watch" | off (until validated on the phone) | "While walking a route, checks the path for cones, barriers and scooters every 8 seconds" |
| Hazards | "Live camera view" | off, not persisted | "Shows what the camera sees, for a sighted helper" |
| Watch | "Mirror obstacle cues to the watch" | off | "Also taps the wrist for every obstacle; automatic when the phone's haptic engine fails" |

Debug controls (sighted teammate / developer):
- **Haptics card**: pills ENGINE OK / ENGINE DOWN and the active cue; four test buttons "Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic" (60 pt, icon + caption, bypass the decider; centre plays the loop for 2 s); speech pills SPEAKING / QUIET and SYSTEM / ELEVENLABS; a "Speech test" big button (a scene line, then an obstacle line that interrupts it).
- **Hazards card**: two neutral pills, the hazard watch backend (the provider name, e.g. "ON-DEVICE"; spoken "Hazard watch uses …") and "N MAPPED" (spoken "N hazards on the map"); one detection row per source that has spoken, LIDAR / SIGN / WATCH in the `pill` font and `textSecondary` followed by the last line in `body` (one VoiceOver element per row); an error line in red; "Share hazard map" (60 pt, secondary style, a `ShareLink` of this session's GeoJSON, shown once the file exists, hint "Shares a GeoJSON map of every hazard found on this walk"); under "Live camera view" a ~3 Hz camera image (hidden from VoiceOver, "Camera warming up" before the first frame, no new frames while hot or in the background).
- **Watch card**: link pill REACHABLE / ASLEEP / APP NOT INSTALLED / NOT PAIRED / UNSUPPORTED and the last watch command; four buttons "Send left / right / cross / arrive cue to the watch" (disabled when unreachable).
- **This phone**: "LiDAR depth", "Mesh classification (door / wall / seat)", "Logic package linked", each read as "<name>: available / not available".
- **Debug footer**: removed (`DebugFooter.swift` is gone). fps is no longer shown; thermal and battery are in the trip log's `lanes` records; the log file is found in the Files app.

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
but unused); `WKFont` instruction `.title3` semibold, button `.headline` rounded semibold, footnote;
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

```
Lock screen / banner
┌───────────────────────────────────────────────────────┐
│  ↱   Goodwin Avenue. Intersection. Turn right…   120 m │  glyph .title bold; instruction .headline ≤ 2 lines;
│      ISR Townsend Hall to CIF                          │  route name .caption secondary; distance .title rounded heavy, tabular
└───────────────────────────────────────────────────────┘
Dynamic Island: expanded = glyph (leading) · distance (trailing) · instruction (bottom, ≤ 2 lines)
                compact = glyph + distance · minimal = glyph only (never the distance)
```

- Glyph from the last wrist cue: `arrow.turn.up.left` / `arrow.turn.up.right` (turns and veers), `figure.walk` (crossing), `flag.checkered` (arrived / ended), `arrow.up` (straight, at route start).
- Colours are fixed, not `CKColor`: ink ground (`activityBackgroundTint` ≈ `#171410`) with ivory text (≈ `#F5F2EB`). No pill, no colour meaning.
- Update rate: on every GPS fix, coalesced — only when the instruction or glyph changes or the distance moves ≥ 10 m (ActivityKit budget). The island is a summary, not a gauge.
- Ends on arrival or Stop with the arrival glyph, dismissed 60 s later. Tapping opens the app. No interactive buttons: "Next" from the lock screen is too easy to hit by accident with the phone on a cane.
- **Not built**: the TRUSTED pill and the "14 min left · 820 steps" line; VoiceOver currently reads the glyph by its raw kind ("turnLeft"), see §10.

---

## 7. Do not

- No colour-only meaning. Every lane state has a level word and a number; every pill has a word.
- No sentence text under 15 pt for the user; the only smaller text is the listed caption exceptions in §1 (13 pt mono is reserved for `accessibilityHidden` developer views, and none is on screen since the footer was removed).
- No gradient text, no gradient fills, no glass over content that must be read. iOS 26 Liquid Glass stays where the system puts it (navigation bar, keyboard); our cards and tiles are flat.
- No pure grey neutrals and no `#000000` / `#FFFFFF` on the phone outside increased-contrast mode (the card `surface` is `#FFFFFF` in light mode by design; the watch ground is pure black because it is OLED).
- No side-stripe borders on cards. A card is a fill and a hairline.
- No animation on the depth grid. No colour cross-fades on lane tiles.
- No shadows. Elevation is a fill change and a hairline.
- No icon-only buttons. Every button has a visible word; the SF Symbol is a companion (the watch's half-width buttons put the word under the symbol).
- No custom fonts. SF Pro / SF Rounded / SF Mono only.
- No haptics for decoration. The Taptic Engine is a safety channel; the big-button press confirm, the watch's `.click` send confirm and the system crown detents are the only non-cue haptics.
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
- `CKBigButton(title:systemImage:role:hint:value:action:)` is the big button (Guide, Haptics "Speech test"). The smaller buttons (Go, haptic / wrist test buttons) are plain `Button`s styled with `CKBigButtonStyle` and set their own labels. System `Toggle`s and the `TextField` are unstyled.
- `CKStatusPill(text:tone:systemImage:spoken:updatesFrequently:)` is the only pill: one VoiceOver element, label `spoken ?? text` (use `spoken` when the visible text is terse: "±6 M" → "GPS: ±6 m").
- `CKCard(title:) { }` is a `.contain` container labelled by its title; untitled cards set their own label.
- Watch: `WKBigButton`, `WKFont`, `WKColor`, `WKSpacing` in `WatchTheme.swift`; the watch is always dark.
- Demo checklist: Dark Mode on, Increase Contrast off (the normal ladder is calibrated), Bold Text off, Guided Access on, brightness 60 % in the dark room / 100 % outdoors, AirPods Spatial Audio off (`docs/devices_setup.md`), Reduce Motion irrelevant (nothing meaningful moves).

---

## 9. Accessibility contract (what the XCUITests depend on)

`ios/CaneKitUITests/CaneKitUITests.swift` and `CaneKitVisualTour.swift` find elements by these exact
strings. AGENTS.md rule 9: none of them may change without updating the tests in the same commit.
Both suites launch with `CANEKIT_UITEST=1` (skips the launch location prompt).

| Query | Exact string | Where it comes from | Used by |
|---|---|---|---|
| `buttons[…]` | "Start route to CIF" | `GuideCard`, idle | every test waits for it first; tour |
| `buttons[…]` | "Stop route" | `GuideCard`, navigating | route test, tour |
| `buttons[…]` | "Next" | `GuideCard`, navigating | route test (advances to WP2), tour |
| `buttons[…]` | "Repeat" | `GuideCard`, navigating / after arrival | route test (must not change the instruction; must be **absent** after a mid-route Stop), tour |
| `buttons[…]` | "Recenter" | `GuideCard`, navigating | route test, tour |
| `buttons[…]` | "Where am I" | `GuideCard` (becomes "Describing…" while busy) | no-key test, labels test, tour |
| `buttons[…]` | "Go" | `GuideCard`, idle | empty-destination test, tour |
| `buttons[…]` | "Test left haptic", "Test center haptic", "Test right haptic", "Test head haptic" | `HapticsCard` (`"Test \(title.lowercased()) haptic"`) | haptics test, tour |
| `switches[…]` | "Silence haptics" | `HapticsCard` toggle | haptics test, tour |
| `switches[…]` | "Mirror left / right" | Mount toggle | toggle test (value must change on tap) |
| `switches[…]` | "Write trip log" | Mount toggle | labels test |
| `otherElements[…]` | "Head row" | `LaneGridView` row label `"\(title) row"` | labels test |
| `staticTexts[…]` (exact) | "Type a destination first" | `AppModel.navigate(to:)` → Guide error line | empty-destination test, suggestion test |
| `textFields[…]` | "Destination" | `DestinationField` search field | suggestion test (types "Grainger") |
| `buttons[…]` | "Grainger Engineering Library, campus place" | `DestinationSuggestion.voiceOverLabel` (CaneKitLogic) for a campus row with no fix | suggestion test |
| `staticTexts` label CONTAINS[c] | "Townsend" | WP1 `say` in `route_isr_cif.json`, shown as the instruction | route test |
| `staticTexts` label CONTAINS[c] | "Illinois Street" | WP2 `say` (WP1's line also contains it) | route test |
| `staticTexts` label CONTAINS[c] "camera" OR BEGINSWITH | "camera" / "Scene:" | describer error "No camera frame" (the simulator has no camera) or the scene text's label "Scene: <description>"; then "Where am I" must be back. No key is needed any more (cloud → on-device fallback) | no-key test |

Structural rules the tests rely on: the instruction and error lines are plain `Text`s whose label is
their content; the Mount toggles are system `Toggle`s (the tests tap the switch knob); the Head / Torso
rows are single elements. Labels outside this table (card titles, pill `spoken` strings, hints) are
free to improve, but keep them in step with §6.

---

## 10. Open design gaps (code ≠ intent, not yet fixed)

- Error lines use `laneUrgent` as text colour: fine on dark cards (6.4:1) but 2.8:1 on the white light-mode card, below WCAG AA. **Fixed for the Guide's route error line** (Step 14: `textPrimary` text plus a `danger` warning glyph); the describer error line on Guide and the Hazards card's error line still use red text.
- The lane-ladder contrast ratios quoted in `Theme.swift` / `CODE_REFERENCE.md` comments (11.4 / 15.2 / 8.9 / 7.1) are overstated; the recomputed values are in §2.
- The watch cuts a long instruction after two lines (≈ 70 % scale) — Repeat is the recovery.
- The Live Activity glyph's VoiceOver label is the raw kind string ("turnLeft", "straight").
- "GPS: Denied" is a neutral pill; a denied permission arguably deserves `danger`.
- Stop route has no lock or confirmation (Guided Access is the mitigation; `docs/todo.md` open item).
- `.updatesFrequently` pills may be read repeatedly by VoiceOver while focused (`docs/todo.md` open item).
