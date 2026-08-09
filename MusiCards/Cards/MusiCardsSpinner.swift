//
//  MusiCardsSpinner.swift
//

import SwiftUI

struct MusiCardsSpinner: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.blue)
            .frame(width: 40, height: 40)

#if os(iOS)
            .background(
                Circle()
                    .fill(
                        colorScheme == .dark
                            ? AppStyle.darkCardBackgroundColor
                            : AppStyle.lightCardBackgroundColor
                    )
                    .shadow(
                        color: .black.opacity(0.1),
                        radius: 10,
                        x: 2,
                        y: 2
                    )
            )
#endif
    }
}
