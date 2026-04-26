//
//  ContentView.swift
//  cmux-harness-ios
//
//  Created by Ronnie Rocha on 4/26/26.
//

import SwiftUI
import ComposableArchitecture

struct ContentView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        HarnessRootView(store: store)
    }
}

#Preview {
    ContentView(
        store: Store(initialState: HarnessFeature.State()) {
            HarnessFeature()
        }
    )
}
