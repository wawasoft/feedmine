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
    ) async throws -> T {
        if slots[category] == nil { slots[category] = AsyncSemaphore(limit: 1) }
        let semaphore = slots[category]!
        let acquired = await semaphore.wait()
        guard acquired else {
            // Slot not acquired — the caller's task was cancelled while
            // queued. Never run the operation and never emit a spurious
            // signal(): the wait already released the slot.
            throw CancellationError()
        }
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
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func wait() async -> Bool {
        if count < limit { count += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters.append((id, cont))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let (_, cont) = waiters.remove(at: idx)
        cont.resume(returning: false)  // false = no slot acquired
    }

    func signal() {
        if let (_, waiter) = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: true)
        } else {
            count -= 1
        }
    }
}
