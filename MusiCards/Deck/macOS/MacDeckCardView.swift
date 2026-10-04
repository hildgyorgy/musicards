//
//  DeckCardView.swift
//

#if os(macOS)
import SwiftUI

struct DeckCardView<ID: Hashable, CollapsedHeaderContent: View, HeaderContent: View, CardContent: View>: View {
    let card: DeckCard<ID>
    let isActive: Bool
    let allowsWindowDragging: Bool
    let showsCollapsedHeader: Bool
    let onTap: () -> Void
    let collapsedHeader: CollapsedHeaderContent
    let header: HeaderContent
    let content: CardContent

    init(
        card: DeckCard<ID>,
        isActive: Bool,
        allowsWindowDragging: Bool,
        showsCollapsedHeader: Bool,
        onTap: @escaping () -> Void,
        @ViewBuilder collapsedHeader: () -> CollapsedHeaderContent,
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder content: () -> CardContent
    ) {
        self.card = card
        self.isActive = isActive
        self.allowsWindowDragging = allowsWindowDragging
        self.showsCollapsedHeader = showsCollapsedHeader
        self.onTap = onTap
        self.collapsedHeader = collapsedHeader()
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
            headerInteraction

            if isShowingCollapsedHeader {
                collapsedHeader
                    .transition(.opacity)
            } else {
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
                    .allowsHitTesting(false)
            }
        }
        .frame(height: cardHeaderHeight)
    }

    @ViewBuilder
    private var headerInteraction: some View {
        if allowsWindowDragging {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
                .onHover { isHoveringLabel = $0 }
        } else {
            PanHandleView(
                isEnabled: true,
                onTap: onTap,
                onBegan: nil,
                onChanged: { _ in },
                onEnded: { _, _ in }
            )
            .contentShape(Rectangle())
            .onHover { isHoveringLabel = $0 }
        }
    }

    private var isShowingCollapsedHeader: Bool {
        !isActive && showsCollapsedHeader
    }

    private var cardHeaderHeight: CGFloat {
        isShowingCollapsedHeader
            ? DeckStyle.collapsedPlayerHeight
            : DeckStyle.cardLabelHitHeight
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
