import SwiftUI
import WebKit

////////////////////////////////////////////////////////////////////////////////
//
//  BrowserPanel — 内置浏览器，和 iOS / 鸿蒙平板同一套：
//    左侧栏分「后台」（PinnedLinksStore，管理后台清单，跟手机同步）
//    和「原型」（prototype.douwantech.com 目录，ProtoCatalog，默认最近更新混排）；
//    右边一个 WKWebView，整站 Basic Auth 自动带账密。
//
//  顶栏那颗地球按钮开关它（RootView.TopBar），⌘B 也行。
//
////////////////////////////////////////////////////////////////////////////////

// MARK: - WebView + 导航状态

final class BrowserWeb: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL = ""
    /// 地址栏文本（正在编辑时不被导航回调顶掉）
    @Published var urlText = ""
    @Published var editing = false

    let webView: WKWebView
    private var obs: [NSKeyValueObservation] = []
    /// 每个 host 只自动应答一次 Basic Auth，账密错了也不会死循环
    private var authTries: [String: Int] = [:]

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        obs = [
            webView.observe(\.canGoBack) { [weak self] w, _ in self?.canGoBack = w.canGoBack },
            webView.observe(\.canGoForward) { [weak self] w, _ in self?.canGoForward = w.canGoForward },
            webView.observe(\.isLoading) { [weak self] w, _ in self?.isLoading = w.isLoading },
            webView.observe(\.url) { [weak self] w, _ in
                guard let self, let u = w.url?.absoluteString else { return }
                self.currentURL = u
                if !self.editing { self.urlText = u }
            },
        ]
    }

    func load(_ raw: String) {
        guard let u = Self.normalize(raw) else { return }
        authTries.removeAll()
        editing = false
        urlText = u.absoluteString
        currentURL = u.absoluteString
        webView.load(URLRequest(url: u))
    }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    static func normalize(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("about:") || s.hasPrefix("file:") {
            return URL(string: s)
        }
        if s.contains("."), !s.contains(" ") { return URL(string: "https://" + s) }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: "https://www.bing.com/search?q=" + q)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        let basicLike = m == NSURLAuthenticationMethodHTTPBasic
            || m == NSURLAuthenticationMethodHTTPDigest
            || m == NSURLAuthenticationMethodNTLM
        let host = challenge.protectionSpace.host
        if basicLike, challenge.previousFailureCount == 0, (authTries[host] ?? 0) < 1 {
            authTries[host] = (authTries[host] ?? 0) + 1
            var cred = PinnedLinksStore.credentials(forHost: host)
            if cred == nil, host == kProtoHost { cred = ProtoCatalog.credentials() }
            if let cred {
                completionHandler(.useCredential,
                                  URLCredential(user: cred.0, password: cred.1, persistence: .forSession))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let web: BrowserWeb
    func makeNSView(context: Context) -> WKWebView { web.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - 侧栏数据（后台 / 原型）

final class BrowserCatalog: ObservableObject {
    @Published var seg = UserDefaults.standard.integer(forKey: "BrowserPanel.segment")
    @Published var links: [PinnedLink] = []
    @Published var items: [ProtoItem] = []
    @Published var sections: [String] = []
    @Published var filter = ""          // "" = 最近更新
    @Published var query = ""
    @Published var fetchedAt: Date?
    @Published var loading = false
    @Published var message = ""

    init() {
        links = PinnedLinksStore.links()
        if let c = ProtoCatalog.loadCache() {
            items = c.items; sections = c.sections; fetchedAt = c.fetchedAt
        }
    }

    func reloadLinks() { links = PinnedLinksStore.links() }

    /// 新增（index = nil）或改写一条后台，落盘同步文件 + iCloud KV
    func upsert(_ l: PinnedLink, at index: Int?) {
        if let i = index, links.indices.contains(i) { links[i] = l } else { links.append(l) }
        PinnedLinksStore.save(links)
    }

    func remove(at index: Int) {
        guard links.indices.contains(index) else { return }
        links.remove(at: index)
        PinnedLinksStore.save(links)
    }

    /// 目录 10 分钟内拉过就不重拉（侧栏底部可手动刷新）
    func refreshIfStale() {
        if let at = fetchedAt, Date().timeIntervalSince(at) < 600 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        message = ""
        ProtoCatalog.fetch { [weak self] r in
            guard let self else { return }
            self.loading = false
            switch r {
            case .ok(let c):
                ProtoCatalog.saveCache(c)
                self.items = c.items
                self.sections = c.sections
                self.fetchedAt = c.fetchedAt
                if !self.filter.isEmpty && !c.sections.contains(self.filter) { self.filter = "" }
            case .noauth(let m), .error(let m):
                self.message = m
            }
        }
    }

    var visible: [ProtoItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var arr = items.filter { it in
            (filter.isEmpty || it.section == filter) &&
            (q.isEmpty || it.title.lowercased().contains(q) || it.desc.lowercased().contains(q)
             || it.section.lowercased().contains(q))
        }
        if filter.isEmpty {
            arr = arr.enumerated().sorted {
                $0.element.updated == $1.element.updated ? $0.offset < $1.offset
                                                         : $0.element.updated > $1.element.updated
            }.map { $0.element }
        }
        return arr
    }

    var footer: String {
        if loading { return "更新中…" }
        guard let at = fetchedAt else { return message }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "\(items.count) 页 · \(f.string(from: at)) 更新" + (message.isEmpty ? "" : " · 刷新失败")
    }
}

// MARK: - 后台编辑器

/// 正在编辑的一条后台（index = nil 表示新增）
struct PinnedDraft: Identifiable {
    let id = UUID()
    var index: Int?
    var title = ""
    var url = ""
    var user = ""
    var pass = ""
}

private struct PinnedEditor: View {
    @State var draft: PinnedDraft
    var onSave: (PinnedLink, Int?) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.index == nil ? "添加后台" : "编辑后台")
                .font(Theme.ui(14, .semibold)).foregroundColor(Theme.fg)
            field("名称（可空，会用网址）", text: $draft.title)
            field("网址", text: $draft.url)
            Text("HTTP Basic 账密（可空）").font(Theme.ui(11)).foregroundColor(Theme.dim)
            HStack(spacing: 8) {
                field("用户名", text: $draft.user, label: false)
                SecureField("密码", text: $draft.pass)
                    .textFieldStyle(.plain).font(Theme.ui(12)).foregroundColor(Theme.fg)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel3))
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).buttonStyle(.plain)
                    .font(Theme.ui(12)).foregroundColor(Theme.sub)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill2))
                Button("保存") {
                    let u = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty else { return }
                    onSave(PinnedLink(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      url: u.contains("://") ? u : "https://" + u,
                                      authUser: draft.user.isEmpty ? nil : draft.user,
                                      authPassword: draft.pass.isEmpty ? nil : draft.pass),
                           draft.index)
                }
                .buttonStyle(.plain)
                .font(Theme.ui(12, .semibold)).foregroundColor(Theme.bg)
                .padding(.horizontal, 16).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.teal))
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.panel2)
    }

    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>, label: Bool = true) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.ui(12)).foregroundColor(Theme.fg)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel3))
    }
}

// MARK: - 面板

struct BrowserPanel: View {
    @EnvironmentObject var state: AppState
    @StateObject private var web = BrowserWeb()
    @StateObject private var cat = BrowserCatalog()
    @AppStorage("BrowserPanel.sidebar") private var showSidebar = true
    @AppStorage("BrowserPanel.last") private var lastURL = ""
    @State private var draft: PinnedDraft?      // 正在添加/编辑的后台
    @State private var deleting: Int?           // 待确认删除的后台下标
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hair)
            HStack(spacing: 0) {
                if showSidebar {
                    sidebar.frame(width: 290)
                    Divider().overlay(Theme.hair)
                }
                ZStack {
                    WebViewHost(web: web)
                    if web.currentURL.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 34)).foregroundColor(Color(hex: 0x4a515c))
                            Text("从左侧选一个后台或原型").font(Theme.ui(13)).foregroundColor(Theme.sub)
                            Text("也可以在地址栏直接输入网址").font(Theme.ui(12)).foregroundColor(Theme.dim)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.term)
                    }
                }
            }
        }
        .background(Theme.panel2)
        .onAppear {
            cat.reloadLinks()
            cat.refreshIfStale()
            if web.currentURL.isEmpty {
                let first = lastURL.isEmpty ? (cat.links.first?.url ?? "") : lastURL
                if !first.isEmpty { web.load(first) }
            }
        }
    }

    // MARK: 顶栏

    private var toolbar: some View {
        HStack(spacing: 4) {
            IconButton(system: showSidebar ? "sidebar.left" : "sidebar.leading",
                       color: showSidebar ? Theme.teal : Theme.sub, iconSize: 15) {
                showSidebar.toggle()
            }
            IconButton(system: "chevron.left", color: web.canGoBack ? Theme.fg : Color(hex: 0x3a4048),
                       iconSize: 14) { web.webView.goBack() }
            IconButton(system: "chevron.right", color: web.canGoForward ? Theme.fg : Color(hex: 0x3a4048),
                       iconSize: 14) { web.webView.goForward() }

            HStack(spacing: 6) {
                Image(systemName: lockIcon)
                    .font(.system(size: 11))
                    .foregroundColor(web.urlText.hasPrefix("http://") ? Theme.wait : Theme.dim)
                TextField("搜索或输入网址", text: $web.urlText, onEditingChanged: { web.editing = $0 })
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .foregroundColor(Theme.fg)
                    .onSubmit { open(web.urlText, title: "") }
                IconButton(system: web.isLoading ? "xmark" : "arrow.clockwise", size: 24, iconSize: 12) {
                    web.reloadOrStop()
                }
            }
            .padding(.leading, 12).padding(.trailing, 2)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 15).fill(Theme.panel3))

            IconButton(system: "xmark", iconSize: 14, action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Theme.panel)
    }

    private var lockIcon: String {
        if web.urlText.hasPrefix("https://") { return "lock.fill" }
        if web.urlText.hasPrefix("http://") { return "exclamationmark.triangle.fill" }
        return "globe"
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $cat.seg) {
                Text("后台 \(cat.links.count)").tag(0)
                Text("原型 \(cat.items.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            .onChange(of: cat.seg) { new in
                UserDefaults.standard.set(new, forKey: "BrowserPanel.segment")
                if new == 1 { cat.refreshIfStale() }
            }

            if cat.seg == 0 { adminList } else { protoList }

            Divider().overlay(Theme.hair)
            HStack(spacing: 6) {
                Text(cat.seg == 1 ? cat.footer : "右键编辑 · 与手机 / 平板同步")
                    .font(Theme.mono(10.5)).foregroundColor(Theme.dim).lineLimit(1)
                Spacer()
                if cat.seg == 1 {
                    IconButton(system: "arrow.clockwise", size: 26, iconSize: 13) { cat.refresh() }
                } else {
                    IconButton(system: "plus", color: Theme.teal, size: 26, iconSize: 14) {
                        // 默认填当前网页，直接钉住看着的这一页
                        draft = PinnedDraft(index: nil,
                                            title: web.webView.title ?? "",
                                            url: web.currentURL)
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
        }
        .background(Theme.panel)
        .sheet(item: $draft) { d in
            PinnedEditor(draft: d, onSave: { link, idx in
                cat.upsert(link, at: idx)
                draft = nil
                open(link.url, title: link.title)
            }, onCancel: { draft = nil })
        }
        .alert("删除后台", isPresented: Binding(get: { deleting != nil },
                                             set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let i = deleting { cat.remove(at: i) }
                deleting = nil
            }
        } message: {
            Text(deleting.flatMap { cat.links.indices.contains($0) ? cat.links[$0] : nil }
                .map { "删除「\($0.title.isEmpty ? $0.host : $0.title)」？" } ?? "")
        }
    }

    private var adminList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(cat.links.enumerated()), id: \.element.id) { i, l in
                    let on = same(web.currentURL, l.url)
                    Button { open(l.url, title: l.title) } label: {
                        HStack(spacing: 10) {
                            Text(String((l.title.isEmpty ? l.host : l.title).prefix(1)).uppercased())
                                .font(Theme.ui(12, .bold)).foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8).fill(grad(i)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.title.isEmpty ? l.host : l.title)
                                    .font(Theme.ui(13)).foregroundColor(Theme.fg).lineLimit(1)
                                Text(l.host).font(Theme.mono(10)).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let u = l.authUser, !u.isEmpty {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9)).foregroundColor(Color(hex: 0x4a515c))
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(on ? Theme.teal.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑") {
                            draft = PinnedDraft(index: i, title: l.title, url: l.url,
                                                user: l.authUser ?? "", pass: l.authPassword ?? "")
                        }
                        Button("删除", role: .destructive) { deleting = i }
                    }
                }
                if cat.links.isEmpty {
                    Text("还没有后台\n在手机或平板上钉一个网址，会同步过来")
                        .font(Theme.ui(12)).foregroundColor(Theme.dim)
                        .multilineTextAlignment(.center).padding(.top, 40)
                }
            }
            .padding(.horizontal, 8).padding(.top, 4)
        }
    }

    private var protoList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.dim)
                TextField("搜索原型", text: $cat.query)
                    .textFieldStyle(.plain).font(Theme.ui(12)).foregroundColor(Theme.fg)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel3))
            .padding(.horizontal, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("最近更新", "")
                    ForEach(cat.sections, id: \.self) { s in chip(s, s) }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26).padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(cat.visible, id: \.url) { it in
                        let on = same(web.currentURL, it.url)
                        Button { open(it.url, title: it.title) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(it.title).font(Theme.ui(12.5)).foregroundColor(Color(hex: 0xe3e8ed))
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                if !cat.filter.isEmpty && !it.desc.isEmpty {
                                    Text(it.desc).font(Theme.ui(11)).foregroundColor(Theme.dim).lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    if it.isNew {
                                        Text("新").font(Theme.ui(9, .bold)).foregroundColor(.black)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.wait))
                                    }
                                    Text(dateLabel(it))
                                        .font(Theme.mono(10)).foregroundColor(Color(hex: 0x5a636e)).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(on ? Theme.rest.opacity(0.16) : Color.white.opacity(0.035)))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(on ? Theme.rest.opacity(0.45) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    if cat.visible.isEmpty {
                        Text(cat.loading ? "正在拉取原型目录…"
                                         : (cat.message.isEmpty ? "还没有原型目录" : cat.message))
                            .font(Theme.ui(12)).foregroundColor(Theme.dim).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func chip(_ label: String, _ key: String) -> some View {
        let on = cat.filter == key
        return Button { cat.filter = key } label: {
            Text(label).font(Theme.ui(11.5))
                .foregroundColor(on ? Color(hex: 0xd9d8ff) : Theme.sub)
                .padding(.horizontal, 11).frame(height: 24)
                .background(Capsule().fill(on ? Theme.rest.opacity(0.22) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    // MARK: 小工具

    private func open(_ url: String, title: String) {
        web.load(url)
        if let u = BrowserWeb.normalize(url) { lastURL = u.absoluteString }
    }

    private func dateLabel(_ it: ProtoItem) -> String {
        let d = it.updated.count >= 10 ? String(it.updated.dropFirst(5).prefix(5)) : ""
        return d + (cat.filter.isEmpty && !it.section.isEmpty ? "  ·  \(it.section)" : "")
    }

    private func grad(_ i: Int) -> LinearGradient {
        let pairs: [(UInt, UInt)] = [(0x4ea8ff, 0x8f8cff), (0xf5a83d, 0xff5a5c),
                                     (0x40d68c, 0x63d3e8), (0x8f8cff, 0x5a57c9)]
        let p = pairs[i % pairs.count]
        return LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func same(_ a: String, _ b: String) -> Bool {
        func strip(_ u: String) -> String {
            var s = u.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return !a.isEmpty && !b.isEmpty && strip(a) == strip(b)
    }
}
