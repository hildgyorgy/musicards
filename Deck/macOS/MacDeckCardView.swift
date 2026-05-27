//
//  DeckCardView.swift
//

#if os(macOS)
import SwiftUI

struct DeckCardView<ID: Hashable, HeaderContent: View, CardContent: View>: View {
    let card: DeckCard<ID>
    let isActive: Bool
    let onTap: () -> Void
    let header: HeaderContent
    let content: CardContent

    init(
        card: DeckCard<ID>,
        isActive: Bool,
        onTap: @escaping () -> Void,
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder content: () -> CardContent
    ) {
        self.card = card
        self.isActive = isActive
        self.onTap = onTap
        self.header = header()
        self.content = content()
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringLabel = false

    var cardBackground: Color {
        DeckStyle.cardBackgroundColor
    }

    var contentBackground: Color {
        DeckStyle.contentBackgroundColor
    }

    var strokeColor: Color {
        DeckStyle.strokeColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader

            if isActive {
                cardExpandedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(cardBackground)
        .overlay(
            Rectangle()
                .frame(height: DeckStyle.strokeWidth)
                .foregroundStyle(strokeColor),
            alignment: .bottom
        )
    }
    
    private var cardHeader: some View {
        ZStack {
            Text(card.cardLabel.uppercased())
                .font(.system(size: DeckStyle.cardLabelFontSize, weight: DeckStyle.cardLabelFontWeight))
                .tracking(DeckStyle.cardLabelTracking)
                .foregroundStyle(
                    isHoveringLabel
                           ? .blue
                           : (isActive ? .primary : DeckStyle.cardLabelColor)
                )
                .animation(.easeOut(duration: 0.12), value: isHoveringLabel)
                .frame(maxWidth: .infinity, alignment: .center)

            PanHandleView(
                isEnabled: true,
                onTap: onTap,
                onBegan: nil,
                onChanged: { _ in },
                onEnded: { _, _ in }
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringLabel = hovering
            }
        }
        .frame(height: DeckStyle.cardLabelHitHeight)
    }

    private var cardExpandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: DeckStyle.headerTopSpacing)
            header
                .padding(.horizontal, DeckStyle.contentHorizontalPadding)
            Spacer().frame(height: DeckStyle.contentTopSpacing)
            content
                .padding(.horizontal, DeckStyle.contentHorizontalPadding)
        }
    }
}
#endif
