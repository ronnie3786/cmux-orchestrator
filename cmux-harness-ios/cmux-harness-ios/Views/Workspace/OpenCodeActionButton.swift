import SwiftUI

struct OpenCodeActionButton: View {
    enum Role {
        case primary
        case secondary
        case destructive
        case neutral
        case attention
    }

    let title: String
    let systemImage: String
    let role: Role
    var fillsWidth = true
    var showsTitle = true
    let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: buttonRole, action: action) {
            Group {
                if showsTitle {
                    Label(title, systemImage: systemImage)
                } else {
                    Label(title, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                }
            }
                .font(.subheadline.bold())
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .fixedSize(horizontal: !fillsWidth, vertical: false)
                .background(backgroundColor, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                }
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.46)
        .accessibilityInputLabels([title])
    }

    private var foregroundColor: Color {
        switch role {
        case .primary:
            return .white
        case .secondary:
            return .blue
        case .destructive:
            return .red
        case .neutral:
            return .primary
        case .attention:
            return .orange
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .primary:
            return .blue
        case .secondary:
            return Color.blue.opacity(0.13)
        case .destructive:
            return Color.red.opacity(0.10)
        case .neutral:
            return Color.white.opacity(0.07)
        case .attention:
            return Color.orange.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary:
            return differentiateWithoutColor ? .white.opacity(0.8) : .clear
        case .secondary:
            return Color.blue.opacity(differentiateWithoutColor ? 0.9 : 0.34)
        case .destructive:
            return Color.red.opacity(differentiateWithoutColor ? 0.9 : 0.38)
        case .neutral:
            return Color.white.opacity(differentiateWithoutColor ? 0.5 : 0.14)
        case .attention:
            return Color.orange.opacity(differentiateWithoutColor ? 0.9 : 0.38)
        }
    }

    private var borderWidth: CGFloat {
        differentiateWithoutColor ? 1.5 : 1
    }

    private var buttonRole: ButtonRole? {
        switch role {
        case .destructive:
            return .destructive
        default:
            return nil
        }
    }
}
