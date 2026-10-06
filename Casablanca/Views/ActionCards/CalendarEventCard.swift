// Casablanca/Views/ActionCards/CalendarEventCard.swift
import SwiftUI

/// Small calendar-card for the `calendar_event` bucket. Shows a prominent date +
/// time, invitee chips, location as subtitle, and an editable agenda + subject.
struct CalendarEventCard: View {
    @State private var model: CalendarEventBody
    @Binding var editedBody: String

    init(model: CalendarEventBody, editedBody: Binding<String>) {
        _model = State(initialValue: model)
        _editedBody = editedBody
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            // Prominent date + time.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .foregroundStyle(Color.accentPrimary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.dateText ?? model.whenRaw)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        if let time = model.timeRange {
                            Text(time)
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                if let location = model.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(CasaSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CasaRadius.md)
                    .fill(Color.accentPrimary.opacity(0.08))
            )

            // Subject — editable.
            CardTextField(label: "Subject", text: $model.subject)

            // Invitees as chips.
            if !model.invitees.isEmpty {
                VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                    Text("Invitees")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    FlowChips {
                        ForEach(model.invitees, id: \.self) { invitee in
                            CasaChip(invitee, systemImage: "person")
                        }
                    }
                }
            }

            // Agenda — editable.
            VStack(alignment: .leading, spacing: CasaSpace.xxs) {
                Text("Agenda · editable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                CardBodyEditor(text: $model.agenda, minHeight: 120)
            }
        }
        .onChange(of: model) { _, newValue in
            editedBody = newValue.serialized()
        }
    }
}
