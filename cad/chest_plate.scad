// chest_plate.scad — flat chest/lanyard plate with a GoPro-style 3-prong mount
// so the jackw01 phone clamp (2-prong male) snaps on. Hedge against motion blur on the cane.
// DRAFT: unrendered. Check prong spacing against your printed phone clamp before relying on it.
// Print: flat, PETG, no supports.
// LEGACY (ESP32 era, cut 2026-09-10 when the app went phone-only): do not print for the demo.
// Sized for a 12.7 mm aluminium/graphite shaft; the prototype stick is 27.65 mm (measured
// 2026-09-12), so nothing here fits it. The live mount is hardware/mount_screwless/ (see
// cad/README.md and hardware/README.md). Not rendered by any script (scripts/build_stl.ps1 covers
// hardware/ only); no tests; no owner on the current team. Units: millimetres throughout.
// Why it existed: the plan's hedge if the phone on the cane blurred too much — the same GoPro-knuckle
// phone holder snaps onto the chest instead (docs/ideas.md "Hedge": a 2025 study measured cane-mounted
// camera tracking at 55-58 % outdoors vs > 98 % head-mounted). Never printed or tested; the
// phone-only app assumes the cane mount.

// Circle facets for every cylinder in this file.
$fn = 48;
// Plate outline (width, height, thickness, corner radius), mm.
plate_w = 70; plate_h = 90; plate_t = 4; corner_r = 8;
// Four strap slots: slot length (a 25 mm webbing strap passes through it) and slot width, mm.
slot_w = 26; slot_h = 4;      // 25 mm webbing
// GoPro-style prongs: thickness, gap between prongs, height to the bolt axis, rounded-end radius,
// and the clearance hole for the M5 thumb screw. Unverified against a real GoPro accessory.
prong_t = 3; prong_gap = 3.5; prong_h = 14; prong_r = 7.5; bolt_d = 5.3;
prongs = 3;                   // 3 = base (female) mates with 2-prong accessories

// Rounded-rectangle base plate lying on z = 0.
module plate() {
    hull() for (x = [-1,1], y = [-1,1])
        translate([x*(plate_w/2 - corner_r), y*(plate_h/2 - corner_r), 0]) cylinder(r = corner_r, h = plate_t);
}
// Through-cutters for the four strap slots, two near each long edge.
module slots() {
    for (y = [-1, 1]) for (x = [-1, 1])
        translate([x*(plate_w/2 - 12) - slot_h/2, y*(plate_h/2 - 14) - slot_w/2, -1])
            cube([slot_h, slot_w, plate_t + 2]);
}
// The prongs standing on the plate's top face, with the shared bolt hole through their rounded ends.
module prong_set() {
    total = prongs*prong_t + (prongs-1)*prong_gap;
    difference() {
        union() for (i = [0:prongs-1])
            translate([-total/2 + i*(prong_t + prong_gap), 0, plate_t - 0.01])
                hull() {
                    translate([0, -prong_r, 0]) cube([prong_t, 2*prong_r, 0.01]);
                    translate([0, 0, prong_h]) rotate([0, 90, 0]) cylinder(r = prong_r, h = prong_t);
                }
        translate([-total/2 - 1, 0, plate_t + prong_h]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = total + 2);
    }
}
difference() { plate(); slots(); }
prong_set();
