import Foundation

nonisolated final class RsyncOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let capturesCompleteOutput: Bool

    private var completeOutput = ""
    private var recentOutput = ""
    private var pendingText = ""
    private var ignoresLeadingLineFeed = false

    init(capturesCompleteOutput: Bool = true) {
        self.capturesCompleteOutput = capturesCompleteOutput
    }

    func append(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        if capturesCompleteOutput {
            completeOutput += chunk
        }

        recentOutput += chunk
        if recentOutput.count > 4_096 {
            recentOutput = String(recentOutput.suffix(4_096))
        }

        pendingText += chunk

        var lines: [String] = []

        while !pendingText.isEmpty {
            if ignoresLeadingLineFeed {
                if pendingText.unicodeScalars.first == "\n" {
                    pendingText.unicodeScalars.removeFirst()
                }

                ignoresLeadingLineFeed = false
            }

            guard let separator = pendingText.unicodeScalars.firstIndex(
                where: { $0 == "\n" || $0 == "\r" }
            ) else {
                break
            }

            let separatorValue = pendingText.unicodeScalars[separator]
            let line = String(pendingText.unicodeScalars[..<separator])
            let nextIndex = pendingText.unicodeScalars.index(after: separator)

            pendingText = String(pendingText.unicodeScalars[nextIndex...])
            ignoresLeadingLineFeed = separatorValue == "\r"

            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }

    func finish() -> (
        output: String,
        recentOutput: String,
        finalLine: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        let finalLine = pendingText.isEmpty
            ? nil
            : pendingText

        pendingText = ""

        return (
            output: completeOutput,
            recentOutput: recentOutput,
            finalLine: finalLine
        )
    }
}
nonisolated private final class RsyncProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !cancellationRequested else {
            throw SyncEngine.SyncEngineError.cancelled
        }

        self.process = process

        do {
            try process.run()
        } catch {
            self.process = nil
            throw error
        }
    }

    func clearProcess() {
        lock.lock(); defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning { runningProcess.terminate() }
    }

    func wasCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationRequested
    }
}

nonisolated final class SyncEngine {

    let configuration: SyncConfiguration
    private let processState = RsyncProcessState()

    enum SyncEngineError: LocalizedError {
        case rsyncNotFound
        case invalidRsyncVersion(location: String)
        case rsyncTooOld(
            location: String,
            found: RsyncVersion,
            required: RsyncVersion
        )
        case rsyncMissingIconv(location: String)
        case remoteRsyncUnavailable(details: String)
        case rsyncFailed(exitCode: Int32, details: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .rsyncNotFound:
                return "The required rsync executable was not found."
            case .invalidRsyncVersion(let location):
                return "The \(location) rsync version could not be determined."
            case .rsyncTooOld(let location, let found, let required):
                return "The \(location) rsync version is \(found.displayString). Version \(required.displayString) or newer is required."
            case .rsyncMissingIconv(let location):
                return "The \(location) rsync does not include the required iconv support."
            case .remoteRsyncUnavailable(let details):
                return details.isEmpty
                    ? "The remote rsync installation could not be verified."
                    : "The remote rsync installation could not be verified. \(details)"
            case .rsyncFailed(let exitCode, let details):
                return details.isEmpty
                    ? "rsync failed with exit code \(exitCode)."
                    : "rsync failed with exit code \(exitCode). \(details)"
            case .cancelled:
                return "Synchronization stopped."
            }
        }
    }

    init(
        configuration: SyncConfiguration = .defaultConfiguration
    ) {
        self.configuration = configuration
    }

    func cancel() {
        processState.cancel()
    }

    func checkRsync() throws {
        let path = configuration.rsyncPath

        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw SyncEngineError.rsyncNotFound
        }
    }

    func rsyncVersionInfo() throws -> RsyncVersionInfo {
        try checkRsync()

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: configuration.rsyncPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SyncEngineError.rsyncNotFound
        }

        guard let info = RsyncVersionParser().parse(output) else {
            throw SyncEngineError.invalidRsyncVersion(location: "local")
        }

        return info
    }

    func validateRemoteRsync() async throws -> RsyncVersionInfo? {
        guard configuration.destination.kind == .remote else {
            return nil
        }

        let configuration = self.configuration
        let processState = self.processState

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let info = try Self.remoteRsyncVersionBlocking(
                        configuration: configuration,
                        processState: processState
                    )

                    continuation.resume(returning: info)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func parsePreview(_ output: String) -> SyncPreview {
        RsyncPreviewParser().parse(output)
    }

    func preview(
        onOutput: @escaping @Sendable ([String]) -> Void = { _ in }
    ) async throws -> String {
        try await runRsync(
            dryRun: true,
            onOutput: onOutput
        )
    }

    func sync(
        onOutput: @escaping @Sendable ([String]) -> Void = { _ in }
    ) async throws {
        _ = try await runRsync(
            dryRun: false,
            onOutput: onOutput
        )
    }

    private func runRsync(
        dryRun: Bool,
        onOutput: @escaping @Sendable ([String]) -> Void
    ) async throws -> String {

        let configuration = self.configuration
        let processState = self.processState

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Self.runRsyncBlocking(
                        configuration: configuration,
                        dryRun: dryRun,
                        processState: processState,
                        onOutput: onOutput
                    )

                    continuation.resume(returning: output)

                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runRsyncBlocking(
        configuration: SyncConfiguration,
        dryRun: Bool,
        processState: RsyncProcessState,
        onOutput: @escaping @Sendable ([String]) -> Void
    ) throws -> String {

        guard FileManager.default.isExecutableFile(
            atPath: configuration.rsyncPath
        ) else {
            throw SyncEngineError.rsyncNotFound
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL =
            URL(fileURLWithPath: configuration.rsyncPath)

        process.arguments = rsyncArguments(
            configuration: configuration,
            dryRun: dryRun
        )

        process.standardOutput = pipe
        process.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        let outputState = RsyncOutputState(
            capturesCompleteOutput: dryRun
        )
        let pipeReadLock = NSLock()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            pipeReadLock.lock()
            defer { pipeReadLock.unlock() }

            let data = handle.availableData

            guard !data.isEmpty else {
                return
            }

            let chunk = String(
                decoding: data,
                as: UTF8.self
            )

            let lines = outputState.append(chunk)

            if !lines.isEmpty {
                onOutput(lines)
            }
        }

        process.terminationHandler = { _ in
            finished.signal()
        }

        defer { processState.clearProcess() }

        try processState.start(process)
        finished.wait()

        pipe.fileHandleForReading.readabilityHandler = nil

        let wasCancelled = processState.wasCancelled()

        if !wasCancelled {
            pipeReadLock.lock()
            let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
            pipeReadLock.unlock()

            if !remainingData.isEmpty {
                let remainingChunk = String(decoding: remainingData, as: UTF8.self)

                let remainingLines = outputState.append(remainingChunk)
                if !remainingLines.isEmpty {
                    onOutput(remainingLines)
                }
            }
        }

        let finalOutput = outputState.finish()

        if !wasCancelled,
           let finalLine = finalOutput.finalLine,
           !finalLine.isEmpty {
            onOutput([finalLine])
        }

        if wasCancelled {
            throw SyncEngineError.cancelled
        }

        guard process.terminationStatus == 0 else {
            throw SyncEngineError.rsyncFailed(
                exitCode: process.terminationStatus,
                details: finalOutput.recentOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return finalOutput.output
    }

    private static func remoteRsyncVersionBlocking(
        configuration: SyncConfiguration,
        processState: RsyncProcessState
    ) throws -> RsyncVersionInfo {
        guard let user = configuration.destination.user,
              let host = configuration.destination.host else {
            throw SyncEngineError.remoteRsyncUnavailable(details: "")
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-i", configuration.sshKeyPath,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=none",
            "\(user)@\(host)",
            "rsync --version"
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        defer { processState.clearProcess() }

        try processState.start(process)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if processState.wasCancelled() {
            throw SyncEngineError.cancelled
        }

        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw SyncEngineError.remoteRsyncUnavailable(
                details: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let info = RsyncVersionParser().parse(output) else {
            throw SyncEngineError.invalidRsyncVersion(location: "remote")
        }

        try validate(
            info,
            location: "remote",
            minimum: RsyncRequirements.remoteMinimum
        )

        return info
    }

    static func validate(
        _ info: RsyncVersionInfo,
        location: String,
        minimum: RsyncVersion
    ) throws {
        guard info.version >= minimum else {
            throw SyncEngineError.rsyncTooOld(
                location: location,
                found: info.version,
                required: minimum
            )
        }

        guard info.supportsIconv else {
            throw SyncEngineError.rsyncMissingIconv(location: location)
        }
    }

    static func rsyncArguments(
        configuration: SyncConfiguration,
        dryRun: Bool
    ) -> [String] {

        var arguments: [String] = [
            "-av",
            "--itemize-changes",
            "--delete",
            "--delete-excluded",
            "--iconv=UTF-8-MAC,UTF-8",
            "--secluded-args",

            "--exclude=.DS_Store",
            "--exclude=._*",
            "--exclude=.Spotlight-V100",
            "--exclude=.Trashes",

        ]
        switch configuration.destination.kind {

        case .remote:
            arguments.append("--timeout=30")
            arguments.append(contentsOf: [
            "-e",
            """
            ssh -i \(configuration.sshKeyPath) \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o ConnectionAttempts=1 \
            -o ControlMaster=no \
            -o ControlPersist=no \
            -o ControlPath=none
            """
        ])

        case .local:
            break
        }

        if dryRun {
            arguments.append("--dry-run")
            arguments.append("--out-format=%i|%n")
        } else {
            // %b is a transfer-statistic escape, so rsync emits each itemized
            // file line after that file has finished instead of before it starts.
            arguments.append("--out-format=%i|%n|%b")
            arguments.append("--no-inc-recursive")
            arguments.append("--outbuf=L")
        }

        arguments.append(configuration.sourcePath)
        arguments.append(
            configuration.destination.remoteDestination
        )

        return arguments
    }
}
