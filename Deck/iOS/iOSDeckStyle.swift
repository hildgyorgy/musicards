//
//  DeckStyle.swift
//

#if os(iOS)
import SwiftUI

enum DeckStyle {
    
    // MARK: - Geometry 

    static var horizontalInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8
    }

    static let maximumPadCardWidth: CGFloat = 600
    static let minimumPadHorizontalMargin: CGFloat = 8

    static let expandedTopInset: CGFloat = 0
    static let cardBottomInset: CGFloat = 8

    static let peek: CGFloat = 36

    // MARK: - Card shape

    static let topCornerRadius: CGFloat = 35

    static func bottomCornerRadius(
        viewportWidth: CGFloat,
        viewportSafeAreaTop: CGFloat,
        viewportSafeAreaBottom: CGFloat
    ) -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return topCornerRadius
        }

        let cardInset = max(horizontalInset, cardBottomInset)
        let estimatedViewportRadius: CGFloat

        if viewportSafeAreaTop > 30 {
            estimatedViewportRadius = viewportSafeAreaTop
        } else if viewportSafeAreaBottom > 0 {
            estimatedViewportRadius = viewportWidth * 0.148
        } else {
            estimatedViewportRadius = topCornerRadius + cardInset
        }

        return max(topCornerRadius, estimatedViewportRadius - cardInset)
    }

    // MARK: - Card border

    static let strokeLight = Color.black.opacity(0.2)
    static let strokeDark: Color = Color(UIColor.opaqueSeparator)
    static let strokeWidth: CGFloat = 1

    // MARK: - Card shadow

    static let shadowColor: Color = .black.opacity(0.25)
    static let shadowRadius: CGFloat = 8
    static let shadowYOffset: CGFloat = 2

    // MARK: - Card label

    static let cardLabelFont: Font = .caption.weight(.medium)
    static let cardLabelTracking: CGFloat = 4
    static let cardLabelTopPadding: CGFloat = 12
    static let cardLabelColor: Color = .secondary
    static let cardLabelHitHeight: CGFloat = 56
    static let collapsedPlayerHeight: CGFloat = 92
    
    // MARK: - Header

    static let headerSpacing: CGFloat = 6
    static let headerTopSpacing: CGFloat = 20
    static let contentTopSpacing: CGFloat = 24
    static let contentHorizontalPadding: CGFloat = 32

    // MARK: - Interaction

    static let dragThreshold: CGFloat = 80

    // MARK: - Animation

    static let animation = Animation.spring(response: 0.32, dampingFraction: 0.82)

    // MARK: - Container (box / base)

    static let boxBackgroundLight: Color = Color(UIColor.secondarySystemBackground)
    static let boxBackgroundDark: Color = Color(UIColor.systemBackground)

    // MARK: - Card background

    static let lightCardBackgroundColor: Color = Color(UIColor.systemBackground)
    static let darkCardBackgroundColor: Color = Color(UIColor.secondarySystemBackground)

    // MARK: - Content area

    static let contentBackgroundLight: Color = Color(UIColor.secondarySystemFill)
    static let contentBackgroundDark: Color = Color(UIColor.secondarySystemFill)
    
    static let primaryHeaderFont: Font = .title2
    static let secondaryHeaderFont: Font = .body

}
#endif
