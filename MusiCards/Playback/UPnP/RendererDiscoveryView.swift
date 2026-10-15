import SwiftUI

struct RendererDiscoveryView: View {
    @ObservedObject var browser: UPnPRendererBrowser
    @ObservedObject var navidromeConnection: NavidromeConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var rendererAddress = ""
    @State private var rendererServerAddress = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Text("Select one renderer, then provide a Navidrome address it can reach.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                content
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        .onAppear {
            browser.beginRendererSelection()
            rendererServerAddress = navidromeConnection.rendererServerURL?
                .absoluteString ?? ""
            if !browser.hasStartedAutomaticDiscovery {
                browser.refresh()
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        HStack {
            Text("NETWORK RENDERER LAB")
                .font(.system(.headline, design: .monospaced))
                .tracking(2)

            Spacer()

            Button("CANCEL") {
                browser.cancelRendererSelection()
                dismiss()
            }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .buttonStyle(.plain)

            Button("OK") {
                browser.commitRendererSelection()
                dismiss()
            }
            .font(.system(.footnote, design: .monospaced).weight(.bold))
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var content: some View {
        rendererServerSection

        LazyVStack(spacing: 14) {
            ForEach(UPnPRendererBrowser.DiscoveryMethod.allCases) { method in
                discoverySection(method)
            }
        }

        Button("RUN AUTOMATIC TESTS AGAIN") { browser.refresh() }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .buttonStyle(.plain)
            .disabled(browser.isSearching)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    private var rendererServerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NAVIDROME ADDRESS FOR RENDERER")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1.2)

            Text(
                "Use a home-network address the renderer can open, for example http://umbrel.local:4533. The app keeps using the normal HTTPS address and reuses the same saved account."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(
                "http://umbrel.local:4533",
                text: $rendererServerAddress
            )
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif

            HStack(spacing: 10) {
                Button {
                    Task {
                        await navidromeConnection
                            .verifyAndSaveRendererServerURL(
                                rendererServerAddress
                            )
                    }
                } label: {
                    Text(
                        navidromeConnection.isVerifyingRendererServer
                            ? "VERIFYING…" : "VERIFY & SAVE"
                    )
                }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .buttonStyle(.borderedProminent)
                .disabled(
                    navidromeConnection.isVerifyingRendererServer
                        || rendererServerAddress.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )

                Button("USE NORMAL ADDRESS") {
                    navidromeConnection.useNormalServerAddressForRenderer()
                    rendererServerAddress = ""
                }
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .buttonStyle(.plain)
            }

            if let message = navidromeConnection.rendererServerStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let message = navidromeConnection.rendererServerErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func discoverySection(
        _ method: UPnPRendererBrowser.DiscoveryMethod
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(method.title)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1.2)

            Text(method.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stageResult(browser.state(for: method))

            if method == .subnetSweep {
                Button("RUN DEEP SEARCH") { browser.deepSearch() }
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.isSearching)
            }

            if method == .manualAddress {
                manualAddressControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func stageResult(
        _ state: UPnPRendererBrowser.DiscoveryStageState
    ) -> some View {
        switch state {
        case .waiting:
            resultLabel("WAITING", color: .secondary)
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                resultLabel("SEARCHING…", color: .secondary)
            }
        case .noResult:
            resultLabel("NO RENDERER FOUND", color: .orange)
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: 3) {
                resultLabel("NOT AVAILABLE", color: .secondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 3) {
                resultLabel("ERROR", color: .red)
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

    private func resultLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(color)
    }

    private var manualAddressControls: some View {
        HStack(spacing: 10) {
            TextField("192.168.---.---", text: $rendererAddress)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                #endif

            Button("FIND") {
                browser.findRenderer(at: rendererAddress)
            }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .buttonStyle(.bordered)
            .disabled(
                browser.isSearching
                    || rendererAddress.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            )
        }
    }

    private func rendererRow(_ renderer: UPnPRendererDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(renderer.friendlyName)
                    .font(.headline)
                Spacer()
                resultLabel("FOUND", color: .green)
                selectionButton(for: renderer)
            }

            if let modelName = renderer.modelName {
                Text(modelName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let host = renderer.descriptionURL.host {
                Text(host)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(capabilityText(renderer.capabilities))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snapshot = browser.snapshots[renderer.id] {
                Text(snapshotText(snapshot))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            if let error = browser.statusErrors[renderer.id] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                browser.checkStatus(of: renderer)
            } label: {
                Text(
                    browser.checkingRendererIDs.contains(renderer.id)
                        ? "CHECKING…" : "CHECK TRANSPORT"
                )
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(browser.checkingRendererIDs.contains(renderer.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectionButton(
        for renderer: UPnPRendererDescriptor
    ) -> some View {
        let isSelected = browser.isDraftSelected(renderer)
        return Button {
            browser.toggleDraftSelection(of: renderer)
        } label: {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.title3)
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

    private func capabilityText(_ capabilities: UPnPRendererCapabilities) -> String {
        var values: [String] = []
        if capabilities.supportsPlay { values.append("PLAY") }
        if capabilities.supportsPause { values.append("PAUSE") }
        if capabilities.supportsStop { values.append("STOP") }
        if capabilities.supportsSeek { values.append("SEEK") }
        if capabilities.supportsSetNext { values.append("SET NEXT") }
        return values.isEmpty ? "CAPABILITIES: UNKNOWN" : values.joined(separator: " • ")
    }

    private func snapshotText(_ snapshot: AVTransportSnapshot) -> String {
        let position = snapshot.position.relativeTime.map(durationText) ?? "—"
        let duration = snapshot.position.duration.map(durationText) ?? "—"
        return "STATE: \(snapshot.transport.state)\nPOSITION: \(position) / \(duration)"
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
