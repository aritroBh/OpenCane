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
// The bore coupons bracket ALL THREE candidates, so one 20-minute print
// settles it against the real cane instead of against anyone's memory.
// Print them before the collar. If the winning ring is not near 27.65,
// change this number and tell the rest of the team.
pole_d       = 27.65;  // mm, cane shaft diameter at the collar.
bore_clear   = 0.40;   // mm, ADDED TO DIAMETER. Set this from the coupons.
collar_wall  = 4.20;   // mm, radial wall around the bore.
grip_ribs    = 8;      // axial ribs inside the bore that bite the shaft.
rib_h        = 0.50;   // mm, how far a rib stands proud of the bore.
rib_w        = 1.60;   // mm, rib width at the bore.

/* [Collet and ring] */
base_len     = 9.0;    // mm, unslotted base below the thread.
thread_len   = 15.0;   // mm, threaded band.
cone_len     = 20.0;   // mm, slotted cone above the thread.
cone_taper   = 2.60;   // mm, radius lost from the bottom of the cone to the top.
n_slots      = 4;      // collet fingers.
slot_w       = 2.60;   // mm, slot width.
slot_over    = 5.0;    // mm, how far each slot runs down past the cone.
thr_pitch    = 3.00;   // mm, trapezoidal thread pitch. Coarse prints better.
thr_depth    = 1.20;   // mm, thread radial depth.
thr_clear    = 0.35;   // mm, radial clearance, ring thread vs collar thread.
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
sock_slots   = 4;      // socket fingers.
sock_slot_w  = 2.40;   // mm, socket slot width.

/* [Geometry] */
// The repo derives the arm angle as 90 - cane_angle + cam_down, which
// puts the rear camera cam_down degrees below the horizon. DESIGN.md s4
// wants 5 deg; the app accepts 3-8 and shows it live on the Mount card.
cane_angle   = 45;     // deg above horizontal, cane in the walking pose.
cam_down     = 5;      // deg, rear camera below the horizon.
arm_reach    = 46.0;   // mm, cane surface -> phone back plate.
arm_t        = 10.0;   // mm, arm thickness.
arm_w        = 30.0;   // mm, arm width.

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
latch_w      = 24.0;   // mm, sprung top latch width.
latch_t      = 2.20;   // mm, latch spring thickness.
latch_rise   = 16.0;   // mm, how far the latch cantilevers past the back plate.
latch_grab   = 2.60;   // mm, how far the latch hooks over the screen.
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

// =====================================================================
// Thread generator
// =====================================================================
// A 2D disc carrying one trapezoidal bump, linear-extruded with twist,
// is a single-start thread. 2021.01 has no thread library and we are not
// taking a dependency for one.
module thread_profile(minor, depth) {
    union() {
        circle(r = minor);
        polygon([[minor - eps, -thr_pitch * 0.42],
                 [minor + depth, -thr_pitch * 0.20],
                 [minor + depth,  thr_pitch * 0.20],
                 [minor - eps,  thr_pitch * 0.42]]);
    }
}

// thr_seg trades mesh size against thread smoothness. 24 segments per
// turn on a 3 mm pitch is well under one layer of error and keeps the
// STL small enough that the slicer stays responsive.
thr_seg = 24;   // helix segments per turn
thr_fs  = 0.9;  // mm, facet size around the thread circumference

module thread(len, minor, depth) {
    turns = len / thr_pitch;
    linear_extrude(height = len, twist = -360 * turns,
                   slices = max(24, ceil(turns * thr_seg)), convexity = 12)
        thread_profile(minor, depth, $fs = thr_fs, $fa = 4);
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
module pawl_spring() {
    union() {
        translate([-pawl_w / 2, 0, -pawl_len / 2])
            cube([pawl_w, pawl_t, pawl_len]);
        translate([-pawl_w / 2, 0, pawl_len / 2 - 3])
            cube([pawl_w, pawl_t + pawl_catch, 3]);
    }
}

module pawl_catch_hole() {
    translate([0, dt_depth / 2, pawl_len / 2 - 1.5])
        cube([pawl_w + 2 * dt_clear, dt_depth + 2, 4 + 2 * dt_clear], center = true);
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
        // dovetail socket, mouth on +X, sliding along Z
        translate([pad_x, 0, base_len / 2]) rotate([0, -90, 0]) dt_socket();
        // catch hole for the arm's pawl
        translate([pad_x, 0, base_len / 2]) rotate([0, -90, 0]) pawl_catch_hole();
    }
}

// =====================================================================
// COLLET NUT - screws down a slotted cone and closes it
// =====================================================================
// One module, two uses: the big ring that clamps the cane, and the small
// lock ring that clamps the ball. Same mechanism, same feel in the hand,
// one place to fix if the thread fit is wrong.
module collet_nut(h, outer_r, thr_len, tminor, cone_r_lo, cone_r_hi, flutes) {
    difference() {
        cylinder(h = h, r = outer_r);
        translate([0, 0, -eps]) thread(thr_len + 2, tminor + thr_clear, thr_depth);
        translate([0, 0, thr_len])
            cylinder(h = h - thr_len + eps,
                     r1 = cone_r_lo + thr_clear, r2 = cone_r_hi + thr_clear);
        for (i = [0 : flutes - 1])
            rotate([0, 0, i * 360 / flutes])
                translate([outer_r, 0, -eps])
                    cylinder(h = h + 2 * eps, r = flute_d / 2, $fn = 20);
    }
}

module ring() {
    collet_nut(ring_h, ring_or, thread_len, thr_minor, cone_r0, cone_r1, ring_flutes);
}

module lock() {
    collet_nut(lock_h, lock_or, sock_thr_len, sock_or - thr_depth,
               sock_or, sock_or - sock_taper, 8);
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
module socket_part() {
    union() {
        socket();
        translate([0, 0, dt_depth]) rotate([0, 180, 0]) rotate([0, 0, 90]) dt_tenon();
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
module arm() {
    difference() {
        union() {
            // tapered fin
            hull() {
                translate([0, -arm_w / 2, -arm_t / 2]) cube([eps, arm_w, arm_t]);
                rotate([0, 0, 0])
                    translate([arm_reach, -arm_w / 2, -arm_t / 2])
                        rotate([0, 0, 0]) cube([eps, arm_w, arm_t]);
            }
            // tenon that enters the collar (points -X)
            translate([0, 0, 0]) rotate([0, 90, 0]) dt_tenon();
            // far end: either the cradle dovetail at a fixed angle, or a
            // ball you aim by hand and lock.
            translate([arm_reach, 0, 0]) rotate([0, arm_angle, 0]) {
                translate([-3, -arm_w / 2, -arm_t / 2]) cube([3 + eps, arm_w, arm_t]);
                if (joint == "ball") rotate([0, -90, 0]) mirror([0, 0, 1]) ball_stud();
                else                 rotate([0, -90, 0]) dt_tenon();
            }
        }
        // pocket that frees the collar pawl to flex
        translate([0, 0, 0]) rotate([0, 90, 0])
            translate([0, -dt_depth - 1, 0])
                cube([pawl_w + 2, 3, pawl_len + 6], center = true);
    }
    // the collar pawl itself
    rotate([0, 90, 0]) translate([0, dt_depth - pawl_t - 0.6, 0]) pawl_spring();
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
        if (vent)
            for (yc = [[6, 34], [80, plate_top - 8]])
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
            translate([-latch_w / 2, plate_top + latch_rise - latch_t - latch_grab,
                       phone_d - back_t])
                cube([latch_w, latch_t + latch_grab, latch_t]);
            // dovetail socket block on the back
            translate([-(dt_len + 10) / 2, plate_top / 2 - 16, -back_t - dt_depth])
                cube([dt_len + 10, 32, dt_depth + eps]);
        }
        // the phone
        translate([0, phone_h / 2, 0]) phone_block(clear);
        // button windows, measured from the TOP edge
        for (w = left_windows)
            translate([-outer_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        for (w = right_windows)
            translate([inner_x - 1, phone_h - w[1], -eps])
                cube([wall_t + 2, w[1] - w[0], phone_d + lip_t + 2]);
        // dovetail socket, sliding along Y (= the cane axis in use)
        translate([0, plate_top / 2, -back_t - dt_depth])
            rotate([-90, 0, 0]) rotate([0, 0, 180]) dt_socket();
    }
}

// =====================================================================
// Preview
// =====================================================================
module assembly() {
    collar();
    translate([0, 0, base_len]) color("orange", 0.85) ring();
    color("steelblue", 0.9)
        translate([pad_x - dt_depth, 0, base_len / 2]) arm();
    if (world_view)
        color("silver", 0.25) translate([0, 0, -60]) cylinder(h = 200, r = pole_d / 2);
}

// =====================================================================
if (part == "assembly")     assembly();
else if (part == "collar")  collar();
else if (part == "ring")    ring();
else if (part == "arm")     arm();
else if (part == "cradle")  cradle();
else if (part == "socket")  socket_part();
else if (part == "lock")    lock();

echo(str("bore D", bore_d, "  collar OD D", core_r * 2, "  ring OD D", ring_or * 2,
         "  arm ", arm_angle, "deg  cradle covers ", plate_top, "mm of ", phone_h));
