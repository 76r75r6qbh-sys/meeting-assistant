import SwiftUI

/// A consistent pill-style tag chip used across the inspector editor, sidebar
/// filter bar, sidebar rows, and search results so tag styling never drifts.
struct TagChip: View {
    let text: String
    /// When true the chip renders in its selected/active appearance.
    var isSelected: Bool = false
    /// When non-nil a small remove (×) button is shown and this is called on tap.
    var onRemove: (() -> Void)? = nil
    /// When non-nil the whole chip is tappable (e.g. filter toggle).
    var onTap: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: CasaSpace.xxs) {
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(text)")
            }
        }
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xxs)
        .foregroundStyle(isSelected ? Color.white : Color.textSecondary)
        .background(
            isSelected ? Color.accentColor : Color.backgroundTertiary,
            in: Capsule()
        )

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter by tag \(text)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }
}

/// A simple wrapping flow layout for chips that may overflow a single line
/// (used by the inspector tag editor). Lays children left-to-right, wrapping to
/// a new row when the available width is exceeded.
struct FlowLayout: Layout {
    var spacing: CGFloat = CasaSpace.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A read-only, wrapping-ish row of small tag chips for display (sidebar rows,
/// search results). Truncates with a "+N" when there are many, keeping rows tidy.
struct TagChipStrip: View {
    let tags: [String]
    var limit: Int = 3

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: CasaSpace.xxs) {
                ForEach(Array(tags.prefix(limit)), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, CasaSpace.xs)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.textTertiary)
                        .background(Color.backgroundTertiary, in: Capsule())
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
    }
}
