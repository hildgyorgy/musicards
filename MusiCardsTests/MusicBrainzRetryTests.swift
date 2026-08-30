import XCTest
@testable import MusiCards

@MainActor
final class MusicBrainzRetryTests: XCTestCase {
    func testServerFailureIsRetriedAndThenSucceeds() async throws {
        let executor = ScriptedRequestExecutor([
            .response(statusCode: 503),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let service = makeService(executor: executor, sleeper: sleeper)

        let artists = try await service.searchArtists(query: "test")
        let requestCount = await executor.requestCount
        let delays = await sleeper.delays

        XCTAssertTrue(artists.isEmpty)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(delays, [.milliseconds(10)])
    }

    func testTwoTransientFailuresUseBothRetries() async throws {
        let executor = ScriptedRequestExecutor([
            .failure(.timedOut),
            .response(statusCode: 503),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let service = makeService(executor: executor, sleeper: sleeper)

        _ = try await service.searchArtists(query: "test")
        let requestCount = await executor.requestCount
        let delays = await sleeper.delays

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(
            delays,
            [.milliseconds(10), .milliseconds(20)]
        )
    }

    func testFiveTransientFailuresCanRecoverOnSixthAttempt() async throws {
        let executor = ScriptedRequestExecutor([
            .response(statusCode: 503),
            .response(statusCode: 503),
            .response(statusCode: 503),
            .response(statusCode: 503),
            .response(statusCode: 503),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let delays: [Duration] = [
            .milliseconds(1),
            .milliseconds(2),
            .milliseconds(3),
            .milliseconds(4),
            .milliseconds(5)
        ]
        let service = makeService(
            executor: executor,
            sleeper: sleeper,
            retryDelays: delays,
            maximumTotalRetryDelay: .milliseconds(20)
        )

        _ = try await service.searchArtists(query: "test")
        let requestCount = await executor.requestCount
        let recordedDelays = await sleeper.delays

        XCTAssertEqual(requestCount, 6)
        XCTAssertEqual(recordedDelays, delays)
    }

    func testNonTransientHTTPFailureIsNotRetried() async {
        let executor = ScriptedRequestExecutor([
            .response(statusCode: 404),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let service = makeService(executor: executor, sleeper: sleeper)

        do {
            _ = try await service.searchArtists(query: "test")
            XCTFail("Expected an HTTP failure")
        } catch let error as MusicBrainzServiceError {
            guard case .httpFailure(let statusCode) = error else {
                return XCTFail("Expected httpFailure, got \(error)")
            }
            XCTAssertEqual(statusCode, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await executor.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(delays.isEmpty)
    }

    func testRetryAfterSecondsOverridesShorterBackoff() async throws {
        let executor = ScriptedRequestExecutor([
            .response(
                statusCode: 429,
                headers: ["Retry-After": "2"]
            ),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let service = makeService(
            executor: executor,
            sleeper: sleeper,
            maximumTotalRetryDelay: .seconds(3)
        )

        _ = try await service.searchArtists(query: "test")
        let requestCount = await executor.requestCount
        let delays = await sleeper.delays

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(delays, [.seconds(2)])
    }

    func testRetryAfterBeyondBudgetDoesNotSendAnEarlyRetry() async {
        let executor = ScriptedRequestExecutor([
            .response(
                statusCode: 429,
                headers: ["Retry-After": "10"]
            ),
            .response(statusCode: 200, data: Self.emptyArtistSearchResponse)
        ])
        let sleeper = RetryDelayRecorder()
        let service = makeService(executor: executor, sleeper: sleeper)

        do {
            _ = try await service.searchArtists(query: "test")
            XCTFail("Expected a rate-limit failure")
        } catch let error as MusicBrainzServiceError {
            guard case .rateLimited(let statusCode, let retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertEqual(statusCode, 429)
            XCTAssertEqual(retryAfter, 10)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await executor.requestCount
        let delays = await sleeper.delays
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(delays.isEmpty)
    }

    func testCancellationDuringBackoffStopsTheRetryChain() async {
        let executor = ScriptedRequestExecutor([.failure(.timedOut)])
        let sleeper = BlockingRetrySleeper()
        let service = MusicBrainzService(
            rateLimiter: RateLimiter(minimumInterval: 0),
            retryDelays: [.seconds(1)],
            maximumTotalRetryDelay: .seconds(1),
            requestExecutor: { request in
                try await executor.execute(request)
            },
            retrySleeper: { delay in
                try await sleeper.sleep(for: delay)
            }
        )

        let task = Task {
            try await service.searchArtists(query: "test")
        }
        await sleeper.waitUntilEntered()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let requestCount = await executor.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testHTTPDateRetryAfterIsParsed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let retryDate = now.addingTimeInterval(2)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: Self.testURL,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": formatter.string(from: retryDate)]
            )
        )

        let interval = try XCTUnwrap(
            MusicBrainzService.retryAfterInterval(from: response, now: now)
        )
        XCTAssertEqual(
            interval,
            2,
            accuracy: 0.001
        )
    }

    private func makeService(
        executor: ScriptedRequestExecutor,
        sleeper: RetryDelayRecorder,
        retryDelays: [Duration] = [
            .milliseconds(10),
            .milliseconds(20)
        ],
        maximumTotalRetryDelay: Duration = .milliseconds(100)
    ) -> MusicBrainzService {
        MusicBrainzService(
            rateLimiter: RateLimiter(minimumInterval: 0),
            retryDelays: retryDelays,
            maximumTotalRetryDelay: maximumTotalRetryDelay,
            requestExecutor: { request in
                try await executor.execute(request)
            },
            retrySleeper: { delay in
                await sleeper.record(delay)
            }
        )
    }

    private static let testURL = URL(string: "https://musicbrainz.org")!
    private static let emptyArtistSearchResponse = Data(
        #"{"artists":[]}"#.utf8
    )
}

private actor ScriptedRequestExecutor {
    enum Outcome {
        case response(
            statusCode: Int,
            headers: [String: String] = [:],
            data: Data = Data()
        )
        case failure(URLError.Code)
    }

    private var outcomes: [Outcome]
    private(set) var requestCount = 0

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func execute(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        guard !outcomes.isEmpty else {
            throw URLError(.unknown)
        }

        switch outcomes.removeFirst() {
        case .response(let statusCode, let headers, let data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (data, response)
        case .failure(let code):
            throw URLError(code)
        }
    }
}

private actor RetryDelayRecorder {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}

private actor BlockingRetrySleeper {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for delay: Duration) async throws {
        entered = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        try await Task.sleep(for: delay)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
