import Foundation

/// Spaces requests out: `wait()` returns no sooner than `interval` after the previous call
/// returned. One limiter per host keeps a source at or below one request per interval.
public actor RateLimiter {
    private let interval: Duration
    private let clock = ContinuousClock()
    private var nextAllowed: ContinuousClock.Instant?

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    public func wait() async throws {
        while true {
            let now = clock.now
            if let next = nextAllowed, next > now {
                // Other callers may run while this one sleeps; whoever wakes first takes the
                // slot, the rest come round again.
                try await Task.sleep(until: next, clock: clock)
                continue
            }
            nextAllowed = now + interval
            return
        }
    }

    /// Push the next request back, e.g. after a 429 with Retry-After.
    public func backOff(_ delay: Duration) {
        let candidate = clock.now + delay
        if let current = nextAllowed, current > candidate { return }
        nextAllowed = candidate
    }
}

public enum RetryAfter {
    /// Seconds to wait according to a `Retry-After` header: either a number of seconds or an
    /// HTTP date. nil if the header is missing or unreadable. Never negative.
    public static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) { return seconds.isFinite ? max(0, seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    /// The wait to apply after a 429: the header's value, or `fallback`, capped at `cap`.
    public static func delay(from header: String?, fallback: TimeInterval = 30, cap: TimeInterval = 300, now: Date = Date()) -> TimeInterval {
        min(cap, seconds(from: header, now: now) ?? fallback)
    }
}
