//
//  MacWindowMetrics.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 19..
//

import AppKit

enum MacWindowMetrics {
    static var contentSize: NSSize {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = max(
            screenHeight * DeckStyle.windowHeightRatio,
            DeckStyle.minimumWindowHeight
        )
        let width = height * DeckStyle.windowWidthToHeightRatio

        return NSSize(width: width, height: height)
    }
}

