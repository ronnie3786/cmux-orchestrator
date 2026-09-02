import SwiftUI

struct HerdrSectionLabel: View {
    let title: String
    var detail: String?
    var monospaced = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.lowercased())
                .bold()
                .underline()
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .font(monospaced ? .subheadline.monospaced() : .subheadline)
        .foregroundStyle(HerdrTheme.mist)
        .accessibilityElement(children: .combine)
    }
}
