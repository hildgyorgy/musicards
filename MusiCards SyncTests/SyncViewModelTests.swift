import XCTest
@testable import MusiCards_Sync

final class SyncViewModelTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MusiCardsSyncTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testCheckRequiresASelectedSource() {
        let model = makeModel()

        XCTAssertFalse(model.canCheck)

        model.selectSource(path: "/tmp/Music")

        XCTAssertFalse(model.canCheck)

        model.addRemoteDestination(remoteDestination())

        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(model.configuration.sourcePath, "/tmp/Music/")
    }

    @MainActor
    func testCheckRequiresASelectedDestination() {
        let model = makeModel()
        model.selectSource(path: "/tmp/Music")

        XCTAssertEqual(model.configuration.destination, .unconfigured)
        XCTAssertFalse(model.canCheck)
    }

    @MainActor
    func testUnsupportedLocalRsyncDisablesCheck() {
        let model = makeModel()
        model.selectSource(path: "/tmp/Music")
        model.localRsyncStatus = .tooOld(
            RsyncVersionInfo(
                version: RsyncVersion(major: 3, minor: 1, patch: 3),
                displayLine: "rsync version 3.1.3",
                supportsIconv: true
            )
        )

        XCTAssertFalse(model.canCheck)
        XCTAssertTrue(model.localRsyncStatusIsError)
        XCTAssertTrue(model.localRsyncVersionText.contains("requires 3.2.6"))
    }

    @MainActor
    func testRemoteRsyncStatusShowsVersionAndDestination() {
        let model = makeModel()
        model.remoteRsyncStatus = .available(
            destinationName: "CasaOS – RPi 4",
            info: RsyncVersionInfo(
                version: RsyncVersion(major: 3, minor: 2, patch: 7),
                displayLine: "rsync version 3.2.7 protocol version 32",
                supportsIconv: true
            )
        )

        XCTAssertEqual(
            model.remoteRsyncVersionText,
            "Remote  rsync version 3.2.7 protocol version 32 · CasaOS – RPi 4"
        )
        XCTAssertFalse(model.remoteRsyncStatusIsError)
    }

    @MainActor
    func testLocalDestinationHidesRemoteRsyncStatus() {
        let model = makeModel()

        model.selectLocalDestination(path: "/tmp/Destination")

        XCTAssertNil(model.remoteRsyncVersionText)
    }

    @MainActor
    func testOverlappingLocalPathsStopBeforeCheckStarts() {
        let model = makeModel()
        model.selectSource(path: "/Volumes/Music")
        model.selectLocalDestination(path: "/Volumes/Music")

        model.checkSync()

        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(
            model.errorMessage,
            "Source and local destination must be different folders."
        )
    }

    @MainActor
    func testSyncStatusDistinguishesVerificationFailure() {
        let model = makeModel()
        model.syncProgress = 1
        model.syncPhase = .verificationFailed

        XCTAssertEqual(
            model.syncStatusText,
            "Synchronization completed — verification failed"
        )
    }

    @MainActor
    func testStoppedSyncKeepsPreviewAndDisplaysOnlyCompletedSummary() {
        let model = makeModel()
        model.preview.newFiles = (1...10).map { "track-\($0).m4a" }
        model.hasChecked = true
        model.syncCompletedSummary = SyncSummary(
            newFiles: 3,
            modifiedFiles: 1,
            newFolders: 2,
            deletedFiles: 0,
            deletedFolders: 0,
            systemCleanup: 1
        )
        model.syncCompletedFileCount = 3
        model.syncTotalFileCount = 10
        model.libraryIndexSyncSummary = LibraryIndexSyncSummary(
            indexGenerated: true,
            previousIndexRemoved: true,
            newIndexPublished: false,
            musicBrainzReadyAlbumCount: 35,
            totalAlbumCount: 1_250
        )
        model.syncPhase = .synchronizationStopped

        XCTAssertEqual(model.preview.newFiles.count, 10)
        XCTAssertEqual(
            model.displayedSyncSummary,
            model.syncCompletedSummary
        )
        XCTAssertEqual(model.syncFileProgressText, "3 files completed")
        XCTAssertEqual(
            model.displayedLibraryIndexSyncSummary,
            LibraryIndexSyncSummary(
                indexGenerated: true,
                previousIndexRemoved: true,
                newIndexPublished: false,
                musicBrainzReadyAlbumCount: 35,
                totalAlbumCount: 1_250
            )
        )
        XCTAssertFalse(model.canSync)

        model.syncPhase = .completed

        XCTAssertEqual(
            model.displayedSyncSummary,
            model.syncCompletedSummary
        )
        XCTAssertEqual(model.preview.newFiles.count, 10)

        model.syncPhase = .synchronizing

        XCTAssertEqual(model.syncFileProgressText, "3 / 10 files")
    }

    @MainActor
    func testLineBufferPreservesOrderAcrossBatches() {
        let buffer = RsyncLineBuffer()

        buffer.append(["one", "two"])
        buffer.append(["three"])

        XCTAssertEqual(buffer.drain(), ["one", "two", "three"])
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    @MainActor
    func testDestinationChangeInvalidatesPreviousPreview() {
        let model = makeModel()
        model.preview.newFiles = ["album/track.m4a"]
        model.hasChecked = true
        model.syncProgress = 0.5

        let destination = remoteDestination()
        model.addRemoteDestination(destination)

        XCTAssertFalse(model.hasChecked)
        XCTAssertFalse(model.preview.hasChanges)
        XCTAssertNil(model.syncProgress)
        XCTAssertEqual(model.configuration.destination, destination)
    }

    @MainActor
    func testPreviouslySelectedRemoteDestinationMigratesIntoProfileStore() {
        let destination = remoteDestination()
        var configuration = SyncConfiguration.defaultConfiguration
        configuration.destination = destination
        SyncConfigurationStore(userDefaults: userDefaults).save(configuration)

        let model = makeModel()

        XCTAssertEqual(model.configuration.destination, destination)
        XCTAssertEqual(model.remoteDestinations, [destination])
        XCTAssertEqual(
            RemoteDestinationStore(userDefaults: userDefaults).load(),
            [destination]
        )
    }

    @MainActor
    func testRemovingSelectedRemoteKeepsNoEndpointInConfiguration() {
        let model = makeModel()
        model.addRemoteDestination(remoteDestination())

        model.removeCurrentRemoteDestination()

        XCTAssertEqual(model.configuration.destination, .unconfigured)
        XCTAssertTrue(model.remoteDestinations.isEmpty)
        XCTAssertFalse(model.canCheck)
    }

    @MainActor
    func testCompletedCheckAllowsIndexOnlySyncWithoutFileChanges() {
        let model = makeModel()
        model.selectSource(path: "/tmp/Music")
        model.hasChecked = true
        model.preview = SyncPreview()

        XCTAssertTrue(model.canSync)
    }

    @MainActor
    func testUnavailableLocalDestinationIsNotOfferedAndInvalidatesPreview() {
        let model = makeModel()
        let missingPath = "/Volumes/Missing-\(UUID().uuidString)"

        model.selectLocalDestination(path: missingPath)
        model.preview.newFiles = ["album/track.m4a"]
        model.hasChecked = true

        XCTAssertFalse(
            model.destinationOptions.contains(model.configuration.destination)
        )

        model.localVolumesDidChange()

        XCTAssertFalse(model.hasChecked)
        XCTAssertFalse(model.preview.hasChanges)
        XCTAssertTrue(
            model.errorMessage?.contains(
                "local destination folder is not available"
            ) == true
        )
    }

    @MainActor
    func testConfirmationMentionsDestinationDeletions() {
        let model = makeModel()
        model.preview.deletedFiles = ["old.m4a", "other.m4a"]
        model.preview.deletedFolders = ["old-album/"]

        XCTAssertTrue(
            model.syncConfirmationMessage.contains(
                "2 file(s) and 1 folder(s) will be deleted"
            )
        )
    }

    @MainActor
    private func makeModel() -> SyncViewModel {
        let model = SyncViewModel(
            configurationStore: SyncConfigurationStore(userDefaults: userDefaults),
            remoteDestinationStore: RemoteDestinationStore(
                userDefaults: userDefaults
            )
        )

        model.localRsyncStatus = .available(
            RsyncVersionInfo(
                version: RsyncVersion(major: 3, minor: 4, patch: 4),
                displayLine: "rsync version 3.4.4",
                supportsIconv: true
            )
        )

        return model
    }

    @MainActor
    private func remoteDestination() -> DestinationProfile {
        DestinationProfile(
            name: "Test server",
            kind: .remote,
            user: "music",
            host: "server.local",
            path: "/srv/music/"
        )
    }
}
