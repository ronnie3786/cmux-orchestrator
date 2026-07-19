import SwiftUI

struct OpenCodeChoiceRow: View {
    let label: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                isSelected ? Color.blue.opacity(0.12) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected
                            ? Color.blue.opacity(differentiateWithoutColor ? 0.95 : 0.5)
                            : Color.white.opacity(differentiateWithoutColor ? 0.28 : 0.08),
                        lineWidth: differentiateWithoutColor ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(detail ?? "Selects this answer")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
