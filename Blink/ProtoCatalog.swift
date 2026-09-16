////////////////////////////////////////////////////////////////////////////////
//
//  ProtoCatalog — prototype.douwantech.com 原型目录（浏览器侧栏「原型」那一面）
//
//  与鸿蒙平板版 harmony/pad/.../model/ProtoCatalog.ets 一比一对应，逻辑一致：
//    首页 site/index.html 只挑了部分条目、data-updated 被部署时的 checkout 时间刷成同一天，
//    各分区页（/ai-printer/ 等）收录全、日期准 —— 所以两层都拉再按网址合并。
//  整站 Basic Auth，账密走 PinnedTabsStore（host 匹配）或内置兜底。
//  目录缓存在 Caches/proto_index.json，没网也能显示上次的列表。
//
////////////////////////////////////////////////////////////////////////////////

import Foundation

let kProtoHost = "prototype.douwantech.com"
let kProtoOrigin = "https://prototype.douwantech.com"

struct ProtoItem: Codable, Equatable {
  var section: String
  var url: String
  var title: String
  var desc: String
  var updated: String   // YYYY-MM-DD，可能为空

  /// 3 天内更新过 → 列表上标「新」
  var isNew: Bool {
    guard updated.count >= 10 else { return false }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: String(updated.prefix(10))) else { return false }
    return Date().timeIntervalSince(d) < 3 * 86400
  }
}

struct ProtoCache: Codable {
  var fetchedAt: Date
  var sections: [String]
  var items: [ProtoItem]
}

enum ProtoFetchResult {
  case ok(ProtoCache)
  case noauth(String)
  case error(String)
}

enum ProtoCatalog {

  // MARK: 缓存

  static var cacheURL: URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("proto_index.json")
  }

  static func loadCache() -> ProtoCache? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode(ProtoCache.self, from: data)
  }

  static func saveCache(_ c: ProtoCache) {
    guard let data = try? JSONEncoder().encode(c) else { return }
    try? data.write(to: cacheURL, options: .atomic)
  }

  // MARK: 账密

  /// 原型站账密：钉住的 tab 里存的优先，其次内置兜底（与 TranscriptViewController.basicAuth 同源）
  static func credentials() -> (String, String) {
    for t in PinnedTabsStore.shared.tabs {
      guard let u = t.authUser, !u.isEmpty, let p = t.authPassword, !p.isEmpty,
            let url = URL(string: t.url), url.host == kProtoHost else { continue }
      return (u, p)
    }
    let d = UserDefaults.standard
    if let u = d.string(forKey: "ProtoCatalog.user"), !u.isEmpty,
       let p = d.string(forKey: "ProtoCatalog.pass"), !p.isEmpty {
      return (u, p)
    }
    return ("binku87", "binku87works")
  }

  static func setCredentials(user: String, pass: String) {
    let d = UserDefaults.standard
    d.set(user, forKey: "ProtoCatalog.user")
    d.set(pass, forKey: "ProtoCatalog.pass")
  }

  // MARK: 拉取

  /// 首页拿分区顺序 + 各分区页并发拉，合并后回主线程回调。
  static func fetch(completion: @escaping (ProtoFetchResult) -> Void) {
    let (user, pass) = credentials()
    get("/", user: user, pass: pass) { code, body in
      if code == 401 {
        finish(.noauth(user.isEmpty ? "需要原型站账号" : "账号或密码不对"), completion)
        return
      }
      guard code == 200, let home = body else {
        finish(.error("HTTP \(code)"), completion)
        return
      }
      let parsed = parse(home)
      if parsed.items.isEmpty {
        finish(.error("首页里没解析到原型"), completion)
        return
      }
      let group = DispatchGroup()
      var extra: [ProtoItem] = []
      let lock = NSLock()
      for link in parsed.links {
        group.enter()
        get(link.href, user: user, pass: pass) { c, b in
          if c == 200, let b {
            let items = parseItems(b, section: link.section)
            lock.lock(); extra.append(contentsOf: items); lock.unlock()
          }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        finish(.ok(merge(home: parsed, extra: extra)), completion)
      }
    }
  }

  private static func finish(_ r: ProtoFetchResult, _ completion: @escaping (ProtoFetchResult) -> Void) {
    if Thread.isMainThread { completion(r) } else { DispatchQueue.main.async { completion(r) } }
  }

  private static func get(_ path: String, user: String, pass: String,
                          done: @escaping (Int, String?) -> Void) {
    guard let u = URL(string: kProtoOrigin + path) else { done(0, nil); return }
    var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    if !user.isEmpty {
      let token = Data("\(user):\(pass)".utf8).base64EncodedString()
      req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
    URLSession.shared.dataTask(with: req) { data, resp, _ in
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      let body = (code == 200 && data != nil) ? String(data: data!, encoding: .utf8) : nil
      done(code, body)
    }.resume()
  }

  // MARK: 解析

  struct SectionLink { var section: String; var href: String }
  struct Parsed { var sections: [String]; var links: [SectionLink]; var items: [ProtoItem] }

  /// 首页条目 + 分区页条目按网址合并：分区页的标题/描述/日期优先，分区页独有的补进来
  static func merge(home: Parsed, extra: [ProtoItem]) -> ProtoCache {
    var byKey: [String: ProtoItem] = [:]
    var order: [String] = []
    func key(_ url: String) -> String {
      url.hasSuffix("index.html") ? String(url.dropLast("index.html".count)) : url
    }
    for it in home.items where byKey[key(it.url)] == nil {
      byKey[key(it.url)] = it
      order.append(key(it.url))
    }
    for it in extra {
      let k = key(it.url)
      if var old = byKey[k] {
        if !it.title.isEmpty { old.title = it.title }
        if !it.desc.isEmpty { old.desc = it.desc }
        if it.updated > old.updated { old.updated = it.updated }
        byKey[k] = old
      } else {
        byKey[k] = it
        order.append(k)
      }
    }
    return ProtoCache(fetchedAt: Date(), sections: home.sections, items: order.compactMap { byKey[$0] })
  }

  static func parse(_ html: String) -> Parsed {
    var sections: [String] = []
    var links: [SectionLink] = []
    var items: [ProtoItem] = []
    for body in matches(html, #"<section class="group">([\s\S]*?)</section>"#, group: 1) {
      let section = first(body, #"<h2>([\s\S]*?)</h2>"#, group: 1).map(text) ?? ""
      let got = parseItems(body, section: section)
      items.append(contentsOf: got)
      if !section.isEmpty && !got.isEmpty {
        sections.append(section)
        if let href = first(body, #"class="to-section" href="([^"]+)""#, group: 1), href.hasPrefix("/") {
          links.append(SectionLink(section: section, href: href))
        }
      }
    }
    return Parsed(sections: sections, links: links, items: items)
  }

  /// 抽 <a class="item">：标题在 h3（首页）或 h2（分区页）里，去掉 <span class="upd">
  static func parseItems(_ html: String, section: String) -> [ProtoItem] {
    var out: [ProtoItem] = []
    guard let re = try? NSRegularExpression(pattern: #"<a class="item"([^>]*)>([\s\S]*?)</a>"#) else { return out }
    let ns = html as NSString
    for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      let attrs = ns.substring(with: m.range(at: 1))
      let inner = ns.substring(with: m.range(at: 2))
      guard let href = first(attrs, #"href="([^"]+)""#, group: 1), href != "/" else { continue }
      let updated = first(attrs, #"data-updated="([^"]*)""#, group: 1) ?? ""
      var title = ""
      if let h = first(inner, #"<h[23]>([\s\S]*?)</h[23]>"#, group: 1) {
        title = text(h.replacingOccurrences(of: #"<span class="upd">[^<]*</span>"#,
                                            with: "", options: .regularExpression))
      }
      if title.isEmpty { title = href }
      let desc = first(inner, #"<p>([\s\S]*?)</p>"#, group: 1).map(text) ?? ""
      out.append(ProtoItem(section: section,
                           url: href.hasPrefix("http") ? href : kProtoOrigin + href,
                           title: title, desc: desc, updated: updated))
    }
    return out
  }

  // MARK: 正则小工具

  private static func matches(_ s: String, _ pattern: String, group: Int) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
      ns.substring(with: $0.range(at: group))
    }
  }

  private static func first(_ s: String, _ pattern: String, group: Int) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: m.range(at: group))
  }

  private static func text(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                   ("&#39;", "'"), ("&nbsp;", " ")] {
      t = t.replacingOccurrences(of: a, with: b)
    }
    return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
