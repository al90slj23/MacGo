public enum SwitcherSelectionPolicy: Equatable {
    case previousWindow
    case currentWindow
    case firstWindow
}

/// A keyboard window-selection session. Its order is frozen until completion,
/// except for windows removed because they have closed.
public struct SwitcherSession<ID: Hashable> {
    public private(set) var items: [ID] = []
    public private(set) var selectedIndex: Int?

    public init() {}

    public var selectedID: ID? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    public var isActive: Bool { !items.isEmpty }

    /// Opens a session and selects the window after `currentID`. With an MRU
    /// list, a quick forward invocation therefore selects the previous window.
    /// Repeated invocations keep the existing order and advance one position.
    public mutating func begin(items candidates: [ID], currentID: ID?, backwards: Bool = false,
                               initialSelection: SwitcherSelectionPolicy = .previousWindow) {
        if isActive {
            advance(backwards: backwards)
            return
        }

        var seen = Set<ID>()
        items = candidates.filter { seen.insert($0).inserted }
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }

        if initialSelection == .firstWindow {
            selectedIndex = backwards ? items.count - 1 : 0
        } else if let currentID, let index = items.firstIndex(of: currentID) {
            selectedIndex = index
            if initialSelection == .previousWindow { advance(backwards: backwards) }
        } else {
            selectedIndex = backwards ? items.count - 1 : 0
        }
    }

    public mutating func advance(backwards: Bool = false) {
        guard !items.isEmpty else { return }
        guard let selectedIndex else {
            self.selectedIndex = backwards ? items.count - 1 : 0
            return
        }
        let offset = backwards ? items.count - 1 : 1
        self.selectedIndex = (selectedIndex + offset) % items.count
    }

    /// Selects an existing keyboard choice, for example when its card is
    /// hovered. Mouse-only application entries cannot be inserted this way.
    /// Subsequent Tab presses continue from this choice in the frozen order.
    @discardableResult public mutating func select(_ id: ID) -> Bool {
        guard let index = items.firstIndex(of: id) else { return false }
        selectedIndex = index
        return true
    }

    /// Preserves the selected window when another one closes. When the selected
    /// window closes, selects its successor (wrapping to the first window).
    public mutating func remove(_ id: ID) {
        guard let removedIndex = items.firstIndex(of: id) else { return }
        let oldIndex = selectedIndex
        items.remove(at: removedIndex)
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        guard let oldIndex else {
            selectedIndex = 0
            return
        }
        if removedIndex < oldIndex {
            selectedIndex = oldIndex - 1
        } else if removedIndex == oldIndex {
            selectedIndex = removedIndex % items.count
        }
    }

    public mutating func cancel() {
        items.removeAll(keepingCapacity: true)
        selectedIndex = nil
    }

    /// Returns the selected window and ends the session. Further calls return nil.
    public mutating func finish() -> ID? {
        let result = selectedID
        cancel()
        return result
    }
}
