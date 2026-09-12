#!/usr/bin/env python3
"""
streetview_stim.py — High-speed Street View Route Stimulator & Multimodal Perception Engine

Simulates walking the demo route (ISR Townsend Hall -> CIF) through real Google Street View
imagery at a fast cadence (1–3 seconds per viewpoint). At each frame:
  1. Computes navigation geometry (waypoint arrival, remaining metres, turn bearing).
  2. Runs Apple Vision scene classification & OCR text recognition on the view.
  3. Synthesizes Sundar Pichai / Project Astra style multimodal perception (spatial commentary,
     hazard watch, sign warnings).
  4. Renders a live terminal HUD and outputs an interactive HTML/Web dashboard with
     synchronized images, vision overlays, haptic pulses, and dataset JSONL.

Usage:
    python3 ios/scripts/streetview_stim.py                    # 2.0s per viewpoint
    python3 ios/scripts/streetview_stim.py --cadence 1.0      # 1.0s fast stim
    python3 ios/scripts/streetview_stim.py --fast             # instant batch processing
    python3 ios/scripts/streetview_stim.py --export-html      # builds interactive web HUD
"""

import argparse
import base64
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
FRAMES_DIR = ROOT / "ios" / "scripts" / "streetview"
ROUTE_FILE = ROOT / "ios" / "CaneKit" / "Resources" / "route_isr_cif.json"
OUT_DIR = ROOT / "ios" / "build" / "streetview_stim"

# Hazard detection taxonomy (CaneKitLogic / OnDeviceVision)
HAZARD_MAP = {
    "fence": "a fence", "stairs": "stairs", "staircase": "stairs", "scooter": "a scooter",
    "bicycle": "a bicycle", "motorcycle": "a motorcycle", "pole": "a pole",
    "fire_hydrant": "a fire hydrant", "hydrant": "a fire hydrant", "bench": "a bench",
    "trash_can": "a trash can", "snow": "snow", "ice": "ice", "dog": "a dog",
    "crosswalk": "a pedestrian crossing", "curb": "a curb edge", "traffic_light": "traffic signal"
}

BORING_LABELS = {
    "outdoor", "structure", "material", "blue_sky", "sky", "daytime",
    "night_sky", "land", "people", "adult"
}

def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0  # Earth radius in metres
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0)**2
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))

def bearing_deg(lat1, lon1, lat2, lon2):
    y = math.sin(math.radians(lon2 - lon1)) * math.cos(math.radians(lat2))
    x = math.cos(math.radians(lat1)) * math.sin(math.radians(lat2)) - \
        math.sin(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.cos(math.radians(lon2 - lon1))
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0

def run_vision_on_frames(frames_json_path):
    """Run swift vision probe to extract on-device Vision labels and OCR texts."""
    probe_script = ROOT / "ios" / "scripts" / "vision_probe.swift"
    res = subprocess.run(["swift", str(probe_script), str(FRAMES_DIR)],
                         capture_output=True, text=True, check=True)
    
    # Parse output blocks
    results = {}
    current_file = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith("── "):
            parts = line.split()
            current_file = parts[1]
            results[current_file] = {"sees": [], "texts": [], "says": ""}
        elif line.startswith("sees:") and current_file:
            labels_raw = line[5:].strip()
            results[current_file]["sees"] = [l.strip() for l in labels_raw.split(",") if l.strip()]
        elif line.startswith("text:") and current_file:
            texts_raw = line[5:].strip()
            results[current_file]["texts"] = [t.strip() for t in texts_raw.split("|") if t.strip()]
        elif line.startswith("says:") and current_file:
            results[current_file]["says"] = line[5:].strip()
            if results[current_file]["says"] == "(nothing)":
                results[current_file]["says"] = ""
    return results

def synthesize_astra_commentary(frame_name, entry, vision_data, current_wp, next_wp, dist_to_next):
    """Generate Sundar Pichai / Astra-style natural multimodal narration."""
    labels = vision_data.get("sees", [])
    texts = vision_data.get("texts", [])
    says = vision_data.get("says", "")
    
    # Clean label names
    clean_labels = [l.split()[0] for l in labels]
    
    lines = []
    # 1. Navigation context
    if dist_to_next < 20:
        lines.append(f"Arriving at {next_wp['name']}.")
    else:
        lines.append(f"{dist_to_next:.0f} metres to {next_wp['name']}.")
    
    # 2. Scene perception (Astra style)
    if "crosswalk" in clean_labels:
        lines.append("Marked pedestrian crosswalk visible ahead.")
    elif "path" in clean_labels or "sidewalk" in clean_labels:
        lines.append("Clear pedestrian walkway ahead.")
    elif "furniture" in clean_labels or "table" in clean_labels:
        lines.append("Indoor vestibule: tables and seating area.")
        
    if "automobile" in clean_labels or "car" in clean_labels:
        lines.append("Vehicles moving on adjacent roadway.")
    if "manhole" in clean_labels:
        lines.append("Utility access cover on pavement.")
        
    # 3. Text/sign perception
    if texts:
        lines.append(f"Sign reads: \"{texts[0]}\".")
        
    # 4. Immediate Hazard Watch
    hazards = []
    for l in clean_labels:
        if l in HAZARD_MAP:
            hazards.append(HAZARD_MAP[l])
    if hazards:
        lines.append(f"Caution: {hazards[0]} detected near path.")
        
    return " ".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Street View Route Stimulator & Multimodal Perception Engine")
    parser.add_argument("--cadence", type=float, default=2.0, help="Stimulation cadence in seconds per frame (default 2.0s)")
    parser.add_argument("--fast", action="store_true", help="Instant execution without playback delays")
    parser.add_argument("--export-html", action="store_true", default=True, help="Generate interactive Web HUD")
    args = parser.parse_args()

    print("=" * 80)
    print(" 🦯  OpenCane / CaneKit: Google Street View Route Stimulator (Astra Edition)")
    print(f" Cadence: {args.cadence:.1f}s per viewpoint | Mode: {'Fast batch' if args.fast else 'Real-time Playback'}")
    print("=" * 80)

    # 1. Load Route & Frames
    with open(ROUTE_FILE, "r") as f:
        route = json.load(f)
    waypoints = route["waypoints"]

    with open(FRAMES_DIR / "frames.json", "r") as f:
        frames = json.load(f)

    print(f"Loaded {len(waypoints)} waypoints and {len(frames)} Street View panoramic frames.")
    print("Running Apple Vision Neural Engine inference over all frames...")
    vision_results = run_vision_on_frames(FRAMES_DIR / "frames.json")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    db_records = []
    html_items = []

    # 2. Replay loop
    wp_idx = 0
    t0 = time.time()
    
    for i, frame in enumerate(frames):
        fname = frame["file"]
        flat, flon = frame["lat"], frame["lon"]
        heading = frame.get("heading", 0)
        v_data = vision_results.get(fname, {"sees": [], "texts": [], "says": ""})

        # Find closest and next waypoints
        closest_wp = min(waypoints, key=lambda w: haversine(flat, flon, w["lat"], w["lon"]))
        target_wp = waypoints[min(wp_idx + 1, len(waypoints) - 1)]
        dist_to_target = haversine(flat, flon, target_wp["lat"], target_wp["lon"])

        if dist_to_target <= target_wp.get("radius_m", 15):
            wp_idx = min(wp_idx + 1, len(waypoints) - 1)
            target_wp = waypoints[min(wp_idx + 1, len(waypoints) - 1)]
            dist_to_target = haversine(flat, flon, target_wp["lat"], target_wp["lon"])

        # Astra commentary
        spoken = synthesize_astra_commentary(fname, frame, v_data, closest_wp, target_wp, dist_to_target)

        # Haptic pulse simulation
        if dist_to_target < 15:
            haptic_pattern = "[ • • • ] ARRIVAL PULSE"
        elif "crosswalk" in str(v_data.get("sees")):
            haptic_pattern = "[  •••  ] CROSSING VIBRATION"
        else:
            haptic_pattern = "[   •   ] STEADY GUIDANCE"

        # Record for database
        rec = {
            "index": i + 1,
            "file": fname,
            "timestamp": time.time() - t0,
            "lat": flat,
            "lon": flon,
            "heading": heading,
            "current_place": closest_wp["name"],
            "target_place": target_wp["name"],
            "distance_m": round(dist_to_target, 1),
            "vision_labels": v_data["sees"][:5],
            "ocr_text": v_data["texts"],
            "spoken_commentary": spoken,
            "haptic": haptic_pattern
        }
        db_records.append(rec)

        # Terminal Display HUD
        os.system("clear") if not args.fast and sys.stdout.isatty() else None
        print("\n" + "─" * 80)
        print(f" ▶ VIEWPOINT [{i+1}/{len(frames)}]: {fname:24s} | HEADING: {heading:3.0f}°")
        print(f" 📍 GPS: ({flat:.6f}, {flon:.6f}) | 🎯 NEXT: {target_wp['name']} ({dist_to_target:.0f}m)")
        print(f" 👁️  VISION SEES: {', '.join(v_data['sees'][:4]) if v_data['sees'] else 'Clear path'}")
        if v_data['texts']:
            print(f" 🔤 OCR TEXT:    {' | '.join(v_data['texts'])}")
        print(f" 📳 HAPTIC:      {haptic_pattern}")
        print(f" 🗣️  ASTRA SAYS:  \"{spoken}\"")
        print("─" * 80)

        # Prepare HTML item with base64 embedded thumbnail
        img_path = FRAMES_DIR / fname
        if img_path.exists():
            with open(img_path, "rb") as img_f:
                b64_img = base64.b64encode(img_f.read()).decode("utf-8")
        else:
            b64_img = ""

        html_items.append({
            "rec": rec,
            "b64": b64_img
        })

        if not args.fast:
            time.sleep(args.cadence)

    # 3. Write Multimodal JSONL Database
    db_file = OUT_DIR / "streetview_stim_db.jsonl"
    with open(db_file, "w") as f:
        for r in db_records:
            f.write(json.dumps(r) + "\n")
    print(f"\n✅ Multimodal dataset records saved to: {db_file}")

    # 4. Generate Interactive Web Dashboard
    if args.export_html:
        html_file = OUT_DIR / "index.html"
        cards_html = ""
        for item in html_items:
            r = item["rec"]
            b64 = item["b64"]
            labels_pills = "".join(f"<span class='badge'>{l}</span>" for l in r["vision_labels"])
            cards_html += f"""
            <div class="viewpoint-card" id="vp-{r['index']}">
                <div class="card-header">
                    <h3>#{r['index']} · {r['file']}</h3>
                    <span class="heading-tag">🧭 {r['heading']}°</span>
                </div>
                <div class="media-row">
                    <img src="data:image/jpeg;base64,{b64}" alt="{r['file']}" class="pano-img" />
                    <div class="telemetry-box">
                        <div class="metric"><label>Nearest Landmark:</label> <b>{r['current_place']}</b></div>
                        <div class="metric"><label>Target Waypoint:</label> <b>{r['target_place']} ({r['distance_m']}m)</b></div>
                        <div class="metric"><label>Haptic Signal:</label> <span class="haptic-badge">{r['haptic']}</span></div>
                        <div class="metric labels-wrap"><label>Vision Detections:</label><br/>{labels_pills}</div>
                        <div class="speech-bubble">
                            <span class="speaker-icon">🗣️</span>
                            <div class="speech-text">"{r['spoken_commentary']}"</div>
                        </div>
                    </div>
                </div>
            </div>
            """

        html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>OpenCane / Street View Multimodal Perception HUD</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0c0f14; color: #f0f3f6; margin: 0; padding: 24px; }}
        h1 {{ margin-top: 0; color: #38bdf8; font-weight: 700; }}
        .subtitle {{ color: #94a3b8; margin-bottom: 24px; font-size: 1.1em; }}
        .hud-stats {{ display: flex; gap: 16px; margin-bottom: 24px; }}
        .stat-card {{ background: #18202c; border: 1px solid #283548; padding: 14px 20px; border-radius: 10px; flex: 1; }}
        .stat-card .val {{ font-size: 1.8em; font-weight: bold; color: #38bdf8; }}
        .stat-card .lbl {{ font-size: 0.85em; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.5px; }}
        .viewpoint-card {{ background: #131924; border: 1px solid #222e3f; border-radius: 12px; margin-bottom: 24px; overflow: hidden; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }}
        .card-header {{ background: #1a2332; padding: 12px 20px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #243347; }}
        .card-header h3 {{ margin: 0; font-size: 1.15em; color: #e2e8f0; }}
        .heading-tag {{ background: #0369a1; padding: 4px 10px; border-radius: 6px; font-size: 0.85em; font-weight: 600; }}
        .media-row {{ display: flex; flex-direction: row; gap: 20px; padding: 18px; }}
        .pano-img {{ width: 520px; height: 280px; object-fit: cover; border-radius: 8px; border: 1px solid #2d3b4e; }}
        .telemetry-box {{ flex: 1; display: flex; flex-direction: column; gap: 10px; }}
        .metric label {{ font-size: 0.8em; color: #94a3b8; text-transform: uppercase; }}
        .badge {{ display: inline-block; background: #1e293b; color: #38bdf8; padding: 3px 8px; border-radius: 5px; font-size: 0.8em; margin: 2px 4px 2px 0; border: 1px solid #334155; }}
        .haptic-badge {{ color: #a78bfa; font-family: monospace; font-weight: bold; }}
        .speech-bubble {{ margin-top: auto; background: #1e293b; border-left: 4px solid #38bdf8; padding: 12px 16px; border-radius: 0 8px 8px 0; display: flex; gap: 12px; align-items: center; }}
        .speech-bubble .speaker-icon {{ font-size: 1.6em; }}
        .speech-bubble .speech-text {{ font-size: 1.05em; line-height: 1.4; color: #f8fafc; font-weight: 500; }}
    </style>
</head>
<body>
    <h1>🦯 OpenCane: Real-Time Street View Stimulator & Astra Vision HUD</h1>
    <div class="subtitle">Autonomous Multimodal Navigation Simulation · ISR Townsend Hall → Campus Instructional Facility (UIUC)</div>
    
    <div class="hud-stats">
        <div class="stat-card"><div class="val">{len(frames)}</div><div class="lbl">Route Viewpoints</div></div>
        <div class="stat-card"><div class="val">989 m</div><div class="lbl">Total Distance</div></div>
        <div class="stat-card"><div class="val">{args.cadence:.1f}s</div><div class="lbl">Stimulation Interval</div></div>
        <div class="stat-card"><div class="val">Active</div><div class="lbl">Vision & Hazard Watch</div></div>
    </div>

    <div class="cards-container">
        {cards_html}
    </div>
</body>
</html>
"""
        with open(html_file, "w", encoding="utf-8") as f:
            f.write(html_content)
        print(f"✅ Interactive HTML dashboard generated at: {html_file}")
        print("=" * 80)

if __name__ == "__main__":
    main()
