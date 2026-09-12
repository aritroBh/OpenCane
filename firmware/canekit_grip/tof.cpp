/*
 * tof.cpp — VL53L1X in short-distance mode, 50 ms timing budget, continuous ranging.
 */
#include "tof.h"

#if HAS_TOF
#include <Wire.h>
#include <VL53L1X.h>

static VL53L1X  sensor;
static bool     present  = false;
static int      lastMm   = -1;
static uint32_t lastOkMs = 0;

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

bool tofPresent() { return present; }

void tofUpdate() {
  if (!present || !sensor.dataReady()) return;
  sensor.read(false);                                       // data is ready: non-blocking read
  if (sensor.ranging_data.range_status == VL53L1X::RangeValid) {
    lastMm = sensor.ranging_data.range_mm;
    lastOkMs = millis();
  }
}

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
