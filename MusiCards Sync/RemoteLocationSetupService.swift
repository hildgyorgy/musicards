import Foundation

nonisolated final class RemoteLocationSetupService: Sendable {
    enum SetupError: LocalizedError {
        case passwordRequired
        case keyPairIsIncomplete
        case commandFailed(String)
        case pairingTimedOut

        var errorDescription: String? {
            switch self {
            case .passwordRequired:
                return "This remote location does not accept the MusiCards Sync key yet. Enter the SSH password once to pair it."
            case .keyPairIsIncomplete:
                return "The MusiCards Sync SSH key pair is incomplete. Remove the incomplete key files or choose another key location."
            case .commandFailed(let details):
                return details.isEmpty
                    ? "The remote location could not be paired."
                    : details
            case .pairingTimedOut:
                return "Pairing timed out. Check the hostname, port, and network connection."
            }
        }
    }

    func ensureKeyPair(at privateKeyPath: String) async throws {
        try await Task.detached(priority: .utility) {
            try Self.ensureKeyPairBlocking(at: privateKeyPath)
        }.value
    }

    func installPublicKey(
        for profile: DestinationProfile,
        password: String,
        privateKeyPath: String
    ) async throws {
        guard !password.isEmpty else { throw SetupError.passwordRequired }

        try await Task.detached(priority: .userInitiated) {
            try Self.ensureKeyPairBlocking(at: privateKeyPath)
            try Self.installPublicKeyBlocking(
                for: profile,
                password: password,
                privateKeyPath: privateKeyPath
            )
        }.value
    }

    private static func ensureKeyPairBlocking(at privateKeyPath: String) throws {
        let fileManager = FileManager.default
        let privateURL = URL(fileURLWithPath: privateKeyPath)
        let publicURL = URL(fileURLWithPath: privateKeyPath + ".pub")
        let privateExists = fileManager.fileExists(atPath: privateURL.path)
        let publicExists = fileManager.fileExists(atPath: publicURL.path)

        if privateExists && publicExists { return }
        if !privateExists && publicExists { throw SetupError.keyPairIsIncomplete }

        try fileManager.createDirectory(
            at: privateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if privateExists {
            let output = try runCommand(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-y", "-f", privateKeyPath]
            )
            try Data((output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
                .write(to: publicURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: publicURL.path
            )
            return
        }

        _ = try runCommand(
            executable: "/usr/bin/ssh-keygen",
            arguments: [
                "-q",
                "-t", "ed25519",
                "-N", "",
                "-C", "MusiCards Sync",
                "-f", privateKeyPath
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateURL.path
        )
    }

    private static func installPublicKeyBlocking(
        for profile: DestinationProfile,
        password: String,
        privateKeyPath: String
    ) throws {
        guard let user = profile.user, let host = profile.host else {
            throw SetupError.commandFailed(
                "Remote hostname and username are required."
            )
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-f", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        var environment = ProcessInfo.processInfo.environment
        environment["MUSICARDS_SYNC_PASSWORD"] = password
        environment["MUSICARDS_SYNC_PUBLIC_KEY"] = privateKeyPath + ".pub"
        environment["MUSICARDS_SYNC_USER"] = user
        environment["MUSICARDS_SYNC_HOST"] = host
        environment["MUSICARDS_SYNC_PORT"] = String(profile.sshPort)
        process.environment = environment

        let script = #"""
        set timeout 30
        log_user 1
        spawn /usr/bin/ssh-copy-id -i $env(MUSICARDS_SYNC_PUBLIC_KEY) -p $env(MUSICARDS_SYNC_PORT) -o StrictHostKeyChecking=accept-new "$env(MUSICARDS_SYNC_USER)@$env(MUSICARDS_SYNC_HOST)"
        expect {
            -re "(?i)are you sure.*yes/no" {
                send -- "yes\r"
                exp_continue
            }
            -re "(?i)password:" {
                send -- "$env(MUSICARDS_SYNC_PASSWORD)\r"
                exp_continue
            }
            timeout {
                exit 124
            }
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }
        """#

        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let details = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 124 {
            throw SetupError.pairingTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SetupError.commandFailed(details)
        }
    }

    @discardableResult
    private static func runCommand(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SetupError.commandFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}
