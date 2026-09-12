# OpenCane Speech Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce truthful but excessive OpenCane narration while preserving every safety, route, and explicit-request speech path.

**Architecture:** Add a Foundation-only `SpeechLoadPolicy` to `CaneKitLogic`. `SpeechQueue` remains the one AVFoundation owner and invokes the policy only for explicitly tagged optional obstacle-name requests. Tighten scene fact selection at the existing `SceneVocabulary` / on-device VLM boundary, and route conversational scene questions through the already-grounded scene describer.

**Tech Stack:** Swift 6, Swift Testing, Foundation, SwiftUI app target, existing `CaneKitLogic` package; no dependencies.

## Global Constraints

- Swift 6 strict concurrency with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`; no `@unchecked Sendable` on main-actor classes.
- Decisions with numeric thresholds live in `ios/Logic`; effects stay in `ios/CaneKit`.
- `.playback` remains the normal audio session; no new audio-session calls.
- `.safety`, `.head`, route guidance, directional fallback cues, and explicit user responses are never suppressed.
- User-facing strings say OpenCane; code/module/target/bundle naming stays CaneKit.
- No new dependency; all tests use Swift Testing and real pure logic.
- Preserve the existing uncommitted hands-free/audio WIP and do not stage it.

---

### Task 1: Add the pure optional-speech admission policy

**Files:**
- Create: `ios/Logic/Sources/CaneKitLogic/SpeechLoadPolicy.swift`
- Create: `ios/Logic/Tests/CaneKitLogicTests/SpeechLoadPolicyTests.swift`

**Interfaces:**
- Produces `SpeechLoadClass`, `SpeechSuppressionReason`, `SpeechLoadDecision`, and `SpeechLoadPolicy`.
- `SpeechLoadPolicy.Configuration.minimumAmbientGap` defaults to `7.0` seconds.
- `mutating func admit(_ kind: SpeechLoadClass, now: TimeInterval, isBusy: Bool) -> SpeechLoadDecision`.
- `mutating func reset()` clears the optional-callout clock.

- [ ] **Step 1: Write tests for normal bypass, first admission, seven-second suppression, boundary admission, busy suppression, and reset.**
- [ ] **Step 2: Run `cd ios && swift test --package-path Logic --filter SpeechLoadPolicyTests` and confirm the new tests fail because the policy does not exist.**
- [ ] **Step 3: Implement the smallest Foundation-only policy with finite-time validation and no sleeping.**
- [ ] **Step 4: Re-run the focused tests and then `cd ios && make test`.**

### Task 2: Apply the policy at the speech boundary

**Files:**
- Modify: `ios/CaneKit/Speech/SpeechQueue.swift`
- Modify: `ios/CaneKit/App/AppModel.swift`

**Interfaces:**
- `SpeechQueue.say(_:_:ttl:load:)` adds `load: SpeechLoadClass = .normal` and remains `@discardableResult`.
- `SpeechQueue.onSuppressed` reports `(text, load, reason)` on the main actor.

- [ ] **Step 1: Add an app-level testable call-site expectation in the Logic policy tests; do not add an AVFoundation mock.**
- [ ] **Step 2: Import `CaneKitLogic`, store the policy in `SpeechQueue`, and invoke it after trim but before interruption/queue insertion.**
- [ ] **Step 3: Tag only `AppModel.handle` obstacle names as `.ambientObstacleName`; leave directional fallback, hazards, route, and explicit responses normal/protected.**
- [ ] **Step 4: Wire `speech.onSuppressed` to a `speech_suppressed` trip-log event without claiming that the dropped line was spoken.**
- [ ] **Step 5: Run `cd ios && make test` and `cd ios && make sim`.**

### Task 3: Make scene narration select useful facts

**Files:**
- Modify: `ios/Logic/Sources/CaneKitLogic/SceneVocabulary.swift`
- Modify: `ios/Logic/Tests/CaneKitLogicTests/SceneVocabularyTests.swift`
- Modify: `ios/CaneKit/Scene/OnDeviceVision.swift`
- Modify: `ios/CaneKit/Scene/SceneDescriber.swift`
- Modify: `ios/Logic/Sources/CaneKitLogic/ConversationPrompt.swift`

**Interfaces:**
- `SceneVocabulary.narrationNouns(_:max:)` returns ranked nouns for spoken scene output.
- `SceneVocabulary.sentence(_:max:)` preserves the existing default and supports the two-item fallback.

- [ ] **Step 1: Add a failing test proving a scene with three ranked nouns is spoken with only the top two when the narration limit is used.**
- [ ] **Step 2: Run the focused scene-vocabulary tests and confirm the new assertion fails against the current three-item fallback.**
- [ ] **Step 3: Use the two-item policy in `OnDeviceVLMClient.facts`, `template`, and both cloud faithfulness paths; update the model instruction to omit background detail.**
- [ ] **Step 4: Route `FastPathIntentClassifier.isSceneQuestion` through `AppModel.askAboutScene` before generic cloud conversation dispatch, and remove the unnecessary spoken “Describing.” progress line.**
- [ ] **Step 5: Run the focused tests, then `cd ios && make test` and `cd ios && make sim`.**

### Task 4: Fix the known persistence honesty bug

**Files:**
- Modify: `ios/CaneKit/Conversation/PostStore.swift`
- Modify: `ios/CaneKit/Conversation/ConversationCoordinator.swift`

**Interfaces:**
- `PostStore.append(_:) -> Bool` returns whether the atomic write succeeded while retaining the in-memory marker.

- [ ] **Step 1: Add the return value without changing the on-disk JSON shape.**
- [ ] **Step 2: Make `dropPost(name:)` say that saving failed when `append` returns false, while retaining the marker and logging `lastError`.**
- [ ] **Step 3: Run `cd ios && make test` and `cd ios && make sim`; inspect the diff for no secrets or broad filesystem changes.**

### Task 5: Safety regression and independent review

**Files:**
- Modify: `ios/Logic/Sources/CaneKitLogic/Hazards.swift` if the red-team reassurance case is confirmed.
- Modify: `ios/Logic/Tests/CaneKitLogicTests/HazardTests.swift` if that case is fixed.
- Modify: `docs/CODE_REFERENCE.md`, `CHANGELOG.md`, `docs/todo.md`, and this plan as steps complete.

- [ ] **Step 1: Add a failing hazard-watch test for reassurance text such as “The path is clear.”**
- [ ] **Step 2: Implement the minimal fail-closed rejection and run focused plus full Logic tests.**
- [ ] **Step 3: Run independent agent review, Muse, and Antigravity against a scratch copy; verify every finding against the source and tests before changing code.**
- [ ] **Step 4: Run fresh `make test`, `make sim`, and where available `make uitest` / `make tour`; record device-only gates honestly.**
- [ ] **Step 5: Refresh `graphify-out` with `graphify update .` and ensure the speech boundary is queryable.**
