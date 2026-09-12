// cane_mount.scad - OpenCane / CaneKit: iPhone 17 Pro Max on a 28.75 mm non-metal cane.
//
// STATUS: NOT RENDERED. Written 2026-09-11 on a machine without OpenSCAD, so nobody has pressed
// F5 on this file yet. Before printing anything:
//   1. Open in OpenSCAD 2021.01 or newer (a 2024+ development snapshot with the Manifold backend
//      renders about 100x faster). Fix any syntax error it reports (none are expected).
//   2. Set part = "assembly", press F5, and look at hinge_angle = 35, 50 and 80: the phone ghost
//      (transparent) must not touch the cane, the collar or the ear.
//   3. Select each part in turn, F6 (render), then File > Export > STL. Each part below is already
//      placed in its print orientation (see DESIGN.md section 10).
// Design brief and every number's source: hardware/mount/DESIGN.md.
// Phone numbers: Apple "iPhone 17 Pro Max - Tech Specs" (support.apple.com/en-us/125091) and
// Apple's dimensional drawing (developer.apple.com/accessories -> Dimensional Drawings,
// iphone-17-pro-max.pdf, dated 2025-09-09). Values marked MEASURE were scaled off that drawing or
// are not on it: check them with calipers on the real phone before the final print.
//
// Parts (set `part`):
//   collar_a  upper clamp half + ear + collar-side rosette (print standing, bore vertical)
//   collar_b  lower clamp half with M4 heat-set inserts          (print standing, bore vertical)
//   arm       cradle-side rosette + fin, screws to the back plate (print flat, teeth up)
//   cradle    back plate + side rails + bottom corner cups       (print back plate down)
//   cap       top cap that locks the phone in; 2 x M3            (print back side down)
//   knob      tool-less M5 knob (an M5 hex bolt head presses in)  (print flat)
//   assembly  everything assembled on a ghost cane, with a ghost phone (preview only)
//
// Frames used below (all right-handed, millimetres, degrees):
//   COLLAR frame: +Z = along the cane toward the grip, +Y = the "ear" direction (the upper side
//                 of the cane, where the phone stands), X = lateral (left/right of the walker).
//   PHONE frame:  +X = toward the phone's right edge as seen from the SCREEN, +Y = toward the top
//                 of the phone (Y = 0 is the bottom edge), +Z = toward the screen (Z = 0 is the
//                 back glass; the camera plateau and lenses sit at Z < 0).
//   The hinge axis is parallel to X in both frames. hinge_angle (phi) is the angle between the
//   cane axis (toward the grip) and the phone's long axis (toward its top). With the cane held
//   at cane_angle above horizontal, the camera looks (hinge_angle + cane_angle - 90) degrees
//   below horizontal. DESIGN.md section 4 explains why the target is 5 degrees, not 10-20.

/* [What to render] */
part = "assembly"; // [assembly, collar_a, collar_b, arm, cradle, cap, knob]
// Assembly only: rotate the whole thing so the cane sits at cane_angle (Y = forward, Z = up).
world_view = true;

/* [Cane] */
// MEASURED 27.65 by the bore coupons in hardware/mount_screwless/,
// 2026-09-12, and independently by dial caliper on Sep 11. The 28.75
// here was 1.132 in read off the wrong part of a tapered cane; a collar
// bored for it has 1.10 mm of clearance and spins on the shaft. Changed
// 2026-09-12. Do not put 28.75 back without a ring that proves it.
pole_d       = 27.65;  // mm, stick diameter at the collar spot. MEASURED.
bore_clear   = 0.3;    // mm, added to the bore DIAMETER. Retune from test_coupons.scad bore rings.
collar_len   = 44;     // mm, collar length along the cane. Keep = 2 x ear_disc_r so it prints flat.
collar_wall  = 5;      // mm, radial wall around the bore.
clamp_gap    = 1.0;    // mm, total gap between the halves as printed; tightening closes part of it.
flange_h     = 12;     // mm, clamp flange height each side of the split (Y).
clamp_bolt_z = [-13, 13]; // mm, M4 clamp bolt positions along the cane (two bolts per side).
m4_clear_d   = 4.4;    // mm, M4 clearance hole.
m4_head_d    = 7.6;    // mm, M4 socket-head counterbore diameter (head is 7.0).
m4_head_h    = 4.2;    // mm, counterbore depth (head is 4.0).
m4_insert_d  = 5.6;    // mm, hole for an M4 brass heat-set insert. CHECK your insert's datasheet.
m4_insert_len = 8.5;   // mm, insert hole depth (insert length + 0.4).
cane_angle   = 45;     // deg above horizontal, walking pose (grip 0.85-0.95 m, tip ~1 m ahead). Preview + echo only.

/* [Hinge (Hirth-style rosette, M5 bolt)] */
hinge_angle  = 50;     // deg, phi. 90 - cane_angle + 5 gives the 5-degree-down camera of DESIGN.md s4.
ear_len      = 46;     // mm, cane axis -> hinge axis (Y, collar frame). Checked for clearance at phi 35-80.
ear_t        = 10;     // mm, ear plate thickness (X).
ear_disc_r   = 22;     // mm, ear disc radius around the hinge; the angle scale is engraved in the rim.
arm_disc_r   = 19.5;   // mm, arm disc radius (smaller so the ear's scale stays visible).
teeth        = 72;     // rosette tooth count -> 360/72 = 5 degree detents. Fallback 36 (10 deg) if 72 prints mushy.
tooth_h      = 0.8;    // mm, tooth height (about a 90 degree tooth at the outer radius for 72 teeth).
rosette_r_in = 6;      // mm, inner radius of the toothed ring.
rosette_r_out = 18;    // mm, outer radius of the toothed ring.
m5_clear_d   = 5.5;    // mm, M5 clearance hole.
m5_nut_af    = 8.2;    // mm, M5 nut across flats (8.0) + 0.2.
m5_nut_h     = 4.4;    // mm, M5 nut pocket depth (nut is 4.0).
m5_head_af   = 8.1;    // mm, M5 hex bolt head across flats (8.0) + 0.1, press fit in the knob.
m5_head_h    = 3.7;    // mm, M5 hex head height (3.5) + 0.2.
knob_d       = 28;     // mm, knob diameter.
knob_h       = 10;     // mm, knob height.

/* [Arm (joins the hinge to the cradle's back plate)] */
arm_t        = 8;      // mm, arm fin thickness (X).
arm_off      = 30;     // mm, back glass -> hinge axis, measured behind the phone (phone Z).
hinge_below  = 14;     // mm, hinge axis below the phone's bottom edge (phone Y).
arm_root     = [8, 48];   // mm, phone-Y span where the fin's edge sits in the back plate pocket.
arm_screw_y  = [16, 40];  // mm, phone-Y of the two M3 screws that hold the fin to the back plate.
root_pocket  = 0.6;    // mm, depth of the locating pocket in the back plate for the fin edge.
m3_clear_d   = 3.4;    // mm, M3 clearance hole.
m3_csk_d     = 6.6;    // mm, M3 90-degree countersink diameter (flat head is 6.0).
m3_insert_d  = 4.0;    // mm, hole for an M3 brass heat-set insert (short, 5.7 mm). CHECK datasheet.
m3_insert_len = 6.0;   // mm, M3 insert hole depth.
m3_nut_af    = 5.6;    // mm, M3 nut across flats (5.5) + 0.1.
m3_nut_h     = 2.6;    // mm, M3 nut pocket depth (nut is 2.4).

/* [Phone: iPhone 17 Pro Max] */
phone_w      = 78.0;   // mm, Apple tech specs (drawing: 77.98).
phone_h      = 163.4;  // mm, Apple tech specs (drawing: 163.43).
phone_d      = 8.75;   // mm, Apple tech specs; excludes the camera plateau.
phone_r      = 11.7;   // mm, plan-view corner radius. MEASURE (drawing sheet 4 shows R11.70-R11.96 zones).
plateau_h    = 49;     // mm, camera plateau height from the top edge. MEASURE (scaled 47-49 off the drawing).
plateau_clear = 2;     // mm, gap between the plateau's lower edge and the back plate.
plateau_proud = 2.55;  // mm, back glass -> plateau surface (Apple drawing).
cam_proud    = 4.43;   // mm, back glass -> rear lens glass (2.55 + 1.88, Apple drawing).
// Rear sensors, measured from the TOP edge and from the phone's RIGHT edge (screen view) - Apple
// drawing detail D. The wide (Main) camera is "rear camera 2"; ARKit and the LiDAR depth use it.
cam_wide_from_top   = 33.61;
cam_wide_from_right = 14.37;
lidar_from_top      = 34.16;
lidar_from_right    = 64.18;

/* [Cradle] */
clear        = 0.3;    // mm, gap phone <-> cradle on every side. Retune from the corner coupons.
back_t       = 3.2;    // mm, back plate thickness.
wall_t       = 2.4;    // mm, side wall thickness (6 perimeters of 0.4).
lip_w        = 1.2;    // mm, how far the front lip reaches over the screen edge. Must stay < 2.56 (display border).
lip_t        = 1.6;    // mm, lip thickness (printed as 3 steps = a support-free chamfer).
cup_len      = 13;     // mm, bottom corner cups reach this far in from each side edge.
cap_len      = 20;     // mm, the top cap covers the top cap_len of the phone.
cap_corner   = 12;     // mm, front lip length at each top corner (keeps off front camera + sensors).
top_port_w   = 32.85;  // mm, receiver / front-mic keepout on the top edge (28.85 + 2 x 2).
tab_w        = 9;      // mm, cap screw tab width beyond the side wall (X).
tab_len      = 6;      // mm, cap screw tab length (Y).
vent         = true;   // open windows in the back plate so the phone's back can shed heat.
visor_depth  = 0;      // mm, optional rain/sun brim behind the top edge; <= 15 stays outside the wide + LiDAR cones.
// Button windows, measured from the TOP edge (Apple drawing): LEFT side (screen view) has the
// Action button 30.83-37.73, Volume up 42.83-54.03, Volume down 57.03-68.23; RIGHT side has the
// side button 46.68-64.38 and Camera Control 103.27-120.37 (Apple keepout 25 mm long).
left_windows  = [[28, 71]];
right_windows = [[44, 67], [97, 127]];
// Bottom opening between the corner cups (USB-C plug, 5 speaker holes, 2 mics stay open).
floor_gap_w  = phone_w - 2 * cup_len;   // 52 mm; a USB-C plug overmold needs >= 16.

$fa = 2;
$fs = 0.4;

// ------------------------------------------------------------------ derived values
bore_d   = pole_d + bore_clear;
bore_r   = bore_d / 2;
collar_r = bore_r + collar_wall;
bolt_x   = bore_r + 2.5 + m4_clear_d / 2;   // 2.5 mm of plastic between bore and bolt hole
boss_d   = m4_head_d + 3;                   // clamp boss diameter (1.5 mm wall around the head)
arm_x0   = ear_t / 2 + tooth_h;             // arm fin inner face (X) when the teeth are meshed
z_back   = -(clear + back_t);               // back face of the back plate (phone Z)
plate_top = phone_h - plateau_h - plateau_clear;  // back plate stops here (phone Y)
split_y  = phone_h - cap_len;               // cradle | cap boundary (phone Y)
tab_x    = phone_w / 2 + clear + wall_t;    // outer face of a side wall (phone X)
step_deg = 360 / teeth;
cam_wide = [phone_w / 2 - cam_wide_from_right, phone_h - cam_wide_from_top];
lidar    = [phone_w / 2 - lidar_from_right, phone_h - lidar_from_top];
// Back plate ventilation windows [x, y, width, height] in the phone frame, clear of the arm root.
vent_rects = [[-31, 10, 18, 40], [-31, 58, 18, 46], [17, 10, 14, 26], [17, 58, 14, 46]];

echo(str("CaneKit mount: camera pitch = ", hinge_angle + cane_angle - 90,
         " deg below horizontal (target 5, keep 3..8; DESIGN.md s4)"));
echo(str("bore = ", bore_d, " mm, hinge detent = ", step_deg, " deg, collar-to-hinge = ", ear_len, " mm"));

// Checks that protect the geometry decisions in DESIGN.md. They stop the render with a message.
assert(lip_w < 2.56, "lip_w would cover the active display (Apple: 2.56 mm border)");
assert(ear_len - ear_disc_r - collar_r >= 2, "ear disc hits the collar: raise ear_len");
assert(arm_off - clear - back_t - ear_disc_r >= 2, "ear disc hits the back plate: raise arm_off");
assert(hinge_angle >= 35 && hinge_angle <= 80, "hinge_angle outside the clearance-checked 35..80 range");
assert(rosette_r_out < arm_disc_r - 1, "rosette teeth must sit inside the arm disc");
assert(floor_gap_w >= 16, "floor gap too narrow for a USB-C plug");
assert(abs(collar_len - 2 * ear_disc_r) < 0.01, "collar_len must equal 2 x ear_disc_r so collar_a prints flat");

// ------------------------------------------------------------------ small helpers

// Convex hull of a list of 3D points (tiny cubes stand in for points; winding-proof).
module hull_points(pts) {
    hull() for (p = pts) translate(p) cube(0.01, center = true);
}

// 2D rounded rectangle with its lower-left corner at the origin.
module rounded_square(size, r) {
    translate([r, r]) offset(r = r) square([size[0] - 2 * r, size[1] - 2 * r]);
}

// The phone's plan outline (phone frame: X centred, Y from 0 at the bottom edge), grown by `grow`
// mm (negative shrinks).
module phone_outline(grow = 0) {
    offset(r = grow)
        translate([-phone_w / 2 + phone_r, phone_r])
            offset(r = phone_r) square([phone_w - 2 * phone_r, phone_h - 2 * phone_r]);
}

// Hirth-style face rosette in its own frame: axis +Z, base plane z = 0, `n` radial V-teeth up to
// z = h between radii r0 and r1. Two identical rosettes mesh face to face when one is turned half
// a tooth; `phase` (deg) rotates the teeth about the axis. Teeth dip 0.3 mm below z = 0 so they
// fuse with the plate they sit on.
module rosette(n = teeth, h = tooth_h, r0 = rosette_r_in, r1 = rosette_r_out, phase = 0) {
    a = 360 / n;
    for (i = [0 : n - 1])
        rotate([0, 0, i * a + phase])
            hull_points([
                [r0 * cos(-a / 2), r0 * sin(-a / 2), 0], [r0 * cos(a / 2), r0 * sin(a / 2), 0], [r0, 0, h],
                [r1 * cos(-a / 2), r1 * sin(-a / 2), 0], [r1 * cos(a / 2), r1 * sin(a / 2), 0], [r1, 0, h],
                [r0 * cos(-a / 2), r0 * sin(-a / 2), -0.3], [r0 * cos(a / 2), r0 * sin(a / 2), -0.3],
                [r1 * cos(-a / 2), r1 * sin(-a / 2), -0.3], [r1 * cos(a / 2), r1 * sin(a / 2), -0.3]
            ]);
}

// ------------------------------------------------------------------ collar (COLLAR frame)

// Outer solid of both halves: the collar tube hulled with four clamp bosses (bolts along Y).
module collar_hull() {
    hull() {
        cylinder(r = collar_r, h = collar_len, center = true);
        for (s = [-1, 1], z = clamp_bolt_z)
            translate([s * bolt_x, 0, z]) rotate([90, 0, 0])
                cylinder(d = boss_d, h = 2 * flange_h, center = true);
    }
}

// The bore for the cane.
module collar_bore() {
    cylinder(d = bore_d, h = collar_len + 2, center = true);
}

// M4 clearance holes through both halves (along Y).
module clamp_holes() {
    for (s = [-1, 1], z = clamp_bolt_z)
        translate([s * bolt_x, 0, z]) rotate([90, 0, 0])
            cylinder(d = m4_clear_d, h = 2 * collar_r + 2, center = true);
}

// 2D profile of the ear in the collar's YZ plane (2D x = collar Y, 2D y = collar Z): a disc
// around the hinge hulled onto the collar. Its lower edge is flat at Z = -collar_len/2.
module ear_2d() {
    hull() {
        translate([ear_len, 0]) circle(r = ear_disc_r);
        translate([0, -collar_len / 2]) square([collar_r - 1, collar_len]);
    }
}

// Ear plate (X from -ear_t/2 to +ear_t/2) with the collar-side rosette on its +X face.
module ear() {
    intersection() {
        translate([-ear_t / 2, 0, 0]) rotate([90, 0, 90]) linear_extrude(height = ear_t) ear_2d();
        cube([200, 400, collar_len], center = true);   // never below/above the collar's end faces
    }
    // rotate([0, 90, 0]) turns the rosette's +Z into +X: teeth point at the arm.
    translate([ear_t / 2 - 0.01, ear_len, 0]) rotate([0, 90, 0]) rosette(phase = 0);
}

// Angle scale engraved in the ear's +X face just outside the arm disc. The arm's pointer notch
// faces the phone's -Y (down the phone); in the collar frame that direction sits at
// (270 - phi) degrees from +Y toward +Z, so the tick for phi is drawn there.
// Long ticks every 10 degrees, short every 5, and an extra-long tick at the design hinge_angle.
module ear_ticks() {
    for (phi = [35 : 5 : 80])
        translate([ear_t / 2 - 0.6, ear_len, 0])
            rotate([270 - phi, 0, 0])
                translate([0, arm_disc_r + 0.7, -0.35])
                    cube([1, (phi % 10 == 0 ? 2.2 : 1.2) + (phi == hinge_angle ? 1.0 : 0), 0.7]);
}

// Upper clamp half: counterbored M4 bolt heads, the ear, the M5 hinge hole with a hex nut pocket
// on the ear's -X face, the angle scale, and a zip-tie slot for the USB-C cable.
module collar_a() {
    intersection() {
        difference() {
            union() {
                collar_hull();
                ear();
            }
            collar_bore();
            clamp_holes();
            for (s = [-1, 1], z = clamp_bolt_z)
                translate([s * bolt_x, flange_h - m4_head_h, z]) rotate([-90, 0, 0])
                    cylinder(d = m4_head_d, h = m4_head_h + 10);
            translate([0, ear_len, 0]) rotate([0, 90, 0])
                cylinder(d = m5_clear_d, h = 3 * ear_t, center = true);
            // Hex pocket: rotate([0,90,0]) puts a hex vertex at +/-Z, so the pocket prints
            // without support when collar_a stands on its end face.
            translate([-ear_t / 2 - 0.01, ear_len, 0]) rotate([0, 90, 0])
                cylinder(d = m5_nut_af / cos(30), h = m5_nut_h + 0.01, $fn = 6);
            ear_ticks();
            translate([-ear_t / 2 - 1, collar_r + 6, -2.1]) cube([ear_t + 2, 2.2, 4.2]);
        }
        translate([-100, clamp_gap / 2, -100]) cube([200, 200, 200]);   // keep Y >= +gap/2
    }
}

// Lower clamp half: M4 heat-set inserts pressed in from the split face.
module collar_b() {
    intersection() {
        difference() {
            collar_hull();
            collar_bore();
            clamp_holes();
            for (s = [-1, 1], z = clamp_bolt_z)
                translate([s * bolt_x, -clamp_gap / 2 + 0.01, z]) rotate([90, 0, 0])
                    cylinder(d = m4_insert_d, h = m4_insert_len);
        }
        translate([-100, -200 - clamp_gap / 2, -100]) cube([200, 200, 200]);   // keep Y <= -gap/2
    }
}

// ------------------------------------------------------------------ arm (PHONE frame)

// 2D profile of the arm fin in the phone's YZ plane (2D x = phone Y, 2D y = phone Z): the hinge
// disc hulled onto the root that sits in the back plate pocket.
module arm_2d() {
    hull() {
        translate([-hinge_below, -arm_off]) circle(r = arm_disc_r);
        translate([arm_root[0], z_back - 2]) square([arm_root[1] - arm_root[0], 2 + root_pocket]);
    }
}

// Arm fin (X from arm_x0 to arm_x0 + arm_t) with the cradle-side rosette on its -X face. The half
// tooth phase makes the teeth mesh at hinge angles that are multiples of step_deg.
module arm() {
    difference() {
        union() {
            translate([arm_x0, 0, 0]) rotate([90, 0, 90]) linear_extrude(height = arm_t) arm_2d();
            // rotate([0, -90, 0]) turns the rosette's +Z into -X: teeth point at the ear.
            translate([arm_x0 + 0.01, -hinge_below, -arm_off]) rotate([0, -90, 0])
                rosette(phase = step_deg / 2);
        }
        translate([0, -hinge_below, -arm_off]) rotate([0, 90, 0])
            cylinder(d = m5_clear_d, h = 100, center = true);
        // M3 heat-set inserts in the root edge; screws come through the back plate from the phone side.
        for (y = arm_screw_y)
            translate([arm_x0 + arm_t / 2, y, z_back + root_pocket + 0.01]) rotate([180, 0, 0])
                cylinder(d = m3_insert_d, h = m3_insert_len);
        // Pointer notch on the disc rim, facing the phone's -Y; read it against the ear's ticks.
        translate([arm_x0 - 1, -hinge_below - arm_disc_r - 1, -arm_off - 0.6])
            cube([arm_t + 2, 2.2, 1.2]);
        // Zip-tie slot for the USB-C cable.
        translate([arm_x0 - 1, 2, -18]) cube([arm_t + 2, 2.5, 4.5]);
    }
}

// ------------------------------------------------------------------ cradle + cap (PHONE frame)

// Side walls: a ring around the phone outline from the back plate's back face to the screen plane.
module side_walls() {
    translate([0, 0, z_back]) linear_extrude(height = phone_d + clear - z_back + 0.01)
        difference() {
            phone_outline(clear + wall_t);
            phone_outline(clear);
        }
}

// Front lips over the screen edge, in three steps so the underside is a printable chamfer.
module front_lips() {
    for (k = [0 : 2])
        translate([0, 0, phone_d + clear + k * lip_t / 3])
            linear_extrude(height = lip_t / 3 + 0.01)
                difference() {
                    phone_outline(clear + wall_t);
                    phone_outline(clear - (lip_w + clear) * (k + 1) / 3);
                }
}

// M3 countersink from the phone side, head 0.3 mm below the plate face (no metal touches the phone).
module csk_m3() {
    translate([0, 0, z_back - 1]) cylinder(d = m3_clear_d, h = back_t + 2);
    translate([0, 0, -clear - 0.3 - (m3_csk_d - m3_clear_d) / 2])
        cylinder(d1 = m3_clear_d, d2 = m3_csk_d, h = (m3_csk_d - m3_clear_d) / 2 + 0.01);
    translate([0, 0, -clear - 0.3]) cylinder(d = m3_csk_d, h = 1);
}

// Back plate: the phone outline grown to the wall, from the bottom up to just below the camera
// plateau, with vent windows, the arm's locating pocket and its two countersunk screw holes.
module back_plate() {
    difference() {
        intersection() {
            translate([0, 0, z_back]) linear_extrude(height = back_t) phone_outline(clear + wall_t);
            translate([-100, -50, -50]) cube([200, plate_top + 50, 100]);
        }
        if (vent)
            for (r = vent_rects)
                translate([r[0], r[1], z_back - 1]) linear_extrude(height = back_t + 2)
                    rounded_square([r[2], r[3]], 3);
        translate([arm_x0 - 0.2, arm_root[0] - 0.2, z_back - 0.01])
            cube([arm_t + 0.4, arm_root[1] - arm_root[0] + 0.4, root_pocket + 0.01]);
        for (y = arm_screw_y) translate([arm_x0 + arm_t / 2, y, 0]) csk_m3();
    }
}

// Screw tabs outside both side walls, Y from y0 to y0 + tab_len. The cradle's tabs carry an M3
// nut pocket on their lower face; the cap's tabs sit on top; one M3 x 14 per side joins them.
module screw_tabs(y0, with_nut) {
    for (s = [-1, 1])
        difference() {
            translate([s > 0 ? tab_x - 0.01 : -tab_x - tab_w + 0.01, y0, z_back])
                cube([tab_w, tab_len, phone_d + clear - z_back]);
            translate([s * (tab_x + tab_w / 2), y0 - 1, (z_back + phone_d + clear) / 2])
                rotate([-90, 0, 0]) cylinder(d = m3_clear_d, h = tab_len + 2);
            if (with_nut)
                translate([s * (tab_x + tab_w / 2), y0 - 0.01, (z_back + phone_d + clear) / 2])
                    rotate([-90, 0, 0]) rotate([0, 0, 30])   // vertex up: prints without support
                        cylinder(d = m3_nut_af / cos(30), h = m3_nut_h + 0.01, $fn = 6);
        }
}

// Windows so the buttons stay pressable. The cut starts at the back glass plane, so a thin sill
// of wall remains behind the phone and keeps each rail in one piece.
module button_windows() {
    for (w = left_windows)
        translate([-phone_w / 2 - 30, phone_h - w[1], -clear]) cube([33, w[1] - w[0], 30]);
    for (w = right_windows)
        translate([phone_w / 2 - 3, phone_h - w[1], -clear]) cube([33, w[1] - w[0], 30]);
}

// Open bottom between the corner cups (USB-C plug, speakers, mics).
module floor_gap() {
    translate([-floor_gap_w / 2, -20, -50]) cube([floor_gap_w, 20, 100]);
}

// Cradle: the phone slides in from the top between the rails (the lips act as a channel) and
// sits in the two bottom corner cups; the cap then locks it in.
module cradle() {
    difference() {
        union() {
            back_plate();
            intersection() {
                union() {
                    side_walls();
                    front_lips();
                }
                translate([-100, -50, -50]) cube([200, split_y - 0.2 + 50, 100]);
            }
            screw_tabs(split_y - 0.2 - tab_len, true);
        }
        button_windows();
        floor_gap();
    }
}

// Top cap: side walls + top bridge + corner lips above split_y. Nothing reaches behind the back
// glass further than z_back (in front of the lens and flash planes, so outside every rear
// keepout cone); the front lip exists only at the two top corners.
module cap() {
    difference() {
        union() {
            intersection() {
                union() {
                    side_walls();
                    front_lips();
                }
                translate([-100, split_y + 0.2, -50]) cube([200, 100, 100]);
            }
            screw_tabs(split_y + 0.2, false);
            if (visor_depth > 0)
                translate([-phone_w / 2, phone_h + clear, z_back - visor_depth])
                    cube([phone_w, wall_t, visor_depth + 0.01]);
        }
        translate([-(phone_w / 2 - cap_corner), split_y, phone_d + clear - 0.01])
            cube([phone_w - 2 * cap_corner, 40, 10]);
        translate([-top_port_w / 2, phone_h, phone_d - 3]) cube([top_port_w, 10, 10]);
    }
}

// ------------------------------------------------------------------ knob

// Scalloped knob; an M5 x 30 hex bolt presses head-first into the hex pocket (add a drop of CA).
module knob() {
    difference() {
        cylinder(d = knob_d, h = knob_h);
        for (i = [0 : 5])
            rotate([0, 0, i * 60]) translate([knob_d / 2 + 1.5, 0, -1]) cylinder(d = 8, h = knob_h + 2);
        translate([0, 0, -1]) cylinder(d = m5_clear_d, h = knob_h + 2);
        translate([0, 0, knob_h - m5_head_h]) cylinder(d = m5_head_af / cos(30), h = m5_head_h + 1, $fn = 6);
    }
}

// ------------------------------------------------------------------ assembly preview

// Transparent phone with its camera plateau and the wide camera's optical axis (the thin line
// shows where ARKit looks).
module phone_ghost() {
    %union() {
        linear_extrude(height = phone_d) phone_outline(0);
        translate([0, 0, -plateau_proud]) linear_extrude(height = plateau_proud + 0.01)
            intersection() {
                phone_outline(-1.5);
                translate([-50, phone_h - plateau_h]) square([100, plateau_h]);
            }
        translate([cam_wide[0], cam_wide[1], -cam_proud]) rotate([180, 0, 0]) cylinder(d = 1, h = 600);
        translate([lidar[0], lidar[1], -plateau_proud]) rotate([180, 0, 0]) cylinder(d = 6.65, h = 1);
    }
}

// Everything in the collar frame; the phone-frame parts are moved so the hinge axis lands on the
// ear (translate), turned by (90 - hinge_angle) about X, and pushed out to the ear tip.
module assembly() {
    rotate([world_view ? 90 - cane_angle : 0, 0, 0]) {
        color("SteelBlue") collar_a();
        color("SteelBlue") collar_b();
        %cylinder(d = pole_d, h = 700, center = true);   // the cane
        translate([0, ear_len, 0]) rotate([90 - hinge_angle, 0, 0]) translate([0, hinge_below, arm_off]) {
            color("Orange") cradle();
            color("Orange") cap();
            color("Gold") arm();
            color("DimGray") translate([arm_x0 + arm_t, -hinge_below, -arm_off]) rotate([0, 90, 0]) knob();
            phone_ghost();
        }
    }
}

// ------------------------------------------------------------------ dispatch (print orientations)

if (part == "assembly") {
    assembly();
} else if (part == "collar_a") {
    translate([0, 0, collar_len / 2]) collar_a();                  // stands on its end face
} else if (part == "collar_b") {
    translate([0, 0, collar_len / 2]) collar_b();                  // stands on its end face
} else if (part == "arm") {
    translate([0, 0, arm_x0 + arm_t]) rotate([0, 90, 0]) arm();    // +X face down, teeth up
} else if (part == "cradle") {
    translate([0, 0, -z_back]) cradle();                           // back plate down
} else if (part == "cap") {
    translate([0, 0, -z_back]) cap();                              // back side down
} else if (part == "knob") {
    knob();
} else {
    echo(str("Unknown part: ", part));
}
