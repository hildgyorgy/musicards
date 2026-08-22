#if DEBUG && os(macOS)
import Foundation
import XCTest
@testable import MusiCards

final class RemoteAudioFileDecoderTests: XCTestCase {
    @MainActor
    func testProductionRemoteDecoderPrimesCallbackBackedPCM() async throws {
        let wave = makePCM16Wave(sampleRate: 8_000, seconds: 2)
        let loader = DataRangeLoader(data: wave)
        let byteSource = try HTTPRandomAccessByteSource(
            baseRequest: URLRequest(
                url: URL(string: "https://example.invalid/rest/stream")!
            ),
            length: Int64(wave.count),
            loader: loader,
            chunkSize: 4_096,
            maximumCachedChunkCount: 8
        )
        let asset = RemotePlaybackAsset(
            source: .navidrome,
            providerItemID: "debug-wave",
            displayName: "NAVIDROME",
            mediaSize: Int64(wave.count),
            suffix: "wav",
            contentType: "audio/wav",
            byteSourceProvider: RemoteByteSourceProviderStub(
                source: byteSource
            )
        )

        let decodedPCM = try await Task.detached {
            try RemoteAudioFileDecoder.decode(
                asset: asset,
                byteSource: byteSource
            )
        }.value
        defer { decodedPCM.cancel() }

        XCTAssertTrue(decodedPCM.isRemote)
        XCTAssertEqual(decodedPCM.sampleRate, 8_000)
        XCTAssertEqual(decodedPCM.channelCount, 1)
        XCTAssertEqual(decodedPCM.frameCount, 16_000)
        XCTAssertGreaterThan(byteSource.statistics.networkByteCount, 0)
        XCTAssertLessThanOrEqual(
            byteSource.statistics.networkByteCount,
            Int64(wave.count)
        )
    }

    func testExistingLocalDecoderStillProducesPCM() async throws {
        let wave = makePCM16Wave(sampleRate: 8_000, seconds: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicards-local-decoder-\(UUID().uuidString).wav"
        )
        try wave.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let decodedPCM = try await Task.detached {
            try LocalAudioFileDecoder.decode(url: url)
        }.value
        defer { decodedPCM.cancel() }

        XCTAssertFalse(decodedPCM.isRemote)
        XCTAssertEqual(decodedPCM.sampleRate, 8_000)
        XCTAssertEqual(decodedPCM.channelCount, 1)
        XCTAssertEqual(decodedPCM.frameCount, 16_000)
    }

    private func makePCM16Wave(sampleRate: Int, seconds: Int) -> Data {
        let frameCount = sampleRate * seconds
        let dataByteCount = frameCount * MemoryLayout<Int16>.size
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataByteCount))
        for frame in 0..<frameCount {
            let sample = Int16(
                sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate))
                    * Double(Int16.max / 4)
            )
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

@MainActor
private final class RemoteByteSourceProviderStub:
    RemoteAudioByteSourceProviding
{
    private let source: HTTPRandomAccessByteSource

    init(source: HTTPRandomAccessByteSource) {
        self.source = source
    }

    func makeByteSource() throws -> HTTPRandomAccessByteSource {
        source
    }
}

private actor DataRangeLoader: HTTPRangeLoading {
    private let data: Data
    private var requests = 0

    init(data: Data) {
        self.data = data
    }

    func load(
        request: URLRequest,
        start: Int64,
        end: Int64
    ) async throws -> HTTPRangeLoadResult {
        requests += 1
        let range = Int(start)..<(Int(end) + 1)
        return HTTPRangeLoadResult(
            statusCode: 206,
            contentRange: "bytes \(start)-\(end)/\(data.count)",
            data: data.subdata(in: range),
            exceededLimit: false
        )
    }

    func requestCount() -> Int {
        requests
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif
