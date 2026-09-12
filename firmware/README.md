# CaneKit grip module firmware

> **Stretch / history only — not used by the app.** The ESP32 grip was cut on 2026-09-10 when
> OpenCane went phone-only (`AGENTS.md`: no ESP32, no external sensors). Nothing in the iOS targets
> talks to it; the only client ever written is `ios/stretch/CaneBLE.swift` (in no target), which
> speaks the protocol below. The housings are the legacy drafts in [`cad/`](../cad/README.md).
> Never built in CI, no automated tests; the local fail-safe thresholds were never tuned on a cane.

BLE haptic grip for a smart-cane retrofit: two coin ERM motors driven from a phone over
Nordic UART Service, optional VL53L1X ground-distance sensor, and a local fail-safe
drop-off / step-up alert when no phone is connected.

Files: `canekit_grip.ino` (BLE, motors, parser, telemetry, fail-safe), `tof.h/.cpp`
(VL53L1X, compile out with `HAS_TOF 0`), `platformio.ini`.

## Build — Arduino IDE

1. File > Preferences > Additional boards manager URLs:
   `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
2. Boards Manager: install **esp32 by Espressif Systems** (3.x tested API; 2.x also guarded).
3. Library Manager: install **NimBLE-Arduino** (h2zero, 2.x) and **VL53L1X** (Pololu).
4. Board: **XIAO_ESP32S3** (Tools > Board > ESP32 Arduino). Fallback: **ESP32C3 Dev Module**
   with *USB CDC On Boot: Enabled* for the SuperMini.
5. Open `canekit_grip.ino` (the folder must be named `canekit_grip` for the IDE — rename the
   folder or copy the three source files into `canekit_grip/`), upload, open Serial Monitor @ 115200.

No ToF fitted? Set `#define HAS_TOF 0` in `tof.h` (or `-DHAS_TOF=0` in platformio.ini);
the sketch also runs fine with `HAS_TOF 1` and no sensor — it just reports `D:-1`.

## Build — PlatformIO

```
pio run -e xiao_esp32s3 -t upload
pio device monitor
```
`-e esp32c3_supermini` for the fallback board.

## Wiring

Pin numbers are GPIO numbers. XIAO ESP32-S3 mapping verified against the Seeed wiki
(XIAO ESP32S3 pin multiplexing page): D0=GPIO1, D1=GPIO2, D2=GPIO3, D4=GPIO5 (SDA),
D5=GPIO6 (SCL), user LED = GPIO21 (active low).

| Signal            | XIAO ESP32-S3      | ESP32-C3 SuperMini (unverified) |
|-------------------|--------------------|---------------------------------|
| Left motor drive  | D0 / GPIO1         | GPIO2                           |
| Right motor drive | D1 / GPIO2         | GPIO3                           |
| ToF SDA           | D4 / GPIO5         | GPIO6                           |
| ToF SCL           | D5 / GPIO6         | GPIO7                           |
| Battery sense     | D2 / GPIO3 (opt.)  | GPIO0 (opt.)                    |
| Status LED        | on-board GPIO21    | on-board GPIO8                  |

Motor driver, one per motor (low-side NPN switch, e.g. 2N2222 / BC337 / S8050):

```
3V3 ----+----- motor(+)
        |        motor(-) ----+---- NPN collector
   1N4148 (cathode to 3V3,    |          NPN emitter ---- GND
   anode to motor(-))        0.1uF      NPN base ---- 1k ---- GPIO (D0 / D1)
        |                     |
        +---------------------+
```

- 1N4148 flyback across the motor: cathode (band) to 3V3, anode to the collector side.
- 0.1 uF ceramic directly across the motor terminals (brush noise).
- Coin ERMs pull ~60-90 mA each; the XIAO 3V3 regulator handles two. If you see BLE
  resets when both buzz, add a 100 uF cap on 3V3 or feed the motors from VBAT instead.

VL53L1X: VIN->3V3, GND->GND, SDA->D4, SCL->D5. Pololu carrier has on-board pull-ups.
Mount it pointing at the ground ~40-60 cm ahead of the tip.

Battery (optional): the XIAO ESP32-S3 has no battery ADC by default. Wire BAT+ through
two equal resistors (e.g. 100k/100k) to GND, tap the midpoint to D2, and uncomment
`#define BAT_SENSE_PIN 3` in the sketch. Without it the firmware reports `B:-1`.

## Protocol (NUS, device name `CANE`)

Service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX write `6E400002-...`, TX notify `6E400003-...`.

| Command            | Meaning |
|--------------------|---------|
| `H:{L,R,B}:{1-4}:{ms}` | Buzz left/right/both at intensity 1-4 (40/60/80/100 %) for `ms` (1-10000). Up to 4 commands wait behind the one playing; extra ones are rejected (logged on Serial, nothing sent back over BLE). |
| `P:1`              | Double pulse, both motors |
| `P:2` / `P:3`      | Left / right triple pulse |
| `P:4`              | STOP: flush the queue, then one long buzz on both |
| `S:1` / `S:0`      | Silence on / off. `S:1` flushes the queue and stops the motors; while on, commands are accepted and dropped. ⚠ It persists across a disconnect and also mutes the local fail-safe alerts until `S:0` or a reboot. |

Command letters are case-insensitive; one command per line (LF or CR; 47 characters max, longer
lines are truncated). Anything else is rejected on Serial.

Telemetry, every 100 ms while connected: `D:<mm>,B:<pct>\n` (`-1` = unknown; `B` refreshes once a second).

LED: solid = connected, short blip each second = advertising, fast blink = local
fail-safe mode (no phone for 5 s and ToF present). In local mode both motors buzz when
the ground distance rises > 250 mm above baseline (drop-off: double pulse) or falls below 60 % of it
(step-up: one 400 ms buzz), at most once per 1.5 s. Baseline = median of the last 20 readings
(one per 50 ms, so ~1 s) whenever their spread is <= 40 mm; it keeps its old value while readings
are unsettled, so any surface held steady for ~1 s becomes the new baseline.

## Testing with nRF Connect (Android / iOS)

1. Scan, connect to **CANE**. The board LED goes solid.
2. Expand the Nordic UART Service, tap the down-arrow on the TX characteristic
   (`...0003`) to enable notifications. You should see `D:-1,B:-1` (or a real distance)
   arriving 10x per second — switch the value display to Text/UTF-8.
3. Tap the up-arrow on RX (`...0002`), set the type to **Text**, enter `H:B:4:500` and
   send. Both motors buzz at full for 500 ms. A trailing newline is ideal; without one
   the line is parsed after 150 ms anyway.
4. Try `P:1`, `P:2`, `H:L:2:2000` then `H:R:4:200` (queued), `S:1` then `P:4` (nothing),
   `S:0`. Serial Monitor echoes every line and any rejection.
5. Disconnect and wait 5 s: with a ToF attached the LED starts blinking fast; sweep the
   sensor over a table edge to trigger the drop-off buzz.
