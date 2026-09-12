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
// 1. BORE RINGS (row 1, NOTCHED 1..5 = absolute BORE DIAMETER, mm)
//      1 notch  27.85     4 notches 28.95
//      2 notches 28.25    5 notches 29.15
//      3 notches 28.45
//    These are bore diameters, not clearances, because the cane diameter
//    itself is disputed: the dial caliper says 27.65 mm, the repo and the
//    hardware brief say 28.75 mm, and 1.128 in (28.65) was quoted once.
//    That is a 1.1 mm spread - three times any sane clearance - so the
//    rings bracket ALL of it and the cane decides.
//
//    Slide each onto the real cane AT THE EXACT SPOT THE COLLAR SITS -
//    not up from the tip, canes taper. Record the whole pattern ("1,2,3
//    will not go; 4 goes firm; 5 rattles"), not just the winner. Then:
//      pole_d = (the SMALLEST ring that goes on at all) - 0.10
//    NOT minus 0.35. A rigid 10 mm ring that goes on with firm thumb
//    pressure has about 0.05-0.15 mm of clearance on diameter, not 0.35,
//    so the old formula came out ~0.25 mm small and a collet bored that
//    tight will not reach the cane at all before the nut bottoms out.
//    If you printed these in PLA and the collar will be PETG, subtract a
//    further 0.06 mm - or just take the larger ring when you are borderline.
//
//    bore_clear is NOT an output of this test. These rings are rigid; the
//    collar is a collet that closes. Set bore_clear as a design decision
//    (0.40 today) and let collet_squeeze take it up.
//
//    Then tell the rest of the team, because hardware/mount/ is still
//    modelled at 28.75 and one of the two folders is wrong.
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
pole_d       = 27.65;   // dial caliper, Sep 11. Disputed - see above.
collar_wall  = 4.20;
grip_ribs    = 8;
rib_h        = 0.50;
rib_w        = 1.60;
thr_pitch    = 3.00;
thr_depth    = 1.20;
thr_duty     = 0.25;
thr_crest    = 0.10;
thr_axial    = 0.25;
dt_wide      = 20.0;
dt_narrow    = 14.0;
dt_depth     = 7.0;

/* [Coupon settings] */
ring_h       = 10.0;   // mm, height of each bore ring.
// Even 0.30 steps from just above the smallest candidate. The old set
// started at 27.85, ABOVE the 27.65 caliper reading, so if the caliper was
// right the smallest ring still fitted and the test had no lower bracket -
// it could only contradict itself. It also put 28.65 and 28.75 inside one
// 0.50 mm gap. This set brackets 27.65 from below and halves that gap.
bore_tests   = [27.75, 28.05, 28.35, 28.65, 28.95];  // absolute BORE diameters
dt_tests     = [0.15, 0.25, 0.35];         // dt_clear values to try
thr_test     = 0.35;   // thr_clear to try on the thread pair
notch_d      = 1.20;   // mm, identity notch depth.
notch_w      = 2.00;   // mm, identity notch width.
gap          = 8.0;    // mm, spacing between coupons on the plate.

$fa = 2;
$fs = 0.5;
eps = 0.01;

// ---------------------------------------------------------------- bore
module bore_ring(bd) {
    br = bd / 2;
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
        n = search([bd], bore_tests)[0] + 1;
        for (k = [0 : n - 1])
            rotate([0, 0, 90 + k * 13])
                translate([orr - 1.2, 0, ring_h - notch_d])
                    cube([3, notch_w, notch_d + eps], center = false);
    }
}

module bore_row() {
    step = bore_tests[len(bore_tests) - 1] + 2 * collar_wall + gap;
    for (i = [0 : len(bore_tests) - 1])
        translate([i * step, 0, 0]) bore_ring(bore_tests[i]);
}

// -------------------------------------------------------------- thread
// Short lengths of the real thread, so the fit you measure is the fit
// you get. Geometry is duplicated from screwless_mount.scad rather than
// imported, because that file's thread is wrapped inside the collar.
// Kept in sync with screwless_mount.scad's thread_profile BY HAND, and
// the thing to keep in sync is the reason it looks like this: a twisted
// linear_extrude turns ANGLE into height, so a tooth drawn as a linear
// offset in y comes out ~0.03 mm thick and slices away to a plain
// cylinder. Both copies had that bug until 2026-09-12. Draw the tooth as
// an angular SECTOR or this coupon measures nothing at all.
function thr_ang2(axial_mm) = axial_mm * 360 / thr_pitch;

module thread_profile2(minor, depth, grow = 0) {
    ar = thr_ang2(thr_pitch * thr_duty  + grow);
    ac = thr_ang2(thr_pitch * thr_crest + grow);
    n  = 16;
    union() {
        circle(r = minor);
        polygon(concat(
            [ for (i = [0 : n]) let (a = -ac + 2 * ac * i / n)
                [ (minor + depth) * cos(a), (minor + depth) * sin(a) ] ],
            [ for (i = [0 : n]) let (a = ar - 2 * ar * i / n)
                [ (minor - eps) * cos(a), (minor - eps) * sin(a) ] ]
        ));
    }
}

module thread2(len, minor, depth, grow = 0) {
    turns = len / thr_pitch;
    linear_extrude(height = len, twist = -360 * turns,
                   slices = max(24, ceil(turns * 24)), convexity = 12)
        thread_profile2(minor, depth, grow, $fs = 0.9, $fa = 4);
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
            translate([0, 0, -eps])
                thread2(tl + 2, minor + thr_test, thr_depth, thr_axial / 2);
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
