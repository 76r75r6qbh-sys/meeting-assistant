import AppKit
import SwiftUI

/// The draft reply for one to-do: drafted by headless Claude Code on open,
/// editable, revisable with a steer, copied or handed to an interactive Claude
/// Code session. Nothing is sent and nothing is kept: closing the sheet stops
/// any run in flight and drops the draft.
struct DraftReplySheet: View {
    /// Opens Claude Code with a prompt. Injectable so a render never opens Terminal.
    typealias ContinueInClaudeCode = @MainActor (String) async throws -> Void

    private let todoText: String
    private let meetingSubtitle: String?
    private let sourceLink: TodoSourceLink?
    private let toastCenter: ToastCenter
    /// Nil when the to-do has no meeting. Called after the sheet is dismissed.
    private let onOpenMeeting: (() -> Void)?
    private let continueInClaudeCode: ContinueInClaudeCode

    /// Held in `@State`, so the first view model sticks for the sheet's life
    /// even though the parent rebuilds this view (and a new, unused one).
    @State private var viewModel: DraftReplyViewModel
    @State private var isConfirmingStartOver = false
    @State private var isOpeningClaudeCode = false
    @Environment(\.dismiss) private var dismiss

    /// Drafts with ``DraftReplyService``. Snapshots the to-do on the main
    /// actor; the run never touches SwiftData.
    init(todo: TodoItem, toastCenter: ToastCenter, onOpenMeeting: (() -> Void)?) {
        self.init(
            todo: todo,
            viewModel: DraftReplyViewModel(context: DraftReplyContext(todo: todo), drafter: DraftReplyService()),
            toastCenter: toastCenter,
            onOpenMeeting: onOpenMeeting
        )
    }

    init(
        todo: TodoItem,
        viewModel: DraftReplyViewModel,
        toastCenter: ToastCenter,
        onOpenMeeting: (() -> Void)?,
        continueInClaudeCode: @escaping ContinueInClaudeCode = DraftReplySheet.openClaudeCode
    ) {
        let presentation = TodoRowPresentation(todo: todo)
        self.todoText = todo.text
        self.meetingSubtitle = presentation.meetingSubtitle
        self.sourceLink = presentation.sourceLink
        self.toastCenter = toastCenter
        self.onOpenMeeting = presentation.meetingID == nil ? nil : onOpenMeeting
        self.continueInClaudeCode = continueInClaudeCode
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(CasaSpace.lg)
            Divider()
            draftArea
                .padding(CasaSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(CasaSpace.lg)
        }
        .frame(
            minWidth: CasaLayout.modalWidthLarge, idealWidth: 640, maxWidth: .infinity,
            minHeight: 480, idealHeight: 560, maxHeight: .infinity
        )
        .onAppear {
            // Once per view model: a second appearance must not redraft.
            guard viewModel.inFlight == nil else { return }
            viewModel.start()
        }
        .onDisappear {
            viewModel.cancel()
        }
        .confirmationDialog("Discard your edits?", isPresented: $isConfirmingStartOver) {
            Button("Start over", role: .destructive) { viewModel.startOver() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Start over writes a new draft from scratch.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: CasaSpace.md) {
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                Text("Draft reply")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textTertiary)
                Text(todoText)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if meetingSubtitle != nil || sourceLink != nil {
                    HStack(spacing: CasaSpace.sm) {
                        if let meetingSubtitle {
                            meetingButton(meetingSubtitle)
                        }
                        if let sourceLink {
                            TodoSourceLinkChip(link: sourceLink)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private func meetingButton(_ subtitle: String) -> some View {
        if let onOpenMeeting {
            Button {
                dismiss()
                onOpenMeeting()
            } label: {
                Label(subtitle, systemImage: "calendar")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(GhostButtonStyle())
            .help("Open the meeting")
        }
    }

    // MARK: - Draft

    private var isGenerating: Bool {
        if case .generating = viewModel.phase { return true }
        return false
    }

    private var hasDraftText: Bool {
        !viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var draftArea: some View {
        switch viewModel.phase {
        case .failed(let message):
            failure(message)
        case .generating(let label) where !hasDraftText:
            VStack(spacing: CasaSpace.md) {
                ProgressView()
                    .controlSize(.regular)
                Text(label)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                Button("Cancel") { viewModel.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            editor
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: CasaSpace.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Color.accentWarning)
            Text(message)
                .font(.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Retry") { viewModel.start() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            if let channel = viewModel.channel {
                Label("Reply via \(channel)", systemImage: "paperplane")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            draftText
                .padding(CasaSpace.sm)
                .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: CasaRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: CasaRadius.lg)
                        .strokeBorder(Color.borderSubtle)
                )
                .accessibilityLabel("Draft")
            if case .generating(let label) = viewModel.phase {
                HStack(spacing: CasaSpace.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { viewModel.cancel() }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    /// Read-only while a run is in flight: its result replaces the text and
    /// would silently drop an edit made meanwhile. `.disabled` does not stop
    /// typing into a `TextEditor` that already has focus, so the editor is
    /// swapped for plain text until the run ends.
    @ViewBuilder
    private var draftText: some View {
        if isGenerating {
            ScrollView {
                Text(viewModel.draftText)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Matches the text view's line fragment padding.
                    .padding(.horizontal, 5)
            }
        } else {
            TextEditor(text: $viewModel.draftText)
                .font(.body)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            HStack(spacing: CasaSpace.sm) {
                TextField("Steer the draft, e.g. shorter, more formal, in Dutch", text: $viewModel.steer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.revise() }
                    .disabled(isGenerating)
                    .accessibilityLabel("Steer")
                Button("Revise") { viewModel.revise() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!viewModel.canRevise)
                moreMenu
            }
            if let revisionError = viewModel.revisionError {
                Label(revisionError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Start over", systemImage: "arrow.counterclockwise") {
                if viewModel.isEdited {
                    isConfirmingStartOver = true
                } else {
                    viewModel.startOver()
                }
            }
            Button("Copy", systemImage: "doc.on.doc") { copyDraft() }
                .disabled(!hasDraftText)
            Divider()
            Button("Continue in Claude Code", systemImage: "terminal") { openInClaudeCode() }
                .disabled(isOpeningClaudeCode)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: - Actions

    private func copyDraft() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.draftText, forType: .string)
        toastCenter.show(message: "Draft copied")
    }

    private func openInClaudeCode() {
        let prompt = DraftReplyPrompt.continuation(
            draft: viewModel.draftText,
            steer: viewModel.steer,
            context: viewModel.context
        )
        isOpeningClaudeCode = true
        Task {
            defer { isOpeningClaudeCode = false }
            do {
                try await continueInClaudeCode(prompt)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                toastCenter.show(message: "Couldn't open Claude Code — \(message)")
            }
        }
    }

    /// Resolves the `claude` binary as the draft run does (the Settings path,
    /// else known install paths, else a login shell) and opens it in Terminal.
    static func openClaudeCode(prompt: String) async throws {
        let defaults = UserDefaults.standard
        let cli = ClaudeCLIProvider(
            endpoint: defaults.string(forKey: AppPreferenceKey.claudeCLIPath) ?? "",
            model: DraftReplyService.defaultModel,
            defaults: defaults
        )
        guard let executable = try await cli.resolvedExecutablePath(preferring: cli.endpoint) else {
            throw LLMProviderError.invalidEndpoint(provider: cli.displayName)
        }
        try ClaudeCodeLauncher.launch(claudePath: executable, prompt: prompt)
    }
}
