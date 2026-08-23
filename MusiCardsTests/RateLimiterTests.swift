import XCTest
@testable import MusiCards

final class RateLimiterTests: XCTestCase {
    func testCancelledWaiterDoesNotConsumeAdmissionOrReachDownstream() async throws {
        let limiter = RateLimiter(minimumInterval: 0.05)
        let downstream = InvocationCounter()
        let firstAdmission = try await limiter.waitIfNeeded()

        let waiter = Task {
            try await limiter.waitIfNeeded()
            try Task.checkCancellation()
            await downstream.record()
        }
        try await Task.sleep(for: .milliseconds(5))
        waiter.cancel()

        await assertCancellation(of: waiter)
        let lastAdmission = await limiter.lastAdmission
        let invocationCount = await downstream.count
        XCTAssertEqual(lastAdmission, firstAdmission)
        XCTAssertEqual(invocationCount, 0)
    }

    func testConcurrentWaitersRemainSpacedApart() async throws {
        let limiter = RateLimiter(minimumInterval: 0.02)
        let admissions = try await withThrowingTaskGroup(
            of: ContinuousClock.Instant.self
        ) { group in
            for _ in 0..<4 {
                group.addTask { try await limiter.waitIfNeeded() }
            }

            var values: [ContinuousClock.Instant] = []
            for try await admission in group { values.append(admission) }
            return values.sorted()
        }

        for pair in zip(admissions, admissions.dropFirst()) {
            let spacing = pair.0.duration(to: pair.1)
            XCTAssertGreaterThanOrEqual(spacing, .milliseconds(18))
        }
    }

    func testCancellationAfterAdmissionPreventsDownstreamRequest() async throws {
        let limiter = RateLimiter(minimumInterval: 0)
        let barrier = CancellationBarrier()
        let downstream = InvocationCounter()

        let request = Task {
            try await limiter.waitIfNeeded()
            await barrier.arriveAndWait()
            try Task.checkCancellation()
            await downstream.record()
        }

        await barrier.waitUntilArrived()
        request.cancel()
        await barrier.release()

        await assertCancellation(of: request)
        let invocationCount = await downstream.count
        XCTAssertEqual(invocationCount, 0)
    }

    private func assertCancellation(
        of task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}

private actor InvocationCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

private actor CancellationBarrier {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
