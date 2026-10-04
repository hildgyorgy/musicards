import Foundation

enum DIDLLiteMetadataError: Error, Equatable {
    case missingMIMEType
}

/// Builds the metadata sent with a renderer's CurrentURI or NextURI.
enum DIDLLiteMetadataBuilder {
    static func makeMetadata(
        for track: PlaybackTrack,
        itemID: String,
        streamURL: URL,
        mimeType: String
    ) throws -> String {
        let mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mimeType.isEmpty else {
            throw DIDLLiteMetadataError.missingMIMEType
        }

        let durationAttribute: String
        if let duration = track.duration,
           duration.isFinite,
           duration >= 0,
           duration < Double(Int.max) {
            let seconds = Int(duration)
            let clock = String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds % 3_600) / 60,
                seconds % 60
            )
            durationAttribute = " duration=\"\(clock)\""
        } else {
            durationAttribute = ""
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="\(escape(itemID))" parentID="0" restricted="1"><dc:title>\(escape(track.title))</dc:title><upnp:artist>\(escape(track.artist))</upnp:artist><upnp:album>\(escape(track.albumTitle))</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo="http-get:*:\(escape(mimeType)):*"\(durationAttribute)>\(escape(streamURL.absoluteString))</res></item></DIDL-Lite>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
