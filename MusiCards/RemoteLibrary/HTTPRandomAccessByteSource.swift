import Foundation

nonisolated struct NavidromeHTTPContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?

    static func parse(_ value: String?) -> Self? {
        guard let value else { return nil }
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2,
              pieces[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = pieces[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        let total = rangeAndTotal[1] == "*"
            ? nil : Int64(rangeAndTotal[1])
        if let total, total <= end { return nil }
        return Self(start: start, end: end, total: total)
    }
}

nonisolated struct HTTPRangeLoadResult: Sendable {
    let statusCode: Int
    let contentRange: String?
    let data: Data
    let exceededLimit: Bool
}

nonisolated protocol HTTPRangeLoading: Sendable {
    func load(
        request: URLRequest,
        start: Int64,
        end: Int64
    ) async throws -> HTTPRangeLoadResult
}

nonisolated final class URLSessionHTTPRangeLoader: HTTPRangeLoading,
    @unchecked Sendable
{
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    func load(
        request baseRequest: URLRequest,
        start: Int64,
        end: Int64
    ) async throws -> HTTPRangeLoadResult {
        var request = baseRequest
        request.setValue(
            "bytes=\(start)-\(end)",
            forHTTPHeaderField: "Range"
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw HTTPRandomAccessByteSourceError.invalidHTTPResponse
        }

        let expectedCount = Int(end - start + 1)
        let captureLimit = expectedCount + 1
        var data = Data()
        data.reserveCapacity(captureLimit)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= captureLimit {
                bytes.task.cancel()
                break
            }
        }

        return HTTPRangeLoadResult(
            statusCode: response.statusCode,
            contentRange: response.value(
                forHTTPHeaderField: "Content-Range"
            ),
            data: data,
            exceededLimit: data.count > expectedCount
        )
    }
}

nonisolated struct HTTPRangeAccessTrace: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let statusCode: Int
    let byteCount: Int

    var summary: String {
        "bytes=\(start)-\(end) status=\(statusCode) bytes=\(byteCount)"
    }
}

nonisolated struct HTTPRandomAccessStatistics: Equatable, Sendable {
    let rangeRequestCount: Int
    let networkByteCount: Int64
    let cachedByteCount: Int64
    let trace: [HTTPRangeAccessTrace]
}

nonisolated enum HTTPRandomAccessByteSourceError:
    LocalizedError, Equatable, Sendable
{
    case invalidLength
    case invalidRead
    case invalidHTTPResponse
    case unexpectedStatus(Int)
    case invalidContentRange(String?)
    case unexpectedByteCount(expected: Int, actual: Int)
    case networkLimitExceeded
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            "The remote media length is unavailable."
        case .invalidRead:
            "Core Audio requested an invalid remote byte range."
        case .invalidHTTPResponse:
            "The remote media request did not return an HTTP response."
        case .unexpectedStatus(let status):
            "The remote server returned HTTP status \(status) for a byte range."
        case .invalidContentRange:
            "The remote server returned a mismatched Content-Range."
        case .unexpectedByteCount(let expected, let actual):
            "The remote byte range returned \(actual) bytes instead of \(expected)."
        case .networkLimitExceeded:
            "Remote seeking exceeded its bounded network-read limit."
        case .cancelled:
            "The remote byte source was cancelled."
        }
    }
}

/// A bounded, in-memory, random-access view of one authenticated HTTP media
/// resource. Its synchronous read API is suitable for AudioFile callbacks;
/// network work is performed by coalesced asynchronous chunk loads.
nonisolated final class HTTPRandomAccessByteSource: @unchecked Sendable {
    let length: Int64

    private let baseRequest: URLRequest
    private let loader: any HTTPRangeLoading
    private let chunkSize: Int64
    private let maximumCachedChunkCount: Int
    private let maximumNetworkByteCount: Int64
    private let condition = NSCondition()
    private var cachedChunks = [Int64: Data]()
    private var cacheRecency = [Int64]()
    private var inFlightLoads = [Int64: ChunkLoad]()
    private var isCancelled = false
    private var rangeRequestCount = 0
    private var networkByteCount: Int64 = 0
    private var reservedNetworkByteCount: Int64 = 0
    private var temporaryNetworkByteLimit: Int64?
    private var trace = [HTTPRangeAccessTrace]()

    init(
        baseRequest: URLRequest,
        length: Int64,
        loader: any HTTPRangeLoading = URLSessionHTTPRangeLoader(),
        chunkSize: Int64 = 256 * 1_024,
        maximumCachedChunkCount: Int = 32,
        maximumNetworkByteCount: Int64 = .max
    ) throws {
        guard length > 0,
              chunkSize > 0,
              maximumCachedChunkCount > 0,
              maximumNetworkByteCount > 0 else {
            throw HTTPRandomAccessByteSourceError.invalidLength
        }
        self.baseRequest = baseRequest
        self.length = length
        self.loader = loader
        self.chunkSize = chunkSize
        self.maximumCachedChunkCount = maximumCachedChunkCount
        self.maximumNetworkByteCount = maximumNetworkByteCount
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else {
            throw HTTPRandomAccessByteSourceError.invalidRead
        }
        guard count > 0, offset < length else { return Data() }

        let endExclusive = min(
            length,
            offset + Int64(count)
        )
        var position = offset
        var result = Data()
        result.reserveCapacity(Int(endExclusive - offset))

        while position < endExclusive {
            try throwIfCancelled()
            let chunkStart = (position / chunkSize) * chunkSize
            let chunk = try loadChunk(start: chunkStart)
            let offsetInChunk = Int(position - chunkStart)
            let available = chunk.count - offsetInChunk
            guard available > 0 else {
                throw HTTPRandomAccessByteSourceError.invalidRead
            }
            let requested = Int(endExclusive - position)
            let copyCount = min(available, requested)
            result.append(
                chunk.subdata(
                    in: offsetInChunk..<(offsetInChunk + copyCount)
                )
            )
            position += Int64(copyCount)
        }
        return result
    }

    func cancel() {
        condition.lock()
        guard !isCancelled else {
            condition.unlock()
            return
        }
        isCancelled = true
        let loads = Array(inFlightLoads.values)
        condition.broadcast()
        condition.unlock()
        loads.forEach { $0.cancel() }
    }

    var statistics: HTTPRandomAccessStatistics {
        condition.withLock {
            HTTPRandomAccessStatistics(
                rangeRequestCount: rangeRequestCount,
                networkByteCount: networkByteCount,
                cachedByteCount: Int64(
                    cachedChunks.values.reduce(0) { $0 + $1.count }
                ),
                trace: trace
            )
        }
    }

    func beginTemporaryNetworkBudget(additionalBytes: Int64) {
        condition.withLock {
            temporaryNetworkByteLimit = networkByteCount
                + reservedNetworkByteCount
                + max(additionalBytes, 0)
        }
    }

    func endTemporaryNetworkBudget() {
        condition.withLock { temporaryNetworkByteLimit = nil }
    }

    private func loadChunk(start: Int64) throws -> Data {
        condition.lock()
        if isCancelled {
            condition.unlock()
            throw HTTPRandomAccessByteSourceError.cancelled
        }
        if let cached = cachedChunks[start] {
            touchCache(start)
            condition.unlock()
            return cached
        }
        if let existing = inFlightLoads[start] {
            condition.unlock()
            return try existing.wait()
        }

        let end = min(start + chunkSize, length) - 1
        let requestedByteCount = end - start + 1
        let projectedNetworkBytes = networkByteCount
            + reservedNetworkByteCount
            + requestedByteCount
        guard projectedNetworkBytes <= maximumNetworkByteCount,
              temporaryNetworkByteLimit.map({
                  projectedNetworkBytes <= $0
              }) ?? true else {
            condition.unlock()
            throw HTTPRandomAccessByteSourceError.networkLimitExceeded
        }
        let load = ChunkLoad()
        inFlightLoads[start] = load
        reservedNetworkByteCount += requestedByteCount
        condition.unlock()

        load.start { [weak self] in
            guard let self else {
                throw HTTPRandomAccessByteSourceError.cancelled
            }
            return try await self.loader.load(
                request: self.baseRequest,
                start: start,
                end: end
            )
        } completion: { [weak self, weak load] transportResult in
            guard let self, let load else { return }
            let dataResult = transportResult.flatMap { result in
                Result {
                    try self.validatedData(
                        result,
                        requestedStart: start,
                        requestedEnd: end
                    )
                }
            }
            self.completeLoad(
                start: start,
                end: end,
                load: load,
                dataResult: dataResult,
                transportResult: try? transportResult.get()
            )
        }
        return try load.wait()
    }

    private func validatedData(
        _ result: HTTPRangeLoadResult,
        requestedStart: Int64,
        requestedEnd: Int64
    ) throws -> Data {
        guard result.statusCode == 206 else {
            throw HTTPRandomAccessByteSourceError.unexpectedStatus(
                result.statusCode
            )
        }
        let contentRange = NavidromeHTTPContentRange.parse(
            result.contentRange
        )
        guard contentRange?.start == requestedStart,
              contentRange?.end == requestedEnd,
              contentRange?.total == length else {
            throw HTTPRandomAccessByteSourceError.invalidContentRange(
                result.contentRange
            )
        }
        let expectedCount = Int(requestedEnd - requestedStart + 1)
        guard !result.exceededLimit,
              result.data.count == expectedCount else {
            throw HTTPRandomAccessByteSourceError.unexpectedByteCount(
                expected: expectedCount,
                actual: result.data.count
            )
        }
        return result.data
    }

    private func completeLoad(
        start: Int64,
        end: Int64,
        load: ChunkLoad,
        dataResult: Result<Data, Error>,
        transportResult: HTTPRangeLoadResult?
    ) {
        condition.lock()
        inFlightLoads.removeValue(forKey: start)
        reservedNetworkByteCount = max(
            reservedNetworkByteCount - (end - start + 1),
            0
        )
        if let transportResult {
            rangeRequestCount += 1
            networkByteCount += Int64(transportResult.data.count)
            if trace.count < 40 {
                trace.append(
                    HTTPRangeAccessTrace(
                        start: start,
                        end: end,
                        statusCode: transportResult.statusCode,
                        byteCount: transportResult.data.count
                    )
                )
            }
        }
        if case .success(let data) = dataResult, !isCancelled {
            cachedChunks[start] = data
            touchCache(start)
            evictCacheIfNeeded()
        }
        condition.broadcast()
        condition.unlock()
        load.complete(dataResult)
    }

    private func throwIfCancelled() throws {
        condition.lock()
        let cancelled = isCancelled
        condition.unlock()
        if cancelled {
            throw HTTPRandomAccessByteSourceError.cancelled
        }
    }

    private func touchCache(_ start: Int64) {
        cacheRecency.removeAll { $0 == start }
        cacheRecency.append(start)
    }

    private func evictCacheIfNeeded() {
        while cachedChunks.count > maximumCachedChunkCount,
              let oldest = cacheRecency.first {
            cacheRecency.removeFirst()
            cachedChunks.removeValue(forKey: oldest)
        }
    }
}

private nonisolated final class ChunkLoad: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<HTTPRangeLoadResult, Error>
    ) -> Void

    private let condition = NSCondition()
    private var result: Result<Data, Error>?
    private var task: Task<Void, Never>?

    func start(
        operation: @escaping @Sendable () async throws -> HTTPRangeLoadResult,
        completion: @escaping Completion
    ) {
        condition.lock()
        guard task == nil, result == nil else {
            condition.unlock()
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            do {
                completion(.success(try await operation()))
            } catch {
                completion(.failure(error))
            }
        }
        self.task = task
        condition.unlock()
    }

    func wait() throws -> Data {
        condition.lock()
        while result == nil {
            condition.wait()
        }
        let result = result!
        condition.unlock()
        return try result.get()
    }

    func complete(_ result: Result<Data, Error>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        let task = task
        if result == nil {
            result = .failure(HTTPRandomAccessByteSourceError.cancelled)
            condition.broadcast()
        }
        condition.unlock()
        task?.cancel()
    }
}

private extension NSCondition {
    nonisolated func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
