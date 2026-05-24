//
//  MusiCardID.swift
//  MusiCards Release Viewer
//
//  Created by Hild György on 2026. 05. 24..
//

import Foundation

enum MusiCardID: Int, CaseIterable, Identifiable {
    case home = 0
    case search = 1
    case release = 2
    case tracks = 3
    case artist = 4

    var id: Int { rawValue }
    var slotIndex: Int { rawValue }
}
