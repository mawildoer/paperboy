/// What one fetch run did.
public struct FetchSummary: Sendable {
    public init() {}

    public var added = 0
    public var failed = 0
    public var notes: [String] = []

    public mutating func merge(_ other: FetchSummary) {
        added += other.added
        failed += other.failed
        notes += other.notes
    }
}
