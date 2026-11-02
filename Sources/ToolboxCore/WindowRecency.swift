/// Maintains most-recently-used window IDs independently of the currently open
/// selection session. It stores no window titles or other window contents.
public struct WindowRecency<ID: Hashable> {
    private var history: [ID] = []
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(_ id: ID) {
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        if history.count > capacity {
            history.removeLast(history.count - capacity)
        }
    }

    /// Recent windows come first. Unknown windows retain the caller's original
    /// order, so enumeration order does not become random for unvisited windows.
    /// Duplicate input IDs appear once in the result.
    public func ordered(_ ids: [ID]) -> [ID] {
        var seen = Set<ID>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        let available = Set(uniqueIDs)
        let recent = history.filter { available.contains($0) }
        let tracked = Set(recent)
        return recent + uniqueIDs.filter { !tracked.contains($0) }
    }

    /// Drop closed windows, including stale IDs that might later be reused.
    public mutating func prune(validIDs: Set<ID>) {
        history.removeAll { !validIDs.contains($0) }
    }
}
