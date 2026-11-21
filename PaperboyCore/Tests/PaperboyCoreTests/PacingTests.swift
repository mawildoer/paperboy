import Foundation
import Testing

@testable import PaperboyCore

@Suite struct PacingTests {
    @Test func retryAfterSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_794_744_000)  // Sun, 15 Nov 2026 12:00:00 GMT
        #expect(RetryAfter.seconds(from: "120", now: now) == 120)
        #expect(RetryAfter.seconds(from: " 7 ", now: now) == 7)
        #expect(RetryAfter.seconds(from: "-5", now: now) == 0)
        #expect(RetryAfter.seconds(from: "Sun, 15 Nov 2026 12:01:30 GMT", now: now) == 90)
        #expect(RetryAfter.seconds(from: "Sun, 15 Nov 2026 11:00:00 GMT", now: now) == 0)
        #expect(RetryAfter.seconds(from: nil, now: now) == nil)
        #expect(RetryAfter.seconds(from: "", now: now) == nil)
        #expect(RetryAfter.seconds(from: "soon", now: now) == nil)
        #expect(RetryAfter.seconds(from: "nan", now: now) == nil)
        #expect(RetryAfter.delay(from: "100000", now: now) == 300)
        #expect(RetryAfter.delay(from: nil, fallback: 30, now: now) == 30)
    }

    // Only lower bounds are asserted, and only against instants read before the limiter was
    // called, so a busy machine cannot make these fail.
    @Test func rateLimiterSpacesRequests() async throws {
        let limiter = RateLimiter(interval: .milliseconds(60))
        let clock = ContinuousClock()
        let start = clock.now
        var stamps: [Duration] = []
        for _ in 0..<4 {
            try await limiter.wait()
            stamps.append(clock.now - start)
        }
        // Request n cannot return before n intervals have passed since the first one.
        for (index, stamp) in stamps.enumerated() {
            #expect(stamp >= .milliseconds(60 * index))
        }
        let before = clock.now
        await limiter.backOff(.milliseconds(200))
        try await limiter.wait()
        #expect(clock.now - before >= .milliseconds(200))
    }

    @Test func rateLimiterQueuesConcurrentCallers() async throws {
        let limiter = RateLimiter(interval: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await limiter.wait() } }
            try await group.waitForAll()
        }
        #expect(clock.now - start >= .milliseconds(150))  // 4 callers, 3 gaps
    }
}
