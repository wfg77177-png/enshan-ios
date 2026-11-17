import SwiftUI
import WebKit

// MARK: - JS injected at document start (tiny: dark + ad-hide CSS only)
// Runs before first paint to kill the white flash. Reads display settings
// from localStorage only (dark / hideAds). No credentials, no sign-in.
private let esJSStart = """
(function(){
  function read(k,d){ try{ var v=localStorage.getItem('es_'+k); return v===null?d:v; }catch(e){ return d; } }
  if(read('dark','0')==='1'){
    var el=document.createElement('style'); el.id='es-dark-style';
    el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
    document.documentElement.appendChild(el);
  }
  if(read('hideAds','1')==='1'){
    var el2=document.createElement('style'); el2.id='es-ad-style';
    el2.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
    document.documentElement.appendChild(el2);
  }
})();
"""

// MARK: - JS injected at document end
// Safe features only: dark mode toggle, hide ads toggle, keyword filter,
// fullscreen images, remember scroll position, section navigation.
// NOTE: Enshan has NO sign-in API/button. The daily reward (+1 恩山币)
// is granted by visiting while logged in, so opening the app IS the
// daily visit. No attendance call is made here. Login state lives only
// in the WKWebView system cookie jar; localStorage holds display
// settings only (dark / hideAds / keywords), never any credential.
private let esJSEnd = """
(function(){
  function store(k,v){ try{ localStorage.setItem('es_'+k, v); }catch(e){} }
  function read(k,d){ try{ var v=localStorage.getItem('es_'+k); return v===null?d:v; }catch(e){ return d; } }

  // ---------- 1. Dark mode (toggle; start script already applied the CSS) ----------
  window.__esSetDark = function(on){
    store('dark', on?'1':'0');
    var id='es-dark-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('dark','0')==='1') { window.__esSetDark(true); }

  // ---------- 2. Hide ads / promo blocks (toggle; start script already applied the CSS) ----------
  window.__esSetHideAds = function(on){
    store('hideAds', on?'1':'0');
    var id='es-ad-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('hideAds','1')==='1') { window.__esSetHideAds(true); }

  // ---------- 3. Keyword filter (hide thread rows whose title contains a keyword) ----------
  // Discuz thread links look like thread-123-1-1.html or forum.php?mod=viewthread.
  window.__esSetKeywords = function(csv){
    store('keywords', csv||'');
    applyKeywords();
  };
  function applyKeywords(){
    var csv = read('keywords','');
    var kws = csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
    var rows = document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
    rows.forEach(function(a){
      var row = a.closest('li, article, div, tr');
      if(!row) return;
      var txt = (a.textContent||'');
      var hit = kws.some(function(k){ return txt.indexOf(k) !== -1; });
      row.style.display = hit ? 'none' : '';
    });
  }
  window.__esApplyKeywords = applyKeywords;
  applyKeywords();
  new MutationObserver(function(){ applyKeywords(); }).observe(document.documentElement, {childList:true, subtree:true});

  // ---------- 4. Fullscreen image viewer ----------
  document.addEventListener('click', function(e){
    var img = e.target.closest ? e.target.closest('img') : null;
    if(!img || !img.src) return;
    if(img.closest('a')) return;
    var ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.92);z-index:999999;display:flex;align-items:center;justify-content:center;';
    var im=document.createElement('img');
    im.src=img.src; im.style.cssText='max-width:96vw;max-height:92vh;object-fit:contain;';
    ov.appendChild(im);
    ov.addEventListener('click', function(){ ov.remove(); });
    document.body.appendChild(ov);
  }, true);

  // ---------- 5. Remember scroll position (per URL) ----------
  var saveTimer=null;
  function savePos(){
    try{ sessionStorage.setItem('es_pos_'+location.pathname, String(window.scrollY)); }catch(e){}
  }
  function restorePos(){
    try{
      var y=parseInt(sessionStorage.getItem('es_pos_'+location.pathname)||'0',10);
      if(y>200){ setTimeout(function(){ window.scrollTo(0,y); }, 350); }
    }catch(e){}
  }
  window.addEventListener('scroll', function(){
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(savePos, 400);
  }, {passive:true});
  window.addEventListener('pagehide', savePos);
  restorePos();

  // ---------- 6. Section navigation (tap a section name in the native picker) ----------
  // Exact board-name match first, then substring match (board titles on
  // the homepage carry brand/type suffixes, e.g. "小米/红米无线路由器…").
  window.__esGoSection = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      return t===name && a.getAttribute('href') && a.getAttribute('href').indexOf('/')===0;
    });
    if(!hit){
      hit = links.find(function(a){
        var t=(a.textContent||'').trim();
        return t.indexOf(name)!==-1 && a.getAttribute('href') && a.getAttribute('href').indexOf('forum')!==-1;
      });
    }
    if(hit){ hit.click(); return true; }
    return false;
  };

  // ---------- 7. Back to top ----------
  window.__esTop = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // ---------- 8. Re-run hook (called from native didFinish) ----------
  window.__esAfterLoad = function(){ applyKeywords(); restorePos(); };
})();
"""

// MARK: - Model
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?
    @Published var isDark = false
    @Published var fontScale: CGFloat = 1.0
    @Published var hideAds = true
    @Published var keywords = ""
    @Published var canGoBack = false

    // Trailing slash: /forum without it 301-redirects once (wasted round trip).
    let homeURL = URL(string: "https://www.right.com.cn/forum/")!
    let sections = ["OpenWrt","小米","拆机","TP-LINK","华为","中兴","CPE","腾达","华硕","H3C","斐讯","360"]

    init() {
        // Settings read synchronously here so the webview can load at once
        // without waiting for the view's onAppear.
        isDark = UserDefaults.standard.bool(forKey: "es_dark")
        hideAds = UserDefaults.standard.object(forKey: "es_hideAds") as? Bool ?? true
        keywords = UserDefaults.standard.string(forKey: "es_keywords") ?? ""
        let fs = UserDefaults.standard.double(forKey: "es_fontScale")
        if fs > 0 { fontScale = CGFloat(fs) }
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__esTop && window.__esTop();", completionHandler: nil)
    }
    func goSection(_ name: String) {
        webView?.evaluateJavaScript("window.__esGoSection && window.__esGoSection('\(name)');") { _, _ in }
    }
    func setDark(_ on: Bool) {
        isDark = on
        UserDefaults.standard.set(on, forKey: "es_dark")
        webView?.evaluateJavaScript("window.__esSetDark && window.__esSetDark(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setFontScale(_ s: CGFloat) {
        fontScale = s
        UserDefaults.standard.set(Double(s), forKey: "es_fontScale")
        webView?.pageZoom = s
    }
    func setHideAds(_ on: Bool) {
        hideAds = on
        UserDefaults.standard.set(on, forKey: "es_hideAds")
        webView?.evaluateJavaScript("window.__esSetHideAds && window.__esSetHideAds(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setKeywords(_ s: String) {
        keywords = s
        UserDefaults.standard.set(s, forKey: "es_keywords")
        let esc = s.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__esSetKeywords && window.__esSetKeywords('\(esc)');", completionHandler: nil)
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showSections: $showSections, showSettings: $showSettings)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
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
        // Split injection: tiny CSS-only script at document start (kills
        // white flash), the rest at document end. forMainFrameOnly: true
        // keeps the scripts out of every ad iframe.
        let startScript = WKUserScript(source: esJSStart, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let endScript = WKUserScript(source: esJSEnd, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(startScript)
        config.userContentController.addUserScript(endScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
        // Load immediately: settings were already read in the model init.
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
            // Re-apply keyword filter + scroll restore now the page is done.
            webView.evaluateJavaScript("window.__esAfterLoad && window.__esAfterLoad();", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
        }
    }
}

// MARK: - Bottom bar (comfortable proportions, smooth)
// Enshan has no sign-in button: opening the app IS the daily visit.
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 4) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: model.isDark ? "moon.fill" : "moon", label: "深色") {
                model.setDark(!model.isDark)
            }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "gearshape", label: "设置") { showSettings = true }
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

// MARK: - Section picker sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
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
                Text("点分区名即跳到对应版块；若某一名没跳过去，说明首页该版块标题写法不同，改在设置里报给我即可。")
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

// MARK: - Settings sheet
struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("每日访问") {
                    Text("恩山没有签到按钮：登录后每天打开 App 就算一次访问（+1 恩山币）。登录一次即可，登录态会一直保留；若掉登录，重新登录一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("阅读") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Stepper("", value: Binding(
                            get: { model.fontScale },
                            set: { model.setFontScale($0) }
                        ), in: 0.85...1.35, step: 0.05)
                        Text(String(format: "%.0f%%", model.fontScale * 100))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle("深色模式", isOn: Binding(
                        get: { model.isDark },
                        set: { model.setDark($0) }
                    ))
                    Toggle("隐藏广告与推广位", isOn: Binding(
                        get: { model.hideAds },
                        set: { model.setHideAds($0) }
                    ))
                }
                Section("屏蔽关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $keywordsText)
                        .onChange(of: keywordsText) { model.setKeywords($0) }
                    Text("包含这些词的帖子标题会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("刷新页面") { model.reload(); dismiss() }
                    Button("回到首页") { model.goHome(); dismiss() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { keywordsText = model.keywords }
        }
        .presentationDetents([.medium, .large])
    }
}
