#!/usr/bin/env python3
"""
cue_audit.py — how loud was that walk? Reads one CaneKit trip log (canekit-*.jsonl) and measures the
cue load a walker actually got, so cue design v2 (docs/cue_design_v2.md) is tuned from evidence, not
from a feeling. Step 35, the "measure first" item of the research's ranked change list.

It answers, from the log alone:
  1. Was the phone on the mount, and could the camera see head height? Camera tilt from `lanes.tilt`
     vs the 3–8° window (`MountTilt.aim`, a hinge recommendation since Step 51); a handheld walk (the
     first field log: median 26°) must not be used to tune distances. Step 51 `head_cover`: the share
     of `lanes` frames with any head lane covered (`lanes.head_cover`, or for a log from before Step
     51 the tilt against the geometry limit, ≈ 19° at camera 95 cm / head 140 cm / 150 cm). At the
     cane's natural 45° it is 0: head cues were impossible on that walk. `could_not_be_head` counts
     rows-mode head cells whose most optimistic (top-row) height is still under 140 cm.
  2. Is "head height" an overhang or a wall? For every `lanes` cell with head < 1.5 m, is the torso
     cell of the same lane also near (within 0.5 m → wall / furniture / person, which the cane finds)
     or clearly farther / empty (the overhang signature)?
  3. How much was said and felt? cues per minute by kind, spoken lines per minute by priority,
     unsolicited (not asked-for) lines per minute, suppressed lines by reason.
  4. How choppy? `speech_dispatch` replays (a cut line resumed — mid-line from its clause, or from the
     line start), lines dispatched < 1 s apart, and different-band lines starting < 0.3 s after the
     previous line's `speech_end`.
  5. App bugs: any `field_kind` / `field_t` column (TripLogRecord collision; e2e.py fails on it too).
  6. What would Steps 51–52 have done? (`head_gate_replay`) a Python mirror of `HeadGate` plus the
     head episode (onset; re-fire on 1.0 / 0.6 m ≥ 1.5 s apart; end after 2 s of trusted clear;
     "Head height." on the onset under a 4 s limiter and once more under 0.6 m) over the 2 Hz
     `lanes` records, beside the log's own head cues and lines.
  7. Speech load (Step 68, `--speech-load`): lines and characters per minute of one route, by text,
     from `speech_dispatch` first dispatches; and the same route replayed through the Step 68 rules
     (`step68_replay`: GPSAnnouncer hysteresis, no headphone / watch / head-cover line at start, the
     short intro and screen-lock line, an estimate of "Close." from the 2 Hz `lanes`).
  6. One voice? (Step 53) Which engine actually spoke each line — `speech_dispatch.engine`, a `race`
     settled by its `speech_engine` record — and how often the voice flipped: per minute over the
     whole walk, and separately inside route speech (consecutive `nav` lines while a route runs),
     which should be 0 once the cache is warm.

Run from ios/:
    scripts/cue_audit.py path/to/canekit-2026-09-12T20-57-17Z.jsonl
    scripts/cue_audit.py --pull              # copy the newest log off the phone in local.mk first
    scripts/cue_audit.py --json log.jsonl    # machine-readable
    scripts/cue_audit.py --selftest          # the fixture checks below (no device, no simulator)
    scripts/cue_audit.py --speech-load log.jsonl   # Step 68: route speech load, before vs the new rules

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
# `priority`, `replays`, `resume_from`, and since Step 53 `engine` / `engine_reason`), `speech_engine`
# (`text`, `engine`, `engine_reason`), `route` (`action` start / stop / restart), `speech_end`
# (`priority`), and for the hazard sections
# `hazard` (`type`, `source`), `hazard_watch` (`reply`, `error`, `dropped`, `ms`) and `describe_result`
# (`ms`, −1 when unknown), all written by AppModel / TripLogger / HazardScanner; `t` is seconds since
# the TripLogger was created (wall clock) on every record. ⚠ The describe_result section also counts
# `source` / `outcome`, which AppModel.describe_result does not write (it logs `provider`, `gate`,
# `error`, `question`, `frame`), so those counters read only "?" on a real log.

from __future__ import annotations

import argparse
import json
import math
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
# metres; torso at least this much farther than head = overhang. An app constant since Step 52.
SIGNATURE_GAP_M = 0.5         # CueThresholds.overhangGapM (HeadGate)
# degrees below the horizon (inclusive); `MountTilt.aim` = 3...8 (LaneReport.swift).
MOUNT_AIM_DEG = (3.0, 8.0)    # MountTilt.aim (a hinge recommendation since Step 51)
# Step 51 geometry (LaneConfig, centimetres) and the depth map's long-axis half FOV; a
# `depth_geometry` record in the log overrides them (`geometry_from`).
CAMERA_HEIGHT_CM = 95.0       # LaneConfig.cameraHeightCm
HEAD_MIN_CM = 140.0           # LaneConfig.headMinHeightCm
COVER_RANGE_CM = 150.0        # LaneConfig.coverageRangeCm
HALF_FOV_LONG_DEG = 33.5      # 256-px axis of ARKit's depth map
# Step 52 head episode (CueThresholds / CueSpeechPolicy).
HYSTERESIS_M = 0.15           # CueThresholds.hysteresis
HEAD_REFIRE_BANDS_M = (1.0, 0.6)  # CueThresholds.headRefireBands
HEAD_REFIRE_MIN_GAP_S = 1.5   # CueThresholds.headRefireMinGap
HEAD_CLEAR_S = 2.0            # CueThresholds.headClearSeconds
HEAD_LINE_INTERVAL_S = 4.0    # CueSpeechPolicy.headInterval
HEAD_SECOND_LINE_M = 0.6      # CueSpeechPolicy.headSecondLineBelowM
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


# ---- Step 51 / 52: head cover and the head-gate replay (pure; pinned by `selftest_head`) ----------

# `MountTilt.headCoverLimitDeg` (LaneReport.swift): the steepest pitch at which the top ray reaches
# `head_min_cm` at `range_cm` of z-depth. cos θ · tan h − sin θ = k  →  θ = acos(k · cos h) − (90° − h).
def head_cover_limit_deg(cam_h_cm: float = CAMERA_HEIGHT_CM, head_min_cm: float = HEAD_MIN_CM,
                         range_cm: float = COVER_RANGE_CM, half_fov_deg: float = HALF_FOV_LONG_DEG) -> float:
    """Degrees below the horizon; ≈ 19.0 with the app defaults."""
    k = (head_min_cm - cam_h_cm) / range_cm
    h = math.radians(half_fov_deg)
    return math.degrees(math.acos(max(-1.0, min(1.0, k * math.cos(h)))) - (math.pi / 2 - h))


# The geometry constants of this log: the first `depth_geometry` record (Step 51 builds) or the
# defaults above. Returns (cam_h_cm, head_min_cm, range_cm, half_fov_deg).
def geometry_from(records: list[dict]) -> tuple[float, float, float, float]:
    """Camera height, head minimum, cover range (cm) and long-axis half FOV (deg)."""
    for r in records:
        if r.get("kind") == "depth_geometry":
            return (float(r.get("cam_h_cm", CAMERA_HEIGHT_CM)), float(r.get("head_min_cm", HEAD_MIN_CM)),
                    float(r.get("cover_range_cm", COVER_RANGE_CM)),
                    float(r.get("half_fov_long_deg", HALF_FOV_LONG_DEG)))
    return CAMERA_HEIGHT_CM, HEAD_MIN_CM, COVER_RANGE_CM, HALF_FOV_LONG_DEG


# Is any head lane covered in this `lanes` record? The logged flags when present (Step 51), else
# the tilt against the geometry limit (None when the record has neither).
def frame_head_cover(r: dict, limit_deg: float) -> bool | None:
    """True / False / None (unknown)."""
    cover = r.get("head_cover")
    if isinstance(cover, list) and cover:
        return any(bool(c) for c in cover)
    t = r.get("tilt")
    return (t <= limit_deg) if isinstance(t, (int, float)) else None


# Rows-mode head cells (a log from before Step 51, or `bands: rows`) that could not have been head
# height even from the top image row: optimistic height = camH + d · (cos θ · tan h − sin θ).
def could_not_be_head(frames: list[dict], geom: tuple[float, float, float, float]) -> dict:
    """{"cells": head cells under the enter distance with a tilt, "could_not_be_head": how many sit
    under `head_min_cm` even at the top ray}. Metric frames are skipped (their head band already
    means ≥ 140 cm)."""
    cam_h, head_min, _, half_fov = geom
    tan_h = math.tan(math.radians(half_fov))
    cells = impossible = 0
    for r in frames:
        if r.get("bands") == "metric" or not isinstance(r.get("tilt"), (int, float)):
            continue
        th = math.radians(r["tilt"])
        gain = math.cos(th) * tan_h - math.sin(th)
        for h in (r.get("head") or [])[:3]:
            if isinstance(h, (int, float)) and 0 <= h < HEAD_ENTER_M:
                cells += 1
                if cam_h + h * 100 * gain < head_min:
                    impossible += 1
    return {"cells": cells, "could_not_be_head": impossible}


# Python mirror of `HeadGate.candidate` over one `lanes` record. Log values: −1 = no data (∞).
# `head_cover` / `torso_cover` default to all True (a log before Step 51); `head_cover` may be
# overridden (the replay's cover estimate for rows-mode frames).
def head_gate(r: dict, enter: float, gap: float | None, head_cover: list | None = None) -> float | None:
    """Nearest covered head distance < enter carrying the overhang signature, or None."""
    head, torso = r.get("head") or [], r.get("torso") or []
    hc = head_cover if head_cover is not None else (r.get("head_cover") or [True, True, True])
    tc = r.get("torso_cover") or [True, True, True]
    best = None
    for i in range(min(3, len(head))):
        h = head[i]
        if not (i < len(hc) and hc[i]) or not isinstance(h, (int, float)) or h < 0 or h >= enter:
            continue
        if gap is not None:
            t = torso[i] if i < len(torso) and isinstance(torso[i], (int, float)) else -1
            covered = tc[i] if i < len(tc) else True
            if covered and t >= 0 and t < h + gap:
                continue                  # near in both bands: a wall, the torso logic's
        best = h if best is None else min(best, h)
    return best


# Python mirror of the Step 52 head episode (`CueDecider`) and `CueSpeechPolicy` over the 2 Hz
# `lanes` records with depth. ⚠ ±0.5 s timing (2 Hz), no 400 ms change gate, no dropout hold.
# `estimate_cover`: for rows-mode frames, treat the head band as uncovered when the tilt is past the
# geometry limit (what Step 51 would have reported); metric frames use their logged flags.
def head_gate_replay(records: list[dict], gap: float | None = SIGNATURE_GAP_M,
                     estimate_cover: bool = False) -> dict:
    """{"frames", "onsets", "band_refires", "lines_would_speak"} for the replayed rule."""
    limit = head_cover_limit_deg(*geometry_from(records))
    frames = sorted((r for r in records if r.get("kind") == "lanes" and r.get("depth")),
                    key=lambda r: r.get("ar_t", r.get("t", 0)))
    zone = False
    episode = None                    # {"last_fire", "bands", "clear_since"}
    last_line = -math.inf
    second_spoken = False
    onsets = refires = lines = 0
    for r in frames:
        now = r.get("ar_t", r.get("t", 0))
        if not r.get("trusted", True):
            continue                              # a sweep freezes the clock (review 2026-09-13)
        cover = None
        if estimate_cover and r.get("bands") != "metric":
            cover = [frame_head_cover(r, limit) is not False] * 3
        d = head_gate(r, HEAD_ENTER_M + (HYSTERESIS_M if zone else 0), gap, cover)
        zone = d is not None and (d <= HEAD_ENTER_M + HYSTERESIS_M if zone else d < HEAD_ENTER_M)
        if episode:
            if zone:
                if episode["clear_since"] is not None and now - episode["clear_since"] >= HEAD_CLEAR_S:
                    episode = None
                else:
                    episode["clear_since"] = None
            else:
                since = episode["clear_since"] if episode["clear_since"] is not None else now
                episode = None if now - since >= HEAD_CLEAR_S else {**episode, "clear_since": since}
        if not zone:
            continue
        inside = sum(1 for b in HEAD_REFIRE_BANDS_M if d <= b)
        if episode is None:
            onsets += 1
            episode = {"last_fire": now, "bands": inside, "clear_since": None}
            second_spoken = False
            if now - last_line >= HEAD_LINE_INTERVAL_S:
                lines += 1
                last_line = now
        elif (episode["bands"] < len(HEAD_REFIRE_BANDS_M) and d < HEAD_REFIRE_BANDS_M[episode["bands"]]
              and now - episode["last_fire"] >= HEAD_REFIRE_MIN_GAP_S):
            refires += 1
            episode["bands"] = max(episode["bands"] + 1, inside)
            episode["last_fire"] = now
            if not second_spoken and d < HEAD_SECOND_LINE_M:
                second_spoken = True
                lines += 1
                last_line = now
    return {"frames": len(frames), "onsets": onsets, "band_refires": refires, "lines_would_speak": lines}


# The measurement itself: pure over the parsed records (no I/O), so `selftest` can drive it.
# Rates divide by `minutes` = span of every numeric `t` in the log, floored at 1e-9 so a log with a
# single timestamp does not divide by zero (its per-minute numbers are then meaningless).
# Returns a JSON-serialisable dict; `human` renders it, `--json` prints it raw.
# Step 53: the engine that actually spoke each dispatched line, in time order, as [t, priority, engine]
# with engine "elevenlabs" or "system". A dispatch's `engine` is final unless it is "race" — then the
# next `speech_engine` record for the same text settles it — and a `playback_failed` resolution turns
# the latest dispatch of that text into "system". Muted lines are skipped; a race never settled (the
# line was cut first) is left "race" and ignored by the flip counters. Pre-Step 53 logs have no
# `engine` field: every dispatch is skipped and the counters report that. Callers: the two below.
def resolved_engines(records: list[dict]) -> list[list]:
    """[t, priority, engine] per non-muted dispatched line, races resolved."""
    timed = sorted((r for r in records if r.get("kind") in ("speech_dispatch", "speech_engine")
                    and isinstance(r.get("t"), (int, float))), key=lambda r: r["t"])
    out: list[list] = []
    last_by_text: dict = {}
    for r in timed:
        if r["kind"] == "speech_dispatch":
            engine = r.get("engine")
            if engine in (None, "muted"):
                continue
            out.append([r["t"], r.get("priority"), engine])
            last_by_text[r.get("text")] = len(out) - 1
        else:
            i = last_by_text.get(r.get("text"))
            if i is not None and r.get("engine") in ("elevenlabs", "system"):
                out[i][2] = r["engine"]
    return out


# Engine flips over the whole walk: adjacent settled lines whose engines differ. Returns a dict with the
# count, the rate per minute and the lines per engine, or a string when the log predates Step 53.
def engine_flips_per_minute(records: list[dict], minutes: float) -> dict | str:
    """How often the walker heard the voice change, anywhere in the walk."""
    lines = resolved_engines(records)
    if not lines:
        return "no speech_dispatch.engine fields (build before Step 53): one-voice unmeasured"
    settled = [e for _, _, e in lines if e in ("elevenlabs", "system")]
    flips = sum(1 for a, b in zip(settled, settled[1:]) if a != b)
    return {"flips": flips, "per_min": round(flips / minutes, 1),
            "by_engine": dict(Counter(settled)), "unsettled_races": len(lines) - len(settled)}


# Engine flips inside route speech: consecutive `nav` lines within one route (a `route {action: start}`
# up to the next stop / restart / start). The number the plan's device check wants at 0: a route's
# own lines are prefetched before they are spoken (Step 54), so a flip here is a real regression.
# Returns the count, or a string when there is no engine field or no route record.
def engine_flips_inside_route_speech(records: list[dict]) -> int | str:
    """Voice changes between consecutive route lines of the same route."""
    lines = resolved_engines(records)
    if not lines:
        return "no speech_dispatch.engine fields"
    routes = sorted((r for r in records if r.get("kind") == "route" and isinstance(r.get("t"), (int, float))),
                    key=lambda r: r["t"])
    if not routes:
        return "no route records"
    # [start, end) windows; an unterminated route runs to the end of the log.
    windows, open_at = [], None
    for r in routes:
        action = r.get("action")
        if open_at is not None and action in ("stop", "restart", "start"):
            windows.append((open_at, r["t"]))
            open_at = None
        if action == "start":
            open_at = r["t"]
    if open_at is not None:
        windows.append((open_at, float("inf")))
    flips = 0
    for start, end in windows:
        nav = [e for t, p, e in lines if start <= t < end and p == "nav" and e in ("elevenlabs", "system")]
        flips += sum(1 for a, b in zip(nav, nav[1:]) if a != b)
    return flips


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
    # Step 51: could the camera see head height at all? (logged flags, else tilt vs the geometry).
    geom = geometry_from(records)
    limit = head_cover_limit_deg(*geom)
    covers = [c for c in (frame_head_cover(r, limit) for r in all_lanes) if c is not None]
    rep["head_cover"] = {
        "limit_deg": round(limit, 1),
        "frames": len(covers),
        "share_head_cover": round(sum(covers) / len(covers), 2) if covers else None,
        "bands": dict(Counter(r.get("bands", "rows (pre-Step 51)") for r in all_lanes)),
        **could_not_be_head(lanes, geom),
    }

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

    # Step 53: one voice. Both counters are separate on purpose — a flip on a warning during warm-up is
    # expected, a flip between two route lines is not.
    rep["voice"] = {"engine_flips": engine_flips_per_minute(records, minutes),
                    "engine_flips_inside_route_speech": engine_flips_inside_route_speech(records)}

    # Step 52: what the head gate + episode rule would have done with these frames, beside what the
    # log's build actually did (`cue` records with cue == head, spoken "Head height." lines).
    rep["head_gate_replay"] = {
        "signature_only": head_gate_replay(records),
        "signature_and_estimated_cover": head_gate_replay(records, estimate_cover=True),
        "no_signature": head_gate_replay(records, gap=None),
        "logged_head_cues": sum(1 for r in cue_recs if r.get("cue") == "head" and not r.get("suppressed")),
        "logged_head_onsets": sum(1 for r in cue_recs if r.get("cue") == "head" and r.get("onset") is True),
        "logged_head_lines": sum(1 for r in spoken if r.get("text") == "Head height."),
        "caveat": "2 Hz replay: ±0.5 s timing, no 400 ms change gate; rows-mode logs cannot be re-bucketed",
    }

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
    hc = rep.get("head_cover") or {}
    if hc.get("share_head_cover") is not None:
        impossible = " — head cues were impossible on this walk" if hc["share_head_cover"] == 0 else ""
        lines.append(f"head-height cover in {int(hc['share_head_cover'] * 100)}% of frames "
                     f"(limit ≈ {hc['limit_deg']}°){impossible}; bands {hc['bands']}; "
                     f"rows-mode head cells that could not be head height: "
                     f"{hc['could_not_be_head']} of {hc['cells']}")
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
    lines.append(f"voice: flips {rep['voice']['engine_flips']}; "
                 f"flips inside route speech {rep['voice']['engine_flips_inside_route_speech']} (want 0)")
    if rep.get("head_gate_replay"):
        g = rep["head_gate_replay"]
        lines.append(f"head gate replay (Step 52 rule): signature only {g['signature_only']}; "
                     f"+ estimated cover {g['signature_and_estimated_cover']}; without signature "
                     f"{g['no_signature']}; logged: {g['logged_head_cues']} head cues, "
                     f"{g['logged_head_lines']} \"Head height.\" lines ({g['caveat']})")
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
    # Step 53 one voice: e(route) → race→system(route) → e(route) → e→playback_failed safety → [stop]
    # → e nav. Whole walk e,s,e,s,e = 4 flips; inside the route the nav lines e,s,e = 2; a muted line
    # and a never-settled race are ignored.
    voice = [
        {"t": 0.5, "kind": "route", "action": "start"},
        {"t": 1.0, "kind": "speech_dispatch", "priority": "nav", "text": "Route started.", "engine": "elevenlabs", "engine_reason": "cached"},
        {"t": 2.0, "kind": "speech_dispatch", "priority": "nav", "text": "Turn left.", "engine": "race", "engine_reason": "race"},
        {"t": 4.5, "kind": "speech_engine", "text": "Turn left.", "engine": "system", "engine_reason": "race_timeout", "wait_ms": 2500},
        {"t": 5.0, "kind": "speech_dispatch", "priority": "nav", "text": "Cross.", "engine": "elevenlabs", "engine_reason": "cached"},
        {"t": 5.5, "kind": "speech_dispatch", "priority": "safety", "text": "Head height.", "engine": "elevenlabs", "engine_reason": "cached"},
        {"t": 5.6, "kind": "speech_engine", "text": "Head height.", "engine": "system", "engine_reason": "playback_failed", "wait_ms": 0},
        {"t": 5.8, "kind": "speech_dispatch", "priority": "nav", "text": "muted", "engine": "muted", "engine_reason": "muted"},
        {"t": 5.9, "kind": "speech_dispatch", "priority": "scene", "text": "cut race", "engine": "race", "engine_reason": "race"},
        {"t": 6.0, "kind": "route", "action": "stop"},
        {"t": 7.0, "kind": "speech_dispatch", "priority": "nav", "text": "Route stopped.", "engine": "elevenlabs", "engine_reason": "cached"},
    ]
    flips = engine_flips_per_minute(voice, 1.0)
    assert flips["flips"] == 4 and flips["unsettled_races"] == 1, flips
    assert flips["by_engine"] == {"elevenlabs": 3, "system": 2}, flips
    assert engine_flips_inside_route_speech(voice) == 2, engine_flips_inside_route_speech(voice)
    assert engine_flips_per_minute(recs, 1.0).startswith("no speech_dispatch.engine"), rep
    no_routes = [r for r in voice if r["kind"] != "route"]
    assert engine_flips_inside_route_speech(no_routes) == "no route records", no_routes
    selftest_head()                                   # Step 51 / 52 (agent A)
    selftest_speech_load()                            # Step 68
    print("cue_audit selftest: ok")


# Step 51 / 52 fixtures: the geometry limit, `could_not_be_head` on a 45° and a 5° rows frame, the
# cover verdict from logged flags, the gate (wall vs sign vs dropout vs uncovered) and episode
# sequences (onset once; steady, no re-fire; back after 1.5 s of clear = same episode; after 2.5 s
# = new onset; two band re-fires held to 1.5 s apart; a sweep freezes, never restarts, the clock).
# Caller: `selftest`.
def selftest_head() -> None:
    """Asserts for the head-cover and head-gate sections."""
    assert abs(head_cover_limit_deg() - 19.0) < 0.3, head_cover_limit_deg()
    rows = [{"t": 0, "kind": "lanes", "depth": True, "tilt": 45.0, "head": [1.0, 4.0, -1], "torso": [1.4, 1.4, 1.4]},
            {"t": 1, "kind": "lanes", "depth": True, "tilt": 5.0, "head": [1.0, 4.0, 4.0], "torso": [3, 3, 3]}]
    geom = geometry_from(rows)
    assert could_not_be_head(rows, geom) == {"cells": 2, "could_not_be_head": 1}, could_not_be_head(rows, geom)
    steep = [{"t": 0, "kind": "lanes", "depth": True, "tilt": 45.0, "bands": "metric",
              "head": [-1, -1, -1], "torso": [-1, -1, -1], "head_cover": [False] * 3, "torso_cover": [True] * 3}]
    rep = audit(steep)
    assert rep["head_cover"]["share_head_cover"] == 0 and rep["head_cover"]["bands"] == {"metric": 1}, rep
    wall = {"head": [4, 1.0, 4], "torso": [4, 1.0, 4]}
    sign = {"head": [4, 1.0, 4], "torso": [4, 2.5, 4]}
    assert head_gate(wall, 1.5, 0.5) is None and head_gate(wall, 1.5, None) == 1.0
    assert head_gate(sign, 1.5, 0.5) == 1.0
    assert head_gate({**sign, "torso": [4, -1, 4]}, 1.5, 0.5) == 1.0            # dropout fails safe
    assert head_gate({**sign, "head_cover": [True, False, True]}, 1.5, 0.5) is None
    assert head_gate({**wall, "torso_cover": [True, False, True]}, 1.5, 0.5) == 1.0

    # One `lanes` record: head centre `head` m (None = clear), torso empty.
    def frame(t: float, head: float | None, trusted: bool = True) -> dict:
        return {"t": t, "kind": "lanes", "depth": True, "trusted": trusted, "bands": "metric",
                "head": [4, head if head is not None else -1, 4], "torso": [-1, -1, -1]}
    seq = [frame(0, 1.2), frame(0.5, 1.2), frame(1.0, 1.2),        # onset, then steady
           frame(1.5, None), frame(2.5, None), frame(3.0, 1.2),    # 1.5 s clear: same episode
           frame(3.5, None), frame(6.0, None), frame(6.5, 1.2)]    # 2.5 s clear: new onset
    g = head_gate_replay(seq)
    assert g == {"frames": 9, "onsets": 2, "band_refires": 0, "lines_would_speak": 2}, g
    bands = [frame(0, 1.2), frame(1.0, 0.9), frame(2.0, 0.9), frame(4.0, 0.5), frame(6.0, 0.3)]
    g = head_gate_replay(bands)                                    # 0.9 at 1.0 s is < 1.5 s: held to 2.0
    assert g == {"frames": 5, "onsets": 1, "band_refires": 2, "lines_would_speak": 2}, g
    sweep = [frame(0, 1.2), frame(0.5, None), frame(1.5, None, trusted=False), frame(2.0, None),
             frame(3.0, 1.2)]                                      # 2.5 s since 0.5: the sweep did not hold it
    assert head_gate_replay(sweep)["onsets"] == 2, head_gate_replay(sweep)


# ---- Step 68: speech load and the "half the words" replay (pure; pinned by `selftest_speech_load`) ----

# Mirrors of the Step 68 constants (CaneKitLogic `GPSAnnouncer`, `NavigationHealth`, `TileLevel`,
# `CueSpeechPolicy.close`). ⚠ Keep in step with the Swift.
# Review round Steps 67–68 retuned the announcer: weak 10 s after the bad onset, again after 60 s,
# back at most once per 120 s (pending meanwhile), a fix older than 12 s is bad (dated from the 5 s
# guidance pause), no fix is bad from 10 s after the route start.
GPS_WEAK_AFTER_S = 10.0       # GPSAnnouncer.weakAfter
GPS_BACK_AFTER_S = 10.0       # GPSAnnouncer.backAfter
GPS_WEAK_REPEAT_S = 60.0      # GPSAnnouncer.weakRepeatInterval
GPS_BACK_INTERVAL_S = 120.0   # GPSAnnouncer.backInterval
GPS_ANNOUNCER_MAX_FIX_AGE_S = 12.0  # GPSAnnouncer.maxFixAge
GPS_NO_FIX_GRACE_S = 10.0     # GPSAnnouncer.noFixGrace
GPS_MAX_FIX_AGE_S = 5.0       # NavigationHealth.maxFixAge (the engine's guidance pause)
GPS_MAX_ACCURACY_M = 20.0     # GPSAnnouncer.maxAccuracyM = NavigationEngine.veerMaxAccuracy
CLOSE_RED_BELOW_M = 0.7       # TileLevel.urgent
CLOSE_CLEAR_S = 3.0           # CueSpeechPolicy.closeClearSeconds
CLOSE_INTERVAL_S = 4.0        # CueSpeechPolicy.closeInterval
# Lines Step 68 no longer speaks at route start, and the two replaced wordings.
STEP68_DROPPED = {"GPS weak. Waypoint cues paused until it recovers.", "GPS back.",
                  "No headphones. Beacon paused until AirPods connect.",
                  "Watch not reachable. Open OpenCane on the watch.",
                  "Camera too steep for head-height cover. Torso obstacles only."}
STEP68_REWORDED = {"Screen locked. Obstacle warnings are paused until you unlock.":
                   "Screen locked. Obstacle warnings off."}


# The route window of a log: from the first route-start sign (`route_readiness` / `sensor_mode`
# route_start_reserved / `route` start — so "Starting." is inside) to the route's stop / arrival,
# else the last record. None when the log has no route. Caller: `speech_load`, `step68_replay`.
def route_window(records: list[dict]) -> tuple[float, float] | None:
    ts = lambda pred: [r["t"] for r in records if isinstance(r.get("t"), (int, float)) and pred(r)]
    starts = ts(lambda r: r.get("kind") == "route" and r.get("action") == "start")
    if not starts:
        return None
    pre = ts(lambda r: (r.get("kind") == "route_readiness" or
                        (r.get("kind") == "sensor_mode" and r.get("action") == "route_start_reserved"))
             and r["t"] <= starts[0])
    t0 = min(pre + [starts[0]])
    ends = ts(lambda r: r["t"] > starts[0] and (r.get("kind") == "arrived" or
                                                (r.get("kind") == "route" and r.get("action") in ("stop", "restart"))))
    t1 = ends[0] if ends else max(ts(lambda r: True))
    return t0, t1


# What was said in [t0, t1]: first dispatches only (a resumed replay is the same line). Caller: both below.
def dispatched(records: list[dict], t0: float, t1: float) -> list[tuple[float, str]]:
    return sorted((r["t"], r.get("text", "")) for r in records
                  if r.get("kind") == "speech_dispatch" and isinstance(r.get("t"), (int, float))
                  and t0 <= r["t"] <= t1 and not r.get("replays"))


# Lines / characters per minute and a by-text table (count, characters), largest first.
def load_of(lines: list[tuple[float, str]], minutes: float) -> dict:
    by: dict[str, list[int]] = {}
    for _, text in lines:
        by.setdefault(text, [0, 0])
        by[text][0] += 1
        by[text][1] += len(text)
    chars = sum(len(text) for _, text in lines)
    return {"lines": len(lines), "chars": chars, "minutes": round(minutes, 2),
            "lines_per_min": round(len(lines) / minutes, 1), "chars_per_min": round(chars / minutes, 1),
            "by_text": sorted(([t, n, c] for t, (n, c) in by.items()), key=lambda x: -x[2])}


def speech_load(records: list[dict]) -> dict | str:
    """Step 68: the route's speech load as dispatched (lines, characters, per minute, by text)."""
    w = route_window(records)
    if not w:
        return "no route start in this log"
    minutes = max((w[1] - w[0]) / 60.0, 1e-9)
    return {"window_s": [round(w[0], 1), round(w[1], 1)], **load_of(dispatched(records, *w), minutes)}


# Python `WalkingIntro.destinationName` + `routeStarted`: "Route started. <name>. First: <say>" →
# "Route to <destination>. <say>". Other text is returned unchanged.
def step68_intro(text: str) -> str:
    m = re.match(r"^Route started\. (.*?)\. First: ?(.*)$", text)
    if not m:
        return text
    name, first = m.group(1).strip(), m.group(2).strip()
    if name.startswith("To "):
        dest = name[3:]
    elif " to " in name:
        dest = name.rsplit(" to ", 1)[1]
    else:
        dest = name
    dest = dest.strip().rstrip(".") or name
    return f"Route to {dest}." + (f" {first}" if first else "")


# Python `GPSAnnouncer` fed like `NavigationEngine.announceGPS` at the 10 Hz ticker over [t0, t1]
# (outdoors assumed; t0 = the route start). ⚠ Mirrors `GPSAnnouncer.badOnset` / `update(badOnset:…)`.
def gps_bad_onset(last: tuple[float, float] | None, t0: float, now: float) -> float | None:
    if last is None:
        return t0 + GPS_NO_FIX_GRACE_S if now >= t0 + GPS_NO_FIX_GRACE_S else None
    age = now - last[0]
    if age < 0:
        return now
    if age > GPS_ANNOUNCER_MAX_FIX_AGE_S:
        return last[0] + GPS_MAX_FIX_AGE_S
    if not 0 <= last[1] <= GPS_MAX_ACCURACY_M:
        return now
    return None


def gps_announcer_replay(records: list[dict], t0: float, t1: float) -> list[tuple[float, str]]:
    fixes = sorted((r["t"], r.get("acc", -1)) for r in records
                   if r.get("kind") == "gps" and isinstance(r.get("t"), (int, float)) and r["t"] >= t0)
    out, i, last = [], 0, None
    bad_since = good_since = last_weak = last_back = None
    weak = False
    step = 0
    while True:
        now = round(t0 + step * 0.1, 3)
        if now > t1:
            break
        while i < len(fixes) and fixes[i][0] <= now:
            last = fixes[i]
            i += 1
        onset = gps_bad_onset(last, t0, now)
        if onset is not None:
            good_since = None
            bad_since = onset if bad_since is None else min(bad_since, onset)
            if (not weak and now - bad_since >= GPS_WEAK_AFTER_S
                    and (last_weak is None or now - last_weak >= GPS_WEAK_REPEAT_S)):
                weak, last_weak = True, now
                out.append((now, "GPS weak."))
        else:
            bad_since = None
            good_since = now if good_since is None else good_since
            if (weak and now - good_since >= GPS_BACK_AFTER_S
                    and (last_back is None or now - last_back >= GPS_BACK_INTERVAL_S)):
                weak, last_back = False, now
                out.append((now, "GPS back."))
        step += 1
    return out


# Estimate of the Step 68 "Close." lines from the 2 Hz `lanes` records (the app sees every 30 Hz
# frame, so this can miss a red moment shorter than 0.5 s): centre torso < 0.7 m, trusted, covered;
# a frame with any `held` cell may continue an episode but not start one (the log does not say which
# cell was held).
def close_replay(records: list[dict], t0: float, t1: float) -> list[tuple[float, str]]:
    out, episode, clear_since, last = [], False, None, None
    for r in sorted((r for r in records if r.get("kind") == "lanes" and isinstance(r.get("t"), (int, float))
                     and t0 <= r["t"] <= t1), key=lambda r: r["t"]):
        torso, cover = r.get("torso") or [], r.get("torso_cover") or [True, True, True]
        if not r.get("trusted") or len(torso) < 2 or not cover[1]:
            continue
        d = torso[1]
        red = isinstance(d, (int, float)) and 0 <= d < CLOSE_RED_BELOW_M
        if red:
            clear_since = None
            if episode or r.get("held"):
                continue
            if last is not None and r["t"] - last < CLOSE_INTERVAL_S:
                continue
            episode, last = True, r["t"]
            out.append((r["t"], "Close."))
        elif episode:
            clear_since = r["t"] if clear_since is None else clear_since
            if r["t"] - clear_since >= CLOSE_CLEAR_S:
                episode, clear_since = False, None
    return out


def step68_replay(records: list[dict]) -> dict | str:
    """Step 68: the route as dispatched vs replayed through the new rules; `chars_per_min_change_pct`."""
    w = route_window(records)
    if not w:
        return "no route start in this log"
    minutes = max((w[1] - w[0]) / 60.0, 1e-9)
    before = dispatched(records, *w)
    kept = [(t, STEP68_REWORDED.get(x, step68_intro(x))) for t, x in before if x not in STEP68_DROPPED]
    gps = gps_announcer_replay(records, *w)
    close = close_replay(records, *w)
    after = sorted(kept + gps + close)
    b, a = load_of(before, minutes), load_of(after, minutes)
    pct = lambda x, y: round(100.0 * (y - x) / x, 1) if x else None
    return {"window_s": [round(w[0], 1), round(w[1], 1)], "before": b, "after": a,
            "gps_lines_after": len(gps), "close_lines_estimated": len(close),
            "chars_per_min_change_pct": pct(b["chars_per_min"], a["chars_per_min"]),
            "lines_per_min_change_pct": pct(b["lines_per_min"], a["lines_per_min"])}


# Plain-text rendering of `step68_replay` for `--speech-load`.
def human_speech_load(rep: dict | str) -> str:
    if isinstance(rep, str):
        return rep
    rows = [f"route window {rep['window_s'][0]}–{rep['window_s'][1]} s ({rep['before']['minutes']} min)"]
    for label in ("before", "after"):
        x = rep[label]
        rows.append(f"{label}: {x['lines']} lines, {x['chars']} characters; "
                    f"{x['lines_per_min']} lines/min, {x['chars_per_min']} characters/min")
        rows += [f"    {n:>3} × {c:>5} ch  {t}" for t, n, c in x["by_text"]]
    rows.append(f"characters/min {rep['chars_per_min_change_pct']} %, lines/min {rep['lines_per_min_change_pct']} %; "
                f"GPS lines after {rep['gps_lines_after']}, \"Close.\" estimated {rep['close_lines_estimated']}")
    return "\n".join(rows)


# Fixture for the Step 68 section: a 120 s route whose GPS goes stale every 6 s (flap), the old start
# chatter, a red approach; asserts the replay drops the chatter, keeps one "Close." and no GPS line.
def selftest_speech_load() -> None:
    recs = [{"t": 0.0, "kind": "sensor_mode", "action": "route_start_reserved"},
            {"t": 0.5, "kind": "speech_dispatch", "text": "Starting.", "priority": "nav"},
            {"t": 1.0, "kind": "route", "action": "start"},
            {"t": 1.5, "kind": "speech_dispatch", "priority": "nav",
             "text": "Route started. ISR Townsend Hall to CIF. First: Leave Townsend Hall."},
            {"t": 3.0, "kind": "speech_dispatch", "priority": "nav", "text": "No headphones. Beacon paused until AirPods connect."},
            {"t": 3.5, "kind": "speech_dispatch", "priority": "nav", "text": "Screen locked. Obstacle warnings are paused until you unlock."},
            {"t": 3.6, "kind": "speech_dispatch", "priority": "nav", "text": "Screen locked. Obstacle warnings are paused until you unlock.", "replays": 1}]
    for k in range(20):
        recs.append({"t": 1.0 + 6 * k, "kind": "gps", "acc": 7.0})
        recs.append({"t": 7.0 + 6 * k, "kind": "speech_dispatch", "priority": "nav",
                     "text": "GPS weak. Waypoint cues paused until it recovers." if k % 2 == 0 else "GPS back."})
    for k, d in enumerate([1.5, 1.0, 0.6, 0.5, 0.4, 0.9, 0.6]):     # one red episode (0.9 for 0.5 s only)
        recs.append({"t": 50.0 + 0.5 * k, "kind": "lanes", "trusted": True, "torso": [-1, d, -1], "held": 0})
    recs.append({"t": 121.0, "kind": "route", "action": "stop"})
    load = speech_load(recs)
    assert load["lines"] == 24 and load["window_s"] == [0.0, 121.0], load     # the replay is not a line
    rep = step68_replay(recs)
    texts = [t for t, _, _ in rep["after"]["by_text"]]
    assert rep["gps_lines_after"] == 0 and rep["close_lines_estimated"] == 1, rep
    assert "Route to CIF. Leave Townsend Hall." in texts and "Screen locked. Obstacle warnings off." in texts, rep
    assert not any(t.startswith(("GPS", "No headphones")) for t in texts), rep
    assert rep["chars_per_min_change_pct"] < -50, rep
    assert step68_intro("Route started. To Grainger Engineering Library. First: Go.") == \
        "Route to Grainger Engineering Library. Go."
    assert speech_load([{"t": 0, "kind": "session"}]) == "no route start in this log"


# CLI entry: `log` path, `--pull`, `--json`, `--selftest` (selftest wins and ignores the rest).
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log", nargs="?", type=Path)
    ap.add_argument("--pull", action="store_true", help="copy the newest log off the phone first")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--speech-load", action="store_true",
                    help="Step 68: route speech load, as dispatched and replayed through the new rules")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return
    path = pull_latest() if a.pull else a.log
    if not path:
        ap.error("give a log path, --pull or --selftest")
    if a.speech_load:
        rep = step68_replay(load(path))
        print(json.dumps(rep, indent=2) if a.json else human_speech_load(rep))
        return
    rep = audit(load(path))
    print(json.dumps(rep, indent=2) if a.json else human(rep))


if __name__ == "__main__":
    main()
