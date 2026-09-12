# Bolt's Journal - Critical Learnings

## 2026-09-12 - SwiftUI Observation Root Invalidation from 30 Hz Sensor Streams

**Learning:** In Swift 6 / SwiftUI with `@Observable`, referencing a high-frequency sensor property (such as `model.depth.report` at 15–30 Hz) directly in root container views like `ContentView.body` causes the entire root view hierarchy (all 9 navigation, guide, status, haptics, watch, and settings cards) to re-evaluate on every depth frame.
**Action:** Isolate high-frequency observed properties into dedicated leaf subviews (e.g. `ObstaclesCard` wrapping pure `LaneGridView(report:)`, and isolating `MountAimRow` as a leaf view) so observation dependencies are tracked strictly by leaf views that render the data, preventing root container re-renders while keeping leaf components pure and easily previewable/testable.
