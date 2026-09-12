/*
 * canekit_grip.ino — CaneKit smart-cane retrofit grip module (hackathon firmware)
 *
 * Boards : Seeed XIAO ESP32-S3 (primary) / ESP32-C3 SuperMini (fallback)
 * BLE    : NimBLE-Arduino 2.x, Nordic UART Service, device name "CANE"
 * Motors : two coin ERM motors via NPN low-side switches, LEDC PWM @ 200 Hz
 * ToF    : optional VL53L1X (see tof.h / tof.cpp, HAS_TOF)
 *
 * RX commands (ASCII, one per line, '\n' or '\r' terminated; a write without a
 * terminator is parsed after 150 ms so nRF Connect "send text" works too):
 *   H:<L|R|B>:<1-4>:<ms>   haptic: motor, intensity 1-4 (40/60/80/100 % duty), duration
 *   P:<n>                  pattern: 1 double pulse both, 2 left triple, 3 right triple,
 *                                   4 long both = STOP (flushes queue first)
 *   S:<0|1>                silence off / on (drops all haptics while on)
 * TX notify every 100 ms:  "D:<mm>,B:<pct>\n"  (-1 when unknown)
 *
 * Fail-safe: no BLE connection for 5 s and ToF present -> LOCAL mode: buzz both
 * motors on drop-off (> baseline+250 mm) or step-up (< 60 % baseline).
 */
#include <Arduino.h>
#include <NimBLEDevice.h>
#include "tof.h"

// ---------------------------------------------------------------- pin maps
#if defined(ARDUINO_XIAO_ESP32S3) || defined(CONFIG_IDF_TARGET_ESP32S3)
  #define BOARD_NAME     "XIAO ESP32-S3"
  #define MOTOR_L_PIN    1      // D0 -> 1k -> NPN base (left motor)
  #define MOTOR_R_PIN    2      // D1 -> 1k -> NPN base (right motor)
  #define LED_PIN        21     // on-board user LED (active LOW)
  #define LED_ACTIVE_LOW 1
  #define I2C_SDA_PIN    5      // D4 (verified: Seeed wiki pin multiplexing page)
  #define I2C_SCL_PIN    6      // D5
  // #define BAT_SENSE_PIN 3    // D2 — uncomment only if a divider is fitted (README)
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
  #define BOARD_NAME     "ESP32-C3 SuperMini"
  #define MOTOR_L_PIN    2
  #define MOTOR_R_PIN    3
  #define LED_PIN        8      // on-board LED (active LOW) — clashes with default SDA, so I2C moved
  #define LED_ACTIVE_LOW 1
  #define I2C_SDA_PIN    6
  #define I2C_SCL_PIN    7
  // #define BAT_SENSE_PIN 0    // ADC1_CH0
#else
  #error "Unsupported board: build for XIAO ESP32-S3 or ESP32-C3"
#endif

#define BAT_DIV_RATIO   2.0f  // (R_top+R_bot)/R_bot, e.g. 100k/100k -> 2.0
#define PWM_FREQ        200   // Hz, per spec (ERM motors are fine here; 200 Hz is audible-ish)
#define PWM_RES         8     // bits -> duty 0..255

// ---------------------------------------------------------------- BLE (NUS)
#define NUS_SVC "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // phone -> cane (write)
#define NUS_TX  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // cane -> phone (notify)

static NimBLECharacteristic* txChar = nullptr;
static volatile bool connected = false;
static uint32_t lastConnMs = 0;          // last time we were connected (for 5 s fail-safe)

// RX bytes arrive on the NimBLE host task; hand them to loop() via a SPSC ring.
static uint8_t  rxRing[256];
static volatile uint8_t rxHead = 0, rxTail = 0;

class ServerCB : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override { connected = true; }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    connected = false; lastConnMs = millis();
    NimBLEDevice::startAdvertising();
  }
};
class RxCB : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    NimBLEAttValue v = c->getValue();
    for (size_t i = 0; i < v.length(); i++) {
      uint8_t next = rxHead + 1;            // uint8_t wraps at 256 = ring size
      if (next == rxTail) break;            // full: drop
      rxRing[rxHead] = v.data()[i]; rxHead = next;
    }
  }
};

static void bleSetup() {
  NimBLEDevice::init("CANE");
  NimBLEDevice::setMTU(64);
  NimBLEServer* srv = NimBLEDevice::createServer();
  srv->setCallbacks(new ServerCB());
  NimBLEService* svc = srv->createService(NUS_SVC);
  txChar = svc->createCharacteristic(NUS_TX, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rx = svc->createCharacteristic(NUS_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  rx->setCallbacks(new RxCB());
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName("CANE");
  adv->addServiceUUID(NUS_SVC);
  adv->enableScanResponse(true);
  adv->start();
}

// ---------------------------------------------------------------- motors / haptics
enum { M_L = 1, M_R = 2, M_B = 3 };
struct Step { uint8_t mask, duty; uint16_t ms; };            // ms == 0 terminates a sequence
static const uint8_t DUTY[5] = { 0, 102, 153, 204, 255 };    // intensity 0..4 -> 0/40/60/80/100 %

static const Step PAT_DOUBLE[]  = { {M_B,255,120}, {0,0,100}, {M_B,255,120}, {0,0,0} };
static const Step PAT_LTRIPLE[] = { {M_L,255,100}, {0,0,80}, {M_L,255,100}, {0,0,80}, {M_L,255,100}, {0,0,0} };
static const Step PAT_RTRIPLE[] = { {M_R,255,100}, {0,0,80}, {M_R,255,100}, {0,0,80}, {M_R,255,100}, {0,0,0} };
static const Step PAT_STOP[]    = { {M_B,255,700}, {0,0,0} };
static const Step PAT_STEPUP[]  = { {M_B,255,400}, {0,0,0} };     // local-mode only
static const Step* const PATTERNS[] = { nullptr, PAT_DOUBLE, PAT_LTRIPLE, PAT_RTRIPLE, PAT_STOP };

// Command queue: up to 4 pending commands (each = one H step or one pattern).
struct Cmd { const Step* seq; Step single; };
#define QUEUE_LEN 4
static Cmd     queue[QUEUE_LEN];
static uint8_t qHead = 0, qCount = 0;
static const Step* curSeq = nullptr;   // sequence being played (nullptr = idle)
static Step    oneShot[2];             // storage for an H command while it plays
static uint8_t curIdx = 0;
static uint32_t stepEndMs = 0;
static bool silenced = false;

static void motorWrite(uint8_t pin, uint8_t duty) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(pin, duty);                        // core 3.x: pin-based API
#else
  ledcWrite(pin == MOTOR_L_PIN ? 0 : 1, duty); // core 2.x: channel-based API
#endif
}
static void motorsSetup() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(MOTOR_L_PIN, PWM_FREQ, PWM_RES);
  ledcAttach(MOTOR_R_PIN, PWM_FREQ, PWM_RES);
#else
  ledcSetup(0, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_L_PIN, 0);
  ledcSetup(1, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_R_PIN, 1);
#endif
  motorWrite(MOTOR_L_PIN, 0); motorWrite(MOTOR_R_PIN, 0);
}
static void motorsApply(uint8_t mask, uint8_t duty) {
  motorWrite(MOTOR_L_PIN, (mask & M_L) ? duty : 0);
  motorWrite(MOTOR_R_PIN, (mask & M_R) ? duty : 0);
}
static void hapticStopAll() { qCount = 0; curSeq = nullptr; motorsApply(0, 0); }

static bool enqueue(const Cmd& c) {
  if (silenced) return true;                   // accepted, silently dropped
  if (qCount >= QUEUE_LEN) return false;
  queue[(qHead + qCount) % QUEUE_LEN] = c; qCount++;
  return true;
}
static bool enqueueStep(uint8_t mask, uint8_t duty, uint16_t ms) {
  Cmd c; c.seq = nullptr; c.single = { mask, duty, ms }; return enqueue(c);
}
static bool enqueuePattern(const Step* seq) { Cmd c; c.seq = seq; return enqueue(c); }

static void startStep() {
  const Step& s = curSeq[curIdx];
  motorsApply(s.mask, s.duty);
  stepEndMs = millis() + s.ms;
}
// Non-blocking scheduler: advance the current sequence, then pull the next command.
static void hapticUpdate() {
  uint32_t now = millis();
  if (curSeq && (int32_t)(now - stepEndMs) >= 0) {
    curIdx++;
    if (curSeq[curIdx].ms == 0) { curSeq = nullptr; motorsApply(0, 0); }
    else startStep();
  }
  if (!curSeq && qCount) {
    Cmd& c = queue[qHead]; qHead = (qHead + 1) % QUEUE_LEN; qCount--;
    if (c.seq) curSeq = c.seq;
    else { oneShot[0] = c.single; oneShot[1] = {0,0,0}; curSeq = oneShot; }
    curIdx = 0; startStep();
  }
}

// ---------------------------------------------------------------- command parser
static char     line[48];
static uint8_t  lineLen = 0;
static uint32_t lineTs = 0;

static void handleLine(char* s) {
  while (*s == ' ') s++;
  Serial.printf("[rx] %s\n", s);
  bool ok = false;
  switch (toupper(s[0])) {
    case 'H': {                                   // H:<L|R|B>:<1-4>:<ms>
      char m = 0; int lvl = 0; long ms = 0;
      if (sscanf(s + 1, ":%c:%d:%ld", &m, &lvl, &ms) == 3 && lvl >= 1 && lvl <= 4 && ms > 0 && ms <= 10000) {
        uint8_t mask = (toupper(m) == 'L') ? M_L : (toupper(m) == 'R') ? M_R : (toupper(m) == 'B') ? M_B : 0;
        if (mask) ok = enqueueStep(mask, DUTY[lvl], (uint16_t)ms);
      }
      break;
    }
    case 'P': {                                   // P:<1-4>
      int n = 0;
      if (sscanf(s + 1, ":%d", &n) == 1 && n >= 1 && n <= 4) {
        if (n == 4) hapticStopAll();              // STOP: flush everything, then long buzz
        ok = enqueuePattern(PATTERNS[n]);
      }
      break;
    }
    case 'S': {                                   // S:<0|1>
      int n = -1;
      if (sscanf(s + 1, ":%d", &n) == 1 && (n == 0 || n == 1)) {
        silenced = (n == 1);
        if (silenced) hapticStopAll();
        ok = true;
      }
      break;
    }
  }
  if (!ok) Serial.println("[rx] rejected (bad syntax or queue full)");
}
static void rxUpdate() {
  while (rxTail != rxHead) {
    char c = (char)rxRing[rxTail]; rxTail++;
    if (c == '\n' || c == '\r') { if (lineLen) { line[lineLen] = 0; handleLine(line); } lineLen = 0; }
    else if (lineLen < sizeof(line) - 1) { line[lineLen++] = c; lineTs = millis(); }
  }
  // No terminator within 150 ms -> treat what we have as a complete line.
  if (lineLen && millis() - lineTs > 150) { line[lineLen] = 0; handleLine(line); lineLen = 0; }
}

// ---------------------------------------------------------------- battery
static int batteryPct() {
#ifdef BAT_SENSE_PIN
  uint32_t mv = 0;
  for (int i = 0; i < 8; i++) mv += analogReadMilliVolts(BAT_SENSE_PIN);
  float v = (mv / 8.0f) * BAT_DIV_RATIO / 1000.0f;          // volts at the cell
  int pct = (int)((v - 3.3f) / (4.2f - 3.3f) * 100.0f + 0.5f); // crude linear LiPo map
  return constrain(pct, 0, 100);
#else
  return -1;                                                  // XIAO S3 has no battery ADC by default
#endif
}

// ---------------------------------------------------------------- local (fail-safe) mode
#define LOCAL_MODE_DELAY_MS  5000
#define BASE_N               20
#define STABLE_SPREAD_MM     40      // max-min of last 20 readings to count as "stable"
#define DROPOFF_MM           250
#define ALERT_COOLDOWN_MS    1500
static int16_t  hist[BASE_N];
static uint8_t  histIdx = 0, histFill = 0;
static int      baseline = -1;
static uint32_t lastAlertMs = 0;
static bool     localMode = false;

// Feed every valid reading; baseline = median of the last 20 readings while stable.
static void baselineFeed(int d) {
  hist[histIdx] = d; histIdx = (histIdx + 1) % BASE_N;
  if (histFill < BASE_N && ++histFill < BASE_N) return;   // need 20 samples first
  int16_t s[BASE_N]; memcpy(s, hist, sizeof(s));
  for (int i = 1; i < BASE_N; i++) { int16_t v = s[i]; int j = i - 1; while (j >= 0 && s[j] > v) { s[j+1] = s[j]; j--; } s[j+1] = v; }
  if (s[BASE_N-1] - s[0] <= STABLE_SPREAD_MM) baseline = (s[BASE_N/2 - 1] + s[BASE_N/2]) / 2;
}
static void localModeCheck(int d) {
  if (baseline <= 0 || millis() - lastAlertMs < ALERT_COOLDOWN_MS) return;
  bool drop = d > baseline + DROPOFF_MM;
  bool step = d < (baseline * 6) / 10;
  if (drop || step) {
    lastAlertMs = millis();
    Serial.printf("[local] %s d=%d base=%d\n", drop ? "DROP-OFF" : "STEP-UP", d, baseline);
    hapticStopAll();
    enqueuePattern(drop ? PAT_DOUBLE : PAT_STEPUP);
  }
}

// ---------------------------------------------------------------- LED
static void ledUpdate() {
  uint32_t t = millis();
  bool on = connected ? true                      // solid: connected
          : localMode ? ((t / 125) & 1)           // fast blink: local fail-safe mode
          : ((t % 1000) < 100);                   // short blip: advertising
  digitalWrite(LED_PIN, LED_ACTIVE_LOW ? !on : on);
}

// ---------------------------------------------------------------- setup / loop
void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  motorsSetup();
  bool tof = tofBegin(I2C_SDA_PIN, I2C_SCL_PIN);
  bleSetup();
  lastConnMs = millis();
  Serial.printf("CaneKit grip on %s, ToF %s, advertising as CANE\n", BOARD_NAME, tof ? "OK" : "absent");
}

void loop() {
  static uint32_t lastTx = 0, lastBat = 0, lastTofMs = 0;
  static int batPct = -1;
  uint32_t now = millis();

  rxUpdate();
  hapticUpdate();
  tofUpdate();

  int d = tofDistanceMm();
  if (d >= 0 && now - lastTofMs >= 50) { lastTofMs = now; baselineFeed(d); if (localMode && !silenced) localModeCheck(d); }

  if (connected) lastConnMs = now;
  localMode = !connected && tofPresent() && (now - lastConnMs > LOCAL_MODE_DELAY_MS);

  if (now - lastBat >= 1000) { lastBat = now; batPct = batteryPct(); }

  if (now - lastTx >= 100) {                       // telemetry: "D:<mm>,B:<pct>\n"
    lastTx = now;
    char buf[24];
    int n = snprintf(buf, sizeof(buf), "D:%d,B:%d\n", d, batPct);
    if (connected && txChar) { txChar->setValue((uint8_t*)buf, n); txChar->notify(); }
  }
  ledUpdate();
}
