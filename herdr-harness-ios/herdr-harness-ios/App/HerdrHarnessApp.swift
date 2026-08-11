import SwiftUI

@main
struct HerdrHarnessApp: App {
    @UIApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate
    @State private var model = HerdrAppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView(model: model)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
        }
    }
}
