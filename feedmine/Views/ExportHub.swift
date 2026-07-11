import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - ExportHub

struct ExportHub: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared

    // Toast state
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark.circle.fill"

    // OPML
    @State private var opmlScope: OPMLScope = .all
    enum OPMLScope: String, CaseIterable { case all, mine
        var label: String {
            switch self {
            case .all: return String(localized: "All")
            case .mine: return String(localized: "Mine")
            }
        }
    }

    // JSON import
    @State private var showJSONImporter = false
    @State private var jsonImportError: String?

    // HTML preview
    @State private var generatedHTML: String?
    @State private var showHTMLPreview = false

    // PDF preview
    @State private var generatedPDF: Data?
    @State private var showPDFPreview = false

    private var userSources: [FeedSource] {
        loader.sources.filter { $0.origin == .user || $0.origin == .imported }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                engine.pageBackground.ignoresSafeArea()

                List {
                    // MARK: - Data Formats
                    Section {
                        // OPML
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .font(.title3)
                                    .foregroundStyle(engine.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("OPML")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Feed list for other RSS readers")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Picker("Scope", selection: $opmlScope) {
                                ForEach(OPMLScope.allCases, id: \.self) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(opmlDisabled)
                            if opmlScope == .mine && userSources.isEmpty {
                                Text("No user sources")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            ShareLink(item: opmlExportString) {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                            .disabled(opmlDisabled)
                            .tint(engine.accent)
                        }
                        .padding(.vertical, 4)

                        // CSV
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "tablecells")
                                    .font(.title3)
                                    .foregroundStyle(engine.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("CSV")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Bookmarks as spreadsheet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                ShareLink(item: csvExportString) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                        .font(.subheadline)
                                }
                                .disabled(loader.bookmarkedIDs.isEmpty)
                                .tint(engine.accent)
                                if loader.bookmarkedIDs.isEmpty {
                                    Text("No bookmarks to export")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // JSON
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox")
                                    .font(.title3)
                                    .foregroundStyle(engine.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("JSON")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Full backup: library, lists, channels, settings")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                ShareLink(item: jsonExportString) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                        .font(.subheadline)
                                }
                                .tint(engine.accent)

                                Button {
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                    showJSONImporter = true
                                } label: {
                                    Label("Import", systemImage: "square.and.arrow.down")
                                        .font(.subheadline)
                                }
                                .tint(engine.accent)
                            }
                            if let error = jsonImportError {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Label("Data Formats", systemImage: "gearshape.2")
                    }

                    // MARK: - Document Formats
                    Section {
                        // HTML
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "safari")
                                    .font(.title3)
                                    .foregroundStyle(engine.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("HTML")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Bookmarks as self-contained web page")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                Button {
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                    generateHTML()
                                } label: {
                                    Label("Generate", systemImage: "doc.badge.gearshape")
                                        .font(.subheadline)
                                }
                                .disabled(loader.bookmarkedIDs.isEmpty)
                                .tint(engine.accent)
                                if loader.bookmarkedIDs.isEmpty {
                                    Text("No bookmarks to export")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // PDF
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.richtext")
                                    .font(.title3)
                                    .foregroundStyle(engine.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("PDF")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("Reading stats + bookmark list, formatted")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                generatePDF()
                            } label: {
                                Label("Generate", systemImage: "doc.badge.gearshape")
                                    .font(.subheadline)
                            }
                            .tint(engine.accent)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Label("Document Formats", systemImage: "doc.viewfinder")
                    }
                }
                .scrollContentBackground(.hidden)

                // Toast overlay
                toastOverlay
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(engine.accent)
                }
            }
            .fileImporter(isPresented: $showJSONImporter, allowedContentTypes: [.json, .init(filenameExtension: "feedmine")!]) { result in
                handleJSONImport(result)
            }
            .sheet(isPresented: $showHTMLPreview) {
                HTMLPreviewView(html: $generatedHTML, onShare: { showToast(message: "Exported as HTML") })
            }
            .sheet(isPresented: $showPDFPreview) {
                PDFPreviewView(pdfData: $generatedPDF, onShare: { showToast(message: "Exported as PDF") })
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: toastIcon).font(.subheadline)
                    Text(toastMessage).font(.subheadline).fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showToast = false }
                    }
                }
            }
        }
    }

    private func showToast(message: String) {
        toastMessage = message
        toastIcon = "checkmark.circle.fill"
        withAnimation { showToast = true }
    }

    // MARK: - OPML

    private var opmlDisabled: Bool {
        opmlScope == .mine && userSources.isEmpty
    }

    private var opmlExportString: String {
        let sources: [FeedSource]
        switch opmlScope {
        case .all: sources = loader.sources
        case .mine: sources = userSources
        }
        return OPMLParser.exportOPML(sources: sources)
    }

    // MARK: - CSV

    private var csvExportString: String {
        let items = loader.bookmarkedItems
        var csv = "Title,URL,Category,Date Saved\n"
        let formatter = ISO8601DateFormatter()
        for item in items {
            let title = item.title.replacingOccurrences(of: "\"", with: "\"\"")
            let date = formatter.string(from: item.publishedAt)
            csv += "\"\(title)\",\"\(item.url)\",\"\(item.category)\",\"\(date)\"\n"
        }
        return csv
    }

    // MARK: - JSON

    private var jsonExportString: String {
        struct Backup: Codable {
            let exportDate: Date
            let sourceCount: Int
            let enabledCount: Int
            let readCount: Int
            let bookmarkCount: Int
            let sources: [BackupSource]
            let bookmarks: [BackupBookmark]
        }
        struct BackupSource: Codable {
            let title: String
            let url: String
            let category: String
            let region: String
            let origin: String
        }
        struct BackupBookmark: Codable {
            let title: String
            let url: String
            let category: String
        }

        let bSources = loader.sources.map { BackupSource(title: $0.title, url: $0.url, category: $0.category, region: $0.region, origin: $0.origin.rawValue) }
        let bBookmarks = loader.bookmarkedItems.map { BackupBookmark(title: $0.title, url: $0.url, category: $0.category) }

        let backup = Backup(
            exportDate: Date(),
            sourceCount: loader.sources.count,
            enabledCount: loader.enabledSources.count,
            readCount: loader.readItemIDs.count,
            bookmarkCount: loader.bookmarkedIDs.count,
            sources: bSources,
            bookmarks: bBookmarks
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(backup)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - JSON Import

    private func handleJSONImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let backup = try decoder.decode(BackupCodable.self, from: data)
                jsonImportError = nil
                showToast(message: "Imported backup: \(backup.sourceCount) sources, \(backup.bookmarkCount) bookmarks")
            } catch {
                jsonImportError = "Failed to import: \(error.localizedDescription)"
            }
        case .failure(let error):
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            jsonImportError = error.localizedDescription
        }
    }

    private struct BackupCodable: Codable {
        let sourceCount: Int
        let bookmarkCount: Int
        let sources: [BackupSourceCodable]
        let bookmarks: [BackupBookmarkCodable]
    }

    private struct BackupSourceCodable: Codable {
        let title: String
        let url: String
        let category: String
        let region: String
        let origin: String
    }

    private struct BackupBookmarkCodable: Codable {
        let title: String
        let url: String
        let category: String
    }

    // MARK: - HTML Generation

    private func generateHTML() {
        let items = loader.bookmarkedItems
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Feedmine Bookmarks</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 20px; }
            h1 { font-size: 28px; font-weight: 700; margin-bottom: 4px; }
            .subtitle { color: #86868b; margin-bottom: 24px; font-size: 14px; }
            .card { background: white; border-radius: 12px; padding: 16px; margin-bottom: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
            .card h2 { font-size: 17px; font-weight: 600; margin-bottom: 4px; }
            .card h2 a { color: #1d1d1f; text-decoration: none; }
            .card h2 a:hover { text-decoration: underline; }
            .card .meta { font-size: 12px; color: #86868b; }
            .card .category { display: inline-block; background: #007aff15; color: #007aff; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 500; margin-top: 8px; }
            .footer { text-align: center; color: #86868b; font-size: 12px; margin-top: 32px; padding-top: 16px; border-top: 1px solid #d2d2d7; }
        </style>
        </head>
        <body>
        <h1>Feedmine Bookmarks</h1>
        <p class="subtitle">\(items.count) bookmarks &middot; Exported \(ISO8601DateFormatter().string(from: Date()))</p>
        """

        for item in items {
            let title = item.title
            let url = item.url
            let category = item.category
            let dateStr = Self.dateFormatter.string(from: item.publishedAt)
            html += """
            <div class="card">
                <h2><a href="\(url)">\(title)</a></h2>
                <div class="meta">\(url)</div>
                <div class="meta">\(dateStr)</div>
                <span class="category">\(category)</span>
            </div>
            """
        }

        html += """
        <div class="footer">Generated by Feedmine</div>
        </body>
        </html>
        """

        generatedHTML = html
        showHTMLPreview = true
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    // MARK: - PDF Generation

    private func generatePDF() {
        let fmt = UIGraphicsPDFRendererFormat()
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: fmt)

        let data = renderer.pdfData { ctx in
            ctx.beginPage()

            let titleFont = UIFont.boldSystemFont(ofSize: 24)
            let subtitleFont = UIFont.systemFont(ofSize: 14)
            let bodyFont = UIFont.systemFont(ofSize: 12)
            let accentColor = UIColor(engine.accent)

            // Title
            "Feedmine Report".draw(at: CGPoint(x: 40, y: 40), withAttributes: [
                .font: titleFont,
                .foregroundColor: accentColor
            ])

            // Stats
            let statsY: CGFloat = 90
            let stats: [(String, String)] = [
                ("Sources", "\(loader.sources.count)"),
                ("Read", "\(loader.readItemIDs.count) articles"),
                ("Bookmarks", "\(loader.bookmarkedIDs.count)"),
            ]
            var y: CGFloat = statsY
            for (label, value) in stats {
                label.draw(at: CGPoint(x: 40, y: y), withAttributes: [
                    .font: subtitleFont,
                    .foregroundColor: UIColor.secondaryLabel
                ])
                value.draw(at: CGPoint(x: 200, y: y), withAttributes: [
                    .font: subtitleFont,
                    .foregroundColor: UIColor.label
                ])
                y += 22
            }

            // Bookmark list
            y += 20
            let items = loader.bookmarkedItems
            if !items.isEmpty {
                "Bookmarks".draw(at: CGPoint(x: 40, y: y), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: accentColor
                ])
                y += 30

                for item in items.prefix(30) {
                    guard y < 740 else { break }
                    let title = item.title
                    (title as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [
                        .font: bodyFont,
                        .foregroundColor: UIColor.label
                    ])
                    y += 18
                    (item.url as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.secondaryLabel
                    ])
                    y += 16
                    y += 8
                }

                if items.count > 30 {
                    (String(format: "+ %d more bookmarks", items.count - 30) as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [
                        .font: subtitleFont,
                        .foregroundColor: UIColor.secondaryLabel
                    ])
                }
            }

            // Footer
            (String(format: "Generated by Feedmine — %@", ISO8601DateFormatter().string(from: Date())) as NSString).draw(at: CGPoint(x: 40, y: 750), withAttributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.tertiaryLabel
            ])
        }

        generatedPDF = data
        showPDFPreview = true
    }
}

// MARK: - HTML Preview Sheet

struct HTMLPreviewView: View {
    @Binding var html: String?
    let onShare: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared

    var body: some View {
        NavigationStack {
            if let html {
                HTMLWebView(html: html)
                    .ignoresSafeArea()
                    .navigationTitle("Preview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { dismiss() }
                                .foregroundStyle(engine.accent)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: html) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(engine.accent)
                        }
                    }
            }
        }
    }
}

struct HTMLWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - PDF Preview Sheet

struct PDFPreviewView: View {
    @Binding var pdfData: Data?
    let onShare: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            if let data = pdfData {
                PDFWebView(data: data)
                    .ignoresSafeArea()
                    .navigationTitle("Preview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { dismiss() }
                                .foregroundStyle(engine.accent)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            if let url = shareURL {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(engine.accent)
                            } else {
                                Button {
                                    writePDFToTempFile()
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(engine.accent)
                            }
                        }
                    }
                    .onAppear { writePDFToTempFile() }
            }
        }
    }

    private func writePDFToTempFile() {
        guard let data = pdfData else { return }
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("Feedmine-Report-\(UUID().uuidString.prefix(8)).pdf")
        try? data.write(to: url)
        shareURL = url
    }
}

struct PDFWebView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(data, mimeType: "application/pdf", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
