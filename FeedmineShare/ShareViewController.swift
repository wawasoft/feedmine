import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the Feedmine Share Extension.
/// Extracts URLs, files, and text from the extension context,
/// writes them to the App Group pending queue, then shows confirmation UI.
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

            for item in extensionItems {
                // 1. URL attachments
                if let urlProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
                    for provider in urlProviders {
                        if let url = try? await loadURL(from: provider) {
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

                // 2. File attachments (OPML)
                if let fileProviders = item.attachments?.filter({
                    $0.hasItemConformingToTypeIdentifier("org.opml.opml") ||
                    $0.hasItemConformingToTypeIdentifier("public.xml")
                }) {
                    for provider in fileProviders {
                        if let result = try? await loadFile(from: provider) {
                            if result.isOPML {
                                pendingItems.append(PendingItem(
                                    id: UUID().uuidString,
                                    type: .opmlImport,
                                    sourceURL: result.url?.absoluteString ?? "file://\(result.fileName)",
                                    foundFeeds: [],
                                    fileName: result.fileName,
                                    feedCount: nil,
                                    receivedAt: Int(Date().timeIntervalSince1970)
                                ))
                            }
                        }
                    }
                }

                // 3. Text content
                if let textProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
                    for provider in textProviders {
                        if let urls = try? await extractURLsFromText(from: provider) {
                            for url in urls {
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

    private func loadFile(from provider: NSItemProvider) async throws -> (fileName: String, url: URL?, isOPML: Bool)? {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.xml.identifier)
        if let url = data as? URL {
            let fileName = url.lastPathComponent
            let isOPML = fileName.hasSuffix(".opml") || fileName.hasSuffix(".xml")
            return (fileName, url, isOPML)
        }
        return nil
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
