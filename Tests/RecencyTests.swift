import Foundation

@main struct Tests {
    static func main() {
        func snapshot(_ urls: [String], _ selected: Int, _ window: Int = 1) -> TabSnapshot {
            TabSnapshot(windowID: window, selected: selected,
                        tabs: urls.map { TabInfo(url: $0, title: $0) })
        }
        var model = RecentTabs()
        model.observe(snapshot(["a", "b", "c"], 0))
        model.observe(snapshot(["a", "b", "c"], 2))
        assert(model.order == [2, 0, 1])
        assert(model.target(step: 1) == 0)
        assert(model.target(step: -1) == 1)
        assert(model.target(step: 4) == 0)
        // Visiting the previous tab promotes it, making the next tap toggle back.
        model.observe(snapshot(["a", "b", "c"], 0))
        assert(model.target(step: 1) == 2)
        // Navigation changes the URL but preserves the visited-tab order.
        model.observe(snapshot(["a2", "b", "c"], 0))
        assert(model.order == [0, 2, 1])
        // Unique URLs preserve identity after a tab move.
        model.observe(snapshot(["c", "a2", "b"], 1))
        assert(model.order == [1, 0, 2])
        // Closing a tab removes its old position without corrupting history.
        model.observe(snapshot(["c", "a2"], 1))
        assert(model.order == [1, 0])
        // Ambiguous duplicate-URL structural changes reset history.
        model.observe(snapshot(["a", "a", "c"], 2))
        model.observe(snapshot(["a", "c", "a"], 0))
        assert(model.order == [0, 1, 2])
        model.observe(snapshot(["x", "y"], 1, 2))
        assert(model.order == [1, 0])
        model.observe(snapshot([], -1, 2))
        assert(model.order == [1, 0])
        print("Passed: recency, toggle, cycling, navigation, reordering, closing, duplicates, windows, empty snapshots")
    }
}
