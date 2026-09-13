#!/usr/bin/env python3
"""
campaign.py — the Step 66 repeat-run campaign: every e2e scenario N times, one at a time, then a table
of outcomes and a determinism check.

For each round (1..--runs) it runs, in order, the four `make e2e` scenarios, `indoor_isr`, and every
stress trace (scripts/stress/traces/*.json) once per seed in --seeds. Each run is its own
`scripts/e2e.py` process (never two at once: a contended simulator starves the GPS replay). After every
run it saves the report under --out/reports/ and rewrites --out/results.md, so a crash or an interrupt
never loses finished runs.

Determinism: runs with identical arguments (same scenario, same seed) are compared on their outcome and
on a *signature* — waypoint indices, wrist cues, and the spoken lines with every number replaced by #
(the trip summary's minutes and metres legitimately vary) — plus, for indoor_isr, the advanced indices.
A config whose runs differ is flagged DIFFERENT with the first difference.

    python3 scripts/stress/campaign.py --out /tmp/stress          # 3 rounds, seeds 11 22 33
    python3 scripts/stress/campaign.py --runs 1 --only stress_cif_siebel --seeds 11
    python3 scripts/stress/campaign.py --out /tmp/stress --summarize   # rebuild results.md only

Needs `make sim` first (the e2e.py APP path). Python 3 stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
IOS = HERE.parent.parent
BASE = ["clean", "missed_fence", "gps_jitter", "wrong_turn", "indoor_isr"]


def configs(seeds: list[int], only: list[str] | None) -> list[tuple[str, int | None]]:
    """(scenario, seed) pairs in campaign order; the base scenarios use e2e.py's default seed."""
    out: list[tuple[str, int | None]] = [(s, None) for s in BASE]
    out += [(f"stress_{p.stem}", seed) for p in sorted((HERE / "traces").glob("*.json")) for seed in seeds]
    return [c for c in out if not only or c[0] in only]


def key(scenario: str, seed: int | None) -> str:
    return scenario if seed is None else f"{scenario}-s{seed}"


def signature(entry: dict) -> dict:
    """What must not change between identical runs (numbers in speech masked)."""
    return {"pass": entry.get("pass"),
            "waypoints": entry.get("waypoints"),
            "navcues": entry.get("navcues"),
            "speech": [re.sub(r"\d+(\.\d+)?", "#", s) for s in entry.get("speech", [])],
            "advanced": (entry.get("indoor") or {}).get("advanced")}


def first_difference(a: dict, b: dict) -> str:
    for field in a:
        if a[field] != b.get(field):
            if isinstance(a[field], list) and isinstance(b.get(field), list):
                x, y = a[field], b[field]
                i = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
                return (f"{field}[{i}]: {x[i] if i < len(x) else '∅'!r} vs {y[i] if i < len(y) else '∅'!r} "
                        f"(len {len(x)} vs {len(y)})")
            return f"{field}: {a[field]!r} vs {b.get(field)!r}"
    return "-"


def summarize(out: Path) -> str:
    runs = []
    for p in sorted((out / "reports").glob("*.json")):
        doc = json.loads(p.read_text())
        for name, entry in doc.get("scenarios", {}).items():
            m = re.match(r"(.+)-r(\d+)\.json$", p.name)
            runs.append({"config": m.group(1) if m else p.stem, "round": int(m.group(2)) if m else 0,
                         "wall_s": doc.get("wall_s"), "entry": entry})
    lines = ["# Step 66 stress campaign — results", "",
             f"Generated {time.strftime('%Y-%m-%d %H:%M:%S')} from {len(runs)} runs in `{out / 'reports'}`.", "",
             "| config | round | result | s | waypoints | wrist cues | veers | passed | lines/min | arrival m | GPS fixes / median dt / max gap | notes |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in runs:
        e = r["entry"]
        st = e.get("stress") or {}
        ind = e.get("indoor") or {}
        said = e.get("speech", [])
        veers = st.get("veers", sum(s.startswith("Veer") for s in said))
        passed = st.get("passed", sum(s.startswith("Passed") for s in said))
        notes = "; ".join(e.get("failures", []) + [w[:80] for w in e.get("warnings", [])])
        if ind:
            notes = f"advanced {ind.get('advanced')} handover by {ind.get('handover_by')}; " + notes
        lines.append(f"| {r['config']} | {r['round']} | {'PASS' if e.get('pass') else 'FAIL'} | {e.get('seconds')} | "
                     f"{len(e.get('waypoints', []))} | {len(e.get('navcues', []))} | {veers} | {passed} | "
                     f"{st.get('lines_per_min', '')} | {st.get('arrival_m', '')} | "
                     f"{e.get('gps_fixes')} / {e.get('gps_median_dt')} / {e.get('gps_max_dt')} | {notes[:300]} |")
    lines += ["", "## Determinism (identical arguments, different rounds)", "",
              "| config | rounds | outcomes | identical signature | first difference |", "|---|---|---|---|---|"]
    by: dict[str, list[dict]] = {}
    for r in runs:
        by.setdefault(r["config"], []).append(r)
    for config, rs in by.items():
        sigs = [signature(r["entry"]) for r in rs]
        same = all(s == sigs[0] for s in sigs)
        diff = "-" if same else next(first_difference(sigs[0], s) for s in sigs[1:] if s != sigs[0])
        outcomes = "".join("P" if r["entry"].get("pass") else "F" for r in rs)
        lines.append(f"| {config} | {len(rs)} | {outcomes} | {'yes' if same else '**DIFFERENT**'} | {diff[:220]} |")
    text = "\n".join(lines) + "\n"
    (out / "results.md").write_text(text)
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=IOS / "build/stress")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--seeds", type=int, nargs="+", default=[11, 22, 33])
    ap.add_argument("--only", nargs="+", help="scenario names to keep (e.g. indoor_isr stress_cif_siebel)")
    ap.add_argument("--sim", default="iPhone 17 Pro Max")
    ap.add_argument("--summarize", action="store_true", help="only rebuild results.md from saved reports")
    args = ap.parse_args()
    (args.out / "reports").mkdir(parents=True, exist_ok=True)
    (args.out / "console").mkdir(parents=True, exist_ok=True)
    if args.summarize:
        print(summarize(args.out))
        return 0
    failures = 0
    for rnd in range(1, args.runs + 1):
        for scenario, seed in configs(args.seeds, args.only):
            name = f"{key(scenario, seed)}-r{rnd}"
            report = args.out / "reports" / f"{name}.json"
            if report.exists():
                print(f"= {name}: already done", flush=True)
                continue
            cmd = [sys.executable, str(IOS / "scripts/e2e.py"), "--sim", args.sim, "--scenario", scenario,
                   "--report", str(report)]
            if seed is not None:
                cmd += ["--seed", str(seed)]
            print(f"▶ {name}", flush=True)
            began = time.time()
            with open(args.out / "console" / f"{name}.log", "w") as console:
                code = subprocess.run(cmd, cwd=IOS, stdout=console, stderr=subprocess.STDOUT).returncode
            wall = round(time.time() - began)
            if report.exists():
                doc = json.loads(report.read_text())
                doc["wall_s"], doc["exit"] = wall, code
                report.write_text(json.dumps(doc, indent=2))
            else:
                report.write_text(json.dumps({"wall_s": wall, "exit": code, "scenarios": {scenario: {
                    "pass": False, "failures": [f"e2e.py exited {code} without a report"]}}}, indent=2))
            failures += code != 0
            print(f"  exit {code} in {wall} s", flush=True)
            summarize(args.out)
    print(summarize(args.out))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
