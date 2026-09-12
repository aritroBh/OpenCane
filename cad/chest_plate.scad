// chest_plate.scad — flat chest/lanyard plate with a GoPro-style 3-prong mount
// so the jackw01 phone clamp (2-prong male) snaps on. Hedge against motion blur on the cane.
// DRAFT: unrendered. Check prong spacing against your printed phone clamp before relying on it.
// Print: flat, PETG, no supports.

$fn = 48;
plate_w = 70; plate_h = 90; plate_t = 4; corner_r = 8;
slot_w = 26; slot_h = 4;      // 25 mm webbing
prong_t = 3; prong_gap = 3.5; prong_h = 14; prong_r = 7.5; bolt_d = 5.3;
prongs = 3;                   // 3 = base (female) mates with 2-prong accessories

module plate() {
    hull() for (x = [-1,1], y = [-1,1])
        translate([x*(plate_w/2 - corner_r), y*(plate_h/2 - corner_r), 0]) cylinder(r = corner_r, h = plate_t);
}
module slots() {
    for (y = [-1, 1]) for (x = [-1, 1])
        translate([x*(plate_w/2 - 12) - slot_h/2, y*(plate_h/2 - 14) - slot_w/2, -1])
            cube([slot_h, slot_w, plate_t + 2]);
}
module prong_set() {
    total = prongs*prong_t + (prongs-1)*prong_gap;
    difference() {
        union() for (i = [0:prongs-1])
            translate([-total/2 + i*(prong_t + prong_gap), 0, plate_t - 0.01])
                hull() {
                    translate([0, -prong_r, 0]) cube([prong_t, 2*prong_r, 0.01]);
                    translate([0, 0, prong_h]) rotate([0, 90, 0]) cylinder(r = prong_r, h = prong_t);
                }
        translate([-total/2 - 1, 0, plate_t + prong_h]) rotate([0, 90, 0]) cylinder(d = bolt_d, h = total + 2);
    }
}
difference() { plate(); slots(); }
prong_set();
