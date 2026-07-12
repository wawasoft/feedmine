import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the Feedmine Share Extension.
/// Extracts URLs, files, and text from the extension context,
/// writes them to the App Group pending queue, then shows confirmation UI.
@MainActor
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        processInputItems()
    }

    // MARK: - Input processing

    private func processInputItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No content received")
            return
        }

        Task {
            var pendingItems: [PendingItem] = []
            /// Track source URLs already enqueued so the text block doesn't
            /// re-process the same URL (NSItemProvider can conform to both
            /// public.url and public.plain-text simultaneously).
            var processedSourceURLs = Set<String>()

            for item in extensionItems {
                // 1. URL attachments
                if let urlProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
                    for provider in urlProviders {
                        if let url = try? await loadURL(from: provider) {
                            let urlString = url.absoluteString
                            processedSourceURLs.insert(urlString)
                            let isDirect = FeedDiscoveryService.isDirectFeedURL(url)
                            let discovered = isDirect
                                ? [PendingItem.DiscoveredFeed(title: url.host ?? "Feed", url: urlString)]
                                : (try? await FeedDiscoveryService.discover(url: url)) ?? []
                            pendingItems.append(PendingItem(
                                id: UUID().uuidString,
                                type: isDirect ? .feedDirect : .feedDiscovery,
                                sourceURL: urlString,
                                foundFeeds: discovered,
                                fileName: nil,
                                feedCount: nil,
                                receivedAt: Int(Date().timeIntervalSince1970)
                            ))
                        }
                    }
                }

                // 2. File attachments (OPML)
                if let fileProviders = item.attachments?.filter({
                    $0.hasItemConformingToTypeIdentifier("org.opml.opml") ||
                    $0.hasItemConformingToTypeIdentifier("public.xml")
                }) {
                    for provider in fileProviders {
                        if let result = try? await loadAndCopyOPML(from: provider) {
                            pendingItems.append(PendingItem(
                                id: UUID().uuidString,
                                type: .opmlImport,
                                sourceURL: result.permanentURL.absoluteString,
                                foundFeeds: [],
                                fileName: result.fileName,
                                feedCount: result.feedCount,
                                receivedAt: Int(Date().timeIntervalSince1970)
                            ))
                        }
                    }
                }

                // 3. Text content — skip URLs already processed from URL attachments
                // (NSItemProvider for a shared URL conforms to both public.url
                // and public.plain-text, causing duplicate discovery otherwise.)
                if let textProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
                    for provider in textProviders {
                        if let urls = try? await extractURLsFromText(from: provider) {
                            for url in urls where !processedSourceURLs.contains(url.absoluteString) {
                                let isDirect = FeedDiscoveryService.isDirectFeedURL(url)
                                let discovered = isDirect
                                    ? [PendingItem.DiscoveredFeed(title: url.host ?? "Feed", url: url.absoluteString)]
                                    : (try? await FeedDiscoveryService.discover(url: url)) ?? []
                                pendingItems.append(PendingItem(
                                    id: UUID().uuidString,
                                    type: isDirect ? .feedDirect : .feedDiscovery,
                                    sourceURL: url.absoluteString,
                                    foundFeeds: discovered,
                                    fileName: nil,
                                    feedCount: nil,
                                    receivedAt: Int(Date().timeIntervalSince1970)
                                ))
                            }
                        }
                    }
                }
            }

            guard !pendingItems.isEmpty else {
                showError("No feeds found in shared content")
                return
            }

            // Write to App Group queue
            PendingQueue.append(pendingItems)

            // Show confirmation UI
            await MainActor.run {
                showConfirmation(items: pendingItems)
            }
        }
    }

    // MARK: - Attachment loaders

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        return data as? URL
    }

    private struct OPMLResult {
        let fileName: String
        let permanentURL: URL  // URL in App Group container
        let feedCount: Int
    }

    private func loadAndCopyOPML(from provider: NSItemProvider) async throws -> OPMLResult? {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.xml.identifier)
        guard let tempURL = data as? URL else { return nil }

        let fileName = tempURL.lastPathComponent
        guard fileName.hasSuffix(".opml") || fileName.hasSuffix(".xml") else { return nil }

        // Security-scoped resource: read now while we have access.
        // The temp URL is deleted when the extension exits, so we must
        // copy the file contents to the App Group container.
        let didAccess = tempURL.startAccessingSecurityScopedResource()
        defer { if didAccess { tempURL.stopAccessingSecurityScopedResource() } }

        // Copy to App Group so the main app can read it
        let containerDir = PendingQueue.containerURL.deletingLastPathComponent()
        let safeName = "imported_\(UUID().uuidString)_\(fileName)"
        let destURL = containerDir.appendingPathComponent(safeName)

        let fileData = try Data(contentsOf: tempURL)
        try fileData.write(to: destURL, options: .atomic)

        // Quick count: parse the OPML to count feeds
        let feedSources = try OPMLParser.parseImportedFile(url: destURL)
        return OPMLResult(fileName: fileName, permanentURL: destURL, feedCount: feedSources.count)
    }

    private func extractURLsFromText(from provider: NSItemProvider) async throws -> [URL] {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        guard let text = data as? String else { return [] }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { $0.url }
    }

    // MARK: - UI

    private func showConfirmation(items: [PendingItem]) {
        let confirmView = ShareConfirmationView(
            itemCount: items.count,
            feedCount: items.reduce(0) { $0 + max($1.foundFeeds.count, 1) }
        ) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let hosting = UIHostingController(rootView: confirmView)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Feedmine", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: NSError(
                domain: "com.feedmine.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        })
        present(alert, animated: true)
    }
}
