//
//  DeckWindow.swift
//

import SwiftUI

struct DeckWindow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: MacWindowMetrics.contentSize.width,
                height: MacWindowMetrics.contentSize.height
            )
            .background(WindowAccessor())
    }
}
