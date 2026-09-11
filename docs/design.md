# CaneKit design system

Visual + interaction spec for the iPhone app, the watch companion and the Live Activity.
Code twin: `ios/CaneKit/UI/Theme.swift` (phone) and `ios/CaneKitWatch/WatchTheme.swift` (watch).
When this file and the Swift disagree, fix the Swift.

---

## 0. Who looks at the screen, and what that forces

| Viewer | Situation | What it forces |
|---|---|---|
| **The blind user** | Never looks. Phone is clamped to the cane; they touch it by feel or use the watch / Action button. | Every screen is a linear VoiceOver list with an obvious focus order. Touch targets ≥ 60 pt (ours are 72 pt). Every state has words: speech via `SpeechQueue`, and an `accessibilityValue` on screen. Nothing is colour-only. |
| **The sighted judge / teammate** | Glances at the phone on the cane from ~1 m, in a room with the lights off (demo) or in sunlight (walk). | The 6-tile grid and the status pill must be readable at arm's length: numerals ≥ 28 pt bold, fills at ≥ 7:1 against their text, no thin type, no mid-grey. Dark surfaces by default (a bright screen in a dark room blinds the room). |
| **The developer** | Reads fps, \|ω\|, thermal, battery, log while walking behind. | A monospaced footer that is *hidden from VoiceOver* and off by default. Debug never steals space from the grid. |

**Brand voice.** A safety instrument, not a lifestyle app. Think avalanche beacon or aircraft
standby gauge: calm, terse, trustworthy, legible in the dark. Everything on screen is either a
measurement, a state, or a button. No marketing surfaces.

**The five rules** (the rest of this file is detail):
1. Words first. Speech is the primary channel; the screen mirrors it, never replaces it.
2. Three-way redundancy on every hazard: fill colour **and** a glyph **and** a number.
3. Big and few. Four big buttons on Guide. If a fifth is needed, it goes to Settings.
4. Ivory on near-black. The white cane is the brand; the accent is *cane white on ink*, not a hue.
5. Nothing animates that carries meaning. The grid updates at 15 Hz with no transitions.

---

## 1. Typography

Fonts are system only (no bundle, no licensing, full Dynamic Type):

| Face | Used for | Why |
|---|---|---|
| **SF Pro (text design, default)** | Instructions, body, settings, hints | Highest legibility per point at UI sizes; Dynamic Type native. |
| **SF Rounded** | Distance numerals, tile metres, button labels, pills | Wider apertures and rounded terminals hold up better when read from 1 m and at heavy weights; it is the face Apple uses for glanceable numbers (Fitness, Watch). Only at weights ≥ semibold. |
| **SF Mono** | Developer footer only | Aligned columns for fps / ω / °C / %. Never for user-facing text. |
| **New York** | *Not used.* | A serif has no job here. Deliberate omission, not an oversight. |

### Scale (text styles, so Dynamic Type just works)

| Token (`CKFont`) | Style | Design / weight | Notes |
|---|---|---|---|
| `hero` | 64 pt, scaled via `@ScaledMetric(relativeTo: .largeTitle)` | Rounded / heavy | Distance on Guide. Tabular digits. Caps at `.xxxLarge` so it never pushes buttons off-screen. |
| `tile` | `.title` (28 pt) | Rounded / bold | Metres in the depth grid. Tabular digits. |
| `instruction` | `.title2` (22 pt) | Text / semibold | Current instruction. Max 3 lines, `minimumScaleFactor 0.8`. |
| `button` | `.title3` (20 pt) | Rounded / semibold | Big button labels. |
| `label` | `.headline` (17 pt) | Text / semibold | Card titles, settings rows. |
| `body` | `.body` (17 pt) | Text / regular | Settings descriptions, route names. |
| `pill` | `.subheadline` (15 pt) | Rounded / bold, uppercase, +0.06 em tracking | Status pills. 1–2 words only. |
| `secondary` | `.subheadline` (15 pt) | Text / regular | Hints under controls. **Smallest user-facing size.** |
| `mono` | `.footnote` (13 pt) | Mono / regular | Developer footer only, `accessibilityHidden`. |

Rules:
- **Tabular numerals everywhere a number can change** (`.monospacedDigit()`): distance, metres, ETA, steps, battery. Proportional digits make "1.2 m → 1.1 m" jitter.
- Dynamic Type: all text uses styles; the app supports up to `.accessibility5` for lists and settings. The depth grid and the Guide hero clamp at `.xxxLarge` (`.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`) because six tiles must stay on one screen; at larger sizes the *number* is still ≥ 28 pt, which VoiceOver users don't see anyway.
- Big buttons: at accessibility sizes the icon and label stack vertically (`ViewThatFits`), the button grows, it never truncates.
- Line height: default. Never tighten. Never letter-space lowercase text.
- Units: `1.4 m`, `120 m`, `14 min`, `1,300 steps` — non-breaking space between number and unit, one decimal under 10 m, none above.

---

## 2. Colour tokens

Neutrals are tinted warm (toward the ivory of a cane), never pure grey. Values are sRGB hex,
chosen in OKLCH so each ladder step is a roughly even lightness jump. Three variants per token:
light, dark, and increased-contrast (`Settings → Accessibility → Increase Contrast`), resolved by
UIKit trait collections in `CKColor`.

### Surfaces and text

| Token | Light | Dark | Light HC | Dark HC | Use |
|---|---|---|---|---|---|
| `background` | `#F4F1EA` | `#0E0D0B` | `#FFFFFF` | `#000000` | Screen ground |
| `surface` | `#FFFFFF` | `#1A1816` | `#FFFFFF` | `#0A0A0A` | Cards |
| `surfaceRaised` | `#EAE6DD` | `#26231F` | `#E3DED3` | `#141210` | Secondary buttons, no-data tiles |
| `border` | `#C9C3B6` | `#3A362F` | `#000000` | `#FFFFFF` | 1 pt hairlines; 3 pt in HC |
| `textPrimary` | `#17140F` | `#F4F1EA` | `#000000` | `#FFFFFF` | ≥ 14:1 on background |
| `textSecondary` | `#5C574D` | `#B5AFA3` | `#3A362F` | `#D9D4C9` | ≥ 6.5:1; hints only |
| `accent` | `#17140F` | `#F4F1EA` | `#000000` | `#FFFFFF` | Primary button fill, focus, selected state. **Ink in light, ivory in dark.** |
| `onAccent` | `#F4F1EA` | `#0E0D0B` | `#FFFFFF` | `#000000` | Text on `accent` |
| `ink` | `#17140F` | `#17140F` | `#000000` | `#000000` | Text on every coloured fill (lanes, pills). One rule, no exceptions. |

### Lane ladder (same in light and dark; the fill is the signal, so it does not flip)

| Token | Distance | Normal | HC | Glyph | Ink contrast |
|---|---|---|---|---|---|
| `laneClear` | ≥ 2.0 m | `#4ADE80` | `#22D36B` | `checkmark` | 11.4:1 |
| `laneFar` | 1.2 – 2.0 m | `#FDE047` | `#FFD500` | `minus` | 15.2:1 |
| `laneNear` | 0.7 – 1.2 m | `#FB923C` | `#FF7A00` | `exclamationmark.triangle.fill` | 8.9:1 |
| `laneUrgent` | < 0.7 m | `#F87171` | `#FF6B6B` | `octagon.fill` | 7.1:1 |
| `laneNoData` | no depth | = `surfaceRaised` | — | `questionmark` | text in `textSecondary` |

Deuteranopia check: far and near are close in hue, which is why the glyph and the number are
mandatory on every tile. Lightness order is clear (0.85) > far (0.90) > near (0.75) > urgent
(0.68), so the two dangerous states are also the two darkest fills.

### Status

| Token | Normal | HC | Use |
|---|---|---|---|
| `trusted` | = `laneClear` | = HC clear | TRUSTED pill, "phone connected" |
| `warning` | `#FBBF24` | `#FFB000` | SWEEPING, HOT, LOW BATTERY, crossing banner |
| `danger` | = `laneUrgent` | = HC urgent | Stop button, CRITICAL thermal, engine failure |
| `neutral` | = `surfaceRaised` | — | Idle / paused pills, text in `textPrimary` |

### Appearance policy
- The app follows the system appearance. **For the demo, set the phone to Dark Mode** (dark room; the screen must not light the judges' faces) and run under Guided Access.
- In sunlight the light palette wins: ivory ground, ink text, the same lane fills.
- Accent never carries hazard meaning. Hazard is only ever the lane ladder.

---

## 3. Spacing and radius

4 pt base. Semantic names so layouts read as intent, not numbers.

| `CKSpacing` | pt | Use |
|---|---|---|
| `xs` | 4 | Icon-to-text inside a pill |
| `sm` | 8 | Between pills; grid tile gap |
| `md` | 12 | Inside cards between rows |
| `lg` | 16 | Card padding; between big buttons |
| `xl` | 24 | Between sections |
| `xxl` | 32 | Above the button stack on Guide |
| `gutter` | 20 | Screen edge |

| `CKRadius` | pt | Use |
|---|---|---|
| `tile` | 14 | Depth tiles |
| `button` | 18 | Big buttons (72 pt tall → radius = ¼ height, reads as a slab not a pill) |
| `card` | 20 | Cards |
| `pill` | 999 | Status pills |

Touch targets: big buttons 72 pt tall, full width or half width (≥ 170 pt). Settings rows 60 pt.
Tiles are not tappable (they are a display). Nothing interactive is smaller than 60 × 60 pt on the phone; 48 pt on the watch (HIG minimum is 44, the screen is 198 pt tall).

Elevation: none. No shadows — a card is a fill and a hairline. Depth is not a metaphor we need
when the screen is a gauge.

---

## 4. Motion

Motion never carries information. Reduce Motion (`accessibilityReduceMotion`) is honoured by
every rule below; the "reduced" column is what ships, the other is decoration.

| Event | Normal | Reduce Motion |
|---|---|---|
| Depth grid update (15 Hz) | **None.** Fill and number change instantly. | Same |
| Urgent tile | Opacity 1.0 → 0.7 at 2 Hz (`repeatForever`, `autoreverses`) plus a 4 pt `ink` border | Static, 4 pt border only |
| Status pill change | Cross-fade 150 ms | Instant |
| Distance on Guide | `.contentTransition(.numericText())` 200 ms | Instant |
| Big button press | Scale 0.97, 120 ms spring; `.sensoryFeedback(.impact(weight: .light))` | Opacity 0.85 only; haptic kept |
| Obstacle banner in / out | Slide from top 200 ms `easeOut` | Fade 100 ms |
| Arrival card | Sheet presentation (system) | System handles |
| Screen changes | System tab switch | System |

Never animate layout of the grid. Never animate colour of a lane tile (a fade through orange
lies about the distance for 150 ms).

---

## 5. Cue mapping: every cue → felt, heard, shown

Sources: `CueDecider` (obstacles, phone Taptic Engine), `NavCue` (turns, wrist), `BeaconEngine`
(bearing, AirPods). Speech is `AVSpeechSynthesizer` via `SpeechQueue` (priorities: **P0**
interrupts everything, **P1** queues, **P2** drops if anything is speaking).

| Cue | Felt (phone Taptic through the cane unless noted) | Heard (AirPods) | Shown (phone) | Shown (watch) |
|---|---|---|---|---|
| `clear` | Nothing (engine idle) | Nothing | Grid all `laneClear`; no banner | — |
| `centerApproach(d)` 2.0 → 0.5 m | Geiger loop: one transient (intensity 0.7 → 1.0 with proximity, sharpness 0.5) at 2 Hz @ 2 m → 8 Hz @ 0.5 m | Silent until ≤ 1.2 m, then **P1** "Ahead, one point two" (or class name: "Wall ahead, one metre"), re-spoken every 3 s while it closes | Torso-centre tile by distance; banner "AHEAD 1.2 m" in the tile's colour, `ink` text | — |
| `left` (torso-left < 1.2 m) | 2 transients, intensity 1.0, sharpness 0.8, 120 ms apart; repeats ≤ 1 Hz | **P1** "Left" at ≤ 0.8 m only | Torso-left tile; banner "LEFT 0.9 m" | — |
| `right` | 3 transients, same params | **P1** "Right" at ≤ 0.8 m | Torso-right tile; banner "RIGHT 0.9 m" | — |
| `head` (any head tile < 1.5 m) | Sharp double hit: 2 transients, intensity 1.0, sharpness 1.0, 60 ms apart; repeats ≤ 1 Hz | **P0** "Head height, left / ahead / right" | Head-row tile; full-width banner "HEAD" in `laneUrgent` with `octagon.fill` | If `fallbackToWatch`: `.click` ×2 |
| Sweeping (`isTrusted == false`) | Nothing (state frozen) | Nothing | Pill flips to SWEEPING (`warning`); tiles dim to 60 % and keep last value with a leading "~" | — |
| No depth | Nothing | **P1** once: "No depth. Check the camera." | All tiles `laneNoData` "?"; pill NO DEPTH (`danger`) | — |
| `turnLeft` | — | **P1** "In 15 metres, turn left onto Goodwin" | Instruction + `arrow.turn.up.left` | `.directionUp` ×2, 250 ms apart; glyph + text |
| `turnRight` | — | **P1** "…turn right…" | `arrow.turn.up.right` | `.directionUp` ×3 |
| `crossing` | — | **P0** "Goodwin Avenue. Crossing. Listen for traffic." Beacon pauses. | Banner "CROSSING" in `warning`, instruction "Tap Next when across" | `.stop` then `.notification`; text "CROSSING" |
| `arrived` | — | **P0** "CIF east entrance. 1.0 kilometres, 14 minutes, 1,300 steps." | Arrival card (sheet) | `.success` ×2; "Arrived" |
| Off-bearing > 25° | — | Beacon click pans toward the target; 1 Hz, louder as the error grows | Bearing chevron rotates; "Bear left" text under the distance | — |
| Describe (pressed) | `.sensoryFeedback(.impact)` on press | Earcon: two rising notes; then **P1** the description | Button shows "Describing…" (progress, `updatesFrequently`); result text in the instruction card | Button shows "Describing…" |
| Recenter (pressed) | `.success` | Single tick; **P2** "Recentred" | Toast pill "RECENTRED" 2 s | `.success` |
| Next (pressed) | `.success` | **P1** next instruction | Instruction changes | `.click` |
| Thermal `.serious` | — | **P1** "Phone hot. Door detection off." | Pill HOT (`warning`) | — |
| Thermal `.critical` | — | **P1** "Phone critical. Beacon off." | Pill CRITICAL (`danger`) | — |
| Battery < 20 % | — | **P1** once "Battery 20 percent" | Pill 19 % (`warning`) | — |
| Phone haptic engine failed | (watch takes over) | **P1** "Cues moved to the watch" | Pill WATCH (`warning`) | Mirrors obstacle counts via `.click` |
| Watch unreachable | — | Nothing (not safety-relevant) | Pill NO WATCH (`neutral`) | "Phone not connected" |

Sound policy: bone-conduction / open-ear only. No earcons for obstacles — the cane is the
obstacle channel, the ears stay on traffic. The only sounds are speech, the beacon, and the two
confirm earcons above. The phone speaker is never used except the "find my cane" chirp.

**VoiceOver rule.** The `SpeechQueue` is the app's voice. When VoiceOver is running the app does
*not* also post `AccessibilityNotification.Announcement` for cues (double-speak). Screen values
carry `accessibilityValue` and `.updatesFrequently` so a VoiceOver user who touches the screen
hears the current state; they are never *pushed* it twice.

---

## 6. Screens

Navigation: a 4-tab bar (iOS 26 system tab bar): **Guide · Depth · Route · Settings**. Tabs are
the first thing VoiceOver reaches after the screen title; each tab label is its screen name.
Default tab is Guide. Live Activity and the watch have no navigation.

Legend for the wireframes: `[ ]` button · `( )` pill · `┌┐` card · `#` filled tile.
Widths are for a 393 pt phone in portrait; the grid area is 353 pt wide.

### 6.1 Guide (Home)

```
┌─────────────────────────────────────────┐
│ CaneKit          (TRUSTED) (WATCH) (82%) │  ← status row, pills wrap
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ Turn left onto Goodwin Avenue       │ │  instruction, .title2 semibold
│ │                                     │ │
│ │        1 2 0  m                     │ │  hero 64 pt rounded heavy, tabular
│ │        ↖  bear left                 │ │  bearing chevron + word, .subheadline
│ └─────────────────────────────────────┘ │
│                                         │
│ ▌██ AHEAD 1.2 m ████████████████████▐  │  obstacle banner, only while a cue is active
│                                         │
│ [ ■ Stop route                        ] │  72 pt, danger while running; "Start route" primary when idle
│ [ ◉ Describe                          ] │  72 pt, secondary
│ [ ⟲ Recenter        ] [ ▶ Next        ] │  72 pt each, secondary
│                                         │
│ fps 15  ω 0.21  38°C nominal  82%  (dev)│  mono footer, hidden unless Settings › Developer
├─────────────────────────────────────────┤
│  Guide     Depth     Route     Settings │
└─────────────────────────────────────────┘
```

Thumb zone: Next and Describe are the two most-pressed controls, so they sit lowest. Start/Stop
is deliberately highest of the four: hard to hit by accident when reaching for Next.

| # | Control | VoiceOver label | Value | Hint | Traits |
|---|---|---|---|---|---|
| 1 | Screen title | "CaneKit, Guide" | — | — | `.isHeader` |
| 2 | Status pills (combined) | "Status" | "Trusted. Watch connected. Battery 82 percent." | — | `.updatesFrequently` |
| 3 | Instruction card (combined) | "Next instruction" | "Turn left onto Goodwin Avenue. 120 metres. Bear left." | — | `.updatesFrequently` |
| 4 | Obstacle banner | "Obstacle" | "Ahead, 1.2 metres" | — | `.updatesFrequently`; removed from tree when no cue |
| 5 | Start / Stop | "Start route" / "Stop route" | — | "Begins guidance along the selected route" / "Ends guidance and shows the arrival summary" | `.isButton` |
| 6 | Describe | "Describe surroundings" | "Describing…" while busy | "Takes a photo and speaks a one-sentence description" | `.isButton`; `.startsMediaSession` |
| 7 | Recenter | "Recentre beacon" | — | "Sets straight ahead as the beacon's forward direction" | `.isButton` |
| 8 | Next | "Next waypoint" | — | "Skips to the next instruction" | `.isButton` |
| 9 | Dev footer | *(hidden)* | — | — | `accessibilityHidden(true)` |
| 10 | Tab bar | system | | | |

Focus order is exactly 1 → 10, top to bottom. Nothing is `accessibilitySortPriority`-reordered.

### 6.2 Depth (debug grid)

```
┌─────────────────────────────────────────┐
│ Depth               (TRUSTED)  15 fps   │
│                                         │
│ ┌───────────┬───────────┬───────────┐   │
│ │  ✓        │  ⚠        │  ✓        │   │  head row
│ │  3.1      │  1.0      │  2.6      │   │  metres, 28 pt rounded bold, ink on fill
│ │  head L   │  head C   │  head R   │   │  .caption label, ink 70 %
│ ├───────────┼───────────┼───────────┤   │
│ │  ─        │  ⬣        │  ✓        │   │  torso row
│ │  1.6      │  0.5      │  2.2      │   │  urgent tile: 4 pt ink border, pulses
│ │  torso L  │  torso C  │  torso R  │   │
│ └───────────┴───────────┴───────────┘   │
│                                         │
│ Centre: door · 0.5 m                    │  mesh hit, .headline; "—" when none
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ ω 0.21 rad/s   gate 0.60            │ │  developer panel, mono, always shown here
│ │ thermal nominal · 38 °C             │ │
│ │ battery 82 % · 2 h 10 m left        │ │
│ │ cue center 0.5 m · last 0.4 s       │ │
│ └─────────────────────────────────────┘ │
│ [ ⇄ Mirror L/R ]   [ ⤓ Export log     ] │  60 pt, secondary
├─────────────────────────────────────────┤
│  Guide     Depth     Route     Settings │
└─────────────────────────────────────────┘
```

Tiles: 3 × 2, gap 8, radius 14, each ~112 × 112 pt at 393 pt width. Each tile = fill (`laneX`) +
glyph (top-left, 22 pt) + metres (centre, tabular) + position label (bottom, `ink` at 70 %).
"∞" is shown as "clear" text, not the symbol. Sweeping: tiles at 60 % opacity, metres prefixed "~".

| Control | Label | Value | Hint | Traits |
|---|---|---|---|---|
| Title | "Depth" | — | — | `.isHeader` |
| Trusted pill | "Depth status" | "Trusted" / "Sweeping, cues paused" / "No depth" | — | `.updatesFrequently` |
| Grid (one element) | "Depth grid" | "Head: left 3.1 metres clear, centre 1.0 near, right 2.6 clear. Torso: left 1.6 far, centre 0.5 urgent, right 2.2 clear." | — | `.updatesFrequently`. Six tiles are one VoiceOver element on purpose: reading six cells is slower than one sentence. |
| Mesh line | "Centre object" | "Door, 0.5 metres" / "None" | — | `.updatesFrequently` |
| Dev panel | *(hidden)* | | | `accessibilityHidden(true)` |
| Mirror L/R | "Mirror left and right" | "On" / "Off" | "Swaps the left and right lanes if the mount faces the other way" | `.isButton`, `.isToggle` semantics via value |
| Export log | "Export trip log" | — | "Shares the JSON log file" | `.isButton` |

### 6.3 Route picker

```
┌─────────────────────────────────────────┐
│ Route                                   │
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ ● Recorded route         RECOMMENDED│ │  selected: 3 pt accent border + checkmark
│ │ ISR front desk → CIF east entrance  │ │
│ │ 1.0 km · 11 waypoints · 5 crossings │ │  tabular
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ ○ Any destination                   │ │
│ │ Walking directions from Maps        │ │
│ │ [ 🔍 Search destination            ] │ │  60 pt, opens system search sheet
│ └─────────────────────────────────────┘ │
│                                         │
│ [ ▶ Use this route                    ] │  72 pt primary; returns to Guide
├─────────────────────────────────────────┤
│  Guide     Depth     Route     Settings │
└─────────────────────────────────────────┘
```

| Control | Label | Value | Hint | Traits |
|---|---|---|---|---|
| Recorded route card | "Recorded route, ISR front desk to CIF east entrance" | "Selected" / "" | "1.0 kilometres, 11 waypoints, 5 crossings. Double-tap to select." | `.isButton`, `.isSelected` when chosen |
| Any destination card | "Any destination, walking directions from Maps" | "Selected" / "" | "Double-tap to select, then search for a place" | `.isButton`, `.isSelected` |
| Search | "Search destination" | current destination name or "None" | "Opens a search for a place to walk to" | `.isButton`, `.isSearchField` |
| Use this route | "Use this route" | — | "Returns to Guide with this route ready to start" | `.isButton` |

### 6.4 Arrival card (sheet over Guide)

```
┌─────────────────────────────────────────┐
│                                         │
│              ✓  (64 pt, laneClear)      │
│            Arrived                      │  .largeTitle rounded heavy
│        CIF east entrance                │  .title2
│                                         │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│   │  1.0    │ │  14     │ │ 1,300   │   │  hero-ish 40 pt rounded heavy, tabular
│   │  km     │ │  min    │ │ steps   │   │  .subheadline
│   └─────────┘ └─────────┘ └─────────┘   │
│                                         │
│ [ ◉ Describe where I am               ] │  72 pt secondary
│ [ ✓ Done                              ] │  72 pt primary
└─────────────────────────────────────────┘
```

| Control | Label | Value | Hint | Traits |
|---|---|---|---|---|
| Header (combined) | "Arrived at CIF east entrance" | — | — | `.isHeader` |
| Stats (combined) | "Trip summary" | "1.0 kilometres, 14 minutes, 1,300 steps" | — | `.isStaticText` |
| Describe | "Describe where I am" | — | "Speaks a one-sentence description of the surroundings" | `.isButton` |
| Done | "Done" | — | "Closes the summary and ends the route" | `.isButton` |

The sheet is `.interactiveDismissDisabled(false)`; VoiceOver's escape gesture (two-finger Z) also
dismisses. Presented as a `.presentationDetents([.large])` sheet so the Guide stays underneath.

### 6.5 Settings

```
┌─────────────────────────────────────────┐
│ Settings                                │
│                                         │
│ MOUNTING                                │
│ ┌─────────────────────────────────────┐ │
│ │ Phone held upright            [on ] │ │  60 pt rows, .headline label
│ │ Camera at the top of the clamp      │ │  .subheadline secondary
│ ├─────────────────────────────────────┤ │
│ │ Mirror left and right         [off] │ │
│ │ If left obstacles buzz on the right │ │
│ └─────────────────────────────────────┘ │
│ CUES                                    │
│ ┌─────────────────────────────────────┐ │
│ │ Silence phone haptics         [off] │ │
│ │ Speech and watch keep working       │ │
│ ├─────────────────────────────────────┤ │
│ │ Mirror cues to watch          [off] │ │
│ │ Always, not only if the phone fails │ │
│ └─────────────────────────────────────┘ │
│ SCENE DESCRIPTION                       │
│ ┌─────────────────────────────────────┐ │
│ │ Provider              Anthropic  ›  │ │  picker: Custom / Anthropic / Gemini / OpenAI
│ │ Key present ✓                       │ │  or "No key: describe will say so"
│ └─────────────────────────────────────┘ │
│ DEVELOPER                               │
│ ┌─────────────────────────────────────┐ │
│ │ Show debug footer on Guide    [off] │ │
│ │ Export trip log                  ›  │ │
│ └─────────────────────────────────────┘ │
├─────────────────────────────────────────┤
│  Guide     Depth     Route     Settings │
└─────────────────────────────────────────┘
```

Toggles are system `Toggle`s (VoiceOver announces "switch button, on/off" for free). The row's
label + description are the toggle's label so the whole 60 pt row is the hit target.

| Control | Label | Hint |
|---|---|---|
| Phone held upright | "Phone held upright" | "On when the camera is at the top of the clamp. Off if the phone is sideways." |
| Mirror left and right | "Mirror left and right" | "Turn on if obstacles on your left buzz as right" |
| Silence phone haptics | "Silence phone haptics" | "Stops the cane vibrating. Speech and the watch keep working." |
| Mirror cues to watch | "Mirror cues to watch" | "Sends every obstacle cue to the watch as well as the cane" |
| Provider | "Scene description provider" (value: current) | "Chooses which service describes a photo" |
| Show debug footer | "Show debug footer on Guide" | "Shows frame rate, motion, thermal state and battery under the buttons" |
| Export trip log | "Export trip log" | "Shares the JSON log file" |

Section headers carry `.isHeader` so VoiceOver's rotor can jump between groups.

### 6.6 Watch face (45 mm, 198 × 242 pt)

Two horizontally paged screens (`TabView(.page)`). Page 1 is the default and owns the crown.

```
Page 1 — status                       Page 2 — actions
┌──────────────────────┐              ┌──────────────────────┐
│ CaneKit   (TRUSTED)  │              │ [ ▶ Next            ]│  48 pt, ivory fill, ink text
│                      │              │                      │
│ Turn left onto       │  .title3     │ [ ◉ Describe        ]│  48 pt, raised fill
│ Goodwin Avenue       │  semibold    │                      │
│                      │              │ [ ⟲ Recenter        ]│  48 pt, raised fill
│   1 2 0 m            │  .title rounded heavy, tabular
│                      │              │                      │
│ ⟳ crown: next        │  .footnote   │ ● phone connected    │  .footnote
└──────────────────────┘              └──────────────────────┘
```

Crown: `.digitalCrownRotation` on page 1; ≥ 3 detents in either direction within 1 s = Next
(matches the verified deviation in `ios/README.md` §2). The hint line disappears while a route is
not running. The watch is always black-background (OLED, wrist-down power).

| Control | Label | Value | Hint | Traits |
|---|---|---|---|---|
| Page 1 (combined) | "Guide" | "Turn left onto Goodwin Avenue. 120 metres. Trusted." | "Turn the crown to skip to the next instruction. Swipe left for buttons." | `.updatesFrequently`, `.isHeader` |
| Next | "Next waypoint" | — | "Skips to the next instruction" | `.isButton` |
| Describe | "Describe surroundings" | "Describing…" while busy | "Asks the phone to describe what is ahead" | `.isButton` |
| Recenter | "Recentre beacon" | — | "Sets straight ahead as the beacon's forward direction" | `.isButton` |
| Connection | "Phone connection" | "Connected" / "Not connected" | — | `.updatesFrequently` |

Wrist haptics are specified in §5. The watch never shows the depth grid: at 198 pt wide the tiles
would be 60 pt and the numbers 20 pt, below the arm's-length floor.

### 6.7 Live Activity / Dynamic Island

```
Compact (island, both sides)        Minimal (island, one side)
┌───────( ↰ )───────( 120 m )──┐    ┌──( ↰ )──┐
                                     turn glyph only

Expanded (island, long press / lock screen)
┌────────────────────────────────────────────────┐
│  ↰            Turn left onto Goodwin      120 m │  glyph 28 pt; instruction .headline; distance .title rounded heavy tabular
│  (TRUSTED)    ISR → CIF · 14 min left · 820 steps│  pill + .subheadline secondary, tabular
└────────────────────────────────────────────────┘
```

- Compact leading: the turn glyph (`arrow.turn.up.left` / `.right` / `figure.walk` for straight / `flag.checkered` for arrived). Compact trailing: distance, tabular, `.headline` rounded.
- Minimal: glyph only. Never the distance (too small to read, too fast to change).
- Colour: glyph and distance in the system's island foreground (white); the pill uses `trusted` / `warning` fills with `ink` text — the only colour in the island, so it reads as status not decoration.
- Update rate: at most once per 5 m or 15 s, whichever first (ActivityKit budget). The island is a summary, not a gauge.
- Tapping opens the app to Guide. No interactive buttons in the island: "Next" from the lock screen is too easy to hit by accident with the phone on a cane.
- VoiceOver: the expanded view is one element, label "CaneKit route", value "Turn left onto Goodwin, 120 metres. Trusted. 14 minutes left, 820 steps."

---

## 7. Do not

- No colour-only meaning. Every lane state has a glyph and a number; every pill has a word.
- No text under 15 pt for the user; 13 pt mono is allowed only in developer panels that are `accessibilityHidden`.
- No gradient text, no gradient fills, no glass over content that must be read. iOS 26 Liquid Glass stays where the system puts it (tab bar, sheets); our cards and tiles are flat.
- No pure grey neutrals and no `#000000` / `#FFFFFF` outside increased-contrast mode.
- No side-stripe borders on cards or banners. A banner is a full fill.
- No animation on the depth grid. No colour cross-fades on lane tiles.
- No shadows. Elevation is a fill change and a hairline.
- No icon-only buttons. Every button has a visible word; the SF Symbol is a companion.
- No custom fonts. SF Pro / SF Rounded / SF Mono only.
- No haptics for decoration. The Taptic Engine is a safety channel; a press confirm is the only non-cue haptic.
- No sounds through the phone speaker (except the "find my cane" chirp). No earcons for obstacles.
- No interactive controls under 60 pt on the phone, 48 pt on the watch.
- No double-speak: cue speech comes from `SpeechQueue`, never also from a VoiceOver announcement.
- No truncation of an instruction. Wrap to 3 lines, then scale to 0.8, never "…".
- No `accessibilitySortPriority`. The visual order is the focus order; if that's wrong, fix the layout.
- No light-on-dark hero in a dark room brighter than the tokens allow: the ivory is `#F4F1EA`, not white, on purpose.

---

## 8. Implementation notes for the Swift twin

- `CKColor.*` are `Color(uiColor:)` dynamic providers that read `userInterfaceStyle` and `accessibilityContrast` from the trait collection. Nothing else in the app should construct a `Color` literal.
- Hero distance: `@ScaledMetric(relativeTo: .largeTitle) private var hero = 64` then `.font(CKFont.hero(hero))`; wrap the card in `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`.
- Border width: `CKMetrics.border(for: colorSchemeContrast)` returns 1 or 3.
- `CKBigButton(title:systemImage:role:hint:action:)` is the only button on Guide, Route and Arrival. Settings uses system `Toggle` / `Picker` in 60 pt rows.
- `CKStatusPill(text:tone:systemImage:spoken:)` is the only pill. `spoken` is the VoiceOver value when the visible text is too terse ("82%" → "Battery 82 percent").
- `CKCard(title:) { }` groups children as one VoiceOver container with the title as its label.
- Watch: `WKBigButton`, `WKFont`, `WKColor` in `WatchTheme.swift`; watch is always dark.
- Demo checklist: Dark Mode on, Increase Contrast off (the normal ladder is calibrated), Bold Text off, Guided Access on, brightness 60 % in the dark room / 100 % outdoors, Reduce Motion irrelevant (nothing meaningful moves).
