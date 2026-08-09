import Foundation

nonisolated struct RsyncVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    var displayString: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: RsyncVersion, rhs: RsyncVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) <
            (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated struct RsyncVersionInfo: Equatable, Sendable {
    let version: RsyncVersion
    let displayLine: String
    let supportsIconv: Bool
}

nonisolated enum RsyncRequirements {
    static let localMinimum = RsyncVersion(major: 3, minor: 2, patch: 6)
    static let remoteMinimum = RsyncVersion(major: 3, minor: 1, patch: 0)
}

nonisolated struct RsyncVersionParser: Sendable {
    func parse(_ output: String) -> RsyncVersionInfo? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)

        guard let displayLine = lines.first(where: {
            $0.range(of: #"rsync\s+version\s+\d+\.\d+\.\d+"#,
                     options: .regularExpression) != nil
        }) else {
            return nil
        }

        let pattern = #"rsync\s+version\s+(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(displayLine.startIndex..<displayLine.endIndex,
                            in: displayLine)
        guard let match = regex.firstMatch(in: displayLine, range: range),
              let major = integer(at: 1, match: match, in: displayLine),
              let minor = integer(at: 2, match: match, in: displayLine),
              let patch = integer(at: 3, match: match, in: displayLine) else {
            return nil
        }

        return RsyncVersionInfo(
            version: RsyncVersion(major: major, minor: minor, patch: patch),
            displayLine: displayLine,
            supportsIconv: capabilities(from: lines).contains("iconv")
        )
    }

    private func integer(
        at index: Int,
        match: NSTextCheckingResult,
        in text: String
    ) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else {
            return nil
        }

        return Int(text[range])
    }

    private func capabilities(from lines: [String]) -> Set<String> {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "Capabilities:"
        }) else {
            return []
        }

        var words: Set<String> = []

        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasSuffix(":"), !trimmed.contains(",") {
                break
            }

            for item in trimmed.split(separator: ",") {
                let capability = item
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()

                if capability == "iconv" {
                    words.insert(capability)
                }
            }
        }

        return words
    }
}
