//
//  AppStyle.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 25..
//

import SwiftUI

enum AppStyle {
    
    #if os(iOS)
    
    // MARK: - Animation
    
    static let animation = Animation.spring(response: 0.32, dampingFraction: 0.82)
    
    // MARK: - Card appearance
    
    static let boxBackgroundLight: Color = Color(UIColor.secondarySystemBackground)
    static let boxBackgroundDark: Color = Color(UIColor.systemBackground)
    
    static let lightCardBackgroundColor: Color = Color(UIColor.systemBackground)
    static let darkCardBackgroundColor: Color = Color(UIColor.secondarySystemBackground)
    
    static let cardLabelFont: Font = .caption.weight(.medium)
    static let cardLabelTracking: CGFloat = 4
    
    static let strokeLight = Color.black.opacity(0.2)
    static let strokeDark: Color = Color(UIColor.opaqueSeparator)
    
    // MARK: - Expanded content layout
    
    static let headerSpacing: CGFloat = 6
    static let headerTopSpacing: CGFloat = 20
    
    static let contentTopSpacing: CGFloat = 24
    static let contentHorizontalPadding: CGFloat = 32
    
    static let contentBackgroundLight: Color = Color(UIColor.secondarySystemFill)
    static let contentBackgroundDark: Color = Color(UIColor.secondarySystemFill)
    
    // MARK: - Expanded content typography
    
    static let primaryHeaderFont: Font = .title2
    static let secondaryHeaderFont: Font = .body
    
    #endif

    #if os(macOS)
    
    // MARK: - Animation

    static let animation = Animation.spring(response: 0.48, dampingFraction: 0.82)
    
    // MARK: - Card appearance
    
    static let cornerRadius: CGFloat = 35
    
    static let darkCardBackgroundColor = Color(.windowBackgroundColor).opacity(0.8)
    static let lightCardBackgroundColor = Color(.windowBackgroundColor).opacity(0.95)
    
    static let boxBackgroundDark = Color.black.opacity(0.25)
    static let boxBackgroundLight = Color.white.opacity(0.25)
    
    static let strokeDark = Color.white.opacity(0.15)
    static let strokeLight = Color.black.opacity(0.1)
    
    // MARK: - Expanded content typography
    
    static let titleFontSize: CGFloat = 40
    static let titleFontWeight: Font.Weight = .bold
    static let titleColor: Color = .primary

    static let subtitleFontSize: CGFloat = 20
    static let subtitleFontWeight: Font.Weight = .regular
    static let subtitleColor: Color = .blue
    
    static let primaryHeaderFont: Font = .title2
    static let secondaryHeaderFont: Font = .title3
    
    static let cardLabelFont = Font.system(size: 11, weight: .semibold)
    static let cardLabelTracking: CGFloat = 4
    
    // MARK: - Expanded content layout
    
    static let headerTopSpacing: CGFloat = 20
    static let headerSpacing: CGFloat = 8
    
    static let contentTopSpacing: CGFloat = 24
    static let contentHorizontalPadding: CGFloat = 32
    
    #endif
}
