#if DEBUG && (os(macOS) || os(iOS))
import Foundation
import XCTest
@testable import MusiCards

final class LibFLACRemoteAudioDecoderTests: XCTestCase {
    func testBridgeRejectsMissingCallbacksAndRepeatInitialization() throws {
        let read: MCPFLACReadCallback = { _, _, count in count?.pointee = 0; return 1 }
        let seek: MCPFLACSeekCallback = { _, _ in 0 }
        let tell: MCPFLACTellCallback = { _, offset in offset?.pointee = 0; return 0 }
        let length: MCPFLACLengthCallback = { _, size in size?.pointee = 0; return 0 }
        let eof: MCPFLACEofCallback = { _ in true }
        let write: MCPFLACWriteCallback = { _, _, _, _, _ in 0 }
        let metadata: MCPFLACMetadataCallback = { _, _, _, _, _ in }
        let error: MCPFLACErrorCallback = { _, _ in }
        for missing in 0..<9 {
            let context = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            context.initialize(to: 0)
            defer { context.deinitialize(count: 1); context.deallocate() }
            let decoder = try XCTUnwrap(MCPFLACDecoderCreate())
            defer { MCPFLACDecoderDestroy(decoder) }
            let status = MCPFLACDecoderInitialize(
                decoder, missing == 0 ? nil : read, missing == 1 ? nil : seek,
                missing == 2 ? nil : tell, missing == 3 ? nil : length,
                missing == 4 ? nil : eof, missing == 5 ? nil : write,
                missing == 6 ? nil : metadata, missing == 7 ? nil : error,
                missing == 8 ? nil : UnsafeMutableRawPointer(context)
            )
            XCTAssertEqual(status, -1, "Missing callback/context \(missing) must be rejected")
            // Rejection must leave the wrapper usable for a complete setup.
            XCTAssertEqual(MCPFLACDecoderInitialize(decoder, read, seek, tell, length, eof, write, metadata, error, context), 0)
            XCTAssertEqual(MCPFLACDecoderInitialize(decoder, read, seek, tell, length, eof, write, metadata, error, context), -1)
        }
    }

    func testMetadataAndSequential16BitDecodeFromRangeSource() throws {
        let fixture = try loadFixture(named: "remote-stereo-16")
        let source = try makeSource(fixture)
        let backend = try LibFLACPCMDecoderBackend(
            byteSource: source,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        defer { backend.cancel() }

        XCTAssertEqual(backend.format.sampleRate, 44_100)
        XCTAssertEqual(backend.format.channelCount, 2)
        XCTAssertEqual(backend.bitsPerSample, 16)
        XCTAssertEqual(backend.frameCount, 308_700)
        XCTAssertEqual(backend.seekCapabilityOverride, .supported)

        var samples = [Float](repeating: 0, count: 2 * 4_096)
        let framesRead = try samples.withUnsafeMutableBytes { bytes in
            try backend.read(
                into: bytes.baseAddress!,
                frameCapacity: 4_096
            )
        }
        XCTAssertEqual(framesRead, 4_096)
        XCTAssertGreaterThan(samples.reduce(0) { $0 + abs($1) }, 0)
    }

    func test24BitMetadataAndFloatConversion() throws {
        let fixture = try loadFixture(named: "remote-stereo-24")
        let source = try makeSource(fixture)
        let backend = try LibFLACPCMDecoderBackend(
            byteSource: source,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        defer { backend.cancel() }

        XCTAssertEqual(backend.format.sampleRate, 96_000)
        XCTAssertEqual(backend.format.channelCount, 2)
        XCTAssertEqual(backend.bitsPerSample, 24)
        XCTAssertEqual(backend.frameCount, 838_036)

        var samples = [Float](repeating: 0, count: 2 * 16)
        let framesRead = try samples.withUnsafeMutableBytes { bytes in
            try backend.read(
                into: bytes.baseAddress!,
                frameCapacity: 16
            )
        }
        XCTAssertEqual(framesRead, 16)
        XCTAssertGreaterThan(abs(samples[0]), 0.0001)
        XCTAssertGreaterThan(abs(samples[1]), 0.0001)
    }

    func testAbsoluteForwardBackwardAndRepeatedSeek() throws {
        let fixture = try loadFixture(named: "remote-stereo-16")
        let source = try makeSource(fixture)
        let backend = try LibFLACPCMDecoderBackend(
            byteSource: source,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        defer { backend.cancel() }

        for frame in [1_000, 100, 1_800, 24, 300_000, 512, 120_000] {
            try backend.seek(to: UInt64(frame))
            var samples = [Float](repeating: 0, count: 2)
            let framesRead = try samples.withUnsafeMutableBytes { bytes in
                try backend.read(
                    into: bytes.baseAddress!,
                    frameCapacity: 1
                )
            }
            XCTAssertEqual(framesRead, 1)
            let comparisonSource = try loadSource(
                try loadFixture(named: "remote-stereo-16")
            )
            let comparisonBackend = try LibFLACPCMDecoderBackend(
                byteSource: comparisonSource,
                startedAt: DispatchTime.now().uptimeNanoseconds
            )
            defer { comparisonBackend.cancel() }
            try comparisonBackend.seek(to: UInt64(frame))
            var expected = [Float](repeating: 0, count: 2)
            _ = try expected.withUnsafeMutableBytes { bytes in
                try comparisonBackend.read(
                    into: bytes.baseAddress!,
                    frameCapacity: 1
                )
            }
            XCTAssertEqual(samples, expected, "first PCM after seek to frame \(frame)")
        }
    }

    @MainActor
    func testDecodedPCMSeekResetsRendererTimeline() throws {
        let fixture = try loadFixture(named: "remote-stereo-16")
        let source = try makeSource(fixture)
        let asset = RemotePlaybackAsset(
            source: .navidrome,
            providerItemID: "libflac-test",
            displayName: "libFLAC test",
            mediaSize: Int64(fixture.count),
            suffix: "flac",
            contentType: "audio/flac",
            byteSourceProvider: TestByteSourceProvider(source: source)
        )
        let decodedPCM = try LibFLACRemoteAudioDecoder.decode(
            asset: asset,
            byteSource: source
        )
        defer { decodedPCM.cancel() }

        try decodedPCM.seek(to: 1_000)
        XCTAssertEqual(
            MCPPCMRendererCurrentFrame(decodedPCM.renderer),
            1_000
        )

        try decodedPCM.seek(to: 100)
        XCTAssertEqual(
            MCPPCMRendererCurrentFrame(decodedPCM.renderer),
            100
        )
    }

    private func makeSource(_ data: Data) throws -> HTTPRandomAccessByteSource {
        try loadSource(data)
    }

    private func loadSource(_ data: Data) throws -> HTTPRandomAccessByteSource {
        try HTTPRandomAccessByteSource(
            baseRequest: URLRequest(
                url: URL(string: "https://example.invalid/libflac-test")!
            ),
            length: Int64(data.count),
            loader: DataRangeLoader(data: data),
            chunkSize: 256,
            maximumCachedChunkCount: 8
        )
    }

    private func loadFixture(named name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(
            forResource: name,
            withExtension: "flac"
        ) else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }
}

private enum FixtureError: Error {
    case missing(String)
}

@MainActor
private final class TestByteSourceProvider:
    RemoteAudioByteSourceProviding, @unchecked Sendable
{
    let source: HTTPRandomAccessByteSource

    init(source: HTTPRandomAccessByteSource) {
        self.source = source
    }

    func makeByteSource() throws -> HTTPRandomAccessByteSource { source }
}

private actor DataRangeLoader: HTTPRangeLoading {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    func load(
        request: URLRequest,
        start: Int64,
        end: Int64
    ) async throws -> HTTPRangeLoadResult {
        let range = Int(start)..<(Int(end) + 1)
        return HTTPRangeLoadResult(
            statusCode: 206,
            contentRange: "bytes \(start)-\(end)/\(data.count)",
            data: data.subdata(in: range),
            exceededLimit: false
        )
    }
}

#endif
