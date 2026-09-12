// =====================================================================
// OpenCane screwless mount - FIT COUPONS
// =====================================================================
// Print this FIRST. It decides three numbers that every other part
// depends on. Printing the real parts before these is how you burn three
// hours and a spool finding out the bore is 0.2 mm tight.
//
// TIME, sliced 2026-09-12, 0.4 nozzle / 0.2 layer / 4 walls / 25% gyroid:
//   what="bore"   52 m 53 s   the five rings alone
//   what="all"     3 h 01 m   the whole plate
// The header said "~25 minutes" until 2026-09-12. It is not 25 minutes
// and never was; someone planning an evening around that number lost two
// and a half hours. If you only need pole_d, print what="bore".
//
// Print settings: the same profile you will use for the real parts.
// 0.4 nozzle, 0.2 layer, 4 walls, 25% gyroid, PETG. If you change the
// nozzle or the layer height afterwards, the numbers move - reprint.
//
// WHAT TO DO WITH IT
//
// 1. BORE RINGS (row 1, NOTCHED 1..5 = absolute BORE DIAMETER, mm)
//      1 notch  27.75     4 notches 28.65
//      2 notches 28.05    5 notches 28.95
//      3 notches 28.35
//    This table is the ONE thing in this header a fitter reads with parts
//    in hand, and it was wrong until 2026-09-12: it still listed the
//    superseded 27.85/28.25/28.45/28.95/29.15 set while bore_tests below
//    had already moved to the values above. Every ring would have been
//    recorded as 0.10-0.20 mm larger than it is. If you edit bore_tests,
//    edit this table in the same keystroke.
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
//    RESULT, 2026-09-12 - this test has been RUN and it is settled:
//      1 notch  27.75  barely went on   <- the bound
//      2 notches 28.05  decent
//      3 notches 28.35  decent, yellow and white agreed
//    pole_d = 27.75 - 0.10 = 27.65, matching the dial caliper exactly.
//    hardware/mount/'s 28.75 was wrong by 1.10 mm and is retired.
//    You do not need to reprint these rings unless the cane changes.
//
// 2. THREAD ROW (row 2): ONE stub + FOUR fluted nuts.
//      stub  = threads on the OUTSIDE, sits on a thin flange
//      nut   = 10 scallops round the rim, thread hidden INSIDE
//
//    NOTCHES ON THE NUT'S TOP RIM -> [thr_clear, thr_axial], mm:
//      1 notch   0.45  0.25     radial step only
//      2 notches 0.35  0.45     AXIAL step only
//      3 notches 0.45  0.45     both, modest
//      4 notches 0.55  0.65     both, generous
//    TWO numbers per nut, not one. This table was written for an earlier
//    THREE-nut set stepping thr_clear 0.35/0.45/0.55 and was not updated
//    when the set became four pairs on 2026-09-12 - it would have named
//    the wrong clearance for every nut on the plate. Read it from
//    thr_tests below, and if you edit thr_tests, edit this in the same
//    keystroke. It is the same defect this file's bore table carried,
//    and the reason that one now has a warning attached to it.
//
//    Screw each nut down the stub by hand, no tool. Take the SMALLEST
//    nut that turns freely for the WHOLE length with no play you can
//    feel by rocking it at the top. Put both its numbers in
//    `thr_clear` / `thr_axial`.
//
//    WHY TWO AXES. The 2026-09-12 bench run had one nut, [0.35, 0.25],
//    and it went down two turns of four and then jammed. That rules out
//    both single-axis causes: not radial clearance, because the first
//    two turns were free; not elephant's foot on the stub, because that
//    binds at the LAST turn against the flange. Binding that worsens as
//    more teeth engage is cumulative per-tooth error, and the clearance
//    that absorbs it is axial - thr_axial was 0.25 mm, 1.25 layers at
//    0.2 mm. Two teeth can wiggle into alignment; four cannot.
//    So nut 1 tests the radial theory, nut 2 the axial one, and which
//    of them frees the thread is the answer.
//    If ONLY nut 4 works, stop and investigate - a loose thread is
//    hiding a fault, not fixing one.
//
//    WHERE it binds, note it either way:
//      tight from the first turn       -> radial. Nut 1 or 3.
//      free, then jams part-way down   -> axial. Nut 2 or 3.
//      free, then jams AT THE FLANGE   -> elephant's foot on the stub's
//        first layers, not clearance at all. Chamfer the stub; do not
//        open the thread to paper over it.
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

/* [What to print] */
what = "all"; // [all, next, bore, thread, dovetail]

/* [Copied from screwless_mount.scad - keep in sync] */
pole_d       = 27.65;   // MEASURED by these very rings, 2026-09-12.
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
// 0.50 mm gap. This set halves that gap and moves the floor down 0.10.
//
// It does NOT bracket 27.65 from below - 27.75 is still above it. The
// comment here claimed it did until 2026-09-12. If ring 1 goes on
// LOOSELY the cane is below this set's floor and the test has failed to
// bound it; cut a set from 27.15 in 0.20 steps and rerun. Only a ring
// that REFUSES to go on gives a real lower bound.
bore_tests   = [27.75, 28.05, 28.35, 28.65, 28.95];  // absolute BORE diameters
dt_tests     = [0.15, 0.25, 0.35];         // dt_clear values to try
// Thread fit tests: [thr_clear, thr_axial] per nut, NOTCHED 1..4.
// One male stub serves all four - only the female cut varies.
//
// TWO axes, not one, and the reason is a measurement from the bench on
// 2026-09-12: a single nut at [0.35, 0.25] went down two turns of four
// and then jammed. That symptom rules out both single-axis causes. It
// was not radial clearance - the first two turns were free. It was not
// elephant's foot on the stub - that binds at the LAST turn, against the
// flange, not in the middle. Binding that worsens as more teeth engage
// is cumulative per-tooth error, and the clearance that absorbs it is
// AXIAL: thr_axial was 0.25 mm, which is 1.25 layers at 0.2 mm. Two
// teeth can wiggle into alignment, four cannot.
//
// So this set steps the two axes SEPARATELY before stepping both, which
// is what makes the result diagnostic instead of merely better:
//   1  radial only   - if this frees it, blame thr_clear after all
//   2  axial only    - if this frees it, the diagnosis above is right
//   3  both, modest  - the expected winner
//   4  both, generous- if ONLY this frees it, something else is wrong
//                      and a looser thread is hiding it, not fixing it
// Take the SMALLEST nut that runs the full length freely. A thread that
// needs nut 4 should be investigated, not shipped.
thr_tests    = [[0.45, 0.25], [0.35, 0.45], [0.45, 0.45], [0.55, 0.65]];
thr_len      = 12.0;   // mm, threaded length of the stub and each nut.
// Bore clearance the THREAD PAIR is built around, so its core diameter
// matches the real collar's. Was inlined as a bare 0.40 in thread_pair()
// until 2026-09-12, against the house rule that every dimension lives in
// this block. Keep it equal to bore_clear in screwless_mount.scad. It is
// NOT an output of the bore-ring test - see note 1 above.
bore_clear   = 0.40;   // mm, on diameter.
// Root arc inset below the thread minor radius. circle(r) in OpenSCAD is
// an INSCRIBED polygon: its true radius dips about 0.0104 mm below r
// between facets at $fa=4. A root arc at minor-eps (0.01) therefore lands
// within 0.0004 mm of that dip, tangent rather than buried, and the
// extrude sheds zero-volume helical sheets that slicers choke on while
// OpenSCAD still reports NoError. 0.05 clears the dip with margin.
thr_sink     = 0.05;   // mm.
thr_arc2     = 16;     // segments per arc and per flank in the tooth.
notch_d      = 1.20;   // mm, identity notch depth.
notch_w      = 2.00;   // mm, identity notch width.
gap          = 8.0;    // mm, spacing between coupons on the plate.
per_row      = 3;      // coupons per row before wrapping to the next row.

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

// The flank is interpolated in POLAR space. A straight Cartesian chord
// from the crest corner to the root corner - which is what the two-arc
// polygon here used to be - passes INSIDE circle(minor) whenever the root
// half-angle is large. At these defaults (ar = 90, ac = 36) its closest
// approach is r = 15.65 against a minor of 17.03, so union() with
// circle(minor) swallowed the outer half of every tooth: the coupon
// printed a 0.738 mm root where thr_duty asks for 1.500, and measuring
// its fit told you about a thread the collar does not have. Measured by
// radial pin, 2026-09-12; 1.396 mm after this rewrite. Walking angle and
// radius together is what makes a trapezoid once the twist turns angle
// into height. This is a hand copy of thread_profile() in
// screwless_mount.scad - if you change one, change both.
module thread_profile2(minor, depth, grow = 0) {
    ar = thr_ang2(thr_pitch * thr_duty  + grow);   // root half-angle, deg
    ac = thr_ang2(thr_pitch * thr_crest + grow);   // crest half-angle, deg
    rc = minor + depth;                            // crest radius
    rr = minor - thr_sink;                         // root radius
    n  = thr_arc2;
    union() {
        circle(r = minor);
        polygon(concat(
            // crest arc, -ac -> +ac
            [ for (i = [0 : n]) let (a = -ac + 2 * ac * i / n)
                [ rc * cos(a), rc * sin(a) ] ],
            // trailing flank, +ac -> +ar, radius rc -> rr
            [ for (i = [1 : n]) let (u = i / n,
                                     a = ac + (ar - ac) * u,
                                     r = rc + (rr - rc) * u)
                [ r * cos(a), r * sin(a) ] ],
            // root arc, +ar -> -ar
            [ for (i = [0 : n]) let (a = ar - 2 * ar * i / n)
                [ rr * cos(a), rr * sin(a) ] ],
            // leading flank, -ar -> -ac, radius rr -> rc
            [ for (i = [1 : n - 1]) let (u = i / n,
                                         a = -ar + (ar - ac) * u,
                                         r = rr + (rc - rr) * u)
                [ r * cos(a), r * sin(a) ] ]
        ));
    }
}

module thread2(len, minor, depth, grow = 0) {
    turns = len / thr_pitch;
    linear_extrude(height = len, twist = -360 * turns,
                   slices = max(24, ceil(turns * 24)), convexity = 12)
        thread_profile2(minor, depth, grow, $fs = 0.9, $fa = 4);
}

module thread_stub() {
    br    = (pole_d + bore_clear) / 2;
    core  = br + collar_wall;
    minor = core - thr_depth;
    difference() {
        union() {
            cylinder(h = 3, r = core + 1);
            translate([0, 0, 3]) thread2(thr_len, minor, thr_depth);
        }
        translate([0, 0, -eps]) cylinder(h = thr_len + 4, r = br);
    }
}

// One female nut. tc = [thr_clear, thr_axial]; notched by its index in
// thr_tests. The axial clearance enters as grow on the cutting thread:
// thr_ang2() turns an axial millimetre into an angle, so growing the cut
// by axial/2 on each side opens the groove by `axial` in total along the
// helix - which is the direction the jam happened in.
module thread_nut(tc) {
    br    = (pole_d + bore_clear) / 2;
    core  = br + collar_wall;
    minor = core - thr_depth;
    orr   = core + 4;
    idx   = [for (i = [0 : len(thr_tests) - 1]) if (thr_tests[i] == tc) i][0] + 1;
    difference() {
        cylinder(h = thr_len, r = orr);
        translate([0, 0, -eps])
            thread2(thr_len + 2, minor + tc[0], thr_depth, tc[1] / 2);
        // flutes: finger grips, 10 of them at 36 deg spacing
        for (i = [0 : 9])
            rotate([0, 0, i * 36])
                translate([orr, 0, -eps])
                    cylinder(h = thr_len + 2, r = 2.5, $fn = 20);
        // Identity notches in the top rim, one per FLUTE MIDPOINT.
        //
        // The 13 deg step the bore rings use is WRONG here and was in
        // this file for about ten minutes on 2026-09-12. Flutes land on
        // multiples of 36, so notches at 90, 103, 116, 129 put the third
        // and fourth INSIDE the flute at 108. Measured: the notch-region
        // volume fell 0.002, 0.007, 0.008 cm3 across the four nuts where
        // a constant ~0.007 was due. A notch sunk in a scallop is also
        // impossible to count by thumb, which is the whole point of
        // notching instead of printing digits. 36 deg puts every notch
        // exactly between two flutes, on the widest land available.
        // (The bore rings are unaffected: their 8 grip grooves are on
        // the INNER bore, at a different radius from the rim notches.)
        for (k = [0 : idx - 1])
            rotate([0, 0, 90 + k * 36])
                translate([orr - 3.2, 0, thr_len - notch_d])
                    cube([3, notch_w, notch_d + eps], center = false);
    }
}

// Laid out in rows of `per_row`, not one long line. A single line of the
// stub plus four nuts is 251.11 mm wide, which leaves 4.4 mm a side on a
// 260 mm bed - less than a brim - and it grew past the bed the moment the
// fourth nut was added on 2026-09-12. Wrapping keeps the plate square as
// more clearances get added.
module thread_row() {
    br   = (pole_d + bore_clear) / 2;
    core = br + collar_wall;
    step = 2 * (core + 4) + gap;
    for (i = [0 : len(thr_tests)])
        translate([(i % per_row) * step, floor(i / per_row) * step, 0])
            if (i == 0) thread_stub();
            else        thread_nut(thr_tests[i - 1]);
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
// Row origins. These are NOT round numbers chosen by eye: each is the
// previous row's real extent plus `gap`. The thread row wraps to two
// rows of three now, 96.90 mm tall instead of 44.45, and the old hand
// -picked y=70/130 made it overlap the bore rings - the plate rendered
// as 14 solids instead of 16 because two pairs of coupons had merged
// into each other. Measured and fixed 2026-09-12. If you add a coupon,
// re-render and CHECK THE COMPONENT COUNT; a merge is silent otherwise.
row_bore = 0;                       // bore rings span y +-18.67
row_thr  = 60;                      // two rows, y -22.23 .. +74.68 of here
row_dt   = 170;                     // dovetail pairs span y 0 .. 49
// "next" is the plate to print when the bore rings are already DONE and
// pole_d is settled - which it is, as of 2026-09-12. It is the thread row
// and the dovetail row together in one job, because those are the two
// numbers still unknown and there is no reason to run the printer twice.
// Skipping the bore row saves 21.33 cm3 and its 52 m 53 s.
if (what == "next") {
    translate([0, 0,      0]) thread_row();
    translate([0, row_dt - row_thr, 0]) dt_row();
} else if (what == "all") {
    translate([0, row_bore, 0]) bore_row();
    translate([0, row_thr,  0]) thread_row();
    translate([0, row_dt,   0]) dt_row();
} else if (what == "bore")       bore_row();
else if (what == "thread")     thread_row();
else if (what == "dovetail")   dt_row();

echo(str("coupons: bore ", bore_tests, "  dt ", dt_tests, "  thr_clear ", thr_tests));
