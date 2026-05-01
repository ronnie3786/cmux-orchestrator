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
