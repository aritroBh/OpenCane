# Street View route frames (local test input)

Google Street View captures of the ISR Townsend Hall → CIF route, one per waypoint, facing the
walking direction. They let us test the camera features without walking the route:

- `swift scripts/vision_probe.swift scripts/streetview` — what the phone's on-device Vision
  (scene labels, sign text, hazard labels) says at each corner.
- `make uitest-streetview` — the real app in the simulator uses the frame nearest to its GPS
  position as its camera (`FrameReplay`, `CANEKIT_FRAME_DIR`) and "Where am I" must answer.
- `make e2e SCENARIO=streetview` — the real app walks the whole route (simulated GPS) with these
  frames as its camera, the hazard watch on and "Where am I" asked at the start and every waypoint;
  `ios/build/e2e/report.json` lists what was said at each corner (`describes`), every text the sign
  reader saw (`scan_texts`) and every hazard-watch reply (`hazard_watch`).
- `swift scripts/sign_probe.swift scripts/streetview` — pastes a "SIDEWALK CLOSED" sign onto each
  frame at many sizes and measures how far away the app's sign reader can read it.

`frames.json` (committed) lists file, lat, lon, heading. The JPEGs are Google's imagery and are
**git-ignored**: capture them yourself — open each viewpoint in Chrome with
`https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=<lat>,<lon>&heading=<heading>&pitch=-8&fov=90`,
screenshot the window at 1493×812, crop rows 185–700 (drops the Maps overlays), save as
`<file>` next to `frames.json`.

## Step 12 findings (2026-09-11, afternoon) and fixes

| Found | Fix |
|---|---|
| The on-device "Where am I" template read Vision's taxonomy aloud: "Automobile, machine and vehicle in view." (Green St), "Conveyance, portal and manhole in view." (Springfield), "Furniture, table and conveyance in view." (ISR lounge) | `SceneVocabulary` (CaneKitLogic): "Ahead: the street and cars.", "Ahead: the street and a manhole cover.", "Ahead: tables, chairs and windows."; a crosswalk is said first |
| Sign range was a guess ("~5 m") | `sign_probe.swift` measured it: the old 1/80 text floor read 7.5 cm letters from ≈ 4.4 m; now 1/128 reads them from ≈ 7 m (15 cm from ≈ 14 m) on every frame, at the same OCR cost |
| At that range a STOP sign (for drivers) would be read at every stop-controlled corner | "STOP" removed from the sign phrases; "PUSH BUTTON" added |
| The e2e "passed" with no trace of the camera | trip-log `scan`, `hazard_watch`, `describe_result` records; the streetview scenario fails unless ≥ 8 of 10 corners are described |

## What the first 2026-09-11 run showed

| Where | On-device Vision saw | Notes |
|---|---|---|
| ISR lounge (start) | furniture 80 %, table 77 %, chair 52 % | indoor scene recognised |
| Goodwin / Illinois corner | crosswalk 86–95 %, road, path | crosswalk is the most reliable crossing cue |
| Green St | cars, road, traffic light (low) | |
| Springfield | manhole 98 %, road, sidewalk | |
| Mathews | sign 64 %, hydrant 16 % | hydrant present but weak |
| CIF path / entrance | sidewalk, trash can 59 %, stairs, planters | |

Text recognition read **nothing** from mid-road viewpoints (signs are ~30 px tall), so the sign
reader stayed silent the whole route — no false sign reads. On the cane, signs are metres away.
Railings score "fence" 44–62 % all along the route, which is why the on-device hazard watch only
names a label when LiDAR confirms an obstacle ahead, and is off by default.
