import SwiftUI

@main
struct HerdrHarnessApp: App {
    @UIApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var model = HerdrAppModel()
    @State private var herdPulse = HerdPulseCoordinator()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .environment(herdPulse)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
        }
    }
}
