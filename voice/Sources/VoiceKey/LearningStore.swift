import Foundation

/// VoiceKey 自己的语音学习数据（历史输入 / 整句修正记录 / 高频错词表），持久化到
/// ~/Library/Application Support/VoiceKey/learning.json —— 删 app 只删 .app 包，这个
/// 用户数据目录留着，重装后自动读回，不会丢。
final class LearningStore {
    static let shared = LearningStore()

    struct Payload: Codable {
        var history: [String] = []          // 近期已提交输入（从旧到新）
        var corrections: [[String]] = []    // [[asrRaw, final]] 整句修正
        var terms: [String: [String: Int]] = [:]   // 错→{对: 次数} 词级映射
    }

    private let fileURL: URL
    private var payload = Payload()
    private let q = DispatchQueue(label: "voicekey.learning")
    private let maxHistory = 40
    private let maxCorrections = 40

    var storePath: String { fileURL.path }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("learning.json")
        load()
        migrateLegacyIfNeeded()
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }  // 立即落一个文件，删 app 也在
    }

    // MARK: 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        payload = p
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 一次性把旧的 UserDefaults 历史迁移进来（早期版本存那里的），迁完标记。
    private func migrateLegacyIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "VoiceKey.learningMigrated.v1") else { return }
        if let old = d.stringArray(forKey: "VoiceKey.aiHistory"), !old.isEmpty {
            for t in old { appendHistoryInternal(t) }
            save()
        }
        d.set(true, forKey: "VoiceKey.learningMigrated.v1")
    }

    // MARK: 历史

    func addHistory(_ text: String) {
        q.sync {
            appendHistoryInternal(text)
            save()
        }
    }

    private func appendHistoryInternal(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        payload.history.removeAll { $0 == t }
        payload.history.append(t)
        if payload.history.count > maxHistory {
            payload.history.removeFirst(payload.history.count - maxHistory)
        }
    }

    var history: [String] { q.sync { payload.history } }

    // MARK: 修正记录 + 词表（供未来「编辑后提交」学习用；也可外部 seed）

    /// 记录一次整句修正（ASR 原文 → 用户改后），并从词级差异挖高频错词。
    func recordCorrection(asrRaw: String, final: String) {
        let a = asrRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !f.isEmpty, a != f else { return }
        q.sync {
            payload.corrections.removeAll { $0.count == 2 && $0[0] == a && $0[1] == f }
            payload.corrections.append([a, f])
            if payload.corrections.count > maxCorrections {
                payload.corrections.removeFirst(payload.corrections.count - maxCorrections)
            }
            mineTerms(asr: a, final: f)
            save()
        }
    }

    /// 极简词级挖矿：两句按空白/标点切词，等长时逐词比对，不同的成对计数。
    private func mineTerms(asr: String, final: String) {
        let sep = CharacterSet(charactersIn: " ，。、,.\n\t；;：:！!？?")
        let aw = asr.components(separatedBy: sep).filter { !$0.isEmpty }
        let fw = final.components(separatedBy: sep).filter { !$0.isEmpty }
        guard aw.count == fw.count else { return }
        for (w, c) in zip(aw, fw) where w != c && w.lowercased() != c.lowercased() {
            payload.terms[w, default: [:]][c, default: 0] += 1
        }
    }

    var corrections: [[String]] { q.sync { payload.corrections } }
    var terms: [String: [String: Int]] { q.sync { payload.terms } }

    /// 外部一次性导入（比如从别处拿到的历史/修正），只在当前为空时填，不覆盖用户已积累的。
    func seedIfEmpty(history: [String], corrections: [[String]], terms: [String: [String: Int]]) {
        q.sync {
            if payload.history.isEmpty { payload.history = Array(history.suffix(maxHistory)) }
            if payload.corrections.isEmpty { payload.corrections = Array(corrections.suffix(maxCorrections)) }
            if payload.terms.isEmpty { payload.terms = terms }
            save()
        }
    }
}
