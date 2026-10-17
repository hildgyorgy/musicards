import SwiftUI

struct RendererDiscoveryView: View {
    private enum OutputKind {
        case systemAudio
        case upnpRenderer
    }

    @ObservedObject var browser: UPnPRendererBrowser
    @ObservedObject var controller: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var rendererAddress = ""
    @State private var selectedOutputKind: OutputKind = .systemAudio

    var body: some View {
        Group {
            #if os(iOS)
            iosOutputSheet
            #else
            content
                .frame(width: MacWindowMetrics.contentSize.width - 4)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .onAppear {
            #if os(macOS)
            browser.beginRendererSelection()
            selectedOutputKind = browser.draftRendererID == nil
                ? .systemAudio
                : .upnpRenderer
            #else
            selectedOutputKind = browser.hasSelectedRendererPreference
                ? .upnpRenderer
                : .systemAudio
            #endif
            if selectedOutputKind == .upnpRenderer,
               !browser.hasStartedAutomaticDiscovery {
                browser.refresh()
            }
            if selectedOutputKind == .upnpRenderer {
                browser.startPassiveListening()
            }
        }
        .onDisappear { browser.stopPassiveListening() }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    #if os(iOS)
    private var iosOutputSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        iosOutputButton(.systemAudio, title: "System audio")
                        iosOutputButton(.upnpRenderer, title: "UPnP renderer")
                    }
                    .listRowBackground(Color.clear)
                }

                if selectedOutputKind == .systemAudio {
                    iosSystemAudioContent
                } else {
                    iosUPnPContent
                }
            }
            .navigationTitle("Audio output")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func iosOutputButton(
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

    private var iosSystemAudioContent: some View {
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
    private var iosUPnPContent: some View {
        Section("Find and select UPnP renderer") {
            iosSearchHeader(for: .multicast)
            iosDiscoveryResult(for: .multicast)
        }

        Section {
            iosSearchHeader(for: .subnetSweep)
            iosDiscoveryResult(for: .subnetSweep)
        }

        Section {
            iosSearchHeader(for: .rememberedAddress)
            iosDiscoveryResult(for: .rememberedAddress)
        }

        Section {
            iosSearchHeader(for: .manualAddress)
            TextField("e.g. 192.168.1.50", text: $rendererAddress)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(searchManualAddress)
            iosDiscoveryResult(for: .manualAddress)
        }
    }

    private func iosSearchHeader(
        for method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        HStack(spacing: 12) {
            Text(iosTitle(for: method))
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

    private func iosTitle(
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
    private func iosDiscoveryResult(
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
                iosRendererRow(renderer)
            }
        }
    }

    private func iosRendererRow(
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
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            outputKindPicker

            if selectedOutputKind == .upnpRenderer {
                upnpContent
            } else {
                systemAudioContent
            }
        }
        .padding(24)
    }

    private var header: some View {
        ZStack {
            Text("AUDIO OUTPUT")
                .font(.system(.headline, design: .monospaced))
                .tracking(2)

            HStack {
                Button {
                    browser.cancelRendererSelection()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")

                Spacer()

                Button("OK") {
                    browser.commitRendererSelection()
                    dismiss()
                }
                #if os(iOS)
                .buttonStyle(.borderless)
                .tint(.accentColor)
                #else
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
                #endif
                .disabled(
                    selectedOutputKind == .upnpRenderer
                        && browser.draftRendererID == nil
                )
            }
        }
    }

    private var outputKindPicker: some View {
        HStack(spacing: 8) {
            Text("SYSTEM AUDIO")
                .foregroundStyle(
                    selectedOutputKind == .systemAudio
                        ? .primary
                        : .secondary
                )

            Toggle(
                "",
                isOn: Binding(
                    get: { selectedOutputKind == .upnpRenderer },
                    set: setUsesUPnPRenderer
                )
            )
            .toggleStyle(.switch)
            .tint(.blue)
            .labelsHidden()

            Text("UPNP RENDERER")
                .foregroundStyle(
                    selectedOutputKind == .upnpRenderer
                        ? .primary
                        : .secondary
                )
        }
        .font(.caption)
        .tracking(1.5)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var systemAudioContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYSTEM AUDIO")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1.2)

            Text("Sound follows the output selected in the system, such as built-in speakers, headphones, Bluetooth or AirPlay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var upnpContent: some View {
        Text("FIND AND SELECT UPNP RENDERER")
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(.blue)

        LazyVStack(spacing: 0) {
            ForEach(
                Array(UPnPRendererBrowser.DiscoveryMethod.allCases.enumerated()),
                id: \.element.id
            ) { index, method in
                discoverySection(method)
                if index < UPnPRendererBrowser.DiscoveryMethod.allCases.count - 1 {
                    PopupSectionDivider()
                }
            }
        }
    }

    private func setUsesUPnPRenderer(_ usesUPnPRenderer: Bool) {
        if usesUPnPRenderer {
            selectedOutputKind = .upnpRenderer
            browser.beginRendererSelection()
            browser.startPassiveListening()
            if !browser.hasStartedAutomaticDiscovery {
                browser.refresh()
            }
        } else {
            selectedOutputKind = .systemAudio
            browser.stopPassiveListening()
            browser.clearDraftRendererSelection()
        }
    }

    private func discoverySection(
        _ method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(method.title)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .tracking(1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if horizontalSizeClass != .compact,
                   method != .manualAddress {
                    Text(method.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                discoveryAction(for: method)
            }

            if method == .manualAddress {
                manualAddressControls
            }

            stageResult(browser.state(for: method))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func discoveryAction(
        for method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        switch method {
        case .multicast:
            compactRunButton("RUN", action: browser.searchMulticast)
        case .rememberedAddress:
            compactRunButton("RUN", action: browser.searchRememberedAddresses)
        case .subnetSweep:
            compactRunButton("RUN", action: browser.deepSearch)
        case .manualAddress:
            EmptyView()
        }
    }

    private func compactRunButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        monochromePillButton(
            title,
            isDisabled: browser.isSearching,
            action: action
        )
    }

    private func monochromePillButton(
        _ title: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                colorScheme == .dark ? Color.white : Color.black,
                in: Capsule()
            )
            .buttonStyle(.plain)
            .opacity(isDisabled ? 0.45 : 1)
            .disabled(isDisabled)
    }

    @ViewBuilder
    private func stageResult(
        _ state: UPnPRendererBrowser.DiscoveryStageState
    ) -> some View {
        switch state {
        case .waiting:
            placeholderRendererRow()
        case .searching:
            placeholderRendererRow("SEARCHING…", showsProgress: true)
        case .noResult:
            placeholderRendererRow("NO RENDERER FOUND", color: .orange)
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: 3) {
                placeholderRendererRow("NOT AVAILABLE")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 3) {
                placeholderRendererRow("ERROR", color: .red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .found(renderers):
            VStack(spacing: 8) {
                ForEach(renderers) { renderer in
                    rendererRow(renderer)
                }
            }
        }
    }

    private func placeholderRendererRow(
        _ status: String? = nil,
        color: Color = .secondary,
        showsProgress: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                if let status {
                    Text(status)
                        .font(
                            .system(
                                .caption,
                                design: .monospaced
                            ).weight(.semibold)
                        )
                        .foregroundStyle(color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 37, alignment: .center)
            .background(.primary.opacity(0.055), in: Capsule())

            Image(systemName: "circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var manualAddressControls: some View {
        HStack(spacing: 10) {
            TextField("192.168.---.---", text: $rendererAddress)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                #endif

            monochromePillButton(
                "RUN",
                isDisabled: browser.isSearching
                    || rendererAddress.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                action: {
                    browser.findRenderer(at: rendererAddress)
                }
            )
        }
    }

    private func rendererRow(_ renderer: UPnPRendererDescriptor) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(renderer.friendlyName)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)

                Spacer(minLength: 8)
                if let host = renderer.descriptionURL.host {
                    Text(host)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.055), in: Capsule())

            selectionButton(for: renderer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionButton(
        for renderer: UPnPRendererDescriptor
    ) -> some View {
        let isSelected = browser.isDraftSelected(renderer)
        return Button {
            browser.toggleDraftSelection(of: renderer)
        } label: {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected
                ? "Deselect \(renderer.friendlyName)"
                : "Select \(renderer.friendlyName)"
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

}
