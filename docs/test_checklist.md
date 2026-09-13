# OpenCane — device test checklist (Sun Sep 13)

Tick each box on the phone (iPhone 17 Pro Max, unlocked, USB or not). Pull a trip log after each block:
`cd ios && make audit` (copies the newest `canekit-*.jsonl`). ✅ pass · ❌ fail (write what happened).

## 0. Before you start
- [ ] Latest build installed (Guide shows the big round microphone with contour rings)
- [ ] Settings → Auto-Lock **Never** (Settings app → Display & Brightness)
- [ ] Location: **Always** (Settings app → Privacy → Location Services → OpenCane)
- [ ] Microphone + Speech Recognition allowed
- [ ] ElevenLabs: account topped up? (0 credits = every line in Apple's voice — expected, not a bug)

## 1. Launch and the voice shell
- [ ] Open the app: "OpenCane ready." → the menu → tick → mic opens by itself
- [ ] Say **"status"** → one sentence, one voice (no Apple/ElevenLabs flip mid-session)
- [ ] Say **"help"** → numbered list; say **"four"** → status again
- [ ] Say nothing after an answer → the 5 s follow-up window closes silently (no "I did not catch that")
- [ ] Tap the big mic, ask a free question → "One moment." if slow, answer or timeout by ~4 s
- [ ] Ask a question, then ask another before it answers → only the second answer is spoken
- [ ] Lock the phone mid-question, unlock → no stale answer, no mic dot
- [ ] Settings → Voice: Natural / System picker works; Haptics card shows why if the key is refused

## 2. Emergency (do NOT say "yes" unless the contact expects a call)
- [ ] Say **"emergency"** → "Say yes to call … at …" → wait for the whole prompt → say **"no"** → "Emergency canceled."
- [ ] Say "emergency" and stay silent → "Emergency canceled." after ~8 s
- [ ] (Optional, warned contact) "emergency" → full prompt → "yes" → phone call sheet opens

## 3. Obstacles on the cane (phone mounted, ~45° down)
- [ ] Settings → Mount card says **"too steep for head-height cover"** at 45°; head tiles say NO COVER
- [ ] Walk at a wall: centre buzz, **no "Head height."**
- [ ] Tilt the phone to ~5–10° and hold a board / sign at head height (1.5–1.8 m) → one "Head height.", no repeat every few seconds
- [ ] Sweep the cane under a doorway sign twice, 3 s apart → "Head height." both times
- [ ] Walk up to a wall until the phone nearly touches → STOP (red), never CLEAR
- [ ] Dark hallway → "Low light. Obstacle detection still works."

## 4. Indoor → outdoor (ISR → CIF)
- [ ] In Townsend 1st-floor south corridor, say **"take me from ISR to CIF"** → "This indoor route has not been walked yet…" then step 1
- [ ] Walk: steps advance by the pedometer; say **"next"** to skip, **"repeat"** to hear the step again
- [ ] "The main desk is on your right." near the lobby
- [ ] At the doors: "You are at the ISR front doors. Go outside and wait a moment for GPS."
- [ ] Outside: GPS handover starts the CIF route by itself (or say **"I'm outside"**)
- [ ] Lock the phone during the indoor walk, keep walking out of the doors → handover still happens even if the steps never reached the exit (GPS-only: 3 fixes ≤ 10 m within 15 m of the door); trip log shows `indoor {action: paused_background}` then `handover {by: gps}`
- [ ] Island during the indoor walk is the same activity after the handover (warming → walking), not a second one
- [ ] Guide card shows "Indoors · step N of 5" with Repeat / Next / Stop route
- [ ] Stop route (two taps) ends the indoor walk too

## 5. Record the real indoor route (sighted teammate, once)
- [ ] Settings → Record indoor route → **Start recording** at the lab door
- [ ] Walk to the ISR front doors at a normal pace, phone on the cane
- [ ] At each landmark tap **Add landmark** and say it ("personal lab on your left")
- [ ] Tap **Add landmark** and say **"stop"** → it is not added as a landmark (card: "Not added as a landmark…"); the command acts
- [ ] Outside the doors: **Finish at the exit** (hold still ~8 s) → **Save**
- [ ] Indoors, far from a window: **Finish at the exit** → "No GPS fix. Step outside the door…" (an indoor 30 m+ fix is not saved as the exit)
- [ ] Run section 4 again: no "not walked yet" caveat, your landmarks are spoken

## 6. Outdoor route (ISR → CIF)
- [ ] Route intro in one voice; beacon in AirPods points the right way
- [ ] Turns: "Turn right onto Goodwin…" at the corner, wrist tap on the watch
- [ ] Crossings: signal lines at Green St / Springfield / Mathews
- [ ] Arrival at the CIF east entrance → summary with distance, time, steps
- [ ] Say **"where am I"** mid-route → description; lock the phone during it → nothing stale after unlock

## 7. Dynamic Island / Live Activity (Step 64)
- [ ] Start a route, lock the phone: island shows the **OpenCane ring mark** + turn glyph + metres (not a location dot)
- [ ] Route warming up: countdown in the island
- [ ] Locked during a route: island says **obstacles paused** — never a green "Path clear"
- [ ] Long-press the island: instruction (3 lines), route progress, obstacle state
- [ ] Obstacle stop/head while locked: the screen lights once (not repeatedly)
- [ ] Indoor walk: island "Indoors · step 3 of 5"
- [ ] Stop route: "Route stopped" card for ~10 s
- [ ] Control Center: add **Talk to OpenCane** control → it opens the app listening
- [ ] Lock screen: OpenCane widget → opens the app

## 8. Other
- [ ] Type a destination: tab bar hides with the keyboard; no Australian / foreign suggestions
- [ ] Watch: Repeat / Next / Describe / Recenter; crown = Next; indoor Next works
- [ ] Settings → Family alerts → Send test event
- [ ] Profile → emergency phone 925-791-8082 → Call link works

## After testing
- [ ] `cd ios && make audit` and send the output / log name
- [ ] Note every ❌ with what you heard/saw
