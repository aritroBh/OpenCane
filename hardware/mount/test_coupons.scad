// test_coupons.scad - quick prints that tune cane_mount.scad before the long prints.
//
// STATUS: NOT RENDERED (written 2026-09-11 without OpenSCAD installed). Open, F5, fix anything
// it reports, F6, export one STL per `coupon` choice (or "all" as one plate).
// Parameters mirror cane_mount.scad: if you change a value there, change it here too.
// How to read each coupon: hardware/mount/DESIGN.md section 12 (step T0) and hardware/README.md.
//
//   rings     4 bore-fit rings: 28.75 mm -0.2 / +0 / +0.2 / +0.4 (1-4 notches + engraved label).
//             Print them flat (axis vertical) - the same orientation as the collar's bore.
//             Slide each onto the stick (take the tip or handle off). Pick the first ring that
//             slides on with light hand pressure; set bore_clear = that ring's offset + 0.1.
//   corners   bottom-left corner of the cradle at clear = 0.2 / 0.3 / 0.4 mm (engraved on the
//             back plate). Press the phone's corner in: pick the one that holds with no rattle and
//             comes out without a tool; set clear to its value. Also checks phone_r and lip_w.
//   rosettes  two hinge rosette plates: one printed flat (teeth up, like the arm) and one printed
//             standing (teeth vertical, like the collar ear). Bolt them face to face with an M5
//             and try to turn them by hand: they must click in 5-degree steps and not slip.

/* [What to render] */
coupon = "all"; // [all, rings, corners, rosettes]

/* [Mirrored from cane_mount.scad] */
// MEASURED 27.65 by the bore coupons in hardware/mount_screwless/,
// 2026-09-12, and independently by dial caliper on Sep 11. The 28.75
// here was 1.132 in read off the wrong part of a tapered cane; a collar
// bored for it has 1.10 mm of clearance and spins on the shaft. Changed
// 2026-09-12. Do not put 28.75 back without a ring that proves it.
pole_d       = 27.65;  // mm, stick diameter. MEASURED.
phone_w      = 78.0;   // mm
phone_h      = 163.4;  // mm
phone_d      = 8.75;   // mm
phone_r      = 11.7;   // mm, plan-view corner radius (MEASURE)
back_t       = 3.2;    // mm
wall_t       = 2.4;    // mm
lip_w        = 1.2;    // mm
lip_t        = 1.6;    // mm
teeth        = 72;     // rosette teeth (5 degree steps)
tooth_h      = 0.8;    // mm
rosette_r_in = 6;      // mm
rosette_r_out = 18;    // mm
m5_clear_d   = 5.5;    // mm

/* [Coupon settings] */
ring_offsets = [-0.2, 0, 0.2, 0.4];         // mm, added to pole_d
ring_labels  = ["-0.2", "+0", "+0.2", "+0.4"];
ring_wall    = 3;      // mm
ring_h       = 8;      // mm
corner_clears = [0.2, 0.3, 0.4];            // mm, phone <-> cradle gap per coupon
corner_reach = 28;     // mm, how far each corner coupon extends along both edges

$fa = 2;
$fs = 0.4;

// Same outline as cane_mount.scad: phone plan, X centred, Y = 0 at the bottom edge.
module phone_outline(grow = 0) {
    offset(r = grow)
        translate([-phone_w / 2 + phone_r, phone_r])
            offset(r = phone_r) square([phone_w - 2 * phone_r, phone_h - 2 * phone_r]);
}

// Same rosette as cane_mount.scad (axis +Z, teeth from z = 0 up to z = h).
module hull_points(pts) {
    hull() for (p = pts) translate(p) cube(0.01, center = true);
}
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

// One bore ring with a label tab; `idx` + 1 notches on the rim identify it if the text is unreadable.
module bore_ring(idx) {
    d = pole_d + ring_offsets[idx];
    difference() {
        union() {
            cylinder(d = d + 2 * ring_wall, h = ring_h);
            translate([d / 2 + ring_wall - 1, -6, 0]) cube([18, 12, 3]);
        }
        translate([0, 0, -1]) cylinder(d = d, h = ring_h + 2);
        translate([d / 2 + ring_wall + 8, 0, 3 - 0.6])
            linear_extrude(height = 1) text(ring_labels[idx], size = 4, halign = "center", valign = "center");
        for (j = [0 : idx])
            rotate([0, 0, 90 + j * 12]) translate([d / 2 + ring_wall - 0.6, -0.5, ring_h - 1]) cube([2, 1, 2]);
    }
}

// Bottom-left corner of the cradle with phone gap `c`, in print orientation (back plate down).
module corner_coupon(c) {
    zb = -(c + back_t);
    translate([0, 0, -zb])
        difference() {
            intersection() {
                union() {
                    // back plate
                    translate([0, 0, zb]) linear_extrude(height = back_t) phone_outline(c + wall_t);
                    // side wall ring
                    translate([0, 0, zb]) linear_extrude(height = phone_d + c - zb + 0.01)
                        difference() {
                            phone_outline(c + wall_t);
                            phone_outline(c);
                        }
                    // stepped front lip
                    for (k = [0 : 2])
                        translate([0, 0, phone_d + c + k * lip_t / 3])
                            linear_extrude(height = lip_t / 3 + 0.01)
                                difference() {
                                    phone_outline(c + wall_t);
                                    phone_outline(c - (lip_w + c) * (k + 1) / 3);
                                }
                }
                translate([-phone_w / 2 - 10, -10, -20]) cube([10 + corner_reach, 10 + corner_reach, 40]);
            }
            // label engraved into the face the phone rests on
            translate([-phone_w / 2 + 16, 15, -c - 0.4])
                linear_extrude(height = 1) text(str(c), size = 5, halign = "center", valign = "center");
        }
}

// A 44 x 44 x 4 plate with the hinge rosette on top and an M5 hole.
module rosette_plate() {
    difference() {
        union() {
            translate([-22, -22, 0]) cube([44, 44, 4]);
            translate([0, 0, 4 - 0.01]) rosette();
        }
        translate([0, 0, -1]) cylinder(d = m5_clear_d, h = 10);
    }
}

module rings() {
    pos = [[0, 0], [60, 0], [0, 45], [60, 45]];
    for (i = [0 : 3]) translate([pos[i][0], pos[i][1], 0]) bore_ring(i);
}

module corners() {
    for (i = [0 : len(corner_clears) - 1])
        translate([i * 45, 0, 0]) translate([phone_w / 2, 0, 0]) corner_coupon(corner_clears[i]);
}

module rosettes() {
    rosette_plate();                                            // flat: teeth up
    translate([60, 0, 22]) rotate([90, 0, 0]) rosette_plate();  // standing: teeth face -Y
    translate([60 - 22, -12, 0]) cube([44, 20, 2]);             // foot so the standing plate stays put
}

if (coupon == "rings" || coupon == "all") rings();
if (coupon == "corners" || coupon == "all") translate([0, 100, 0]) corners();
if (coupon == "rosettes" || coupon == "all") translate([0, 160, 0]) rosettes();
