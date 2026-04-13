# Recording Capture-First Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce recording-time CPU and memory growth by keeping the live recording path focused on capture and file writes, and deferring heavier processing until the recording stops.

**Architecture:** Split the current recorder hot path into small testable helpers: one layer for cheap live capture writes and one layer for post-stop conversion/mixing. Keep live metering, but remove avoidable per-buffer work and unneeded screen-frame capture. Preserve the existing final `.wav` output contract so the rest of the app stays unchanged.

**Tech Stack:** Swift, SwiftUI, AVFoundation, ScreenCaptureKit, XCTest, SwiftData

---

### Task 1: Add Regression Tests For Deferred Processing Helpers

**Files:**
- Create: `CasablancaTests/AudioRecordingPipelineTests.swift`
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Test: `CasablancaTests/AudioRecordingPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPostProcessingPlanUsesRawCaptureFormatsWithoutRealtimeConversion()
func testMixPlanSkipsMissingSystemTrack()
func testMixPlanComputesExpectedOutputFrameCount()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -only-testing:CasablancaTests/AudioRecordingPipelineTests`
Expected: FAIL because the post-processing helper types do not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
struct RecordedTrackCapturePlan { ... }
struct DeferredRecordingMixPlan { ... }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2
Expected: PASS

### Task 2: Refactor Live Recording To Capture First

**Files:**
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Test: `CasablancaTests/AudioRecordingPipelineTests.swift`

- [ ] **Step 1: Write the failing test for the live-path decision**

```swift
func testCaptureFirstPlanKeepsRealtimeWorkInRawTargetFormat()
```

- [ ] **Step 2: Run test to verify it fails**

Run: same focused `xcodebuild` command
Expected: FAIL because the live path still assumes converted PCM targets.

- [ ] **Step 3: Write minimal implementation**

```swift
// Live microphone/system audio writes raw capture buffers to temp files.
// Conversion to the final transcript/export format is deferred to stop().
```

- [ ] **Step 4: Run test to verify it passes**

Run: same focused `xcodebuild` command
Expected: PASS

### Task 3: Remove Unnecessary Runtime Capture Work

**Files:**
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Test: `CasablancaTests/AudioRecordingPipelineTests.swift`

- [ ] **Step 1: Write the failing test for stream configuration**

```swift
func testScreenCaptureOutputIsNotRequiredForSystemAudioOnlyRecording()
```

- [ ] **Step 2: Run test to verify it fails**

Run: same focused `xcodebuild` command
Expected: FAIL because the stream configuration still includes unused screen output.

- [ ] **Step 3: Write minimal implementation**

```swift
// Only attach the `.audio` SCStream output needed for system-audio capture.
```

- [ ] **Step 4: Run test to verify it passes**

Run: same focused `xcodebuild` command
Expected: PASS

### Task 4: Verify End-To-End Regression Safety

**Files:**
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Test: `CasablancaTests/AudioRecordingPipelineTests.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Run focused regression tests**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' -only-testing:CasablancaTests/AudioRecordingPipelineTests -only-testing:CasablancaTests/MeetingStartFlowTests`
Expected: PASS

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
Expected: PASS with 0 failures
