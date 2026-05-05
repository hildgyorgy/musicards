//
//  TrackDetailPagerView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 10..
//

import SwiftUI

struct TrackDetailPagerView: View {
    @Binding var selectedPage: Int
    let recordingID: String?
    @ObservedObject var detailStore: TrackDetailStore
    let onSelectArtist: (String) -> Void

    @State private var maxPageHeight: CGFloat = 80

    var detailData: TrackDetailData? { detailStore.data(for: recordingID) }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPage) {
                creatorsPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tag(0)

                performersPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tag(1)

                technicalPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: maxPageHeight)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.secondary : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .background(
            VStack(spacing: 0) {
                TrackDetailMeasuredPage { creatorsPage }
                TrackDetailMeasuredPage { performersPage }
                TrackDetailMeasuredPage { technicalPage }
            }
            .hidden()
        )
        .onPreferenceChange(TrackDetailPageHeightPreferenceKey.self) { value in
            if value > 0 {
                maxPageHeight = value
            }
        }
    }

    @ViewBuilder
    private var creatorsPage: some View {
        if let detailData {
            TrackCreatorsWorkPage(
                detailData: detailData,
                onSelectArtist: onSelectArtist
            )
        } else if detailStore.isLoading(recordingID) {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            TrackEmptyDetailPage()
        }
    }

    @ViewBuilder
    private var performersPage: some View {
        if let detailData {
            TrackGroupedDetailPage(
                groups: detailData.performers,
                onSelectArtist: onSelectArtist
            )
        } else if detailStore.isLoading(recordingID) {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            TrackEmptyDetailPage()
        }
    }

    @ViewBuilder
    private var technicalPage: some View {
        if let detailData {
            TrackTechnicalDetailPage(detailData: detailData)
        } else if detailStore.isLoading(recordingID) {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
        } else {
            TrackEmptyDetailPage()
        }
    }
}

private struct TrackDetailMeasuredPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TrackDetailPageHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
    }
}

private struct TrackDetailPageHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TrackEmptyDetailPage: View {
    var body: some View {
        Text("n/a")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 0)
            .padding(.trailing, 0)
            .padding(.vertical, 8)
    }
}

private struct TrackCreatorsWorkPage: View {
    let detailData: TrackDetailData
    let onSelectArtist: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if detailData.creators.isEmpty && detailData.workHierarchy.isEmpty {
                TrackEmptyDetailPage()
            } else {
                if !detailData.creators.isEmpty {
                    ForEach(Array(detailData.creators.enumerated()), id: \.offset) { _, item in
                        linkedAlignedDetailRow(
                            role: item.role,
                            artists: item.artists,
                            onSelectArtist: onSelectArtist
                        )
                    }
                }

                if !detailData.workHierarchy.isEmpty {
                    alignedDetailRow(
                        role: "work",
                        value: detailData.workHierarchy.joined(separator: "\n")
                    )
                    .padding(.top, 14)
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 0)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

private struct TrackGroupedDetailPage: View {
    let groups: [LinkedArtistGroup]
    let onSelectArtist: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if groups.isEmpty {
                TrackEmptyDetailPage()
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, item in
                    linkedAlignedDetailRow(
                        role: item.role,
                        artists: item.artists,
                        onSelectArtist: onSelectArtist
                    )
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 0)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

private struct TrackTechnicalDetailPage: View {
    let detailData: TrackDetailData

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if detailData.technical.isEmpty && detailData.notes.isEmpty {
                TrackEmptyDetailPage()
            } else {
                ForEach(Array(detailData.technical.enumerated()), id: \.offset) { _, item in
                    alignedDetailRow(
                        role: item.role,
                        value: item.names.joined(separator: ", ")
                    )
                }

                if !detailData.notes.isEmpty {
                    alignedDetailRow(
                        role: "notes",
                        value: detailData.notes.joined(separator: "\n")
                    )
                    .padding(.top, 2)
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 0)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

@ViewBuilder
private func alignedDetailRow(role: String, value: String) -> some View {
    ColonAlignedRowLayout(colonWidth: 10) {
        Text(role)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)

        Text(":")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

        Text(value)
            .font(.subheadline)
            .foregroundStyle(role == "notes" ? .secondary : .primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@ViewBuilder
private func linkedAlignedDetailRow(
    role: String,
    artists: [LinkedArtist],
    onSelectArtist: @escaping (String) -> Void
) -> some View {
    ColonAlignedRowLayout(colonWidth: 10) {
        Text(role)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)

        Text(":")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

        if artists.count == 1, let artist = artists.first {
            Button {
                onSelectArtist(artist.id)
            } label: {
                Text(artist.name)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            InlineWrapLayout(spacing: 0, lineSpacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                    Button {
                        onSelectArtist(artist.id)
                    } label: {
                        Text(artist.name)
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)

                    if index < artists.count - 1 {
                        Text(", ")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
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
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth, height: nil)
            )

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
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth, height: nil)
            )

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
private struct ColonAlignedRowLayout: Layout {
    let colonWidth: CGFloat

    init(colonWidth: CGFloat = 10) {
        self.colonWidth = colonWidth
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 3 else { return .zero }

        let totalWidth = proposal.width ?? 0
        let sideWidth = max((totalWidth - colonWidth) / 2, 0)

        let leftSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: sideWidth, height: nil)
        )
        let colonSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: colonWidth, height: nil)
        )
        let rightSize = subviews[2].sizeThatFits(
            ProposedViewSize(width: sideWidth, height: nil)
        )

        let height = max(leftSize.height, colonSize.height, rightSize.height)

        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 3 else { return }

        let sideWidth = max((bounds.width - colonWidth) / 2, 0)

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: sideWidth, height: bounds.height)
        )

        subviews[1].place(
            at: CGPoint(x: bounds.minX + sideWidth, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: colonWidth, height: bounds.height)
        )

        subviews[2].place(
            at: CGPoint(x: bounds.minX + sideWidth + colonWidth, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: sideWidth, height: bounds.height)
        )
    }
}
