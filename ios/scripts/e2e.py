#!/usr/bin/env python3
"""
e2e.py — end-to-end GPS replay of the demo route through the REAL app in the iOS simulator.

For each scenario it: boots the simulator, pre-grants location/motion, installs the built app,
parks the simulated GPS at the Townsend Hall door, launches CaneKit with CANEKIT_DEMO_ROUTE=1
(the app starts the bundled ISR → CIF route on its own), feeds a scenario path through
`xcrun simctl location start`, waits for arrival (or a timeout), then reads the app's JSONL trip
log (Documents/canekit-*.jsonl, written by TripLogger) and asserts on what the app actually said
and did: waypoint order, wrist cues, veer cues, "Passed …" lines, arrival, trip summary.

Nothing here needs LiDAR, haptics, AirPods or a watch — it exercises navigation, speech
decisions, the route file and the log. Run from ios/:

    make e2e                                   # all scenarios on the iPhone 17 Pro Max simulator
    scripts/e2e.py --scenario clean            # one scenario
    scripts/e2e.py --sim "iPhone 17 Pro Max" --speed 4 --scenario all

Scenarios (see SCENARIOS below):
    clean         walk through every waypoint                → 9 waypoints in order, exact wrist cues, no veer
    missed_fence  pass Illinois St 22 m wide, skip CIF path  → "Passed …" lines, still arrives
    gps_jitter    clean path with ±6 m noise on every fix    → still arrives, at most 3 veer cues
    wrong_turn    overshoot west at Goodwin, then come back  → at least one "Veer right.", still arrives
    streetview    clean path with Google Street View frames as the camera (FrameReplay,
                  CANEKIT_FRAME_DIR=scripts/streetview; frames are local-only), the hazard watch on
                  and "Where am I" asked at the start and every waypoint → passes like clean, and
                  every corner gets a described sentence; the report lists per-corner descriptions,
                  sign-scan text and hazard-watch replies. Not in "all" (needs the git-ignored
                  JPEGs); run with --scenario streetview.
    indoor_isr    (Step 66) CANEKIT_INDOOR_ROUTE=1 + CANEKIT_INDOOR_SIM_STEPS_PER_S=3 with the GPS
                  parked at the ISR door → indoor `advanced` in order, one `exit`, one `handover`, then
                  `route start` (the app's own walk simulator takes over there; the run stops).
    stress_<walk> (Step 66) a trace from scripts/stress/traces/<walk>.json (OpenStreetMap foot routing,
                  scripts/stress/build_routes.py), densified to one simulator tick per vertex, AR(1)
                  jitter (--jitter-m, --seed) and --dropouts GPS gaps of --gap-s seconds; a
                  non-bundled route is loaded through CANEKIT_ROUTE_FILE. Asserts: route start with the
                  route's waypoint count, arrival, waypoint indices strictly ascending, the arrival fix
                  ≤ 25 m from the last waypoint, ≤ --max-lines-per-min spoken lines, no identical
                  consecutive lines, no field_kind. stress_all = every trace. Not in "all".
    --trace FILE  the stress checks for any trace JSON (or a GPX track, walked on the bundled route).

Exit status 0 only if every requested scenario passes. Reports + copied logs: build/e2e/.
Requires a simulator build first (`make sim`); the Makefile's e2e target does that.

Run it **alone**: the scenarios are real-time GPS replays, so another xcodebuild / simulator job
on the same device starves the app and the assertions then describe a walk that never happened
(`gps_median_dt` in the report, and the "GPS replay starved" warning, say when that happened).
"""
# Owner / callers: `make e2e` (ios/Makefile; builds `make sim` and runs `sim-grant` first), or by hand
# from ios/. Part of the per-change gate in AGENTS.md "How we engineer" §4; CI does not run it.
# Python 3 stdlib only; needs Xcode's `xcrun simctl` and a booted-or-bootable iOS simulator.
# Why it exists (Step 11): unit tests cannot see what the whole app says on a walk; this replays the
# demo route through the real NavigationEngine / SpeechQueue / TripLogger and asserts on the log.
# Tests: none of its own — its assertions ARE the test; a scenario's failures and non-failing
# warnings land in build/e2e/report.json.
# App contracts it depends on (renaming any of these breaks it, usually as a false FAIL):
#   env hooks  CANEKIT_DEMO_ROUTE (AppModel.start → startDemoRoute), CANEKIT_MUTE (SpeechQueue.muted),
#              CANEKIT_FRAME_DIR (FrameReplay), CANEKIT_DESCRIBE_EVERY_WAYPOINT
#              (AppModel.describeEveryWaypoint), CANEKIT_HAZARD_WATCH (AppModel.wireHazards),
#              CANEKIT_ROUTE_FILE (RouteSource.bundled, Step 66), CANEKIT_INDOOR_ROUTE +
#              CANEKIT_INDOOR_SIM_STEPS_PER_S (IndoorGuide.attach / simulate)
#   indoor     indoor{action: start | advanced | exit | handover, index} (IndoorGuide.log)
#   log kinds  route{action}, waypoint{index}, navcue{cue}, arrived, speech{text}, gps, cue{cue},
#              hazard{type,text,source}, describe_result{frame,text,error,ms,labels,vision_error},
#              scan{frame,texts}, hazard_watch{frame,reply,said,dropped,error}; and TripLogRecord's
#              `field_t` / `field_kind` collision columns (any one fails the run)
#   route file route_isr_cif.json with 9 waypoints whose ids 2, 3 and 8 the scenarios move
# ⚠ The `clean` wrist-cue list and the 1..9 waypoint list in `check` are pinned to the route file;
# edit them with it (and RouteTests.shippedRouteFileIsConsistent).

from __future__ import annotations

import argparse
import json
import math
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ios/ — every path below is absolute from here, so the script runs from any working directory.
IOS = Path(__file__).resolve().parent.parent
ROUTE = IOS / "CaneKit/Resources/route_isr_cif.json"
# The product of `make sim` (DERIVED = build, CONFIG Debug). A device build (`make build`) lands in
# Debug-iphoneos instead and does not satisfy this.
APP = IOS / "build/Build/Products/Debug-iphonesimulator/CaneKit.app"
# Report (report.json) and one copied trip log per scenario (<name>.jsonl); git-ignored with build/.
OUT = IOS / "build/e2e"
BUNDLE = "com.aritro.canekit"
# frames.json (committed) + the git-ignored Street View JPEGs; handed to the app as CANEKIT_FRAME_DIR.
STREETVIEW = IOS / "scripts/streetview"
# Step 66 stress campaign: traces/*.json + routes/*.json from scripts/stress/build_routes.py.
STRESS = IOS / "scripts/stress"
# The bundled ISR indoor draft that CANEKIT_INDOOR_ROUTE=1 starts (its step count and exit are read).
INDOOR_ISR = IOS / "CaneKit/Resources/indoor_isr.json"
# Mean Earth radius in metres (same spherical model as CaneKitLogic's GeoMath haversine).
EARTH = 6_371_000.0


# MARK: - geometry (metres ↔ degrees near the campus; plenty accurate over 1 km)

# Flat-earth displacement: fine for the tens of metres the scenarios move a point. Degrees in and out.
def offset(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    """Move a coordinate by metres north / east."""
    dlat = north_m / EARTH * 180 / math.pi
    dlon = east_m / (EARTH * math.cos(math.radians(lat))) * 180 / math.pi
    return lat + dlat, lon + dlon


# (lat, lon) degrees → metres. Used for path length, densify spacing and the arrival time budget.
def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Haversine distance in metres."""
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH * math.asin(min(1, math.sqrt(h)))


# Linear interpolation in degrees (not great-circle), each segment split into floor(len / step_m)
# equal parts (at least 1), so spacing is ≥ step_m. Keeps every original vertex. Caller: gps_jitter.
def densify(points: list[tuple[float, float]], step_m: float) -> list[tuple[float, float]]:
    """Insert points every `step_m` along each segment (so jitter can be applied per fix)."""
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        n = max(1, int(dist(a, b) // step_m))
        for i in range(1, n + 1):
            t = i / n
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


# Total polyline length in metres; printed per scenario and stored as `path_m` in the report.
def path_length(points: list[tuple[float, float]]) -> float:
    return sum(dist(a, b) for a, b in zip(points, points[1:]))


# MARK: - scenarios

# The bundled route's waypoint dicts (`id`, `lat`, `lon`, …) in file order — the same file the app
# loads for CANEKIT_DEMO_ROUTE, so a moved waypoint moves the replay with it.
def load_waypoints() -> list[dict]:
    return json.loads(ROUTE.read_text())["waypoints"]


# Builds every scenario's path (ordered (lat, lon) vertices fed to `simctl location start`). `seed`
# makes gps_jitter reproducible (`--seed`, default 7). ⚠ Indexes P[0..8] and ids 2 / 3 / 8 assume
# the 9-waypoint route file; a route with a different count raises IndexError / KeyError here.
# Dict order matters: `main` runs "all" in this insertion order (streetview excluded).
def scenario_paths(wps: list[dict], seed: int) -> dict[str, list[tuple[float, float]]]:
    """Each scenario = a list of GPS points from the Townsend door to CIF."""
    P = [(w["lat"], w["lon"]) for w in wps]
    by_id = {w["id"]: (w["lat"], w["lon"]) for w in wps}

    clean = list(P)

    # Illinois St sidewalk (WP2) passed 22 m to the south-east — outside its 15 m fence, inside
    # 2× radius — and the CIF path corner (WP8) skipped by cutting 28 m north of it.
    wide2 = offset(*by_id[2], north_m=-16, east_m=15)
    wide8 = offset(*by_id[8], north_m=28, east_m=0)
    missed = [P[0], wide2, P[2], P[3], P[4], P[5], P[6], wide8, P[8]]

    rng = random.Random(seed)
    jitter = [offset(lat, lon, rng.uniform(-6, 6), rng.uniform(-6, 6))
              for (lat, lon) in densify(clean, 5)]
    jitter[0], jitter[-1] = P[0], P[-1]          # start at the door, end at the entrance

    # At Goodwin (WP3) keep walking west 60 m, stand, then come back and continue north.
    over = offset(*by_id[3], north_m=0, east_m=-60)
    wrong = [P[0], P[1], P[2], over, P[2], P[3], P[4], P[5], P[6], P[7], P[8]]

    return {"clean": clean, "missed_fence": missed, "gps_jitter": jitter, "wrong_turn": wrong,
            "streetview": list(P)}


# MARK: - stress traces (Step 66)

# Walk names with a trace file (scripts/stress/traces/<walk>.json), sorted — the `stress_<walk>` choices.
def stress_names() -> list[str]:
    return sorted(p.stem for p in (STRESS / "traces").glob("*.json"))


# A trace: JSON {name, route, points: [[lat, lon], …]} (route = "bundled" or a path relative to ios/),
# or a GPX track (every <trkpt>, walked on the bundled route).
def load_trace(path: Path) -> dict:
    if path.suffix.lower() == ".gpx":
        import re
        pts = []
        for tag in re.findall(r"<trkpt\b[^>]*>", path.read_text()):
            lat = re.search(r'lat="([-0-9.]+)"', tag)
            lon = re.search(r'lon="([-0-9.]+)"', tag)
            if lat and lon:
                pts.append((float(lat.group(1)), float(lon.group(1))))
        return {"name": path.stem, "route": "bundled", "points": pts}
    doc = json.loads(path.read_text())
    doc["points"] = [tuple(p) for p in doc["points"]]
    return doc


# The waypoint dicts of a trace's route ("bundled" = route_isr_cif.json).
def route_waypoints(route: str) -> list[dict]:
    return json.loads((ROUTE if route == "bundled" else IOS / route).read_text())["waypoints"]


# Seconds `simctl location start --interval=1` spends on a path: at least one tick per segment.
def ticks(points: list[tuple[float, float]], speed: float) -> int:
    return sum(max(1, math.ceil(dist(a, b) / speed)) for a, b in zip(points, points[1:]))


def perturb(points: list[tuple[float, float]], seed: int, jitter_m: float, speed: float,
            dropouts: int) -> tuple[list[list[tuple[float, float]]], dict]:
    """A replayable, seeded version of a trace: densified to `speed` metres per vertex (one simulator
    tick each, so the walk keeps its speed), AR(1) Gaussian jitter (ρ 0.7, σ `jitter_m`, first and last
    point pinned) and `dropouts` cut points between 15 % and 85 % of the walk. Returns the segments
    (consecutive segments share their cut vertex) and a summary for the report. Same arguments →
    identical output (`random.Random(seed)`, no clock)."""
    rng = random.Random(seed)
    dense = densify(points, max(1.0, speed))
    rho, n, e, out = 0.7, 0.0, 0.0, []
    for i, (lat, lon) in enumerate(dense):
        n = rho * n + math.sqrt(1 - rho * rho) * rng.gauss(0, jitter_m)
        e = rho * e + math.sqrt(1 - rho * rho) * rng.gauss(0, jitter_m)
        out.append((lat, lon) if i in (0, len(dense) - 1) else offset(lat, lon, n, e))
    cuts = sorted({rng.randint(int(len(out) * 0.15), int(len(out) * 0.85)) for _ in range(dropouts)}) \
        if dropouts > 0 and len(out) > 20 else []
    segments, start = [], 0
    for c in cuts:
        if c - start >= 2:
            segments.append(out[start:c + 1])
            start = c
    segments.append(out[start:])
    return segments, {"seed": seed, "jitter_m": jitter_m, "vertices": len(out), "cuts": cuts,
                      "max_offset_m": round(max(dist(a, b) for a, b in zip(dense, out)), 1)}


# MARK: - simulator plumbing

# Run a command, return stripped stdout. `check=True` raises RuntimeError with stderr (or stdout) on a
# non-zero exit — inside `main`'s try that becomes the scenario's "harness error". `check=False` is
# used for idempotent cleanup (boot, terminate, clear) whose failure means "already in that state".
def sh(*args: str, check: bool = True, capture: bool = True) -> str:
    r = subprocess.run(list(args), capture_output=capture, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {r.stderr.strip() or r.stdout.strip()}")
    return (r.stdout or "").strip()


# First AVAILABLE simulator with this exact name under any iOS runtime (so with two iOS runtimes
# installed the pick follows simctl's JSON order). Exits with "Create it: make sim17" when absent.
def udid_for(name: str) -> str:
    devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    for runtime, devs in devices.items():
        if "iOS" not in runtime:
            continue
        for d in devs:
            if d["name"] == name:
                return d["udid"]
    raise SystemExit(f"No available iOS simulator named '{name}'. Create it: make sim17")


# Boot (ignored if already booted), block until the device is ready, pre-grant location and motion
# so no permission alert covers the app — the same grants as the Makefile's `sim-grant`.
def prepare(udid: str) -> None:
    sh("xcrun", "simctl", "boot", udid, check=False)
    sh("xcrun", "simctl", "bootstatus", udid, "-b")
    for service in ("location", "motion"):
        sh("xcrun", "simctl", "privacy", udid, "grant", service, BUNDLE, check=False)


# The installed app's data container on the Mac's disk (its Documents/ holds the trip logs).
def container(udid: str) -> Path:
    return Path(sh("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))


# This run's trip log: the newest Documents/canekit-*.jsonl modified at or after `after` − 2 s
# (`after` = wall-clock launch time; 2 s of slack for file-system timestamp granularity), or None.
def newest_log(udid: str, after: float) -> Path | None:
    docs = container(udid) / "Documents"
    logs = [p for p in docs.glob("canekit-*.jsonl") if p.stat().st_mtime >= after - 2]
    return max(logs, key=lambda p: p.stat().st_mtime) if logs else None


# Parse the JSONL log (TripLogger flushes every 2 s while the app runs, so this is re-read in polls).
def read_events(log: Path) -> list[dict]:
    events = []
    for line in log.read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass                                  # a half-written last line while the app runs
    return events


def launch_and_wait_for_route(udid: str, attempts: int = 3, extra_env: dict[str, str] | None = None) -> float:
    """Launch with the demo-route hook and wait until the log shows `route start`.

    The simulator occasionally drops a launch that races the previous process's teardown (seen
    once: a session line and nothing else), so relaunch up to `attempts` times.
    Returns the launch wall-clock time used to find this run's log.
    """
    for attempt in range(1, attempts + 1):
        started = time.time()
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE],
                       env={**os.environ, "SIMCTL_CHILD_CANEKIT_DEMO_ROUTE": "1", "SIMCTL_CHILD_CANEKIT_MUTE": "1",
                            **(extra_env or {})},
                       capture_output=True, text=True, check=True)
        deadline = time.time() + 20
        while time.time() < deadline:
            time.sleep(1)
            log = newest_log(udid, started)
            if log and any(e.get("kind") == "route" and e.get("action") == "start" for e in read_events(log)):
                time.sleep(4)                     # route intro before moving
                return started
        print(f"  (launch {attempt}: route did not start, retrying)", flush=True)
    raise RuntimeError("app never started the demo route (CANEKIT_DEMO_ROUTE hook)")


# One scenario end to end: terminate + clear GPS, reinstall the build, park GPS on the first vertex,
# launch (streetview adds the frame-dir, describe-every-waypoint and hazard-watch env), replay the path
# at `speed` m/s, poll every 5 s for `arrived` (+6 s for the trip summary) or the time budget, clean up
# and copy the log into OUT. Returns `events` (possibly empty), `seconds` (wall clock from launch,
# including the post-arrival wait), `log` (container path or None) and `path_m`. It never asserts;
# `check` does. Raises (via `sh` / launch) on install or launch failure.
def run_scenario(udid: str, name: str, points: list[tuple[float, float]], speed: float,
                 route_file: str | None = None, segments: list[list[tuple[float, float]]] | None = None,
                 gap_s: float = 0.0, log_name: str | None = None) -> dict:
    # Step 66: `route_file` → CANEKIT_ROUTE_FILE (a non-bundled route through the demo hook);
    # `segments` replays the path in pieces with `gap_s` seconds of no GPS between them (a dropout:
    # simctl stops sending fixes when a path ends); `log_name` names the copied log.
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    sh("xcrun", "simctl", "location", udid, "clear", check=False)
    sh("xcrun", "simctl", "install", udid, str(APP))
    sh("xcrun", "simctl", "location", udid, "set", f"{points[0][0]},{points[0][1]}")
    extra = {}
    if name == "streetview":
        extra["SIMCTL_CHILD_CANEKIT_FRAME_DIR"] = str(STREETVIEW)
        extra["SIMCTL_CHILD_CANEKIT_DESCRIBE_EVERY_WAYPOINT"] = "1"
        extra["SIMCTL_CHILD_CANEKIT_HAZARD_WATCH"] = "1"
    if route_file:
        extra["SIMCTL_CHILD_CANEKIT_ROUTE_FILE"] = route_file
    started = launch_and_wait_for_route(udid, extra_env=extra)
    segs = segments or [points]
    for i, seg in enumerate(segs):
        coords = [f"{lat:.7f},{lon:.7f}" for lat, lon in seg]
        sh("xcrun", "simctl", "location", udid, "start", f"--speed={speed}", "--interval=1", *coords)
        if i < len(segs) - 1:
            time.sleep(ticks(seg, speed) + gap_s)

    # simctl spends at least one --interval tick on every vertex, so a densified path (gps_jitter:
    # ~5 m segments) takes far longer than length / speed (review round 5: it could never arrive).
    budget = ticks(segs[-1], speed) + 75
    deadline = time.time() + budget
    log: Path | None = None
    events: list[dict] = []
    while time.time() < deadline:
        time.sleep(5)
        log = log or newest_log(udid, started)
        if log:
            events = read_events(log)
            if any(e.get("kind") == "arrived" for e in events):
                time.sleep(6)                     # let the trip summary line land
                events = read_events(log)
                break
    sh("xcrun", "simctl", "location", udid, "clear", check=False)
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)

    OUT.mkdir(parents=True, exist_ok=True)
    if log:
        shutil.copy(log, OUT / f"{log_name or name}.jsonl")
    return {"events": events, "seconds": round(time.time() - started), "log": str(log) if log else None,
            "path_m": round(path_length(points))}


def run_indoor(udid: str, log_name: str = "indoor_isr") -> dict:
    """Step 66 `indoor_isr`: GPS parked at the ISR door, launch with CANEKIT_INDOOR_ROUTE=1 and
    CANEKIT_INDOOR_SIM_STEPS_PER_S=3 (no demo-route hook), wait for the handover's `route start`
    (IndoorGuide feeds 5 m fixes at the exit itself), 6 s more, stop. One relaunch when no indoor walk
    started within 25 s (the same dropped-launch race as launch_and_wait_for_route)."""
    ex = json.loads(INDOOR_ISR.read_text())["exit"]
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    sh("xcrun", "simctl", "location", udid, "clear", check=False)
    sh("xcrun", "simctl", "install", udid, str(APP))
    sh("xcrun", "simctl", "location", udid, "set", f"{ex['lat']},{ex['lon']}")
    env = {**os.environ, "SIMCTL_CHILD_CANEKIT_INDOOR_ROUTE": "1", "SIMCTL_CHILD_CANEKIT_INDOOR_SIM_STEPS_PER_S": "3",
           "SIMCTL_CHILD_CANEKIT_MUTE": "1"}
    events: list[dict] = []
    log: Path | None = None
    started = time.time()
    for attempt in (1, 2):
        started = time.time()
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE],
                       env=env, capture_output=True, text=True, check=True)
        deadline, begun = time.time() + 180, False
        while time.time() < deadline:
            time.sleep(2)
            log = newest_log(udid, started)
            events = read_events(log) if log else []
            begun = begun or any(e.get("kind") == "indoor" and e.get("action") == "start" for e in events)
            if not begun and time.time() - started > 25:
                break
            handed = [e["t"] for e in events if e.get("kind") == "indoor" and e.get("action") == "handover"]
            if handed and any(e.get("kind") == "route" and e.get("action") == "start" and e["t"] >= handed[0]
                              for e in events):
                time.sleep(6)
                events = read_events(log)
                break
        if begun:
            break
        print(f"  (launch {attempt}: indoor walk did not start, retrying)", flush=True)
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    OUT.mkdir(parents=True, exist_ok=True)
    if log:
        shutil.copy(log, OUT / f"{log_name}.jsonl")
    return {"events": events, "seconds": round(time.time() - started), "log": str(log) if log else None, "path_m": 0}


# MARK: - assertions

# Text of every caller-written `speech` record, in log order (not `speech_dispatch`: e2e asserts on
# what the app decided to say, which is what AppModel logs as `speech`).
def speech(events: list[dict]) -> list[str]:
    return [e.get("text", "") for e in events if e.get("kind") == "speech"]


# Wrist cues sent to the watch, in order (`NavCue.rawValue`: turnLeft / turnRight / crossing / arrived).
def navcues(events: list[dict]) -> list[str]:
    return [e.get("cue", "") for e in events if e.get("kind") == "navcue"]


# Report-only, never asserted: the simulator has no LiDAR, so obstacle cues are not expected there.
def obstacle_cues(events: list[dict]) -> list[str]:
    """Obstacle cue records (`kind: cue`); the cue itself is in the `cue` field (it used to be a
    `kind` field that overwrote the record kind, so these records were invisible)."""
    return [e.get("cue", "") for e in events if e.get("kind") == "cue"]


# Report-only list of announced hazards; no scenario asserts on it.
def hazards(events: list[dict]) -> list[dict]:
    """Announced hazards (`kind: hazard`): `type` (dropOff / sign / vision …), `text`, `source`.
    Before the 2026-09-11 fix the app wrote the type as `kind`, replacing "hazard", so this list
    was always empty."""
    return [{"type": e.get("type", ""), "text": e.get("text", ""), "source": e.get("source", "")}
            for e in events if e.get("kind") == "hazard"]


# Asserted in every scenario by `check` (a non-empty list is a failure).
def reserved_collisions(events: list[dict]) -> list[dict]:
    """Records where a caller passed a field named `t` or `kind`: TripLogger keeps the record's
    own and writes the caller's as `field_t` / `field_kind`. Any hit is an app bug."""
    return [e for e in events if "field_kind" in e or "field_t" in e]


def fix_cadence(events: list[dict]) -> tuple[int, float, float, float]:
    """GPS fixes the app logged: count, median gap, largest gap, and the span they cover (seconds).

    The replay feeds one fix per second (`--interval=1`), so anything else means the app or the
    simulator was starved — almost always a second xcodebuild / simulator job on the same device.
    Every assertion below then describes a walk that never really happened (seen on 2026-09-11:
    `wrong_turn` reported "no arrival (last waypoint index 3)" and no veer cue while a UI-test run
    shared the simulator; alone it arrives in 296 s with the veer).

    Three numbers, because one is not enough. A run starved *in the middle* keeps a healthy median
    — the same 2026-09-11 session produced a `clean` run whose median was 1.01 s and which still
    failed with "no arrival (last waypoint index 5)", because its 141 fixes covered only 141 s of
    a 340 s run: the app was starved in long stretches, not uniformly slowed. So `check` also
    compares the **span** against the scenario's wall-clock seconds, and watches the largest gap.
    Healthy reference (four scenarios, 2026-09-11, machine idle): median 1.01 s, max 6.5-6.9 s
    (simctl pauses an interval at every path vertex), span within 4% of the run.
    """
    ts = [e["t"] for e in events if e.get("kind") == "gps" and isinstance(e.get("t"), (int, float))]
    if len(ts) < 3:
        return len(ts), 0.0, 0.0, 0.0
    gaps = sorted(b - a for a, b in zip(ts, ts[1:]))
    return len(ts), round(gaps[len(gaps) // 2], 2), round(gaps[-1], 2), round(ts[-1] - ts[0], 1)


# Module-level so `check` can append without a return value. ⚠ `main` clears it only after
# `run_scenario` returns, so when a scenario raises (harness error) the previous scenario's warnings
# are copied into this scenario's report entry and printed again.
warnings: list[str] = []   # non-failing notes for the report (reset per scenario in main)


# The pass criteria. Every scenario: route started, arrived, waypoint indices ascending, trip summary
# spoken ("kilometers" or "meters,"), no field_t / field_kind collision; plus the starved-replay warning.
# clean / streetview: waypoints exactly 1..9, wrist cues exactly `want`, no "Veer…", no "Passed…".
# missed_fence: ≥ 1 "Passed …" and none built from a sentence. gps_jitter: ≤ 3 "Veer…".
# wrong_turn: ≥ 1 "Veer right.". streetview also: ≥ 8 answered describes, ≥ 6 distinct described
# frames, ≥ 5 distinct scanned frames, ≥ 1 clean hazard-watch reply. `seconds` = run_scenario's wall
# clock (0 disables the span test).
def check(name: str, events: list[dict], seconds: float = 0.0) -> list[str]:
    """Return a list of failures (empty = pass). Non-failing notes go to `warnings`."""
    fails: list[str] = []
    said = speech(events)
    cues = navcues(events)
    wp_idx = [e.get("index") for e in events if e.get("kind") == "waypoint"]
    veers = [s for s in said if s.startswith("Veer")]
    passed = [s for s in said if s.startswith("Passed")]
    arrived = any(e.get("kind") == "arrived" for e in events)

    if not any(e.get("kind") == "route" and e.get("action") == "start" for e in events):
        fails.append("route never started (CANEKIT_DEMO_ROUTE hook?)")
    if not arrived:
        fails.append(f"no arrival (last waypoint index {wp_idx[-1] if wp_idx else None})")
    # Say out loud when the run itself was starved — whatever it did or did not assert, so a
    # contended simulator is never read as a navigation bug (see fix_cadence). A starved run can
    # also arrive and merely lose a cue, so this is not inside the `not arrived` branch.
    fixes, median_dt, max_dt, span = fix_cadence(events)
    # Uniformly slow (median), stalled for a stretch (max gap), or simply absent for most of the
    # run (span vs elapsed) — a run can be starved in any of the three ways and only the last one
    # caught the 2026-09-11 `clean` failure. `seconds` includes launch and the post-arrival wait,
    # so a healthy span is ~96% of it; 60% is comfortably clear of that and of any simctl pause.
    starved = (median_dt > 1.5 or fixes < 30 or max_dt > 15
               or (seconds > 0 and span < 0.6 * seconds))
    if starved:
        warnings.append(f"GPS replay starved: {fixes} fixes, median {median_dt} s apart, largest "
                        f"gap {max_dt} s, covering {span} s of a {seconds} s run (the replay feeds "
                        "1/s) — was another xcodebuild / simulator job using this device? Re-run "
                        "the scenario alone before believing anything above")
    if wp_idx != sorted(wp_idx):
        fails.append(f"waypoints out of order: {wp_idx}")
    if arrived and not any("kilometers" in s or "meters," in s for s in said):
        fails.append("arrival trip summary was not spoken")
    collisions = reserved_collisions(events)
    if collisions:
        fails.append(f"{len(collisions)} log records had a field named 't' or 'kind' (first: {collisions[0]})")

    if name in ("clean", "streetview"):
        if wp_idx != list(range(1, 10)):
            fails.append(f"expected waypoints 1..9, got {wp_idx}")
        # WP2 +41° and WP3 +92° turns, crossings at WP4/6/7, arrival (WP8's −28° is under the 30° cue
        # threshold). Veer cues also send turnLeft/turnRight, so a clean path must have none.
        want = ["turnRight", "turnRight", "crossing", "crossing", "crossing", "arrived"]
        got = cues
        if veers:
            fails.append(f"unexpected veer cues on the clean path: {veers}")
        if got != want:
            fails.append(f"wrist cues {got} != {want}")
        if passed:
            fails.append(f"unexpected 'Passed' lines: {passed}")
    elif name == "missed_fence":
        if not passed:
            fails.append("expected at least one 'Passed …' line")
        if any(s.startswith("Passed CIF is") or s.startswith("Passed Illinois Street sidewalk.") for s in passed):
            fails.append(f"passed-by used a sentence instead of a waypoint name: {passed}")
    elif name == "gps_jitter":
        if len(veers) > 3:
            fails.append(f"{len(veers)} veer cues under jitter (max 3): {veers}")
    if name == "streetview":
        described = [e for e in events if e.get("kind") == "describe_result"]
        good = [e for e in described if e.get("text")]
        if len(good) < 8:
            errs = sorted({e.get("error", "") for e in described if e.get("error")})
            fails.append(f"only {len(good)} of {len(described)} 'Where am I' requests answered "
                         f"(want ≥ 8 of 10: start + 9 waypoints); errors: {errs}")
        # The camera must actually move along the route (Muse, Step 12: a stuck nearest frame or a
        # dead hazard watch would otherwise still pass).
        described_frames = {e.get("frame") for e in good if e.get("frame")}
        if len(described_frames) < 6:
            fails.append(f"'Where am I' saw only {len(described_frames)} distinct Street View frames (want ≥ 6)")
        scan_frames = {e.get("frame") for e in events if e.get("kind") == "scan" and e.get("frame")}
        if len(scan_frames) < 5:
            fails.append(f"sign scans saw only {len(scan_frames)} distinct frames (want ≥ 5): is FrameReplay following the GPS?")
        # Scene labels cannot come from the simulator ("Failed to create espresso context"): say so
        # in the report instead of letting "Nothing recognized ahead." look like camera coverage.
        if described and all(not e.get("labels") for e in described):
            errs = sorted({(e.get("vision_error") or "")[:60] for e in described})
            warnings.append("no scene labels in any description (simulator limit?): " + "; ".join(errs)
                            + " -- scene words are covered by vision_probe.swift on the Mac and the phone")
        clean = [e for e in events if e.get("kind") == "hazard_watch"
                 and e.get("reply") and not e.get("error") and not e.get("dropped")]
        if not clean:
            fails.append("no clean hazard-watch reply (all errored, dropped or missing; CANEKIT_HAZARD_WATCH=1 should turn it on)")
    elif name == "wrong_turn":
        if not any(v == "Veer right." for v in veers):
            fails.append(f"expected 'Veer right.' after overshooting west at Goodwin, got {veers}")
    return fails


def check_stress(events: list[dict], wps: list[dict], max_lpm: float) -> tuple[list[str], dict]:
    """Step 66 invariants for a trace replay, on top of `check`. Returns (failures, metrics)."""
    fails: list[str] = []
    starts = [e for e in events if e.get("kind") == "route" and e.get("action") == "start"]
    arrived = [e for e in events if e.get("kind") == "arrived"]
    idx = [e.get("index") for e in events if e.get("kind") == "waypoint"]
    if starts and starts[0].get("waypoints") != len(wps):
        fails.append(f"route start has {starts[0].get('waypoints')} waypoints, the route file {len(wps)} "
                     "(CANEKIT_ROUTE_FILE not honoured?)")
    if any(b <= a for a, b in zip(idx, idx[1:])):
        fails.append(f"waypoint indices not strictly ascending: {idx}")
    arrival_m = None
    if arrived:
        fixes = [e for e in events if e.get("kind") == "gps" and e.get("t", 0) <= arrived[0]["t"]]
        if fixes:
            arrival_m = round(dist((fixes[-1]["lat"], fixes[-1]["lon"]), (wps[-1]["lat"], wps[-1]["lon"])), 1)
            if arrival_m > 25:
                fails.append(f"arrived {arrival_m} m from the last waypoint (max 25)")
    lines = [e for e in events if e.get("kind") == "speech" and not e.get("repeat")]
    t0 = starts[0]["t"] if starts else 0.0
    t1 = arrived[0]["t"] if arrived else (events[-1].get("t", t0) if events else t0)
    walk = [e for e in lines if t0 <= e.get("t", 0) <= t1]
    lpm = round(len(walk) / max(1.0, (t1 - t0) / 60), 2)
    if lpm > max_lpm:
        fails.append(f"{lpm} spoken lines per minute on the walk (max {max_lpm})")
    # Identical consecutive lines with no waypoint advance between them (two different waypoints may
    # legitimately share a line: unnamed OSM footpaths all read "Turn left onto the path.").
    exempt_consecutive = {"Head height.", "Close.", "Veer left.", "Veer right."}
    dups, last, advanced = [], None, False
    for e in events:
        if e.get("kind") == "waypoint":
            advanced = True
        elif e.get("kind") == "speech" and not e.get("repeat"):
            txt = e.get("text")
            if txt == last and not advanced and txt not in exempt_consecutive:
                dups.append(last)
            last, advanced = txt, False
    if dups:
        fails.append(f"identical consecutive lines: {dups[:3]}")
    said = [e.get("text", "") for e in lines]
    metrics = {"walk_s": round(t1 - t0, 1), "lines": len(walk), "lines_per_min": lpm, "arrival_m": arrival_m,
               "veers": sum(s.startswith("Veer") for s in said), "passed": sum(s.startswith("Passed") for s in said),
               "gps_weak": sum("GPS" in s for s in said), "duplicates": len(dups)}
    return fails, metrics


def check_indoor(events: list[dict]) -> tuple[list[str], dict]:
    """Step 66 `indoor_isr`: indoor start, `advanced` never backwards and ending on the last step, exactly
    one `exit` and one `handover` in that order, then `route start`; no field_kind. (IndoorGuide logs the
    mirrored step index, so two advances in one pedometer update log the same index twice — allowed.)"""
    fails: list[str] = []
    steps = len(json.loads(INDOOR_ISR.read_text())["steps"])
    ind = [e for e in events if e.get("kind") == "indoor"]
    first = lambda action: next((e["t"] for e in ind if e.get("action") == action), None)
    adv = [e.get("index") for e in ind if e.get("action") == "advanced"]
    t_start, t_exit, t_hand = first("start"), first("exit"), first("handover")
    route_after = [e["t"] for e in events if e.get("kind") == "route" and e.get("action") == "start"
                   and t_hand is not None and e["t"] >= t_hand]
    if t_start is None:
        fails.append("no indoor start (CANEKIT_INDOOR_ROUTE hook?)")
    if any(b < a for a, b in zip(adv, adv[1:])) or (adv and adv[-1] != steps - 1) or any(not 1 <= i < steps for i in adv):
        fails.append(f"indoor steps out of order: advanced {adv} for {steps} steps")
    for action in ("exit", "handover"):
        n = sum(e.get("action") == action for e in ind)
        if n != 1:
            fails.append(f"{n} indoor {action} records (want 1)")
    if None not in (t_start, t_exit, t_hand) and not t_start <= t_exit <= t_hand:
        fails.append(f"indoor order wrong: start {t_start}, exit {t_exit}, handover {t_hand}")
    if not route_after:
        fails.append("no route start after the handover")
    collisions = reserved_collisions(events)
    if collisions:
        fails.append(f"{len(collisions)} log records had a field named 't' or 'kind'")
    metrics = {"advanced": adv, "t_start": t_start, "t_exit": t_exit, "t_handover": t_hand,
               "t_route_start": route_after[0] if route_after else None,
               "handover_by": next((e.get("by") for e in ind if e.get("action") == "handover"), None)}
    return fails, metrics


# MARK: - main

# CLI entry; returns the process exit status (0 only if every requested scenario passed). Refuses to
# start without the simulator build or, for streetview, frames.json. Scenarios run sequentially on one
# simulator, each isolated by try / except / finally; report.json is deleted up front and rewritten
# after every scenario so a crash never leaves a stale PASS.
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", default="iPhone 17 Pro Max")
    ap.add_argument("--scenario", default="all",
                    choices=["all", "clean", "missed_fence", "gps_jitter", "wrong_turn", "streetview", "indoor_isr",
                             "stress_all"] + [f"stress_{n}" for n in stress_names()])
    ap.add_argument("--trace", type=Path, help="Step 66: replay this trace JSON / GPX with the stress checks")
    ap.add_argument("--speed", type=float, default=4.0, help="m/s (4 keeps each run ~4 min)")
    ap.add_argument("--seed", type=int, default=7, help="gps_jitter noise; stress jitter and dropout positions")
    ap.add_argument("--jitter-m", type=float, default=3.0, help="stress: AR(1) jitter σ, metres (0 = none)")
    ap.add_argument("--dropouts", type=int, default=2, help="stress: GPS gaps inserted into the replay")
    ap.add_argument("--gap-s", type=float, default=20.0, help="stress: seconds of each GPS gap")
    ap.add_argument("--max-lines-per-min", type=float, default=15.0, help="stress: spoken-line cap on the walk")
    ap.add_argument("--report", type=Path, default=OUT / "report.json", help="where report.json is written")
    args = ap.parse_args()

    if not APP.exists():
        raise SystemExit(f"{APP} missing — run `make sim` first")
    paths = scenario_paths(load_waypoints(), args.seed)
    # "all" = the four GPS scenarios; streetview needs local-only frames, indoor_isr and the stress
    # traces are Step 66's campaign — all three are opt-in.
    if args.trace:
        names = [f"trace_{args.trace.stem}"]
    elif args.scenario == "all":
        names = [n for n in paths if n != "streetview"]
    elif args.scenario == "stress_all":
        names = [f"stress_{n}" for n in stress_names()]
    else:
        names = [args.scenario]
    if "streetview" in names and not (STREETVIEW / "frames.json").exists():
        raise SystemExit(f"{STREETVIEW}/frames.json missing — capture frames per scripts/streetview/README.md")
    udid = udid_for(args.sim)
    prepare(udid)

    OUT.mkdir(parents=True, exist_ok=True)
    report_path = args.report
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.unlink(missing_ok=True)          # never leave a stale PASS behind a crashed run
    report = {"sim": args.sim, "udid": udid, "speed": args.speed, "seed": args.seed, "scenarios": {}}
    ok = True
    for name in names:
        extra: dict = {}
        trace = None
        if name.startswith("stress_") or name.startswith("trace_"):
            trace = load_trace(args.trace if args.trace else STRESS / "traces" / f"{name[len('stress_'):]}.json")
            segments, extra["perturbation"] = perturb(trace["points"], args.seed, args.jitter_m, args.speed, args.dropouts)
            extra["route"] = trace["route"]
            flat = [p for i, s in enumerate(segments) for p in (s if i == 0 else s[1:])]
            path_m = path_length(flat)
        else:
            path_m = path_length(paths[name]) if name in paths else 0
        print(f"▶ {name}: {path_m:.0f} m at {args.speed} m/s (seed {args.seed}) …", flush=True)
        try:
            warnings.clear()
            if name == "indoor_isr":
                res = run_indoor(udid)
                fails, extra["indoor"] = check_indoor(res["events"])
            elif trace is not None:
                wps = route_waypoints(trace["route"])
                route_file = None if trace["route"] == "bundled" else str(IOS / trace["route"])
                res = run_scenario(udid, name, flat, args.speed, route_file=route_file, segments=segments,
                                   gap_s=args.gap_s, log_name=f"{name}-s{args.seed}")
                fails = check(name, res["events"], res["seconds"] - args.gap_s * (len(segments) - 1))
                more, extra["stress"] = check_stress(res["events"], wps, args.max_lines_per_min)
                fails += more
            else:
                res = run_scenario(udid, name, paths[name], args.speed)
                fails = check(name, res["events"], res["seconds"])
        except Exception as e:                   # one bad launch must not abort the other scenarios
            res = {"events": [], "seconds": 0, "path_m": round(path_m)}
            fails = [f"harness error: {e}"]
        finally:
            sh("xcrun", "simctl", "location", udid, "clear", check=False)
            sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
        ok &= not fails
        fixes, median_dt, max_dt, span = fix_cadence(res["events"])
        report["scenarios"][name] = {
            "pass": not fails, "failures": fails, "warnings": list(warnings),
            "seconds": res["seconds"], "path_m": res["path_m"],
            # Cadence of the replay as the app saw it: ~1 fix/s covering the whole run is
            # healthy; see fix_cadence for what each number catches.
            "gps_fixes": fixes, "gps_median_dt": median_dt,
            "gps_max_dt": max_dt, "gps_span_s": span,
            "waypoints": [e.get("index") for e in res["events"] if e.get("kind") == "waypoint"],
            "navcues": navcues(res["events"]),
            "speech": speech(res["events"]),
            "hazards": hazards(res["events"]),
            "obstacle_cues": obstacle_cues(res["events"]),
            "describes": [{"frame": e.get("frame"), "text": e.get("text"), "error": e.get("error"), "ms": e.get("ms"),
                           "labels": e.get("labels"), "vision_error": e.get("vision_error")}
                          for e in res["events"] if e.get("kind") == "describe_result"],
            "scan_texts": sorted({t for e in res["events"] if e.get("kind") == "scan" for t in e.get("texts", [])}),
            "hazard_watch": [{"frame": e.get("frame"), "reply": e.get("reply"), "said": e.get("said"),
                       "dropped": e.get("dropped"), "error": e.get("error")}
                      for e in res["events"] if e.get("kind") == "hazard_watch"],
            **extra,
        }
        report_path.write_text(json.dumps(report, indent=2))   # after every scenario
        print(("  ✔ PASS" if not fails else "  ✘ FAIL") + f"  ({res['seconds']} s)", flush=True)
        for f in fails:
            print(f"    - {f}")
        for w in warnings:
            print(f"    ! {w}")
    print(f"report: {report_path}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
