import Foundation

/// In-memory clipboard history, newest first. Nothing here is ever written to disk.
final class HistoryStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    var limit: Int {
        didSet { trim(); onChange?() }
    }

    /// Upper bound on clipboard data held in memory; the oldest entries are dropped first.
    let byteBudget: Int

    init(limit: Int, byteBudget: Int = 64 << 20) {
        self.limit = limit
        self.byteBudget = byteBudget
    }

    func add(_ item: ClipItem) {
        // Copying the same thing again moves it to the top instead of duplicating it.
        items.removeAll { $0.fingerprint == item.fingerprint && $0.contents == item.contents }
        items.insert(item, at: 0)
        trim()
        onChange?()
    }

    func promote(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        items.insert(items.remove(at: index), at: 0)
        onChange?()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        onChange?()
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    private func trim() {
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        var total = items.reduce(0) { $0 + $1.byteSize }
        while total > byteBudget, items.count > 1 {
            total -= items.removeLast().byteSize
        }
    }
}
