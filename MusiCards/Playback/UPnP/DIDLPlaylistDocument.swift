import Foundation

nonisolated enum RendererPlaylistError: LocalizedError {
    case unavailable
    case invalidQueue
    case tooLarge
    case notDownloaded
    case notConfirmed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The renderer's album playlist could not be prepared."
        case .invalidQueue: "The album does not contain a valid Navidrome playback queue."
        case .tooLarge: "This album playlist exceeds the renderer handoff limit."
        case .notDownloaded: "The renderer did not download the album playlist."
        case .notConfirmed: "The renderer did not confirm the complete album playlist."
        }
    }
}

nonisolated enum DIDLPlaylistDocument {
    static let maximumByteCount = 1_048_576
    static let profile = "DLNA.ORG_PN=DIDL_S"
    private static let opening = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
    """

    static func make(items: [PlaybackQueueItem], urls: [URL]) throws -> Data {
        guard !items.isEmpty, items.count == urls.count else { throw RendererPlaylistError.invalidQueue }
        guard items.count <= 1_000 else { throw RendererPlaylistError.tooLarge }
        var xml = opening
        for (index, item) in items.enumerated() {
            guard case .remoteAudio(let asset) = item.source, asset.source == .navidrome else {
                throw RendererPlaylistError.invalidQueue
            }
            xml += itemXML(item, url: urls[index], asset: asset, id: String(index + 1))
            guard xml.utf8.count <= maximumByteCount else { throw RendererPlaylistError.tooLarge }
        }
        xml += "</DIDL-Lite>"
        guard xml.utf8.count <= maximumByteCount else { throw RendererPlaylistError.tooLarge }
        return Data(xml.utf8)
    }

    static func trackMetadata(for item: PlaybackQueueItem, streamURL: URL, asset: RemotePlaybackAsset) -> String {
        opening + itemXML(item, url: streamURL, asset: asset, id: asset.providerItemID) + "</DIDL-Lite>"
    }

    static func metadata(title: String, url: URL) -> String {
        opening + """
        <item id="playlist" parentID="0" restricted="1"><dc:title>\(escape(title))</dc:title><upnp:class>object.item.playlistItem</upnp:class><res protocolInfo="http-get:*:text/xml:\(profile)">\(escape(url.absoluteString))</res></item></DIDL-Lite>
        """
    }

    private static func itemXML(_ item: PlaybackQueueItem, url: URL, asset: RemotePlaybackAsset, id: String) -> String {
        let track = item.track
        let mime = asset.contentType?.split(separator: ";", maxSplits: 1).first.map(String.init)
        let type = (mime?.isEmpty == false ? mime : nil) ?? mimeType(for: asset.suffix)
        let duration = track.duration.flatMap { value -> String? in
            guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
            let seconds = Int(value.rounded())
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        let durationAttribute = duration.map { " duration=\"\($0)\"" } ?? ""
        let artworkElement = track.releaseID.flatMap(UUID.init(uuidString:))
            .flatMap { CoverArtSize.thumbnail.url(for: $0.uuidString.lowercased()) }
            .map { "<upnp:albumArtURI>\(escape($0.absoluteString))</upnp:albumArtURI>" } ?? ""
        return """
        <item id="\(escape(id))" parentID="0" restricted="1"><dc:title>\(escape(track.title))</dc:title><upnp:artist>\(escape(track.artist))</upnp:artist><upnp:album>\(escape(track.albumTitle))</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class>\(artworkElement)<res protocolInfo="http-get:*:\(escape(type)):*"\(durationAttribute)>\(escape(url.absoluteString))</res></item>
        """
    }

    private static func mimeType(for suffix: String?) -> String {
        switch suffix?.lowercased() {
        case "flac": "audio/flac"
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: "application/octet-stream"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
