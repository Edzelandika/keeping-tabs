import Foundation

// Main-thread only. Coalesces input bursts and retains one refresh while busy.
final class RefreshScheduler {
    private let canRead: () -> Bool
    private let read: (Bool) -> Void
    private var work: DispatchWorkItem?
    private var pending = false
    private var force = false

    init(canRead: @escaping () -> Bool, read: @escaping (Bool) -> Void) {
        self.canRead = canRead
        self.read = read
    }

    func request(after delay: TimeInterval = 0.1, force: Bool = false) {
        pending = true
        self.force = self.force || force
        work?.cancel()
        work = nil
        if delay <= 0 { resume(); return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.work = nil
            self.resume()
        }
        work = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    // Safety ticks must not pull a deliberately deferred refresh forward.
    func requestIfNeeded() {
        guard !pending else { return }
        request(after: 0)
    }

    func resume() {
        guard pending, work == nil, canRead() else { return }
        let forced = force
        pending = false
        force = false
        read(forced)
    }

    func cancel() {
        work?.cancel()
        work = nil
        pending = false
        force = false
    }
}
