# Stress campaign (Step 66)

The owner asked: *"can we make sure this really really works — spin up a few simulations and other things
like Google Maps and really stress the idea and logic; whenever you do it for some reason it's always
different."* This folder is the answer in three layers. Each layer runs on its own.

| Layer | What runs | Needs | Time |
|---|---|---|---|
| A. Logic properties | `ios/Logic/Tests/CaneKitLogicTests/StressTests.swift`: seeded random walks, lane streams, indoor chaos, island churn, 5,000-utterance fast-path fuzz | nothing (part of `make test`) | ~5 s |
| B. Route data | `build_routes.py`: walks from OpenStreetMap foot routing (the "Google Maps-like" source) | network once (cached in `osm/`) | ~10 s |
| C. Simulator replays | `../e2e.py --scenario stress_* / indoor_isr`, and `campaign.py` repeats everything | `make sim`, the iPhone 17 Pro Max simulator, nothing else using it | ~5 min per run |

## A. Logic: determinism and invariants

```sh
cd ios && make test                                   # includes StressTests
cd ios/Logic && swift test --disable-xctest --filter "Survives|islandNever|islandAlert|fastPathFuzz" | grep STRESS-
```

Every stress test runs each seed twice in the same process and asserts identical output. It also prints
`STRESS-DIGEST <suite> <hash>` over everything it generated and decided. Swift randomizes its hash seed
per process, so compare the digests **across processes** too:

```sh
cd ios/Logic
for run in a b; do swift test --disable-xctest --filter StressTests 2>&1 | grep STRESS-DIGEST | sort > /tmp/digest_$run.txt; done
SWIFT_DETERMINISTIC_HASHING=1 swift test --disable-xctest --filter StressTests 2>&1 | grep STRESS-DIGEST | sort > /tmp/digest_c.txt
diff /tmp/digest_a.txt /tmp/digest_b.txt && diff /tmp/digest_a.txt /tmp/digest_c.txt && echo identical
```

`STRESS-STAT` lines carry the measurements: arrival rate per noise bucket, worst early arrival, and
head fires and lines. `STRESS-VIOLATION` lines list any broken invariant. The invariants are listed
in the test file's header.

## B. Walks from OpenStreetMap

```sh
cd ios
python3 scripts/stress/build_routes.py            # refetch from routing.openstreetmap.de (1 request / s)
python3 scripts/stress/build_routes.py --offline  # rebuild from osm/*.json; byte-identical output
```

| Walk | Route the app walks | Trace the simulated walker follows |
|---|---|---|
| `isr_cif` | bundled `route_isr_cif.json` (demo) | its 9 waypoints (the e2e `clean` path) |
| `cif_isr` | `routes/cif_isr.json` (OSRM, reversed demo) | OSRM foot geometry |
| `isr_grainger` | `routes/isr_grainger.json` | OSRM foot geometry |
| `isr_union` | `routes/isr_union.json` | OSRM foot geometry |
| `cif_siebel` | `routes/cif_siebel.json` | OSRM foot geometry |
| `isr_union_wrong_turn` | `routes/isr_union.json` | OSRM geometry, 50 m past its first real turn and back (the loop with a recovery) |

`routes/*.json` use the app's route schema, built the way `RouteBuilder.waypoints` turns MapKit steps
into waypoints: one waypoint at the end of each step, spoken with the next step's instruction, 15 m
fences and a 20 m arrival fence. `traces/*.gpx` hold the same points, so you can open a walk in any
map viewer. Endpoints are the `CampusPlaces` entrances. OSM data is © OpenStreetMap contributors,
ODbL. None of these routes has been walked.

## C. Simulator replays

A non-bundled route reaches the app through one environment hook, `CANEKIT_ROUTE_FILE=<absolute path>`
(`RouteSource.bundled()`). The demo-route hook `CANEKIT_DEMO_ROUTE=1` then walks that file instead of
the bundled one.

```sh
cd ios && make sim
python3 scripts/e2e.py --scenario stress_cif_siebel --seed 11          # jitter 3 m, 2 × 20 s GPS gaps
python3 scripts/e2e.py --scenario stress_isr_grainger --seed 22 --jitter-m 6 --dropouts 3 --gap-s 30
python3 scripts/e2e.py --trace scripts/stress/traces/isr_union_wrong_turn.json --speed 2
python3 scripts/e2e.py --scenario indoor_isr                           # indoor steps → handover → route start
python3 scripts/stress/campaign.py --out build/stress                  # everything × 3 rounds, seeds 11 22 33
python3 scripts/stress/campaign.py --out build/stress --summarize      # rebuild results.md
```

- **Stress checks** (`check_stress`), in addition to e2e's usual ones: route start with the route
  file's waypoint count, arrival, waypoint indices strictly ascending, the arrival fix ≤ 25 m from the
  last waypoint, ≤ `--max-lines-per-min` (15) spoken lines per minute of walking, no identical
  consecutive lines, and no `field_kind`.
- **Perturbation** (`perturb`) is seeded: the trace is densified to one simulator tick per vertex,
  gets AR(1) Gaussian jitter, and is cut at `--dropouts` random points. Replay pauses `--gap-s`
  seconds at each cut, and `simctl` sends no fixes while it pauses. The same arguments always build
  the same replay.
- **`indoor_isr`** launches with `CANEKIT_INDOOR_ROUTE=1` and `CANEKIT_INDOOR_SIM_STEPS_PER_S=3`, with
  the GPS parked at the ISR door. It asserts `indoor` `advanced` never goes backwards and ends on the
  last step, then exactly one `exit` and one `handover` in order, then `route start`. After the handover
  the app starts its own walk simulator, so the run stops there.
- **`campaign.py`** runs one `e2e.py` process at a time, never in parallel. It saves each report under
  `--out/reports/` and flags every config whose repeated runs differ in outcome, waypoints, wrist cues
  or spoken lines (numbers masked). That table is where "it's always different" gets measured.

Run the simulator layer alone. A second xcodebuild or simulator job starves the GPS replay, and the
report's `gps_median_dt` / starved warning then says so.
