// Casablanca/Views/ActionCards/ActionCardView.swift
import SwiftUI

/// Per-bucket approval-card router. Given an `ActionQueueItem` and a binding to
/// the sheet-owned `editedBody`, renders the bespoke card for the item's bucket,
/// falling back to the legacy plain-text editor for buckets without a card yet
/// (and for nil / `.unknown`).
///
/// Editing contract (see each card): a card parses `item.body` into a local
/// `@State` model and only writes back into `editedBody` once the user edits a
/// field — an untouched item therefore approves with `editedBody == item.body`
/// (→ nil edited body). On parse failure each card renders the legacy editor so
/// approval is never blocked.
struct ActionCardView: View {
    let item: ActionQueueItem
    @Binding var editedBody: String

    var body: some View {
        switch item.bucket {
        case .partnerApiReply:
            if let parsed = PartnerApiReplyBody(parsing: item.body) {
                PartnerApiReplyCard(item: item, model: parsed, editedBody: $editedBody)
            } else {
                legacy
            }
        case .topdeskResponse:
            if let parsed = TopdeskResponseBody(parsing: item.body) {
                TopdeskResponseCard(model: parsed, editedBody: $editedBody)
            } else {
                legacy
            }
        case .calendarEvent:
            if let parsed = CalendarEventBody(parsing: item.body) {
                CalendarEventCard(model: parsed, editedBody: $editedBody)
            } else {
                legacy
            }
        case .todo:
            TodoCard(item: item)
        case .ticketDraft, .refinementPrep, .roadmapCommitment:
            // TODO(T6): bespoke card — route to the legacy editor for now.
            legacy
        case .unknown, .none:
            legacy
        }
    }

    private var legacy: some View {
        LegacyDraftEditor(label: ActionCardView.legacyLabel(for: item), editedBody: $editedBody)
    }

    /// The legacy editor's label (each parsed/empty-state card owns its own
    /// header; this is only used by the `LegacyDraftEditor` fallback).
    static func legacyLabel(for item: ActionQueueItem) -> String {
        switch item.draftType {
        case .jira: return "Proposed comment"
        case .teams: return "Proposed message"
        case .calendar: return "Proposed event"
        case .topdesk: return "Proposed response"
        case .email, .other, .unknown, .none: return "Proposed reply"
        }
    }
}

// MARK: - Shared card UI

/// Small rounded capsule used across cards for recipients, invitees, attachments
/// and inline flags. Matches the detail sheet's tag styling.
struct CasaChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .accentSecondary

    init(_ text: String, systemImage: String? = nil, tint: Color = .accentSecondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: CasaSpace.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xxs)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// A labeled vertical block — caption header + body value — matching the detail
/// sheet's `labeledBlock` so cards stay visually consistent with the rest of the
/// sheet.
struct CardLabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An editable `TextEditor` styled to match the legacy draft editor — reused by
/// the parsed cards for their editable body/agenda/response fields.
struct CardBodyEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 180

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body))
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .padding(CasaSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(Color.accentSecondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .stroke(Color.textTertiary.opacity(0.3))
            )
    }
}

/// A wrapping row of chips. Reuses the shared `FlowLayout` (see TagChip.swift) so
/// chips flow onto new lines when they exceed the available width.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: CasaSpace.xs) { content }
    }
}

/// A single-line editable field styled like the revision composer's text field.
struct CardTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.xxs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(CasaSpace.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: CasaRadius.md)
                        .stroke(Color.textTertiary.opacity(0.3))
                )
        }
    }
}
