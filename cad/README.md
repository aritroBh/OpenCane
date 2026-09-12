# Cane printable drafts (OpenSCAD), legacy ESP32 era

**Legacy, do not print for the demo.** These drafts are from the ESP32 plan (XIAO grip module,
VL53L1X sensor pod, coin motors), which the phone-only CaneKit app replaced. They also assume a
12.7 mm aluminum/graphite shaft; the prototype stick is **27.65 mm, non-metal** (a broom handle,
measured by the bore rings on 2026-09-12; the earlier 28.75 mm reading was wrong), so none of the
clamps below fit it. The phone-to-cane mount now lives in [`hardware/`](../hardware/README.md): the
live design is [`hardware/mount_screwless/`](../hardware/mount_screwless/) (print files in
[`hardware/3d_print_files/`](../hardware/3d_print_files/)); [`hardware/mount/`](../hardware/mount/)
is the screwed alternative. The firmware these housings were for is [`firmware/`](../firmware/README.md),
also stretch only. No script renders these files (`scripts/build_stl.ps1` covers `hardware/` only).

All three files are UNRENDERED drafts written without a running OpenSCAD.
Open each, press F5, and check pockets against the real parts before exporting STL.

- grip_module.scad — split grip sleeve: XIAO ESP32-S3 bay, 500mAh LiPo bay, 2x 10mm coin motor pockets, M3 join, wire channels.
- chest_plate.scad — lanyard/chest plate with GoPro-style 3-prong mount. Hedge if phone-on-cane blur is a problem.
- sensor_pod.scad — hooded tube clamp for VL53L1X, aims 35° down the shaft.

External parts to grab as-is (sized for the old 12.7 mm shaft):
- Phone clamp (GoPro-compatible): https://www.printables.com/model/145012
- Pole grip, set poleDiameter=12.7 (the prototype stick would need 27.65): https://github.com/j-h-a/go-pro-mounts
- Parametric tube clamp: https://www.printables.com/model/1214545-print-in-place-tube-clamp-fully-parametric

Key dimensions used: shaft 12.7 mm (Ambutech aluminum/graphite; not the demo stick, which is 27.65 mm non-metal), VL53L1X breakout 25.5x17.5x4.6, LiPo 36x29x4.75, XIAO ESP32-S3 21x17.5.
