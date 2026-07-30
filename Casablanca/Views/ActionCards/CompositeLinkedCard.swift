// Casablanca/Views/ActionCards/CompositeLinkedCard.swift
import SwiftUI

/// Standalone composite view that stacks a primary action item together with its
/// linked items, each rendered as a sub-card via `ActionCardView`. Offers a
/// prominent "Approve all" action plus per-sub-card Approve / Decline / Revise.
///
/// Presented by Task 7 from the list (NOT routed by `ActionCardView`). Sizes like
/// the existing detail sheet.
struct CompositeLinkedCard: View {
    let primary: ActionQueueItem
    let linked: [ActionQueueItem]
    let model: ActionQueueModel
    let onDismiss: () -> Void

    /// Per-sub-item edited body, keyed by item id. Intentionally NOT pre-seeded:
    /// an absent key reads the item's current body (see `bodyBinding`), so a
    /// re-drafted (revision→pending) item never approves with a stale body.
    @State private var editedBodies: [String: String] = [:]
    @State private var revisingId: String?
    @State private var revisionPrompt: String = ""

    /// All sub-items in display order, primary first.
    private var allItems: [ActionQueueItem] {
        [primary] + linked
    }

    /// A sub-item is actionable (Approve/Decline/Revise, counts toward
    /// "Approve all") only while pending. Declined/revision-requested items are
    /// shown greyed-out per the schema, with no live actions.
    private func isActionable(_ item: ActionQueueItem) -> Bool {
        item.status == .pending
    }

    /// Greyed-out sub-cards: declined or revision-requested stay visible but
    /// disabled within the composite.
    private func isDimmed(_ item: ActionQueueItem) -> Bool {
        item.status == .declined || item.status == .revisionRequested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CasaSpace.lg) {
                    header
                    ForEach(allItems) { item in
                        subCard(item)
                    }
                }
                .padding(.horizontal, CasaSpace.xl)
                .padding(.top, CasaSpace.lg)
                .padding(.bottom, CasaSpace.md)
            }

            Divider()
            bottomBar
        }
        .frame(width: CasaLayout.modalWidthXL)
        .frame(minHeight: 420)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    // MARK: - Header / bars

    private var header: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            Text(primary.title.isEmpty ? "Linked actions" : primary.title)
                .font(.title3.weight(.semibold))
                .padding(.trailing, CasaSpace.xxl)
            Text("\(allItems.count) linked actions · \(pendingCount) pending")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var pendingCount: Int {
        allItems.filter(isActionable).count
    }

    private var bottomBar: some View {
        HStack(spacing: CasaSpace.sm) {
            Spacer()
            Button("Approve all") {
                approveAll()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(pendingCount == 0)
        }
        .padding(CasaSpace.lg)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(CasaSpace.lg)
        .help("Close")
        .accessibilityLabel("Close")
    }

    // MARK: - Sub-card

    @ViewBuilder
    private func subCard(_ item: ActionQueueItem) -> some View {
        let dimmed = isDimmed(item)
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack(spacing: CasaSpace.sm) {
                Text(item.bucket?.displayName ?? "General")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                if item.id == primary.id {
                    CasaChip("Primary", tint: .accentPrimary)
                }
                Spacer()
                Text(ActionQueuePresentation.statusLabel(item.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ActionQueuePresentation.statusColor(item.status))
            }

            ActionCardView(item: item, editedBody: bodyBinding(for: item))

            if isActionable(item) {
                subCardActions(item)
            }
        }
        .padding(CasaSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CasaRadius.lg)
                .fill(Color.textTertiary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CasaRadius.lg)
                .stroke(Color.textTertiary.opacity(0.2))
        )
        .opacity(dimmed ? 0.5 : 1)
        .disabled(dimmed)
    }

    @ViewBuilder
    private func subCardActions(_ item: ActionQueueItem) -> some View {
        HStack(spacing: CasaSpace.sm) {
            Button("Decline") {
                model.decline(id: item.id)
            }
            .buttonStyle(.bordered)

            Button("Revise…") {
                revisionPrompt = ""
                revisingId = item.id
            }
            .buttonStyle(.bordered)
            .popover(isPresented: revisingBinding(for: item), arrowEdge: .top) {
                revisionComposer(for: item)
            }

            Spacer()

            Button("Approve") {
                approve(item)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func revisionComposer(for item: ActionQueueItem) -> some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            Text("Request a change")
                .font(.headline)
            TextField("How should the copilot re-draft this?", text: $revisionPrompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(CasaSpace.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .stroke(Color.textTertiary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Cancel") { revisingId = nil }
                    .buttonStyle(.bordered)
                Button("Send back") {
                    model.requestRevision(id: item.id, prompt: revisionPrompt)
                    revisingId = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(revisionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(CasaSpace.lg)
        .frame(width: 320)
    }

    // MARK: - Bindings & actions

    private func bodyBinding(for item: ActionQueueItem) -> Binding<String> {
        Binding(
            get: { editedBodies[item.id] ?? item.body },
            set: { editedBodies[item.id] = $0 }
        )
    }

    private func revisingBinding(for item: ActionQueueItem) -> Binding<Bool> {
        Binding(
            get: { revisingId == item.id },
            set: { if !$0 { revisingId = nil } }
        )
    }

    /// Approve one sub-item, passing the edited body only when it changed.
    private func approve(_ item: ActionQueueItem) {
        let edited = editedBodies[item.id]
        let trimmed = (edited == nil || edited == item.body) ? nil : edited
        model.approve(id: item.id, editedBody: trimmed)
    }

    /// Approve every still-pending sub-card, then dismiss.
    private func approveAll() {
        for item in allItems where isActionable(item) {
            approve(item)
        }
        onDismiss()
    }
}
