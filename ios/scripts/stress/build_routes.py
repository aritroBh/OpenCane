#!/usr/bin/env python3
"""
build_routes.py — route + trace data for the Step 66 stress campaign, from OpenStreetMap.

The "Google Maps-like" source is OSRM foot routing over OpenStreetMap
(routing.openstreetmap.de/routed-foot, © OpenStreetMap contributors, ODbL). For every walk it
writes, under ios/scripts/stress/:

    osm/<walk>.json      the raw OSRM response (cached; `--offline` rebuilds from these)
    routes/<walk>.json   a route file in the app's schema (Waypoint.swift CodingKeys), built the way
                         `RouteBuilder.waypoints(from:destinationName:)` builds MapKit routes: a
                         waypoint at the end of every step, spoken with the NEXT step's instruction,
                         15 m fences, 20 m for arrival, "crossing" when the line says "cross"
    traces/<walk>.json   {name, route, source, points: [[lat, lon], …]} — the path the simulated
                         walker follows (OSRM's full geometry), read by `e2e.py --trace`
    traces/<walk>.gpx    the same points as a GPX track (open it in Google Earth / gpx.studio to see it)

Walks: isr_cif (the bundled route_isr_cif.json and its own waypoints — the demo baseline),
cif_isr, isr_grainger, isr_union, cif_siebel (OSRM), isr_union_wrong_turn (the isr_union route with a
50 m wrong turn at its first real turn, then back — the "loop with recovery").
Endpoints are the `CampusPlaces.all` entrances (ios/Logic/Sources/CaneKitLogic/CampusPlaces.swift).

    python3 scripts/stress/build_routes.py            # fetch (1 request / s) and write everything
    python3 scripts/stress/build_routes.py --offline  # rebuild from osm/*.json, no network

Python 3 stdlib only. Deterministic: the same osm/*.json always gives byte-identical outputs.
"""
from __future__ import annotations

import argparse
import json
import math
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
IOS = HERE.parent.parent
BUNDLED = IOS / "CaneKit/Resources/route_isr_cif.json"
OSRM = ("https://routing.openstreetmap.de/routed-foot/route/v1/foot/"
        "{a_lon},{a_lat};{b_lon},{b_lat}?overview=full&geometries=geojson&steps=true")
EARTH = 6_371_000.0

# id → (spoken name, lat, lon): CampusPlaces.all entrances. ⚠ Keep in sync with CampusPlaces.swift.
PLACES = {
    "isr": ("the Townsend Hall doors", 40.10949, -88.22135),
    "cif": ("the CIF east entrance", 40.11242, -88.22788),
    "grainger": ("Grainger Engineering Library", 40.1125612, -88.2272830),
    "union": ("the Illini Union", 40.1098522, -88.2272312),
    "siebel": ("the Siebel Center", 40.1141046, -88.2243039),
}
OSRM_WALKS = [("cif_isr", "cif", "isr"), ("isr_grainger", "isr", "grainger"),
              ("isr_union", "isr", "union"), ("cif_siebel", "cif", "siebel")]


def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Haversine metres between (lat, lon) pairs (GeoMath.distanceMeters)."""
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH * math.asin(min(1, math.sqrt(h)))


def bearing(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Initial bearing degrees true in [0, 360) (GeoMath.bearingDegrees)."""
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return math.degrees(math.atan2(y, x)) % 360


def offset(p: tuple[float, float], bearing_deg: float, metres: float) -> tuple[float, float]:
    """Move a point `metres` along `bearing_deg` (flat earth; fine for tens of metres)."""
    n = metres * math.cos(math.radians(bearing_deg))
    e = metres * math.sin(math.radians(bearing_deg))
    return (p[0] + n / EARTH * 180 / math.pi,
            p[1] + e / (EARTH * math.cos(math.radians(p[0]))) * 180 / math.pi)


def compass(deg: float) -> str:
    return ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][round(deg / 45) % 8]


def instruction(step: dict) -> str:
    """A MapKit-style instruction for an OSRM step ("Turn left onto West Green Street.")."""
    m = step["maneuver"]
    kind, mod = m["type"], m.get("modifier", "")
    name = step.get("name") or "the path"
    if kind == "depart":
        return f"Head {compass(m.get('bearing_after', 0))} on {name}."
    if mod == "uturn":
        return f"Make a U-turn onto {name}."
    if kind in ("new name", "continue") or mod == "straight":
        return f"Continue onto {name}." if mod in ("", "straight") else f"Bear {mod} onto {name}."
    if kind in ("roundabout", "rotary", "roundabout turn", "exit roundabout"):
        return f"At the roundabout, take the exit onto {name}."
    return f"Turn {mod} onto {name}." if mod else f"Continue onto {name}."


def route_from_osrm(resp: dict, route_name: str, dest_name: str) -> dict:
    """OSRM steps → the app's route JSON, mirroring RouteBuilder.waypoints (see the module doc)."""
    steps = [s for s in resp["routes"][0]["legs"][0]["steps"]
             if s["maneuver"]["type"] != "arrive" and len(s["geometry"]["coordinates"]) >= 2]
    wps = []
    for i, s in enumerate(steps):
        lon, lat = s["geometry"]["coordinates"][-1]
        last = i == len(steps) - 1
        say = f"Arrived at {dest_name}." if last else instruction(steps[i + 1])
        wp = {"id": i + 1, "lat": round(lat, 7), "lon": round(lon, 7), "radius_m": 20 if last else 15,
              "say": say, "crossing": "cross" in say.lower()}
        if not last:
            nlon, nlat = steps[i + 1]["geometry"]["coordinates"][-1]
            wp["bearing_next_deg"] = round(bearing((lat, lon), (nlat, nlon)), 1)
        wps.append(wp)
    return {"name": route_name, "source": "OSRM foot routing over OpenStreetMap (ODbL), "
            "routing.openstreetmap.de; built by ios/scripts/stress/build_routes.py (RouteBuilder mirror); "
            "not walked", "waypoints": wps}


def geometry(resp: dict) -> list[tuple[float, float]]:
    """OSRM overview geometry as (lat, lon), consecutive duplicates dropped."""
    out: list[tuple[float, float]] = []
    for lon, lat in resp["routes"][0]["geometry"]["coordinates"]:
        p = (round(lat, 7), round(lon, 7))
        if not out or out[-1] != p:
            out.append(p)
    return out


def wrong_turn(resp: dict, points: list[tuple[float, float]]) -> tuple[list[tuple[float, float]], dict]:
    """At the first turn ≥ 60° at least 80 m into the walk: keep going straight 50 m, stop, come back."""
    walked = 0.0
    for s in resp["routes"][0]["legs"][0]["steps"]:
        m = s["maneuver"]
        turn = abs((m.get("bearing_after", 0) - m.get("bearing_before", 0) + 180) % 360 - 180)
        if m["type"] not in ("depart", "arrive") and walked >= 80 and turn >= 60:
            lon, lat = m["location"]
            corner = (round(lat, 7), round(lon, 7))
            k = min(range(len(points)), key=lambda i: dist(points[i], corner))
            over = tuple(round(v, 7) for v in offset(points[k], m["bearing_before"], 50))
            info = {"corner": list(points[k]), "overshoot_m": 50, "bearing_deg": m["bearing_before"],
                    "turn_deg": round(turn), "street": s.get("name", "")}
            return points[:k + 1] + [over, points[k]] + points[k + 1:], info
        walked += s["distance"]
    raise SystemExit("no turn of 60° or more after 80 m on isr_union")


def write_trace(name: str, route: str, source: str, points: list, extra: dict | None = None) -> None:
    (HERE / "traces").mkdir(exist_ok=True)
    length = sum(dist(a, b) for a, b in zip(points, points[1:]))
    doc = {"name": name, "route": route, "source": source, "length_m": round(length), "points": [list(p) for p in points]}
    doc.update(extra or {})
    (HERE / "traces" / f"{name}.json").write_text(json.dumps(doc, indent=1) + "\n")
    trk = "\n".join(f'      <trkpt lat="{lat}" lon="{lon}"/>' for lat, lon in points)
    (HERE / "traces" / f"{name}.gpx").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="OpenCane build_routes.py" xmlns="http://www.topografix.com/GPX/1/1">\n'
        f'  <trk><name>{name}</name><trkseg>\n{trk}\n  </trkseg></trk>\n</gpx>\n')
    print(f"  {name}: {len(points)} points, {length:.0f} m → route {route}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--offline", action="store_true", help="use osm/*.json, no network")
    args = ap.parse_args()
    (HERE / "osm").mkdir(exist_ok=True)
    (HERE / "routes").mkdir(exist_ok=True)

    bundled = json.loads(BUNDLED.read_text())
    wp_points = [(w["lat"], w["lon"]) for w in bundled["waypoints"]]
    write_trace("isr_cif", "bundled", "route_isr_cif.json waypoints in order (the e2e `clean` path)", wp_points)

    responses = {}
    for walk, a, b in OSRM_WALKS + [("isr_cif_osm", "isr", "cif")]:
        cache = HERE / "osm" / f"{walk}.json"
        if not args.offline:
            url = OSRM.format(a_lat=PLACES[a][1], a_lon=PLACES[a][2], b_lat=PLACES[b][1], b_lon=PLACES[b][2])
            resp = json.load(urllib.request.urlopen(url, timeout=30))
            if resp.get("code") != "Ok":
                raise SystemExit(f"OSRM {walk}: {resp.get('code')} {resp.get('message', '')}")
            cache.write_text(json.dumps(resp, indent=1, sort_keys=True) + "\n")
            time.sleep(1)                      # the public server's usage policy: be gentle
        responses[walk] = json.loads(cache.read_text())

    for walk, a, b in OSRM_WALKS:
        resp = responses[walk]
        route = route_from_osrm(resp, f"To {PLACES[b][0]}", PLACES[b][0])
        rel = f"scripts/stress/routes/{walk}.json"
        (IOS / rel).write_text(json.dumps(route, indent=1) + "\n")
        write_trace(walk, rel, "OSRM foot geometry (OpenStreetMap)", geometry(resp),
                    {"waypoints": len(route["waypoints"]), "osrm_distance_m": round(resp["routes"][0]["distance"])})

    pts, info = wrong_turn(responses["isr_union"], geometry(responses["isr_union"]))
    write_trace("isr_union_wrong_turn", "scripts/stress/routes/isr_union.json",
                "OSRM foot geometry with a 50 m wrong turn and recovery", pts, {"wrong_turn": info})

    # How far is OSM's idea of ISR → CIF from the recorded demo route? (README evidence, not a walk.)
    osm = geometry(responses["isr_cif_osm"])
    worst = max(min(dist(p, q) for q in [(wp_points[i][0] + (wp_points[i + 1][0] - wp_points[i][0]) * t / 20,
                                           wp_points[i][1] + (wp_points[i + 1][1] - wp_points[i][1]) * t / 20)
                                          for i in range(len(wp_points) - 1) for t in range(21)]) for p in osm)
    print(f"  isr_cif_osm: OSRM {responses['isr_cif_osm']['routes'][0]['distance']:.0f} m; farthest OSM point "
          f"from the recorded route {worst:.0f} m")


if __name__ == "__main__":
    main()
