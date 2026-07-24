import SwiftUI
import WebKit

struct ArticleReaderView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArticleWebView(item: item)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = URL(string: item.url) {
                            Link(destination: url) {
                                Image(systemName: "safari")
                                    .font(.title3)
                            }
                        }
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }
}

struct ArticleWebView: UIViewRepresentable {
    let item: FeedItem

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.navigationDelegate = context.coordinator

        // Thin progress bar at top of web content
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.tintColor = .systemBlue
        progressView.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: webView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])
        context.coordinator.progressView = progressView

        // Observe loading progress
        context.coordinator.progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
            let progress = Float(webView.estimatedProgress)
            context.coordinator.progressView?.progress = progress
            context.coordinator.progressView?.isHidden = progress >= 1.0
        }

        loadContent(in: webView, context: context)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload if item changed (e.g. reused for different article) (#46)
        guard item.id != context.coordinator.lastLoadedItemID else { return }
        loadContent(in: webView, context: context)
    }

    private func loadContent(in webView: WKWebView, context: Context) {
        context.coordinator.lastLoadedItemID = item.id

        Task {
            if let pageURL = await DownloadManager.shared.localPagePath(for: item.id) {
                let html = try? String(contentsOfFile: pageURL.path, encoding: .utf8)
                if let html {
                    let baseURL = pageURL.deletingLastPathComponent()
                    await MainActor.run {
                        webView.loadHTMLString(html, baseURL: baseURL)
                    }
                    return
                }
            }

            // Fallback: load live URL
            if let url = URL(string: item.url) {
                await MainActor.run {
                    webView.load(URLRequest(url: url))
                }
            }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var progressView: UIProgressView?
        var progressObservation: NSKeyValueObservation?
        var lastLoadedItemID: String?

        deinit {
            progressObservation?.invalidate()
        }
    }
}
