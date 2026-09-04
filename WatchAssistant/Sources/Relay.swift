import Foundation

// 腕上助手的后端地址/令牌。可在表上「设置」里改，默认走编译进来的值。
enum RelayConfig {
  // 公网入口：Tailscale Funnel（Mac 直服，不经阿里云）
  static let candidates = [
    "https://qinjunbins-macbook-pro.tail02fd9d.ts.net:8443",
  ]
  static let defaultToken = "w7Kq2mZ9xVbLp0"

  // 已探明可用的入口（探到后缓存，避免每次都试）
  static var base: String? {
    get { UserDefaults.standard.string(forKey: "relay_base") }
    set { UserDefaults.standard.set(newValue, forKey: "relay_base") }
  }
  static var token: String {
    get { UserDefaults.standard.string(forKey: "relay_token") ?? defaultToken }
    set { UserDefaults.standard.set(newValue, forKey: "relay_token") }
  }

  // 依次探 candidates，返回第一个 /health 通的
  static func resolveBase() async -> String? {
    if let b = base, await ping(b) { return b }
    for c in candidates where await ping(c) {
      base = c
      return c
    }
    base = nil
    return nil
  }

  static var lastErr = ""

  private static func ping(_ b: String) async -> Bool {
    guard let url = URL(string: b + "/health") else { return false }
    var req = URLRequest(url: url); req.timeoutInterval = 6
    do {
      let (_, resp) = try await URLSession.shared.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      if code == 200 { return true }
      lastErr = "HTTP \(code) @\(b.suffix(12))"
      return false
    } catch {
      lastErr = "\((error as NSError).code) \((error as NSError).localizedDescription) @\(b.suffix(12))"
      return false
    }
  }
}

// 后端队列里的一条(与 mac-daemon/watchrelay 的 JSON 对应)。
struct RelayItem: Codable {
  let id: String
  let emp: String
  let proj: String
  let branch: String
  let head: String
  let body: String
  let speak: String
  let chips: [String]
  let urgent: Bool
  let ts: Int64
}

enum Relay {
  private struct QueueResp: Codable { let items: [RelayItem] }

  static func fetch() async -> [RelayItem]? {
    guard let b = await RelayConfig.resolveBase() else { return nil }
    guard var c = URLComponents(string: b + "/queue") else { return nil }
    c.queryItems = [URLQueryItem(name: "token", value: RelayConfig.token)]
    guard let url = c.url else { return nil }
    do {
      var req = URLRequest(url: url)
      req.timeoutInterval = 8
      let (d, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
      return try JSONDecoder().decode(QueueResp.self, from: d).items
    } catch {
      return nil
    }
  }

  static func reply(id: String, text: String) async -> Bool {
    var b = RelayConfig.base
    if b == nil { b = await RelayConfig.resolveBase() }
    guard let base = b else { return false }
    guard let url = URL(string: base + "/reply?token=" + RelayConfig.token) else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 8
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "text": text])
    do {
      let (_, resp) = try await URLSession.shared.data(for: req)
      return (resp as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }
}
