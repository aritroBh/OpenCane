/*
 * tof.h — optional VL53L1X ground-distance sensor (Pololu vl53l1x-arduino library).
 * Set HAS_TOF to 0 (here, or -DHAS_TOF=0 in platformio.ini) to compile it out entirely;
 * the stubs then report "no sensor" and the main sketch never enters local mode.
 */
#pragma once
#include <Arduino.h>

#ifndef HAS_TOF
#define HAS_TOF 1
#endif

bool tofBegin(int sdaPin, int sclPin);  // true if a VL53L1X answered on I2C
bool tofPresent();                       // sensor was found at boot
void tofUpdate();                        // poll (non-blocking); call every loop()
int  tofDistanceMm();                    // last valid range in mm, or -1 (absent/invalid/stale)
