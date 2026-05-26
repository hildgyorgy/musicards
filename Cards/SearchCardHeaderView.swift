//
//  SearchCardHeaderView.swift
//  MusiCards
//
//  Created by Hild György on 2026. 04. 07..
//

import SwiftUI
import VisionKit

struct SearchCardHeaderView: View {
    @ObservedObject var viewModel: SearchViewModel
    let onTapCurrentArtist: () -> Void
    let onBarcodeScanned: (String) -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isShowingBarcodeScanner = false

    @Environment(\.colorScheme) private var colorScheme

    private var isReleaseGroupMode: Bool {
        if case .releaseGroupResults = viewModel.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.footnote)

                if isReleaseGroupMode {
                    Button {
                        viewModel.switchToSearch()
                        isSearchFocused = true
                    } label: {
                        HStack {
                            Text("New search")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                } else {
                    TextField("Artist, release", text: $viewModel.searchQuery)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled(true)
#if os(iOS)
                        .keyboardType(.default)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
#endif
                        .focused($isSearchFocused)

                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
#if os(iOS)
                Button {
                    isShowingBarcodeScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .foregroundStyle(.tint)
                        .font(.callout)
                }
                .buttonStyle(.plain)
#endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        colorScheme == .dark
                        ? AppStyle.boxBackgroundDark
                        : AppStyle.boxBackgroundLight
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                colorScheme == .dark
                                ? AppStyle.strokeDark
                                : AppStyle.strokeLight,
                                lineWidth: 0.5
                            )
                    )
            )

            Spacer().frame(height: 32)

            if isReleaseGroupMode {
                Text(viewModel.displayTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Button {
                    onTapCurrentArtist()
                } label: {
                    Text(viewModel.displayArtist)
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.queryDidChange()
        }
#if os(iOS)
        .sheet(isPresented: $isShowingBarcodeScanner) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                BarcodeScannerView { code in
                    isShowingBarcodeScanner = false
                    onBarcodeScanned(code)
                }
            } else {
                VStack(spacing: 16) {
                    Text("Barcode scanning is not available on this device.")
                        .multilineTextAlignment(.center)

                    Button("Close") {
                        isShowingBarcodeScanner = false
                    }
                }
                .padding()
            }
        }
#endif
    }
}
