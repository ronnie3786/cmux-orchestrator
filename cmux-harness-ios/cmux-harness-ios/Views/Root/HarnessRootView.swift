import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HarnessRootView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @EnvironmentObject private var pushBridge: PushNotificationBridge

    var body: some View {
        Group {
            if store.isServerConfigured {
                NavigationSplitView {
                    WorkspaceListView(store: store)
                } detail: {
                    if let workspace = store.selectedWorkspace {
                        WorkspaceDetailView(store: store, workspace: workspace)
                    } else {
                        ZStack {
                            SessionDetailBackground()
                            ContentUnavailableView(
                                "No Session Selected",
                                systemImage: "terminal",
                                description: Text("Choose a cmux session.")
                            )
                            .foregroundStyle(.white)
                        }
                    }
                }
            } else {
                ServerSetupView(store: store)
            }
        }
        .overlay(alignment: .top) {
            if let banner = pushBridge.banner {
                PushApprovalBanner(
                    notification: banner,
                    openAction: {
                        openPushApproval(banner)
                    },
                    dismissAction: {
                        pushBridge.dismissBanner()
                    }
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .overlay {
            if let quickSessionCreation = store.quickSessionCreation {
                SessionCreationProgressOverlay(creation: quickSessionCreation)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(30)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pushBridge.banner?.id)
        .animation(.easeInOut(duration: 0.18), value: store.quickSessionCreation)
        .sheet(isPresented: $store.isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $store.isShowingNewSession) {
            NewSessionView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.isShowingFileSearch },
                set: { isPresented in
                    if !isPresented {
                        store.send(.dismissFileSearch)
                    }
                }
            )
        ) {
            FileSearchView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.isShowingJiraTickets },
                set: { isPresented in
                    if !isPresented {
                        store.send(.dismissJiraTickets)
                    }
                }
            )
        ) {
            JiraTicketsView(store: store)
        }
        .sheet(
            isPresented: Binding(
                get: { store.diffSheet != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.closeDiff)
                    }
                }
            )
        ) {
            if let diffSheet = store.diffSheet {
                DiffSheetView(store: store, diffSheet: diffSheet)
            }
        }
        .alert(
            "Rename Session",
            isPresented: Binding(
                get: { store.renameWorkspaceID != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.cancelRename)
                    }
                }
            )
        ) {
            TextField("Name", text: $store.renameText)
            Button("Save") {
                store.send(.commitRename)
            }
            Button("Cancel", role: .cancel) {
                store.send(.cancelRename)
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onDisappear {
            store.send(.onDisappear)
        }
        .onChange(of: pushBridge.pendingDeepLink) { _, notification in
            guard let notification else { return }
            openPushApproval(notification)
            pushBridge.pendingDeepLink = nil
        }
    }

    private func openPushApproval(_ notification: PushApprovalNotification) {
        store.send(.openPushApproval(notification))
        pushBridge.dismissBanner()
        PushNotificationBridge.clearApplicationBadge()
    }
}

struct DemoModeBanner: View {
    let exitAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)

            VStack(alignment: .leading, spacing: 1) {
                Text("Local Demo Mode")
                    .font(.caption.weight(.black))
                    .lineLimit(1)

                Text("Simulated data. No Mac is connected.")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: exitAction) {
                Text("Connect Real Server")
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.84), in: Capsule())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.orange,
                            Color.yellow.opacity(0.92),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }
}
