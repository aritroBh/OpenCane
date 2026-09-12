// =====================================================================
// OpenCane - ROLLING BALL TIP
// =====================================================================
// A printed rolling ball for the end of the shaft, so the user can feel
// the difference between a crack and a joint by rolling over it instead
// of catching in it. Zero bought hardware: no bearing, no screws. The
// commercial part this imitates (Ambutech's 2 in rolling ball) has a
// steel bearing inside; we do not, so the swivel is a printed thrust
// face and everything below follows from that one constraint.
//
// ---------------------------------------------------------------- FIT
// WHAT THIS IS FITTED TO, stated plainly because it matters:
// shaft_d defaults to 27.65 mm, which is a BROOM HANDLE. It is the
// prototype shaft, measured 2026-09-12 by the bore-ring coupons in
// hardware/mount_screwless/. It is NOT a white cane.
//
// Real long canes are much thinner, and the sources disagree with our
// prototype by a factor of two:
//   Ambutech Premium Aluminum mobility cane   13.0 mm  (0.5 in)
//   Ambutech SlimLine Graphite / Aluminum ID   9.5 mm  (3/8 in)
//   NFB Type 10 carbon fibre, tapered      15.9 -> 9.5 mm
//   NFB Type 2 fibreglass, tapered         12.7 -> 9.5 mm
//     (Rodgers & Wall Emerson, Materials Testing in Long Cane Design,
//      JVIB 99(11) 2005)
//   WHO APS24 procurement draft            "about 12mm", "13mm or smaller"
// So a real cane is 9.5-13 mm AT THE TIP END, and tapered fibre canes
// converge on 9.5. Retargeting is a 2x change, not a tweak: set shaft_d
// and RE-CHECK every derived wall, because at 9.5 mm the stem is thinner
// than the ball's lip and the failure mode moves.
//
// Broom handles do not taper, which is the one way this prototype is
// EASIER than a cane: the tip-end diameter equals the collar diameter,
// so one measurement serves both. A cane would need both measured.
//
// ------------------------------------------------------------- SAFETY
// NOT FOR STREET USE. This is a bench and demo part.
// A cane tip that comes off mid-stride is a fall, and we have no pull-off
// number to quote: there is no product standard for white canes (WHO
// APS24 points only at the general ISO 21856:2022; the FDA's 21 CFR
// 890.3075 "Cane" covers weight-bearing support canes, not long canes),
// and no manufacturer publishes a retention force. So there is no bar to
// clear and no benchmark to compare against. Any number we claim has to
// be one we measured ourselves, against a commercial tip tested the same
// way, and we have not done that.
// Both published open-source cane tips ship the same warning and tell
// users to practise indoors in a known environment first
// (github.com/MHatfull/cane_tip, MIT; printables.com/model/699705, CC0).
// Match that at minimum before this touches a pavement.
//
// Weight is a documented drawback, not a neutral trade: a COMS case
// study has a student fatiguing 20 minutes into a lesson on a 69 g
// roller ball and preferring a 39 g roller marshmallow
// (aphconnectcenter.org, "O&M: What's in a Tip?"), and Ambutech voids
// warranty on its heaviest rolling tips for thin shafts because "the
// weight of the tip could damage the cane shaft". Print this in the
// lightest infill that survives, and weigh it.
// =====================================================================

/* [What to print] */
// swivel_test FIRST - see PRINT ORDER at the bottom of this file.
part = "swivel_test"; // [swivel_test, lower, upper, stem, assembly]

/* [Shaft] */
shaft_d     = 27.65;  // mm, MEASURED. Broom handle, not a cane. See FIT.
shaft_clear = 0.35;   // mm, added to shaft DIAMETER for the slip fit.
socket_len  = 30.0;   // mm, how far the stem swallows the shaft.

/* [Ball] */
// 50.8 mm = 2 in, which is the size Ambutech's Rolling Ball Tip and
// Stationary Ball Tip both use, and the size the APH O&M textbook calls
// "the size of a billiards ball". Note this EXCEEDS the WHO APS24 draft,
// which asks for a tip "2-3cm thick" - commercial practice breaks that
// figure too, so we are following the market, not the draft. Set
// ball_d = 30 for a WHO-compliant, much lighter variant.
ball_d      = 50.8;   // mm, outside diameter of the rolling ball.
// Where the ball is split for printing, as a fraction of its DIAMETER
// measured up from the bottom pole. This is the single most important
// number in the file and it is NOT cosmetic: printed cut-face-down, the
// steepest overhang on the lower piece sits at the bed and equals
// atan(z / sqrt(R^2 - z^2)) with z = mouth_frac * ball_d - ball_d / 2.
// At 0.78 that is 34.1 deg, comfortably inside the 45 deg a 0.4 nozzle
// bridges. Lower it and the overhang worsens fast: 0.70 gives 45.6 deg,
// already past the limit. The assert below enforces it - do not just
// edit the number and hope.
mouth_frac  = 0.78;
ball_wall   = 2.40;   // mm, shell thickness of the rolling ball. 6 lines.

/* [Swivel] */
// The load path and the retention path are SEPARATED on purpose, and
// this is the whole trick of the part:
//   - the ball's weight and the user's lean ride on a SMALL radius
//     thrust boss (thrust_r). Friction torque goes as radius, so small
//     means it spins freely.
//   - the ball is HELD ON by a lip at a LARGE radius, where there is
//     room for material and the hoop stress is low.
// Doing both jobs at one radius is what makes printed swivels either
// stiff or fall apart.
thrust_r    = 5.00;   // mm, radius of the thrust boss that carries load.
thrust_gap  = 0.30;   // mm, axial running clearance at the thrust face.
lip_grab    = 1.60;   // mm, how far the retaining lip reaches inward.
lip_clear   = 0.40;   // mm, radial running clearance at the lip.
lip_slots   = 6;      // relief slots so the lip can flex over the bead.
slot_w      = 2.20;   // mm, width of each relief slot.

/* [Stem] */
stem_wall   = 3.20;   // mm, wall around the shaft socket.
bead_drop   = 1.00;   // mm, how far the retaining bead sits below the lip.

/* [Test coupon] */
// A SMALL swivel, printed first, to answer the one question that decides
// whether any of this works: does a printed thrust face and a printed
// snap lip actually spin after it comes off the bed, or does it fuse?
// Answer that on a 6 g part, not a 60 g one.
test_ball   = 25.0;   // mm, ball diameter for the swivel test coupon.
// The test coupon needs its OWN stem radius, and forgetting that was a
// real bug on 2026-09-12: stem_r comes from the 27.65 mm broom handle
// and is 17.2, so the stem measures 37.6 mm across its bead while a
// 25 mm test ball has a mouth only 21.0 mm across. The stem could not
// enter the ball it was meant to test, and the plate rendered as 2
// solids instead of 3 because the stem had merged into the cap. The
// test exists to ask "does a printed swivel spin", which needs no shaft
// bore at all - so it gets a small solid stem instead.
test_stem_r = 6.00;   // mm, stem radius on the swivel test coupon only.
test_sock   = 20.0;   // mm, stem length on the test coupon - a handle to twist.
lay_gap     = 12.0;   // mm, spacing between pieces on the test plate.

$fa = 2;
$fs = 0.6;
eps = 0.01;

// --------------------------------------------------------------- derived
shaft_r = (shaft_d + shaft_clear) / 2;
stem_r  = shaft_r + stem_wall;

// Height of the split plane relative to the ball's CENTRE (positive =
// above centre), the mouth's radius there, and the steepest overhang the
// lower piece presents when printed cut-face-down. All three are
// functions of ball diameter because the test coupon uses a smaller one.
function mouth_z(bd)  = mouth_frac * bd - bd / 2;
function mouth_r(bd)  = sqrt(pow(bd / 2, 2) - pow(mouth_z(bd), 2));
function mouth_oh(bd) = atan(mouth_z(bd) / mouth_r(bd));

assert(mouth_oh(ball_d) < 45,
       "ball split plane makes an overhang past 45 deg - raise mouth_frac");
assert(mouth_r(ball_d) > thrust_r + lip_grab + 2,
       "ball mouth is too narrow for the lip and thrust boss - raise mouth_frac");
assert(stem_r < mouth_r(ball_d) - lip_grab,
       "stem is fatter than the ball's mouth - it cannot enter the ball");
// The same check for the TEST coupon. It is a separate assert because it
// is a separate ball AND a separate stem; asserting only the real pair
// is what let the broken coupon through.
assert(test_stem_r < mouth_r(test_ball) - lip_grab,
       "test stem is fatter than the test ball's mouth - lower test_stem_r");
assert(thrust_r + 2.0 < test_ball / 2 - ball_wall,
       "thrust seat is wider than the test ball's cavity - lower thrust_r");
assert(ball_wall >= 1.6,
       "ball shell thinner than 4 lines at 0.4 nozzle - it will crush");

echo(str("ball_tip: shaft ", shaft_d, " (BROOM, not a cane)  ball ", ball_d,
         "  split overhang ", mouth_oh(ball_d), " deg  mouth r ",
         mouth_r(ball_d), "  stem r ", stem_r));

// ------------------------------------------------------------------ ball
// The rotating half. Hollow, because a solid 50.8 mm ball is both heavy
// (and weight is a documented drawback, see SAFETY) and a waste of an
// hour. Ground contact is the bottom pole.
module ball_lower(bd = ball_d) {
    mz = mouth_z(bd);
    union() {
        difference() {
            // outer shell, bottom pole up to the split plane
            intersection() {
                sphere(d = bd);
                translate([0, 0, -bd]) cylinder(h = bd + mz, r = bd);
            }
            // hollow it
            sphere(d = bd - 2 * ball_wall);
            // open the mouth, leaving lip_grab of overhanging lip
            translate([0, 0, mz - eps])
                cylinder(h = bd, r = mouth_r(bd) - lip_grab);
            // relief slots so the lip can spring over the stem's bead
            for (i = [0 : lip_slots - 1])
                rotate([0, 0, i * 360 / lip_slots])
                    translate([0, -slot_w / 2, mz - lip_grab - 2])
                        cube([bd, slot_w, lip_grab + 4]);
        }
        // The thrust seat: a small pad the stem's boss rides on, sitting
        // at the BOTTOM of the cavity. Small radius = low friction
        // torque, which is the whole reason it is not just the cavity
        // floor. Tapered so it prints off the inner shell without a
        // ledge.
        translate([0, 0, -(bd / 2 - ball_wall)])
            cylinder(h = ball_wall, r1 = thrust_r + 2.0, r2 = thrust_r + 1.2);
    }
}

// The cap. Closes the ball so the cavity does not fill with grit, and
// gives the stem a bearing surface on the way out.
module ball_upper(bd = ball_d, sr = -1) {
    mz = mouth_z(bd);
    r  = (sr < 0) ? stem_r : sr;
    difference() {
        intersection() {
            sphere(d = bd);
            translate([0, 0, mz]) cylinder(h = bd, r = bd);
        }
        translate([0, 0, mz - eps]) cylinder(h = bd, r = r + lip_clear);
    }
}

// ------------------------------------------------------------------ stem
// Slips onto the shaft and carries the ball. The bead is what the ball's
// lip snaps over (retention, large radius); the boss below it is what
// the ball actually rides on (load, small radius).
// The stem: slips onto the shaft and carries the ball.
//
// Every feature is positioned FROM THE BALL, not from a fixed length.
// stem_len used to be a flat 18 mm, which fits inside a 50.8 mm ball and
// punches straight through the bottom of a 25 mm one - the test coupon
// was modelling a neck 8 mm below the ball's own cavity floor. Anything
// that reaches into the ball has to scale with the ball.
//
// Two radii, two jobs (see [Swivel] above):
//   thrust boss, radius thrust_r  - small, carries the load, spins easy
//   bead, radius r + lip_grab     - large, holds the ball on
//
//   sr    stem radius; -1 = the real shaft stem
//   bore  cut the shaft socket (false on the test coupon: no shaft)
//   sock  socket length; -1 = socket_len
module stem(bd = ball_d, sr = -1, bore = true, sock = -1) {
    r    = (sr < 0) ? stem_r : sr;
    sl   = (sock < 0) ? socket_len : sock;
    // cavity floor of the ball, and the face the boss rides on
    floor_z = -(bd / 2 - ball_wall);
    boss_z  = floor_z + thrust_gap;
    // the bead sits below the ball's lip so the lip can snap over it
    bead_z  = mouth_z(bd) - lip_grab - bead_drop;
    assert(bead_z > boss_z + lip_grab,
           "retaining bead is below the thrust face - ball is too small for this stem");
    difference() {
        union() {
            cylinder(h = sl, r = r);                          // shaft socket
            translate([0, 0, bead_z])
                cylinder(h = -bead_z + eps, r = r);           // neck up to z=0
            translate([0, 0, bead_z])                         // retaining bead
                cylinder(h = lip_grab * 2, r = r + lip_grab, center = true);
            translate([0, 0, boss_z])                         // thrust boss
                cylinder(h = bead_z - boss_z + eps, r = thrust_r);
        }
        if (bore) translate([0, 0, 2]) cylinder(h = sl, r = shaft_r);
    }
}

// Lowest point of the stem, so a caller can sit it on the bed without
// guessing. Hand-computed offsets are what floated the ball 12.5 mm above
// the plate and buried the stem 9.8 mm under it on 2026-09-12.
function stem_bottom(bd) = -(bd / 2 - ball_wall) + thrust_gap;

// ------------------------------------------------------------- swivel test
// The whole mechanism at test_ball, laid out for one small print. Print
// it, snap it together, and see whether it spins. If it does not, nothing
// at 50 mm will either, and we have lost 20 minutes instead of 2 hours.
// Spacing is driven by the widest piece on the plate, not by test_ball -
// the stem's bead is wider than the ball when the stem is fat, and a
// hand-picked gap is what let two pieces merge.
// Laid out PRINT-READY: every piece already sits on z = 0 in the
// orientation it must be printed in, so the plate can go straight into
// the slicer without anyone rotating anything by hand.
//
// The rotation on ball_lower is the one that matters. As modelled its
// cut face is at the TOP and the ground pole at the bottom, so dropped
// on a bed as-is it would try to print balancing on a single point and
// then carry a 90 deg overhang all the way out to the equator. Flipped,
// the flat cut face is the first layer and the steepest overhang is
// mouth_oh() = 34 deg at the bed, falling to zero at the equator. Same
// solid, same file, and the difference between a clean print and a
// bird's nest.
module swivel_test() {
    w  = max(test_ball, 2 * (test_stem_r + lip_grab), 2 * mouth_r(test_ball));
    mz = mouth_z(test_ball);
    // ball: flipped so the flat cut face is the first layer
    translate([0, 0, mz]) rotate([180, 0, 0]) ball_lower(test_ball);
    // cap: already flat-faced, just drop it to the bed
    translate([w + lay_gap, 0, -mz]) ball_upper(test_ball, test_stem_r);
    // stem: standing on its bead, boss upward-buried. Socket shortened to
    // test_sock - the coupon has no shaft to fit, so a full socket_len
    // would be 30 mm of plastic answering no question and a taller
    // skinny column to knock over.
    translate([2 * (w + lay_gap), 0, -stem_bottom(test_ball)])
        stem(test_ball, test_stem_r, false, test_sock);
}

// ------------------------------------------------------------------ lay
if      (part == "swivel_test") swivel_test();
else if (part == "lower")       ball_lower();
else if (part == "upper")       ball_upper();
else if (part == "stem")        stem();
else if (part == "assembly") {
    ball_lower();
    ball_upper();
    stem();
    %translate([0, 0, socket_len]) cylinder(h = 300, r = shaft_d / 2);
}

// =====================================================================
// PRINT ORDER - smallest and cheapest first, each one answering a
// question the next one depends on. Do not skip ahead.
//
//   1. part="swivel_test"   ~25 mm pieces. Does a printed swivel spin at
//                           all? Decides thrust_gap and lip_clear.
//   2. part="stem"          Does it slip onto the broom handle and stay?
//                           Decides shaft_clear. Cheap, no ball.
//   3. part="lower"         The real ball's bottom. Biggest single piece
//                           and the one with the overhang - inspect the
//                           bed edge for droop before printing anything
//                           bigger.
//   4. part="upper"         Only after 3 prints clean.
// =====================================================================
