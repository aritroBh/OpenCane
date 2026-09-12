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
// 1.6, not 2.6: the cone now starts INSIDE the thread's major radius (see
// cone_relief), so 2.6 would leave the finger tips 0.75 mm thick. 1.6 keeps
// them at 1.75 and makes the wedge gentler - the squeeze builds over the
// last 0.6 / 0.08 = 7.5 mm (two and a half turns) instead of the last 4.6.
// A 4.6 deg half-angle is also self-locking against PETG-on-PETG friction,
// so sweep vibration cannot back the ring off.
cone_taper   = 1.60;   // mm, radius lost from the bottom of the cone to the top.
// THE RING'S THREAD BORE HAS TO PASS OVER THE CONE. The ring's threaded band
// sits below its cone, so on the way down its thread crests (radius
// thr_minor + thr_clear) sweep the whole cone. The first version started
// the cone at the thread's MAJOR radius, 0.75 mm outside those crests, and
// the ring's top crest hit the cone's base with 3.8 mm still to go: the
// ring stopped there, which is what happened on the first printed pair.
// Measured on 2026-09-12 by lifting the ring in the model: 0.165 cm3 of
// solid overlap at every height from 6 mm up. The cone base now sits
// cone_relief inside the crests, so the threaded band passes it freely
// and only the ring's own cone ever touches it.
cone_relief  = 0.10;   // mm, cone base radius below the ring's thread crest radius.
n_slots      = 4;      // collet fingers.
slot_w       = 2.60;   // mm, slot width.
// Longer slots = softer fingers = less torque to close the collet. At 5 mm
// the fingers root inside the thread band 14 mm below where the ring bears,
// and closing them 0.8 mm needed about 1 N.m on the ring - which is why the
// first printed ring stopped short of fully down. 8 mm roots them 3 mm
// deeper: stiffness falls by (14/17)^3, about 45%.
slot_over    = 8.0;    // mm, how far each slot runs down past the cone.
thr_pitch    = 3.00;   // mm, trapezoidal thread pitch. Coarse prints better.
thr_depth    = 1.20;   // mm, thread radial depth.
// [thr_clear, thr_axial] = the bench's four-nut coupon (coupons.scad, thr_tests)
// steps radial and axial clearance separately; nut 3 = [0.45, 0.45] is
// the expected winner and is what the collar and ring are cut to here.
// [0.35, 0.25] is what the bench ran on 2026-09-12 and it JAMMED two turns
// in - which the model agrees with: 0.125 mm per flank is under one line
// of over-extrusion. When a nut has been read, put ITS pair here.
thr_clear    = 0.45;   // mm, radial clearance, ring thread vs collar thread. = nut 3.
// Tooth shape, as AXIAL half-widths in fractions of the pitch. Read the
// comment on thread_profile() before touching these: they are converted
// to ANGLES, because that is what a twisted extrude turns into height.
// root - crest sets the flank slope. At 0.25/0.10 the flank runs 0.45 mm
// axially over thr_depth of radius, so a 0.20 mm layer oversteps by
// 0.53 mm - about one line width, which prints without support. Make the
// crest larger and the flank gets shallower and starts drooping.
// (With the polar flank below - the chord version printed a 0.74 mm square
// tooth whatever these said; see thread_profile.)
// 0.30 / 0.067, not 0.25 / 0.10: that flank ran 0.45 mm axially over 1.2 mm
// of radius, 69 degrees from vertical, and every 0.2 mm layer of it hung
// 0.53 mm past the one below - more than a line width, so the lower flank
// of every tooth printed in air. 0.70 mm of run makes it 60 degrees, 0.35
// per layer, which prints clean; the crest is one 0.4 mm line. Measured on
// the STL: the collar had 262 mm2 of >45-degree overhang per mm of thread.
thr_duty     = 0.30;   // tooth half-width at the ROOT / thr_pitch.
thr_crest    = 0.067;  // tooth half-width at the CREST / thr_pitch.
// 0.25 gave 0.125 mm per flank, and a 0.4 mm line printed 0.2 mm layers
// eats that in over-extrusion alone: the first printed ring would not go
// fully down. 0.50 is the usual FDM figure for a 3 mm trapezoid. The
// assert further down keeps the mating tooth from running out of room.
thr_axial    = 0.45;   // mm, axial slack between the two threads' flanks. = nut 3.
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
// 0.80 asked the fingers for four times the closure they need to reach the
// cane (bore_clear/2 = 0.20) and, with the 5 mm slots, about 1 N.m at the
// ring. 0.60 still leaves 0.40 mm of preload after the cane is touched.
// On the cane the ring STOPS about 0.4 / 0.13 = 3 mm short of the shoulder
// - that is the clamp working, not a fault. If it reaches the shoulder
// with the cane in, the bore is too big for the cane.
collet_squeeze = 0.60; // mm, radial closure the ring forces on the collet.
// 5, not 4: the ring is the collar joint's lock (see dt_top), so its rim has
// to reach at least 1 mm past the tenon's buried face at pad_x - dt_depth.
// With the 5 mm dovetail that face is 22.2 mm out and a 4 mm wall put the
// rim at 22.7 - the assert below caught it. 5 mm puts the rim at 23.7.
ring_wall    = 5.00;   // mm, wall outside the ring's thread.
// How much of the collar's cone the ring's internal cone actually grips.
// A collet closes most at the free end of its fingers, so a short ring
// that only touches the finger ROOTS squeezes the bore far less than its
// thread torque suggests. Keep this close to cone_len.
cone_engage  = 17.0;   // mm, ring cone length (of cone_len available).
ring_flutes  = 10;     // finger flutes so the ring turns by hand.
flute_d      = 5.0;    // mm, flute cutter diameter.

/* [Dovetail joint - used at every interface] */
// 45-DEGREE FLANKS: (dt_wide - dt_narrow) / 2 == dt_depth. The arm prints
// on its side and the cradle prints on its socket block, so in both the
// dovetail's width is the build axis and one flank of every tenon and
// socket faces DOWN. At 20 / 14 / 7 that flank was 67 degrees from
// vertical: 0.47 mm of overhang per layer on the fit-critical faces, and
// the slicer wanted support inside the cradle's socket. At 24 / 14 / 5 it
// is 45 degrees, which every printer does clean with nothing under it.
// Retention is unchanged in kind - 5 mm of 45-degree lip each side.
dt_wide      = 24.0;   // mm, dovetail width at its buried face.
dt_narrow    = 14.0;   // mm, width at the mouth.
dt_depth     = 5.0;    // mm, how deep the dovetail sits in its socket.
dt_len       = 30.0;   // mm, slide length (along the cane axis).
dt_clear     = 0.25;   // mm, per-face clearance. Set from the coupons.
pad_w        = 34.0;   // mm, width of the flat pad the socket is cut into (4.75 mm beside the socket).
pad_t        = 9.0;    // mm, pad thickness measured off the collar surface.
// THE PAWL LIVES ON THE BED FACE OF THE FIN. The arm prints on its side, so
// the fin's -Y face is the first layer. A leaf centred in the fin sat in a
// pocket with 1.5 mm of air on both sides of it - in the print that is a
// 20 mm long, 1.2 mm thick wall starting 1.5 mm ABOVE the pocket floor,
// anchored at one end: unprintable. Putting the leaf's outer face ON the
// bed makes it a plain freestanding wall in an open-sided slot, with its
// only clearance above it (a 3.2 mm bridge, trivial). It costs the far
// tenon its -Y lip over the pocket's length; the +Y lip and the lower
// third of the tenon keep the full dovetail.
//
// There is only ONE pawl now, on the far tenon. The collar joint does not
// need one: the collar's socket is closed at the bottom and open at the
// top, the arm drops in with the ring off, and the ring then sits 0.5 mm
// over the tenon and is the lock (see collar()).
pawl_w       = 10.0;   // mm, pawl width, measured up from the fin's bed face.
// 20, not 16: the catch has to be pressed 1.25 mm into its pocket to enter
// the socket, and on a 16 mm leaf that is 2.5% strain in PETG (yield ~4%).
// 20 mm brings it to 1.3%. It still fits inside the 30 mm tenon.
pawl_len     = 20.0;   // mm, pawl cantilever length.
// 1.2 (three 0.4 mm lines), not 1.6: with the leaf 10 mm wide and 20 long,
// 1.6 needed ~10 N to press the catch flush; 1.2 needs ~4 N and strains 1%.
pawl_t       = 1.2;    // mm, pawl spring thickness.
pawl_catch   = 1.5;    // mm, how far the catch stands proud.
// The catch's height along the slide and the window that receives it are
// the SAME dimension in two modules; a literal 3 in both once drifted.
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
// Not a styling number. It sets how far the phone stands off the shaft,
// and with it how far the shaft sits outside the camera cones: at 58 mm
// the shaft's lower end is 45.6 deg off the wide camera's axis against a
// 45 deg keep-out, and 3.6 deg outside the LiDAR's. Shorter is worse. The
// closest printed thing to the shaft is now the cradle's dovetail block
// (the phone rides ABOVE the arm); the assert below keeps that gap over 8.
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
arm_t        = 24.0;   // mm, fin thickness ACROSS the cane (Y) = dt_wide.  (was 10, then 20)
arm_w        = 30.0;   // mm, fin depth ALONG the cane axis (Z), at the root.

/* [Arm far end and cradle mount] */
// The cradle's dovetail block sits BELOW the phone's bottom edge, not
// behind its middle. This is forced, not chosen: the camera has to face
// away from the cane, so the cradle's back plate is on the FAR side of the
// phone from the arm, and the only route from the collar to that plate
// that does not pass through the phone goes around its bottom edge. The
// first version put the block at mid-height and the fin went straight
// through the phone - 6.9 cm3 of overlap, measured on 2026-09-12 - and
// the assembly preview did not show it because the colours overlap too.
// sock_y is the cradle-frame Y (0 = the phone's bottom edge) of the tenon
// centre; the block, its stop and the pawl window all hang off it.
sock_y       = -4.0;   // mm, tenon centre relative to the phone's bottom edge (negative = below).
blk_end      = 5.0;    // mm, solid wall under the socket's closed lower end = the stop the cradle rests on.
far_t        = 8.0;    // mm, thickness of the arm's far pad, outboard of the cradle's mating face.
far_fin      = 20.0;   // mm, how much of the far pad the fin lands on, measured down the pad.
far_gap      = 4.0;    // mm, air between the cradle block's lower end and the fin's top edge.

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
wall_t       = 2.60;   // mm, side wall thickness.
lip_w        = 1.20;   // mm, front lip reach over the screen edge. Keep < 2.56.
lip_t        = 1.60;   // mm, lip thickness.
cup_len      = 13.0;   // mm, bottom corner cups reach this far in from each side.
// Top corner caps on sprung rails replace the old mid-height "top latch",
// which was drawn straight through the phone (its riser was inside the
// pocket, so the phone cut left the hook as a loose island 8.75 mm off the
// bed) and whose leaf sat on the camera plateau. A hook can only stop the
// phone sliding UP if it bears on the top edge, 51 mm above where the
// plate has to stop for the plateau - so the rails run up beside the phone,
// behind the button line, and hook the top corners from the front.
cap_in       = 12.0;   // mm, corner cap reach in from the side, over the top edge.
cap_grab     = 2.00;   // mm, corner lip reach down the front face. Keep < 2.56 (display border).
rail_z       = 2.00;   // mm, rail top above the back glass. Side buttons start at z = 3.0.
vent         = true;   // open the back plate so the phone sheds heat.
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
cone_r0   = thr_minor + thr_clear - cone_relief;   // cone base: clears the ring's crests
cone_r1   = cone_r0 - cone_taper;
assert(cone_r1 - bore_r >= 1.5,
       "collet finger tips are thinner than 1.5 mm - lower cone_taper or raise collar_wall");
assert(cone_r0 < thr_minor + thr_clear,
       "the cone base is outside the ring's thread crests - the ring will jam on it");
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
// Dovetail placement on the collar. The socket is CLOSED at the bottom and
// open through the pad top: with the ring off, the arm drops in from above
// (the tenon runs at x >= pad_x - dt_depth = 2 mm outside the thread's
// major radius, so it clears the threaded band on the way down) and lands
// on the stop. The ring then screws on above it, and because the ring's
// outer radius reaches past the tenon's buried face, the ring is the lock:
// the arm can rise at most the gap under the ring. Gravity seats it, the
// dovetail's friction fit (set from the coupons: "stays put when shaken")
// holds it there, and the ring makes escape impossible. No pawl.
dt_top    = base_len - 0.5;         // z of the tenon's top: 0.5 mm under the ring
arm_z     = dt_top - dt_len / 2;    // z of the arm's own origin, in collar coords
sock_z0   = dt_top - dt_len;        // the stop
sock_z1   = base_len + 1;           // open, through the pad top
pawl_y0   = -arm_t / 2;             // the pawl leaf's outer face = the fin's bed face
assert(pad_x - dt_depth < ring_or - 1,
       "the ring does not reach over the arm's tenon - the collar joint has no lock");
assert(sock_z0 >= 4,
       "no stop wall under the collar's dovetail socket - raise base_len");
// Cradle socket block, in the cradle frame (y along the phone, 0 = bottom edge).
blk_y0    = sock_y - dt_len / 2 - blk_end;   // lower end of the block = under the stop
blk_y1    = sock_y + dt_len / 2 + 1;         // upper end of the block
sock_y0   = sock_y - dt_len / 2;             // the stop: the tenon's lower end lands here
sock_y1   = blk_y1 + dt_depth + 2;           // open top, running out past the flare
rail_h    = back_t + rail_z;                 // rail height, from the plate's back face
// Arm far end, in the far-end frame (z up the mating face, 0 = tenon centre).
far_lo    = -(dt_len / 2 + blk_end + far_gap + far_fin);   // lower end of the far pad

assert(base_len >= dt_len + 4,
       "base_len must exceed dt_len by at least 4 mm or the dovetail socket cuts through the pad top");
assert(pad_w >= dt_wide + 6,
       "pad_w must exceed dt_wide by at least 6 mm or the socket breaks out of the pad sides");
assert(abs((dt_wide - dt_narrow) / 2 - dt_depth) < 0.01,
       "dovetail flanks are not 45 degrees - one flank of every tenon and socket will be an overhang");
assert(pad_t > dt_depth,
       "pad_t must exceed dt_depth or the socket cuts into the collar bore");
assert(arm_t >= dt_wide,
       "arm_t is thinner than dt_wide - the arm will print balanced on its two dovetail edges");

// How close the cradle gets to the shaft. The phone rides above the arm,
// so the worst point is the lower inboard corner of the cradle's dovetail
// block: back_t + dt_depth inboard of the mating face, dt_len/2 + blk_end
// below the tenon centre, half the flare's width off the centreline, and
// arm_angle rakes it back toward the cane. Pushed through the same
// transforms assembly() uses, so if you change those, change this. (The
// arm's own root starts at the pad face, pad_t clear of the bore by
// construction.)
blk_lo    = -(dt_len / 2 + blk_end);
tip_x     = pad_x + arm_reach
            - (back_t + dt_depth) * cos(arm_angle)
            + blk_lo * sin(arm_angle);
tip_y     = (dt_len + 10) / 2 + dt_depth;
tip_clear = sqrt(tip_x * tip_x + tip_y * tip_y) - pole_d / 2;
assert(tip_clear >= 8,
       "the cradle's dovetail block fouls the cane - raise arm_reach");

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
// `lead` chamfers one end face of the catch to 45 degrees so a socket
// arriving from that side cams the leaf in on its own; the other face stays
// square and carries the load. "none" is the collar pawl: it is pressed in
// by hand from under the pad, and both its faces stay square.
module pawl_spring(lead = "none") {
    c0 = pawl_len / 2 - pawl_catch_h;    // the catch spans z = c0 .. c0 + pawl_catch_h
    union() {
        // The leaf is a rectangle in a trapezoid: its outer face is on the
        // fin's bed face, but the tenon's flank runs in from there at 45
        // degrees, so the leaf's outer-inner corner would stand proud of
        // the flank and bind in the socket (2.5 mm3 of it, measured). Trim
        // it to the tenon's own envelope; the bottom of the leaf is then a
        // 45-degree chamfer that prints on its buried edge.
        intersection() {
            translate([0, pawl_y0, -pawl_len / 2]) cube([pawl_t, pawl_w, pawl_len]);
            translate([dt_depth, 0, 0]) rotate([0, 0, 90]) dt_tenon(pawl_len + 2);
        }
        hull() {
            translate([-pawl_catch, pawl_y0, c0 + (lead == "bottom" ? pawl_catch : 0)])
                cube([pawl_catch + eps, pawl_w, pawl_catch_h - (lead == "none" ? 0 : pawl_catch)]);
            translate([-eps, pawl_y0, c0]) cube([2 * eps, pawl_w, pawl_catch_h]);
        }
    }
}

// The pocket that frees a pawl leaf, in the tenon's frame: cut in from the
// buried face by pawl_t + 2 so the leaf has 2 mm to flex, open through the
// fin's bed face and 1.5 mm past the leaf's other edge (the slot's roof, a
// 3.2 mm bridge), open toward the leaf's free end and `over` mm past the
// tenon's end, and closed 4 mm above the leaf's foot so it stays rooted.
module pawl_pocket(over = 5) {
    translate([-dt_depth - eps, pawl_y0 - 1, -pawl_len / 2 + 4])
        cube([pawl_t + 2.0, pawl_w + 1 + 1.5, pawl_len / 2 - 4 + dt_len / 2 + over]);
}

// The arm's far-end frame: origin on the arm's centreline at the cradle's
// mating face, +X outboard (away from the cane and down the back of the
// phone), +Z up the mating face = the far tenon's slide axis. Everything
// at the far end, and assembly()'s placement of the cradle, goes through
// this one module so they cannot disagree.
module far_frame() { translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0]) children(); }

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
        // slide axis is Z = the cane axis. Closed at the bottom (the stop
        // at sock_z0), open through the pad top; the ring above is the
        // lock. See the comment at dt_top.
        translate([pad_x, 0, (sock_z0 + sock_z1) / 2])
            rotate([0, 0, 90]) dt_socket(sock_z1 - sock_z0);
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
            // The fin runs from the collar face to the FOOT of the far pad,
            // which sits below the cradle's dovetail block - not to the
            // tenon. Everything inboard of the cradle's mating face at the
            // tenon's height is the block, its flare, or the phone, so a
            // fin landing there went straight through the phone (see
            // sock_y). One hull, so the load path is a single web with no
            // step in it.
            hull() {
                translate([-eps, -arm_t / 2, -arm_w / 2]) cube([eps, arm_t, arm_w]);
                far_frame() translate([0, -arm_t / 2, far_lo]) cube([far_t, arm_t, far_fin]);
            }
            far_frame() {
                // The far pad: a slab OUTBOARD of the mating face, rising
                // from where the fin lands to the top of the tenon. Nothing
                // lives on that side of the face, so it is as thick as
                // stiffness wants (far_t), and its inboard face IS the
                // mating face the cradle's block sits against.
                translate([0, -arm_t / 2, far_lo])
                    cube([far_t, arm_t, dt_len / 2 - far_lo]);
                // Both the tenon and the ball face back INBOARD, along -X of
                // this frame, because the phone hangs on the cane side of the
                // cradle's back plate. Get this backwards and the camera ends
                // up staring at the shaft.
                //
                // In this frame the phone's long axis is +Z, i.e. (sin, 0, cos)
                // of arm_angle in the collar frame - up the cane and away from
                // it - and the back glass normal is +X = (cos, 0, -sin). Tipped
                // into the walking pose that is cam_down degrees below the
                // horizon, the identity hardware/mount/cane_mount.scad states
                // at its line 33: camera pitch = arm_angle + cane_angle - 90.
                if (joint == "ball") rotate([0, -90, 0]) ball_stud();
                else                 rotate([0, 0, 90]) dt_tenon();
            }
        }
        // The far pawl's pocket. The cradle comes DOWN onto this tenon, so
        // the leaf roots at the top and the catch is at the bottom: the
        // same leaf, mirrored in Z. The pocket stops 1 mm past the tenon's
        // end so it does not nick the fin below. (The collar tenon has no
        // pawl - the ring is its lock; see dt_top.)
        if (joint != "ball")
            far_frame() mirror([0, 0, 1]) pawl_pocket(over = 1);
    }
    // The far pawl's leaf, rooted in the material the pocket left. lead =
    // "bottom" in the leaf's own frame becomes the TOP face after the
    // mirror: that is the face the descending socket meets, so it cams in
    // on its own; the lower face stays square and is what holds the cradle
    // down if something tries to lift it off.
    if (joint != "ball")
        far_frame() mirror([0, 0, 1]) translate([-dt_depth, 0, 0]) pawl_spring(lead = "bottom");
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

// Two vent windows, one above the other. The lower one starts above the
// socket block's flare, which is what carries this plate on the bed. Cut
// from the plate ALONE - subtracted from the whole part it would eat the
// flare's landing.
module back_plate() {
    difference() {
        translate([0, plate_top / 2, -back_t])
            linear_extrude(height = back_t)
                offset(r = 4) offset(r = -4)
                    square([2 * outer_x, plate_top], center = true);
        if (vent)
            for (yc = [[24, 62], [68, plate_top - 8]])
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
            // Side walls, full height, up to the plate top. No front lip on
            // them: the phone goes in from the FRONT - bottom edge into the
            // cups, then the top pressed back past the corner caps - and a
            // full-length lip would make that impossible.
            for (sx = [-1, 1]) scale([sx, 1, 1])
                translate([inner_x, 0, -back_t])
                    cube([wall_t, plate_top, back_t + phone_d]);
            // Bottom corner cups with their front lips. Corners only: the
            // floor between them stays open for the USB-C plug, the speaker
            // and the mics (52 mm; a plug overmold needs 16).
            for (sx = [-1, 1]) scale([sx, 1, 1]) {
                translate([inner_x - cup_len, -wall_t, -back_t])
                    cube([cup_len + wall_t, wall_t, back_t + phone_d]);
                translate([inner_x - cup_len, -wall_t, phone_d - eps])
                    cube([cup_len + wall_t, wall_t + lip_w, lip_t]);
            }
            // Top corner caps on sprung rails. Each rail is the side wall
            // carried on past the plate top as a low bar, from the plate's
            // back face up to rail_z - behind the side buttons (2.66 wide,
            // centred 4.375 deep, so nothing of them below z = 3.0). At the
            // top edge it turns in over the corner and hooks cap_grab down
            // the front face, inside the 2.56 mm display border. The lip is a
            // snap hook the right way round: its UNDERSIDE (the face on the
            // phone) is flat and square, so pulling the phone forward cannot
            // cam it open, and its top/inner edge is a hull down to a line,
            // i.e. a ramp, so pressing the phone's rounded corner in spreads
            // the rail (about 6 mm, ~2 N) and the cap snaps over. To take
            // the phone out, spread the two rails and lift the top.
            for (sx = [-1, 1]) scale([sx, 1, 1]) {
                translate([inner_x, plate_top - eps, -back_t])
                    cube([wall_t, phone_h + clear + wall_t - plate_top + eps, rail_h]);
                translate([inner_x - cap_in, phone_h + clear, -back_t])
                    cube([cap_in + wall_t, wall_t, back_t + phone_d + lip_t]);
                hull() {
                    translate([inner_x - cap_in, phone_h + clear - cap_grab, phone_d])
                        cube([cap_in + wall_t, cap_grab + wall_t, eps]);
                    translate([inner_x, phone_h + clear, phone_d + lip_t - eps])
                        cube([wall_t, wall_t, eps]);
                }
            }
            // Dovetail socket block BELOW the phone, with a 45-degree flare
            // up to plate level on its sides and top, and a roof at plate
            // level so the socket has a full-depth floor where there is no
            // plate. The flare is not decoration: this part stands on the
            // block, so the plate is 7 mm off the bed and the flare carries
            // it for dt_depth around the block - the rest of the plate
            // still wants support. See the README.
            translate([-(dt_len + 10) / 2, blk_y0, -back_t - dt_depth])
                cube([dt_len + 10, blk_y1 - blk_y0, dt_depth + eps]);
            hull() {
                translate([-(dt_len + 10) / 2, blk_y0, -back_t - dt_depth])
                    cube([dt_len + 10, blk_y1 - blk_y0, eps]);
                translate([-(dt_len + 10) / 2 - dt_depth, blk_y0, -back_t - eps])
                    cube([dt_len + 10 + 2 * dt_depth, blk_y1 - blk_y0 + dt_depth, eps]);
            }
            translate([-(dt_len + 10) / 2 - dt_depth, blk_y0, -back_t])
                cube([dt_len + 10 + 2 * dt_depth, -blk_y0 + eps, back_t]);
        }
        // The phone. HEIGHT MATTERS: phone_block's default runs 10 mm past
        // the phone's front face, and everything that retains the phone -
        // the cups' lips and the corner caps - lives in exactly that 10 mm.
        // Subtract the default and you delete every one of them and print
        // a tray the phone falls straight out of. Stop the cut at the front
        // face.
        translate([0, phone_h / 2, 0]) phone_block(clear, phone_d);
        // button windows, measured from the TOP edge
        for (w = left_windows)
            translate([-outer_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        for (w = right_windows)
            translate([inner_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        // Dovetail socket, sliding along Y (= up the mating face in use).
        // CLOSED at the bottom - that end is the stop the cradle's weight
        // rests on, since gravity runs within 5 degrees of this slide - and
        // open at the top, running out past the flare so the tenon can
        // enter. It is dt_clear deeper than the tenon, so it takes 0.25 mm
        // out of the plate where it passes behind the phone; fine at 3.2.
        translate([0, (sock_y0 + sock_y1) / 2, -back_t - dt_depth])
            rotate([-90, 0, 0]) rotate([0, 0, 180])
                dt_socket(sock_y1 - sock_y0);
        // Window the far pawl's catch clicks into. Through the roof, below
        // the phone's bottom edge, so you can see it seat and press it back
        // out with a fingernail.
        // The far frame's -Y is the cradle's +X, so a leaf on the fin's bed
        // face (far-frame y in [pawl_y0, pawl_y0 + pawl_w]) lands here.
        translate([-(pawl_y0 + pawl_w / 2), sock_y - pawl_len / 2 + pawl_catch_h / 2, -back_t / 2])
            cube([pawl_w + 2 * dt_clear, pawl_catch_h + 2 * dt_clear, back_t + 2], center = true);
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
                        translate([0, -sock_y, -(back_t + dt_depth)])
                            rotate([0, 180, 0]) cradle_and_phone();
                    }
            } else {
                translate([-(back_t + dt_depth), 0, -sock_y])
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
         "  block-to-shaft gap ", tip_clear, "mm"));
