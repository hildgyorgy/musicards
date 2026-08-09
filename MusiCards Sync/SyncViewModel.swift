import Foundation
import Observation

nonisolated final class RsyncLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLines: [String] = []

    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }

        lock.lock()
        pendingLines.append(contentsOf: lines)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let lines = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        return lines
    }
}

enum LocalRsyncStatus: Equatable {
    case checking
    case available(RsyncVersionInfo)
    case unavailable
    case tooOld(RsyncVersionInfo)
    case missingIconv(RsyncVersionInfo)
}

enum RemoteRsyncStatus: Equatable {
    case notApplicable
    case checking(destinationName: String)
    case available(destinationName: String, info: RsyncVersionInfo)
    case failed(destinationName: String, message: String)
}

enum SyncOperationPhase: Equatable {
    case idle
    case preparing
    case synchronizing
    case verifying
    case completed
    case completedWithRemainingChanges
    case synchronizationStopped
    case verificationStopped
    case synchronizationFailed
    case verificationFailed
}

@MainActor
@Observable
final class SyncViewModel {
    var configuration: SyncConfiguration
    var preview = SyncPreview()
    var isChecking = false
    var errorMessage: String?
    var hasChecked = false
    var showSyncConfirmation = false
    var isSyncing = false

    var progressLines: [String] = []
    var showProgress = false
    var progressTitle = ""
    var syncProgress: Double?
    var syncCompletedFileCount = 0
    var syncTotalFileCount = 0
    var syncCompletedSummary = SyncSummary()
    var syncPhase = SyncOperationPhase.idle
    var localRsyncStatus = LocalRsyncStatus.checking
    var remoteRsyncStatus = RemoteRsyncStatus.notApplicable
    private var localVolumeRevision = 0

    @ObservationIgnored private let configurationStore: SyncConfigurationStore
    @ObservationIgnored private let configurationValidator =
        SyncConfigurationValidator()
    @ObservationIgnored private let completedItemParser =
        RsyncCompletedItemParser()
    @ObservationIgnored private var progressTracker =
        RsyncProgressTracker()
    @ObservationIgnored private var activeEngine: SyncEngine?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var remoteStatusRequestID = UUID()

    init() {
        let configurationStore = SyncConfigurationStore()
        self.configurationStore = configurationStore
        configuration = configurationStore.load()
        prepareRemoteRsyncStatus()
        localVolumesDidChange()
    }

    init(configurationStore: SyncConfigurationStore) {
        self.configurationStore = configurationStore
        configuration = configurationStore.load()
        prepareRemoteRsyncStatus()
        localVolumesDidChange()
    }

    var isBusy: Bool {
        isChecking || isSyncing
    }

    var canCheck: Bool {
        !isBusy && isLocalRsyncReady && !configuration.sourcePath.isEmpty
    }

    var canSync: Bool {
        !isBusy &&
            isLocalRsyncReady &&
            hasChecked &&
            preview.hasChanges &&
            syncPhase == .idle
    }

    var localRsyncVersionText: String {
        switch localRsyncStatus {
        case .checking:
            return "Local   detecting external rsync…"
        case .available(let info):
            return "Local   \(info.displayLine)"
        case .unavailable:
            return "Local   rsync not available"
        case .tooOld(let info):
            return "Local   rsync \(info.version.displayString) — requires \(RsyncRequirements.localMinimum.displayString) or newer"
        case .missingIconv(let info):
            return "Local   rsync \(info.version.displayString) — iconv support required"
        }
    }

    var localRsyncStatusIsError: Bool {
        switch localRsyncStatus {
        case .checking, .available:
            return false
        case .unavailable, .tooOld, .missingIconv:
            return true
        }
    }

    var remoteRsyncVersionText: String? {
        switch remoteRsyncStatus {
        case .notApplicable:
            return nil
        case .checking(let destinationName):
            return "Remote  detecting rsync… · \(destinationName)"
        case .available(let destinationName, let info):
            return "Remote  \(info.displayLine) · \(destinationName)"
        case .failed(let destinationName, _):
            return "Remote  rsync unavailable · \(destinationName)"
        }
    }

    var remoteRsyncStatusIsError: Bool {
        if case .failed = remoteRsyncStatus {
            return true
        }

        return false
    }

    var remoteRsyncHelpText: String {
        switch remoteRsyncStatus {
        case .failed(_, let message):
            return message
        default:
            return "The selected remote destination uses this rsync executable."
        }
    }

    var syncStatusText: String? {
        switch syncPhase {
        case .idle:
            return nil
        case .preparing:
            return "Checking rsync requirements"
        case .synchronizing:
            return "Synchronization in progress"
        case .verifying:
            return "Synchronization complete — verifying"
        case .completed:
            return "Synchronization completed and verified"
        case .completedWithRemainingChanges:
            return "Verification found remaining changes"
        case .synchronizationStopped:
            return "Synchronization stopped"
        case .verificationStopped:
            return "Synchronization completed — verification stopped"
        case .synchronizationFailed:
            return "Synchronization failed"
        case .verificationFailed:
            return "Synchronization completed — verification failed"
        }
    }

    var syncFileProgressText: String? {
        guard syncTotalFileCount > 0 else { return nil }

        switch syncPhase {
        case .preparing, .synchronizing:
            return "\(syncCompletedFileCount) / \(syncTotalFileCount) files"
        case .verifying,
             .completed,
             .completedWithRemainingChanges,
             .synchronizationStopped,
             .verificationStopped,
             .synchronizationFailed,
             .verificationFailed:
            return "\(syncCompletedFileCount) files completed"
        case .idle:
            return nil
        }
    }

    var displayedSyncSummary: SyncSummary? {
        switch syncPhase {
        case .completed,
             .completedWithRemainingChanges,
             .synchronizationStopped,
             .verificationStopped,
             .synchronizationFailed,
             .verificationFailed:
            return syncCompletedSummary
        case .idle, .preparing, .synchronizing, .verifying:
            return nil
        }
    }

    var destinationOptions: [DestinationProfile] {
        _ = localVolumeRevision
        var options = DestinationProfile.defaults

        if configuration.destination.kind == .local,
           !configuration.destination.path.isEmpty,
           configurationValidator.isLocalDestinationAvailable(
               configuration.destination
           ),
           !options.contains(configuration.destination) {
            options.append(configuration.destination)
        }

        return options
    }

    func localVolumesDidChange() {
        localVolumeRevision += 1

        guard !isBusy, configuration.destination.kind == .local else {
            return
        }

        invalidatePreview(resetProgress: true)

        guard !configurationValidator.isLocalDestinationAvailable(
            configuration.destination
        ) else {
            return
        }

        errorMessage = SyncConfigurationValidator.ValidationError
            .localDestinationUnavailable(configuration.destination.path)
            .localizedDescription
    }

    var syncConfirmationMessage: String {
        var lines = [
            "The destination will be updated to match the source."
        ]

        if !preview.deletedFiles.isEmpty || !preview.deletedFolders.isEmpty {
            lines.append(
                "\(preview.deletedFiles.count) file(s) and " +
                "\(preview.deletedFolders.count) folder(s) will be deleted from the destination."
            )
        }

        if !preview.systemCleanup.isEmpty {
            lines.append(
                "\(preview.systemCleanup.count) system file(s) will be cleaned up."
            )
        }

        return lines.joined(separator: "\n\n")
    }

    func checkSync() {
        guard canCheck else { return }
        guard validateSelectedPaths() else { return }

        isChecking = true
        errorMessage = nil
        hasChecked = false
        preview = SyncPreview()
        resetFileProgress()
        syncPhase = .idle
        progressLines = []
        progressTitle = "Checking rsync requirements…"
        showProgress = true

        let engine = SyncEngine(configuration: configuration)
        activeEngine = engine
        let lineBuffer = RsyncLineBuffer()
        let drainTask = startProgressDrain(
            lineBuffer,
            tracksFileProgress: false
        )

        Task { [weak self] in
            guard let self else { return }

            defer {
                drainTask.cancel()
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: false
                )
                isChecking = false
                activeEngine = nil
            }

            do {
                let localInfo = try await validateAndRecordLocalRsync(
                    using: engine
                )
                progressLines.append("Local \(localInfo.displayLine)")

                if let remoteInfo = try await validateAndRecordRemoteRsync(
                    using: engine
                ) {
                    progressLines.append("Remote \(remoteInfo.displayLine)")
                }

                progressTitle = "Checking for changes…"

                let output = try await engine.preview { lines in
                    lineBuffer.append(lines)
                }

                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: false
                )
                preview = engine.parsePreview(output)
                hasChecked = true
                progressTitle = "Check completed"
            } catch SyncEngine.SyncEngineError.cancelled {
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: false
                )
                errorMessage = nil
                progressLines.append("Check was stopped by the user.")
                progressTitle = "Check stopped"
            } catch {
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: false
                )
                let message = error.localizedDescription
                errorMessage = message
                progressLines.append(message)
                progressTitle = "Check failed"
            }
        }
    }

    func performSync() {
        guard canSync else { return }
        guard validateSelectedPaths() else { return }

        isSyncing = true
        progressTracker = RsyncProgressTracker(preview: preview)
        syncCompletedSummary = progressTracker.completedSummary
        syncCompletedFileCount = 0
        syncTotalFileCount = progressTracker.totalCount
        syncProgress = syncTotalFileCount > 0 ? 0 : nil
        syncPhase = .preparing
        errorMessage = nil
        beginSleepPrevention()
        progressLines = []
        progressTitle = "Checking rsync requirements…"
        showProgress = true

        let engine = SyncEngine(configuration: configuration)
        activeEngine = engine
        let lineBuffer = RsyncLineBuffer()
        let drainTask = startProgressDrain(
            lineBuffer,
            tracksFileProgress: true
        )

        Task { [weak self] in
            guard let self else { return }
            var transferCompleted = false

            defer {
                drainTask.cancel()
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: true
                )
                isSyncing = false
                activeEngine = nil
                endSleepPrevention()
            }

            do {
                let localInfo = try await validateAndRecordLocalRsync(
                    using: engine
                )
                progressLines.append("Local \(localInfo.displayLine)")

                if let remoteInfo = try await validateAndRecordRemoteRsync(
                    using: engine
                ) {
                    progressLines.append("Remote \(remoteInfo.displayLine)")
                }

                syncPhase = .synchronizing
                progressTitle = "Synchronizing…"

                try await engine.sync { lines in
                    lineBuffer.append(lines)
                }

                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: true
                )
                transferCompleted = true
                progressTracker.markAllCompleted()
                syncCompletedSummary = progressTracker.completedSummary
                syncCompletedFileCount = syncTotalFileCount
                syncProgress = syncTotalFileCount > 0 ? 1 : nil
                syncPhase = .verifying
                progressTitle = "Verifying…"
                progressLines.append("— Verification —")

                let output = try await engine.preview { lines in
                    lineBuffer.append(lines)
                }

                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: false
                )
                let verificationPreview = engine.parsePreview(output)
                hasChecked = true
                if verificationPreview.hasChanges {
                    syncPhase = .completedWithRemainingChanges
                    progressTitle = "Verification found remaining changes"
                    progressLines.append(
                        "Verification found items that still differ from the source."
                    )
                } else {
                    syncPhase = .completed
                    progressTitle = "Synchronization completed"
                }
            } catch SyncEngine.SyncEngineError.cancelled {
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: true
                )
                errorMessage = nil
                if transferCompleted {
                    syncPhase = .verificationStopped
                    progressLines.append(
                        "Synchronization completed, but verification was stopped by the user."
                    )
                    progressTitle = "Verification stopped"
                } else {
                    syncPhase = .synchronizationStopped
                    progressLines.append(
                        "Synchronization was stopped by the user."
                    )
                    progressTitle = "Synchronization stopped"
                }
            } catch {
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: true
                )
                let message = error.localizedDescription
                if transferCompleted {
                    syncPhase = .verificationFailed
                    errorMessage =
                        "Synchronization completed, but verification failed. " +
                        message
                    progressLines.append(errorMessage ?? message)
                    progressTitle = "Verification failed"
                } else {
                    syncPhase = .synchronizationFailed
                    errorMessage = message
                    progressLines.append(message)
                    progressTitle = "Synchronization failed"
                }
            }
        }
    }

    func stopCurrentOperation() {
        guard isBusy else { return }

        progressTitle = isSyncing
            ? "Stopping synchronization…"
            : "Stopping check…"
        activeEngine?.cancel()
    }

    func selectSource(path: String) {
        configuration.sourcePath = path.withTrailingSlash
        saveAndInvalidatePreview()
    }

    func selectDestination(_ profile: DestinationProfile) {
        guard configuration.destination != profile else { return }

        configuration.destination = profile
        prepareRemoteRsyncStatus()
        saveAndInvalidatePreview()
    }

    func selectLocalDestination(path: String) {
        configuration.destination = DestinationProfile(
            name: "Local folder",
            kind: .local,
            path: path.withTrailingSlash
        )
        prepareRemoteRsyncStatus()
        saveAndInvalidatePreview()
    }

    func loadRsyncVersion() async {
        let engine = SyncEngine(configuration: configuration)
        _ = try? await validateAndRecordLocalRsync(using: engine)
    }

    func loadRemoteRsyncVersion() async {
        let currentConfiguration = configuration

        guard currentConfiguration.destination.kind == .remote else {
            prepareRemoteRsyncStatus()
            return
        }

        let requestID = beginRemoteRsyncCheck(
            destinationName: currentConfiguration.destination.name
        )
        let engine = SyncEngine(configuration: currentConfiguration)

        do {
            guard let info = try await engine.validateRemoteRsync() else {
                return
            }

            guard !Task.isCancelled else { return }
            recordRemoteRsyncSuccess(
                info,
                configuration: currentConfiguration,
                requestID: requestID
            )
        } catch SyncEngine.SyncEngineError.cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            recordRemoteRsyncFailure(
                error,
                configuration: currentConfiguration,
                requestID: requestID
            )
        }
    }

    private func saveAndInvalidatePreview() {
        configurationStore.save(configuration)
        invalidatePreview(resetProgress: true)
    }

    private func validateSelectedPaths() -> Bool {
        do {
            try configurationValidator.validate(configuration)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func startProgressDrain(
        _ lineBuffer: RsyncLineBuffer,
        tracksFileProgress: Bool
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    break
                }

                guard let self else { return }
                consumeProgressLines(
                    lineBuffer.drain(),
                    tracksFileProgress: tracksFileProgress
                )
            }
        }
    }

    private func consumeProgressLines(
        _ lines: [String],
        tracksFileProgress: Bool
    ) {
        guard !lines.isEmpty else { return }

        guard tracksFileProgress, syncPhase == .synchronizing else {
            progressLines.append(contentsOf: lines)
            return
        }

        var logLines: [String] = []
        logLines.reserveCapacity(lines.count)

        for line in lines {
            guard let record = completedItemParser.parse(line) else {
                logLines.append(line)
                continue
            }

            logLines.append(record.displayLine)

            guard progressTracker.recordCompletion(for: record.path) else {
                continue
            }

            syncCompletedSummary = progressTracker.completedSummary
            syncCompletedFileCount = progressTracker.completedCount
            syncProgress = progressTracker.progress
        }

        progressLines.append(contentsOf: logLines)
    }

    private func validateAndRecordRemoteRsync(
        using engine: SyncEngine
    ) async throws -> RsyncVersionInfo? {
        let currentConfiguration = engine.configuration

        guard currentConfiguration.destination.kind == .remote else {
            return nil
        }

        let requestID = beginRemoteRsyncCheck(
            destinationName: currentConfiguration.destination.name
        )

        do {
            let info = try await engine.validateRemoteRsync()

            if let info {
                recordRemoteRsyncSuccess(
                    info,
                    configuration: currentConfiguration,
                    requestID: requestID
                )
            }

            return info
        } catch {
            recordRemoteRsyncFailure(
                error,
                configuration: currentConfiguration,
                requestID: requestID
            )
            throw error
        }
    }

    private func validateAndRecordLocalRsync(
        using engine: SyncEngine
    ) async throws -> RsyncVersionInfo {
        let currentConfiguration = engine.configuration
        let info: RsyncVersionInfo

        do {
            info = try await Task.detached(priority: .utility) {
                try SyncEngine(
                    configuration: currentConfiguration
                ).rsyncVersionInfo()
            }.value
        } catch {
            localRsyncStatus = .unavailable
            throw error
        }

        if info.version < RsyncRequirements.localMinimum {
            localRsyncStatus = .tooOld(info)
        } else if !info.supportsIconv {
            localRsyncStatus = .missingIconv(info)
        } else {
            localRsyncStatus = .available(info)
        }

        try SyncEngine.validate(
            info,
            location: "local",
            minimum: RsyncRequirements.localMinimum
        )

        return info
    }

    @discardableResult
    private func beginRemoteRsyncCheck(destinationName: String) -> UUID {
        let requestID = UUID()
        remoteStatusRequestID = requestID
        remoteRsyncStatus = .checking(destinationName: destinationName)
        return requestID
    }

    private func recordRemoteRsyncSuccess(
        _ info: RsyncVersionInfo,
        configuration checkedConfiguration: SyncConfiguration,
        requestID: UUID
    ) {
        guard remoteStatusRequestID == requestID,
              configuration.destination.id ==
                checkedConfiguration.destination.id else {
            return
        }

        remoteRsyncStatus = .available(
            destinationName: checkedConfiguration.destination.name,
            info: info
        )
    }

    private func recordRemoteRsyncFailure(
        _ error: Error,
        configuration checkedConfiguration: SyncConfiguration,
        requestID: UUID
    ) {
        guard remoteStatusRequestID == requestID,
              configuration.destination.id ==
                checkedConfiguration.destination.id else {
            return
        }

        remoteRsyncStatus = .failed(
            destinationName: checkedConfiguration.destination.name,
            message: error.localizedDescription
        )
    }

    private func prepareRemoteRsyncStatus() {
        remoteStatusRequestID = UUID()

        if configuration.destination.kind == .remote {
            remoteRsyncStatus = .checking(
                destinationName: configuration.destination.name
            )
        } else {
            remoteRsyncStatus = .notApplicable
        }
    }

    private var isLocalRsyncReady: Bool {
        if case .available = localRsyncStatus {
            return true
        }

        return false
    }

    private func invalidatePreview(resetProgress: Bool) {
        preview = SyncPreview()
        hasChecked = false
        errorMessage = nil

        if resetProgress {
            resetFileProgress()
            syncPhase = .idle
        }
    }

    private func resetFileProgress() {
        progressTracker = RsyncProgressTracker()
        syncCompletedFileCount = 0
        syncTotalFileCount = 0
        syncCompletedSummary = SyncSummary()
        syncProgress = nil
    }

    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }

        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "MusiCards Sync is synchronizing the music library."
        )
    }

    private func endSleepPrevention() {
        guard let sleepActivity else { return }

        ProcessInfo.processInfo.endActivity(sleepActivity)
        self.sleepActivity = nil
    }
}

private extension String {
    var withTrailingSlash: String {
        hasSuffix("/") ? self : self + "/"
    }
}
