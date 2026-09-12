// =====================================================================
// verify.scad - interference and kinematics harness for the screwless mount
// =====================================================================
// Every check renders the OVERLAP between two things, and the harness
// runner (scripts/verify_mount.ps1) says whether that overlap is supposed
// to be empty or not. An empty result is an STL that OpenSCAD does not
// write. A non-empty one is the clash itself, so you can open it and see
// where it is.
//
// Why this exists: the assembly preview draws every part in a colour and
// overlaps look like nothing at all. On 2026-09-12 it was hiding 6.9 cm3
// of arm inside the phone, a top latch drawn straight through the phone,
// and a ring whose thread crests hit the collar's cone 3.8 mm from home.
// Render the overlap and there is nowhere for that to hide.
//
//   openscad -o out.stl -D check=\"phone_cradle\" verify.scad
//   -D pole_d=28.75, -D delta=6 etc. override the model's numbers as usual.
//
// Runs in the model's own assembly frame with world_view off: +Z up the
// cane, +X out to the phone, the collar's base at z = 0.
include <screwless_mount.scad>

part       = "none";   // silence the model's own dispatch
world_view = false;
check      = "phone_cradle";
test_cane  = 28.75;    // cane_fit: a cane of this diameter vs the collar bore
delta      = 0;        // ring_at_*: the ring lifted this far above fully down
rot_sign   = 1;        // ring_at_*: +1 turns it the way the helix runs (verified)
shift      = 0;        // ring_shift_thread: pure axial shift, no turn
lift       = 1;        // arm_lift_ring: the arm lifted this far in its socket

// Apple drawing (hardware/mount/DESIGN.md): plateau 2.55 proud, lens glass
// 4.43 proud. Wide camera 33.61 from top / 14.37 from right (screen view),
// dia 16.20. LiDAR 34.16 from top / 64.18 from right, dia 6.65.
plateau_proud = 2.55;
cam_proud     = 4.43;

// ------------------------------------------------ phone ghost (cradle frame)
module phone_body()   { translate([0, phone_h / 2, 0]) phone_block(0, phone_d); }
module phone_plateau() {
    intersection() {
        translate([0, phone_h / 2, -plateau_proud]) phone_block(0, plateau_proud);
        translate([-100, phone_h - plateau_h, -10]) cube([200, plateau_h + 1, 20]);
    }
}
module phone_lenses() {
    translate([phone_w / 2 - 14.37, phone_h - 33.61, -cam_proud]) cylinder(h = cam_proud, d = 16.20);
    translate([phone_w / 2 - 64.18, phone_h - 34.16, -cam_proud]) cylinder(h = cam_proud, d = 6.65);
}
module phone_full() { phone_body(); phone_plateau(); phone_lenses(); }

// ------------------------------------------------ placements = assembly()
module P_collar() { collar(); }
module P_ring()   { translate([0, 0, base_len]) ring(); }
module P_arm()    { translate([pad_x, 0, arm_z]) arm(); }
module at_cradle() {
    translate([pad_x, 0, arm_z]) far_frame()
        translate([-(back_t + dt_depth), 0, -sock_y]) rotate([90, 0, -90])
            children();
}
module P_cradle() { at_cradle() cradle(); }
module P_phone()  { at_cradle() phone_full(); }
module P_cane(d = pole_d) { translate([0, 0, -90]) cylinder(h = 260, r = d / 2); }
module slab(z0, z1) { translate([-200, -200, z0]) cube([400, 400, z1 - z0]); }
module ring_at() {
    translate([0, 0, base_len + delta])
        rotate([0, 0, rot_sign * delta * 360 / thr_pitch]) ring();
}

// ------------------------------------------------ checks
// --- must be EMPTY
if (check == "phone_cradle")                 // pocket vs phone body + plateau + lenses
    intersection() { cradle(); phone_full(); }
else if (check == "plateau_cradle")          // camera plateau and lenses vs the cradle
    intersection() { cradle(); union() { phone_plateau(); phone_lenses(); } }
else if (check == "phone_parts")             // phone vs collar + ring + arm
    intersection() { P_phone(); union() { P_collar(); P_ring(); P_arm(); } }
else if (check == "arm_phone")
    intersection() { P_arm(); P_phone(); }
else if (check == "cane_parts")              // the cane vs everything but the collar
    intersection() { P_cane(); union() { P_ring(); P_arm(); P_cradle(); P_phone(); } }
else if (check == "cane_collar")             // the cane vs the collar bore, at pole_d
    intersection() { P_cane(); P_collar(); }
else if (check == "ring_thread")             // ring vs collar over the threaded band, fully down
    intersection() { P_ring(); P_collar(); slab(base_len - 1, base_len + thread_len); }
else if (check == "arm_collar")              // arm tenon vs collar socket (coplanar slivers only)
    intersection() { P_arm(); P_collar(); }
else if (check == "arm_cradle")              // far tenon + pawl vs cradle socket + window
    intersection() { P_arm(); P_cradle(); }
else if (check == "arm_ring")
    intersection() { P_arm(); P_ring(); }
else if (check == "cradle_parts")            // cradle vs collar + ring
    intersection() { P_cradle(); union() { P_collar(); P_ring(); } }
else if (check == "ring_at_thread")          // thread zone with the ring lifted `delta` and turned to match
    intersection() { ring_at(); P_collar(); slab(base_len - 1, base_len + thread_len); }
// --- must NOT be empty
else if (check == "ring_cone")               // the collet squeeze, fully down: this IS the clamp
    intersection() { P_ring(); P_collar(); slab(base_len + thread_len, collar_h + 1); }
else if (check == "cane_fit")                // a test_cane that is too big for the bore
    intersection() { P_cane(test_cane); P_collar(); }
// --- sweeps (the runner sets delta / shift / lift and knows what to expect)
else if (check == "ring_at_cone")            // cone zone vs delta: empty until the last squeeze/taper mm
    intersection() { ring_at(); P_collar(); slab(base_len + thread_len, collar_h + 40); }
else if (check == "ring_shift_thread")       // flank slack: contact only past thr_axial / 2
    intersection() { translate([0, 0, base_len + shift]) ring(); P_collar(); slab(base_len - 1, base_len + thread_len); }
else if (check == "arm_lift_ring")           // the ring as the lock: contact once the arm rises past its gap
    intersection() { translate([0, 0, lift]) P_arm(); P_ring(); }
// --- looks
else if (check == "assembly_plain")
    { P_collar(); P_ring(); P_arm(); P_cradle(); }
else if (check == "show_clash") {            // pink = arm inside phone or cradle
    P_collar(); P_ring(); P_arm(); P_cradle(); %P_phone();
    #intersection() { P_arm(); union() { P_phone(); P_cradle(); } }
}
