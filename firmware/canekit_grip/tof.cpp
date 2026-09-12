/*
 * tof.cpp — VL53L1X in short-distance mode, 50 ms timing budget, continuous ranging.
 *
 * Implements tof.h (see there for callers and units). Uses the Pololu VL53L1X library over the
 * Arduino Wire bus at 400 kHz, sensor address 0x29. Stretch / history only; no automated tests.
 */
#include "tof.h"

#if HAS_TOF
#include <Wire.h>
#include <VL53L1X.h>

// Driver instance; valid only when `present`.
static VL53L1X  sensor;
// Set once by tofBegin(): the sensor ACKed and was configured.
static bool     present  = false;
// Last RangeValid distance in mm (kept through invalid samples; staleness is judged by lastOkMs).
static int      lastMm   = -1;
// millis() of that reading.
static uint32_t lastOkMs = 0;

// Start I2C on the given GPIOs and configure continuous ranging. Returns false (and the sketch runs
// without ToF) when no sensor answers within the 100 ms I2C timeout.
bool tofBegin(int sdaPin, int sclPin) {
  Wire.begin(sdaPin, sclPin);
  Wire.setClock(400000);
  sensor.setTimeout(100);
  if (!sensor.init()) { present = false; return false; }   // no ACK at 0x29 -> run without ToF
  sensor.setDistanceMode(VL53L1X::Short);                   // best ambient immunity, ~1.3 m max
  sensor.setMeasurementTimingBudget(50000);                 // 50 ms
  sensor.startContinuous(50);                               // one sample every 50 ms
  present = true;
  return true;
}

// Whether tofBegin() found the sensor; never changes after boot (a sensor unplugged later is
// reported through tofDistanceMm() going stale, not here).
bool tofPresent() { return present; }

// Non-blocking poll: take a sample only when one is ready; keep it only if RangeValid.
void tofUpdate() {
  if (!present || !sensor.dataReady()) return;
  sensor.read(false);                                       // data is ready: non-blocking read
  if (sensor.ranging_data.range_status == VL53L1X::RangeValid) {
    lastMm = sensor.ranging_data.range_mm;
    lastOkMs = millis();
  }
}

// Latest valid distance in mm, or -1 when absent or when no valid sample for 500 ms. Note that
// before the first valid sample lastMm is -1, so the result is -1 as well.
int tofDistanceMm() {
  if (!present || millis() - lastOkMs > 500) return -1;     // stale (>10 missed samples)
  return lastMm;
}

#else  // ---- HAS_TOF == 0: stubs ----
bool tofBegin(int, int) { return false; }
bool tofPresent()       { return false; }
void tofUpdate()        {}
int  tofDistanceMm()    { return -1; }
#endif
