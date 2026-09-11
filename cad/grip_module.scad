// grip_module.scad — split grip sleeve for a folding white cane
// Holds: ESP32 (XIAO ESP32-S3 by default), 2x 10mm coin ERM motors, 500mAh LiPo.
// DRAFT: unrendered. Open in OpenSCAD, press F5, check every pocket before F6/export.
// Print: split face down, no supports, PETG, 4 walls. TPU overgrip optional.

$fn = 64;

// ---- cane ----
shaft_d      = 12.7;   // Ambutech aluminum/graphite = 12.7 mm. Fiberglass = 22.2 mm.
shaft_clear  = 0.4;    // radial clearance
// ---- sleeve ----
len          = 120;    // along the cane
od           = 36;     // outer diameter of grip
wall_min     = 2.4;
// ---- ESP32 bay (XIAO: 21 x 17.5 x ~5 with headers; Feather S3: 51 x 23 x 8) ----
mcu_l = 23; mcu_w = 19; mcu_h = 6;
// ---- battery bay (Adafruit 500mAh: 36 x 29 x 4.75) ----
bat_l = 37; bat_w = 30; bat_h = 5.5;
// ---- motors ----
mot_d = 10.4; mot_h = 3.2;
// ---- join ----
bolt_d = 3.2; nut_d = 6.4; nut_h = 2.6;   // M3
// ---- cable / usb ----
usb_w = 10; usb_h = 4;

split_gap = 0.2;

module shell() { cylinder(d = od, h = len); }

module shaft_bore() {
    translate([0,0,-1]) cylinder(d = shaft_d + 2*shaft_clear, h = len + 2);
}

// bays are cut into the +Y half (electronics half), motors into both halves at ±X
module mcu_bay() {
    translate([-mcu_w/2, shaft_d/2 + shaft_clear + 1.2, 8]) cube([mcu_w, mcu_h, mcu_l]);
    // USB-C window out the top end
    translate([-usb_w/2, shaft_d/2 + shaft_clear + 1.2 + (mcu_h-usb_h)/2, 8 + mcu_l - 0.01])
        cube([usb_w, usb_h, len]);
}
module bat_bay() {
    translate([-bat_w/2, shaft_d/2 + shaft_clear + 1.2, 8 + mcu_l + 6]) cube([bat_w, bat_h, bat_l]);
}
module wire_channel() {
    // channel from bays down to motor pockets, both sides
    for (s = [-1, 1])
        translate([s*(od/2 - 5) - 1.5, shaft_d/2 + shaft_clear, 8]) cube([3, 3, len - 16]);
    // exit channel to the shaft (for ToF pod wire) at the bottom
    translate([-2, 0, -1]) cube([4, od/2, 10]);
}
module motor_pockets() {
    // one motor under the thumb (left), one under the index (right), 30 mm from top
    for (s = [-1, 1])
        translate([s*(od/2 - mot_h + 0.01), 0, len - 30])
            rotate([0, s*90, 0]) cylinder(d = mot_d, h = mot_h + 1);
}
module bolts() {
    for (z = [12, len/2, len - 12])
        translate([0, 0, z]) rotate([90, 0, 0]) {
            cylinder(d = bolt_d, h = od + 2, center = true);
            // nut trap on -Y face, cap recess on +Y face
            translate([0, 0, -(od/2 - nut_h)]) cylinder(d = nut_d, h = nut_h + 1, $fn = 6);
            translate([0, 0, od/2 - 2.5]) cylinder(d = 6, h = 3);
        }
}
module grip_texture() {
    for (i = [0:11])
        rotate([0, 0, i*30]) translate([od/2 - 0.6, 0, 6]) cylinder(d = 2.2, h = len - 12);
}

module body() {
    difference() {
        shell();
        shaft_bore();
        mcu_bay();
        bat_bay();
        wire_channel();
        motor_pockets();
        bolts();
        grip_texture();
    }
}

// split along XZ plane into two halves and lay both flat for printing
module half(sign) {
    intersection() {
        body();
        translate([-od, sign > 0 ? split_gap/2 : -od - split_gap/2, -1]) cube([2*od, od, len + 2]);
    }
}

translate([-od - 4, 0, 0]) rotate([90, 0, 0])  half(1);    // electronics half
translate([ od + 4, 0, 0]) rotate([-90, 0, 0]) half(-1);   // plain half
