//
//  MusicLibraryIndexError.swift
//  MusiCards Shared
//

import Foundation

nonisolated struct MusicLibraryIndexError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
