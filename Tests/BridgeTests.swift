import Foundation
@main struct Tests {
    static func main() {
        if CommandLine.arguments.contains("--bridge") { runBridge(); return }
        // Identity matching keeps the original duplicate and moved-tab behavior.
        func target(_ urls: [String], _ index: Int, _ url: String) -> Int? {
            try? SafariScripts.targetIndex(urls: urls, index: index, expectedURL: url).get()
        }
        assert(target(["a", "b"], 1, "b") == 1)
        assert(target(["b", "a"], 1, "b") == 0)
        assert(target(["a", "b"], 3, "b") == 1)
        assert(target(["a", "a"], 1, "a") == 1)
        assert(target(["a", "a", "b"], 2, "a") == nil)
        assert(target(["a"], 0, "b") == nil)
        assert(target([], 0, "a") == nil)
        assert(target(["", "a"], 0, "") == 0)
        let bridge = SafariBridge()
        var done = false
        var ticks = 0
        var responses = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in ticks += 1 }
        let start = Date()
        for _ in 0..<20 {
            bridge.request(BridgeRequest(action: "check")) { result in
                assert(result.error == nil && result.switched, result.error ?? "Scripts failed")
                assert(result.timing != nil, "Bridge timings missing")
                assert(result.timing!.queueMS >= 0 && result.timing!.helperMS >= 0 && result.timing!.callbackMS >= 0)
                responses += 1
                if responses == 20 { done = true }
            }
        }
        while !done && Date().timeIntervalSince(start) < 15 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        assert(done, "Persistent helper did not respond")
        assert(ticks > 0, "Main run loop blocked")
        timer.invalidate()
        bridge.stop()
        print("PASS: 20 ordered persistent-helper round trips; script compilation; main loop remained responsive (\(ticks) timer ticks); total \(Date().timeIntervalSince(start))s")
    }
}
