import SwiftUI

/// Unified pipeline-progress card shown in a recorded meeting's detail view.
/// Replaces the old bare `pipelineBanner`. Renders three stage chips
/// (Transcribe → Summarize → Export), an active-stage row with determinate or
/// indeterminate progress + a Cancel button, and an error row with Retry/Dismiss.
///
/// Driven entirely by a `MeetingPipelinePresentation` (pure) plus a couple of
/// live values (transcription progress, summarization start) the row animates
/// off. All actions are injected so the card stays free of service wiring.
struct ProcessingStatusCard: View {
    let presentation: MeetingPipelinePresentation
    /// Live transcription progress (0–1) for the determinate bar.
    let transcriptionProgress: Double
    /// When the in-flight summarization started, for the elapsed-time readout.
    let summarizationStartedAt: Date?

    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onDismissError: () -> Void = {}
    var onDismissWarning: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            stageChips

            if presentation.isActive {
                activeRow
            }

            if case .failed = presentation.stage {
                errorRow
            }

            if let warning = presentation.warning, !presentation.hasError {
                warningRow(warning)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.statusText.isEmpty ? "Processing" : presentation.statusText)
    }

    // MARK: - Stage chips

    private var stageChips: some View {
        HStack(spacing: CasaSpace.xs) {
            ForEach(Array(PipelineStageKind.allCases.enumerated()), id: \.element) { index, kind in
                StageChip(
                    kind: kind,
                    state: presentation.chipState(for: kind),
                    reduceMotion: reduceMotion
                )
                if index < PipelineStageKind.allCases.count - 1 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
    }

    // MARK: - Active row

    @ViewBuilder
    private var activeRow: some View {
        switch presentation.stage {
        case .transcribing:
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                HStack {
                    Text(presentation.statusText)
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text("\(Int(transcriptionProgress * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                    cancelButton
                }
                ProgressView(value: transcriptionProgress, total: 1.0)
                    .tint(Color.stateProcessing)
            }
        case .summarizing:
            if presentation.isSummarizePending {
                // Armed but not started: a quiet "waiting" row with no spinner, so
                // it doesn't masquerade as active work (and can't look "stuck").
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "clock")
                        .foregroundStyle(Color.textTertiary)
                        .imageScale(.small)
                    Text(presentation.statusText)
                        .font(.subheadline)
                        .foregroundStyle(Color.textTertiary)
                    Spacer()
                }
            } else {
                HStack(spacing: CasaSpace.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(presentation.statusText)
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                    if let startedAt = summarizationStartedAt {
                        elapsedLabel(since: startedAt)
                    }
                    Spacer()
                    cancelButton
                }
            }
        case .exporting:
            HStack(spacing: CasaSpace.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(presentation.statusText)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
            }
        case .idle, .failed, .done:
            EmptyView()
        }
    }

    /// Elapsed-time readout for the indeterminate summarization stage. Ticks via
    /// TimelineView; under reduce-motion it shows a static "in progress" instead
    /// of a per-second updating timer.
    @ViewBuilder
    private func elapsedLabel(since startedAt: Date) -> some View {
        if reduceMotion {
            Text("in progress")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.textTertiary)
        } else {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                Text(Self.formatElapsed(elapsed))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel", action: onCancel)
            .controlSize(.small)
            .buttonStyle(.bordered)
    }

    // MARK: - Error row

    private var errorRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentDanger)
                .symbolRenderingMode(.hierarchical)
            Text(presentation.statusText)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry", action: onRetry)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button("Dismiss", action: onDismissError)
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.top, CasaSpace.xs)
    }

    // MARK: - Warning row

    /// A NON-destructive notice for a success-with-caveat (e.g. summary generated
    /// but its to-dos failed). Muted/secondary styling — no red, no Retry — with a
    /// Dismiss. Distinct from the error row so a successful stage never reads as a
    /// failure.
    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.textTertiary)
                .symbolRenderingMode(.hierarchical)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: onDismissWarning)
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.top, CasaSpace.xs)
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// A single stage chip: icon + title, styled by its `PipelineChipState`.
private struct StageChip: View {
    let kind: PipelineStageKind
    let state: PipelineChipState
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: CasaSpace.xs) {
            icon
            Text(kind.title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xs)
        .background(background, in: Capsule())
        .overlay(
            Capsule().strokeBorder(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentSuccess)
        case .active:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.accentDanger)
        case .pending:
            Image(systemName: kind.systemImage)
                .foregroundStyle(Color.textTertiary)
        }
    }

    private var foreground: Color {
        switch state {
        case .done: return Color.textPrimary
        case .active: return Color.textPrimary
        case .failed: return Color.accentDanger
        case .pending: return Color.textTertiary
        }
    }

    private var background: Color {
        switch state {
        case .active: return Color.stateAIGenerated
        case .failed: return Color.accentDanger.opacity(0.12)
        case .done, .pending: return Color.backgroundActive.opacity(0.4)
        }
    }

    private var borderColor: Color {
        switch state {
        case .active: return Color.stateProcessing.opacity(0.4)
        case .failed: return Color.accentDanger.opacity(0.4)
        case .done, .pending: return Color.clear
        }
    }
}

/// Compact variant for list rows / cards: a single icon + caption, no chips,
/// no controls. Renders nothing when there is nothing to show (idle/done).
struct ProcessingStatusCompact: View {
    let presentation: MeetingPipelinePresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if presentation.isActive {
            HStack(spacing: CasaSpace.xs) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(presentation.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.statusText)
        } else if presentation.hasError {
            HStack(spacing: CasaSpace.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.accentDanger)
                    .imageScale(.small)
                    .symbolRenderingMode(.hierarchical)
                Text(presentation.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.accentDanger)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.statusText)
        }
    }
}
