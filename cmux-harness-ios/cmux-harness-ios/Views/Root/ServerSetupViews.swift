import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ServerSetupView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        ZStack {
            ServerSetupBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("cmux Harness")
                            .font(.caption.weight(.heavy))
                            .tracking(1.8)
                            .textCase(.uppercase)
                            .foregroundStyle(.green.opacity(0.8))

                        Text("Connect to your Mac.")
                            .font(.system(size: 46, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.72)

                        Text("Start dashboard.py on your Mac. The app will try a saved Tailscale host first, then scan the LAN for the Bonjour service.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Server URL")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)

                        TextField("http://macbook.local:9091/harness", text: $store.serverURLString)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                            }
                            .foregroundStyle(.white)

                        Button {
                            store.send(.saveServerTapped)
                        } label: {
                            Label("Save Server URL", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ServerSetupPrimaryButtonStyle())
                    }
                    .padding(18)
                    .background(ServerSetupCard())

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Optional Tailscale")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Enter your Mac's MagicDNS host if you want remote access outside your Wi-Fi network. Use a stable Tailscale machine name so this URL does not change when your Mac hostname changes.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))

                        TextField("your-mac.your-tailnet.ts.net", text: $store.tailscaleHostString)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                            }
                            .foregroundStyle(.white)

                        HStack(spacing: 12) {
                            Button {
                                store.send(.probeTailscaleHostTapped)
                            } label: {
                                Label("Try Tailscale", systemImage: "network")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ServerSetupSecondaryButtonStyle())

                            Button {
                                store.send(.discoverServer)
                            } label: {
                                Label("Scan LAN", systemImage: "dot.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ServerSetupSecondaryButtonStyle())
                        }
                    }
                    .padding(18)
                    .background(ServerSetupCard())

                    if store.isDiscoveringServer {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text(store.serverSetupMessage ?? "Looking for server...")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.82))
                    } else if let message = store.serverSetupMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    if let error = store.serverSetupError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !store.discoveredServers.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Discovered servers")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                            ForEach(store.discoveredServers) { server in
                                Button {
                                    store.send(.useDiscoveredServer(server))
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(server.name)
                                                .font(.subheadline.weight(.bold))
                                            Text(server.urlString)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.white.opacity(0.62))
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle.fill")
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ServerSetupBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.08, blue: 0.07),
                Color(red: 0.08, green: 0.17, blue: 0.13),
                Color(red: 0.24, green: 0.18, blue: 0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Circle()
                .fill(Color.green.opacity(0.18))
                .blur(radius: 60)
                .frame(width: 240, height: 240)
                .offset(x: -150, y: -220)
        }
        .overlay {
            Circle()
                .fill(Color.orange.opacity(0.16))
                .blur(radius: 70)
                .frame(width: 280, height: 280)
                .offset(x: 170, y: 260)
        }
    }
}

struct ServerSetupCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            }
    }
}

struct ServerSetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .background(Color.green.opacity(configuration.isPressed ? 0.75 : 0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ServerSetupSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
    }
}

struct SessionCreationProgressOverlay: View {
    let creation: QuickSessionCreation

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.08)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 330)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 14)
            .padding(24)
        }
    }

    private var title: String {
        switch creation.phase {
        case .creating:
            return "Starting New Session"
        case .switching:
            return "Opening New Session"
        }
    }

    private var message: String {
        switch creation.phase {
        case .creating:
            let directory = creation.directoryPath.abbreviatedPath(componentCount: 3)
            return "Creating a shell session in \(directory). We'll switch you over when it's ready."
        case .switching:
            return "The session is ready. Switching you over now."
        }
    }
}

struct PushApprovalBanner: View {
    let notification: PushApprovalNotification
    let openAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: openAction) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(notification.workspaceName.isEmpty ? "Approval needed" : notification.workspaceName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(notification.request.isEmpty ? notification.reason : notification.request)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(3)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss approval notification")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 10)
    }
}
