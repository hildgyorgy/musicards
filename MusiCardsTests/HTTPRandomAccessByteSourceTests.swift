#if DEBUG
import Foundation
import XCTest
@testable import MusiCards

final class HTTPRandomAccessByteSourceTests: XCTestCase {
    func testNearbyReadsReuseCachedChunks() async throws {
        let loader = RangeLoaderStub(length: 1_024)
        let source = try makeSource(loader: loader)

        let first = try await detachedRead(source, offset: 10, count: 20)
        let nearby = try await detachedRead(source, offset: 20, count: 20)
        let crossing = try await detachedRead(source, offset: 250, count: 20)

        XCTAssertEqual(first, expectedData(offset: 10, count: 20))
        XCTAssertEqual(nearby, expectedData(offset: 20, count: 20))
        XCTAssertEqual(crossing, expectedData(offset: 250, count: 20))
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(source.statistics.rangeRequestCount, 2)
        XCTAssertEqual(source.statistics.networkByteCount, 512)
    }

    func testConcurrentReadsCoalesceTheSameChunkLoad() async throws {
        let loader = RangeLoaderStub(
            length: 1_024,
            delayNanoseconds: 100_000_000
        )
        let source = try makeSource(loader: loader)

        async let first = detachedRead(source, offset: 40, count: 16)
        async let second = detachedRead(source, offset: 80, count: 16)
        let values = try await (first, second)

        XCTAssertEqual(values.0, expectedData(offset: 40, count: 16))
        XCTAssertEqual(values.1, expectedData(offset: 80, count: 16))
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(source.statistics.rangeRequestCount, 1)
    }

    func testCancellationWakesBlockedSynchronousReader() async throws {
        let loader = RangeLoaderStub(
            length: 1_024,
            delayNanoseconds: 5_000_000_000
        )
        let source = try makeSource(loader: loader)
        let readTask = Task.detached {
            try source.read(offset: 0, count: 16)
        }

        await waitUntil { await loader.requestCount() == 1 }
        source.cancel()

        do {
            _ = try await readTask.value
            XCTFail("The cancelled source unexpectedly returned data")
        } catch {
            XCTAssertEqual(
                error as? HTTPRandomAccessByteSourceError,
                .cancelled
            )
        }
    }

    func testNetworkSafetyLimitPreventsWholeResourceFetch() async throws {
        let loader = RangeLoaderStub(length: 1_024)
        let source = try makeSource(
            loader: loader,
            maximumNetworkByteCount: 256
        )

        _ = try await detachedRead(source, offset: 0, count: 16)
        do {
            _ = try await detachedRead(source, offset: 300, count: 16)
            XCTFail("A second chunk should exceed the proof safety limit")
        } catch {
            XCTAssertEqual(
                error as? HTTPRandomAccessByteSourceError,
                .networkLimitExceeded
            )
        }
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testTemporarySeekBudgetIsBoundedAndCanBeReleased() async throws {
        let loader = RangeLoaderStub(length: 1_024)
        let source = try makeSource(loader: loader)

        _ = try await detachedRead(source, offset: 0, count: 16)
        source.beginTemporaryNetworkBudget(additionalBytes: 256)
        _ = try await detachedRead(source, offset: 300, count: 16)

        do {
            _ = try await detachedRead(source, offset: 600, count: 16)
            XCTFail("A third chunk should exceed the temporary seek budget")
        } catch {
            XCTAssertEqual(
                error as? HTTPRandomAccessByteSourceError,
                .networkLimitExceeded
            )
        }

        source.endTemporaryNetworkBudget()
        let resumed = try await detachedRead(source, offset: 600, count: 16)
        XCTAssertEqual(resumed, expectedData(offset: 600, count: 16))
        let requestCount = await loader.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testMismatchedContentRangeIsRejected() async throws {
        let loader = RangeLoaderStub(
            length: 1_024,
            contentRangeOffset: 1
        )
        let source = try makeSource(loader: loader)

        do {
            _ = try await detachedRead(source, offset: 0, count: 16)
            XCTFail("A mismatched Content-Range should be rejected")
        } catch {
            guard case .invalidContentRange =
                    error as? HTTPRandomAccessByteSourceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeSource(
        loader: RangeLoaderStub,
        maximumNetworkByteCount: Int64 = .max
    ) throws -> HTTPRandomAccessByteSource {
        try HTTPRandomAccessByteSource(
            baseRequest: URLRequest(
                url: URL(string: "https://example.invalid/rest/stream")!
            ),
            length: 1_024,
            loader: loader,
            chunkSize: 256,
            maximumCachedChunkCount: 2,
            maximumNetworkByteCount: maximumNetworkByteCount
        )
    }

    private func expectedData(offset: Int, count: Int) -> Data {
        Data((offset..<(offset + count)).map { UInt8($0 % 251) })
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The expected asynchronous state did not arrive")
    }
}

private func detachedRead(
    _ source: HTTPRandomAccessByteSource,
    offset: Int64,
    count: Int
) async throws -> Data {
    try await Task.detached {
        try source.read(offset: offset, count: count)
    }.value
}

private actor RangeLoaderStub: HTTPRangeLoading {
    private let length: Int64
    private let delayNanoseconds: UInt64
    private let contentRangeOffset: Int64
    private var requests = [(Int64, Int64)]()

    init(
        length: Int64,
        delayNanoseconds: UInt64 = 0,
        contentRangeOffset: Int64 = 0
    ) {
        self.length = length
        self.delayNanoseconds = delayNanoseconds
        self.contentRangeOffset = contentRangeOffset
    }

    func load(
        request: URLRequest,
        start: Int64,
        end: Int64
    ) async throws -> HTTPRangeLoadResult {
        requests.append((start, end))
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let data = Data(
            (start...end).map { UInt8(Int($0) % 251) }
        )
        return HTTPRangeLoadResult(
            statusCode: 206,
            contentRange: "bytes \(start + contentRangeOffset)-\(end + contentRangeOffset)/\(length)",
            data: data,
            exceededLimit: false
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}
#endif
