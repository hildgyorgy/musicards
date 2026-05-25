//
//  CardsApp.swift
//  Cards
//
//  Created by Hild György on 2026. 04. 05..
//

import SwiftUI

@main
struct CardsApp: App {
    var body: some Scene {
        #if os(macOS)
            WindowGroup {
                DeckWindow {
                    ContentView()
                }
            }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultSize(
                width: MacWindowMetrics.contentSize.width,
                height: MacWindowMetrics.contentSize.height
            )
        #else
            WindowGroup {
                ContentView()
            }
        #endif
    }
}
