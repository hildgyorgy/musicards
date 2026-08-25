//
//  ReleaseCardContentView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import SwiftUI

struct ReleaseCardContentView: View {
    let release: MBRelease?
    let onShowVersions: () -> Void
#if os(iOS)
    @Environment(\.deckContentBottomInset) private var deckContentBottomInset
#endif

    var body: some View {
        if let release {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        metaRow(
                            "Date",
                            MBTextFormatter.displayDate(from: release.date)
                        )
                        metaRow("Country", release.country ?? "")
                        metaRow("Label", labelText(from: release))
                        metaRow("Cat. no.", catalogNumberText(from: release))
                        metaRow("Barcode", release.barcode ?? "")
                        metaRow("Notes", noteText(from: release))
                        Button(action: {
                            onShowVersions()
                        }) {
                            Text("Other versions →")
                                .font(.body)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .padding(.leading, 92)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
#if os(iOS)
                    Color.clear
                        .frame(height: deckContentBottomInset)
#endif
                }
            }
        } else {
            EmptyStateView.release
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 0)
        }
    }

    @ViewBuilder
    private func metaRow(_ title: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text("\(title):")
                    .foregroundStyle(.secondary)
                    .font(.subheadline.weight(.bold))
                    .frame(width: 80, alignment: .leading)

                Text(value)
                    .foregroundStyle(.primary)
                    .font(.subheadline)
                    .lineSpacing(4)

                Spacer()
                
            }
        }
    }

    private func labelText(from release: MBRelease) -> String {
        release.labelInfo?
            .compactMap { $0.label?.name }
            .joined(separator: ", ") ?? ""
    }

    private func catalogNumberText(from release: MBRelease) -> String {
        release.labelInfo?
            .compactMap { $0.catalogNumber }
            .joined(separator: ", ") ?? ""
    }

    private func noteText(from release: MBRelease) -> String {
        release.disambiguation ?? ""
    }
}
