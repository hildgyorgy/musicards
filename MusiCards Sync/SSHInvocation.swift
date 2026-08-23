import Foundation

/// The deliberately small, shared boundary between Sync configuration and
/// the command representations consumed by rsync and OpenSSH.
nonisolated enum SSHInvocation {
    static let executablePath = "/usr/bin/ssh"

    static let options: [String] = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ConnectionAttempts=1",
        "-o", "ControlMaster=no",
        "-o", "ControlPersist=no",
        "-o", "ControlPath=none"
    ]

    enum ValidationError: Error, Equatable {
        case invalidUsername
        case invalidHostname
        case invalidKeyPath
    }

    static func validate(username: String, hostname: String) throws {
        guard isValidUsername(username) else {
            throw ValidationError.invalidUsername
        }
        guard isValidHostname(hostname) else {
            throw ValidationError.invalidHostname
        }
    }

    static func isValidUsername(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            return false
        }

        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    static func isValidHostname(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            return false
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy({ label in
                  !label.isEmpty &&
                  !label.hasPrefix("-") &&
                  !label.hasSuffix("-") &&
                  label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              }) else {
            return false
        }

        // A conservative IPv4 check is useful here because IPv6 is
        // intentionally outside this patch's supported input space.
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }

        return true
    }

    static func remoteDestination(username: String, hostname: String, path: String) throws -> String {
        try validate(username: username, hostname: hostname)
        return "\(username)@\(hostname):\(path)"
    }

    /// Serializes the command passed to rsync's `-e` option. The key path is
    /// shell-quoted as one argument, so spaces and ordinary punctuation never
    /// become additional SSH arguments. No shell process is spawned by Sync.
    static func rsyncRemoteShell(keyPath: String, port: Int) throws -> String {
        guard !keyPath.isEmpty,
              keyPath.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
              }) else {
            throw ValidationError.invalidKeyPath
        }

        let serializedKeyPath = rsyncRemoteShellArgument(keyPath)
        return ([executablePath, "-i", serializedKeyPath, "-p", String(port)] + options)
            .joined(separator: " ")
    }

    /// Encodes one argument for rsync's own remote-shell parser. Rsync accepts
    /// single-quoted arguments and represents a literal apostrophe by doubling
    /// it; POSIX shell ` '\'' ` escaping is not valid here.
    static func rsyncRemoteShellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
