import Foundation

/// Bounded concurrency limiter with per-category slot allocation.
/// Categories (direct image, article HTML, disk decode, retry) get
/// independent limits so one slow category doesn't starve others.
actor AsyncLimiter {
    private var slots: [String: AsyncSemaphore]

    init(categories: [(String, Int)]) {
        self.slots = Dictionary(uniqueKeysWithValues: categories.map {
            ($0.0, AsyncSemaphore(limit: $0.1))
        })
    }

    func withSlot<T: Sendable>(
        category: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let semaphore = slots[category] ?? AsyncSemaphore(limit: 1)
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        return try await operation()
    }

    func updateLimit(category: String, limit: Int) {
        slots[category] = AsyncSemaphore(limit: limit)
    }
}

// MARK: - Private

private actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func wait() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count -= 1
        }
    }
}
