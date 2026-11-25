import SwiftUI

/// The unobtrusive recording pill shown in focus mode while a recording is in
/// progress: pulsing dot + elapsed timer + compact pause/resume/stop controls.
struct FocusRecordingPill: View {
    let presentation: MeetingWorkspacePresentation
    let elapsed: String
    let isRecordingState: Bool
    let isPreparing: Bool
    let isFinalizing: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOpacity: Double = 1

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            Circle()
                .fill(Color.stateRecording)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)
                .onAppear { startPulseIfNeeded() }
                .onChange(of: isRecordingState) { startPulseIfNeeded() }
                .onChange(of: reduceMotion) { startPulseIfNeeded() }
                .accessibilityLabel(isRecordingState ? "Recording in progress" : "Recording paused")

            Text(elapsed)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isRecordingState ? Color.stateRecording : Color.textPrimary)
                .accessibilityLabel("Elapsed time: \(elapsed)")

            if presentation.showsPauseRecordingButton {
                pillIconButton("pause.fill", label: "Pause", action: onPause)
                    .disabled(isPreparing)
                    .keyboardShortcut("p", modifiers: .command)
            }

            if presentation.showsResumeRecordingButton {
                pillIconButton("play.fill", label: "Resume", action: onResume)
                    .disabled(isPreparing)
                    .keyboardShortcut("p", modifiers: .command)
            }

            if presentation.showsStopRecordingButton {
                pillIconButton("stop.fill", label: "Stop & Process", action: onStop)
                    .disabled(isPreparing || isFinalizing)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, CasaSpace.md)
        .padding(.trailing, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xs)
        .background(Color.stateRecording.opacity(0.14), in: Capsule())
        .overlay(
            Capsule().stroke(Color.stateRecording.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording status")
    }

    private func pillIconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.backgroundActive, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textPrimary)
        .help(label)
        .accessibilityLabel(label)
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
}

/// The leading-aligned "Exit Focus" affordance shown whenever focus mode is
/// active (Esc also exits).
struct FocusExitButton: View {
    let onExitFocus: () -> Void

    var body: some View {
        Button(action: onExitFocus) {
            Label("Exit Focus", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.callout)
        }
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.escape, modifiers: [])
        .help("Exit Focus (Esc)")
    }
}
