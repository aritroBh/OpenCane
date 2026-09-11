# CaneKit stress test and end-to-end test plan (the 24 h before the demo)

Written Fri 2026-09-11 against HEAD `7b15256` plus the uncommitted working tree, then re-checked
against the working tree once it added the hazards layer, the Files app keys and the review round 5
fixes. Every number here comes from the code: `CaneKitLogic`
defaults, `NavigationEngine`, `SpeechQueue`, `BeaconEngine` and `route_isr_cif.json`. If the code
and another doc disagree, the code is right; §0 lists the disagreements. If a number in the code
changes, update this file.

**People.** **Aritro** does the software: builds, automation, logs, phone setup, filming. **Sagar**
does the hardware: clamp, mount angle, cane, power bank, sun shade, heat. **Aarav** is the walker and
wears the watch and AirPods. For the blindfolded walks, Sagar spots and Aritro films.

**Test IDs.** A = automated · B = bench (indoors, phone plugged in) · W = outdoor walk ·
D = device matrix (§2) · F = failure injection (§3) · G = go/no-go (§4).

---

## 0. Read this before testing: facts from the code that change how you test

1. **The trip log and the hazard map are in the Files app.** `ios/project.yml` sets
   `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` to `true`, so Documents shows up
   under **Files → On My iPhone → CaneKit**: the trip logs `canekit-*.jsonl` and
   `hazards/hazards-<session>.geojson` with its photos. AirDrop them from there after every walk; the
   Mac (§1.4) is only the fallback. A phone still running a build from before that change needs one
   `make run` first.
2. **A screen lock stops obstacle sensing and says nothing.** A lock sends the app to the
   background, which pauses ARKit and stops the haptics. GPS, speech, the beacon and watch cues keep
   running (the `location` and `audio` background modes). Guided Access with the side button disabled
   is required (D16).
3. **A killed app doesn't resume the route.** "Start demo route" starts again at WP1. Look-ahead is
   only 2 waypoints and passed-by needs you within 2 × radius, so from mid-route the tracker is stuck
   and the beacon points back toward ISR. The recovery is to press **Next** once per waypoint already
   passed (F12 table).
4. **Some things are not in the log.** Heading, bearing error, beacon volume, head yaw, which voice
   played (ElevenLabs or System), fps, AR tracking state, the channel lines spoken at route start,
   connect and disconnect lines (only an `audioroute` event), "Describing." and the description text.
   For those, screen-record (Control Center) or film the Guide and Haptics pills.
5. **WP1's line is spoken twice.** The intro ("Route started. … First: Leaving Townsend Hall…") says
   it once, and entering the WP1 fence says it again as soon as you move faster than 0.5 m/s. This is
   expected.
6. **WP8 gets no wrist tap.** Its line says "Turn left", but the bearing only changes 265.0° →
   237.4° = −27.6°, and the turn tap needs more than 30°. This is expected (e2e `clean` asserts it).
   The WP1→WP2 leg is `curved`, so the beacon is silent and there are no veer cues until WP2.
7. **Head yaw is ignored until a Recenter.** After route start, each waypoint and each AirPods
   reconnect, the beacon uses the phone heading alone until a manual Recenter or an auto-recenter.
   The auto-recenter (`StraightWalkDetector`) needs 3 consecutive fixes (the first counts) at
   **> 0.6 m/s**, accuracy ≤ 20 m, course steady within 15° from fix to fix, head yaw within 8° from
   fix to fix, AirPods head tracking live, no turn still settling, and ≥ 15 m past a just-reached
   crossing. Any failed check starts the count again; it never fires on a timer. The head-turn check
   in `devices_setup.md` only works after you press Recenter.
8. **Heat handling is thinner than the docs say.** `.serious` or `.critical` turns mesh
   classification off (so no obstacle names), pauses sign reading and the hazard watch, and freezes
   the live camera view. "Phone is hot. Door and wall names and sign reading paused." is spoken
   once when it turns hot; lanes and haptics keep running, and at `.critical` the beacon stays on. There's no low-battery
   line. The debug footer is gone: thermal, battery, camera tilt (`tilt`) and depth rate (`fps`) are
   in every `lanes` log record, and the Mount card shows "Camera tilt N° down · N fps" live; on the
   walk, listen for the hot line.
9. **Arrival gate.** The fix must satisfy `distance + accuracy/2 ≤ 20 m` (WP9 radius) on 2
   consecutive fixes with accuracy ≤ 30 m, and there's no speed gate. So at ±10 m accuracy, arrival
   fires within 15 m of the node. Intermediate fences need accuracy ≤ 20 m and speed > 0.5 m/s. Speed
   is −1 when standing, which fails the gate.
10. **`docs/route_isr_cif.md` matches the JSON** (its tables were regenerated from it on
    2026-09-11): WP3, WP6 and WP8 are 12 m, WP9 is 20 m, and WP3 is **not** a crossing. Crossings are
    WP4, WP6 and WP7. If the two ever disagree, the JSON is the truth.
11. **Watch and cane haptics** (`WatchModel`, `HapticPlayer`; design.md §5.3 / §6.6 agree). Wrist:
    turnLeft `.directionUp`, turnRight `.directionDown`, crossing `.notification`, arrived `.success`,
    and mirrored obstacles left `.start` / right `.stop` / center `.click` / head `.failure`. A button
    press that can't reach the phone plays `.retry`. Every route cue (and veer) is also felt on the
    cane as soft continuous buzzes: left one 0.45 s buzz, right two 0.35 s, crossing three 0.3 s,
    arrived long-short-long. A ground hazard is 4 heavy taps.
12. **Voice cache.** Prefetch covers exactly 25 lines: 15 `commonLines`, 9 waypoint `say` lines and
    the intro. Any line built at runtime is a cache miss: Repeat (it includes a distance), "Passed X.
    Y in N meters.", the arrival summary, "\<AirPods\> connected.", channel warnings, "Describing.".
    A route or Repeat line that misses waits up to **2.5 s** for ElevenLabs, then falls back to the
    system voice. Obstacle and safety lines never wait.

---

## 1. Test levels

### 1.0 The next 24 hours

| Block | When | What runs | Who | Done when |
|---|---|---|---|---|
| A: bench | Tonight, phone plugged in, ISR lobby, ~3.5 h | A1–A5; **D18 first** (needs a fresh install); D1–D8, D10, D11, D13, D15–D17; F10, F11, F12 drill | Aritro on all; Sagar D1–D5 + D16 clamp; Aarav D2, D11 | Every bench D-test passes, or is on the bug list with its log file |
| B: first daylight | Sat from ~08:00 (sunrise ≈ 06:35 CDT), ~2 h | W1 survey → route JSON fixes → A1 + A5 → reinstall + B-smoke → **W2 reference walk** (D9, D12, D13, D14) | Aarav walks, Aritro logs and films, Sagar spots | W2 meets every D12 pass criterion |
| C: stress | 11:00–14:00 | W3 stress walk ≥ 30 min (F1–F3, F5–F9, F12); F4 at 12:30–13:30 | All three | Every F result logged |
| D: fix + freeze | After C, ~2 h | Triage logs → fixes → A1–A6 → reinstall → B-smoke → **code freeze ≥ 3 h before the demo walk** → W2′ (sighted walk on the frozen build) | Aritro | W2′ meets D12 on the frozen build |
| E: rehearsal | Start by 18:15 CDT | §4 go/no-go → **W4 blindfolded rehearsal** | All three | W4 passes |
| Demo | — | §5 run sheet | All three | — |

If code changes after the freeze, rerun A1 + A5 + B-smoke **and** a sighted W2′. Otherwise there is
no blindfolded walk.

### 1.1 Automated (Mac, no phone): run on every change

| ID | Command (from `ios/`) | What it covers | Pass | Time |
|---|---|---|---|---|
| A1 | `make test` | 124 Swift Testing tests: lane math, CueDecider hysteresis and rates, geofence skip-ahead, passed-by, arrival plausibility (30 m blob), TurnSettle incl. curb release, StraightWalk, CueSpeechPolicy, CourseSmoother, ground hazards / signs / hazard watch / GeoJSON, Crown, watch and VLM codecs, route file | 114/114 | < 1 min |
| A2 | `make sim` | Swift 6 strict build for the simulator | 0 errors | ~3 min |
| A3 | `make uitest` | 7 XCUITests: start/Next/Repeat/Recenter/Stop, Where am I without a key, haptic buttons + Silence, mount toggles, a11y labels, empty destination; the Street View "Where am I" test is skipped unless run with `make uitest-streetview` | 6/6 + 1 skipped | ~4 min |
| A4 | `make tour` | PNG per screen state → `build/shots` | Every PNG reviewed: no truncated pill ("SPEAKI…"), no hyphenated "Recen-ter", instruction not clipped | ~3 min |
| A5 | `make e2e` (or `SCENARIO=clean`) | GPS replay through the real app on the iPhone 17 Pro Max / iOS 27 simulator; asserts on the JSONL log. Report: `build/e2e/report.json` | 4/4 PASS | ~20 min |
| A6 | `python3 scripts/e2e.py --scenario clean --speed 1.0` | Same `clean` path at walking pace (the default 4 m/s makes the distance-based turn-settle release fire before the 25 s moving-time one) | PASS | ~19 min |

What `make e2e` asserts (from `scripts/e2e.py`), so a failure is easy to read:

- **All scenarios**: a `route` start, `arrived`, waypoints in ascending order, the trip summary
  spoken ("kilometers" or "meters,").
- **clean**: waypoint indices exactly 1..9; wrist cues exactly `turnRight, turnRight, crossing,
  crossing, crossing, arrived`; 0 "Veer"; 0 "Passed".
- **missed_fence**: WP2 is passed 22 m off (outside the 15 m fence, inside 2r = 30 m) and WP8 is
  skipped 28 m north. Needs at least one "Passed …" line that uses a place name, not a sentence.
- **gps_jitter**: ±6 m noise on a fix every 5 m. At most 3 "Veer" lines, and it still arrives.
- **wrong_turn**: overshoots 60 m west at Goodwin, then comes back. Needs at least one
  "Veer right.", and it still arrives.

**What the simulator can't show you** (so these are device tests):

- **Accuracy is fixed in the simulator**, so "GPS weak", the arrival plausibility check and the
  curb release (two stationary fixes) never happen there. The unit tests cover their logic.
- **There's no compass**, so heading comes from course only.
- **None of the hardware exists there**: LiDAR, haptics, beacon audio, AirPods, the watch, Live
  Activity rendering, thermal state.

**When to run what.** Every code change: A1 + A2. Every UI change: + A3 + A4. Every change to
nav, speech or the route file: + A5. Before each phone install: A1 + A2 + `make e2e SCENARIO=clean`.
Before code freeze: A1–A6.

### 1.2 Bench (indoors, phone plugged in, ISR lobby)

Runs the D-tests that don't need GPS: D1–D8, D10, D11, D13, D15–D18, plus F10, F11 and the bench
part of F12.

- **Thermal and battery numbers from the bench don't count**, because charging heats the phone.
- **Screen-record every bench session** so you capture the pills that §0.4 says aren't logged (the
  debug footer is gone, so fps is not visible anywhere).
- **Bench smoke (B-smoke, 15 min)** runs after every reinstall: D1 wall, D2 four patterns, D5 head,
  D10(a)(b), D11(a)(c).

### 1.3 Outdoor walks

| ID | What | Who | Pass |
|---|---|---|---|
| W1 | **Survey walk, sighted.** Start the demo route (GPS only logs while a route runs) and stand **30 s still** at the outdoor side of the ISR canopy (WP1), the plaza-to-sidewalk junction (WP2), the pedestrian corners at WP3/4/6/7, WP5, the CIF path turn (WP8) and the CIF east door (WP9). At each corner, pace the distance from the curb to the OSM node and write it down. Mark tree-canopy stretches for F1. | Aarav walks, Aritro logs | For each stop, the "stop" script (§1.4) prints the offset to the JSON coordinate. Offset > 8 m on WP1/2/8/9 → Aritro edits `route_isr_cif.json` and reruns A1 + A5. Curb > 10 m from the node → that crossing releases by heading or after 25 s of moving, not at the curb (note it for F2). |
| W2 | **Reference walk, sighted, app running.** Normal pace, no injected faults; film it with the second phone. Includes D9 (auto-recenter), D12, D13, D14. | Aarav walks, Aritro films, Sagar spots | D12 pass criteria |
| W3 | **Stress walk.** The same route with the scripted faults F1, F2, F3, F6, F7, F8 (one segment), F9 (one segment), F12 (at WP5). Run it ≥ 30 min unplugged in the sun, which doubles as F5. | All three | §3 criteria; the route still completes |
| W4 | **Blindfolded rehearsal** after a full §4 go/no-go. Same protocol as the demo. | Aarav walks, Sagar spots, Aritro films | Arrives with ≤ 2 spotter "Stop" interventions and 0 aborts |

Timing for W2/W4: 989 m great-circle, about 1,025 m walked. At 0.8 m/s that's 21.4 min of walking,
plus about 2.3 min waiting at crossings, so **~24 min (range 20–30)**. Cumulative checkpoints: WP2
1.7 min · WP3 5.4 · WP4 8.7 (+1 min signal) · WP5 12.4 · WP6 15.0 (+1 min signal) · WP7 18.9 · WP8
22.4 · WP9 ~24. Daylight: solar noon is about 12:50 CDT and sunset about 19:05 CDT, so start W4 by
18:15.

### 1.4 Log toolkit (Aritro)

**Getting the log off the phone.** Plugged in, or on the same Wi-Fi once paired. Check the flags with
`xcrun devicectl device copy from --help` before relying on them:

```sh
cd ios; mkdir -p logs
xcrun devicectl device info files --device $DEVICE --domain-type appDataContainer \
  --domain-identifier com.aritro.canekit --subdirectory Documents
xcrun devicectl device copy from --device $DEVICE --domain-type appDataContainer \
  --domain-identifier com.aritro.canekit --source Documents/<file>.jsonl --destination logs/<file>.jsonl
```

Fallback: Xcode → Devices and Simulators → the phone → CaneKit → ⋯ → Download Container. Without
the Mac (§0.1): Files → On My iPhone → CaneKit → AirDrop (trip logs, and `hazards/` for the hazard
map).

**What's in the log.** One file per app launch: `canekit-<ISO time with - for :>.jsonl`. Every line
has `t` (seconds since launch) and `kind`:

- `session` · `start` {lidar, mesh, haptics, vision} · `route` {action start|stop, name, waypoints,
  headphones, watch}
- `gps` {lat, lon, acc, speed} ~1 Hz, only while a route runs · `waypoint` {index = the 1-based
  waypoint reached} · `navcue` {cue} · `arrived`
- `speech` {text, priority obstacle|safety|nav, repeat?} · `cue` {kind center|left|right|head|clear,
  ar_t, distance?}
- `lanes` at 2 Hz {head[3], torso[3] (−1 = no data or clear), trusted, omega, cue, thermal, battery,
  mesh}
- `audioroute` {connected, name} · `recenter` {auto?} · `repeat` · `watch` {command | test} ·
  `describe` {provider}
- `hazard` {kind, text, source ground|sign|vision}; the same hazard with GPS and photo goes to
  `Documents/hazards/hazards-<session>.geojson`

```sh
L=logs/canekit-….jsonl
# timeline without the 2 Hz / 1 Hz noise
jq -r 'select(.kind!="lanes" and .kind!="gps") | [(.t*10|round/10), .kind, (.text // .cue // .index // .action // .command // .test // "")] | @tsv' $L
# navigation words that matter
jq -r 'select(.kind=="speech" and (.text|test("^(Veer|Passed|GPS)"))) | "\(.t)\t\(.text)"' $L
# GPS quality: n, median, p90, max, fixes worse than the 20 m gate
jq -s '[.[]|select(.kind=="gps" and .acc>=0)|.acc]|sort|{n:length,p50:.[length/2|floor],p90:.[length*0.9|floor],max:.[-1],over20:(map(select(.>20))|length)}' $L
# thermal + battery once a minute (iOS may report battery in 5 % steps)
jq -r 'select(.kind=="lanes") | "\(.t|floor)\t\(.thermal)\t\(.battery)"' $L | awk -F'\t' '$1>=n{print; n=$1+60}'
# sweep gate: share of untrusted depth samples, peak |ω|
jq -s '[.[]|select(.kind=="lanes")] | {n:length, untrusted:(map(select(.trusted==false))|length), max_omega:(map(.omega)|max)}' $L
# head-height episodes (expect one line per episode, ≥ 4 s apart)
jq -r 'select(.kind=="speech" and .text=="Head height.") | .t' $L
```

**Fence script.** How far from the waypoint node each waypoint fired (run it from the repo root):

```sh
python3 - "$L" <<'EOF'
import json, math, sys
wps = json.load(open("ios/CaneKit/Resources/route_isr_cif.json"))["waypoints"]
def d(a, b):
    p1, p2 = map(math.radians, (a[0], b[0])); dl = math.radians(b[1] - a[1])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))
pending = []    # the triggering fix's `gps` line is written right AFTER its `waypoint` line
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    if e["kind"] == "waypoint": pending.append(e)
    elif e["kind"] == "gps" and pending:
        for p in pending:
            w = wps[p["index"] - 1]
            print(f'WP{w["id"]} t={p["t"]:.0f}s {d((e["lat"], e["lon"]), (w["lat"], w["lon"])):.1f} m from node '
                  f'(r={w["radius_m"]}) acc={e["acc"]:.0f} speed={e["speed"]:.1f}')
        pending = []
EOF
```
The simulator `clean` replay at 4 m/s prints every waypoint at ≤ its radius (at 4 m/s, WP2 fires at
about 13 m). On the phone, a turn waypoint that fires at more than radius + 5 m past the corner fails
D12.

**Stop script** for W1. It finds the 30 s standing stops and prints each one's offset from the
nearest waypoint:

```sh
python3 - "$L" <<'EOF'
import json, math, statistics as st, sys
wps = json.load(open("ios/CaneKit/Resources/route_isr_cif.json"))["waypoints"]
def d(a, b):
    p1, p2 = map(math.radians, (a[0], b[0])); dl = math.radians(b[1] - a[1])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))
fixes = []
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    if e["kind"] == "gps": fixes.append(e)
stops, cur = [], []
for f in fixes + [{"speed": 9, "acc": -1}]:
    if f["speed"] < 0.3 and 0 <= f["acc"] <= 10: cur.append(f)
    else:
        if len(cur) >= 20: stops.append(cur)
        cur = []
for s in stops:
    p = (st.median(f["lat"] for f in s), st.median(f["lon"] for f in s))
    w = min(wps, key=lambda w: d(p, (w["lat"], w["lon"])))
    print(f'stop t={s[0]["t"]:.0f}s n={len(s)} {p[0]:.6f},{p[1]:.6f} acc~{st.median(f["acc"] for f in s):.0f} '
          f'-> WP{w["id"]} off by {d(p, (w["lat"], w["lon"])):.1f} m')
EOF
```

---

## 2. Device test matrix

Each test lists: **Where/Who · Steps · Expect · Pass · Log**. The pass numbers are hard; any fail
goes on the bug list with its log file name and video timestamp.

### D1 LiDAR lanes through the clamp: bench · Sagar (mount), Aritro (reads)
- **Steps.**
  1. Clamp the phone on the cane and hold the cane at the walker's normal angle, tip on the floor.
     Read the Mount card's first line and click the hinge until it says "Camera tilt N° down, good"
     (3–8° down; hardware/mount/DESIGN.md).
  2. Face a flat wall at 0.5, 1.0, 1.5 and 2.0 m (tape from the lens). Read all six tiles for 10 s
     at each distance.
  3. Put a box or hand at torso height 0.8 m ahead in the left third, then the right third.
  4. Point at open space for 60 s.
- **Expect.** Tiles show the 10th-percentile depth. The bottom 25 % of the image is skipped as
  ground. Status shows "Depth OK" and the pill "Trusted".
- **Pass.**
  - At 1.0 m all six tiles read **0.8–1.2 m**; at the other distances ±0.2 m.
  - The left obstacle turns only the Left tiles below 1.2 m. If it turns the Right tiles, set
    "Mirror left / right" and record the final setting.
  - Open space: all torso tiles ≥ 2.0 m and **0 `cue` events in 60 s**. If the floor shows in the
    torso row, the mount angle is wrong and would run the Geiger loop forever: check the tilt line
    (at ~10° down or more the torso lanes read pavement near 2 m). Sagar re-angles.
  - Depth keeps up for 60 s: the Mount card shows ~15 fps and `lanes` records (with `fps` and
    `tilt`) are continuous at 2 Hz.
- **Log.** `lanes` torso/head/tilt/fps; `cue` count.

### D2 Haptic patterns felt through the clamp: bench · Aarav feels, Sagar presses
- **Steps.**
  1. Aarav holds the grip with eyes closed.
  2. Sagar presses the Haptics card test buttons (Left, Center, Right, Head) 20× in random order.
  3. Repeat with Aarav walking on a hard floor.
- **Expect.** Left: 2 taps 120 ms apart. Right: 3 taps 100 ms apart. Head: 2 hits 80 ms apart at
  intensity 1.0, sharpness 1.0. Center: the Geiger loop at 1 m for 2 s.
- **Pass.** Aarav names ≥ 18/20 standing and ≥ 16/20 walking; Head 5/5. Below 16/20 walking →
  Sagar stiffens the coupling (remove rubber, move the clamp toward the grip) and retests.
- **Log.** The test buttons bypass the decider and aren't logged, so use the screen recording.

### D3 Geiger approach and hysteresis: bench · Aritro
- **Steps.**
  1. With the cane still, walk from 3 m to 0.4 m toward a wall at about 0.3 m/s, then back away.
  2. Film with audio (the taps are audible).
  3. Stand at 2.0 m for 10 s.
- **Expect.**
  - The centre cue starts below 2.0 m at **rate = 4/d Hz, clamped to 2–8 Hz**, with intensity
    0.6 → 1.0. It clears only above **2.15 m**.
  - The side lanes enter below 1.2 m and clear above 1.35 m. The head band enters below 1.5 m and
    clears above 1.65 m.
  - Cue changes are ≥ 400 ms apart, and the same discrete cue fires at most once per second.
- **Pass.**
  - Onset at 2.0 ± 0.2 m.
  - Taps in 5 s held at 1.0 m: **20 ± 3**. At 0.5 m: **40 ± 5**.
  - Clears at 2.15 ± 0.2 m going back.
  - Standing at 2.0 m for 10 s: ≤ 1 `cue` fire (no flicker).
- **Log.** `cue` {kind:"center", distance} at onset, `cue` {kind:"clear"} on the way back, and
  `lanes` torso[1] around both.

### D4 Sweep gate: bench · Aarav sweeps, Aritro reads
- **Steps.** Stand 1.5 m from a wall. Do 30 s of normal two-point-touch sweep, then 30 s of fast
  sweep (more than 2 sweeps/s), then 30 s still.
- **Expect.** Frames with |ω| ≥ **0.6 rad/s** are untrusted: the pill shows "Sweeping", cues freeze
  (the decider emits nothing), and heading updates are ignored (the same gate).
- **Pass.**
  - Normal sweep: ≥ 30 % of `lanes` samples trusted, and the centre cue still fires within 1 s of
    reaching 1.5 m.
  - Still: 100 % trusted.
  - Fast sweep: record the trusted %. If it's below 10 %, the pitch and the walker brief say "sweep
    slowly".
- **Log.** The sweep-gate jq line.

### D5 Head height: bench · Aritro, Aarav
- **Steps.**
  1. Hold the cane in walking position.
  2. A helper holds a flat board at 1.6–1.9 m high, 1.0 m ahead, for 5 s, then takes it away for 3 s
     into **empty** space (a wall behind keeps the episode alive). Do 5 episodes.
  3. Turn "Silence haptics" on and do 2 more episodes with the watch on.
  4. Hold the board at 1.0 m high (torso) as a control.
- **Expect.**
  - The head double-hit re-fires up to 1 Hz while the board is there.
  - **"Head height." is spoken once per episode** at safety priority (it cuts any line), with at
    least 4 s between episodes.
  - Silenced: a wrist `.failure` tap plus "Head height.".
  - The torso board gives the centre Geiger, not the head cue.
- **Pass.**
  - Haptic within 0.5 s of the board entering (video), 5/5.
  - Exactly 5 "Head height." lines, ≥ 4 s apart.
  - Silenced: wrist tap and the line, 2/2.
  - Torso control: 0 head cues.
- **Log.** `cue` kind head; `speech` "Head height." priority `safety`.

### D6 Obstacle names indoors: ISR lobby + CIF entrance · Aarav, Aritro
- **Steps.** Five approaches each from 4 m at walking pace, cane still, to the ISR lobby door, the CIF
  east door, a chair, a table and a window. Then 2 approaches to the door with a sweep. Then stand
  10 s at 2 m.
- **Expect.**
  - Mesh lookups at about 4 Hz give "door ahead, two meters" once the object is closer than
    **3.0 m**. Walls are named only closer than **1.5 m**.
  - A class is named again only when it changes or after moving a full metre ("door ahead, one
    meter"), and never more often than every 2.5 s.
  - A class is forgotten 2 s after it leaves the centre. The line is dropped if it waits more than
    4 s (TTL).
  - Mesh is off at thermal `serious`.
  - Signs ("Read signs" on, the default): on-device text every 3 s reads small text (down to 1/128 of
    the frame height: 7.5 cm letters from ≈ 7 m, 15 cm from ≈ 14 m, measured by
    `ios/scripts/sign_probe.swift`). An EXIT / PUSH / PULL / PUSH BUTTON sign gives "Sign: exit."
    at `obstacle` priority, each sign at most once a minute. A STOP sign is never read out.
- **Pass.**
  - The door is named in ≥ 4/5 approaches, first at ≤ 3.0 m.
  - A ~10 cm-lettered sign is read from ≥ 4 m in ≥ 3/5 approaches, and never twice within a minute.
  - Wrong class ≤ 1/5, and never "wall ahead" with the wall more than 1.5 m away.
  - Standing 10 s: ≤ 1 line.
  - Note whether the first approach into a new room is late (the mesh takes time to build).
- **Log.** `speech` priority `obstacle`; the `lanes` `mesh` field; `hazard` {source: sign}.

### D7 Speech queue, priorities, Repeat: bench · Aritro
- **Steps and expected results.**
  - (a) Haptics card → **Speech test**. The scene line is cut at a word boundary by "Door ahead, one
    meter.", then the scene line replays from its start **once**.
  - (b) Start the demo route and make a head-height cue during the intro. "Head height." cuts in
    and the intro replays once. A second cut during that replay drops the intro (max 1 replay).
  - (c) Press **Repeat** mid-line. The last line restarts at once, followed by " Next, \<place\>, in
    N meters.".
  - (d) Press Repeat 5× within 2 s. You hear exactly one full playback after the last press.
  - (e) Queue two lines (Next twice), then **Stop route**. Only "Route stopped." plays.
  - (f) Press **Where am I** while the intro plays. The description, at scene priority, waits for
    the intro.
- **Pass.**
  - (a)–(e) 5/5 each.
  - A cut lands ≤ 0.5 s after the higher-priority trigger (video).
  - No line plays more than twice.
  - The pill goes back to "Quiet" ≤ 1 s after the audio ends. If it sticks, the watchdog frees it
    after 6 s + characters/6 s; log that as a bug.
- **Log.** `speech` (with `repeat:true`), `repeat`, `route` stop.

### D8 ElevenLabs cache and offline voice: bench · Aritro
- **Prerequisite.** `ELEVENLABS_API_KEY` must be in `Secrets.plist` **before** `make run`, because it
  ships inside the app.
- **Steps.**
  1. On Wi-Fi: Start the demo route, wait 60 s (it prefetches 25 lines, 3 at a time), then Stop.
  2. Turn on airplane mode (then turn Bluetooth back on).
  3. Start the demo route and press Next 9× to hear every waypoint line. Press Repeat once. Make a
     head-height cue.
  4. Turn airplane mode off, switch to cellular only with one signal bar if you can find one, and
     press Repeat 3×.
- **Expect.** All 25 prefetched lines play in the ElevenLabs voice (pill "ElevenLabs"). The Repeat
  text (runtime-built) uses the system voice. "Head height." never waits.
- **Pass.**
  - **25/25** prefetched lines are ElevenLabs offline.
  - Offline, no line starts more than 0.5 s after its trigger.
  - Weak cellular: Repeat starts ≤ 3.0 s after the press (2.5 s timeout, then system voice).
  - ≥ 25 files in `Library/Caches/elevenlabs` (`devicectl … info files --subdirectory
    Library/Caches/elevenlabs`).
- **Log.** Which voice played isn't logged; use the screen recording of the voice pill.

### D9 Beacon L/R, head tracking, Recenter: outdoors · Aritro, Aarav
- **Where.** The open plaza **≥ 40 m from the ISR canopy**. Before WP1 is reached the target is WP1,
  so the click should come from the door. (At the door itself the bearing is meaningless.)
- **Prerequisites.** AirPods Pro in, system Spatial Audio and Head Tracking **off**.
- **Steps.**
  1. Start the demo route. The pills should show "Beacon N%" and "Head tracked".
  2. Turn body and cane until the click goes silent.
  3. Press **Recenter** → "Recentered.".
  4. With the body still, turn the head 60° left, then 60° right.
  5. Turn body and cane 90° right.
  6. Blindfold: from 4 random orientations, the walker points the cane at the click.
- **Expect.**
  - Silent within ±10° of the target, rising linearly to full volume at 90°.
  - Clicks at 2.5/s (400 ms period), ducked to 30 % while speech plays.
  - Head left → click moves right. Before step 3, head turns change nothing (§0.7).
- **Pass.**
  - Correct ear **10/10** across body and head turns.
  - Silent zone 20 ± 10° wide (turn slowly, read a compass app on a second phone).
  - Pointing error ≤ 30° in 4/4.
  - With Motion denied or non-Pro AirPods: the pill says "Compass only" and body turns are still
    correct.
- **Auto-recenter (on W2).** `recenter` {auto:true} within ≤ 30 s of walking straight after WP2,
  WP3, WP5 and WP8, and **never** within 15 m after WP4, WP6 or WP7.
- **Log.** `recenter`; beacon volume isn't logged, so screen-record.

### D10 AirPods connect and disconnect: bench, route running · Aritro
- **Steps.**
  - (a) Put both AirPods in the case and close it.
  - (b) Put them back in.
  - (c) Take one AirPod out.
  - (d) Control Center → output → iPhone speaker.
  - (e) Start a route with no headphones.
- **Expect.**
  - (a) and (d): "Headphones disconnected. Beacon paused." from the phone speaker; pills "Beacon
    paused" / "No AirPods"; speech carries on through the speaker.
  - (b): "\<name\> connected."; head tracking restarts and a recenter is pending.
  - (c): record what happens (the route usually stays A2DP, so no line).
  - (e): "No headphones. Beacon paused until AirPods connect.". The HFP (call) route counts as no
    headphones.
- **Pass.**
  - Each change of state is spoken exactly once, within ≤ 2 s.
  - The beacon pill shows "Beacon N%" ≤ 3 s after reconnecting.
  - One click loop, not two. No crash.
- **Log.** One `audioroute` per change of state; `route` start `headphones` field.

### D11 Watch: bench · Aarav wears it, Aritro runs the phone
- **Prerequisites.** The watch app has been opened once and Health allowed. The phone's Watch card
  shows **Reachable**.
- **Steps and expected results.**
  - (a) Watch card Left, Right, Cross, Arrive → `.directionUp`, `.directionDown`, `.notification`,
    `.success`.
  - (b) Wrist down with the screen off for 30 s, 2 min and 5 min, then send each test cue. The
    walking `HKWorkoutSession` keeps haptics alive.
  - (c) Route running, then watch **Repeat, Next, Describe, Recenter**. Each gives a `.click` and
    the phone answers: Repeat = line + distance; Next = the skipped waypoint's own line; Describe =
    "Describing." …; Recenter = "Recentered.".
  - (d) Crown: a brisk turn of **≥ 3 detents within 1 s** → Next. A slow turn (1 detent/s for 6 s)
    → nothing. Two brisk turns 0.5 s apart → one Next (0.8 s debounce).
  - (e) Turn on "Mirror obstacle cues to the watch" and put a hand in front of the LiDAR. Left
    `.start`, right `.stop`, center `.click`, head `.failure`, at most 1 per second per kind.
  - (f) Kill the phone app and press a watch button → `.retry` + "Phone not reachable".
  - (g) **Version skew**: after every `make run`, press Repeat on the watch during a route. "Update
    the phone app" + `.retry` means the phone build is older than the watch, so reinstall. Also
    check Watch app → CaneKit is updated.
- **Pass.**
  - (a) Aarav names 8/8 blind.
  - (b) 12/12 taps felt wrist-down.
  - (c) 4/4 commands; phone speech ≤ 1.5 s after the tap.
  - (d) 5/5 brisk, 0/6 slow, no double fire.
  - (e) Wrist tap ≤ 300 ms after the phone buzz (film both).
  - (f) 3/3.
  - (g) Never shows "Update the phone app".
- **Log.** `watch` {command: nextWaypoint|describe|recenter|repeatLast} and {test}; `navcue`;
  `route` start `watch:true`.

### D12 GPS fences, veer, passed-by, turn settle, arrival: W2 · Aarav walks, Aritro films, Sagar spots

Expected per waypoint (JSON radii; "2r" = the zone around the current waypoint where veer is muted
and passed-by can arm):

| WP | r / 2r (m) | Line on entry (first words) | Wrist | Beacon after entry |
|---|---|---|---|---|
| 1 door | 15 / 30 | "Leaving Townsend Hall…" (second time) | none | silent: curved leg to WP2 |
| 2 Illinois sidewalk | 15 / 30 | "Illinois Street sidewalk. Turn right…" | turnRight (+41°) | holds 225.6° until released, then west |
| 3 Goodwin | 12 / 24 | "Goodwin Avenue. Intersection. Turn right to face north…" | turnRight (+92°) | holds 266.7° until within 6 m of the corner, or receded 6 m on 2 fixes (+4 s), or facing within 30° of 358.5°, or 25 s moving |
| 4 Green St | 15 / 30 | "Green Street. Crossing…" | crossing | **silent** until 2 stationary fixes ≤ 10 m from the node, then north |
| 5 mid-Goodwin | 15 / 30 | "Halfway up Goodwin…" | none | north |
| 6 Springfield | 12 / 24 | "Springfield Avenue. Turn left to face west. Crossing Goodwin…" | crossing | silent until the curb, then west |
| 7 Mathews | 15 / 30 | "Mathews Avenue. Crossing…" | crossing | silent until the curb, then west |
| 8 CIF path | 12 / 24 | "CIF is ahead on your left. Turn left…" | none (−27.6°) | holds 265° until released, then SW |
| 9 CIF east door | 20 / — | "You have arrived…" + "… meters, N minutes, S steps." | arrived | beacon stops; Live Activity ends after 60 s |

Every wrist cue in the table is also felt on the cane as the matching buzz pattern (§0.11).

- **Deliberate veer.** On Goodwin, 50–90 m north of Green St (outside WP5's 30 m zone, after the
  turn has settled), walk 45° off toward the building side, **never the road**, for 6 s at normal
  pace.
  - Expect: "Veer left." or "Veer right." (correct side) after the error has been above **25° for
    3 s**, plus the matching wrist tap. No second veer within **10 s**.
  - Veer is muted when accuracy > 20 m, speed ≤ 0.5 m/s, the fix is older than 5 s, a turn is
    settling, the leg is curved, you're within 2r of the current waypoint, or you're still inside
    the fence of the corner just reached. Walking (> 0.7 m/s), veer is judged on the 15 m smoothed
    course, whose history resets at each waypoint and after each veer cue, so a corrected veer
    doesn't fire again when the 10 s cooldown ends.
- **Arrival hint.** Stand still inside WP9's zone (fence + accuracy/2, at most 40 m) without arrival
  firing, e.g. under the entrance overhang. After 20 s: "You are close to the CIF east entrance. Keep
  going toward it, or press Next to finish." once. It needs no new GPS fixes (the 10 Hz clock
  checks it), and a normal walking approach never hears it.
- **Pass.**
  - All 9 waypoints are reported in order (fence entry, skip-ahead or passed-by), ≥ 7/9 by fence
    entry.
  - Turn lines (WP2, WP3, WP8) start **no later than 5 m past the corner** (spotter marks the spot).
  - **0 "Veer" on normal walking**, including the first 15 m after WP2, WP3 and WP6; the
    deliberate veer fires correctly within 5 s, once.
  - "GPS weak" ≤ 1, and always followed by "GPS back.".
  - Arrival fires while the walker is ≤ 25 m (paced) from the CIF east door, never before WP8.
  - Arrival summary distance within ±15 % of 1,025 m; steps shown.
  - GPS p50 ≤ 10 m, p90 ≤ 20 m.
- **Log.** Fence script; jq navigation-words line; GPS stats; `navcue` sequence equal to the e2e
  `clean` list.

### D13 Live Activity: bench + W2 · Aritro
- **Steps.**
  1. Settings → CaneKit → Live Activities on.
  2. Start the demo route and lock the phone for 20 s (LiDAR stops; accept that for this test).
  3. Unlock, go to the Home Screen for 10 s and look at the Dynamic Island.
  4. On W2, lock twice about 20 m apart, and once after WP2.
  5. On arrival, watch the lock screen. Also test Stop route.
- **Expect.** The instruction matches the Guide card. Distance updates are grouped to a waypoint
  change or a change of ≥ 10 m. The glyph kind changes after a wrist cue. On arrival it shows
  arrived and ends after 60 s. Stop → "Route ended".
- **Pass.**
  - Two locks 20 m apart show different distances.
  - The glyph changes after WP2 and WP4.
  - The activity is gone ≤ 70 s after arrival.
  - Exactly 1 activity after Start → Stop → Start.
- **Log.** Not logged; take screenshots.

### D14 Thermal and battery over 20 min: W2, unplugged · Sagar, Aritro
- **Setup.**
  - Battery ≥ 80 %, clamp on, route running, AirPods and watch in use.
  - Brightness: run 1 at the demo setting. Run 2 (on W3) at minimum with Auto-Brightness **off**.
    The screen never locks during a route (the idle timer is disabled).
- **Pass.**
  - Thermal ≤ `fair` for all 20 min (0 `serious` samples).
  - Battery drop **≤ 12 points** in 20 min (the README budget is 3–4 h, i.e. 8–11 per 20 min).
  - At 20 min `lanes` is still continuous at 2 Hz and the tiles update (fps is no longer on screen).
  - "Engine OK" throughout; no "AR interrupted".
- **If `serious`.** Expect "Phone is hot. Door and wall names and sign reading paused." once,
  "Mesh classification off (thermal)", and the obstacle names, sign reading and hazard watch to
  stop, while lanes and haptics continue (§0.8).
- **Log.** The thermal/battery jq line (one row per minute).

### D15 Phone call and Siri: bench, route running · Aritro calls from another phone
- **Steps.** During a waypoint line:
  - (a) incoming call, declined after 5 s;
  - (b) answer, talk 20 s, hang up;
  - (c) "Hey Siri, what time is it?";
  - (d) a call during a crossing's silent turn-settle.
- **Expect.**
  - The current line is put back in the queue. Lines said during the call wait and play after the
    interruption ends (or after a 15 s fallback) **if their 12 s TTL hasn't run out**. After a 20 s
    call, expect to need Repeat.
  - The beacon goes silent when the interruption begins and restarts afterwards (3 retries, 1 s
    apart).
  - AirPods may switch to HFP for the call, giving "Headphones disconnected…" and later "…
    connected.". That's expected.
- **Pass.**
  - Speech resumes ≤ 3 s after the call or Siri ends.
  - Beacon pill "Beacon N%" ≤ 5 s after.
  - The "Speaking" pill doesn't stick. The route isn't lost.
  - Write down which lines were dropped.
- **Log.** `audioroute` flips; `speech` after the call ends.
- **Demo rule.** A Focus that silences calls is on, so this test only proves recovery.

### D16 Screen lock and Guided Access: bench · Aritro, Sagar
- **Steps.**
  - (a) Route running: lock the phone for 60 s while approaching a wall. Then unlock.
  - (b) Settings → Accessibility → Guided Access on, set a passcode. In CaneKit triple-click → Options:
    **Side Button off, Volume Buttons off, Touch off, Keyboards off, Motion on, no time limit** →
    Start.
  - (c) Rub a palm over the screen for 10 s. Press the side, volume, Action and Camera Control
    buttons.
  - (d) Use all 4 watch buttons.
  - (e) Exit (triple-click + passcode).
- **Expect.**
  - (a) While locked: no obstacle cues, but `gps`, speech, beacon and wrist cues continue. After
    unlocking, "Depth OK". Turn the phone to a different view while it is locked, then press
    **Where am I** right after unlocking: the pre-lock frame was dropped, so it waits (≤ 3 s) for a
    fresh camera frame and describes the new view, never the one from before the lock ("Camera
    warming up. Try again." if no frame comes).
  - (c) No state change. Record whether the Action button's "Where am I" works under Guided Access.
  - (d) The watch commands work. The watch is the only input during the walk.
- **Pass.**
  - (a) During the lock, `gps` events are ≥ 0.5 Hz and `lanes` stop. After unlocking, `lanes` resume
    within ≤ 3 s, and the Where am I sentence describes the new view, 2/2.
  - (c) 0 `route` stop, 0 extra `waypoint`, all toggles unchanged.
  - (e) Exit takes ≤ 10 s.
- **Clamp (Sagar).** Knock the cane 10× against a post. The jaws must never press the side, volume,
  Action or Camera Control buttons. Side + volume held starts Emergency SOS, so fix the clamp rather
  than turning SOS off.
- **Log.** The gap in `lanes` = the lock; `gps` stays continuous.

### D17 Where am I with a key: bench + W2 · Aritro
- **Prerequisites.** VLM keys (`VLM_PROVIDER`, `CUSTOM_*` for Muse 1.3, or another provider) are in
  `Secrets.plist` **before** the build. Settings → Action Button → Shortcut → **Where am I**.
- **Steps.** Wi-Fi off, cellular only:
  - (a) Guide "Where am I" 5× in the lobby, on the sidewalk, at a crossing and at the CIF door;
  - (b) watch Describe 2×;
  - (c) Action button from the lock screen 2×, then 1× cold (kill the app first);
  - (d) airplane mode 1×;
  - (e) on W2, Hazards card → "Hazard watch" on (off by default) for one segment.
- **Expect.**
  - "Describing." right away, then one sentence under 20 words with clock-face directions.
  - A cold launch waits ≤ 3 s for a camera frame, otherwise "Camera warming up. Try again.".
  - A cloud failure (no network, bad key, 12 s total timeout) falls back to the on-device describer,
    so offline still gets a sentence; "Scene description failed." only when that fails too. Any
    route or obstacle line cuts in over a description.
  - (e) Every 8 s while walking: the cloud gets 2.5 s per frame, then the on-device model answers. A reply about a frame older than ~4 m of walking (min(5 s, 4 m ÷ speed)) is
    dropped; one older than 2 s keeps the hazard but loses its distance ("Caution: cones ahead.").
- **Pass.**
  - Median from the press to the first word of the description: **≤ 6 s on Wi-Fi, ≤ 10 s on LTE**.
  - ≥ 4/5 descriptions name a correct salient object with no invented hazard.
  - Cold Action button: sentence ≤ 12 s.
  - Offline: an on-device sentence (or the spoken error) ≤ 15 s and the app still responds.
  - (e) No "Caution:" line describes a hazard already behind the walker (spotter checks the video).
- **Log.** `describe` {provider} only; the text and latency come from the video. Hazard watch:
  `hazard` {source: vision}.

### D18 Cold launch permissions: bench, run first · Aritro
- **Steps.**
  1. Pull the old logs. Delete CaneKit. This also deletes the logs, the voice cache and the mount
     toggles, so redo D1's settings afterwards.
  2. `make run`, trust the developer if asked, and launch.
  3. At launch: the Camera prompt, then Location. Choose **While Using** and keep **Precise on**.
  4. First "Start demo route": the Motion & Fitness prompt and the Health sheet.
  5. On the watch: open CaneKit → Health prompt.
  6. Kill the app and relaunch.
  7. Denial drill: deny Motion once. Then turn Location off for CaneKit, type a destination and
     press Go.
- **Pass.**
  - Each prompt appears once, and nothing blocks the Guide screen after it's answered.
  - 0 prompts on relaunch.
  - The GPS pill shows "±N m", not "Denied" or kilometre-level accuracy (that means Precise is off).
  - "Head tracked" after allowing Motion. The Live Activity appears at route start.
  - Motion denied → "Compass only" and the beacon still pans. Re-enable under Privacy → Motion &
    Fitness.
  - Location off + Go → refused at once (no 15 s wait for a fix): the error line "Location is off
    for CaneKit" and "Location access is off. Turn on Location for CaneKit in Settings to
    navigate." Turn Location back on (While Using, Precise).
  - The trip log starts with `start` {lidar:true, mesh:true, haptics:true}.

---

## 3. Failure injection and stress

**F1 Bad GPS under trees and beside Wardall (12 floors)**: W3 · Aarav, Aritro
- **Inject.** Stand 60 s under the tree stretches marked on W1, walk 50 m under them, then stand
  next to the tower on the plaza.
- **Expect.**
  - The pill turns amber above 15 m.
  - If accuracy is above 20 m for ≥ 10 s: "GPS weak. Waypoint cues paused until it recovers." once.
    Fences and veer pause, and the target falls back to the recorded leg bearing.
  - "GPS back." on the first fix ≤ 20 m.
  - A fence missed during the outage is recovered by skip-ahead ("Passed one waypoint." + the real
    line) or by passed-by ("Passed \<place\>. \<Next\> in N meters.").
- **Pass.**
  - While accuracy is above 20 m: 0 false waypoints and 0 "Veer".
  - "GPS back." ≤ 5 s after accuracy recovers.
  - Each missed waypoint is recovered within 3 good moving fixes after leaving its 2r zone.

**F2 Standing at curbs**: WP4 (signalized), WP6, WP7 · Aarav, Sagar spots
- **Inject.** Stop at the curb for 90 s, turn the head toward traffic both ways, keep the cane still,
  shuffle 1–2 m.
- **Expect.** The crossing line and the `.notification` tap on entry. The beacon stays silent
  ("Listen for traffic") until **2 consecutive stationary fixes ≤ 10 m from the node**, then clicks
  point across the street. No veer (speed ≤ 0.5), no waypoint advance (speed gate), no
  auto-recenter within 15 m after the crossing. With "Detect drop-offs" on, the curb is announced
  once ("Drop-off ahead, …" + 4 heavy taps), then at most every 30 s while it stays in the same
  place, and again when you shuffle 1 m closer.
- **Pass.** During the 90 s: **0 `waypoint`, 0 "Veer", 0 auto `recenter`**, and at most 4 ground
  hazard lines plus one per 1 m shuffle (`hazard` {source: ground}). Once released, the click
  points across the street within ±30° (pointing test). The first auto-recenter comes ≥ 15 m past the
  node. If W1 measured the curb more than 10 m from the node, record which release fired: heading or
  25 s of moving.

**F3 Sweeping the cane fast while walking**: W3 or a corridor · Aarav
- **Inject.** Five approaches to a wall at 0.8 m/s with a normal sweep, then 5 with a fast sweep.
- **Expect.** Cues only on trusted frames (sweep reversals). The heading behind the beacon also
  freezes while untrusted.
- **Pass.**
  - Normal sweep: the first centre cue comes at ≥ 1.2 m in 5/5 (≥ 1 s of warning).
  - Fast sweep: record the first-cue distance. If it's below 0.8 m in ≥ 2/5, the walker brief
    becomes "slow two-point touch".
  - Blind pointing at the beacon while sweeping: error ≤ 45°.

**F4 Bright sun on the LiDAR**: 12:30–13:30 CDT · Sagar, Aritro
- **Inject.** A sunlit wall, pole and sign board at 0.5, 1.0, 1.5 and 2.0 m, then the same in shade.
  Then 60 s pointed at open sunlit sidewalk and sky.
- **Expect.** Confidence drops, and cells with fewer than 8 valid samples read clear (−1). The
  failure mode is a missed warning, not a false one.
- **Pass.**
  - 1.0 m in full sun reads 0.8–1.2 m in ≥ 8/10 `lanes` samples.
  - Record the largest distance that still reads; that number goes in the pitch.
  - 0 head or centre cues in the open-space minute.

**F5 30 min continuous (heat)**: W3 unplugged, in the sun · Sagar, Aritro
- **Setup.** As D14, but ≥ 30 min, ending with 5 min standing in the sun at CIF.
- **Pass.**
  - 0 `serious` samples at ambient ≤ 30 °C.
  - Battery drop ≤ 18 points.
  - `lanes` continuous at 2 Hz at 30 min, "Engine OK" throughout, no ARKit interruption.
- **If it gets hot.** Fit a sun shade (Sagar), use minimum brightness, turn screen recording off. If
  it still reaches `serious`: keep the phone in shade until T-0, and the walk starts ≤ 5 min after
  leaving a cool room.

**F6 AirPods battery dying**: W3 · Aritro
- **Inject.** Mid-leg, put both AirPods in the case for 60 s, then put them back. If you have a
  pair below 10 %, run once with it to check the low-battery chime against speech.
- **Expect.** As D10: speech from the phone speaker on the cane, beacon paused. On reconnect,
  "\<name\> connected." and a recenter is pending.
- **Pass.**
  - The walker hears 2/2 lines from the speaker at arm's length over traffic. Media volume must
    already be ≥ 75 %.
  - Beacon back ≤ 3 s after reconnect.
  - A recenter (auto or manual) happens before the next turn.

**F7 Watch out of range or asleep**: W3 + bench · Aarav
- **Inject.** (a) Watch airplane mode for 60 s mid-route. (b) Swipe the watch app away. (c) Bench:
  carry the phone 30 m away from the watch.
- **Expect.**
  - Phone guidance is unaffected.
  - Wrist cues sent while the watch is unreachable are **dropped**, not queued.
  - The status line (application context) arrives when the watch wakes.
  - Watch buttons give `.retry` + "Phone not reachable".
  - At route start with the watch app not in front: "Watch not reachable. Open CaneKit on the
    watch.".
- **Pass.** Current instruction on the watch ≤ 10 s after reconnect; buttons work ≤ 10 s after
  reconnect; 0 phone-side errors.

**F8 Airplane mode (no network)**: one W3 segment · Aritro
- **Inject.** Airplane mode on, Bluetooth back on, before starting a segment of ≥ 3 waypoints.
- **Expect.**
  - GPS still works (unassisted, so the first fix may be slower).
  - Cached lines use the ElevenLabs voice and misses use the system voice.
  - Where am I → an on-device sentence (Vision + Apple's on-device model, or the template when
    Apple Intelligence is off); the hazard watch, if on, also runs on-device.
  - A typed destination → "Could not build a route…".
- **Pass.** GPS ≤ 15 m within 60 s outdoors; ≥ 3 waypoints fully guided; no hang; Where am I works
  again after airplane mode goes off.

**F9 Low Power Mode**: one W3 segment, 5 min · Aritro
- **Inject.** Low Power Mode on for 5 minutes of walking. The app doesn't detect it.
- **Measure.** `gps` events per minute (about 60 expected), `lanes` rate (fps is no longer on
  screen).
- **Pass (informational).** If `lanes` drops below 2 Hz or GPS below 30 fixes/min, "Low Power Mode off"
  stays a hard rule (it already is). iOS pops a Low Power prompt at 20 % battery, so never start a
  walk below 40 %.

**F10 Accidental screen taps**: bench + 2 min walking · Sagar, Aarav
- **Inject.** 20 palm brushes plus 2 min walking with the cane brushing a jacket. Once without
  Guided Access, once with it (Touch off).
- **Expect.** Without Guided Access, Stop route (no confirmation), Next, Silence haptics, Mirror and
  the beacon toggle are all unprotected (open item in `todo.md`).
- **Pass.** With Guided Access: **0** state changes (no `route` stop, no waypoint jump, toggles
  unchanged). Without: record the count; that's the argument for keeping Guided Access mandatory.

**F11 Two routes back to back**: bench · Aritro
- **Steps.** Start → 30 s → Stop → Start → Next ×9 to arrival → Repeat → Start → Stop.
- **Expect.**
  - One click loop (the beacon graph is built once).
  - The trip timer restarts from 0.
  - One Live Activity.
  - Stop clears the queue.
  - Repeat after arrival says the arrival line plus the summary.
- **Pass.**
  - Clicks in 10 s: **25 ± 2** (50 would mean two loops). Wear AirPods and face ≥ 90° away from the
    target so the beacon is at full volume.
  - 1 Live Activity on the lock screen.
  - `route` start and stop events pair up.
  - The summary's minutes reflect the second route only.

**F12 Killing the app mid-route**: W3 at WP5 + bench drill · Aritro, spotter
- **Inject.** Swipe the app away, or let a crash happen. Relaunch from the Home Screen.
- **Expect.**
  - The old log is complete up to ≤ 2 s before the kill (it flushes every 2 s and on background).
  - A new log file starts, and "CaneKit ready." plays.
  - **No route is running.**
  - The old Live Activity may stay on the lock screen; swipe it away.
  - Guided Access has to be armed again. The watch workout keeps running.
- **Recovery drill.** Start demo route, then press **Next** once for each waypoint already passed.
  Walker stands still. Lines older than 12 s drop out of the queue; press Repeat once it's quiet.

  | Last waypoint passed | 2 Illinois sw | 3 Goodwin | 4 Green | 5 mid | 6 Springfield | 7 Mathews | 8 CIF path |
  |---|---|---|---|---|---|---|---|
  | Press Next | 2 | 3 | 4 | 5 | 6 | 7 | 8 |

  With network, an alternative is to type "Campus Instructional Facility" → **Go**. That builds a
  MapKit route from the current fix, waiting up to 15 s for a first fix.
- **Pass.** Relaunch to correct guidance ≤ 45 s (spotter times it). The screen and watch name the
  correct next waypoint. The old log parses.

---

## 4. Blindfolded walk: go/no-go checklist and spotter protocol

**Go/no-go.** Read aloud at T-15 by Aritro. Every item must pass. One miss → **sighted demo only**
(walker's eyes open, narrating the cues) or the W2 backup video.

| # | Check | Pass value | Who |
|---|---|---|---|
| G1 | The build | The same build that passed W2 today; `make test` + `make e2e` green on its commit; installed ≤ 6 days ago (the free-team profile lasts 7 days) | Aritro |
| G2 | GPS at the ISR canopy (outdoor side) | Pill ≤ ±15 m (green) **continuously for 30 s**. The app's gate is 20 m; 15 leaves margin. | Aritro |
| G3 | LiDAR as clamped for the walk | Wall at 1 m reads **0.8–1.2 m in all 6 tiles**; open space → 0 cues for 30 s | Sagar |
| G4 | Head height | Hand or board overhead → double-hit re-fires; "Head height." spoken once | Sagar |
| G5 | Beacon (plaza, ≥ 40 m from the door) | After Recenter: body 90° right → click in the left ear; head left → click moves right; pill "Head tracked" | Aarav |
| G6 | Watch | Card says "Reachable"; after 30 s wrist-down a Cross test tap is felt | Aarav |
| G7 | Repeat on the watch | The last line again + "Next, \<place\>, in N meters." ≤ 1.5 s | Aarav |
| G8 | Arrival evidence | Today's W2 log: 9/9 waypoints, 0 false "Veer", arrival ≤ 25 m (paced) from the CIF east door | Aritro |
| G9 | Power and heat | Phone ≥ 80 % at T-15 (hard floor 40 %) with the power bank connected; thermal `nominal`/`fair`; AirPods ≥ 60 %; watch ≥ 50 % | Sagar |
| G10 | Phone settings | Guided Access armed (Touch, Side, Volume off); Focus silencing calls; Low Power off; AirPods **Transparency** on (the walker must hear traffic), Spatial Audio + Head Tracking off; media volume ≥ 75 %; "Write trip log" on | Aritro |
| G11 | People and conditions | Walker, spotter and filmer assigned; kill word "Stop" rehearsed 3× (walker frozen within 1 step each time); crossing protocol rehearsed; dry; start before 18:15 CDT | Sagar |

**Spotter protocol.** Sagar is the spotter.
- **Positions.** The spotter stays within arm's reach (≤ 1 m), half a step behind on the **traffic
  side**. The filmer walks 3–5 m behind and never speaks to the walker.
- **Blindfold.** A sleep mask the walker can pull off with one hand. The walker may take it off at
  any time.
- **"Stop"** means freeze with the cane still; the spotter puts a hand on the walker's upper arm,
  says what the hazard is, then "Go". **"Abort"** means the mask comes off and the solo walk ends.
- **Crossings (WP4 Green St, WP6 Goodwin at Springfield, WP7 Mathews).** The app never says when to
  cross.
  1. The walker stops at the curb.
  2. The spotter presses the push button and judges the signal and the traffic.
  3. The spotter says "Clear, go" and guides the walker across (walker holds the spotter's elbow).
  4. The walker goes solo again on the far curb.
- **Call "Stop" for anything the cane won't catch in time.** Bikes and scooters, construction,
  drop-offs, branches, or any obstacle within 1 m that hasn't cued. Otherwise the spotter gives
  **no** directions, or the demo isn't honest. The filmer logs every intervention (time + reason).
- **Abort criteria.** Any one of these ends the solo walk:
  - the walker drifts within 1 m of a road edge away from a crossing;
  - "GPS weak" lasts more than 60 s;
  - 60 s of walking with no click and no speech;
  - the app crashes and F12 recovery takes more than 45 s;
  - thermal reaches `serious`;
  - ≥ 3 "Stop" calls in one leg;
  - the walker asks.
- **The spotter carries** the Guided Access passcode, a charged power bank, this run sheet and the
  F12 Next table.

---

## 5. Demo day run sheet (T-60 to the walk)

| T | Who | Action | Check |
|---|---|---|---|
| −60 | Aritro | Same build as W2. Charge the phone. Relaunch the app so a new log starts. | Files → On My iPhone → CaneKit shows a new `canekit-….jsonl` |
| −60 | Sagar | Clamp: torque, no contact with any button, LiDAR window wiped, sun shade on. Power bank ≥ 80 %, cable can't snag. | Knock test: 0 button presses |
| −55 | Aarav | AirPods ≥ 60 %: Transparency, Spatial Audio off, Head Tracking off. Watch ≥ 50 %, Wrist Detection on. | — |
| −50 | Aritro | Focus silencing calls; Low Power off; Bluetooth + Wi-Fi on; media volume ≥ 75 %; Live Activities on; Location Precise on; Auto-Brightness off, brightness low | — |
| −45 | Aritro | Warm the voice cache: Start demo route indoors on Wi-Fi, wait 60 s, Stop | Voice pill "ElevenLabs" on the intro |
| −40 | Sagar + Aarav | Bench: 4 test haptics named blind through the grip; wall at 1 m; hand at the left edge; board overhead | 4/4; tiles 0.8–1.2 m; Left tiles; head hit + "Head height." (G3, G4) |
| −35 | Aarav | AirPods in; open CaneKit on the watch | "\<name\> connected."; Watch card "Reachable"; Cross tap felt (G6) |
| −30 | All | Out onto the plaza ≥ 40 m from the canopy. Start demo route, Recenter, body and head checks, watch Repeat. Then Stop. Phone stays in shade. | G5, G7 pass |
| −25 | Aritro | Stand at the canopy (WP1, outdoor side) | GPS ≤ ±15 m for 30 s (G2). Still above 20 m at −15 → no-go |
| −20 | Sagar | Spotter brief: positions, "Stop" / "Abort", crossing protocol, abort list. Kill-word drill 3×. | Walker frozen within 1 step, 3/3 |
| −15 | Aritro | Read G1–G11 aloud; record GO / NO-GO with the time | NO-GO → sighted demo or backup video |
| −10 | Aritro | Second phone starts filming (clap to sync). Optional screen recording on the CaneKit phone. **Start demo route** (the trip timer starts now). Arm Guided Access. | Intro plays; no channel warning follows (all channels up) |
| −5 | Aarav + Sagar | Mask on, spotter in position, walker says "ready". Stand still until the intro ends. | — |
| 0 | All | Walk on the spotter's "Go" | Checkpoints: WP2 ~2 min · WP3 ~5 · WP4 ~9 (+signal) · WP6 ~15 (+signal) · WP7 ~19 · WP8 ~22 · arrival ~24 (20–30) |
| +1 after arrival | Aritro | Stop filming, exit Guided Access, pull the log, run the fence script | Arrival summary heard; log saved |

**In-walk recovery:**

| Symptom | Action |
|---|---|
| App crash or kill | Relaunch → Start demo route → Next × (last waypoint passed; F12 table) → re-arm Guided Access. More than 45 s → abort. |
| AirPods die | Carry on: speech comes from the cane speaker and there's no beacon. The spotter decides. |
| Watch not reachable | Raise the wrist or open the app. Not a reason to stop. |
| "GPS weak" for more than 60 s | Abort the solo walk; sighted guide to the next waypoint. |
| Wrong or stale instruction | Watch **Repeat**. If still wrong, crown 3 detents (Next). |
| Silence (no speech, no click) for more than 30 s while walking | Watch Repeat. Still nothing → abort. |
| "Phone is hot. Door and wall names and sign reading paused." (thermal `serious`) | Finish the current leg and abort at the next safe point. |
