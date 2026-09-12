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
  4. How choppy? `speech_dispatch` replays (a cut line resumed) and lines dispatched < 1 s apart.
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

HEAD_ENTER_M = 1.5            # CueThresholds.head
SIGNATURE_GAP_M = 0.5         # cue design v2 §3.2 overhang signature [H]
MOUNT_AIM_DEG = (3.0, 8.0)    # MountTilt.aim
CHOPPY_GAP_S = 1.0            # two dispatches closer than this read as a stutter
ASKED_FOR = ("describe", "Where am I", "Flashlight", "Repeat")  # prefixes of lines the walker requested


def load(path: Path) -> list[dict]:
    """Every JSON line of the log; unparseable lines are skipped (a crash can truncate the last)."""
    out = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def audit(records: list[dict]) -> dict:
    """The whole report as a dict (see the module docstring for what each part means)."""
    times = [r["t"] for r in records if isinstance(r.get("t"), (int, float))]
    minutes = max((max(times) - min(times)) / 60.0, 1e-9) if times else 1e-9
    rep: dict = {"records": len(records), "minutes": round(minutes, 2)}

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

    def in_aim(r: dict) -> bool:
        t = r.get("tilt")
        return isinstance(t, (int, float)) and MOUNT_AIM_DEG[0] <= t <= MOUNT_AIM_DEG[1]

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

    cues = Counter(r.get("cue") for r in records if r.get("kind") == "cue")
    rep["cues_per_min"] = {k: round(v / minutes, 1) for k, v in cues.items() if k and k != "clear"}

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
            "back_to_back_under_1s": sum(1 for g in gaps if 0 < g < CHOPPY_GAP_S),
        }
    else:
        rep["dispatch"] = "no speech_dispatch records (build before Step 34): choppiness unmeasured"

    rep["field_collisions"] = sum(1 for r in records if "field_kind" in r or "field_t" in r)
    return rep


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
    lines.append(f"speech/min {rep['speech_per_min']}, unsolicited {rep['unsolicited_per_min']}/min "
                 f"({rep['unsolicited_non_route_per_min']}/min excluding route lines); "
                 f"suppressed {rep['suppressed']}")
    lines.append(f"top lines {rep['top_lines']}")
    lines.append(f"dispatch {rep['dispatch']}")
    if rep["field_collisions"]:
        lines.append(f"⚠ APP BUG: {rep['field_collisions']} records carry field_kind / field_t")
    return "\n".join(lines)


def pull_latest() -> Path:
    """Copy the newest canekit-*.jsonl off the phone named by DEVICE in ios/local.mk."""
    mk = Path(__file__).resolve().parent.parent / "local.mk"
    m = re.search(r"^\s*DEVICE\s*[:?+]?=\s*(\S+)", mk.read_text(), re.M) if mk.exists() else None
    if not m:
        sys.exit("no DEVICE in ios/local.mk")
    device = m.group(1)

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
    assert rep["unsolicited_non_route_per_min"] == 1.0, rep    # Head height.; Flashlight asked for; route excluded
    assert rep["field_collisions"] == 1, rep
    assert rep["suppressed"] == {"by_reason": {"busy": 1}, "by_load": {"ambientObstacleName": 1}}, rep
    assert audit([{"t": 0, "kind": "session"}])["tilt"] is None
    print("cue_audit selftest: ok")


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
