# Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)

Waypoint file: [`ios/CaneKit/Resources/route_isr_cif.json`](../ios/CaneKit/Resources/route_isr_cif.json)
(route `name` "ISR Townsend Hall to CIF", `recorded` 2026-09-11). The JSON is authoritative; this page
explains it and keeps the evidence. The tables below were regenerated from the JSON on 2026-09-11.

Coordinates pulled 2026-09-10 from OpenStreetMap; start point re-checked 2026-09-11 against the
University Housing ISR site plan and floor plans after the start was fixed as **Townsend Hall**. Step 10
(2026-09-11) then changed the file: WP3 became a turn (`crossing: false`), WP3 / WP6 / WP8 got 12 m
fences, WP1 got `curved: true`, every waypoint got a short `name`, and WP6 says "Turn left to face west"
before the crossing. **Not yet walked or GPS-verified**: see "To re-record on the Friday walk" below.

Path: Townsend Hall, out through the ISR front doors (south vestibule of the 2020 lounge building, at
Townsend's south-west corner) -> south under the canopy, west along the plaza path and down to the
W Illinois St north sidewalk -> west to S Goodwin Ave -> right, north on the east sidewalk of Goodwin
(crossing W Green St) -> left, cross Goodwin at Springfield Ave -> west on the south sidewalk of
Springfield (crossing S Mathews Ave) -> left at the CIF east-side path -> CIF east entrance.

## Waypoints (from the JSON)

| id | `name` (spoken place name) | lat, lon | `radius_m` | `crossing` | `curved` | `bearing_next_deg` | to next (m) | `say` (spoken on fence entry) |
|---|---|---|---|---|---|---|---|---|
| 1 | the Townsend Hall doors | 40.10949, -88.22135 | 15 | no | **yes** | 225.6 | 57.2 (walked ≈ 81) | Leaving Townsend Hall through the ISR front doors. Follow the covered walk south, then the path west and down to the Illinois Street sidewalk. |
| 2 | the Illinois Street sidewalk | 40.10913, -88.22183 | 15 | no | no | 266.7 | 176.3 | Illinois Street sidewalk. Turn right and walk west. Goodwin Avenue is about 175 meters ahead. |
| 3 | Goodwin Avenue | 40.10904, -88.22390 | **12** (turn) | **no** | no | 358.5 | 162.4 | Goodwin Avenue. Intersection. Turn right to face north and stay on this side. No crossing needed. Listen for traffic. |
| 4 | Green Street | 40.11050, -88.22395 | 15 | **yes** | no | 359.6 | 125.7 | Green Street. Crossing. Signalized, push button. Listen for traffic, then cross and continue north. |
| 5 | the middle of Goodwin | 40.11163, -88.22396 | 15 | no | no | 359.6 | 126.8 | Halfway up Goodwin. Keep going north. Springfield Avenue is about 125 meters ahead. |
| 6 | Springfield Avenue | 40.11277, -88.22397 | **12** (turn) | **yes** | no | 270.0 | 141.2 | Springfield Avenue. Turn left to face west. Crossing Goodwin, signalized, push button. Listen for traffic, then cross and keep walking west. |
| 7 | Mathews Avenue | 40.11277, -88.22563 | 15 | **yes** | no | 265.0 | 152.0 | Mathews Avenue. Crossing. Listen for traffic, then cross and continue west. CIF is about 150 meters ahead. |
| 8 | the path to CIF | 40.11265, -88.22741 | **12** (turn) | no | no | 237.4 | 47.5 (L-shaped path) | CIF is ahead on your left. Turn left and follow the path south-west to the east entrance. |
| 9 | the CIF east entrance | 40.11242, -88.22788 | **20** (arrival) | no | no | — (absent) | — | You have arrived at the Campus Instructional Facility, east entrance. |

**Total route length: 988.9 m** (sum of great-circle segment lengths between consecutive waypoints; the
real walked distance is longer because WP1->WP2 and WP8->WP9 follow L/S-shaped paths, not the chord).
Every recorded `bearing_next_deg` equals the geometric bearing to the next waypoint to 0.1°.

Distances use the haversine formula and bearings the initial forward azimuth (degrees true), the same
maths as `CaneKitLogic.GeoMath` (R = 6 371 000 m; the earlier 6 371 008.8 m changes nothing at 0.1 m).

Where the `name` is used: "Passed <name>. <Next name> in N meters." (passed-by), "Next, <name>, in N
meters." (appended by Repeat). The Guide instruction, the watch and the Live Activity show the `say` of the
*upcoming* waypoint.
The route intro at Start is "Route started. ISR Townsend Hall to CIF. First: <WP1 say>".

## What the app does at each waypoint

Derived from `NavigationEngine.reached`, `GeofenceTracker`, `TurnSettle` and the watch haptic map
(`WatchModel`). "Turn cue" = the wrist tap sent when `bearing_next_deg` changes by more than 30°
from the previous leg (right = `.directionDown`, left = `.directionUp`); a crossing sends
`.notification` instead; arrival sends `.success`.

| id | Wrist cue | While the turn settles (fence entered before the corner) | Near-waypoint zone (2 × r: veer muted, leg bearing used) |
|---|---|---|---|
| 1 | none (no previous leg) | leg to WP2 is `curved`: beacon silent and no veer for the whole leg | 30 m (veer muted; no previous leg, so the live bearing) |
| 2 | turn right (+41°, from the WP1 chord 225.6° to 266.7°) | beacon holds **225.6°** (the curved leg's chord) until you turn west | 30 m |
| 3 | turn right (+92°) | beacon holds west (266.7°); not a crossing, so it is not silenced | 24 m |
| 4 | crossing | beacon **silent** ("Listen for traffic") until you stop at the curb or turn | 30 m |
| 5 | none (0°) | releases on the first heading update (you already face north) | 30 m |
| 6 | crossing (beats the left turn) | beacon silent until the curb / turn | 24 m |
| 7 | crossing (-5°) | beacon silent until the curb / turn | 30 m |
| 8 | **none**: -27.6° is under the 30° threshold, so "Turn left" is spoken only | beacon holds 265.0° until you turn | 24 m |
| 9 | arrived | arrival: beacon and head tracking stop, Live Activity ends, trip summary spoken after the WP9 line | 40 m: leg bearing 237.4° used, but veer is **not** muted near the last waypoint |

## Why the file looks the way it does

**Fences.** An intermediate fence fires on the first fix that is inside `radius_m`, with horizontal
accuracy ≤ 20 m and speed > 0.5 m/s (standing still near a fence never fires it). "GPS weak. Waypoint
cues paused until it recovers." is spoken after 10 s of accuracy worse than 20 m, the same threshold.
Every fix is also tested against the next two waypoints (skip-ahead: "Passed one waypoint." then the
real line), and a waypoint you walk past without entering counts once you came within 2 × r and then
receded by a full radius over three fixes (passed-by: "Passed Goodwin Avenue. Green Street in 150
meters." — never the passed waypoint's own "turn right" line, which would be wrong by then).

**Turn fences are 12 m (WP3, WP6, WP8).** A fence fires up to `radius_m` *before* the corner, so the
instruction for a turn is spoken early. 12 m instead of 15 m makes it fire closer to the corner. After it
fires, `TurnSettle` keeps the previous leg's bearing on the beacon and mutes "Veer" cues until the turn is
actually made: within 6 m of the waypoint on a good moving fix (+4 s grace), or receding max(6 m, r/2)
past the closest approach on two consecutive good moving fixes (+4 s), or the gyro-gated body heading
within 30° of the new leg, or 25 s of *moving* time (never a plain timer, never a standing fix). The
test `shippedRouteFileIsConsistent` pins 12 m on exactly 3, 6 and 8; non-turn fences are 15 m for GPS
tolerance.

**The first leg is curved (WP1 `curved: true`).** From the canopy the mapped walk goes south 16 m, west
41 m, then south 18 m to the sidewalk: an S-shape whose chord (225.6°) is a diagonal across the plaza, not
a walkable heading. `curved` means the leg *after* this waypoint is not straight: no veer cues, the beacon
is silent and the bearing pill disappears, and the spoken WP1 line does the guiding. It is the only curved
leg (the test pins `curved == [1]`).

**WP3 is a turn, not a crossing.** The route stays on the east side of Goodwin, so nobody crosses a street
at Illinois / Goodwin: `crossing: false`, the wrist gets a right-turn tap (not the crossing pattern), and
the beacon holds the west bearing through the turn instead of going silent. The line still says "Listen
for traffic" (turning cars) and "No crossing needed"; the test requires any non-crossing line that mentions
"cross" to say "no crossing". The crossings are exactly WP4, WP6, WP7 (pinned by the test). At a crossing
the beacon stays silent while the turn settles, two consecutive stationary good fixes within 10 m of the
waypoint (you stopped at the curb) release it at once, and auto-recenter of the AirPods is blocked within
15 m after it.

**Arrival is 20 m with a two-hit rule (WP9).** Arrival is irreversible (it stops the beacon, head tracking
and the Live Activity), so it is gated differently from the other fences: there is no speed gate (people
stop at the door), a fix counts only if its accuracy is ≤ 30 m **and** `distance + accuracy / 2 ≤ 20 m`, and
it needs **two consecutive** such fixes. A fix too poor to judge (> 30 m) neither counts nor resets the
streak; a judged fix outside the fence resets it. In practice: at ±10 m accuracy you must be within 15 m
of the door, at ±20 m within 10 m, at ±30 m within 5 m. One 30 m blob 45 m short of CIF cannot end the
route. The WP9 line is spoken, then the trip summary ("You have arrived at the Campus Instructional
Facility, east entrance. 1.0 kilometers, 14 minutes, 1300 steps."), which Repeat also includes.

## Where Townsend Hall is, and which door is "the Townsend exit"

- ISR (1010 W Illinois St) is three joined buildings: **Townsend Hall = the east building** (OSM way 899305028, `addr:housenumber=918`, `building:levels=5`, footprint 40.10950–40.11019 N, -88.22127 to -88.22058 W, a C-shape opening east toward Lincoln Ave), **Wardall Hall = the west tower** (OSM way 899305030, 1012 W Illinois, 12 levels, footprint 40.10940–40.10958 N, -88.22199 to -88.22152 W), and the 2020 **lounge / Food Service Building** between them (OSM way 899305029, 1010 W Illinois). The University Housing site plan labels them the same way (Townsend Hall right/east, Wardall Hall bottom-left, "Lounge Building" and "Food Service Building" between) and the ISR page says Townsend has 5 floors and Wardall 12, matching the OSM levels.
- Townsend has **no separately mapped street entrance in OSM** and no door of its own onto W Illinois St. Its ground-floor south corridor runs straight into the ISR lobby, whose only south-facing public door is the canopied vestibule that projects toward Illinois St at Townsend's south-west corner (visible on the 1st-floor plan as the bump-out at the bottom centre, and on the site plan as the canopy between Wardall and Townsend). In OSM that door is `entrance=yes` node 5418851678 at 40.10949, -88.22135 with canopy roof way 1446788061 and covered footway 562059275 leading south from it; the node sits on the shared boundary of the lounge building and is 13.6 m from Townsend's south-west corner node (8355939352, 40.10950 -88.22120).
- So WP1 stays at that node; it is both the ISR front-desk door and the door a Townsend resident exits by. The other Townsend doors on the plans (an exit-stair door on the north-west basement side, a courtyard door on the east face) open away from Illinois St and are not on any mapped footway, so they were not used.
- The plaza exit (WP2) is unchanged: from the canopy the mapped walk goes south 16 m to the east-west plaza path (way 562059272), west 41 m to the connector (way 562059273), then south 18 m to the Illinois St sidewalk junction node 5418851673. Total walked distance WP1->WP2 is about 81 m; the eastern connector (way 562059276, down to 40.10914 -88.22086) is the same length but heads away from Goodwin, so the western one is kept.

## Evidence per waypoint (OSM)

| id | source / OSM reference | status |
|---|---|---|
| 1 | Townsend Hall exit = ISR front doors: OSM node 5418851678 (`entrance=yes`) on the south vestibule of the lounge building at Townsend's SW corner, canopy roof way 1446788061; matches Housing site plan / 1st-floor plan | to re-record Friday |
| 2 | OSM node 5418851673, junction of Illinois St north sidewalk (way 562059268) and plaza connector (way 562059273); walked path from WP1 is canopy walk (562059275) -> 1446788077 -> plaza path 562059272 west -> 562059273 south | to re-record Friday |
| 3 | OSM node 37972349, W Illinois St x S Goodwin Ave street intersection (street centre, not the corner) | verified (OSM); corner to re-record |
| 4 | OSM node 5727977710, `highway=crossing`, signalized, push-button, tactile paving | verified (OSM) |
| 5 | Interpolated mid-block point on Goodwin (WP4-WP6 is 252 m) | interpolated |
| 6 | OSM node 37975504, `highway=traffic_signals`, Springfield Ave x S Goodwin Ave (street centre) | verified (OSM); corner to re-record |
| 7 | OSM node 38077757, Springfield Ave x S Mathews Ave street intersection (street centre) | verified (OSM); corner to re-record |
| 8 | Springfield south-sidewalk node (ways 207579081 / 1504277421 junction), where the path to CIF's east side leaves | to re-record Friday |
| 9 | OSM node 13269443017 (`entrance=yes`) on CIF building way 886109954, east face | to re-record Friday |

## Indoor draft (Step 62)

File: [`ios/CaneKit/Resources/indoor_isr.json`](../ios/CaneKit/Resources/indoor_isr.json) (id
`isr_townsend_to_front_doors`, `walked: false`, `recordedAt` / `strideM` null). It is a **floor-plan
draft, not a recording**: the app says "Draft route. Use your cane." before step 1. Every
line comes from the University Housing **ISR Floor Plans PDF, page 2 "Illinois Street Residence Hall - 1st
Floor"** (Nov 2025; downloaded and rendered 2026-09-13; the PDF has no text layer, so labels were read off
the drawing). The plan has no scale bar. Its scale was calibrated against OSM at about 0.055 m per 300-dpi
pixel. Two checks agree: Townsend's south wing depth (plan 11.2 m, OSM way 899305028 east end 11.4 m) and
Townsend's south-west corner to the vestibule centre (plan 13.75 m, OSM corner node 8355939352 to entrance
node 5418851678 13.6 m). Step counts are plan distance ÷ 0.7 m, rounded; expect ±15 %.

| # | `say` / `landmark` | Source on the 1st-floor plan | Distance |
|---|---|---|---|
| 1 | Start in the Townsend south corridor, face west, "say next" at the end (`steps` null) | Townsend south wing "CORRIDOR C182", running west from "LOUNGE 160" at its east end | full corridor ≈ 46 m, but the start point (the owner's lab) is unknown, so no count |
| 2 | Elevator right, stairs left; west through the connector ≈ 14 steps; "Expect a door." | At the corridor's west end: "LOBBY L183 / ELEV E183" to the north and "STAIR 3 S183" to the south; then "SOUTH CONNECTOR C1007" with a door swing at the Townsend / lounge-building wall | ≈ 10 m |
| 3 | Entering the south lobby, west ≈ 11 steps; landmark "The main desk is on your right." | "C1005 SOUTH CORRIDOR" opens into "C1000 SOUTH LOBBY"; "1002A MAIN DESK" is on the lobby's north side | ≈ 7.8 m |
| 4 | Turn left to face south, ≈ 15 steps to the vestibule doors (`turn: left`) | "V1000 SOUTH ENTRY VESTIBULE" is due south of the lobby centre (plan north is up: site plan has Illinois St at the bottom) | ≈ 10.5 m |
| 5 | Through the inner doors, outer doors ≈ 7 steps | Door leaves drawn on both the inner and outer line of V1000 | ≈ 4.6 m |
| exit | "You are at the ISR front doors…", WP1 40.10949, -88.22135, `radiusM` 25 | OSM `entrance=yes` node 5418851678 on the vestibule's south face (= route WP1) | — |

Not used, because no source supports it: front-desk hours (the Housing ISR page fetched 2026-09-13 gives
6 a.m.–3 a.m. in term and 10 a.m.–10 p.m. on breaks, **not** 24 hours), tactile or floor-surface cues,
whether doors are automatic, push or card-access, the canopy (OSM only, not drawn on the plan), and any
room or lab name along the corridor. OSM has no `indoor=*`, `door=*` or `level` data for ISR. Its only
`entrance` nodes near ISR are 5418851678 (the south doors) and two on the food service building's north side.

**What a teammate must verify and record on site** (Settings → "Record indoor route", sighted walker,
phone held the way the demo walker holds it):
1. **Start from the real origin** (the owner's lab or room) instead of a generic corridor point. The recorder
   names the file `recorded_<date>`, so give it id `isr_townsend_to_front_doors` (or keep the id in mind:
   the recorded file only replaces this draft when the ids match).
2. **Floor.** Confirm that the 1st floor on the plan is the level you walk out on, that the connector is
   step-free, and whether the lab is on another floor (then the elevator L183 becomes a step).
3. **Doors.** Is there a door between Townsend's corridor and connector C1007, does it need a card or a
   push, and are the vestibule doors automatic? Replace "Expect a door." with what is really there.
4. **The turn.** Confirm that the walker turns left once, in the lobby, and not in two steps (for example
   around the lobby columns). The recorder detects turns of 60° or more held for 1.5 s.
5. **The main desk.** Confirm it is on the right when walking west, and speak it with "Add landmark" when it
   is beside you. Check whether it is staffed at demo time (6 a.m.–3 a.m. per Housing).
6. **Step counts and stride.** The recording replaces every count. If you can, pace a known distance to set
   `strideM`.
7. **Exit.** Use "Finish at the exit" standing outside the outer vestibule doors, under the canopy, so the
   exit coordinate is averaged from fixes. Check that a ≤ 15 m fix is available there (12-storey Wardall is
   next door). If the averaged point differs from WP1 by more than about 10 m, re-record WP1 too.
8. When the recorded file replaces this one, set `walked: true` and fill in `recordedAt`, then update this
   table.

## Sources

- Nominatim (`https://nominatim.openstreetmap.org/search`) — located "Illinois Street Residence Halls" (landuse way 899305031, bus stop node 5425410082), "Townsend Hall, 918 West Illinois Street" (building way 899305028, polygon bbox 40.1095012–40.1101866 N, -88.2212685 to -88.2205780 W; queried 2026-09-11) and "Campus Instructional Facility, 1405 Springfield Avenue" (building way 886109954, bbox 40.11230-40.11262 N, -88.22872 to -88.22783 W).
- Overpass API (`https://overpass-api.de/api/interpreter`) — street-intersection nodes (shared nodes between the named highway ways), `entrance=*` nodes, sidewalk and footway geometry around both buildings; re-queried 2026-09-11 for the ISR block (buildings 899305028/029/030, all `entrance` nodes, all footways). The only `entrance` node on the Illinois St side of ISR is 5418851678.
- University Housing Facilities, ISR building information (`https://mail.hsgintranet2024.web.illinois.edu/facilities-building-information-isr-hall`) with its linked **ISR Site Plan** and **ISR Floor Plans** PDFs (`.../sites/default/files/2025-11/Floor%20Plans%20ISR%20Site%20Plan.pdf`, `.../Floor%20Plans%20ISR.pdf`, Nov 2025) — used to identify Townsend as the east building and the lobby vestibule at its SW corner as the Illinois-St-side door. Housing also lists Townsend as 908/918 W Illinois St (the two pages disagree on the number; OSM uses 918).
- University Housing ISR page (`https://www.housing.illinois.edu/living-communities/halls/isr`) — Townsend 5 floors, Wardall 12 floors, single front desk for both halls (re-fetched 2026-09-13: open 6 a.m.–3 a.m. in term, 10 a.m.–10 p.m. on breaks — not 24 hours). The ISR Floor Plans PDF page 2 (1st floor) labels "1002A MAIN DESK", "C1000 SOUTH LOBBY", "C1005 SOUTH CORRIDOR", "C1007 SOUTH CONNECTOR", "V1000 SOUTH ENTRY VESTIBULE" and Townsend "CORRIDOR C182" — the basis of `indoor_isr.json`.
- Data (c) OpenStreetMap contributors, ODbL 1.0.

Note: in OSM, Springfield Ave through campus is named "Springfield Avenue" (no "West"), which is why the strict "West Springfield Avenue" match failed on the first query.

## To re-record on the Friday walk

**How.** Walk the route with the app: Start route to CIF, "Write trip log" on (Mount card, default on),
AirPods in, watch app open. At each real position (the door, the corner you actually stand on, the path
junction) stand still for 10–15 s. The JSONL log in the app's Documents folder (Files app / AirDrop) has
`gps` lines (`lat`, `lon`, `acc`, `speed`), `waypoint` lines (where each fence actually fired), `speech`
lines (what was said) and `navcue` lines (wrist taps). Average the standing fixes with `acc` ≤ 10 m.
Then edit the JSON: `lat` / `lon`, and `bearing_next_deg` = the geometric bearing to the next waypoint
(the test allows 15°); keep ids, names, crossings `[4, 6, 7]`, `curved` `[1]` and 12 m on 3 / 6 / 8 unless
you also change `shippedRouteFileIsConsistent` in `ios/Logic/Tests/CaneKitLogicTests/RouteTests.swift`
(it also wants 20–300 m between waypoints, 700–1300 m in total, a `name` ≤ 30 characters on every
waypoint, and "Goodwin Avenue" as WP3's place name). Run `cd ios && make test`, then update both tables
above and the route section of `docs/CODE_REFERENCE.md`.

1. **WP1, Townsend Hall exit.** The OSM `entrance=yes` node (no `entrance=main` tag) and the Housing plans agree on one canopied south door at Townsend's SW corner, and the 1st-floor plan shows Townsend's south corridor feeding that lobby. Not confirmed: (a) that the demo walker will actually come out of that vestibule rather than a Townsend side/courtyard door (none of those are on a mapped footway, and none face Illinois St); (b) the node's absolute accuracy — it is an OSM-drawn building-outline vertex, so expect a few metres of error; (c) whether the door is card-access only outbound (irrelevant for exit, but check for the return). Re-record standing on the outdoor side of the door, under the canopy. Also check GPS there: the go/no-go needs ≤ 20 m for 30 s at the door, and the WP1 fence only fires on a moving fix with accuracy ≤ 20 m next to a 12-storey tower. Expect the WP1 line twice (once inside the route intro, once when the fence fires as you start walking).
2. **WP2, plaza-to-sidewalk exit.** Chosen from OSM footway geometry (canopy walk south, plaza path west, connector south — about 81 m walked vs 57 m straight-line). Confirm which plaza path a cane user would naturally take; the real headings are ~180 then ~270 then ~180, which is why the leg is `curved`. Because the WP1 chord is 225.6°, the beacon holds 225.6° (south-west) for the few seconds between the WP2 fence and your turn west; check that this is not confusing. The eastern connector (way 562059276) is equally short but leads away from Goodwin.
3. **Intersection waypoints (3, 4, 6, 7) sit on the street-centre / crossing node, not the pedestrian corner.** The corner a walker stands on is ~8–12 m from the node. With the 12 m turn fences on WP3 and WP6 that margin is gone: if the fence does not fire at the corner, passed-by only fires *after* you have walked on (and it names the waypoint instead of saying "turn right" / "turn left"), so at WP3 a walker could continue west into Goodwin. **Re-record WP3 at the NE corner of Illinois / Goodwin and WP6 at the SE corner of Goodwin / Springfield** (where you stand before crossing Goodwin), and WP4 / WP7 at the curb you wait at. At a crossing, the beacon's curb release needs two stationary fixes within 10 m of the waypoint, another reason to put it at the curb.
4. **Sidewalk-side assumption.** The `say` strings assume: north sidewalk of Illinois west to Goodwin, east sidewalk of Goodwin north to Springfield (so no crossing of Goodwin at Illinois — WP3 is `crossing: false` and says "No crossing needed"), one signalized crossing of Green St on that sidewalk (WP4), one signalized crossing of Goodwin at Springfield (WP6), then the south sidewalk of Springfield with the Mathews crossing (WP7). If the team prefers to cross Goodwin at Illinois instead, WP3 becomes a crossing and the crossings pin in the test changes too.
5. **Crossing control at Mathews (WP7)** is not tagged in OSM; the line does not claim a signal. Check whether it is signalized / has a push button and whether the WP4 and WP6 buttons are accessible (APS beeps unverified).
6. **WP5, mid-block.** Purely interpolated. Fine for a distance cue, but confirm nothing (driveway, construction) sits there.
7. **WP8 and WP9, CIF east side.** The `entrance=yes` node on the east face is 26 m south of Springfield. The connector path from the Springfield sidewalk was inferred from nearby footway ways (561329884, 1315345019, 1316576409) without their full geometry. Confirm on site that the east entrance is the intended arrival door (the task said "east entrance on Springfield Ave"; OSM also shows a west-side covered entrance at 40.11242, -88.22866, and CIF's main facade faces Springfield to the north). Two code consequences to check: the turn at WP8 is only -27.6° on the chord bearings, so **no wrist tap** accompanies "Turn left" (the threshold is 30°) — a WP8 re-recorded where the path actually leaves the sidewalk may fix that; and the WP8->WP9 leg is an L, so veer cues on it may fire (only WP1 may be `curved` without changing the test).
8. **Arrival.** Check that the two-hit arrival fires at the CIF east door (go/no-go: within 25 m) and not on the Springfield sidewalk 26 m north of it; with a 20 m fence and good GPS it should need you within ~15 m of the door.
