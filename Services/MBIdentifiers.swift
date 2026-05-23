//
//  MBIdentifiers.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 22..
//

import Foundation

enum MBIdentifiers {
    static func isMBID(_ text: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func isBareBarcode(_ text: String) -> Bool {
        text.allSatisfy(\.isNumber) && text.count >= 8
    }
}
