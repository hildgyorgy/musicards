//
//  ArtistCreditLinksView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 08..
//

import SwiftUI

struct ArtistCreditLinksView: View {
    let artistCredits: [MBArtistCredit]?
    let onSelectArtist: (String) -> Void
    var maxLines: Int = 2

    private let tokenSpacing: CGFloat = 0
    private let lineSpacing: CGFloat = 0

    var body: some View {
        if let artistCredits, !artistCredits.isEmpty {
            InlineWrapLayout(spacing: tokenSpacing, lineSpacing: lineSpacing) {
                ForEach(tokens(from: artistCredits)) { token in
                    tokenView(token)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    private var maxHeightForCurrentFont: CGFloat {
        let lineHeight: CGFloat
        #if canImport(UIKit)
        lineHeight = UIFont.preferredFont(forTextStyle: .title3).lineHeight
        #else
        lineHeight = NSFont.preferredFont(forTextStyle: .title3).pointSize * 1.2
        #endif
        return lineHeight * CGFloat(maxLines)
    }
    
    private func tokenView(_ token: ArtistCreditToken) -> some View {
        Group {
            switch token.kind {
            case .artist(let id):
                Button {
                    onSelectArtist(id)
                } label: {
                    Text(token.text)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)

            case .text:
                Text(token.text)
                    .foregroundStyle(.primary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tokens(from credits: [MBArtistCredit]) -> [ArtistCreditToken] {
        var result: [ArtistCreditToken] = []

        for (index, credit) in credits.enumerated() {
            if let artistID = credit.artist?.id {
                result.append(
                    ArtistCreditToken(
                        text: credit.name,
                        kind: .artist(artistID)
                    )
                )
            } else {
                result.append(
                    ArtistCreditToken(
                        text: credit.name,
                        kind: .text
                    )
                )
            }

            if index < credits.count - 1 {
                let join = credit.joinPhrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if join.isEmpty {
                    result.append(ArtistCreditToken(text: ", ", kind: .text))
                } else {
                    result.append(ArtistCreditToken(text: join, kind: .text))
                }
            }
        }

        return result
    }
}

private struct ArtistCreditToken: Identifiable {
    enum Kind {
        case artist(String)
        case text
    }

    let id = UUID()
    let text: String
    let kind: Kind
}

private struct InlineWrapLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    init(spacing: CGFloat = 0, lineSpacing: CGFloat = 0) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX > 0, currentX + size.width > maxWidth {
                usedWidth = max(usedWidth, currentX)
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        usedWidth = max(usedWidth, currentX)
        let totalHeight = currentY + lineHeight

        return CGSize(width: usedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width

        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX > bounds.minX, currentX + size.width > bounds.minX + maxWidth {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
