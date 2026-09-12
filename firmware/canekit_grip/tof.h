/*
 * tof.h — optional VL53L1X ground-distance sensor (Pololu vl53l1x-arduino library).
 * Set HAS_TOF to 0 (here, or -DHAS_TOF=0 in platformio.ini) to compile it out entirely;
 * the stubs then report "no sensor" and the main sketch never enters local mode.
 *
 * Stretch / history only (see the canekit_grip.ino header): the phone-only app has no ToF sensor.
 * Caller: canekit_grip.ino (setup: tofBegin; loop: tofUpdate, tofDistanceMm; tofPresent gates
 * local mode). Not thread-safe; call from loop() only. Tests: none (README bench test).
 * Distances are millimetres from the sensor face; -1 always means "no usable reading".
 */
#pragma once
#include <Arduino.h>

// Default on; platformio.ini passes -DHAS_TOF=1 explicitly. With 1 and no sensor wired, tofBegin
// fails at boot and every call below reports absent, so HAS_TOF 0 only saves the driver's flash.
#ifndef HAS_TOF
#define HAS_TOF 1
#endif

bool tofBegin(int sdaPin, int sclPin);  // true if a VL53L1X answered on I2C
bool tofPresent();                       // sensor was found at boot
void tofUpdate();                        // poll (non-blocking); call every loop()
int  tofDistanceMm();                    // last valid range in mm, or -1 (absent/invalid/stale)
