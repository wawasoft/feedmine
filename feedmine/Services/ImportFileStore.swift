import Foundation

/// Actor that owns all file I/O for import workflows so that `Data(contentsOf:)`
/// and `Data.write(to:)` never block the MainActor.
///
/// By moving these operations off-MainActor, the UI remains responsive during
/// OPML imports (especially large files with thousands of sources) and while
/// persisting imported-source state.
actor ImportFileStore {

    /// Read a file with an optional byte ceiling. Returns an error instead of
    /// loading, e.g., a gigabyte binary pretending to be OPML into memory.
    func read(url: URL, maxBytes: Int = 10_485_760) throws -> Data {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize, fileSize > maxBytes {
            throw ImportFileError.fileTooLarge(url: url, size: fileSize, limit: maxBytes)
        }
        return try Data(contentsOf: url)
    }

    /// Overwrite a JSON file atomically (write to temp → rename) so a crash
    /// mid-write never leaves a zero-byte or partial file on disk.
    func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Read and decode a JSON file. Returns nil if the file doesn't exist.
    func loadJSON<T: Decodable>(from url: URL, as: T.Type) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Delete a file silently (best-effort — used for cleanup).
    func deleteIfExists(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

enum ImportFileError: LocalizedError, Equatable {
    case fileTooLarge(url: URL, size: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(url, size, limit):
            let sizeMB = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let limitMB = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "\(url.lastPathComponent) is \(sizeMB) — exceeds the \(limitMB) import limit."
        }
    }
}
