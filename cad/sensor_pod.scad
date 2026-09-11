// sensor_pod.scad — hooded tube clamp for a VL53L1X breakout (Adafruit 25.5 x 17.5 x 4.6 mm)
// Clamps a 12.7 mm cane shaft, aims the sensor down-forward at the ground ahead.
// DRAFT: unrendered. Verify the sensor pocket against your actual breakout.
// Print: PETG, hood opening up, may need supports under the hood lip.

$fn = 64;
shaft_d = 12.7; clear = 0.4;
clamp_len = 22; clamp_wall = 4;
aim_deg = 35;                 // tilt down from the shaft axis
brd_l = 26; brd_w = 18; brd_t = 5;   // sensor board pocket (adds clearance)
hood_len = 10;                // lip over the ToF window to shed rain
bolt_d = 3.2;

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
