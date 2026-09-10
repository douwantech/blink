import Foundation

/// 对话记录（transcript）本地缓存 —— 同手机 TranscriptStore：每个会话存
/// {jsonl 文件名, 已读到的行数(游标), 累积的 (role,text) 对}，持久到 UserDefaults，重启保留。
/// 下次点「历史」先秒显缓存，再只拉游标之后的新行增量追加，不每次整拉。
struct TranscriptPair: Codable {
    let r: String   // "you" / "claude"
    let t: String
}

struct TranscriptCache: Codable {
    var file: String        // jsonl basename（换文件→整拉）
    var lines: Int          // 已读到的行数（下次从 lines+1 开始）
    var pairs: [TranscriptPair]
}

enum MacTranscriptStore {
    private static func key(_ id: String) -> String { "BlinkMac.transcript." + id }

    static func load(_ id: String) -> TranscriptCache? {
        guard let d = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(TranscriptCache.self, from: d)
    }

    static func save(_ id: String, _ c: TranscriptCache) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        UserDefaults.standard.set(d, forKey: key(id))
    }
}
