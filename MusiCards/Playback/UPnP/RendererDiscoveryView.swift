import SwiftUI

struct RendererDiscoveryView: View {
    private enum OutputKind {
        case systemAudio
        case upnpRenderer
    }

    @ObservedObject var browser: UPnPRendererBrowser
    @ObservedObject var controller: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var rendererAddress = ""
    @State private var selectedOutputKind: OutputKind = .systemAudio

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                outputForm
                    .navigationTitle("Audio output")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #else
            VStack(spacing: 0) {
                MusiCardsSettingsSheetHeader(title: "Audio output") {
                    dismiss()
                }
                outputPicker
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

                outputForm
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .frame(
                width: MacWindowMetrics.contentSize.width - 4,
                height: MacWindowMetrics.contentSize.height * 0.78
            )
            #endif
        }
        .onAppear {
            selectedOutputKind = browser.hasSelectedRendererPreference
                ? .upnpRenderer
                : .systemAudio
            if selectedOutputKind == .upnpRenderer {
                if !browser.hasStartedAutomaticDiscovery {
                    browser.refresh()
                }
                browser.startPassiveListening()
            }
        }
        .onDisappear { browser.stopPassiveListening() }
    }

    private var outputForm: some View {
        Form {
            #if os(iOS)
            Section {
                outputPicker
                    .listRowBackground(Color.clear)
            }
            #endif

            if selectedOutputKind == .systemAudio {
                systemAudioContent
            } else {
                upnpContent
            }
        }
    }

    private var outputPicker: some View {
        HStack(spacing: 12) {
            outputButton(.systemAudio, title: "System audio")
            outputButton(.upnpRenderer, title: "UPnP renderer")
        }
    }

    @ViewBuilder
    private func outputButton(
        _ kind: OutputKind,
        title: String
    ) -> some View {
        if selectedOutputKind == kind {
            Button {
                selectOutputKind(kind)
            } label: {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            Button {
                selectOutputKind(kind)
            } label: {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private func selectOutputKind(_ kind: OutputKind) {
        guard selectedOutputKind != kind else { return }
        selectedOutputKind = kind
        switch kind {
        case .systemAudio:
            browser.stopPassiveListening()
            browser.selectSystemAudioImmediately()
        case .upnpRenderer:
            browser.startPassiveListening()
            if !browser.hasStartedAutomaticDiscovery {
                browser.refresh()
            }
        }
    }

    private var systemAudioContent: some View {
        Section {
            Text("Active system audio output")
            Text(controller.outputRoute.displayName)
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("System audio")
        } footer: {
            Text("Sound follows the output selected in the system, such as built-in speakers, headphones, Bluetooth, AirPlay, or a connected DAC.")
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var upnpContent: some View {
        Section("Find and select UPnP renderer") {
            searchHeader(for: .multicast)
            discoveryResult(for: .multicast)
        }

        Section {
            searchHeader(for: .subnetSweep)
            discoveryResult(for: .subnetSweep)
        }

        Section {
            searchHeader(for: .rememberedAddress)
            discoveryResult(for: .rememberedAddress)
        }

        Section {
            searchHeader(for: .manualAddress)
            TextField(
                "",
                text: $rendererAddress,
                prompt: Text("e.g. 192.168.1.50")
            )
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Renderer address")
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                #else
                .labelsHidden()
                #endif
                .onSubmit(searchManualAddress)
            discoveryResult(for: .manualAddress)
        }
    }

    private func searchHeader(
        for method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        HStack(spacing: 12) {
            Text(title(for: method))
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if browser.state(for: method).isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching for renderers")
            } else {
                Button(method == .manualAddress ? "Find" : "Search") {
                    search(for: method)
                }
                .buttonStyle(.borderless)
                .tint(.blue)
                .disabled(
                    method == .manualAddress
                        && rendererAddress.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
            }
        }
    }

    private func title(
        for method: UPnPRendererBrowser.DiscoveryMethod
    ) -> String {
        switch method {
        case .multicast: "Multicast SSDP"
        case .subnetSweep: "Deep search"
        case .rememberedAddress: "Saved addresses"
        case .manualAddress: "Manual address"
        }
    }

    private func search(for method: UPnPRendererBrowser.DiscoveryMethod) {
        switch method {
        case .multicast: browser.searchMulticast()
        case .subnetSweep: browser.deepSearch()
        case .rememberedAddress: browser.searchRememberedAddresses()
        case .manualAddress: searchManualAddress()
        }
    }

    private func searchManualAddress() {
        let address = rendererAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        browser.findRenderer(at: address)
    }

    @ViewBuilder
    private func discoveryResult(
        for method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        switch browser.state(for: method) {
        case .waiting:
            EmptyView()
        case .searching:
            Text("Searching…")
                .foregroundStyle(.secondary)
        case .noResult:
            Text("No renderer found")
                .foregroundStyle(.secondary)
        case let .unavailable(message):
            Text(method == .rememberedAddress ? "No saved addresses" : message)
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        case let .found(renderers):
            ForEach(renderers) { renderer in
                rendererRow(renderer)
            }
        }
    }

    private func rendererRow(
        _ renderer: UPnPRendererDescriptor
    ) -> some View {
        let isSelected = browser.isSelected(renderer)
        return Button {
            browser.selectImmediately(renderer)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(renderer.friendlyName)
                        .foregroundStyle(.primary)
                    if let host = renderer.descriptionURL.host {
                        Text(host)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(renderer.friendlyName)
        .accessibilityValue(isSelected ? "Selected output" : "Not selected")
    }
}
