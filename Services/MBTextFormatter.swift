//
//  MBTextFormatter.swift.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 16..
//

import Foundation

nonisolated enum MBTextFormatter {
    static func year(from text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return String(text.prefix(4))
    }

    static func lifeSpanText(from lifeSpan: MBLifeSpan?) -> String? {
        let begin = year(from: lifeSpan?.begin)
        let end = year(from: lifeSpan?.end)

        guard !begin.isEmpty || !end.isEmpty else { return nil }
        return "\(begin)–\(end)"
    }

    static func lifeSpanTextOrEmpty(from lifeSpan: MBLifeSpan?) -> String {
        lifeSpanText(from: lifeSpan) ?? ""
    }
    
    static func displayDate(from text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        
        let formats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                switch format {
                case "yyyy-MM-dd":
                    formatter.dateStyle = .medium
                    formatter.dateFormat = nil
                    return formatter.string(from: date)
                case "yyyy-MM":
                    formatter.dateFormat = "MMMM yyyy"
                    return formatter.string(from: date)
                default:
                    return text
                }
            }
        }
        return text
    }
    
    static func releaseMetaLine(
        year: String?,
        country: String?,
        label: String?,
        format: String?
    ) -> String {
        [
            year,
            country,
            label,
            format
        ]
        .compactMap { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
        .joined(separator: " • ")
    }
    
    static func artistLine(from artistCredit: [MBArtistCredit]?) -> String {
        artistCredit?.compactMap { $0.name }.joined(separator: ", ") ?? ""
    }
}
