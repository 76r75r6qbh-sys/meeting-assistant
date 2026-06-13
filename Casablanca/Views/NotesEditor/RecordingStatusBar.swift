import SwiftUI

/// The calm recording status bar shown above the notes editor while a recording
/// is in progress (expanded chrome state). Hosts the pulsing status dot, the
/// state label, the elapsed timer, the audio level meter, the device/language
/// chip (injected by the parent), and the pause/resume/stop controls.
struct RecordingStatusBar<DeviceChip: View>: View {
    let presentation: MeetingWorkspacePresentation
    let autoPause: AutoPauseIndicatorPresentation?
    let elapsed: String
    let audioLevel: Double
    let isPreparing: Bool
    let isFinalizing: Bool
    let isRecordingState: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    @ViewBuilder let deviceChip: () -> DeviceChip

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOpacity: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let autoPause, autoPause.shouldShow {
                Text(autoPause.summary)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CasaSpace.xl)
                    .padding(.top, CasaSpace.sm)
            }

            HStack(spacing: CasaSpace.lg) {
                recordingStatusDot

                Text(presentation.stateLabel)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(isRecordingState ? Color.stateRecording : Color.textPrimary)

                Text(elapsed)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityLabel("Elapsed time: \(elapsed)")

                AudioLevelMeterView(level: audioLevel)

                deviceChip()

                Spacer(minLength: CasaSpace.md)

                recordingControls
            }
            .padding(.horizontal, CasaSpace.xl)
            .padding(.vertical, CasaSpace.md)
        }
        .background(Color.stateRecording.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.stateRecording.opacity(0.22))
                .frame(height: 1)
        }
    }

    private var recordingStatusDot: some View {
        Circle()
            .fill(Color.stateRecording)
            .frame(width: 10, height: 10)
            .opacity(pulseOpacity)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: isRecordingState) { startPulseIfNeeded() }
            .onChange(of: reduceMotion) { startPulseIfNeeded() }
            .accessibilityLabel(isRecordingState ? "Recording in progress" : "Recording paused")
    }

    private func startPulseIfNeeded() {
        if isRecordingState && !reduceMotion {
            pulseOpacity = 1
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.45
            }
        } else {
            withAnimation(.default) {
                pulseOpacity = 1
            }
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if presentation.showsPauseRecordingButton {
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut("p", modifiers: .command)
            .disabled(isPreparing)
        }

        if presentation.showsResumeRecordingButton {
            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut("p", modifiers: .command)
            .disabled(isPreparing)
        }

        if presentation.showsStopRecordingButton {
            Button(action: onStop) {
                Label("Stop & Process", systemImage: "stop.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isPreparing || isFinalizing)
        }
    }
}
