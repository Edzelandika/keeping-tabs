import Foundation

struct TabInfo: Equatable, Codable {
    var url: String
    var title: String
}

struct TabSnapshot: Codable {
    var windowID: Int
    var selected: Int // Zero-based position in Safari's active tab group.
    var tabs: [TabInfo]
}

struct RecentTabs {
    private(set) var snapshot: TabSnapshot?
    private(set) var order: [Int] = []

    mutating func observe(_ next: TabSnapshot) {
        guard next.tabs.indices.contains(next.selected) else { return }
        if let old = snapshot, old.windowID == next.windowID {
            let before = old.tabs.map(\.url)
            let after = next.tabs.map(\.url)
            if before == after {
                // Titles can change while a page loads.
            } else if before.count == after.count,
                      zip(before, after).filter({ $0 != $1 }).count == 1 {
                // An ordinary navigation changes the URL without changing the tab.
            } else if Set(before).count == before.count,
                      Set(after).count == after.count {
                let positions = Dictionary(uniqueKeysWithValues: after.enumerated().map { ($1, $0) })
                order = order.compactMap { positions[before[$0]] }
            } else {
                // Safari exposes positions rather than stable tab IDs. With duplicate
                // URLs and structural changes, discard ambiguous history.
                order = []
            }
        } else {
            order = []
        }
        order.removeAll { $0 == next.selected || !next.tabs.indices.contains($0) }
        order.insert(next.selected, at: 0)
        let known = Set(order)
        for index in next.tabs.indices where !known.contains(index) { order.append(index) }
        snapshot = next
    }

    func target(step: Int) -> Int? {
        guard !order.isEmpty else { return nil }
        return order[((step % order.count) + order.count) % order.count]
    }
}
