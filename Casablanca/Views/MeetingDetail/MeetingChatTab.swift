import AppKit
import SwiftUI

/// "Ask your meeting" — a grounded Q&A surface over a single meeting's content.
/// Batch (no streaming) with a typing indicator while the local LLM answers.
struct MeetingChatTab: View {
    let meeting: Meeting
    @Bindable var chatService: MeetingChatService

    /// Disabled when there's no transcript AND no summary to ground answers on.
    let hasGroundingContent: Bool
    /// Disabled while a background summary is running for ANY meeting — the local
    /// LLM serializes requests, so a chat would queue behind it and risk the
    /// 120s timeout.
    let isSummaryInProgress: Bool

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDisabled: Bool { !hasGroundingContent || isSummaryInProgress }

    private var disabledHint: String? {
        if !hasGroundingContent {
            return "Ask is available once this meeting has a transcript or summary to draw from."
        }
        if isSummaryInProgress {
            return "Available after the summary finishes — the local model handles one request at a time."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.lg) {
            header

            if let hint = disabledHint {
                disabledBanner(hint)
            }

            messageList

            if let error = chatService.errorMessage {
                errorRow(error)
            }

            inputBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { chatService.activate(meetingID: meeting.id) }
        .onChange(of: meeting.id) { _, newID in chatService.activate(meetingID: newID) }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Ask this meeting", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.accentSecondary)
                .symbolRenderingMode(.hierarchical)

            Spacer()

            Text("Answers use only this meeting's content")
                .font(.caption2)
                .foregroundStyle(Color.textTertiary)
        }
    }

    @ViewBuilder
    private func disabledBanner(_ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.textTertiary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))
    }

    // MARK: - Message list

    @ViewBuilder
    private var messageList: some View {
        if chatService.messages.isEmpty && !chatService.isAnswering {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: CasaSpace.md) {
                ForEach(chatService.messages) { message in
                    messageBubble(message)
                }

                if chatService.isAnswering {
                    typingIndicator
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .casaAnimation(CasaAnimation.fast, value: chatService.messages.count)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Ask anything about this meeting")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            Text("Try: “What did we decide?”, “What are my action items?”, or “Did we discuss the Q3 budget?”")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: CasaSpace.xxl) }

            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(isUser ? Color.white : Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isUser {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.textTertiary)
                    .help("Copy answer")
                    .accessibilityLabel("Copy answer")
                }
            }
            .padding(CasaSpace.md)
            .background(
                isUser ? Color.accentColor : Color.backgroundTertiary,
                in: RoundedRectangle(cornerRadius: CasaRadius.lg)
            )

            if !isUser { Spacer(minLength: CasaSpace.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Assistant"): \(message.text)")
    }

    private var typingIndicator: some View {
        HStack(spacing: CasaSpace.sm) {
            ProgressView().controlSize(.small)
            Text("Thinking…")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button("Cancel") { chatService.cancel() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
        .accessibilityLabel("Generating answer")
    }

    @ViewBuilder
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CasaSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentWarning)
                .symbolRenderingMode(.hierarchical)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { chatService.clearError() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(CasaSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: CasaRadius.md))
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: CasaSpace.sm) {
            TextField("Ask a question…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .disabled(isDisabled || chatService.isAnswering)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Send")
            .accessibilityLabel("Send question")
        }
    }

    private var canSend: Bool {
        !isDisabled
            && !chatService.isAnswering
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let question = draft
        draft = ""
        chatService.ask(question, meeting: meeting)
    }
}
