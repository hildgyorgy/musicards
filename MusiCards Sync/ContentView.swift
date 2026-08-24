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
    @State private var showDestinationPicker = false
    @State private var showRemoteLocationSetup = false
    @State private var showRemoveRemoteConfirmation = false
    @State private var showThirdPartyLicenses = false

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
            appHeader

            VStack(alignment: .leading, spacing: AppDesign.sectionGap) {
                sourceSection
                sourceIndexSection
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
            .sheet(isPresented: $showRemoteLocationSetup) {
            RemoteLocationSetupView { profile, password in
                try await model.pairAndAddRemoteDestination(
                    profile,
                    password: password
                )
            }
        .sheet(isPresented: $showThirdPartyLicenses) {
            SyncThirdPartyLicensesView()
        }
        }
        .confirmationDialog(
            "Remove remote location?",
            isPresented: $showRemoveRemoteConfirmation
        ) {
            Button("Remove", role: .destructive) {
                model.removeCurrentRemoteDestination()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved location from MusiCards Sync. It does not delete music or SSH keys from the server.")
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

    private var appHeader: some View {
        HStack(alignment: .center, spacing: AppDesign.contentGap) {
            Link(
                destination: URL(
                    string: "https://hildgyorgy.github.io/app-support/musicards-sync/#help"
                )!
            ) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        width: AppDesign.headerAppIconSize,
                        height: AppDesign.headerAppIconSize
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppDesign.headerAppIconCornerRadius,
                            style: .continuous
                        )
                    )
                    .frame(
                        width: AppDesign.railWidth,
                        height: AppDesign.railControlHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open MusiCards Sync Help, Support & Privacy")
            .accessibilityLabel("MusiCards Sync Help, Support & Privacy")

            Text("MusiCards Sync")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Spacer()

            Button("Third-Party Licenses…") {
                showThirdPartyLicenses = true
            }
            .buttonStyle(.link)
        }
        .padding(.bottom, 47)
    }

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
            Button {
                showDestinationPicker = true
            } label: {
                AppRailSymbol(
                    systemName: "arrow.right",
                    isEnabled: !model.isBusy
                )
            }
            .buttonStyle(AppRailButtonStyle())
            .disabled(model.isBusy)
            .help("Choose Destination")
            .popover(
                isPresented: $showDestinationPicker,
                arrowEdge: .trailing
            ) {
                destinationPicker
            }

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

    private var sourceIndexSection: some View {
        HStack(alignment: .center, spacing: AppDesign.contentGap) {
            Button {
                model.createSourceLibraryIndex()
            } label: {
                AppRailSymbol(
                    systemName: "doc.text.magnifyingglass",
                    isEnabled: model.canCreateSourceIndex,
                    isActive: model.isIndexingSource
                )
            }
            .buttonStyle(AppRailButtonStyle())
            .disabled(!model.canCreateSourceIndex)
            .help("Create Index in Source Library")

            VStack(alignment: .leading, spacing: AppDesign.detailSpacing) {
                AppSectionHeader("Library Index")

                Text("Create index in source library")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(model.sourceIndexStatusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !model.destinationOptions.isEmpty {
                ForEach(model.destinationOptions) { profile in
                    Button {
                        showDestinationPicker = false
                        model.selectDestination(profile)
                    } label: {
                        HStack(spacing: 12) {
                            Text(destinationDisplayName(profile))
                            Spacer(minLength: 24)
                            if model.configuration.destination == profile {
                                Image(systemName: "checkmark")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .padding(.vertical, 3)
            }

            destinationPickerButton("Add Remote Location…") {
                showDestinationPicker = false
                DispatchQueue.main.async {
                    showRemoteLocationSetup = true
                }
            }

            destinationPickerButton("External Drive…") {
                showDestinationPicker = false
                DispatchQueue.main.async {
                    chooseDestinationFolder()
                }
            }

            if model.configuration.destination.kind == .remote {
                Divider()
                    .padding(.vertical, 3)
                destinationPickerButton(
                    "Remove Current Remote Location…",
                    foregroundStyle: .red
                ) {
                    showDestinationPicker = false
                    DispatchQueue.main.async {
                        showRemoveRemoteConfirmation = true
                    }
                }
            }
        }
        .padding(8)
        .frame(minWidth: 270)
    }

    private func destinationPickerButton(
        _ title: String,
        foregroundStyle: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(foregroundStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            summaryView(
                SyncSummary(preview: model.preview),
                usesPreviewLabels: true
            )
        } else {
            Label(
                "Music files are up to date",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func summaryView(
        _ summary: SyncSummary,
        indexSummary: LibraryIndexSyncSummary? = nil,
        usesPreviewLabels: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let indexSummary {
                summaryStatusRow(
                    "Library index generated",
                    isCompleted: indexSummary.indexGenerated
                )
                if let readyAlbumCount =
                        indexSummary.musicBrainzReadyAlbumCount,
                   let totalAlbumCount = indexSummary.totalAlbumCount {
                    summaryRatioRow(
                        "MusicBrainz-ready albums",
                        numerator: readyAlbumCount,
                        denominator: totalAlbumCount
                    )
                }
                summaryStatusRow(
                    "Previous index removed",
                    isCompleted: indexSummary.previousIndexRemoved
                )
            }

            summaryRow("New files", summary.newFiles)
            summaryRow("Modified files", summary.modifiedFiles)
            summaryRow("New folders", summary.newFolders)
            summaryRow(
                usesPreviewLabels ? "Files to delete" : "Deleted files",
                summary.deletedFiles
            )
            summaryRow(
                usesPreviewLabels ? "Folders to delete" : "Deleted folders",
                summary.deletedFolders
            )
            summaryRow("System cleanup", summary.systemCleanup)

            if let indexSummary {
                summaryStatusRow(
                    "New index published",
                    isCompleted: indexSummary.newIndexPublished
                )
            }
        }
    }

    private func summaryStatusRow(
        _ title: String,
        isCompleted: Bool
    ) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .frame(width: 190, alignment: .leading)

            Text(isCompleted ? "Done" : "Not completed")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private func summaryRatioRow(
        _ title: String,
        numerator: Int,
        denominator: Int
    ) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .frame(width: 190, alignment: .leading)

            Text("\(numerator.formatted()) / \(denominator.formatted())")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()
        }
    }

    private func summaryRow(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .frame(width: 190, alignment: .leading)

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
                    summaryView(
                        syncSummary,
                        indexSummary: model.displayedLibraryIndexSyncSummary
                    )
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

        if profile == .unconfigured {
            return "Choose Destination"
        }

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
