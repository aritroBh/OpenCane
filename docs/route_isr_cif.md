# Route: ISR Townsend Hall to CIF (UIUC, Urbana IL)

Waypoint file: `ios/CaneKit/Resources/route_isr_cif.json`
Coordinates pulled 2026-09-10 from OpenStreetMap; start point re-checked 2026-09-11 against the University Housing ISR site plan and floor plans after the start was fixed as **Townsend Hall**. **Not yet walked or GPS-verified** — see the "to re-record Friday" list below.

Path: Townsend Hall, out through the ISR front doors (south vestibule of the 2020 lounge building, at Townsend's south-west corner) -> south under the canopy, west along the plaza path and down to the W Illinois St north sidewalk -> west to S Goodwin Ave -> north on the east sidewalk of Goodwin (crossing W Green St) -> cross Goodwin at Springfield Ave -> west on the south sidewalk of Springfield (crossing S Mathews Ave) -> left at the CIF east-side path -> CIF east entrance.

## Where Townsend Hall is, and which door is "the Townsend exit"

- ISR (1010 W Illinois St) is three joined buildings: **Townsend Hall = the east building** (OSM way 899305028, `addr:housenumber=918`, `building:levels=5`, footprint 40.10950–40.11019 N, -88.22127 to -88.22058 W, a C-shape opening east toward Lincoln Ave), **Wardall Hall = the west tower** (OSM way 899305030, 1012 W Illinois, 12 levels, footprint 40.10940–40.10958 N, -88.22199 to -88.22152 W), and the 2020 **lounge / Food Service Building** between them (OSM way 899305029, 1010 W Illinois). The University Housing site plan labels them the same way (Townsend Hall right/east, Wardall Hall bottom-left, "Lounge Building" and "Food Service Building" between) and the ISR page says Townsend has 5 floors and Wardall 12, matching the OSM levels.
- Townsend has **no separately mapped street entrance in OSM** and no door of its own onto W Illinois St. Its ground-floor south corridor runs straight into the ISR lobby, whose only south-facing public door is the canopied vestibule that projects toward Illinois St at Townsend's south-west corner (visible on the 1st-floor plan as the bump-out at the bottom centre, and on the site plan as the canopy between Wardall and Townsend). In OSM that door is `entrance=yes` node 5418851678 at 40.10949, -88.22135 with canopy roof way 1446788061 and covered footway 562059275 leading south from it; the node sits on the shared boundary of the lounge building and is 13.6 m from Townsend's south-west corner node (8355939352, 40.10950 -88.22120).
- So WP1 stays at that node; it is both the ISR front-desk door and the door a Townsend resident exits by. The other Townsend doors on the plans (an exit-stair door on the north-west basement side, a courtyard door on the east face) open away from Illinois St and are not on any mapped footway, so they were not used.
- The plaza exit (WP2) is unchanged: from the canopy the mapped walk goes south 16 m to the east-west plaza path (way 562059272), west 41 m to the connector (way 562059273), then south 18 m to the Illinois St sidewalk junction node 5418851673. Total walked distance WP1->WP2 is about 81 m; the eastern connector (way 562059276, down to 40.10914 -88.22086) is the same length but heads away from Goodwin, so the western one is kept.

## Waypoints

| # | lat | lon | r (m) | crossing | bearing to next | seg (m) | source / OSM reference | status |
|---|-----|-----|-------|----------|-----------------|---------|------------------------|--------|
| 1 | 40.10949 | -88.22135 | 15 | no | 225.6 | 57 | Townsend Hall exit = ISR front doors: OSM node 5418851678 (`entrance=yes`) on the south vestibule of the lounge building at Townsend's SW corner, canopy roof way 1446788061; matches Housing site plan / 1st-floor plan | to re-record Friday |
| 2 | 40.10913 | -88.22183 | 15 | no | 266.7 | 176 | OSM node 5418851673, junction of Illinois St north sidewalk (way 562059268) and plaza connector (way 562059273); walked path from WP1 is canopy walk (562059275) -> 1446788077 -> plaza path 562059272 west -> 562059273 south | to re-record Friday |
| 3 | 40.10904 | -88.22390 | 15 | yes | 358.5 | 162 | OSM node 37972349, W Illinois St x S Goodwin Ave street intersection | verified (OSM) |
| 4 | 40.11050 | -88.22395 | 15 | yes | 359.6 | 126 | OSM node 5727977710, `highway=crossing`, signalized, push-button, tactile paving | verified (OSM) |
| 5 | 40.11163 | -88.22396 | 15 | no | 359.6 | 127 | Interpolated mid-block point on Goodwin (WP4-WP6 is 252 m) | interpolated |
| 6 | 40.11277 | -88.22397 | 15 | yes | 270.0 | 141 | OSM node 37975504, `highway=traffic_signals`, Springfield Ave x S Goodwin Ave | verified (OSM) |
| 7 | 40.11277 | -88.22563 | 15 | yes | 265.0 | 152 | OSM node 38077757, Springfield Ave x S Mathews Ave street intersection | verified (OSM) |
| 8 | 40.11265 | -88.22741 | 15 | no | 237.4 | 48 | Springfield south-sidewalk node (ways 207579081 / 1504277421 junction), where the path to CIF's east side leaves | to re-record Friday |
| 9 | 40.11242 | -88.22788 | 20 | no | — | — | OSM node 13269443017 (`entrance=yes`) on CIF building way 886109954, east face | to re-record Friday |

**Total route length: 989 m** (sum of great-circle segment lengths between consecutive waypoints; the real walked distance will be slightly longer because WP1->WP2 and WP8->WP9 follow L-shaped paths, not the straight line).

Bearings are initial great-circle bearings, degrees true, computed with the standard forward-azimuth formula. Distances use the haversine formula with R = 6371008.8 m.

## Sources

- Nominatim (`https://nominatim.openstreetmap.org/search`) — located "Illinois Street Residence Halls" (landuse way 899305031, bus stop node 5425410082), "Townsend Hall, 918 West Illinois Street" (building way 899305028, polygon bbox 40.1095012–40.1101866 N, -88.2212685 to -88.2205780 W; queried 2026-09-11) and "Campus Instructional Facility, 1405 Springfield Avenue" (building way 886109954, bbox 40.11230-40.11262 N, -88.22872 to -88.22783 W).
- Overpass API (`https://overpass-api.de/api/interpreter`) — street-intersection nodes (shared nodes between the named highway ways), `entrance=*` nodes, sidewalk and footway geometry around both buildings; re-queried 2026-09-11 for the ISR block (buildings 899305028/029/030, all `entrance` nodes, all footways). The only `entrance` node on the Illinois St side of ISR is 5418851678.
- University Housing Facilities, ISR building information (`https://mail.hsgintranet2024.web.illinois.edu/facilities-building-information-isr-hall`) with its linked **ISR Site Plan** and **ISR Floor Plans** PDFs (`.../sites/default/files/2025-11/Floor%20Plans%20ISR%20Site%20Plan.pdf`, `.../Floor%20Plans%20ISR.pdf`, Nov 2025) — used to identify Townsend as the east building and the lobby vestibule at its SW corner as the Illinois-St-side door. Housing also lists Townsend as 908/918 W Illinois St (the two pages disagree on the number; OSM uses 918).
- University Housing ISR page (`https://www.housing.illinois.edu/living-communities/halls/isr`) — Townsend 5 floors, Wardall 12 floors, single 24-hour front desk for both halls.
- Data (c) OpenStreetMap contributors, ODbL 1.0.

Note: in OSM, Springfield Ave through campus is named "Springfield Avenue" (no "West"), which is why the strict "West Springfield Avenue" match failed on the first query.

## Could NOT be verified — to re-record Friday

1. **WP1, Townsend Hall exit.** The OSM `entrance=yes` node (no `entrance=main` tag) and the Housing plans agree on one canopied south door at Townsend's SW corner, and the 1st-floor plan shows Townsend's south corridor feeding that lobby. What I could not confirm: (a) that the demo walker will actually come out of that vestibule rather than a Townsend side/courtyard door (none of those are on a mapped footway, and none face Illinois St); (b) the node's absolute accuracy — it is an OSM-drawn building-outline vertex, so expect a few metres of error; (c) whether the door is card-access only outbound (irrelevant for exit, but check for the return). Re-record standing on the outdoor side of the door, under the canopy.
2. **WP2, plaza-to-sidewalk exit.** Chosen from OSM footway geometry (canopy walk south, plaza path west, connector south — about 81 m walked vs 57 m straight-line). Confirm which plaza path a cane user would naturally take; the straight-line bearing 225.6 from WP1 is a diagonal across the plaza, not a walkable heading — the real headings are ~180 then ~270 then ~180. The eastern connector (way 562059276) is equally short but leads away from Goodwin.
3. **WP8 and WP9, CIF east side.** The `entrance=yes` node on the east face is 26 m south of Springfield. I inferred the connector path from the Springfield sidewalk from nearby footway ways (561329884, 1315345019, 1316576409) but did not fetch their full geometry. Confirm on site that the east entrance is the intended arrival door (the task said "east entrance on Springfield Ave"; OSM also shows a west-side covered entrance at 40.11242, -88.22866, and CIF's main facade faces Springfield to the north).
4. **WP5, mid-block.** Purely interpolated. Fine for a distance cue, but confirm nothing (driveway, construction) sits there.
5. **Intersection waypoints (3, 4, 6, 7)** use the street-center/crossing node, not the pedestrian corner. The corner a walker actually stands on is ~8-12 m from the node, inside the 15 m trigger radius, but check the trigger fires reliably.
6. **Sidewalk-side assumption.** The `say` strings assume: east sidewalk of Goodwin from Illinois to Springfield (so no crossing of Goodwin at Illinois — WP3 is still flagged `crossing: true` per the schema spec, and the spoken text says "no crossing needed"), one signalized crossing of Goodwin at Springfield, then the south sidewalk of Springfield. Change WP3/WP6 wording if the team prefers to cross Goodwin at Illinois instead.
7. Crossing control at Mathews (WP7) is not tagged in OSM; treat as unsignalized until checked.
