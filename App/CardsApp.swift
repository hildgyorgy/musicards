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
            ContentView()
                .frame(
                    width: MacWindowMetrics.contentSize.width,
                    height: MacWindowMetrics.contentSize.height
                )
                .containerBackground(.clear, for: .window)
                .background(WindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
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
