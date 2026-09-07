import Foundation

/// 从 iCloud KV 读手机同步过来的机器清单。
///
/// iOS Blink 的 `CloudConfigSync` 早就把整份 `BlinkMachineStore.machines`（JSON 编码的 Data，
/// 含每台机器的 `blinkdHost / blinkdPort / blinkdToken`）镜像进共享 iCloud KV。正式版 BlinkMac
/// 用 team 通配 KV entitlement（`659T9VUN97.*`）认领同一份 KV，直接读出全部机器 —— 于是
/// 「其它机器」也能在 Mac 上列出来，不用改 iOS。
///
/// dev 版（SPM/无 entitlement）读 KV 是空的 → `machines()` 返回 []，调用方回退本地单机。
struct MacMachine {
    let id: String
    let name: String
    let host: String
    let blinkdHost: String?
    let blinkdPort: Int?
    let blinkdToken: String?

    /// 可用的 blinkd 连接信息（host + token 都非空才算；没有的机器多半是走 SSH 的，Mac 端连不了）。
    var blinkd: (host: String, port: UInt16, token: String)? {
        guard let h = blinkdHost, !h.isEmpty, let t = blinkdToken, !t.isEmpty else { return nil }
        return (h, UInt16(clamping: blinkdPort ?? 7777), t)
    }
}

enum MacMachineStore {
    static let kvKey = "BlinkMachineStore.machines"

    /// 读 KV 里的机器清单。iOS 侧存的是 JSON 编码的 Data（`BlinkMachine` 数组），CloudConfigSync 原样搬过来。
    static func machines() -> [MacMachine] {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        // 主要是 Data；容错也接 String（万一某端存成字符串）。
        let data: Data? = kv.data(forKey: kvKey) ?? kv.string(forKey: kvKey)?.data(using: .utf8)
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let name = (m["name"] as? String) ?? ""
            let host = (m["host"] as? String) ?? ""
            return MacMachine(id: id,
                              name: name.isEmpty ? host : name,
                              host: host,
                              blinkdHost: m["blinkdHost"] as? String,
                              blinkdPort: m["blinkdPort"] as? Int,
                              blinkdToken: m["blinkdToken"] as? String)
        }
    }
}
