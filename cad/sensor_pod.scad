// sensor_pod.scad — hooded tube clamp for a VL53L1X breakout (Adafruit 25.5 x 17.5 x 4.6 mm)
// Clamps a 12.7 mm cane shaft, aims the sensor down-forward at the ground ahead.
// DRAFT: unrendered. Verify the sensor pocket against your actual breakout.
// Print: PETG, hood opening up, may need supports under the hood lip.
// LEGACY (ESP32 era, cut 2026-09-10 when the app went phone-only): do not print for the demo.
// Sized for a 12.7 mm aluminium/graphite shaft; the prototype stick is 27.65 mm (measured
// 2026-09-12), so nothing here fits it. The live mount is hardware/mount_screwless/ (see
// cad/README.md and hardware/README.md). Not rendered by any script (scripts/build_stl.ps1 covers
// hardware/ only); no tests; no owner on the current team. Units: millimetres throughout.
// Why it existed: the VL53L1X ground-distance sensor for the grip firmware's local drop-off /
// step-up fail-safe (firmware/canekit_grip/tof.cpp; README says aim ~40-60 cm ahead of the tip).
// The phone-only app replaced it with LiDAR ground hazards (AGENTS.md, Step 11).

$fn = 64;
shaft_d = 12.7; clear = 0.4;
clamp_len = 22; clamp_wall = 4;
aim_deg = 35;                 // tilt down from the shaft axis
brd_l = 26; brd_w = 18; brd_t = 5;   // sensor board pocket (adds clearance)
hood_len = 10;                // lip over the ToF window to shed rain
bolt_d = 3.2;

// Split ring clamping the shaft (axis +Z), with a pinch-bolt ear on the +Y side.
module clamp_ring() {
    difference() {
        cylinder(d = shaft_d + 2*clear + 2*clamp_wall, h = clamp_len);
        translate([0,0,-1]) cylinder(d = shaft_d + 2*clear, h = clamp_len + 2);
        // split
        translate([-1, 0, -1]) cube([2, shaft_d, clamp_len + 2]);
        // pinch bolt
        translate([0, shaft_d/2 + clear + 3, clamp_len/2]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = 30, center = true);
    }
    // bolt ears
    difference() {
        translate([-6, shaft_d/2 + clear, 0]) cube([12, 6, clamp_len]);
        translate([-1, shaft_d/2 - 1, -1]) cube([2, 10, clamp_len + 2]);
        translate([0, shaft_d/2 + clear + 3, clamp_len/2]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = 30, center = true);
    }
}
// Open-fronted box for the breakout: board pocket, a window for the sensor, a cable slot at the
// bottom, and hood_len of wall beyond the board as the rain hood.
module sensor_box() {
    difference() {
        translate([-brd_w/2 - 2, -brd_t - 4, 0]) cube([brd_w + 4, brd_t + 4, brd_l + 4 + hood_len]);
        translate([-brd_w/2, -brd_t - 2, 2]) cube([brd_w, brd_t, brd_l]);         // board pocket
        translate([-brd_w/2 + 2, -brd_t - 5, brd_l/2 - 4]) cube([brd_w - 4, 4, 8]); // window
        translate([-3, -brd_t - 2, -1]) cube([6, brd_t, 4]);                          // cable slot
    }
}
clamp_ring();
translate([0, -(shaft_d/2 + clear + clamp_wall), clamp_len/2])
    rotate([aim_deg, 0, 0]) translate([0, 0, -brd_l/2 - 6]) sensor_box();
