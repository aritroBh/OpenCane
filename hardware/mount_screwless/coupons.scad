// =====================================================================
// OpenCane screwless mount - FIT COUPONS
// =====================================================================
// Print this FIRST. It is ~25 minutes and it decides three numbers that
// every other part depends on. Printing the real parts before these is
// how you burn three hours and a spool finding out the bore is 0.2 mm
// tight.
//
// Print settings: the same profile you will use for the real parts.
// 0.4 nozzle, 0.2 layer, 4 walls, 25% gyroid, PETG. If you change the
// nozzle or the layer height afterwards, the numbers move - reprint.
//
// WHAT TO DO WITH IT
//
// 1. BORE RINGS (row 1, NOTCHED 1/2/3/4 = 0.20/0.30/0.40/0.50 clearance)
//    Slide each onto the actual cane at the spot the collar will sit.
//    You want the one that slides on with firm thumb pressure and does
//    not rattle. Too tight is wrong too - the collet needs room to close.
//    Put that number in screwless_mount.scad as `bore_clear`.
//
// 2. THREAD PAIR (row 2)
//    Screw the small ring onto the threaded stub. It should turn by hand
//    for its whole length with no tool and no slop you can feel at the
//    top. Binds -> raise `thr_clear` by 0.1. Wobbles -> drop it by 0.1.
//
// 3. DOVETAIL PAIR (row 3, NOTCHED 1/2/3 = 0.15/0.25/0.35 clearance)
//    Slide each tenon into its socket. You want it to slide with thumb
//    pressure and stay put when you shake it. Put that number in
//    `dt_clear`.
//
// Coupons are identified by NOTCHES, not printed numbers: count the
// notches in the rim, fewest = smallest clearance. Notches are used
// because OpenSCAD's text() needs fontconfig, which the portable Windows
// snapshot does not ship - text() there renders as nothing at all and you
// get four identical unlabelled rings. Notches also read by thumb, which
// matters on this project.
//
// Write the three numbers on the coupon with a paint pen when you are
// done, and tell the next person. They are cane- and printer-specific.
// =====================================================================

use <screwless_mount.scad>

/* [What to print] */
what = "all"; // [all, bore, thread, dovetail]

/* [Copied from screwless_mount.scad - keep in sync] */
pole_d       = 28.70;
collar_wall  = 4.20;
grip_ribs    = 8;
rib_h        = 0.50;
rib_w        = 1.60;
thr_pitch    = 3.00;
thr_depth    = 1.20;
dt_wide      = 20.0;
dt_narrow    = 14.0;
dt_depth     = 7.0;

/* [Coupon settings] */
ring_h       = 10.0;   // mm, height of each bore ring.
bore_tests   = [0.20, 0.30, 0.40, 0.50];   // bore_clear values to try
dt_tests     = [0.15, 0.25, 0.35];         // dt_clear values to try
thr_test     = 0.35;   // thr_clear to try on the thread pair
notch_d      = 1.20;   // mm, identity notch depth.
notch_w      = 2.00;   // mm, identity notch width.
gap          = 8.0;    // mm, spacing between coupons on the plate.

$fa = 2;
$fs = 0.5;
eps = 0.01;

// ---------------------------------------------------------------- bore
module bore_ring(bc) {
    br = (pole_d + bc) / 2;
    orr = br + collar_wall;
    difference() {
        cylinder(h = ring_h, r = orr);
        translate([0, 0, -eps]) cylinder(h = ring_h + 2 * eps, r = br);
        for (i = [0 : grip_ribs - 1])
            rotate([0, 0, i * 360 / grip_ribs])
                translate([br - rib_h, 0, -eps])
                    cylinder(h = ring_h + 2 * eps, r = rib_w / 2, $fn = 12);
        // identity notches in the top rim: 1 notch = the first value in
        // bore_tests, 2 = the second, and so on.
        n = search([bc], bore_tests)[0] + 1;
        for (k = [0 : n - 1])
            rotate([0, 0, 90 + k * 13])
                translate([orr - 1.2, 0, ring_h - notch_d])
                    cube([3, notch_w, notch_d + eps], center = false);
    }
}

module bore_row() {
    step = pole_d + 2 * collar_wall + gap;
    for (i = [0 : len(bore_tests) - 1])
        translate([i * step, 0, 0]) bore_ring(bore_tests[i]);
}

// -------------------------------------------------------------- thread
// Short lengths of the real thread, so the fit you measure is the fit
// you get. Geometry is duplicated from screwless_mount.scad rather than
// imported, because that file's thread is wrapped inside the collar.
module thread_profile2(minor, depth) {
    union() {
        circle(r = minor);
        polygon([[minor - eps, -thr_pitch * 0.42],
                 [minor + depth, -thr_pitch * 0.20],
                 [minor + depth,  thr_pitch * 0.20],
                 [minor - eps,  thr_pitch * 0.42]]);
    }
}

module thread2(len, minor, depth) {
    turns = len / thr_pitch;
    linear_extrude(height = len, twist = -360 * turns,
                   slices = max(24, ceil(turns * 24)), convexity = 12)
        thread_profile2(minor, depth, $fs = 0.9, $fa = 4);
}

module thread_pair() {
    br    = (pole_d + 0.40) / 2;
    core  = br + collar_wall;
    minor = core - thr_depth;
    tl    = 12;
    // male stub
    difference() {
        union() {
            cylinder(h = 3, r = core + 1);
            translate([0, 0, 3]) thread2(tl, minor, thr_depth);
        }
        translate([0, 0, -eps]) cylinder(h = tl + 4, r = br);
    }
    // female ring
    translate([2 * core + gap + 10, 0, 0])
        difference() {
            cylinder(h = tl, r = core + 4);
            translate([0, 0, -eps]) thread2(tl + 2, minor + thr_test, thr_depth);
            for (i = [0 : 9])
                rotate([0, 0, i * 36])
                    translate([core + 4, 0, -eps])
                        cylinder(h = tl + 2, r = 2.5, $fn = 20);
        }
}

// ------------------------------------------------------------ dovetail
module dt_sect(grow) {
    polygon([[-(dt_narrow / 2 + grow), -grow],
             [ (dt_narrow / 2 + grow), -grow],
             [ (dt_wide  / 2 + grow),  dt_depth + grow],
             [-(dt_wide  / 2 + grow),  dt_depth + grow]]);
}

module dt_pair(dc) {
    l = 18;
    n = search([dc], dt_tests)[0] + 1;
    // tenon on a base
    difference() {
        union() {
            translate([-16, -3, 0]) cube([32, 3, l]);
            translate([0, 3 - eps, 0]) rotate([0, 0, 0])
                linear_extrude(height = l, convexity = 6) dt_sect(0);
            translate([-16, 0, 0]) cube([32, 3, l]);
        }
        // identity notches along the top edge of the base
        for (k = [0 : n - 1])
            translate([-12 + k * 5, -3.1, l - notch_d])
                cube([notch_w, 4, notch_d + eps]);
    }
    // socket block
    translate([0, 34, 0])
        difference() {
            translate([-16, 0, 0]) cube([32, dt_depth + 5, l]);
            translate([0, -eps, -eps])
                linear_extrude(height = l + 2, convexity = 6) dt_sect(dc);
        }
}

module dt_row() {
    for (i = [0 : len(dt_tests) - 1])
        translate([i * 44, 0, 0]) dt_pair(dt_tests[i]);
}

// ----------------------------------------------------------------- lay
if (what == "all") {
    bore_row();
    translate([0, 70, 0]) thread_pair();
    translate([0, 130, 0]) dt_row();
} else if (what == "bore")     bore_row();
else if (what == "thread")     thread_pair();
else if (what == "dovetail")   dt_row();

echo(str("coupons: bore ", bore_tests, "  dt ", dt_tests, "  thr_clear ", thr_test));
