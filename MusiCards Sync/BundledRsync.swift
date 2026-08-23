import Foundation

nonisolated enum BundledRsync {
    static let executableName = "rsync"

    static func executableURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forAuxiliaryExecutable: executableName)
    }
}
