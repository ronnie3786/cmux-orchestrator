import SwiftUI

struct CleanupRailChipsView: View {
    let codes: [String]

    var body: some View {
        CleanupFlowLayout(spacing: 5) {
            ForEach(codes, id: \.self) { code in
                Label(CleanupRail.label(for: code), systemImage: "shield.fill")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(HerdrTheme.alert.opacity(0.12))
                    .clipShape(.capsule)
            }
        }
    }
}
