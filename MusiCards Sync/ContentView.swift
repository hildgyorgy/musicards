import SwiftUI
import AppKit

private struct WindowChromeConfigurator: NSViewRepresentable {
    let refreshToken: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            configure(view.window)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

struct ContentView: View {

    @State private var model: SyncViewModel

    init() {
        _model = State(initialValue: SyncViewModel())
    }

    init(configurationStore: SyncConfigurationStore) {
        _model = State(
            initialValue: SyncViewModel(configurationStore: configurationStore)
        )
    }

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 0) {
            Text("MusiCards Sync")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .padding(.leading, AppDesign.railWidth + AppDesign.contentGap)
                .padding(.bottom, 47)

            VStack(alignment: .leading, spacing: AppDesign.sectionGap) {
                sourceSection
                destinationSection
                previewSection
                syncSection
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.localRsyncVersionText)
                    .foregroundStyle(
                        model.localRsyncStatusIsError
                            ? Color.red
                            : Color.secondary
                    )
                    .help(
                        "MusiCards Sync uses this external local rsync executable."
                    )

                if let remoteText = model.remoteRsyncVersionText {
                    Text(remoteText)
                        .foregroundStyle(
                            model.remoteRsyncStatusIsError
                                ? Color.red
                                : Color.secondary
                        )
                        .help(model.remoteRsyncHelpText)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .lineLimit(1)
        }
        .padding(AppDesign.contentPadding)
        .frame(minWidth: 760, minHeight: 620)
        .confirmationDialog(
            "Start synchronization?",
            isPresented: $model.showSyncConfirmation
        ) {
            Button("Sync") {
                model.performSync()
            }
            .keyboardShortcut(.defaultAction)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.syncConfirmationMessage)
        }
        .sheet(isPresented: $model.showProgress) {
            SyncProgressView(
                title: model.progressTitle,
                lines: model.progressLines,
                isRunning: model.isBusy,
                progress: model.isSyncing ? model.syncProgress : nil,
                progressLabel: model.syncFileProgressText,
                onStop: { model.stopCurrentOperation() },
                onClose: {
                    model.showProgress = false
                }
            )
        }
        .background(
            WindowChromeConfigurator(refreshToken: model.hasChecked)
        )
        .task {
            await model.loadRsyncVersion()
        }
        .task(id: model.configuration.destination.id) {
            await model.loadRemoteRsyncVersion()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didMountNotification
            )
        ) { _ in
            model.localVolumesDidChange()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didUnmountNotification
            )
        ) { _ in
            model.localVolumesDidChange()
        }
    }

    // MARK: - Main window sections

    private var sourceSection: some View {
        HStack(alignment: .center, spacing: AppDesign.contentGap) {
            Button {
                chooseSourceFolder()
            } label: {
                AppRailSymbol(
                    systemName: "arrow.left",
                    isEnabled: !model.isBusy
                )
            }
            .buttonStyle(AppRailButtonStyle())
            .disabled(model.isBusy)
            .help("Choose Source")

            VStack(alignment: .leading, spacing: AppDesign.detailSpacing) {
                AppSectionHeader("Source")

                Text("Music Library")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(model.configuration.sourcePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var destinationSection: some View {
        HStack(alignment: .center, spacing: AppDesign.contentGap) {
            Menu {
                ForEach(model.destinationOptions) { profile in
                    Button {
                        model.selectDestination(profile)
                    } label: {
                        if model.configuration.destination == profile {
                            Label(
                                destinationDisplayName(profile),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(destinationDisplayName(profile))
                        }
                    }
                }

                Divider()

                Button("External Drive…") {
                    chooseDestinationFolder()
                }
            } label: {
                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .frame(
                        width: AppDesign.railWidth,
                        height: AppDesign.railControlHeight
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.isBusy)
            .frame(
                width: AppDesign.railWidth,
                height: AppDesign.railControlHeight
            )
            .overlay {
                AppRailSymbol(
                    systemName: "arrow.right",
                    isEnabled: !model.isBusy
                )
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Choose Destination")
            .help("Choose Destination")

            VStack(alignment: .leading, spacing: AppDesign.detailSpacing) {
                AppSectionHeader("Destination")

                Text(destinationDisplayName(model.configuration.destination))
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(model.configuration.destination.remoteDestination)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var previewSection: some View {
        HStack(alignment: .top, spacing: AppDesign.contentGap) {
            Button {
                model.checkSync()
            } label: {
                AppRailSymbol(
                    systemName: "arrow.triangle.2.circlepath",
                    isEnabled: model.canCheck,
                    isActive: model.isChecking
                )
            }
            .buttonStyle(AppRailButtonStyle())
            .disabled(!model.canCheck)
            .help("Check Synchronization")

            VStack(alignment: .leading, spacing: 12) {
                AppSectionHeader("Sync Preview")

                previewContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if model.isChecking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for changes…")
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage = model.errorMessage,
                  model.syncPhase == .idle {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if !model.hasChecked {
            Text("Ready to check for changes")
                .foregroundStyle(.secondary)
        } else if model.preview.hasChanges {
            summaryView(SyncSummary(preview: model.preview))
        } else {
            Label(
                "Destination is up to date",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func summaryView(_ summary: SyncSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow("New files", summary.newFiles)
            summaryRow("Modified files", summary.modifiedFiles)
            summaryRow("New folders", summary.newFolders)
            summaryRow("Deleted files", summary.deletedFiles)
            summaryRow("Deleted folders", summary.deletedFolders)
            summaryRow("System cleanup", summary.systemCleanup)
        }
    }

    private func summaryRow(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .frame(width: 150, alignment: .leading)

            Text(count.formatted())
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()
        }
    }

    private var syncSection: some View {
        HStack(alignment: .top, spacing: AppDesign.contentGap) {
            Button {
                model.showSyncConfirmation = true
            } label: {
                AppRailSymbol(
                    systemName: "arrow.triangle.2.circlepath",
                    isEnabled: model.canSync,
                    isActive: model.isSyncing
                )
            }
            .buttonStyle(AppRailButtonStyle())
            .disabled(!model.canSync)
            .help("Start Synchronization")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    AppSectionHeader("Sync")

                    Spacer()

                    if let progressText = model.syncFileProgressText {
                        Text(progressText)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                AppThinProgressBar(value: model.syncProgress ?? 0)

                if let syncStatusText = model.syncStatusText {
                    Text(syncStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let syncSummary = model.displayedSyncSummary {
                    summaryView(syncSummary)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()

        panel.title = "Choose Music Source Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK,
           let url = panel.url {
            model.selectSource(path: url.path)
        }
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()

        panel.title = "Choose Destination Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK,
           let url = panel.url {
            model.selectLocalDestination(path: url.path)
        }
    }

    private func destinationDisplayName(
        _ profile: DestinationProfile
    ) -> String {

        guard profile.kind == .local else {
            return profile.name
        }

        let components = URL(
            fileURLWithPath: profile.path
        ).pathComponents

        if let volumesIndex = components.firstIndex(of: "Volumes"),
           components.indices.contains(volumesIndex + 1) {

            let volumeName = components[volumesIndex + 1]
            return "\(volumeName)"
        }

        return "Local Folder"
    }

}

#Preview {
    ContentView()
}
