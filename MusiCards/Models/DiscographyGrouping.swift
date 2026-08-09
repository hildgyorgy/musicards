//
//  DiscographyGrouping.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import Foundation

struct DiscographySection: Identifiable {
    let title: String
    let items: [MBReleaseGroupSummary]

    var id: String { title }
}

func groupedDiscographySections(from releaseGroups: [MBReleaseGroupSummary]) -> [DiscographySection] {
    let filtered = releaseGroups.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    let grouped = Dictionary(grouping: filtered) { group in
        releaseGroupCategory(group)
    }

    let preferredOrder = [
        "Album", "Album + Live",
        "EP", "EP + Live",
        "Single", "Single + Live",
        "Compilation", "Compilation + Live",
        "Soundtrack", "Soundtrack + Live",
        "Live", "Remix", "Remix + Live",
        "DJ Mix", "DJ Mix + Live",
        "Mixtape", "Mixtape + Live",
        "Demo", "Demo + Live",
        "Broadcast", "Broadcast + Live",
        "Other"
    ]

    return preferredOrder.compactMap { title in
        guard let items = grouped[title], !items.isEmpty else { return nil }

        let sorted = items.sorted {
            ($0.firstReleaseDate ?? "") > ($1.firstReleaseDate ?? "")
        }

        return DiscographySection(title: title, items: sorted)
    }
}

private func releaseGroupCategory(_ group: MBReleaseGroupSummary) -> String {
    let primary = group.primaryType?.trimmingCharacters(in: .whitespacesAndNewlines)
    let secondary = Set(group.secondaryTypes ?? [])

    let base = primary?.isEmpty == false ? primary! : "Other"

    if secondary.contains("Live") && base != "Live" {
        return "\(base) + Live"
    }

    if preferredStandaloneLiveCategory(primary: primary, secondary: secondary) {
        return "Live"
    }

    return base
}

private func preferredStandaloneLiveCategory(primary: String?, secondary: Set<String>) -> Bool {
    if primary == "Live" { return true }
    if primary == nil && secondary.contains("Live") { return true }
    return false
}
