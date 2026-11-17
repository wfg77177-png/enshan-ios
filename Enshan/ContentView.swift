import SwiftUI
import WebKit

// MARK: - Search JS (injected at document end)
// Uses the site's own header search form when present (it carries the
// formhash Discuz requires); otherwise navigates to the search page.
private let esSearchJS = """
(function(){
  window.__esSearch = function(q){
    var input = document.querySelector('#scbar_txt, input[name="srchtxt"]');
    var form = input ? input.closest('form') : null;
    if (input && form) {
      input.value = q;
      form.submit();
      return true;
    }
    location.href = 'https://www.right.com.cn/search.php?mod=forum&srchtxt=' + encodeURIComponent(q);
    return true;
  };
})();
"""

// MARK: - Model (minimal: navigation only)
// Enshan has NO sign-in API/button. The daily reward (+1 恩山币) is
// granted by visiting while logged in, so opening the app IS the daily
// visit. No attendance call is made. Login state lives only in the
// WKWebView system cookie jar.
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?

    @Published var searchHistory: [String] = []

    // Trailing slash: /forum without it 301-redirects once (wasted round trip).
    let homeURL = URL(string: "https://www.right.com.cn/forum/")!
    let sections = ["OpenWrt", "小米", "拆机", "TP-LINK", "华为", "中兴", "CPE", "腾达", "华硕", "H3C", "斐讯", "360"]

    init() {
        if let data = UserDefaults.standard.data(forKey: "es_searchHistory"),
           let d = try? JSONDecoder().decode([String].self, from: data) { searchHistory = d }
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func goHome() { load(homeURL) }

    func reload() { webView?.reload() }

    func searchSite(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchHistory.removeAll { $0 == query }
        searchHistory.insert(query, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: "es_searchHistory")
        }
        webView?.evaluateJavaScript("window.__esSearch && window.__esSearch('\(jsString(query))');", completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    func backToTop() {
        webView?.evaluateJavaScript("window.scrollTo({top:0, behavior:'smooth'});", completionHandler: nil)
    }

    // Tap a section name: find the matching board link on the page and click it.
    // Exact board-name match first, then substring match (board titles on the
    // homepage carry brand/type suffixes, e.g. "小米/红米无线路由器…").
    // One-shot evaluateJavaScript only; no injected user script.
    func goSection(_ name: String) {
        let js = """
        (function(){
          var links = Array.prototype.slice.call(document.querySelectorAll('a'));
          var hit = links.find(function(a){
            var t = (a.textContent || '').trim();
            return t === '\(name)' && a.getAttribute('href') && a.getAttribute('href').indexOf('/') === 0;
          });
          if (!hit) {
            hit = links.find(function(a){
              var t = (a.textContent || '').trim();
              return t.indexOf('\(name)') !== -1 && a.getAttribute('href') && a.getAttribute('href').indexOf('forum') !== -1;
            });
          }
          if (hit) { hit.click(); return true; }
          return false;
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - Content
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showSections: $showSections)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
    }
}

// MARK: - WebView
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Explicit default (persistent) data store: cache + cookies persist
        // across launches, so repeat opens reuse cache and the Cloudflare
        // cf_clearance cookie instead of re-verifying. Never clear it,
        // never use .nonPersistent(), never reload ignoring local cache.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // One small user script only: the in-site search bridge.
        // No other injected JS.
        let searchScript = WKUserScript(source: esSearchJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(searchScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // Leave room so the last line is never hidden behind the bottom bar.
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        // Load immediately.
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
    }
}

// MARK: - Bottom bar (3 buttons only)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool

    var body: some View {
        HStack(spacing: 4) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Sections sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func doSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.searchSite(q)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("搜索恩山帖子", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    if !model.searchHistory.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.searchHistory, id: \.self) { h in
                                    Button(h) {
                                        searchText = h
                                        model.searchSite(h)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.sections, id: \.self) { name in
                        Button {
                            model.goSection(name)
                            dismiss()
                        } label: {
                            Text(name)
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                Text("点分区名即跳到对应版块。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            .navigationTitle("分区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
