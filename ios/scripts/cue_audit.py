#!/usr/bin/env python3
"""
cue_audit.py — how loud was that walk? Reads one CaneKit trip log (canekit-*.jsonl) and measures the
cue load a walker actually got, so cue design v2 (docs/cue_design_v2.md) is tuned from evidence, not
from a feeling. Step 35, the "measure first" item of the research's ranked change list.

It answers, from the log alone:
  1. Was the phone on the mount? Camera tilt from `lanes.tilt` vs the 3–8° window (`MountTilt.aim`).
     A handheld walk (the first field log: median 26°) must not be used to tune distances.
  2. Is "head height" an overhang or a wall? For every `lanes` cell with head < 1.5 m, is the torso
     cell of the same lane also near (within 0.5 m → wall / furniture / person, which the cane finds)
     or clearly farther / empty (the overhang signature)?
  3. How much was said and felt? cues per minute by kind, spoken lines per minute by priority,
     unsolicited (not asked-for) lines per minute, suppressed lines by reason.
  4. How choppy? `speech_dispatch` replays (a cut line resumed — mid-line from its clause, or from the
     line start), lines dispatched < 1 s apart, and different-band lines starting < 0.3 s after the
     previous line's `speech_end`.
  5. App bugs: any `field_kind` / `field_t` column (TripLogRecord collision; e2e.py fails on it too).

Run from ios/:
    scripts/cue_audit.py path/to/canekit-2026-09-12T20-57-17Z.jsonl
    scripts/cue_audit.py --pull              # copy the newest log off the phone in local.mk first
    scripts/cue_audit.py --json log.jsonl    # machine-readable
    scripts/cue_audit.py --selftest          # the fixture checks below (no device, no simulator)

The numbers it compares against (1.5 m head, 0.5 m signature gap, 3–8° tilt) are the app's current
constants and the research hypotheses; if those move in CaneKitLogic, move them here too.
Read-only: never writes into the log or the repo.
"""
# Owner / callers: `make audit` in ios/Makefile (runs `--selftest`, then this script on LOG=path or
# `--pull`); by hand from ios/. Nothing in the app or the build imports it. Python 3, stdlib only.
# Why it exists: Step 35's device report ("choppy", "overstimulating") had no numbers behind it; the
# cue design v2 plan (docs/cue_design_v2.md, docs/todo.md) is judged against this script's output
# on a mounted walk (CHANGELOG.md Step 35). Step 37 added the resume / cross-band pause metrics.
# Tests: `selftest()` below (fixture asserts, no device). It is NOT part of `make test` or CI.
# Inputs it depends on (renaming any of these in the app silently zeroes a section): record kinds
# `lanes` (`head`, `torso`, `depth`, `tilt` from TripLogger.lanes), `cue` (field `cue`; Step 41 adds
# `suppressed` = a torso cue the level did not render, `render` = a Standard onset tap), `speech`
# (`text`, `priority`), `speech_suppressed` (`reason`, `load`), `speech_dispatch` (`text`,
# `priority`, `replays`, `resume_from`), `speech_end` (`priority`), and for the hazard sections
# `hazard` (`type`, `source`), `hazard_watch` (`reply`, `error`, `dropped`, `ms`) and `describe_result`
# (`ms`, −1 when unknown), all written by AppModel / TripLogger / HazardScanner; `t` is seconds since
# the TripLogger was created (wall clock) on every record. ⚠ The describe_result section also counts
# `source` / `outcome`, which AppModel.describe_result does not write (it logs `provider`, `gate`,
# `error`, `question`, `frame`), so those counters read only "?" on a real log.

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

# ⚠ Mirrors of app constants — keep in step with the Swift (nothing checks this automatically):
# metres; the head band's enter distance, `CueThresholds.head` (ios/Logic/.../CueDecider.swift).
HEAD_ENTER_M = 1.5            # CueThresholds.head
# metres; torso at least this much farther than head = overhang. A research hypothesis ([H]), not
# an app constant: no Swift code uses it yet.
SIGNATURE_GAP_M = 0.5         # cue design v2 §3.2 overhang signature [H]
# degrees below the horizon (inclusive); `MountTilt.aim` = 3...8 (LaneReport.swift).
MOUNT_AIM_DEG = (3.0, 8.0)    # MountTilt.aim
# seconds, dispatch start to dispatch start; a heuristic for "choppy", not an app constant.
CHOPPY_GAP_S = 1.0            # two dispatches closer than this read as a stutter
# Case-sensitive `str.startswith` prefixes of lines the walker asked for. ⚠ Heuristic, and weaker
# than it looks: in the current app `speech` records are written only by AppModel for cue / obstacle
# lines, NavigationEngine lines (a Repeat is logged with `repeat: true` and the REPEATED text, so it
# does not start with "Repeat"), sound alerts, the arrival summary and the "Walking to …" announce.
# Flashlight confirmations and SceneDescriber lines are said directly and appear only as
# `speech_dispatch`, so these prefixes rarely match and a Repeat counts as unsolicited.
ASKED_FOR = ("describe", "Where am I", "Flashlight", "Repeat")  # prefixes of lines the walker requested


# Parse a trip log file into records, in file order. Errors are replaced on decode (a log cut
# mid-character still loads). Caller: `main`. Not sorted: `audit` sorts where order matters.
def load(path: Path) -> list[dict]:
    """Every JSON line of the log; unparseable lines are skipped (a crash can truncate the last)."""
    out = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


# Step 37 talk-floor check. Returns a count (int), or a string explaining why it cannot be measured
# (so `human` prints the reason instead of a misleading 0). Threshold 0.3 s, just under the app's
# `SpeechResume.crossBandGap` (0.35 s), so timer jitter on a kept pause is not counted. Only
# ADJACENT records after sorting by `t` are compared: an `end` followed by another `end` (or a
# dispatch whose previous record is a dispatch) is never counted. Caller: `audit` (dispatch section);
# pinned by the `pauses` fixture in `selftest`.
def cross_band_short_pauses(records: list[dict]) -> int | str:
    """Lines that started < 0.3 s after a DIFFERENT-priority line ended naturally (`speech_end`), not
    counting `.safety` starts; "no speech_end records" on logs before Step 37."""
    timed = sorted((r for r in records if r.get("kind") in ("speech_end", "speech_dispatch")
                    and isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    if not any(r["kind"] == "speech_end" for r in timed):
        return "no speech_end records (build before Step 37)"
    count = 0
    for a, b in zip(timed, timed[1:]):
        if (a["kind"] == "speech_end" and b["kind"] == "speech_dispatch"
                and a.get("priority") != b.get("priority") and b.get("priority") != "safety"
                and 0 <= b["t"] - a["t"] < 0.3):
            count += 1
    return count


# The measurement itself: pure over the parsed records (no I/O), so `selftest` can drive it.
# Rates divide by `minutes` = span of every numeric `t` in the log, floored at 1e-9 so a log with a
# single timestamp does not divide by zero (its per-minute numbers are then meaningless).
# Returns a JSON-serialisable dict; `human` renders it, `--json` prints it raw.
def audit(records: list[dict]) -> dict:
    """The whole report as a dict (see the module docstring for what each part means)."""
    times = [r["t"] for r in records if isinstance(r.get("t"), (int, float))]
    minutes = max((max(times) - min(times)) / 60.0, 1e-9) if times else 1e-9
    rep: dict = {"records": len(records), "minutes": round(minutes, 2)}

    # `lanes` records are throttled to TripLogger.laneRate (2 per second), so cell counts are samples
    # of the ~30 Hz depth stream, not every frame. The head band uses only records with LiDAR depth.
    all_lanes = [r for r in records if r.get("kind") == "lanes"]
    lanes = [r for r in all_lanes if r.get("depth")]
    # Tilt over every lanes record that carries one, depth or not (no selection bias — Muse, Step 35).
    tilts = [r["tilt"] for r in all_lanes if isinstance(r.get("tilt"), (int, float))]
    if tilts:
        inside = sum(MOUNT_AIM_DEG[0] <= t <= MOUNT_AIM_DEG[1] for t in tilts)
        rep["tilt"] = {
            "median_deg": round(statistics.median(tilts), 1),
            "min_deg": round(min(tilts), 1),
            "max_deg": round(max(tilts), 1),
            "share_in_mount_window": round(inside / len(tilts), 2),
            # Half the frames inside 3–8° is the bar for "this walk was on the mount".
            "mounted": inside / len(tilts) >= 0.5,
        }
    else:
        rep["tilt"] = None

    # True when this record's `tilt` is a number inside the mount window (a JSON null tilt — no
    # gravity yet — is outside).
    def in_aim(r: dict) -> bool:
        t = r.get("tilt")
        return isinstance(t, (int, float)) and MOUNT_AIM_DEG[0] <= t <= MOUNT_AIM_DEG[1]

    # Cells are indexed 0 left, 1 centre, 2 right (LaneReport.head / torso); depths in metres, −1 =
    # no valid depth in that cell (TripLogger writes invalid as −1).
    def head_band(frames: list[dict]) -> dict:
        """Classify every head cell under the enter distance. A frame whose whole torso row has no
        data (−1 ×3) is a dropout, not evidence of an overhang: its cells go to `no_data`
        (Muse, Step 35 — 3 of the first log's 11 "overhangs" were such dropouts)."""
        per_lane = Counter()
        wall_like = overhang_like = no_data = 0
        for r in frames:
            head, torso = r.get("head") or [], r.get("torso") or []
            dropout = len(torso) >= 3 and all(isinstance(x, (int, float)) and x < 0 for x in torso[:3])
            for i, h in enumerate(head[:3]):
                if not isinstance(h, (int, float)) or h < 0 or h >= HEAD_ENTER_M:
                    continue          # −1 = no data in the log; ≥ enter = not a head cell
                per_lane[("left", "centre", "right")[i]] += 1
                t = torso[i] if i < len(torso) else -1
                if dropout or not isinstance(t, (int, float)):
                    no_data += 1
                elif t < 0 or t >= h + SIGNATURE_GAP_M:
                    overhang_like += 1    # torso clear (−1 in a frame with other torso data) or farther
                else:
                    wall_like += 1
        judged = wall_like + overhang_like
        return {
            "cells_under_enter": judged + no_data,
            "by_lane": dict(per_lane),
            "torso_also_near": wall_like,
            "overhang_signature": overhang_like,
            "torso_dropout": no_data,
            "overhang_share": round(overhang_like / judged, 2) if judged else None,
        }

    rep["head_band"] = head_band(lanes)
    # Only frames inside the mount window say anything about what the cane will feel.
    rep["head_band_mounted_frames"] = head_band([r for r in lanes if in_aim(r)])

    # Step 41: a `cue` record with `suppressed` is a decider decision the walker's level, place
    # or crossing settle did NOT render (TorsoHapticPolicy) — it must not count as felt load.
    # `render` (center_onset / center_strong) marks a Standard-level onset tap that was felt.
    cue_recs = [r for r in records if r.get("kind") == "cue"]
    cues = Counter(r.get("cue") for r in cue_recs if not r.get("suppressed"))
    rep["cues_per_min"] = {k: round(v / minutes, 1) for k, v in cues.items() if k and k != "clear"}
    rep["torso_suppressed_per_min"] = {
        k: round(v / minutes, 1)
        for k, v in Counter(r.get("suppressed") for r in cue_recs if r.get("suppressed")).items()}
    rep["center_onsets"] = dict(Counter(r.get("render") for r in cue_recs if r.get("render")))

    spoken = [r for r in records if r.get("kind") == "speech"]
    by_pri = Counter(r.get("priority", "?") for r in spoken)
    rep["speech_per_min"] = {k: round(v / minutes, 1) for k, v in by_pri.items()}
    unsolicited = [r for r in spoken if not str(r.get("text", "")).startswith(ASKED_FOR)]
    rep["unsolicited_per_min"] = round(len(unsolicited) / minutes, 1)
    # Route lines are unsolicited but wanted; the load v2 targets is everything else.
    rep["unsolicited_non_route_per_min"] = round(
        sum(1 for r in unsolicited if r.get("priority") != "nav") / minutes, 1)
    rep["top_lines"] = Counter(r.get("text") for r in spoken).most_common(5)
    sup = [r for r in records if r.get("kind") == "speech_suppressed"]
    rep["suppressed"] = {"by_reason": dict(Counter(r.get("reason", "?") for r in sup)),
                         "by_load": dict(Counter(r.get("load", "?") for r in sup))}

    dispatch = sorted((r for r in records if r.get("kind") == "speech_dispatch"
                       and isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    if dispatch:
        gaps = [b["t"] - a["t"] for a, b in zip(dispatch, dispatch[1:])]
        rep["dispatch"] = {
            "lines": len(dispatch),
            "replays": sum(1 for r in dispatch if (r.get("replays") or 0) > 0),
            # Step 37: a replay with resume_from > 0 continued mid-line from its cut clause. One with
            # resume_from 0 started from the first word: before Step 37 that was every replay (the
            # choppy restart); on a Step 37 build it is a cut in the first clause or after a call /
            # dictation, which is correct. Read the two together with the build (`start` record).
            "replays_resumed_mid_line": sum(1 for r in dispatch
                                            if (r.get("replays") or 0) > 0 and (r.get("resume_from") or 0) > 0),
            "replays_from_line_start": sum(1 for r in dispatch
                                           if (r.get("replays") or 0) > 0 and not (r.get("resume_from") or 0) > 0),
            # Pause between a line's natural END (`speech_end`, Step 37) and the next line's start
            # when their priorities differ: the 0.35 s pause should keep this at 0 (a `.safety` start
            # never waits and is excluded). Start-to-start times cannot see a missing pause (review).
            "cross_band_pause_under_0_3s": cross_band_short_pauses(records),
            "back_to_back_under_1s": sum(1 for g in gaps if 0 < g < CHOPPY_GAP_S),
        }
    else:
        rep["dispatch"] = "no speech_dispatch records (build before Step 34): choppiness unmeasured"

    # Ground hazards (TripLogger event "hazard")
    hazards = [r for r in records if r.get("kind") == "hazard"]
    rep["ground_hazards"] = {
        "count": len(hazards),
        "by_type": dict(Counter(r.get("type", "?") for r in hazards)),
        "by_source": dict(Counter(r.get("source", "?") for r in hazards)),
    }

    # VLM Hazard Watch (TripLogger diagnostic "hazard_watch")
    hw = [r for r in records if r.get("kind") == "hazard_watch"]
    if hw:
        hw_ms = [r["ms"] for r in hw if isinstance(r.get("ms"), (int, float))]
        timeouts = sum(1 for r in hw if r.get("dropped") == "stale" or (isinstance(r.get("ms"), (int, float)) and r["ms"] >= 2500))
        rep["hazard_watch"] = {
            "calls": len(hw),
            "replies": dict(Counter(r.get("reply", "NONE" if not r.get("error") else "error") for r in hw)),
            "timeouts": timeouts,
            "avg_ms": round(statistics.mean(hw_ms), 1) if hw_ms else None,
        }
    else:
        rep["hazard_watch"] = None

    # Scene Description / VLM Queries (TripLogger event "describe_result")
    desc = [r for r in records if r.get("kind") == "describe_result"]
    if desc:
        desc_ms = [r["ms"] for r in desc if isinstance(r.get("ms"), (int, float))]
        rep["describe_result"] = {
            "calls": len(desc),
            "by_source": dict(Counter(r.get("source", "?") for r in desc)),
            "by_outcome": dict(Counter(r.get("outcome", "?") for r in desc)),
            "avg_ms": round(statistics.mean(desc_ms), 1) if desc_ms else None,
        }
    else:
        rep["describe_result"] = None

    rep["field_collisions"] = sum(1 for r in records if "field_kind" in r or "field_t" in r)
    return rep


# Plain-text rendering for a person at the bench. Caller: `main` when `--json` is absent. It
# prints `dispatch` as a raw dict (or the "no speech_dispatch records" string on old builds).
def human(rep: dict) -> str:
    """A short readable summary of `audit`'s dict."""
    lines = [f"{rep['records']} records over {rep['minutes']} min"]
    t = rep.get("tilt")
    if not t:
        lines.append("tilt: no data — mount state unknown, do not tune distances from this log")
    else:
        verdict = "ON THE MOUNT" if t["mounted"] else "NOT MOUNTED — do not tune distances from this log"
        lines.append(f"tilt median {t['median_deg']}° (range {t['min_deg']}…{t['max_deg']}°), "
                     f"{int(t['share_in_mount_window'] * 100)}% inside 3–8° → {verdict}")
    for key, label in (("head_band", "all frames"), ("head_band_mounted_frames", "frames inside 3–8°")):
        hb = rep[key]
        lines.append(f"head band < {HEAD_ENTER_M} m ({label}): {hb['cells_under_enter']} cells {hb['by_lane']}; "
                     f"torso also near {hb['torso_also_near']}, overhang signature {hb['overhang_signature']}, "
                     f"torso dropout {hb['torso_dropout']}"
                     + (f" ({int(hb['overhang_share'] * 100)}% overhang)" if hb["overhang_share"] is not None else ""))
    lines.append(f"cues/min {rep['cues_per_min']}")
    if rep["torso_suppressed_per_min"] or rep["center_onsets"]:
        lines.append(f"torso cues held by the level/min {rep['torso_suppressed_per_min']}; "
                     f"Standard onset taps {rep['center_onsets']}")
    lines.append(f"speech/min {rep['speech_per_min']}, unsolicited {rep['unsolicited_per_min']}/min "
                 f"({rep['unsolicited_non_route_per_min']}/min excluding route lines); "
                 f"suppressed {rep['suppressed']}")
    lines.append(f"top lines {rep['top_lines']}")
    lines.append(f"dispatch {rep['dispatch']}")
    if rep.get("ground_hazards") and rep["ground_hazards"]["count"]:
        gh = rep["ground_hazards"]
        lines.append(f"ground hazards: {gh['count']} total {gh['by_type']} (sources: {gh['by_source']})")
    if rep.get("hazard_watch"):
        hw = rep["hazard_watch"]
        lines.append(f"hazard watch: {hw['calls']} calls, replies {hw['replies']}, "
                     f"{hw['timeouts']} timeouts (avg {hw['avg_ms']} ms)")
    if rep.get("describe_result"):
        dr = rep["describe_result"]
        lines.append(f"describe results: {dr['calls']} calls, by source {dr['by_source']}, "
                     f"outcomes {dr['by_outcome']} (avg {dr['avg_ms']} ms)")
    if rep["field_collisions"]:
        lines.append(f"⚠ APP BUG: {rep['field_collisions']} records carry field_kind / field_t")
    return "\n".join(lines)


# `--pull`: needs the phone plugged in, unlocked and trusted, and Xcode's `devicectl`. Reads the
# first `DEVICE =`, `DEVICE :=`, `DEVICE ?=` or `DEVICE +=` line of ios/local.mk (the same file the
# Makefile includes); exits with a message on any failure rather than auditing nothing. The copy
# goes to a fresh temp dir (never into the repo) and its path is printed to stderr.
def pull_latest() -> Path:
    """Copy the newest canekit-*.jsonl off the phone named by DEVICE in ios/local.mk."""
    mk = Path(__file__).resolve().parent.parent / "local.mk"
    m = re.search(r"^\s*DEVICE\s*[:?+]?=\s*(\S+)", mk.read_text(), re.M) if mk.exists() else None
    if not m:
        sys.exit("no DEVICE in ios/local.mk")
    device = m.group(1)

    # One devicectl call; stdout on success, otherwise exit with its stderr (first 400 chars).
    def run(cmd: list[str]) -> str:
        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as e:
            detail = getattr(e, "stderr", "") or str(e)
            sys.exit(f"devicectl failed ({' '.join(cmd[:4])} …): {detail.strip()[:400]}\n"
                     "Is the phone plugged in, unlocked and trusted? (xcrun devicectl list devices)")

    listing = run(["xcrun", "devicectl", "device", "info", "files", "--device", device,
                   "--domain-type", "appDataContainer", "--domain-identifier", "com.aritro.canekit",
                   "--subdirectory", "Documents"])
    # Names embed a zero-padded ISO timestamp, so the lexicographic max is the newest.
    names = sorted(set(re.findall(r"canekit-[0-9T:-]+Z\.jsonl", listing)))
    if not names:
        sys.exit("no trip logs on the phone")
    dest = Path(tempfile.mkdtemp(prefix="cue_audit_")) / names[-1]
    run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
         "--domain-type", "appDataContainer", "--domain-identifier", "com.aritro.canekit",
         "--source", f"Documents/{names[-1]}", "--destination", str(dest)])
    if not dest.exists() or dest.stat().st_size == 0:
        sys.exit(f"pulled {names[-1]} but {dest} is missing or empty")
    print(f"pulled {names[-1]} → {dest}", file=sys.stderr)
    return dest


# `--selftest` (run first by `make audit`): fixture records that pin each section — wall-like,
# overhang and dropout head cells, the mounted-tilt verdict, a replay without `resume_from`, a
# dispatch record without `t` (skipped, no KeyError), a `field_kind` collision, suppressed-by-load,
# the route-line exclusion, and the Step 37 end → next-start pause cases. Prints "ok" or raises
# AssertionError with the report.
def selftest() -> None:
    """Fixture checks: a wall-like frame, an overhang frame, a mounted tilt, a replay, a collision."""
    recs = [
        {"t": 0.0, "kind": "session"},
        # Wall: head 1.0, torso 0.9 in every lane → 3 wall-like cells.
        {"t": 1.0, "kind": "lanes", "depth": True, "tilt": 5.0, "head": [1.0, 1.0, 1.0], "torso": [0.9, 1.1, 1.2]},
        # Hanging sign in the centre only: torso clear (-1) → 1 overhang cell; sides beyond enter.
        {"t": 2.0, "kind": "lanes", "depth": True, "tilt": 6.0, "head": [3.0, 1.2, 2.0], "torso": [3.0, -1, 2.5]},
        # Handheld frame (tilt 40°), head beyond enter → no cells.
        {"t": 3.0, "kind": "lanes", "depth": True, "tilt": 40.0, "head": [2.0, 2.0, 2.0], "torso": [2.0, 2.0, 2.0]},
        {"t": 4.0, "kind": "cue", "cue": "head"},
        # Step 41: a torso cue the level held is not felt load; a Standard onset tap is.
        {"t": 4.2, "kind": "cue", "cue": "left", "ar_t": 4.2, "suppressed": "quiet"},
        {"t": 4.4, "kind": "cue", "cue": "center", "ar_t": 4.4, "distance": 1.4, "render": "center_onset"},
        {"t": 5.0, "kind": "speech", "priority": "safety", "text": "Head height."},
        {"t": 5.5, "kind": "speech", "priority": "scene", "text": "Flashlight on."},
        {"t": 6.0, "kind": "speech_dispatch", "text": "Head height.", "priority": "safety", "replays": 0},
        {"t": 6.4, "kind": "speech_dispatch", "text": "One meter ahead, table", "priority": "obstacle", "replays": 1},
        {"t": 60.0, "kind": "speech_suppressed", "reason": "busy", "load": "ambientObstacleName", "field_kind": "oops"},
        # Whole torso row missing (dropout) at a mounted tilt: head 1.0 in the centre → no_data, not overhang.
        {"t": 7.0, "kind": "lanes", "depth": True, "tilt": 4.0, "head": [2.0, 1.0, 2.0], "torso": [-1, -1, -1]},
        {"t": 8.0, "kind": "speech", "priority": "nav", "text": "Route started."},
        {"t": 9.0, "kind": "speech_dispatch", "text": "late", "priority": "nav", "replays": 0},
        {"kind": "speech_dispatch", "text": "no time", "priority": "nav"},       # skipped, no KeyError
        {"t": 10.0, "kind": "hazard", "type": "stepUp", "text": "Step up", "source": "lidar"},
        {"t": 11.0, "kind": "hazard_watch", "provider": "gemini", "reply": "NONE", "ms": 2501, "dropped": "stale"},
        {"t": 12.0, "kind": "describe_result", "source": "cloud", "outcome": "spoken", "ms": 6300},
    ]
    rep = audit(recs)
    assert rep["head_band"]["torso_also_near"] == 3, rep
    assert rep["head_band"]["overhang_signature"] == 1, rep
    assert rep["head_band"]["torso_dropout"] == 1, rep
    assert rep["head_band"]["overhang_share"] == 0.25, rep     # dropouts are not judged
    assert rep["head_band"]["by_lane"] == {"left": 1, "centre": 3, "right": 1}, rep
    assert rep["head_band_mounted_frames"]["cells_under_enter"] == 5, rep   # tilts 5, 6, 4 all inside
    assert rep["tilt"]["mounted"] is True and rep["tilt"]["share_in_mount_window"] == 0.75, rep
    assert rep["dispatch"]["lines"] == 3, rep                  # the record without t is skipped
    assert rep["dispatch"]["replays"] == 1 and rep["dispatch"]["back_to_back_under_1s"] == 1, rep
    assert rep["dispatch"]["replays_from_line_start"] == 1, rep   # no resume_from
    assert rep["dispatch"]["replays_resumed_mid_line"] == 0, rep
    assert rep["dispatch"]["cross_band_pause_under_0_3s"].startswith("no speech_end"), rep
    assert rep["ground_hazards"]["count"] == 1 and rep["ground_hazards"]["by_type"] == {"stepUp": 1}, rep
    assert rep["hazard_watch"]["calls"] == 1 and rep["hazard_watch"]["timeouts"] == 1, rep
    assert rep["describe_result"]["calls"] == 1 and rep["describe_result"]["by_source"] == {"cloud": 1}, rep
    # End → next start: a safety line ends, a nav line starts 0.1 s later (missing pause → 1), a
    # nav line starts 0.36 s after an obstacle end (pause kept → 0), a safety start never counts.
    pauses = [
        {"t": 1.0, "kind": "speech_end", "priority": "safety"},
        {"t": 1.1, "kind": "speech_dispatch", "priority": "nav", "text": "a"},
        {"t": 2.0, "kind": "speech_end", "priority": "obstacle"},
        {"t": 2.36, "kind": "speech_dispatch", "priority": "nav", "text": "b"},
        {"t": 3.0, "kind": "speech_end", "priority": "nav"},
        {"t": 3.05, "kind": "speech_dispatch", "priority": "safety", "text": "c"},
        {"t": 4.0, "kind": "speech_end", "priority": "nav"},
        {"t": 4.05, "kind": "speech_dispatch", "priority": "nav", "text": "d"},
    ]
    assert cross_band_short_pauses(pauses) == 1, cross_band_short_pauses(pauses)
    assert rep["unsolicited_non_route_per_min"] == 1.0, rep    # Head height.; Flashlight asked for; route excluded
    assert rep["field_collisions"] == 1, rep
    assert rep["suppressed"] == {"by_reason": {"busy": 1}, "by_load": {"ambientObstacleName": 1}}, rep
    assert rep["cues_per_min"] == {"head": 1.0, "center": 1.0}, rep      # the held left tap is not counted
    assert rep["torso_suppressed_per_min"] == {"quiet": 1.0}, rep
    assert rep["center_onsets"] == {"center_onset": 1}, rep
    assert audit([{"t": 0, "kind": "session"}])["tilt"] is None
    print("cue_audit selftest: ok")


# CLI entry: `log` path, `--pull`, `--json`, `--selftest` (selftest wins and ignores the rest).
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", nargs="?", type=Path)
    ap.add_argument("--pull", action="store_true", help="copy the newest log off the phone first")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return
    path = pull_latest() if a.pull else a.log
    if not path:
        ap.error("give a log path, --pull or --selftest")
    rep = audit(load(path))
    print(json.dumps(rep, indent=2) if a.json else human(rep))


if __name__ == "__main__":
    main()
