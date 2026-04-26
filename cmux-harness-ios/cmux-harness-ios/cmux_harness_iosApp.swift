//
//  cmux_harness_iosApp.swift
//  cmux-harness-ios
//
//  Created by Ronnie Rocha on 4/26/26.
//

import SwiftUI
import ComposableArchitecture

@main
struct cmux_harness_iosApp: App {
    var body: some Scene {
        WindowGroup {
            if TestContext.current == nil {
                ContentView(
                    store: Store(initialState: HarnessFeature.State()) {
                        HarnessFeature()
                    }
                )
            }
        }
    }
}
