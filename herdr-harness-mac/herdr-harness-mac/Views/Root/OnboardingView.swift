import SwiftUI

struct OnboardingView: View {
    @Bindable var model: HerdrAppModel
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    brand
                    promise
                    connectionCard
                    demoButton
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var brand: some View {
        HStack(spacing: 14) {
            HerdrBrandMark(size: 58)

            VStack(alignment: .leading, spacing: 1) {
                Text("herdr")
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)
                Text("Your agents, within reach")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }

    private var promise: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Know where to look.")
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
            Text("Move from workspace to pane to live agent in seconds. Herdr keeps the terminals real; this app keeps the decisions close.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                Label("Connect to your Mac", systemImage: "macbook.and.iphone")
                    .font(.headline.bold())

                TextField("https://your-mac.tailnet.ts.net", text: $model.serverURLString)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .url)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .token }
                    .padding(14)
                    .background(.black.opacity(0.24), in: .rect(cornerRadius: 12))

                SecureField("Pairing token", text: $model.apiToken)
                    .textContentType(.password)
                    .focused($focusedField, equals: .token)
                    .submitLabel(.go)
                    .onSubmit(model.connect)
                    .padding(14)
                    .background(.black.opacity(0.24), in: .rect(cornerRadius: 12))

                Button("Connect", systemImage: "bolt.horizontal.circle.fill", action: model.connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Label("Use localhost when Herdr runs on this Mac, or the private HTTPS URL from tailscale serve status for another Mac. The token stays in Keychain.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
    }

    private var demoButton: some View {
        Button("Explore with live-looking demo data", systemImage: "sparkles", action: model.useDemo)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Opens the app without connecting to a Mac")
    }
}

private extension OnboardingView {
    enum Field: Hashable {
        case url
        case token
    }
}
