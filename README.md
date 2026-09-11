# OpenCane (54FoundersHack) — retrofit smart-cane kit

Clip three parts onto any white cane. The iPhone (LiDAR + ARKit) is the brain; an ESP32 grip module buzzes left/right/above.

- `docs/ideas.md` — the plan: verdict, pushbacks, form factor, buy list, software architecture, ISR→CIF demo, brainstorm, pitch.
- `ios/` — SwiftUI starter (ARKit depth lanes, gyro sweep gate, CoreBluetooth to the grip, haptics, speech, Gemini scene read). Uncompiled.
- `firmware/` — XIAO ESP32-S3 Arduino/PlatformIO firmware (NimBLE UART "CANE", motor PWM, ToF fail-safe). Uncompiled.
- `cad/` — OpenSCAD drafts: grip module, chest plate, sensor pod. Unrendered.

Owners: Aritro = software. Sagar = 3D printing + cane hardware.
