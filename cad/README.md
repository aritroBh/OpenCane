# Cane printable drafts (OpenSCAD)

All three files are UNRENDERED drafts written without a running OpenSCAD.
Open each, press F5, and check pockets against the real parts before exporting STL.

- grip_module.scad — split grip sleeve: XIAO ESP32-S3 bay, 500mAh LiPo bay, 2x 10mm coin motor pockets, M3 join, wire channels.
- chest_plate.scad — lanyard/chest plate with GoPro-style 3-prong mount. Hedge if phone-on-cane blur is a problem.
- sensor_pod.scad — hooded tube clamp for VL53L1X, aims 35° down the shaft.

External parts to grab as-is:
- Phone clamp (GoPro-compatible): https://www.printables.com/model/145012
- Pole grip, set poleDiameter=12.7: https://github.com/j-h-a/go-pro-mounts
- Parametric tube clamp: https://www.printables.com/model/1214545-print-in-place-tube-clamp-fully-parametric

Key dimensions used: shaft 12.7 mm (Ambutech aluminum/graphite), VL53L1X breakout 25.5x17.5x4.6, LiPo 36x29x4.75, XIAO ESP32-S3 21x17.5.
