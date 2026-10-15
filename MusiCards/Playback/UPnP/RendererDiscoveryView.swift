import SwiftUI

struct RendererDiscoveryView: View {
    @ObservedObject var browser: UPnPRendererBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var rendererAddress = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Text("Discovery preview. Playback remains on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                content
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        .onAppear {
            if browser.state == .idle {
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

            Button("DONE") { dismiss() }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch browser.state {
        case .idle, .searching:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching the local network…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)

        case let .failed(message):
            messageView(message)
            addressDiscovery

        case .ready:
            if browser.renderers.isEmpty {
                Text("No UPnP/DLNA MediaRenderer responded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(browser.renderers) { renderer in
                        rendererRow(renderer)
                    }
                }
            }

            addressDiscovery

            Button("SEARCH AGAIN") { browser.refresh() }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var addressDiscovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RENDERER IP ADDRESS")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("192.168.1.50", text: $rendererAddress)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    #endif

                Button("FIND") {
                    browser.refresh(rendererAddress: rendererAddress)
                }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(
                    rendererAddress.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }

            Text("For renderers that do not answer multicast discovery. A successful address is remembered on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func rendererRow(_ renderer: UPnPRendererDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(renderer.friendlyName)
                .font(.headline)

            if let modelName = renderer.modelName {
                Text(modelName)
                    .font(.callout)
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
        .padding(14)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func messageView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("SEARCH AGAIN") { browser.refresh() }
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
