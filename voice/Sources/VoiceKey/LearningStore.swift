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
        seedPresetTermsIfEmpty()
        if !FileManager.default.fileExists(atPath: fileURL.path) { save() }  // 立即落一个文件，删 app 也在
    }

    // MARK: 读写

    /// terms 变更后统一走这里：落盘 + 防抖推三端同步文件（TermSync 自己判断采纳中不回推）。
    /// history/corrections 变更不推——它们是端私有上下文，同步只会互相覆盖丢数据。
    private func saveAndSyncTerms() {
        save()
        TermSync.shared.schedulePush()
    }

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

    // MARK: 词表（只学不改）

    // 2026-10-06：手工增删改的入口按 iOS #22 的口径删掉了（设置页「我的词表」现在只显示
    // 计数）。**学习 / 替换 / 喂识别器 / 三端同步这几条链路一个字没动** —— 下面留着的
    // `mineTerms` / `applyTerms` / `contextualStrings` / `allTermPairs` 就是全部活口，
    // 别再往这里加「设置页改词表」那种 API。

    struct TermPair: Identifiable {
        let id = UUID()
        let wrong: String
        let right: String
        let count: Int
    }

    /// 词表按「次数降序、错词升序」输出（UI 与替换/喂识别器都用这一个顺序）。
    func allTermPairs() -> [TermPair] {
        q.sync {
            termsRaw().map { TermPair(wrong: $0.0, right: $0.1, count: $0.2) }
        }
    }

    private func termsRaw() -> [(String, String, Int)] {
        var out: [(String, String, Int)] = []
        for (wrong, m) in payload.terms {
            for (right, n) in m { out.append((wrong, right, n)) }
        }
        return out.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
    }

    /// 转写后本地直接替换（不依赖 GLM，离线也纠错）。按错词长度降序替换，避免短词先换
    /// 破坏长词；命中的对把次数 +1（「生效次数」就是这张表在干活的证据）。
    func applyTerms(to text: String) -> String {
        let pairs = allTermPairs()
        guard !pairs.isEmpty else { return text }
        var out = text
        var hits: [(String, String)] = []
        for p in pairs.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            if out.range(of: p.wrong, options: .caseInsensitive) != nil {
                out = out.replacingOccurrences(of: p.wrong, with: p.right, options: .caseInsensitive)
                hits.append((p.wrong, p.right))
            }
        }
        guard !hits.isEmpty else { return out }
        q.sync {
            for (w, r) in hits { payload.terms[w, default: [:]][r, default: 0] += 1 }
            saveAndSyncTerms()
        }
        let detail = hits.map { "\($0.0)→\($0.1)" }.joined(separator: "、")
        Diag.log("词表本地替换 \(hits.count) 处：\(detail)")
        return out
    }

    /// 喂给系统识别器的提示词（SFSpeechRecognizer contextualStrings）：词表里错/对两侧
    /// 全部去重。识别器只拿它做偏置不硬替换，所以「cloud→claude」这类正常词也敢放进来。
    func contextualStrings() -> [String] {
        let pairs = allTermPairs()
        var seen = Set<String>()
        var out: [String] = []
        for p in pairs {
            for s in [p.wrong, p.right] where !seen.contains(s) {
                seen.insert(s); out.append(s)
            }
        }
        return out
    }

    /// 采纳三端同步文件里的词表（TermSync 拉到远端值时调）：LWW 整字段覆盖，非空才收。
    /// 这里用裸 save() 不回推——推送方写的这份就是源头，回推只会翻 origin 打乒乓。
    func adoptTerms(_ raw: [String: Any]) {
        q.sync {
            guard let data = try? JSONSerialization.data(withJSONObject: raw),
                  let typed = try? JSONDecoder().decode([String: [String: Int]].self, from: data),
                  !typed.isEmpty, typed != payload.terms else { return }
            payload.terms = typed
            save()
        }
    }

    /// 首次启动把核心预置词 seed 进词表（只在 terms 为空时，不覆盖用户已积累/已删除的）。
    /// 只收「错写不可能是用户本意」的对（GTO→cto、大夫→binsoft-dev、week→wiki 这类
    /// 正常词不进来——本地替换是无脑子串替换，正常词会被误伤；它们留在 GLM 的
    /// userGlossary 里靠语义判断）。
    private static let presetTerms: [(String, String)] = [
        ("蒸鸡", "真机"), ("糖床", "弹窗"), ("棒糖窗", "弹窗"), ("堂装", "弹窗"),
        ("红福", "横幅"), ("主分词", "主分支"), ("冰社", "binsoft"),
        ("金汤", "均摊"), ("的编辑", "边距"),
        ("卡了带", "claude"), ("卡老的", "claude"), ("皮阿", "PR"), ("皮啊", "PR"),
        ("给客密", "commit"), ("给默记", "merge"), ("tailsquare", "tailscale"),
    ]

    private func seedPresetTermsIfEmpty() {
        q.sync {
            guard payload.terms.isEmpty else { return }
            for (w, r) in Self.presetTerms { payload.terms[w, default: [:]][r] = 0 }
            saveAndSyncTerms()   // 首次 seed 顺手推上三端同步文件，手机/鸿蒙直接拿到预置词
            Diag.log("预置词表已 seed：\(Self.presetTerms.count) 对")
        }
    }

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
