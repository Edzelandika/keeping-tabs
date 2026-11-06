import Foundation
@main struct Tests {
    static func main() {
        if CommandLine.arguments.contains("--bridge") { runBridge(); return }
        let bridge = SafariBridge()
        var done = false
        var ticks = 0
        var responses = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in ticks += 1 }
        let start = Date()
        for _ in 0..<20 {
            bridge.request(BridgeRequest(action: "check")) { result in
                assert(result.error == nil && result.switched, result.error ?? "Scripts failed")
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
