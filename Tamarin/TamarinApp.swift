//
//  TamarinApp.swift
//  Tamarin
//
//  Created by Manav Bokinala on 8/27/26.
//

import SwiftUI

@main
struct TamarinApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1220, height: 780)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
