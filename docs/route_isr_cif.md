# Route: ISR to CIF (UIUC, Urbana IL)

Waypoint file: `ios/CaneKit/Resources/route_isr_cif.json`
Coordinates pulled 2026-09-10 from OpenStreetMap. **Not yet walked or GPS-verified** — see the "to re-record Friday" list below.

Path: ISR front entrance -> south through the plaza to the W Illinois St north sidewalk -> west to S Goodwin Ave -> north on the east sidewalk of Goodwin (crossing W Green St) -> cross Goodwin at Springfield Ave -> west on the south sidewalk of Springfield (crossing S Mathews Ave) -> left at the CIF east-side path -> CIF east entrance.

## Waypoints

| # | lat | lon | r (m) | crossing | bearing to next | seg (m) | source / OSM reference | status |
|---|-----|-----|-------|----------|-----------------|---------|------------------------|--------|
| 1 | 40.10949 | -88.22135 | 15 | no | 225.6 | 57 | OSM node 5418851678 (`entrance=yes`), canopy roof way 1446788061, between Wardall (1012) and Townsend (918) halls | to re-record Friday |
| 2 | 40.10913 | -88.22183 | 15 | no | 266.7 | 176 | Junction of Illinois St north sidewalk (way 562059268) and plaza connector (way 562059273) | to re-record Friday |
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

- Nominatim (`https://nominatim.openstreetmap.org/search`) — located "Illinois Street Residence Halls" (landuse way 899305031, bus stop node 5425410082) and "Campus Instructional Facility, 1405 Springfield Avenue" (building way 886109954, bbox 40.11230-40.11262 N, -88.22872 to -88.22783 W).
- Overpass API (`https://overpass-api.de/api/interpreter`) — street-intersection nodes (shared nodes between the named highway ways), `entrance=*` nodes, sidewalk and footway geometry around both buildings.
- Data (c) OpenStreetMap contributors, ODbL 1.0.

Note: in OSM, Springfield Ave through campus is named "Springfield Avenue" (no "West"), which is why the strict "West Springfield Avenue" match failed on the first query.

## Could NOT be verified — to re-record Friday

1. **WP1, ISR front entrance.** OSM has an `entrance=yes` node at the north end of a covered walk between Wardall and Townsend, with a canopy roof mapped just south of it. This is consistent with the post-2020 south-facing main entrance, but the node has no `entrance=main` tag and I could not confirm it is the front-desk door (vs. a side door). Re-record standing at the actual front-desk door.
2. **WP2, plaza-to-sidewalk exit.** Chosen from OSM footway geometry (plaza path goes south, west, south). Confirm which plaza path a cane user would naturally take; the straight-line bearing 225.6 from WP1 is a diagonal across the plaza, not a walkable heading.
3. **WP8 and WP9, CIF east side.** The `entrance=yes` node on the east face is 26 m south of Springfield. I inferred the connector path from the Springfield sidewalk from nearby footway ways (561329884, 1315345019, 1316576409) but did not fetch their full geometry. Confirm on site that the east entrance is the intended arrival door (the task said "east entrance on Springfield Ave"; OSM also shows a west-side covered entrance at 40.11242, -88.22866, and CIF's main facade faces Springfield to the north).
4. **WP5, mid-block.** Purely interpolated. Fine for a distance cue, but confirm nothing (driveway, construction) sits there.
5. **Intersection waypoints (3, 4, 6, 7)** use the street-center/crossing node, not the pedestrian corner. The corner a walker actually stands on is ~8-12 m from the node, inside the 15 m trigger radius, but check the trigger fires reliably.
6. **Sidewalk-side assumption.** The `say` strings assume: east sidewalk of Goodwin from Illinois to Springfield (so no crossing of Goodwin at Illinois — WP3 is still flagged `crossing: true` per the schema spec, and the spoken text says "no crossing needed"), one signalized crossing of Goodwin at Springfield, then the south sidewalk of Springfield. Change WP3/WP6 wording if the team prefers to cross Goodwin at Illinois instead.
7. Crossing control at Mathews (WP7) is not tagged in OSM; treat as unsignalized until checked.
