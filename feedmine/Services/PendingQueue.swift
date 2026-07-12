import Foundation

/// JSON-based queue in the App Group container.
/// Extension writes; main app reads + clears. NSFileCoordinator guards all writes.
struct PendingQueue: Sendable {

    // MARK: - Storage

    static let containerURL: URL = {
        let u = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.feedmine"
        )!
        return u.appendingPathComponent("pending_queue.json")
    }()

    private static let maxItems = 100

    // MARK: - Public API (main app)

    /// Read all pending items. Returns empty array if file doesn't exist or is corrupt.
    static func readAll() -> [PendingItem] {
        guard FileManager.default.fileExists(atPath: containerURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: containerURL)
            let decoder = JSONDecoder()
            return try decoder.decode([PendingItem].self, from: data)
        } catch {
            print("[PendingQueue] Read error: \(error)")
            return []
        }
    }

    /// Clear the queue — call after successful processing in the main app.
    static func clear() {
        do {
            try FileManager.default.removeItem(at: containerURL)
        } catch {
            let nsError = error as NSError
            // File doesn't exist is not an error — the queue is already empty
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 { return }
            print("[PendingQueue] Clear error: \(error)")
        }
    }

    // MARK: - Public API (extension)

    /// Append items from the extension. Coalesces with existing items under
    /// NSFileCoordinator to avoid races if extension and app run simultaneously.
    static func append(_ newItems: [PendingItem]) {
        guard !newItems.isEmpty else { return }

        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(writingItemAt: containerURL,
                               options: .forMerging,
                               error: &error) { writeURL in
            var existing: [PendingItem] = []
            if FileManager.default.fileExists(atPath: writeURL.path) {
                if let data = try? Data(contentsOf: writeURL),
                   let decoded = try? JSONDecoder().decode([PendingItem].self, from: data) {
                    existing = decoded
                }
            }
            existing.append(contentsOf: newItems)
            // FIFO overflow guard
            if existing.count > maxItems {
                existing = Array(existing.suffix(maxItems))
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(existing)
                try data.write(to: writeURL, options: .atomic)
            } catch {
                print("[PendingQueue] Write error: \(error)")
            }
        }

        if let error { print("[PendingQueue] FileCoordinator error: \(error)") }
    }
}
