import Foundation

@main struct RefreshTests {
    static func runLoop(for interval: TimeInterval) {
        let end = Date(timeIntervalSinceNow: interval)
        while Date() < end { RunLoop.current.run(until: min(end, Date(timeIntervalSinceNow: 0.005))) }
    }

    static func main() {
        var busy = false
        var reads: [Bool] = []
        let scheduler = RefreshScheduler(canRead: { !busy }, read: { reads.append($0) })

        // An input burst should result in one read, not one per event.
        for _ in 0..<20 { scheduler.request(after: 0.01) }
        assert(reads.isEmpty)
        runLoop(for: 0.1)
        assert(reads == [false])

        // A read/gesture blocks execution without losing the requested refresh.
        busy = true
        scheduler.request(after: 0.01, force: true)
        scheduler.request(after: 0.01)
        runLoop(for: 0.1)
        assert(reads.count == 1)
        busy = false
        scheduler.resume()
        assert(reads == [false, true], "Busy requests must retain setup's force flag")
        scheduler.resume()
        assert(reads.count == 2, "Resume must not duplicate a completed request")

        // Explicit setup/recovery can still refresh immediately, absorbing a debounce.
        scheduler.request(after: 0.01)
        scheduler.request(after: 0)
        assert(reads.count == 3)
        runLoop(for: 0.1)
        assert(reads.count == 3)

        // Leaving Safari / pausing cancels both delayed and blocked requests.
        scheduler.request(after: 0.01)
        scheduler.cancel()
        runLoop(for: 0.1)
        assert(reads.count == 3)
        busy = true
        scheduler.request(after: 0)
        scheduler.cancel()
        busy = false
        scheduler.resume()
        assert(reads.count == 3)

        // Completion must not bypass an input's still-pending debounce.
        scheduler.request(after: 0.01)
        scheduler.resume()
        assert(reads.count == 3)
        runLoop(for: 0.1)
        assert(reads.count == 4)

        // Successful switches should leave the helper free between rapid toggles.
        for _ in 0..<3 {
            busy = true
            scheduler.requestIfNeeded()
            busy = false
            scheduler.request(after: 0.25)
            scheduler.requestIfNeeded() // Safety tick cannot bypass the quiet gap.
            scheduler.resume()
            runLoop(for: 0.03)
            assert(reads.count == 4, "A refresh interrupted the rapid-switch burst")
        }
        runLoop(for: 0.35)
        assert(reads.count == 5, "The burst must produce one eventual refresh")
        scheduler.requestIfNeeded()
        assert(reads.count == 6, "Safety refresh must still work when nothing is pending")

        assert(!SafariRefreshKey.shouldRefresh(17, command: false, control: false)) // typing T
        assert(!SafariRefreshKey.shouldRefresh(8, command: true, control: false)) // copy
        assert(!SafariRefreshKey.shouldRefresh(48, command: false, control: false)) // focus Tab
        for key: Int64 in [17, 13, 45, 33, 30, 50, 18, 25] {
            assert(SafariRefreshKey.shouldRefresh(key, command: true, control: false))
        }
        assert(SafariRefreshKey.shouldRefresh(48, command: false, control: true))
        assert(SafariRefreshKey.shouldRefresh(36, command: false, control: false))
        print("PASS: debouncing, busy requests, forced setup, immediate recovery, rapid-switch quiet gap, safety timer, cancellation, and input filtering")
    }
}
