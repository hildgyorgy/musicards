//
//  DeckStyle.swift
//

#if os(macOS)
import SwiftUI

enum DeckStyle {

    // MARK: - Window geometry

    static let windowHeightRatio: CGFloat = 0.58
    static let minimumWindowHeight: CGFloat = 720
    static let windowWidthToHeightRatio: CGFloat = 0.46

    // MARK: - Deck geometry

    static let horizontalInset: CGFloat = 0
    static let topInset: CGFloat = 0
    static let titlebarHeight: CGFloat = 65
    static var cornerRadius: CGFloat {
        if #available(macOS 27.0, *) {
            return 18
        } else {
            return 24
        }
    }
    static let collapsedCardHeight: CGFloat = 45
    static let collapsedPlayerHeight: CGFloat = 58

    // MARK: - Glass surface

    static let glassMaterial: Material = .ultraThinMaterial
    static let glassHighlightColor: Color = .white
    static let glassMidColor: Color = .white
    static let glassBottomColor: Color = .white

    static let glassHighlightStrength: Double = 0.10
    static let glassMidStrength: Double = 0.03
    static let glassBottomStrength: Double = 0.22

    // MARK: - Borders

    static let strokeWidth: CGFloat = 1
    static let separatorStrength: Double = 0.3
    static let outerStrokeStrength: Double = 0.20

    static let strokeColor: Color = Color.primary.opacity(separatorStrength)

    // MARK: - Surfaces

    static let cardBackgroundColor: Color = .clear

    // MARK: - Card label

    static let cardLabelFontSize: CGFloat = 11
    static let cardLabelFontWeight: Font.Weight = .medium
    static let cardLabelTracking: CGFloat = 4
    static let cardLabelColor: Color = .secondary
    static let cardLabelHitHeight: CGFloat = collapsedCardHeight

    // MARK: - Expanded content layout

    static let headerTopSpacing: CGFloat = 20
    static let contentTopSpacing: CGFloat = 24
    static let contentHorizontalPadding: CGFloat = 32

    // MARK: - Animation

    static let animation = Animation.spring(
        response: 0.48,
        dampingFraction: 0.82
    )
    static let darkCardBackgroundColor = Color(.windowBackgroundColor).opacity(0.8)
    static let lightCardBackgroundColor = Color(.windowBackgroundColor).opacity(0.95)
    static let cardLabelFont = Font.system(size: 11, weight: .semibold)
    
    static let strokeDark = Color.white.opacity(0.15)
    static let strokeLight = Color.black.opacity(0.1)
}
#endif
