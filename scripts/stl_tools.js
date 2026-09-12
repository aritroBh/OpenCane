#!/usr/bin/env node
// stl_tools.js - the measuring end of the mount's verification.
//
//   node scripts/stl_tools.js vol      a.stl [b.stl ...]   volume, z range; EMPTY for a missing file
//   node scripts/stl_tools.js shells   a.stl [...]         connected shells with their volumes (a loose island = a print failure)
//   node scripts/stl_tools.js overhang a.stl [...]         downward faces steeper than 45 deg that are not on the bed, by height
//   node scripts/stl_tools.js gsupport file.gcode stlMinX stlMinY x0 x1 y0 y1 zmax
//                                                          where the slicer put support, in model coordinates
//
// Binary STL only (build_stl.ps1 writes binstl). No dependencies: the
// machines this runs on have node and nothing else.
'use strict';
const fs = require('fs');

function readTris(path) {
  const b = fs.readFileSync(path); const n = b.readUInt32LE(80); const tris = [];
  for (let i = 0, o = 84; i < n; i++, o += 50) {
    const t = [];
    for (let k = 0; k < 3; k++) t.push([b.readFloatLE(o + 12 + k * 12), b.readFloatLE(o + 16 + k * 12), b.readFloatLE(o + 20 + k * 12)]);
    tris.push(t);
  }
  return tris;
}
const triVol = ([a, b, c]) => (a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6;
const base = p => p.split(/[\\/]/).pop();

function vol(paths) {
  for (const p of paths) {
    if (!fs.existsSync(p)) { console.log(`${base(p).padEnd(36)} EMPTY`); continue; }
    const tris = readTris(p); let v = 0, zmin = Infinity, zmax = -Infinity;
    for (const t of tris) { v += triVol(t); for (const q of t) { if (q[2] < zmin) zmin = q[2]; if (q[2] > zmax) zmax = q[2]; } }
    console.log(`${base(p).padEnd(36)} ${(v / 1000).toFixed(4).padStart(9)} cm3   z ${zmin.toFixed(1)}..${zmax.toFixed(1)}   tris ${tris.length}`);
  }
}

function shells(paths) {
  for (const p of paths) {
    const tris = readTris(p);
    const vid = new Map(), parent = [];
    const key = q => q.map(x => Math.round(x * 1e4)).join(',');
    const find = i => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
    const union = (a, b) => { a = find(a); b = find(b); if (a !== b) parent[a] = b; };
    const root = [];
    for (const t of tris) {
      const ids = t.map(q => { const k = key(q); if (!vid.has(k)) { vid.set(k, parent.length); parent.push(parent.length); } return vid.get(k); });
      union(ids[0], ids[1]); union(ids[1], ids[2]); root.push(ids[0]);
    }
    const comp = new Map();
    tris.forEach((t, i) => {
      const r = find(root[i]);
      if (!comp.has(r)) comp.set(r, { vol: 0, tris: 0, min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] });
      const c = comp.get(r); c.vol += triVol(t); c.tris++;
      for (const q of t) for (let k = 0; k < 3; k++) { if (q[k] < c.min[k]) c.min[k] = q[k]; if (q[k] > c.max[k]) c.max[k] = q[k]; }
    });
    const list = [...comp.values()].sort((a, b) => b.vol - a.vol);
    const solid = list.filter(c => c.vol > 0.5);   // > 0.5 mm3: real bodies, not facet slivers
    console.log(`${base(p)}  triangles ${tris.length}  shells ${list.length} (${solid.length} with volume)`);
    solid.slice(0, 8).forEach((c, i) => console.log(`   #${i + 1}: ${(c.vol / 1000).toFixed(3)} cm3  ${c.tris} tris  x ${c.min[0].toFixed(1)}..${c.max[0].toFixed(1)} y ${c.min[1].toFixed(1)}..${c.max[1].toFixed(1)} z ${c.min[2].toFixed(1)}..${c.max[2].toFixed(1)}`));
  }
}

function overhang(paths) {
  const lim = Math.cos(45 * Math.PI / 180);
  for (const p of paths) {
    const tris = readTris(p); let zmin = Infinity;
    for (const t of tris) for (const q of t) if (q[2] < zmin) zmin = q[2];
    let onBed = 0, down = 0; const bands = new Map();
    for (const [a, c, d] of tris) {
      const u = [c[0] - a[0], c[1] - a[1], c[2] - a[2]], v = [d[0] - a[0], d[1] - a[1], d[2] - a[2]];
      const nx = u[1] * v[2] - u[2] * v[1], ny = u[2] * v[0] - u[0] * v[2], nz = u[0] * v[1] - u[1] * v[0];
      const l = Math.hypot(nx, ny, nz); if (l < 1e-9) continue;
      const area = l / 2;
      if (nz / l < -lim - 1e-6) {
        const z = (a[2] + c[2] + d[2]) / 3;
        if (z < zmin + 0.05) { onBed += area; continue; }
        down += area; const band = Math.floor(z); bands.set(band, (bands.get(band) || 0) + area);
      }
    }
    console.log(`${base(p)}  bed z=${zmin.toFixed(2)}  first layer ${onBed.toFixed(0)} mm2  downward faces past 45 deg, off the bed: ${down.toFixed(0)} mm2`);
    [...bands.entries()].sort((x, y) => x[0] - y[0]).forEach(([z, a]) => { if (a > 2) console.log(`    z ${String(z).padStart(4)}..${z + 1}: ${a.toFixed(0)} mm2`); });
  }
}

function gsupport([file, sx, sy, bx0, bx1, by0, by1, bz1]) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  let z = 0, type = '', x = 0, y = 0, first = null;
  const w = { minx: Infinity, miny: Infinity, maxx: -Infinity, maxy: -Infinity }; const sup = [];
  for (const l of lines) {
    if (l.startsWith(';TYPE:')) { type = l.slice(6).trim(); continue; }
    if (l.startsWith(';Z:')) { z = parseFloat(l.slice(3)); continue; }
    if (!l.startsWith('G1') && !l.startsWith('G0')) continue;
    const m = l.match(/X([-\d.]+)/), n = l.match(/Y([-\d.]+)/), zz = l.match(/Z([-\d.]+)/), e = l.match(/E([-\d.]+)/);
    if (zz && !m && !n) { z = parseFloat(zz[1]); continue; }
    if (m) x = parseFloat(m[1]); if (n) y = parseFloat(n[1]);
    if (!e || parseFloat(e[1]) <= 0) continue;
    if (first === null) first = z;
    if (z <= first + 0.01 && /wall/i.test(type)) { w.minx = Math.min(w.minx, x); w.maxx = Math.max(w.maxx, x); w.miny = Math.min(w.miny, y); w.maxy = Math.max(w.maxy, y); }
    if (/support/i.test(type)) sup.push([x, y, z]);
  }
  const offx = w.minx - +sx, offy = w.miny - +sy;
  const inBox = sup.filter(([px, py, pz]) => { const mx = px - offx, my = py - offy; return mx >= +bx0 && mx <= +bx1 && my >= +by0 && my <= +by1 && pz <= +bz1; });
  console.log(`${base(file)}: model offset x+${offx.toFixed(1)} y+${offy.toFixed(1)} (no rotation assumed); support points ${sup.length} total, ${inBox.length} inside x[${bx0},${bx1}] y[${by0},${by1}] z<=${bz1}`);
  return inBox.length;
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'vol') vol(args);
else if (cmd === 'shells') shells(args);
else if (cmd === 'overhang') overhang(args);
else if (cmd === 'gsupport') gsupport(args);
else { console.error('usage: stl_tools.js vol|shells|overhang|gsupport ...'); process.exit(2); }
