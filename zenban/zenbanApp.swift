//
//  zenbanApp.swift
//  zenban
//
//  Created by Berkay Çit on 25.12.2025.
//

import SwiftUI

@main
struct zenbanApp: App {
    @State private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .commands {
            BoardCommands(store: store)
        }
    }
}
