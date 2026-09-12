// =====================================================================
// OpenCane / CaneKit - SCREWLESS phone-to-cane mount
// =====================================================================
// Zero bought hardware. No screws, no nuts, no heat-set inserts, no
// magnets, no wires, no glue. Four printed parts in PETG, assembled by
// hand in under a minute. The iPhone is the entire electronics package;
// this is dumb plastic whose only job is to aim it and stay put.
//
// CLAMP MECHANISM - collet.
//   The collar's nose is a slotted cone. The ring screws down over that
//   cone and squeezes the slots shut onto the cane, exactly like a drill
//   chuck. Both thread helices run along the print Z axis, which is the
//   only orientation a printed thread is reliable in. Clamping force
//   comes from a wedge, not from a snap fit, so vibration cannot walk it
//   loose the way it walks a snap-fit collar loose.
//
// MODULARITY - three interfaces, one joint type.
//   collar  = the cane interface     -> different cane, reprint this
//   arm     = the angle interface    -> different pose,  reprint this
//   cradle  = the phone interface    -> different phone, reprint this
//   All three meet at the same sliding dovetail running along the cane
//   axis, so the phone's weight loads every joint in shear across its
//   widest face and never tries to peel one open. A printed cantilever
//   pawl clicks into each socket; press it to release.
//
// PHONE DIMENSIONS are lifted from hardware/mount/cane_mount.scad, which
// took them from Apple's dimensional drawings. Do not re-derive them.
//
// Set `part`, export one STL. Every part is already in its print
// orientation - do not rotate it in the slicer.
//
// SUPPORT: none, except the cradle. The cradle stands on its dovetail
// block, so the back plate sits 7 mm off the bed and needs support under
// it ("on build plate only" is enough). Every other part is drawn so that
// no downward face goes past 45 degrees. Do not believe a blanket
// "supports off" instruction on this folder - it was wrong once already.
// =====================================================================

/* [Part to export] */
part = "assembly"; // [assembly, collar, ring, arm, cradle, socket, lock]

// How the cradle attaches to the arm.
//   "dovetail" - fixed angle, set when you print the arm. Stiffest.
//   "ball"     - clamped ball joint: aim it by hand, then lock it.
//
// READ THIS BEFORE CHOOSING "ball". Both the hardware brief and
// hardware/mount/DESIGN.md rejected a ball joint on purpose: "Ball joints
// slip under sweep vibration and break the Point-to-Identify calibration."
// That objection is about a FREE ball (friction only). This one is a
// clamped ball - the same collet trick as the cane collar, a slotted
// socket squeezed by a threaded ring - so holding force comes from a wedge
// you tighten, not from how snugly it printed. That answers the objection
// but does not erase it: a clamp that is not tightened enough still slips,
// and now it slips in two axes instead of none. The fixed-angle dovetail
// arm remains the safe demo part. Test T7 (shake) on whichever you fit,
// and check the Mount card still reads 3-8 degrees down afterwards.
joint = "dovetail"; // [dovetail, ball]

world_view = true;  // ghost cane + phone in the assembly preview

/* [Cane] */
// 27.65 mm, dial caliper, Sagar, Sep 11 2026. THIS IS THE NUMBER IN USE.
//
// It disagrees with everything before it and the disagreement is not a
// rounding error: hardware/mount/cane_mount.scad and the hardware brief
// both say 28.75 mm, and Sagar separately quoted 1.128 in (28.65 mm).
// 27.65 is ~1.1 mm smaller than either, which is three times the bore
// clearance - far too big to absorb. A collar bored for 28.75 would just
// spin on a 27.65 shaft.
//
// MEASURED, 2026-09-12, by the bore coupons against the real cane. This
// is no longer a disputed number. Two sets of rings (yellow and white)
// were slid onto the cane at the collar spot:
//   1 notch  27.75  barely went on          <- the bound
//   2 notches 28.05  went on decently
//   3 notches 28.35  went on decently (both colours agreed)
//   4,5             not needed, larger still
// pole_d = (smallest ring that goes on at all) - 0.10 = 27.65, which is
// exactly what the dial caliper read on Sep 11 by a completely different
// method. Two independent measurements to 0.01 mm.
//
// The rival 28.75 figure is WRONG and is now retired. It survived in
// hardware/mount/ for two days; a collar bored for it has 1.10 mm of
// clearance on a 27.65 shaft and simply spins.
//
// Caveat, so nobody over-reads this: no ring REFUSED to go on, so the
// cane is bounded from above (<= 27.75) but not hard-bounded from below.
// "Barely" is a strong signal - a much smaller cane would have let ring 1
// slide - but if the collet ever comes up short, reprint the coupons from
// 27.15 in 0.20 steps before blaming the collet.
//
// One reading to ignore: an inside-jaw caliper measurement of a printed
// ring bore came out 27.28. That is a chord/inside-jaw artifact, and it
// is physically impossible besides - a rigid 4.2 mm PETG wall cannot
// stretch 0.37 mm to pass a 27.65 shaft. Measure printed bores by which
// gauge ring fits, never with inside jaws.
pole_d       = 27.65;  // mm, cane shaft diameter at the collar. MEASURED.
bore_clear   = 0.40;   // mm, ADDED TO DIAMETER. Set this from the coupons.
collar_wall  = 4.20;   // mm, radial wall around the bore.
// These are GROOVES, not ribs, whatever the name says. The cylinders are
// subtracted, so each one scallops a ~0.3 mm dish out of the bore wall and
// what is left between them are eight lands. That is the right behaviour -
// eight narrow lands carry the collet's grip at higher contact pressure
// than a full-circle bore does, and the grooves give the squeezed plastic
// somewhere to go - but the name misled a reader once, so: grooves.
grip_ribs    = 8;      // axial GROOVES in the bore; the lands between them grip.
rib_h        = 0.50;   // mm, groove centre inset from the bore wall.
rib_w        = 1.60;   // mm, groove cutter diameter.

/* [Collet and ring] */
// The base is not just a stub below the thread: it is the land the
// dovetail socket is cut into, so it has to be LONGER than the dovetail
// slide plus a stop shoulder. There is an assert on this below. If you
// shorten it, the socket cuts clean through the top of the pad and the
// arm has nothing to land against.
base_len     = 36.0;   // mm, unslotted base below the thread = dovetail land.
thread_len   = 15.0;   // mm, threaded band.
cone_len     = 20.0;   // mm, slotted cone above the thread.
cone_taper   = 2.60;   // mm, radius lost from the bottom of the cone to the top.
n_slots      = 4;      // collet fingers.
slot_w       = 2.60;   // mm, slot width.
slot_over    = 5.0;    // mm, how far each slot runs down past the cone.
thr_pitch    = 3.00;   // mm, trapezoidal thread pitch. Coarse prints better.
thr_depth    = 1.20;   // mm, thread radial depth.
// UNRESOLVED, pending the four-nut coupon in coupons.scad.
// [thr_clear, thr_axial] = [0.35, 0.25] is the pair the bench ran on
// 2026-09-12, and it JAMMED - two turns of four and then solid. Leaving
// the disproved value here as if it were settled is exactly what the
// house rule against invented specs forbids, so: this is a placeholder,
// not an answer. Print coupons.scad what="thread", take the smallest nut
// that runs the full length, and put ITS two numbers here.
thr_clear    = 0.35;   // mm, radial clearance. PLACEHOLDER - see above.
// Tooth shape, as AXIAL half-widths in fractions of the pitch. Read the
// comment on thread_profile() before touching these: they are converted
// to ANGLES, because that is what a twisted extrude turns into height.
// root - crest sets the flank slope. At 0.25/0.10 the flank runs 0.45 mm
// axially over thr_depth of radius, so a 0.20 mm layer oversteps by
// 0.53 mm - about one line width, which prints without support. Make the
// crest larger and the flank gets shallower and starts drooping.
thr_duty     = 0.25;   // tooth half-width at the ROOT / thr_pitch.
thr_crest    = 0.10;   // tooth half-width at the CREST / thr_pitch.
thr_axial    = 0.25;   // mm, axial slack. PLACEHOLDER - see thr_clear.
// How far the tooth polygon's root arc sits INSIDE the base circle it is
// unioned with. circle(r) is drawn as an inscribed polygon, so its real
// radius dips ~0.010 mm below r between facets; a root arc at minor-eps
// (0.01) lands within 0.0004 mm of that dip and the union comes out
// tangent, which OpenSCAD resolves into dozens of zero-volume helical
// sheets in the exported STL (36 of them in the ring) while still
// reporting NoError. 0.05 clears the dip by 5x and costs nothing: the
// circle covers this arc completely either way.
thr_sink     = 0.05;   // mm, root arc inset below the thread minor radius.
// Radial interference between the ring's internal cone and the collar's
// cone when the ring is fully down. This IS the clamp: the collet has to
// close by bore_clear/2 just to touch the cane, so anything less than
// that does nothing at all. There is an assert on it below.
collet_squeeze = 0.80; // mm, radial closure the ring forces on the collet.
ring_wall    = 4.00;   // mm, wall outside the ring's thread.
// How much of the collar's cone the ring's internal cone actually grips.
// A collet closes most at the free end of its fingers, so a short ring
// that only touches the finger ROOTS squeezes the bore far less than its
// thread torque suggests. Keep this close to cone_len.
cone_engage  = 17.0;   // mm, ring cone length (of cone_len available).
ring_flutes  = 10;     // finger flutes so the ring turns by hand.
flute_d      = 5.0;    // mm, flute cutter diameter.

/* [Dovetail joint - used at every interface] */
dt_wide      = 20.0;   // mm, dovetail width at its buried face.
dt_narrow    = 14.0;   // mm, width at the mouth.
dt_depth     = 7.0;    // mm, how deep the dovetail sits in its socket.
dt_len       = 30.0;   // mm, slide length (along the cane axis).
dt_clear     = 0.25;   // mm, per-face clearance. Set from the coupons.
pad_w        = 30.0;   // mm, width of the flat pad the socket is cut into.
pad_t        = 9.0;    // mm, pad thickness measured off the collar surface.
pawl_w       = 10.0;   // mm, pawl width.
pawl_t       = 1.6;    // mm, pawl spring thickness.
pawl_len     = 16.0;   // mm, pawl cantilever length.
pawl_catch   = 1.5;    // mm, how far the catch stands proud.
// The catch's height along the slide, and the window in the collar that
// receives it, are the SAME dimension in two different modules. It was
// the literal 3 in both, plus a bare 1.5 (= half of it) positioning the
// window, so moving one silently broke the other. A deleted earlier
// version of the window used 4 for the same thing.
pawl_catch_h = 3.0;    // mm, catch height along the slide.

/* [Ball joint - only used when joint = "ball"] */
ball_d       = 22.0;   // mm, ball diameter. Bigger = more grip area, more bulk.
ball_clear   = 0.30;   // mm, added to the socket's spherical radius x2.
neck_d       = 11.0;   // mm, ball stem. Sets how far you can tilt before it fouls.
neck_len     = 7.0;    // mm, stem length between the arm and the ball.
sock_wall    = 4.50;   // mm, wall around the ball.
sock_mouth   = 0.78;   // fraction of ball_d left open at the lip. Under 1.0 is
                       // what captures the ball: it snaps past the equator and
                       // cannot fall back out even with the ring off.
sock_base    = 7.0;    // mm, solid base below the ball cavity.
sock_thr_len = 10.0;   // mm, threaded band on the socket.
sock_cone_len = 12.0;  // mm, slotted cone above it.
sock_taper   = 1.80;   // mm, radius lost up the socket cone.
sock_engage  = 10.0;   // mm, how much of that cone the lock ring grips.
ball_squeeze = 0.60;   // mm, radial closure the lock ring forces on the socket.
sock_slots   = 4;      // socket fingers.
sock_slot_w  = 2.40;   // mm, socket slot width.

/* [Geometry] */
// The repo derives the arm angle as 90 - cane_angle + cam_down, which
// puts the rear camera cam_down degrees below the horizon. DESIGN.md s4
// wants 5 deg; the app accepts 3-8 and shows it live on the Mount card.
cane_angle   = 45;     // deg above horizontal, cane in the walking pose.
cam_down     = 5;      // deg, rear camera below the horizon.
// Not a styling number. The phone hangs BELOW the dovetail by half the
// back plate, and because the phone is raked over by arm_angle that bottom
// corner swings back in toward the shaft. At 46 mm (the value inherited
// from the screwed mount, where the geometry is different) the bottom
// front lip cleared the cane by 1.1 mm, which is a rattle at best. The
// assert below computes the real gap; keep it above 8 mm.
arm_reach    = 58.0;   // mm, collar pad face -> the cradle's dovetail mouth.
// The fin is DEEP along the cane axis and THIN across it. The phone hangs
// off the end of it, so the bending plane is the one containing the cane
// and the arm; depth in that plane is what stops the phone nodding. Get
// these two the wrong way round and the arm is a diving board.
// The arm prints on its side, so arm_t becomes the BUILD HEIGHT of the
// fin. If it is thinner than dt_wide the two dovetail tenons stand proud
// of the fin in the build direction and the part balances on two knife
// edges: Creality Print measured the first layer at 42 mm2 for a 21 cm3
// part, against 500-840 mm2 for everything else on the plate. It will not
// stay on the bed. Matching dt_wide puts the whole fin face down instead,
// and makes the arm stiffer on the axis that carries the phone. There is
// an assert below.
arm_t        = 20.0;   // mm, fin thickness ACROSS the cane (Y).  (was 10.0)
// A straight boss on the cradle end, standing BEHIND the dovetail mouth
// (away from the phone). It is not decoration and it is not stiffening:
// it moves the point where the fin starts diving back toward the collar,
// and the fin's dive is what drove the fin through the cradle's back
// plate. Measured 2026-09-12: with a 4 mm boss the fin crossed the plate
// at phone-y 34.7-36.8 mm and intersect(arm, cradle) was 2213 mm3 - the
// two parts could not be assembled at all. Lengthening the boss walks
// that crossing down into the lower vent window, which is already a hole.
// If you shorten it, re-run the interference probe in PRINTING.md.
arm_taper    = 16.0;   // mm, length over which the fin narrows to arm_tip_t.
arm_boss     = 14.0;   // mm, straight boss behind the cradle dovetail mouth.
arm_w        = 30.0;   // mm, fin depth ALONG the cane axis (Z), at the root.

/* [Phone: iPhone 17 Pro Max - Apple drawings, do not edit] */
phone_w      = 78.0;   // mm (drawing 77.98).
phone_h      = 163.4;  // mm (drawing 163.43).
phone_d      = 8.75;   // mm, excludes the camera plateau.
phone_r      = 11.7;   // mm, plan-view corner radius.
plateau_h    = 49.0;   // mm, camera plateau height from the TOP edge.
plateau_clear = 2.0;   // mm, gap plateau lower edge -> back plate.

/* [Cradle] */
clear        = 0.30;   // mm, gap phone <-> cradle on every side.
back_t       = 3.20;   // mm, back plate thickness.
// Opening in the BOTTOM edge wall for the charging cable and the bottom
// speaker. Without it the cradle seals both: measured 2382 mm3 of solid
// wall across the full 83.80 mm width, one piece, no opening anywhere.
// That means the phone cannot be charged while mounted - on a route that
// runs ARKit, LiDAR and GPS continuously - and it covers the speaker the
// app falls back to when no headphones are connected. Found 2026-09-12.
//
// port_w is a WINDOW WIDTH, not a plug spec. The actual clearance a
// right-angle USB-C plug body needs is unknown and must be measured
// against the cable you will use; 34 mm is chosen to clear the port and
// both speaker grilles on a phone this size, not from any datasheet.
// The cut runs the full wall depth and full height, so it does not leave
// a lip bridging the opening - the phone is still carried by the cups at
// each end, which the assert below keeps wide enough to be real.
port_w       = 34.0;   // mm, bottom-edge window width. MEASURE your plug.
wall_t       = 2.60;   // mm, side wall thickness.
lip_w        = 1.20;   // mm, front lip reach over the screen edge. Keep < 2.56.
lip_t        = 1.60;   // mm, lip thickness.
cup_len      = 13.0;   // mm, bottom corner cups reach this far in from each side.
// WHERE ALONG THE PHONE THE ARM JOINS, measured from the phone's bottom
// edge. This was hard-coded at plate_top/2 - the plate's mid-height - and
// that is the one value it must not have. The arm is a straight web from
// the collar out to this joint, and the collar is on the CANE side, which
// is the same side the phone is on. With the joint at mid-height the
// plate's lower half rakes back across that web: measured 2026-09-12,
// intersect(arm, cradle) = 2213 mm3 and the arm reached 43.07 mm past the
// back glass - straight through the phone. Nothing could be assembled.
// Low enough and the web passes UNDER the plate's bottom edge instead.
// The cost is a longer moment arm on the dovetail, which is why this is
// as high as the interference probe allows rather than zero.
block_y      = 26.0;   // mm, dovetail joint centre, up from the phone's bottom edge.
// Height of the dovetail block ABOVE the plain dt_depth socket: a plain
// standoff that pushes the whole cradle further out along the arm, away
// from the web. Costs a longer lever on the joint, buys clearance.
dt_stand     = 0.0;    // mm, extra standoff under the cradle's dovetail block.
latch_w      = 24.0;   // mm, sprung top latch width.
latch_t      = 2.20;   // mm, latch spring thickness.
latch_rise   = 16.0;   // mm, how far the latch cantilevers past the back plate.
latch_grab   = 2.60;   // mm, how far the latch hooks over the screen.
vent         = true;   // open the back plate so the phone sheds heat.
vent_min     = 14.0;   // mm, shortest vent window worth cutting.
// Button windows measured from the TOP edge (Apple drawing).
left_windows  = [[28, 71]];
right_windows = [[44, 67], [97, 127]];

$fa = 2;
$fs = 0.5;

// ------------------------------------------------------------ derived
eps       = 0.01;
bore_d    = pole_d + bore_clear;
bore_r    = bore_d / 2;
core_r    = bore_r + collar_wall;          // collar outer radius = thread major
thr_minor = core_r - thr_depth;
cone_r0   = core_r;
cone_r1   = core_r - cone_taper;
collar_h  = base_len + thread_len + cone_len;
ring_h    = thread_len + cone_engage;
ring_or   = core_r + thr_clear + ring_wall;
arm_angle = 90 - cane_angle + cam_down;    // deg, arm relative to the cane axis
plate_top = phone_h - plateau_h - plateau_clear;   // back plate stops here
inner_x   = phone_w / 2 + clear;           // inside face of a side wall
outer_x   = inner_x + wall_t;              // outside face of a side wall
pad_x     = core_r + pad_t;                // outer face of the collar pad
// ball joint
ball_r    = ball_d / 2;
sock_or   = ball_r + sock_wall;            // socket outer radius = its thread major
sock_h    = sock_base + sock_thr_len + sock_cone_len;
sock_ctr  = sock_base + ball_r;            // height of the ball centre in the socket
lock_h    = sock_thr_len + sock_engage;
lock_or   = sock_or + thr_clear + ring_wall;
// Dovetail placement on the collar. The socket is open at the BOTTOM so
// the arm slides up into it, and closed at the top so it lands on a stop
// instead of being held by the pawl alone.
dt_top    = dt_len;                 // z of the socket's closed end
arm_z     = dt_top - dt_len / 2;    // z of the arm's own origin, in collar coords
// Fin width where it passes through the cradle's dovetail MOUTH. Any
// wider and the fin cannot enter the socket at all.
arm_tip_t = dt_narrow - 2 * dt_clear;

assert(base_len >= dt_len + 4,
       "base_len must exceed dt_len by at least 4 mm or the dovetail socket cuts through the pad top");
assert(pad_w >= dt_wide + 6,
       "pad_w must exceed dt_wide by at least 6 mm or the socket breaks out of the pad sides");
assert(pad_t > dt_depth,
       "pad_t must exceed dt_depth or the socket cuts into the collar bore");
assert(arm_t >= dt_wide,
       "arm_t is thinner than dt_wide - the arm will print balanced on its two dovetail edges");

// How close the phone gets to the shaft. The bottom front corner of the
// cradle is the worst point: it sits (wall_t + plate_top/2) below the
// dovetail along the phone, and (phone_d + lip_t + back_t + dt_depth)
// proud of the mating face, and arm_angle rakes both of those back toward
// the cane. Pushed through the same two transforms assembly() uses, so if
// you change those, change this.
tip_x     = pad_x + arm_reach
            - (phone_d + lip_t + back_t + dt_depth + dt_stand) * cos(arm_angle)
            - (wall_t + block_y) * sin(arm_angle);
tip_clear = tip_x - pole_d / 2;
assert(tip_clear >= 8,
       "the cradle's bottom corner fouls the cane - raise arm_reach");

// =====================================================================
// Thread generator
// =====================================================================
// A 2D disc carrying one trapezoidal bump, linear-extruded with twist,
// is a single-start thread. 2021.01 has no thread library and we are not
// taking a dependency for one.
//
// THE ONE THING TO UNDERSTAND HERE. linear_extrude(twist=) turns ANGLE
// into height, not distance. A tooth drawn as a linear offset of y in
// the 2D profile comes out atan(y/r) / (360/thr_pitch) thick, which at
// r = 17 and a 3 mm pitch is THIRTY MICRONS - a seventh of a layer. It
// renders, it passes every assert, it looks like a thread in preview,
// and it slices away to a smooth cylinder. That is exactly what this
// file did until 2026-09-12, and the ring spun freely on the collar.
//
// So the bump is built as an ANGULAR SECTOR: an axial half-width of a mm
// is thr_ang(a) = a * 360 / thr_pitch degrees of arc, at every radius.
// The taper from root to crest is a taper in ANGLE, which is what makes
// the flank a straight line in the finished helix.
function thr_ang(axial_mm) = axial_mm * 360 / thr_pitch;

thr_arc = 16;   // polygon segments per arc. 16 is under 0.02 mm of chord.

// THE FLANK MUST BE INTERPOLATED IN POLAR SPACE, not drawn as a straight
// Cartesian chord from the crest corner to the root corner. A chord from
// (minor+depth) angle ac to (minor) angle ar passes INSIDE circle(minor)
// whenever ar is large: at the shipped defaults (ar = 90, ac = 36) its
// closest approach to the axis is r = 15.65 against a minor of 17.03, so
// union() with circle(minor) swallowed the whole outer half of the tooth
// and the root came out 0.738 mm wide instead of the 1.500 mm thr_duty
// asks for - measured, 2026-09-12, by a radial pin through the band.
// The tooth was square, thr_duty was inert above ~0.155 and INVERTED
// above it (raising it made the tooth narrower), and both asserts below
// guarded a shape the geometry never produced. Walking angle and radius
// together, as here, is what makes a trapezoid in (axial, radius) once
// the twist turns angle into height.
module thread_profile(minor, depth, grow = 0) {
    ar = thr_ang(thr_pitch * thr_duty  + grow);   // root half-angle, deg
    ac = thr_ang(thr_pitch * thr_crest + grow);   // crest half-angle, deg
    rc = minor + depth;                            // crest radius
    rr = minor - thr_sink;                         // root radius, see thr_sink
    union() {
        circle(r = minor);
        polygon(concat(
            // crest arc, -ac -> +ac
            [ for (i = [0 : thr_arc]) let (a = -ac + 2 * ac * i / thr_arc)
                [ rc * cos(a), rc * sin(a) ] ],
            // trailing flank, +ac -> +ar, radius rc -> rr
            [ for (i = [1 : thr_arc]) let (u = i / thr_arc,
                                           a = ac + (ar - ac) * u,
                                           r = rc + (rr - rc) * u)
                [ r * cos(a), r * sin(a) ] ],
            // root arc, +ar -> -ar (passes under the crest; rr < rc, so
            // the loop stays simple for any ar under 180)
            [ for (i = [0 : thr_arc]) let (a = ar - 2 * ar * i / thr_arc)
                [ rr * cos(a), rr * sin(a) ] ],
            // leading flank, -ar -> -ac, radius rr -> rc
            [ for (i = [1 : thr_arc - 1]) let (u = i / thr_arc,
                                               a = -ar + (ar - ac) * u,
                                               r = rr + (rc - rr) * u)
                [ r * cos(a), r * sin(a) ] ]
        ));
    }
}

// thr_ang() is fed a HALF-width, so it returns a HALF-angle: the root arc
// spans twice this. Past 180 the arc wraps onto itself and the polygon
// self-intersects, so 175 is the guard. The old message said "more than
// half a turn", which is a half-angle of 90 - at the shipped defaults the
// expression is 105 and the female tooth is 210 of arc, so the message
// described a limit the default already broke while the assert stayed
// silent. 210 of arc is legal; what is not legal is 360.
assert(thr_ang(thr_pitch * thr_duty + thr_axial / 2) < 175,
       "thread root arc wraps onto itself - lower thr_duty or thr_axial");
assert(thr_duty > thr_crest,
       "thr_duty must exceed thr_crest or the thread flank inverts");
assert(thr_pitch * (1 - 2 * thr_duty) - thr_axial > 0.6,
       "no room left between turns for the mating tooth - lower thr_duty");

// thr_seg trades mesh size against thread smoothness. 24 segments per
// turn on a 3 mm pitch is well under one layer of error and keeps the
// STL small enough that the slicer stays responsive.
thr_seg = 24;   // helix segments per turn
thr_fs  = 0.9;  // mm, facet size around the thread circumference

// grow widens the tooth AXIALLY, in mm. The female thread is cut with
// grow = thr_axial/2 so the two flanks do not wedge against each other.
module thread(len, minor, depth, grow = 0) {
    turns = len / thr_pitch;
    linear_extrude(height = len, twist = -360 * turns,
                   slices = max(24, ceil(turns * thr_seg)), convexity = 12)
        thread_profile(minor, depth, grow, $fs = thr_fs, $fa = 4);
}

// =====================================================================
// The dovetail, shared by every joint
// =====================================================================
// 2D cross-section, mouth at y=0 opening toward -y, buried face at +y.
module dt_section(grow = 0) {
    polygon([[-(dt_narrow / 2 + grow), -grow],
             [ (dt_narrow / 2 + grow), -grow],
             [ (dt_wide  / 2 + grow),  dt_depth + grow],
             [-(dt_wide  / 2 + grow),  dt_depth + grow]]);
}

// A tenon standing proud of the XY plane, sliding along Z.
module dt_tenon(len = dt_len) {
    translate([0, 0, -len / 2])
        linear_extrude(height = len, convexity = 8)
            dt_section(0);
}

// The matching socket, cut deeper and longer so it always clears.
module dt_socket(len = dt_len + 1) {
    translate([0, 0, -len / 2])
        linear_extrude(height = len, convexity = 8)
            dt_section(dt_clear);
}

// Cantilever pawl: a flat spring with a catch on its free end. Sits in a
// pocket beside the tenon and clicks into the socket's catch hole.
// Drawn in the ARM frame with x = 0 on the tenon's buried face: the leaf
// lies just inside the tenon (+X) and the catch stands proud of it (-X),
// so it drops into the collar's window. Rooted at the bottom, free at the
// top, because the arm slides UP into the collar.
module pawl_spring() {
    union() {
        translate([0, -pawl_w / 2, -pawl_len / 2]) cube([pawl_t, pawl_w, pawl_len]);
        translate([-pawl_catch, -pawl_w / 2, pawl_len / 2 - pawl_catch_h])
            cube([pawl_catch + eps, pawl_w, pawl_catch_h]);
    }
}

// =====================================================================
// COLLAR - the cane interface
// =====================================================================
module collar_body() {
    union() {
        cylinder(h = base_len, r = core_r);
        translate([0, 0, base_len]) thread(thread_len, thr_minor, thr_depth);
        translate([0, 0, base_len + thread_len])
            cylinder(h = cone_len, r1 = cone_r0, r2 = cone_r1);
    }
}

// Flat pad on +X carrying the dovetail socket. Only over the base, so it
// never fouls the ring or the collet fingers.
module collar_pad() {
    hull() {
        translate([pad_x - 2, -pad_w / 2, 0]) cube([2, pad_w, base_len]);
        translate([0, 0, 0]) cylinder(h = base_len, r = core_r - 0.5);
    }
}

module collar() {
    difference() {
        union() { collar_body(); collar_pad(); }
        translate([0, 0, -eps]) cylinder(h = collar_h + 2 * eps, r = bore_r);
        // grip ribs
        for (i = [0 : grip_ribs - 1])
            rotate([0, 0, i * 360 / grip_ribs])
                translate([bore_r - rib_h, 0, -eps])
                    cylinder(h = collar_h + 2 * eps, r = rib_w / 2, $fn = 12);
        // collet slots
        for (i = [0 : n_slots - 1])
            rotate([0, 0, i * 360 / n_slots + 45])
                translate([0, -slot_w / 2, base_len + thread_len - slot_over])
                    cube([core_r + 2, slot_w, cone_len + slot_over + 2]);
        // Dovetail socket. rotate([0,0,90]) puts the profile's width on Y
        // and its depth on -X, so the mouth is the flat +X pad face and the
        // slide axis is Z = the cane axis. Open at the bottom (z < 0),
        // stopped at z = dt_top.
        // The +2 of extra socket length all goes BELOW, at the open
        // mouth. A trailing "+ 1" here used to split it, putting the
        // closed face at z = 31 against a tenon that tops out at 30:
        // measured, socket void z[-1.00, 31.00] vs tenon z[0.00, 30.00],
        // so the joint had 1.00 mm of free axial play and the phone's
        // weight hung off the 1.6 mm pawl leaf instead of landing on the
        // stop this socket exists to provide. Fixed 2026-09-12.
        translate([pad_x, 0, dt_top - (dt_len + 2) / 2])
            rotate([0, 0, 90]) dt_socket(dt_len + 2);
        // Window the arm's pawl catches in. Through the pad, so you can
        // see it seat and push it back out with a fingernail.
        translate([pad_x - dt_depth / 2, 0, arm_z + pawl_len / 2 - 1.5])
            cube([dt_depth + pad_t, pawl_w + 2 * dt_clear, 3 + 2 * dt_clear],
                 center = true);
    }
}

// =====================================================================
// COLLET NUT - screws down a slotted cone and closes it
// =====================================================================
// One module, two uses: the big ring that clamps the cane, and the small
// lock ring that clamps the ball. Same mechanism, same feel in the hand,
// one place to fix if the thread fit is wrong.
// cone_r_lo / cone_r_hi are the nut's internal cone radii AS DRAWN - no
// clearance is added to them, because on this face clearance is the enemy.
// The caller derives them from the cone it has to squeeze; see ring().
module collet_nut(h, outer_r, thr_len, tminor, cone_r_lo, cone_r_hi, flutes) {
    difference() {
        cylinder(h = h, r = outer_r);
        translate([0, 0, -eps])
            thread(thr_len + 2, tminor + thr_clear, thr_depth, thr_axial / 2);
        translate([0, 0, thr_len])
            cylinder(h = h - thr_len + eps, r1 = cone_r_lo, r2 = cone_r_hi);
        for (i = [0 : flutes - 1])
            rotate([0, 0, i * 360 / flutes])
                translate([outer_r, 0, -eps])
                    cylinder(h = h + 2 * eps, r = flute_d / 2, $fn = 20);
    }
}

// The nut's cone must share the CONE's taper rate, not the cone's end
// radii. cone_r0/cone_r1 are separated by cone_taper over cone_len; the
// nut only spans cone_engage of that, so handing it cone_r1 makes it a
// steeper cone than the thing it grips - contact degenerates to a line at
// the small end and the collet closes by almost nothing. Take the rate,
// then subtract collet_squeeze so the whole face interferes.
ring_cone_lo = cone_r0 - collet_squeeze;
ring_cone_hi = ring_cone_lo - cone_taper * cone_engage / cone_len;
assert(collet_squeeze > bore_clear / 2 + 0.25,
       "collet_squeeze is smaller than the bore clearance it has to take up first - the ring will bottom out before it touches the cane");
assert(cone_engage <= cone_len,
       "cone_engage exceeds cone_len - the ring's cone runs off the end of the collar's");

module ring() {
    collet_nut(ring_h, ring_or, thread_len, thr_minor,
               ring_cone_lo, ring_cone_hi, ring_flutes);
}

lock_cone_lo = sock_or - ball_squeeze;
lock_cone_hi = lock_cone_lo - sock_taper * sock_engage / sock_cone_len;
assert(ball_squeeze > ball_clear / 2 + 0.15,
       "ball_squeeze is smaller than the ball clearance it has to take up first");

module lock() {
    collet_nut(lock_h, lock_or, sock_thr_len, sock_or - thr_depth,
               lock_cone_lo, lock_cone_hi, 8);
}

// =====================================================================
// SOCKET - the clamped ball cup. Dovetails onto the cradle.
// =====================================================================
// Prints mouth-up with no support: the spherical cavity is a dome over
// air only above its own equator, and above the equator the wall is
// closing IN toward the mouth, which is self-supporting.
module socket() {
    mouth_r = ball_d * sock_mouth / 2;
    difference() {
        union() {
            cylinder(h = sock_base + sock_thr_len, r = sock_or);
            translate([0, 0, sock_base + sock_thr_len])
                cylinder(h = sock_cone_len, r1 = sock_or, r2 = sock_or - sock_taper);
            // thread band
            translate([0, 0, sock_base])
                thread(sock_thr_len, sock_or - thr_depth, thr_depth);
        }
        // the ball cavity
        translate([0, 0, sock_ctr]) sphere(r = ball_r + ball_clear);
        // mouth, straight up from the top of the ball
        translate([0, 0, sock_ctr - eps])
            cylinder(h = sock_h - sock_ctr + 1, r = mouth_r);
        // slots so the fingers can open for the ball and close on it
        for (i = [0 : sock_slots - 1])
            rotate([0, 0, i * 360 / sock_slots + 45])
                translate([0, -sock_slot_w / 2, sock_ctr - ball_r * 0.35])
                    cube([sock_or + 2, sock_slot_w, sock_h]);
    }
}

// The socket plus the tenon that plugs it into the cradle's dovetail.
// The socket plus the tenon that plugs it into the cradle's dovetail. The
// tenon hangs BELOW the cup (depth on -Z, sliding on Y, matching the
// cradle's socket exactly), so the part prints tenon-down and cup-up and
// the ball cavity is a self-supporting dome. The flare between the two is
// there so the cup does not start as a ring of bridges over the tenon.
module socket_part() {
    union() {
        socket();
        rotate([-90, 0, 0]) dt_tenon();
        hull() {
            translate([0, 0, -eps])
                linear_extrude(height = eps)
                    square([dt_wide, dt_len], center = true);
            cylinder(h = sock_base * 0.6, r = sock_or);
        }
    }
}

// Ball on a neck, for the far end of the arm.
module ball_stud() {
    cylinder(h = neck_len, r = neck_d / 2);
    translate([0, 0, neck_len + ball_r * 0.72]) sphere(r = ball_r);
    // blend the neck into the ball so the joint is not a stress riser
    hull() {
        translate([0, 0, neck_len - eps]) cylinder(h = eps, r = neck_d / 2);
        translate([0, 0, neck_len + ball_r * 0.72]) sphere(r = ball_r * 0.92);
    }
}

// =====================================================================
// ARM - sets the camera angle. Prints flat on its side, no support.
// =====================================================================
// Local frame: tenon into the collar points -X, the fin runs +X, the
// cradle tenon sits at the far end rotated by arm_angle.
// ARM frame = COLLAR frame, rotated nowhere: +Z is the cane axis, +X is
// radially out from the cane, Y is across it. That is deliberate. The arm
// is the part that has to agree with two different mating faces at once,
// and every time this file has been wrong it has been because the arm was
// drawn in a frame of its own and the dovetails ended up on the wrong
// axis. Sharing the collar's frame makes assembly() a single translate,
// which is checkable by eye.
//
// x = 0 is the mouth of the collar's dovetail, so the tenon runs from
// x = 0 back to x = -dt_depth and the fin runs out to x = arm_reach.
//
// The export at the bottom of this file lays the arm on its side for
// printing. Do not rotate it again in the slicer.
module arm() {

    difference() {
        union() {
            // tenon into the collar: depth on -X, slide on Z
            rotate([0, 0, 90]) dt_tenon();
            // The fin is one hull from the collar face straight to the cradle
            // face, so the load path is a single web with no step in it. The
            // far face is dt_len deep for the same reason the collar pad is:
            // a dovetail needs material behind its whole slide length, or the
            // far half of the tenon hangs off the end of nothing.
            // TWO hulls, not one, and the reason is the first layer.
            //
            // A single hull from arm_t (20) at the collar to arm_tip_t
            // (13.5) at the tip tapers SYMMETRICALLY about Y, and the
            // export rotates Y onto the build Z - so the fin came out a
            // wedge balanced on one edge. Measured: bed-contact area
            // 0.30 mm2 on a 42.66 cm3 part, against 672 / 810 / 506 mm2
            // for the collar, cradle and ring. It would peel off the bed
            // in the first minute. This is the same failure the comment
            // at arm_t's declaration says was fixed by setting
            // arm_t = dt_wide; that fix was undone the moment the tip
            // was narrowed to clear the socket mouth on 2026-09-12, and
            // assert(arm_t >= dt_wide) did not catch it because arm_t is
            // still 20 - the taper happens at the far end.
            //
            // So: hold full arm_t along the reach (flat bottom, real
            // first layer), and narrow to arm_tip_t only over the last
            // arm_taper mm, which is all that has to pass through the
            // dt_narrow mouth.
            hull() {
                translate([-eps, -arm_t / 2, -arm_w / 2]) cube([eps, arm_t, arm_w]);
                translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0])
                    translate([-(dt_depth + 2 + arm_taper), -arm_t / 2, -dt_len / 2])
                        cube([eps, arm_t, dt_len]);
            }
            hull() {
                translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0])
                    translate([-(dt_depth + 2 + arm_taper), -arm_t / 2, -dt_len / 2])
                        cube([eps, arm_t, dt_len]);
                // ACROSS the cane this box is the socket MOUTH width, not
                // arm_t. dt_wide (20) is the dovetail's BURIED width; the
                // mouth is only dt_narrow (14). A fin of arm_t = dt_wide
                // cannot pass through a dt_narrow mouth - its shoulders
                // land on the cradle block's face, 544 mm3 deep. The hull
                // tapers 20 -> 13.5 along the reach, which is the right
                // shape anyway: widest where the bending moment is.
                // Starts dt_depth + 2 INSIDE the socket, not at the mouth
                // plane. A hull only holds its end width AT the end face;
                // 1.7 mm back toward the collar it has already widened to
                // 8.03 mm half-width against a 7.25 mm socket half-mouth,
                // which is 11 mm3 of shoulder sitting on the block. The
                // tenon unions over this box and supplies the real
                // dovetail, so a narrow box here costs nothing.
                translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0])
                    translate([-(dt_depth + 2), -arm_tip_t / 2, -dt_len / 2])
                        cube([arm_boss + dt_depth + 2, arm_tip_t, dt_len]);
            }
            // Far end. Both the tenon and the ball face back INBOARD, along
            // -X, because the phone hangs on the cane side of the cradle's
            // back plate and the arm tip reaches past it. Get this backwards
            // and the camera ends up staring at the shaft.
            //
            // With rotate([0, arm_angle, 0]) the phone's long axis comes out
            // at (sin, 0, cos) of arm_angle - up the cane and away from it -
            // and the back glass normal at (-cos, 0, sin). Tipped into the
            // walking pose that is cam_down degrees below the horizon, which
            // is the identity hardware/mount/cane_mount.scad states at its
            // line 33: camera pitch = arm_angle + cane_angle - 90.
            translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0])
                if (joint == "ball") rotate([0, -90, 0]) ball_stud();
                else                 rotate([0, 0, 90]) dt_tenon();
        }
        // Pocket that frees the pawl leaf. Open upward, and stopping 4 mm
        // above the tenon's bottom so the leaf keeps a rooted foot.
        translate([-dt_depth - eps, -(pawl_w + 3) / 2, -pawl_len / 2 + 4])
            cube([pawl_t + 2.0, pawl_w + 3, pawl_len + 8]);
    }
    // the pawl leaf, rooted in the material the pocket left below it
    translate([-dt_depth, 0, 0]) pawl_spring();
}

// =====================================================================
// CRADLE - holds the phone. Prints back-down, no support.
// =====================================================================
// Frame: X across the phone, centred. Y=0 at the BOTTOM edge, +Y toward
// the top. Z=0 at the back glass, +Z toward the screen.
module phone_block(grow = 0, height = phone_d + 10) {
    linear_extrude(height = height, convexity = 6)
        offset(r = phone_r + grow)
            offset(r = -phone_r)
                square([phone_w + 2 * grow, phone_h + 2 * grow], center = true);
}

// Two vent windows, one either side of the spine the dovetail block sits
// on. Cut from the plate ALONE - if the vent is subtracted from the whole
// part it eats the spine and the dovetail block ends up floating.
module back_plate() {
    difference() {
        translate([0, plate_top / 2, -back_t])
            linear_extrude(height = back_t)
                offset(r = 4) offset(r = -4)
                    square([2 * outer_x, plate_top], center = true);
        // Vents straddle the dovetail block, so they move with block_y.
        // A window shorter than vent_min is dropped: at a low block_y the
        // lower one would come out inside out (y1 < y0) and cut a hole
        // where the bottom cups live.
        if (vent)
            for (yc = [[6, block_y - 22], [block_y + 22, plate_top - 8]])
                if (yc[1] - yc[0] >= vent_min)
                translate([0, (yc[0] + yc[1]) / 2, -back_t - 1])
                    linear_extrude(height = back_t + 2)
                        offset(r = 7) offset(r = -7)
                            square([2 * outer_x - 30, yc[1] - yc[0]], center = true);
    }
}

module cradle() {
    difference() {
        union() {
            back_plate();
            // side walls, full height, with the front lip on top
            for (sx = [-1, 1]) scale([sx, 1, 1]) {
                translate([inner_x, 0, -back_t])
                    cube([wall_t, plate_top, back_t + phone_d]);
                translate([inner_x - lip_w, 0, phone_d - eps])
                    cube([wall_t + lip_w, plate_top, lip_t]);
            }
            // bottom edge wall + corner cups with their lips
            translate([-outer_x, -wall_t, -back_t])
                cube([2 * outer_x, wall_t, back_t + phone_d]);
            for (sx = [-1, 1]) scale([sx, 1, 1])
                translate([inner_x - cup_len, -wall_t, phone_d - eps])
                    cube([cup_len, wall_t + lip_w, lip_t]);
            // sprung top latch
            translate([-latch_w / 2, plate_top - eps, -back_t])
                cube([latch_w, latch_rise, latch_t]);
            translate([-latch_w / 2, plate_top + latch_rise - latch_t, -back_t])
                cube([latch_w, latch_t, back_t + phone_d + latch_grab]);
            // The hook has to sit ON the front face, not back_t below it -
            // at phone_d - back_t it is buried 3.2 mm inside the phone and
            // grabs nothing.
            translate([-latch_w / 2, plate_top + latch_rise - latch_t - latch_grab,
                       phone_d])
                cube([latch_w, latch_t + latch_grab, latch_t]);
            // Dovetail socket block on the back, with a 45-degree flare up
            // into the back plate. The flare is not decoration: this part
            // stands on the block, so the plate around it is 7 mm off the
            // bed. The flare carries the plate for dt_depth in every
            // direction, which is as much as geometry can do here - the
            // rest of the plate still wants support. See the README.
            translate([-(dt_len + 10) / 2, block_y - 16,
                       -back_t - dt_depth - dt_stand])
                cube([dt_len + 10, 32, dt_depth + dt_stand + eps]);
            hull() {
                translate([-(dt_len + 10) / 2, block_y - 16,
                           -back_t - dt_depth - dt_stand])
                    cube([dt_len + 10, 32, eps]);
                translate([-(dt_len + 10) / 2 - dt_depth,
                           block_y - 16 - dt_depth, -back_t - eps])
                    cube([dt_len + 10 + 2 * dt_depth, 32 + 2 * dt_depth, eps]);
            }
        }
        // The phone. HEIGHT MATTERS: phone_block's default runs 10 mm past
        // the phone's front face, and everything that retains the phone -
        // the side lips, the corner cups' lips, the whole top latch - lives
        // in exactly that 10 mm. Subtract the default and you delete every
        // one of them and print a tray the phone falls straight out of.
        // Stop the cut at the front face.
        translate([0, phone_h / 2, 0]) phone_block(clear, phone_d);
        // button windows, measured from the TOP edge
        for (w = left_windows)
            translate([-outer_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        for (w = right_windows)
            translate([inner_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        // Charging / speaker window through the bottom edge wall.
        translate([-port_w / 2, -wall_t - 1, -eps])
            cube([port_w, wall_t + 2, phone_d + lip_t + 2]);
        // Dovetail socket, sliding along Y (= the cane axis in use).
        // LENGTH MATTERS. The block it is cut into is 32 mm long and the
        // 45-degree flare around that block reaches dt_depth further at
        // each end, so a default dt_len+1 socket leaves 0.5 mm of wall at
        // each end and then the flare seals it completely: a blind pocket
        // with 987 mm3 of material where the arm has to enter. Run it past
        // the flare at both ends so the joint is actually open.
        translate([0, block_y, -back_t - dt_depth - dt_stand])
            rotate([-90, 0, 0]) rotate([0, 0, 180])
                dt_socket(dt_len + 4 * dt_depth);
    }
}

// =====================================================================
// Preview
// =====================================================================
// Everything is drawn in the COLLAR frame: +Z up the cane, +X out to the
// phone. world_view tips the whole stack by (90 - cane_angle) about Y so
// you are looking at the walking pose rather than at the print bed, and
// adds the ghost cane and the ghost phone. If the phone ghost is not
// clear of the collar and the shaft is not in front of the camera
// plateau, the arm geometry is wrong - that is what this preview is for.
module assembly() {
    rotate([0, world_view ? -(90 - cane_angle) : 0, 0]) {
        color("khaki")            collar();
        color("orange", 0.9)      translate([0, 0, base_len]) ring();
        color("steelblue", 0.95)  translate([pad_x, 0, arm_z]) arm();

        // Everything past the far end of the arm lives in the arm's
        // far-end frame, so it inherits arm_angle for free.
        translate([pad_x + arm_reach, 0, arm_z]) rotate([0, arm_angle, 0]) {
            if (joint == "ball") {
                // socket coaxial with the stud, i.e. zero deflection
                translate([-(neck_len + ball_r * 0.72) - sock_ctr, 0, 0])
                    rotate([0, 90, 0]) {
                        color("seagreen", 0.9) socket_part();
                        color("orange", 0.9)
                            translate([0, 0, sock_base]) lock();
                        translate([0, -plate_top / 2, -(back_t + dt_depth)])
                            rotate([0, 180, 0]) cradle_and_phone();
                    }
            } else {
                translate([-(back_t + dt_depth + dt_stand), 0, -block_y])
                    rotate([90, 0, -90]) cradle_and_phone();
            }
        }

        if (world_view)
            color("silver", 0.22) translate([0, 0, -90])
                cylinder(h = 260, r = pole_d / 2);
    }
}

module cradle_and_phone() {
    color("tomato", 0.95) cradle();
    if (world_view) {
        color("black", 0.30) translate([0, phone_h / 2, 0])
            phone_block(0, phone_d);
        // Where the rear camera looks. In the world_view render this ray must
        // come out roughly horizontal and tipped slightly DOWN, and it must
        // miss the shaft. If it points at the cane, the arm is mirrored.
        color("red") translate([0, phone_h - plateau_h / 2, 0])
            rotate([180, 0, 0]) cylinder(h = 150, r = 0.7);
    }
}

// =====================================================================
if (part == "assembly")     assembly();
else if (part == "collar")  collar();
else if (part == "ring")    ring();
// Laid on its side: the fin's thin axis becomes the build axis, so the
// dovetails, the pawl leaf and the angled far end all print without
// support and the pawl bends along its layers instead of across them.
else if (part == "arm")     rotate([90, 0, 0]) arm();
else if (part == "cradle")  cradle();
else if (part == "socket")  socket_part();
else if (part == "lock")    lock();

echo(str("bore D", bore_d, "  collar OD D", core_r * 2, "  ring OD D", ring_or * 2,
         "  arm ", arm_angle, "deg  cradle covers ", plate_top, "mm of ", phone_h,
         "  phone-to-shaft gap ", tip_clear, "mm"));
