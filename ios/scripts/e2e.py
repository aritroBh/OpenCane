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

Exit status 0 only if every requested scenario passes. Reports + copied logs: build/e2e/.
Requires a simulator build first (`make sim`); the Makefile's e2e target does that.
"""

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

IOS = Path(__file__).resolve().parent.parent
ROUTE = IOS / "CaneKit/Resources/route_isr_cif.json"
APP = IOS / "build/Build/Products/Debug-iphonesimulator/CaneKit.app"
OUT = IOS / "build/e2e"
BUNDLE = "com.aritro.canekit"
STREETVIEW = IOS / "scripts/streetview"
EARTH = 6_371_000.0


# MARK: - geometry (metres ↔ degrees near the campus; plenty accurate over 1 km)

def offset(lat: float, lon: float, north_m: float, east_m: float) -> tuple[float, float]:
    """Move a coordinate by metres north / east."""
    dlat = north_m / EARTH * 180 / math.pi
    dlon = east_m / (EARTH * math.cos(math.radians(lat))) * 180 / math.pi
    return lat + dlat, lon + dlon


def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Haversine distance in metres."""
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH * math.asin(min(1, math.sqrt(h)))


def densify(points: list[tuple[float, float]], step_m: float) -> list[tuple[float, float]]:
    """Insert points every `step_m` along each segment (so jitter can be applied per fix)."""
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        n = max(1, int(dist(a, b) // step_m))
        for i in range(1, n + 1):
            t = i / n
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def path_length(points: list[tuple[float, float]]) -> float:
    return sum(dist(a, b) for a, b in zip(points, points[1:]))


# MARK: - scenarios

def load_waypoints() -> list[dict]:
    return json.loads(ROUTE.read_text())["waypoints"]


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


# MARK: - simulator plumbing

def sh(*args: str, check: bool = True, capture: bool = True) -> str:
    r = subprocess.run(list(args), capture_output=capture, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {r.stderr.strip() or r.stdout.strip()}")
    return (r.stdout or "").strip()


def udid_for(name: str) -> str:
    devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    for runtime, devs in devices.items():
        if "iOS" not in runtime:
            continue
        for d in devs:
            if d["name"] == name:
                return d["udid"]
    raise SystemExit(f"No available iOS simulator named '{name}'. Create it: make sim17")


def prepare(udid: str) -> None:
    sh("xcrun", "simctl", "boot", udid, check=False)
    sh("xcrun", "simctl", "bootstatus", udid, "-b")
    for service in ("location", "motion"):
        sh("xcrun", "simctl", "privacy", udid, "grant", service, BUNDLE, check=False)


def container(udid: str) -> Path:
    return Path(sh("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))


def newest_log(udid: str, after: float) -> Path | None:
    docs = container(udid) / "Documents"
    logs = [p for p in docs.glob("canekit-*.jsonl") if p.stat().st_mtime >= after - 2]
    return max(logs, key=lambda p: p.stat().st_mtime) if logs else None


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


def run_scenario(udid: str, name: str, points: list[tuple[float, float]], speed: float) -> dict:
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    sh("xcrun", "simctl", "location", udid, "clear", check=False)
    sh("xcrun", "simctl", "install", udid, str(APP))
    sh("xcrun", "simctl", "location", udid, "set", f"{points[0][0]},{points[0][1]}")
    extra = {}
    if name == "streetview":
        extra["SIMCTL_CHILD_CANEKIT_FRAME_DIR"] = str(STREETVIEW)
        extra["SIMCTL_CHILD_CANEKIT_DESCRIBE_EVERY_WAYPOINT"] = "1"
        extra["SIMCTL_CHILD_CANEKIT_HAZARD_WATCH"] = "1"
    started = launch_and_wait_for_route(udid, extra_env=extra)
    coords = [f"{lat:.7f},{lon:.7f}" for lat, lon in points]
    sh("xcrun", "simctl", "location", udid, "start", f"--speed={speed}", "--interval=1", *coords)

    # simctl spends at least one --interval tick on every vertex, so a densified path (gps_jitter:
    # ~5 m segments) takes far longer than length / speed (review round 5: it could never arrive).
    budget = sum(max(1, math.ceil(dist(a, b) / speed)) for a, b in zip(points, points[1:])) + 75
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
        shutil.copy(log, OUT / f"{name}.jsonl")
    return {"events": events, "seconds": round(time.time() - started), "log": str(log) if log else None,
            "path_m": round(path_length(points))}


# MARK: - assertions

def speech(events: list[dict]) -> list[str]:
    return [e.get("text", "") for e in events if e.get("kind") == "speech"]


def navcues(events: list[dict]) -> list[str]:
    return [e.get("cue", "") for e in events if e.get("kind") == "navcue"]


def check(name: str, events: list[dict]) -> list[str]:
    """Return a list of failures (empty = pass)."""
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
    if wp_idx != sorted(wp_idx):
        fails.append(f"waypoints out of order: {wp_idx}")
    if arrived and not any("kilometers" in s or "meters," in s for s in said):
        fails.append("arrival trip summary was not spoken")

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
        clean = [e for e in events if e.get("kind") == "hazard_watch"
                 and e.get("reply") and not e.get("error") and not e.get("dropped")]
        if not clean:
            fails.append("no clean hazard-watch reply (all errored, dropped or missing; CANEKIT_HAZARD_WATCH=1 should turn it on)")
    elif name == "wrong_turn":
        if not any(v == "Veer right." for v in veers):
            fails.append(f"expected 'Veer right.' after overshooting west at Goodwin, got {veers}")
    return fails


# MARK: - main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", default="iPhone 17 Pro Max")
    ap.add_argument("--scenario", default="all",
                    choices=["all", "clean", "missed_fence", "gps_jitter", "wrong_turn", "streetview"])
    ap.add_argument("--speed", type=float, default=4.0, help="m/s (4 keeps each run ~4 min)")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    if not APP.exists():
        raise SystemExit(f"{APP} missing — run `make sim` first")
    paths = scenario_paths(load_waypoints(), args.seed)
    # "all" = the four GPS scenarios; streetview needs local-only frames, so it is opt-in.
    names = [n for n in paths if n != "streetview"] if args.scenario == "all" else [args.scenario]
    if "streetview" in names and not (STREETVIEW / "frames.json").exists():
        raise SystemExit(f"{STREETVIEW}/frames.json missing — capture frames per scripts/streetview/README.md")
    udid = udid_for(args.sim)
    prepare(udid)

    OUT.mkdir(parents=True, exist_ok=True)
    report_path = OUT / "report.json"
    report_path.unlink(missing_ok=True)          # never leave a stale PASS behind a crashed run
    report = {"sim": args.sim, "udid": udid, "speed": args.speed, "scenarios": {}}
    ok = True
    for name in names:
        print(f"▶ {name}: {path_length(paths[name]):.0f} m at {args.speed} m/s …", flush=True)
        try:
            res = run_scenario(udid, name, paths[name], args.speed)
            fails = check(name, res["events"])
        except Exception as e:                   # one bad launch must not abort the other scenarios
            res = {"events": [], "seconds": 0, "path_m": round(path_length(paths[name]))}
            fails = [f"harness error: {e}"]
        finally:
            sh("xcrun", "simctl", "location", udid, "clear", check=False)
            sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
        ok &= not fails
        report["scenarios"][name] = {
            "pass": not fails, "failures": fails, "seconds": res["seconds"], "path_m": res["path_m"],
            "waypoints": [e.get("index") for e in res["events"] if e.get("kind") == "waypoint"],
            "navcues": navcues(res["events"]),
            "speech": speech(res["events"]),
            "hazards": [e.get("text", "") for e in res["events"] if e.get("kind") == "hazard"],
            "describes": [{"frame": e.get("frame"), "text": e.get("text"), "error": e.get("error"), "ms": e.get("ms"),
                           "labels": e.get("labels"), "vision_error": e.get("vision_error")}
                          for e in res["events"] if e.get("kind") == "describe_result"],
            "scan_texts": sorted({t for e in res["events"] if e.get("kind") == "scan" for t in e.get("texts", [])}),
            "hazard_watch": [{"frame": e.get("frame"), "reply": e.get("reply"), "said": e.get("said"),
                       "dropped": e.get("dropped"), "error": e.get("error")}
                      for e in res["events"] if e.get("kind") == "hazard_watch"],
        }
        report_path.write_text(json.dumps(report, indent=2))   # after every scenario
        print(("  ✔ PASS" if not fails else "  ✘ FAIL") + f"  ({res['seconds']} s)", flush=True)
        for f in fails:
            print(f"    - {f}")
    print(f"report: {report_path}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
