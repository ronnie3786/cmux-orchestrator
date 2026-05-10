import AppKit
import Foundation
import SwiftUI

@MainActor
enum RenderSmokeRunner {
    static func run(outputDirectory: String) -> Int32 {
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            let onboardingState = MacHarnessAppState()
            onboardingState.switchMode(.localDemo, supervisor: ServerSupervisor())
            let onboarding = MacOnboardingView(onboardingComplete: .constant(false))
                .environmentObject(onboardingState)
                .environmentObject(ServerSupervisor())
                .frame(width: 720, height: 980)
            try render(onboarding, to: outputURL.appendingPathComponent("onboarding.png"), size: CGSize(width: 720, height: 980))

            let dashboardState = MacHarnessAppState()
            let dashboardSupervisor = ServerSupervisor()
            dashboardState.switchMode(.localDemo, supervisor: dashboardSupervisor)
            let dashboard = DashboardRenderSmokeView()
                .environmentObject(dashboardState)
                .environmentObject(dashboardSupervisor)
                .frame(width: 1280, height: 820)
            try render(dashboard, to: outputURL.appendingPathComponent("dashboard-demo.png"), size: CGSize(width: 1280, height: 820))

            print("render-smoke ok: \(outputURL.path)")
            return 0
        } catch {
            fputs("render-smoke failed: \(error.localizedDescription)\n", stderr)
            return 5
        }
    }

    private static func render<V: View>(_ view: V, to url: URL, size: CGSize) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderSmokeError.bitmapFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderSmokeError.pngFailed
        }
        try data.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 10_000 else {
            throw RenderSmokeError.outputTooSmall(url.lastPathComponent)
        }
    }
}

enum RenderSmokeError: LocalizedError {
    case bitmapFailed
    case pngFailed
    case outputTooSmall(String)

    var errorDescription: String? {
        switch self {
        case .bitmapFailed:
            "Could not create bitmap renderer"
        case .pngFailed:
            "Could not encode PNG"
        case let .outputTooSmall(filename):
            "\(filename) rendered too small to be a valid UI capture"
        }
    }
}

struct DashboardRenderSmokeView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @State private var detailTab: DetailTab = .terminal
    @State private var inspectorTab: InspectorTab = .git

    var body: some View {
        VStack(spacing: 0) {
            ServerHealthStrip()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 300)
                Divider()
                VStack(spacing: 0) {
                    DetailToolbar(detailTab: $detailTab)
                    Divider()
                    TerminalDetailView()
                }
                Divider()
                InspectorView(selectedTab: $inspectorTab)
                    .frame(width: 390)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(appState)
        .environmentObject(supervisor)
    }
}
