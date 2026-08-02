//
//  ClassicalTrackFormatter.swift
//  MusiCards
//
//  Ported from MBViewer. Logic unchanged.
//

import Foundation

private struct ClassicalTitleSplit {
    let workLine: String
    let movLine: String
}

private struct ColonSplit {
    let left: String
    let right: String
}

private struct PreparedTrackTitle {
    let track: MBTrack
    let rawTitle: String
    let baseWork: String
    let baseMov: String
    let hasColon: Bool
    let colonWork: String
    let colonMov: String
}

enum TrackDisplayRow: Hashable {
    case composerHeader(String)
    case workHeader(String)
    case track(
        releaseTrackID: String?,
        position: Int?,
        title: String,
        length: String?,
        recordingID: String?,
        isMovement: Bool
    )
}

enum ClassicalTrackFormatter {

    static func buildRows(
        from tracks: [MBTrack],
        composerForTrack: ((MBTrack) -> String?)? = nil
    ) -> [TrackDisplayRow] {
        let prepared = prepareTracks(tracks)
        let runLengths = computeRunLengths(prepared)

        var rows: [TrackDisplayRow] = []
        var lastWork = ""
        var lastComposer = ""

        for (index, item) in prepared.enumerated() {
            let hasBaseSplit = !item.baseWork.isEmpty && !item.baseMov.isEmpty
            let runLength = runLengths[index]

            var usedColonGate = false
            var workLine = item.baseWork
            var movLine = item.baseMov

            if !hasBaseSplit,
               item.hasColon,
               !item.colonWork.isEmpty,
               !item.colonMov.isEmpty,
               runLength >= 2 {
                usedColonGate = true
                workLine = item.colonWork
                movLine = item.colonMov
            }

            let work = workLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let mov = movLine.trimmingCharacters(in: .whitespacesAndNewlines)

            let isClassicalGroup = hasBaseSplit || usedColonGate
            let showWorkHeader = isClassicalGroup && !work.isEmpty && work != lastWork

            if showWorkHeader {
                let composer = cleaned(composerForTrack?(item.track))

                if !composer.isEmpty && composer != lastComposer {
                    rows.append(.composerHeader(composer))
                    lastComposer = composer
                }

                rows.append(.workHeader(work))
                lastWork = work
            }

            let visibleTitle = (isClassicalGroup && !mov.isEmpty) ? mov : item.rawTitle

            rows.append(
                .track(
                    releaseTrackID: item.track.id,
                    position: item.track.position,
                    title: visibleTitle,
                    length: formatTrackLength(item.track.length),
                    recordingID: item.track.recording?.id,
                    isMovement: isClassicalGroup && !mov.isEmpty
                )
            )
        }

        return rows
    }

    private static func splitClassicalTitle(_ raw: String) -> ClassicalTitleSplit {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            return ClassicalTitleSplit(workLine: "", movLine: "")
        }

        let t = normalizeWhitespace(s)

        if let colonIndex = t.firstIndex(of: ":") {
            let left = String(t[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(t[t.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            let romanPattern = #"^([IVXLCDM]{1,7})\s*[.:]\s+"#
            if right.range(of: romanPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return ClassicalTitleSplit(workLine: left, movLine: right)
            }
        }

        return ClassicalTitleSplit(workLine: t, movLine: "")
    }

    private static func splitFirstColon(_ raw: String) -> ColonSplit? {
        let s = String(raw)
        guard let colonIndex = s.firstIndex(of: ":") else { return nil }

        let left = String(s[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(s[s.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return ColonSplit(left: left, right: right)
    }

    private static func prepareTracks(_ tracks: [MBTrack]) -> [PreparedTrackTitle] {
        tracks.map { track in
            let rawTitle = String(track.title).trimmingCharacters(in: .whitespacesAndNewlines)

            let base = splitClassicalTitle(rawTitle)
            let colon = splitFirstColon(rawTitle)

            return PreparedTrackTitle(
                track: track,
                rawTitle: rawTitle,
                baseWork: base.workLine.trimmingCharacters(in: .whitespacesAndNewlines),
                baseMov: base.movLine.trimmingCharacters(in: .whitespacesAndNewlines),
                hasColon: colon != nil,
                colonWork: colon?.left.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                colonMov: colon?.right.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }

    private static func computeRunLengths(_ prepared: [PreparedTrackTitle]) -> [Int] {
        var runLengths = Array(repeating: 0, count: prepared.count)
        var i = 0

        while i < prepared.count {
            let current = prepared[i]

            if !current.hasColon || current.colonWork.isEmpty {
                runLengths[i] = 0
                i += 1
                continue
            }

            let work = current.colonWork
            var j = i + 1

            while j < prepared.count,
                  prepared[j].hasColon,
                  !prepared[j].colonWork.isEmpty,
                  prepared[j].colonWork == work {
                j += 1
            }

            let runLength = j - i
            for k in i..<j {
                runLengths[k] = runLength
            }

            i = j
        }

        return runLengths
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func formatTrackLength(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }

        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        return String(format: "%d:%02d", minutes, seconds)
    }
}
