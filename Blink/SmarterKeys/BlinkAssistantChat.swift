//
// BlinkAssistantChat.swift
// AI 助手聊天页（chat-bubble UI），底层后续接 cc --print over ssh
//
// 当前后端是 stub：发送的消息回声成"[占位]..."；UI 跑通后再补真实 SSH 链路。
//

import UIKit
import Combine
import AVFoundation
import SSH
import BlinkConfig
import BlinkFiles

// MARK: - Model

struct BlinkAssistantMessage {
  enum Role { case user, assistant, system }
  /// 当前 turn 里 assistant 气泡的角色：.intermediate 思考中 / .final 总结结句
  enum TurnRole { case none, intermediate, final }
  let role: Role
  var text: String
  var isLoading: Bool = false  // assistant typing 占位
  var turnRole: TurnRole = .none
  var decision: BlinkAssistantDecision? = nil
  var pending: BlinkAssistantPending? = nil
  var patrol: BlinkAssistantPatrol? = nil
}

/// 巡检报告：按状态分 3 段（🙋 等待中 / ⏳ 干活中 / 💤 没在干活）
struct BlinkAssistantPatrol: Codable, Hashable {
  enum Status: String, Codable {
    case waiting, working, idle
    var emoji: String { self == .waiting ? "🙋" : self == .working ? "⏳" : "💤" }
    var title: String { self == .waiting ? "等待中" : self == .working ? "干活中" : "没在干活" }
  }
  struct Project: Codable, Hashable {
    let name: String                // 项目名（talkai / printer / lottie / 基础设施 / xiaobai 等）
    let desc: String                // 当前在做什么 / 等谁，一行
    var waitingFor: String? = nil   // 等待中专用：等谁（user / candy / tom / 外部事件名）
  }
  struct Item: Codable, Hashable {
    let employee: String            // 员工名（tom / dave / candy / alice / ...）
    var role: String? = nil         // CTO / 产品 / iOS / 后端 / 运营 / 前端 / 基建 ...
    let projects: [Project]         // 同一员工的多个 tab / 项目
  }
  struct Segment: Codable, Hashable {
    let status: Status
    let items: [Item]
  }
  var title: String? = nil          // 巡检标题，比如 "团队巡检 · 06-25"
  let segments: [Segment]
}

enum AssistantPatrolParser {
  static func extract(from raw: String) -> (cleanText: String, patrol: BlinkAssistantPatrol?) {
    let nsRaw = raw as NSString
    let startMarker = "<<<PATROL>>>"
    let endMarker = "<<<END_PATROL>>>"
    let startRange = nsRaw.range(of: startMarker)
    guard startRange.location != NSNotFound else { return (raw, nil) }
    let afterStart = NSRange(location: startRange.location + startRange.length,
                             length: nsRaw.length - startRange.location - startRange.length)
    let endRel = nsRaw.range(of: endMarker, options: [], range: afterStart)
    guard endRel.location != NSNotFound else { return (raw, nil) }
    var jsonText = nsRaw.substring(with: NSRange(location: afterStart.location,
                                                  length: endRel.location - afterStart.location))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonText.hasPrefix("```") {
      if let nl = jsonText.firstIndex(of: "\n") {
        jsonText = String(jsonText[jsonText.index(after: nl)...])
      }
      if jsonText.hasSuffix("```") { jsonText = String(jsonText.dropLast(3)) }
      jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = jsonText.data(using: .utf8),
          let patrol = try? JSONDecoder().decode(BlinkAssistantPatrol.self, from: data) else {
      return (raw, nil)
    }
    let prefix = nsRaw.substring(with: NSRange(location: 0, length: startRange.location))
    let suffixStart = endRel.location + endRel.length
    let suffix = nsRaw.substring(with: NSRange(location: suffixStart, length: nsRaw.length - suffixStart))
    let combined = (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    return (combined, patrol)
  }
}

/// 助手"全量待处理"列表的可点回复
struct BlinkAssistantPending: Codable, Hashable {
  struct Item: Codable, Hashable {
    let target: String          // tab customTitle，比如 "tom-xiaobai"
    var machine: String?        // 机器名，nil 默认本机
    let title: String           // 一行待处理摘要
    var context: String?        // 可选补充上下文
    var suggestedReply: String? // 助手给的建议回复（用户可以一键发或改完发）
  }
  let items: [Item]
}

/// 助手用 <<<DECISION>>>{json}<<<END_DECISION>>> 标记的决策请求
struct BlinkAssistantDecision: Codable, Hashable {
  let question: String
  var context: String?
  /// 这个决策是为谁拍板：tab customTitle（不带 cc- 前缀），比如 "candy-printer"
  var target: String?
  /// 目标员工所在的机器名（"Mac" / "xiaobai" 等），nil 默认本机
  var machine: String?
  let options: [DecisionOption]
  struct DecisionOption: Codable, Hashable {
    let key: String
    let label: String
    var isAlways: Bool? = nil  // 选这个 → 让助手把规则写到 ~/.blink/permissions.md
  }

  /// 决策头展示："候 candy-printer · xiaobai" / "候 jack-talkai"
  var headerText: String? {
    guard let t = target, !t.isEmpty else { return nil }
    if let m = machine, !m.isEmpty {
      return "\(t) · \(m)"
    }
    return t
  }
}

extension BlinkAssistantMessage {
  /// 从 raw 文本构造 assistant 气泡，自动抽取 DECISION / PENDING / PATROL 块
  static func assistant(text: String, turnRole: TurnRole = .none) -> BlinkAssistantMessage {
    let (t1, decision) = AssistantDecisionParser.extract(from: text)
    let (t2, pending) = AssistantPendingParser.extract(from: t1)
    let (clean, patrol) = AssistantPatrolParser.extract(from: t2)
    return BlinkAssistantMessage(role: .assistant, text: clean, turnRole: turnRole,
                                  decision: decision, pending: pending, patrol: patrol)
  }
}

enum AssistantPendingParser {
  static func extract(from raw: String) -> (cleanText: String, pending: BlinkAssistantPending?) {
    let nsRaw = raw as NSString
    let startMarker = "<<<PENDING>>>"
    let endMarker = "<<<END_PENDING>>>"
    let startRange = nsRaw.range(of: startMarker)
    guard startRange.location != NSNotFound else { return (raw, nil) }
    let afterStart = NSRange(location: startRange.location + startRange.length,
                             length: nsRaw.length - startRange.location - startRange.length)
    let endRel = nsRaw.range(of: endMarker, options: [], range: afterStart)
    guard endRel.location != NSNotFound else { return (raw, nil) }
    var jsonText = nsRaw.substring(with: NSRange(location: afterStart.location,
                                                  length: endRel.location - afterStart.location))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonText.hasPrefix("```") {
      if let nl = jsonText.firstIndex(of: "\n") {
        jsonText = String(jsonText[jsonText.index(after: nl)...])
      }
      if jsonText.hasSuffix("```") { jsonText = String(jsonText.dropLast(3)) }
      jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = jsonText.data(using: .utf8),
          let pending = try? JSONDecoder().decode(BlinkAssistantPending.self, from: data) else {
      return (raw, nil)
    }
    let prefix = nsRaw.substring(with: NSRange(location: 0, length: startRange.location))
    let suffixStart = endRel.location + endRel.length
    let suffix = nsRaw.substring(with: NSRange(location: suffixStart, length: nsRaw.length - suffixStart))
    let combined = (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    return (combined, pending)
  }
}

enum AssistantDecisionParser {
  /// 从 raw assistant 文本里抽出 DECISION JSON；返回（去掉标记后的剩余文本, 决策）
  static func extract(from raw: String) -> (cleanText: String, decision: BlinkAssistantDecision?) {
    let nsRaw = raw as NSString
    let startMarker = "<<<DECISION>>>"
    let endMarker = "<<<END_DECISION>>>"
    let startRange = nsRaw.range(of: startMarker)
    guard startRange.location != NSNotFound else { return (raw, nil) }
    let afterStart = NSRange(location: startRange.location + startRange.length,
                             length: nsRaw.length - startRange.location - startRange.length)
    let endRel = nsRaw.range(of: endMarker, options: [], range: afterStart)
    guard endRel.location != NSNotFound else { return (raw, nil) }
    var jsonText = nsRaw.substring(with: NSRange(location: afterStart.location,
                                                  length: endRel.location - afterStart.location))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonText.hasPrefix("```") {
      if let nl = jsonText.firstIndex(of: "\n") {
        jsonText = String(jsonText[jsonText.index(after: nl)...])
      }
      if jsonText.hasSuffix("```") { jsonText = String(jsonText.dropLast(3)) }
      jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = jsonText.data(using: .utf8),
          let decision = try? JSONDecoder().decode(BlinkAssistantDecision.self, from: data) else {
      return (raw, nil)
    }
    let prefix = nsRaw.substring(with: NSRange(location: 0, length: startRange.location))
    let suffixStart = endRel.location + endRel.length
    let suffix = nsRaw.substring(with: NSRange(location: suffixStart, length: nsRaw.length - suffixStart))
    let combined = (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    return (combined, decision)
  }
}

enum BlinkAssistantError: LocalizedError {
  case noMachine
  case configFailed(String)
  case execFailed(String)
  var errorDescription: String? {
    switch self {
    case .noMachine: return "没配 machine（先去设置加一台）"
    case .configFailed(let s): return "SSH 配置失败：\(s)"
    case .execFailed(let s): return s
    }
  }
}

// MARK: - 简易 Markdown 渲染（block 自己拆，inline 走 AttributedString(markdown:)）

enum AssistantMarkdown {
  /// 把 markdown 文本渲染成 NSAttributedString，cell label 直接吃
  static func render(_ text: String, baseFont: UIFont = .systemFont(ofSize: 15), textColor: UIColor = .label) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let lines = text.components(separatedBy: "\n")
    var i = 0
    let codeFont = UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1.5, weight: .regular)

    while i < lines.count {
      let line = lines[i]

      // 表格：第二行是 |---|---| 这种分隔时按表格渲染（手机窄屏改成"每行竖排展开"）
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("|") && trimmed.contains("|") {
        var tableLines = [trimmed]
        var j = i + 1
        while j < lines.count {
          let n = lines[j].trimmingCharacters(in: .whitespaces)
          if !n.hasPrefix("|") { break }
          tableLines.append(n)
          j += 1
        }
        let hasSeparator = tableLines.count >= 2 &&
          tableLines[1].replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "|", with: "")
            .isEmpty
        if hasSeparator {
          let headers = Self.parseTableRow(tableLines[0])
          let bodyRows = tableLines.dropFirst(2).map { Self.parseTableRow($0) }
          let headerFont = UIFont.systemFont(ofSize: baseFont.pointSize - 1, weight: .semibold)
          let rowSepPara = NSMutableParagraphStyle()
          rowSepPara.paragraphSpacing = 6
          for (idx, row) in bodyRows.enumerated() {
            if idx > 0 {
              // 行间留个空行作为分隔
              out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .paragraphStyle: rowSepPara]))
            }
            for (k, h) in headers.enumerated() {
              let value = k < row.count ? row[k] : ""
              let hClean = h.trimmingCharacters(in: .whitespaces)
              let vClean = value.trimmingCharacters(in: .whitespaces)
              if hClean.isEmpty && vClean.isEmpty { continue }
              let rowAttr = NSMutableAttributedString()
              if !hClean.isEmpty {
                rowAttr.append(NSAttributedString(string: hClean + "  ", attributes: [
                  .font: headerFont,
                  .foregroundColor: textColor.withAlphaComponent(0.55),
                ]))
              }
              rowAttr.append(inline(vClean, font: baseFont, color: textColor))
              rowAttr.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
              out.append(rowAttr)
            }
          }
          i = j
          continue
        }
      }

      // ``` code block ```
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        i += 1
        var collected: [String] = []
        while i < lines.count {
          if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
          collected.append(lines[i])
          i += 1
        }
        i += 1  // 跳过闭合 ```
        let body = collected.joined(separator: "\n")
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 6
        para.firstLineHeadIndent = 6
        para.headIndent = 6
        para.tailIndent = -6
        out.append(NSAttributedString(string: body + (collected.isEmpty ? "" : "\n"), attributes: [
          .font: codeFont,
          .foregroundColor: textColor.withAlphaComponent(0.9),
          .backgroundColor: UIColor.tertiarySystemFill,
          .paragraphStyle: para,
        ]))
        continue
      }

      // 标题
      if line.hasPrefix("### ") {
        out.append(inline(String(line.dropFirst(4)), font: .systemFont(ofSize: baseFont.pointSize + 1, weight: .semibold), color: textColor))
      } else if line.hasPrefix("## ") {
        out.append(inline(String(line.dropFirst(3)), font: .systemFont(ofSize: baseFont.pointSize + 3, weight: .semibold), color: textColor))
      } else if line.hasPrefix("# ") {
        out.append(inline(String(line.dropFirst(2)), font: .systemFont(ofSize: baseFont.pointSize + 5, weight: .bold), color: textColor))
      }
      // 引用
      else if line.hasPrefix("> ") {
        let q = NSMutableAttributedString(string: "│ ", attributes: [
          .font: baseFont,
          .foregroundColor: UIColor.systemGray,
        ])
        q.append(inline(String(line.dropFirst(2)), font: baseFont, color: .secondaryLabel))
        out.append(q)
      }
      // 项目符号
      else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        let b = NSMutableAttributedString(string: "•  ", attributes: [
          .font: baseFont,
          .foregroundColor: textColor.withAlphaComponent(0.7),
        ])
        b.append(inline(String(line.dropFirst(2)), font: baseFont, color: textColor))
        out.append(b)
      }
      // 数字列表 1.
      else if let m = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
        let prefix = String(line[m])
        let rest = String(line[m.upperBound...])
        let n = NSMutableAttributedString(string: prefix, attributes: [
          .font: baseFont,
          .foregroundColor: textColor.withAlphaComponent(0.7),
        ])
        n.append(inline(rest, font: baseFont, color: textColor))
        out.append(n)
      }
      // 分隔线
      else if line.trimmingCharacters(in: .whitespaces) == "---" || line.trimmingCharacters(in: .whitespaces) == "***" {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 4
        out.append(NSAttributedString(string: "─────────────", attributes: [
          .font: baseFont,
          .foregroundColor: UIColor.separator,
          .paragraphStyle: para,
        ]))
      }
      // 普通段落
      else if line.isEmpty {
        // 留个空行
      } else {
        out.append(inline(line, font: baseFont, color: textColor))
      }

      // 行末换行（最后一行不补）
      if i < lines.count - 1 || lines.count == 1 {
        out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
      }
      i += 1
    }
    return out
  }

  /// 拆 `| a | b | c |` 这种 markdown 表格行成 ["a", "b", "c"]
  private static func parseTableRow(_ row: String) -> [String] {
    var s = row.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s = String(s.dropFirst()) }
    if s.hasSuffix("|") { s = String(s.dropLast()) }
    return s.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
  }

  /// 走系统 AttributedString(markdown:) 解析 inline（**bold** / *italic* / `code` / [link](url)）
  /// 再把字号/颜色 fold 到我们 baseFont/textColor 上。
  private static func inline(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
    var opts = AttributedString.MarkdownParsingOptions()
    opts.interpretedSyntax = .inlineOnly
    guard let parsed = try? AttributedString(markdown: text, options: opts) else {
      return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
    let m = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let full = NSRange(location: 0, length: m.length)
    // 颜色统一塞底色（链接走 .link 属性的我们再覆盖成蓝）
    m.addAttribute(.foregroundColor, value: color, range: full)
    // 字号 fold：先全量赋值 baseFont，再把已有 traits 重新派生到 baseFont 上
    m.enumerateAttribute(.font, in: full) { val, range, _ in
      if let f = val as? UIFont {
        let traits = f.fontDescriptor.symbolicTraits
        if traits.contains(.traitMonoSpace) {
          m.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: range)
          m.addAttribute(.backgroundColor, value: UIColor.tertiarySystemFill, range: range)
          m.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.92), range: range)
        } else if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
          m.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
        } else {
          m.addAttribute(.font, value: font, range: range)
        }
      } else {
        m.addAttribute(.font, value: font, range: range)
      }
    }
    // 链接重新涂蓝
    m.enumerateAttribute(.link, in: full) { val, range, _ in
      if val != nil {
        m.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
      }
    }
    return m
  }
}

// MARK: - 按行流式 Writer（BlinkFiles.Writer 协议）

final class LineStreamWriter: BlinkFiles.Writer {
  private let onLine: (String) -> Void
  private var buffer = Data()
  private let lock = NSLock()

  init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

  func write(_ buf: DispatchData, max length: Int) -> AnyPublisher<Int, Error> {
    var chunk = Data()
    buf.enumerateBytes { region, _, _ in chunk.append(contentsOf: region) }
    let length = chunk.count
    lock.lock()
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 0x0a) {
      let lineData = buffer[buffer.startIndex..<nl]
      let line = String(data: lineData, encoding: .utf8) ?? ""
      buffer.removeSubrange(buffer.startIndex...nl)
      lock.unlock()
      onLine(line)
      lock.lock()
    }
    lock.unlock()
    return Just(length).setFailureType(to: Error.self).eraseToAnyPublisher()
  }

  /// Stream 结束时把还没换行的尾部当一行 flush 出去
  func flush() {
    lock.lock()
    let remain = buffer
    buffer = Data()
    lock.unlock()
    if !remain.isEmpty, let line = String(data: remain, encoding: .utf8), !line.isEmpty {
      onLine(line)
    }
  }
}

// MARK: - 真后端：ssh exec → cc --print

final class BlinkAssistantBackend {
  static let shared = BlinkAssistantBackend()

  /// 每个进行中的 ssh 任务持一份 cancellable，sink 结束时清掉
  private var liveBags: [ObjectIdentifier: AnyCancellable] = [:]
  private let bagsLock = NSLock()

  /// 远端项目目录，跟 sshCommand 里的 workDir / customTitle 保持一致
  private let remoteProjectDir = "$HOME/.claude/projects/-Users-apple-blink-assistant"
  private let remoteWorkDir = "~/blink-assistant"

  /// 流式事件
  enum StreamEvent {
    case text(String)   // 一条 assistant 文本（中间过程或最终回复）
    case done           // 一轮结束（turn_duration）
    case error(String)  // 远端报错
  }

  /// 流式发送：每收到一条新 assistant 文本就立刻 onEvent(.text)，turn 结束发 .done
  func sendStreaming(_ text: String, onEvent: @escaping (StreamEvent) -> Void) async throws {
    let msgB64 = Data(text.utf8).base64EncodedString()
    let script = """
    export PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH
    CLAUDE_BIN="$(command -v claude || echo $HOME/.local/bin/claude)"
    TMUX_SOCK=/private/tmp/tmux-$(id -u)/default
    TMUX="tmux -S $TMUX_SOCK"
    SESS=cc-blink-assistant
    PROJ=\(remoteProjectDir)
    MSG=$(echo \(msgB64) | base64 -d)

    [ -x "$CLAUDE_BIN" ] || { echo "[ERR] claude 不在远端 PATH"; exit 1; }
    [ -S "$TMUX_SOCK" ] || { echo "[ERR] 找不到 launchd tmux socket"; exit 1; }

    # 1) 确保 session 存在
    if ! $TMUX has-session -t "$SESS" 2>/dev/null; then
      mkdir -p \(remoteWorkDir) 2>/dev/null
      $TMUX new-session -d -s "$SESS" "/bin/zsh -ic 'cd \(remoteWorkDir) && claude'"
      for i in $(seq 1 60); do
        [ -d "$PROJ" ] && [ -n "$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)" ] && break
        sleep 0.5
      done
    fi

    # 2) 记录初始游标
    LATEST=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
    [ -n "$LATEST" ] || { echo "[ERR] claude 启动了但 jsonl 没出现"; exit 1; }
    N0=$(wc -l < "$LATEST" | tr -d ' ')
    INIT_TURNS=$(grep -c '"subtype":"turn_duration"' "$LATEST" 2>/dev/null || echo 0)

    # 3) 注入消息（不要 -p，避免 bracketed paste 吃掉 Enter）
    BUF=$(mktemp)
    printf '%s' "$MSG" > "$BUF"
    $TMUX load-buffer -b ai_in "$BUF"
    rm -f "$BUF"
    $TMUX paste-buffer -b ai_in -t "$SESS" 2>/dev/null
    $TMUX delete-buffer -b ai_in 2>/dev/null
    sleep 1
    $TMUX send-keys -t "$SESS" Enter

    # 4) 流式轮询：每秒检查 jsonl 新增的 assistant 文本就 print "TXT:<b64>"，turn_duration 出现就 DONE
    TIMEOUT=300
    WAITED=0
    while [ $WAITED -lt $TIMEOUT ]; do
      sleep 1
      WAITED=$((WAITED+1))
      L=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
      [ -n "$L" ] || continue
      if [ "$L" != "$LATEST" ]; then
        LATEST="$L"; N0=0; INIT_TURNS=0
      fi
      N1=$(wc -l < "$L" | tr -d ' ')
      if [ "$N1" -gt "$N0" ]; then
        sed -n "$((N0+1)),${N1}p" "$L" | while IFS= read -r LINE; do
          T=$(printf '%s' "$LINE" | jq -r '.type // ""' 2>/dev/null)
          if [ "$T" = "assistant" ]; then
            TEXT=$(printf '%s' "$LINE" | jq -r '
              if (.message.content | type) == "string" then
                .message.content
              else
                [.message.content[]? | select(.type=="text") | .text] | join("\n")
              end' 2>/dev/null)
            if [ -n "$TEXT" ] && [ "$TEXT" != "null" ]; then
              # 按 <<<SUMMARY>>> 拆成思考段 / 总结段（marker 行本身丢掉），分别 emit
              if printf '%s' "$TEXT" | grep -qF '<<<SUMMARY>>>'; then
                P1=$(printf '%s\n' "$TEXT" | awk '/<<<SUMMARY>>>/{exit} {print}')
                P2=$(printf '%s\n' "$TEXT" | awk 'f{print} /<<<SUMMARY>>>/{f=1}')
                # trim 首尾空白
                P1=$(printf '%s' "$P1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                P2=$(printf '%s' "$P2" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                if [ -n "$P1" ]; then
                  B64=$(printf '%s' "$P1" | base64 | tr -d '\n')
                  printf 'TXT:%s\n' "$B64"
                fi
                if [ -n "$P2" ]; then
                  B64=$(printf '%s' "$P2" | base64 | tr -d '\n')
                  printf 'TXT:%s\n' "$B64"
                fi
              else
                B64=$(printf '%s' "$TEXT" | base64 | tr -d '\n')
                printf 'TXT:%s\n' "$B64"
              fi
            fi
          fi
        done
        N0=$N1
      fi
      NOW_TURNS=$(grep -c '"subtype":"turn_duration"' "$L" 2>/dev/null || echo 0)
      if [ "$NOW_TURNS" -gt "$INIT_TURNS" ]; then
        printf 'DONE\\n'
        exit 0
      fi
    done
    printf '[TIMEOUT] %s 秒没等到一轮结束\\n' "$TIMEOUT"
    exit 1
    """
    try await execRemoteStream(script: script) { line in
      if line.hasPrefix("TXT:") {
        let b64 = String(line.dropFirst(4))
        if let data = Data(base64Encoded: b64),
           let s = String(data: data, encoding: .utf8) {
          onEvent(.text(s))
        }
      } else if line == "DONE" {
        onEvent(.done)
      } else if line.hasPrefix("[ERR]") || line.hasPrefix("[TIMEOUT]") {
        onEvent(.error(line))
      }
    }
  }

  func send(_ text: String) async throws -> String {
    let msgB64 = Data(text.utf8).base64EncodedString()
    // 走 tmux：claude 跑在 launchd Aqua 起的 tmux server 里才能拿到 keychain 登录态。
    // ssh exec 进来 → tmux send-keys 注入消息 → 轮询 jsonl 等 end_turn。
    let script = """
    export PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH
    CLAUDE_BIN="$(command -v claude || echo $HOME/.local/bin/claude)"
    # launchd Aqua 起的 tmux server 走固定 socket /private/tmp/tmux-<uid>/default；
    # 直跑 `tmux` 默认 socket 跟 TMPDIR 走，可能落到没 keychain 的另一个 server，导致 Not logged in。
    TMUX_SOCK=/private/tmp/tmux-$(id -u)/default
    TMUX="tmux -S $TMUX_SOCK"
    SESS=cc-blink-assistant
    PROJ=\(remoteProjectDir)
    MSG=$(echo \(msgB64) | base64 -d)

    [ -x "$CLAUDE_BIN" ] || { echo "[ERR] claude 不在远端 PATH（当前 PATH=$PATH）"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "[ERR] 远端缺 jq"; exit 1; }
    command -v tmux >/dev/null 2>&1 || { echo "[ERR] 远端缺 tmux"; exit 1; }
    [ -S "$TMUX_SOCK" ] || { echo "[ERR] 找不到 launchd tmux socket $TMUX_SOCK，可能 launchd 服务没起"; exit 1; }

    # 1) 确保 tmux session 存在（让 claude REPL 常驻在 launchd Aqua 那个 server 里）
    if ! $TMUX has-session -t "$SESS" 2>/dev/null; then
      mkdir -p \(remoteWorkDir) 2>/dev/null
      # 跟用户日常 cc tab 一样走 zsh -ic 加载 zshrc（cc alias + 任何 env / keychain hook）
      $TMUX new-session -d -s "$SESS" "/bin/zsh -ic 'cd \(remoteWorkDir) && claude'"
      # 等 claude 起来：jsonl 出现就算 ready，最多 30s
      for i in $(seq 1 60); do
        if [ -d "$PROJ" ] && [ -n "$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)" ]; then break; fi
        sleep 0.5
      done
    fi

    # 2) 当前 jsonl + 初始 turn_duration 计数（一条 turn_duration system 事件 = 一轮完成）
    LATEST=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then echo "[ERR] claude 启动了但 jsonl 没出现"; exit 1; fi
    INIT_TURNS=$(grep -c '"subtype":"turn_duration"' "$LATEST" 2>/dev/null || echo 0)

    # 3) 注入消息：load-buffer 避开转义；paste-buffer -p 用 bracketed paste 保留 literal；然后回车
    BUF=$(mktemp)
    printf '%s' "$MSG" > "$BUF"
    $TMUX load-buffer -b ai_in "$BUF"
    rm -f "$BUF"
    # 不加 -p（bracketed paste），否则 cc 把 paste + Enter 整段视为粘贴，吃掉 Enter
    $TMUX paste-buffer -b ai_in -t "$SESS" 2>/dev/null
    $TMUX delete-buffer -b ai_in 2>/dev/null
    sleep 1
    $TMUX send-keys -t "$SESS" Enter

    # 4) 轮询 jsonl，等 turn_duration 数量比初始多 1 = 我们这一轮完成
    TIMEOUT=180
    WAITED=0
    while [ $WAITED -lt $TIMEOUT ]; do
      sleep 1
      WAITED=$((WAITED+1))
      L=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
      [ -n "$L" ] || continue
      if [ "$L" != "$LATEST" ]; then
        LATEST="$L"; INIT_TURNS=0
      fi
      NOW_TURNS=$(grep -c '"subtype":"turn_duration"' "$L" 2>/dev/null || echo 0)
      [ "$NOW_TURNS" -gt "$INIT_TURNS" ] || continue
      # 这一轮结束，取最后一条 assistant 的 text 部分（跳过 tool_use 等）
      tail -500 "$L" | jq -s -r '
        [.[] | select(.type=="assistant")] | .[-1] |
        if (.message.content | type) == "string" then
          .message.content
        else
          [.message.content[]? | select(.type=="text") | .text] | join("\n")
        end
      '
      exit 0
    done
    echo "[TIMEOUT] 等了 ${TIMEOUT}s 没等到一轮结束（turn_duration），可能 claude 还在跑工具"
    exit 1
    """
    let out = try await execRemote(script: script)
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "（远端没回任何输出）" : trimmed
  }

  /// 把 BlinkMachineStore 的 machines 列表推到远端 ~/.blink/machines.json，
  /// 让 cc-blink-assistant 知道有哪些 peer Mac 可以 ssh 过去扫
  func syncMachinesToRemote() async throws {
    let machines = await MainActor.run { BlinkMachineStore.shared.machines }
    let currentId = await MainActor.run { BlinkMachineStore.shared.currentMachine?.id ?? "" }
    struct Peer: Codable {
      let id: String; let name: String; let host: String
      let host2: String?; let lanHost: String?; let user: String
    }
    struct Payload: Codable { let selfId: String; let machines: [Peer] }
    let payload = Payload(
      selfId: currentId,
      machines: machines.map {
        Peer(id: $0.id, name: $0.name, host: $0.host,
             host2: $0.host2, lanHost: $0.lanHost, user: $0.user)
      }
    )
    guard let json = try? JSONEncoder().encode(payload) else { return }
    let b64 = json.base64EncodedString()
    let script = """
    mkdir -p "$HOME/.blink" 2>/dev/null
    echo \(b64) | base64 -d > "$HOME/.blink/machines.json.tmp"
    mv "$HOME/.blink/machines.json.tmp" "$HOME/.blink/machines.json"
    echo OK
    """
    _ = try await execRemote(script: script)
  }

  struct TabRef: Hashable {
    let machine: String  // 机器名（"Mac" / "xiaobai" / ...）
    let tab: String      // tmux session 去掉 cc- 前缀（"candy-talkai" 等）
  }

  /// 扫本机 + 所有 peer Mac 的 cc-* tmux session，返回 [TabRef]
  /// 排除自己（cc-blink-assistant）
  func listAllTabs() async throws -> [TabRef] {
    let script = #"""
    set -u
    SOCK=/private/tmp/tmux-$(id -u)/default
    BIN=$(command -v tmux || ls /opt/homebrew/bin/tmux /usr/local/bin/tmux 2>/dev/null | head -1)
    # 本机
    SELF_NAME=$(jq -r '.machines[] | select(.id == (input_filename | "")) | .name' < /dev/null 2>/dev/null)
    SELF_NAME=$(jq -r '.machines[] | select(.id == .selfId) | .name' "$HOME/.blink/machines.json" 2>/dev/null | head -1)
    [ -z "$SELF_NAME" ] && SELF_NAME=$(jq -r '.machines[0].name // "Mac"' "$HOME/.blink/machines.json" 2>/dev/null)
    [ -z "$SELF_NAME" ] && SELF_NAME=Mac
    "$BIN" -S "$SOCK" ls -F '#{session_name}' 2>/dev/null | grep '^cc-' | while read s; do
      t=${s#cc-}
      [ "$t" = "blink-assistant" ] && continue
      printf '%s\t%s\n' "$SELF_NAME" "$t"
    done
    # peer
    if [ -f "$HOME/.blink/machines.json" ]; then
      SELF_ID=$(jq -r '.selfId' "$HOME/.blink/machines.json")
      jq -r --arg self "$SELF_ID" '.machines[] | select(.id != $self) | "\(.name)\t\(.user)@\(.host)"' "$HOME/.blink/machines.json" | while IFS=$'\t' read name target; do
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" '
          B=$(command -v tmux || ls /opt/homebrew/bin/tmux /usr/local/bin/tmux 2>/dev/null | head -1)
          [ -x "$B" ] || exit 0
          "$B" -S /private/tmp/tmux-$(id -u)/default ls -F "#{session_name}" 2>/dev/null | grep "^cc-" | sed "s/^cc-//"
        ' 2>/dev/null | while read t; do
          [ -n "$t" ] && [ "$t" != "blink-assistant" ] && printf '%s\t%s\n' "$name" "$t"
        done
      done
    fi
    """#
    let out = try await execRemote(script: script)
    var refs: [TabRef] = []
    var seen = Set<String>()
    for line in out.split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let m = String(parts[0]).trimmingCharacters(in: .whitespaces)
      let t = String(parts[1]).trimmingCharacters(in: .whitespaces)
      guard !m.isEmpty, !t.isEmpty else { continue }
      let key = "\(m)|\(t)"
      if seen.contains(key) { continue }
      seen.insert(key)
      refs.append(TabRef(machine: m, tab: t))
    }
    return refs
  }

  /// 取 ~/blink-assistant/CLAUDE.md 的 mtime（epoch 秒）；文件不存在或失败返 0
  func remoteMarkdownMtime() async throws -> Int {
    let script = """
    P="$HOME/blink-assistant/CLAUDE.md"
    [ -f "$P" ] && stat -f %m "$P" 2>/dev/null || echo 0
    """
    let out = try await execRemote(script: script)
    return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  /// 读 jsonl 把过往 user/assistant 文本对话回填成气泡（过滤掉 tool_use / system reminder）
  func loadHistory() async throws -> [BlinkAssistantMessage] {
    let script = """
    export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
    PROJ=\(remoteProjectDir)
    [ -d "$PROJ" ] || exit 0
    LATEST=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | head -1)
    [ -n "$LATEST" ] || exit 0
    jq -s -r '
      [.[]
        | select(.type=="user" or .type=="assistant")
        | (if (.message.content | type) == "string" then
             .message.content
           else
             [.message.content[]? | select(.type=="text") | .text] | join("\\n")
           end) as $body
        | ($body
            | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
            | sub("^\\\\s+"; "")
            | sub("\\\\s+$"; "")
          ) as $clean
        | select(($clean | length) > 0)
        | {role: (if .type=="user" then "user" else "assistant" end), text: $clean}
      ] |
      .[-50:] |
      .[] |
      (.role + "\\t" + (.text | gsub("\\n"; "\\\\n")))
    ' "$LATEST"
    """
    let out = try await execRemote(script: script)
    var result: [BlinkAssistantMessage] = []
    let marker = "<<<SUMMARY>>>"
    for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let role: BlinkAssistantMessage.Role = (parts[0] == "user") ? .user : .assistant
      let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
      // assistant 历史里如果有 <<<SUMMARY>>> marker，按 marker 拆成 思考段 + 总结段 两条
      if role == .assistant, text.contains(marker) {
        let split = text.components(separatedBy: marker)
        let thinking = split.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = split.dropFirst().joined(separator: marker)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !thinking.isEmpty {
          result.append(BlinkAssistantMessage.assistant(text: thinking, turnRole: .intermediate))
        }
        if !summary.isEmpty {
          result.append(BlinkAssistantMessage.assistant(text: summary, turnRole: .final))
        }
      } else if role == .assistant {
        result.append(BlinkAssistantMessage.assistant(text: text))
      } else {
        result.append(BlinkAssistantMessage(role: role, text: text))
      }
    }
    return result
  }

  // MARK: SSH exec

  private func execRemote(script: String) async throws -> String {
    guard let m = await MainActor.run(body: { BlinkMachineStore.shared.currentMachine }) else {
      throw BlinkAssistantError.noMachine
    }
    let resolvedHost = await MainActor.run { BlinkMachineStore.bestHost(for: m) }
    let user = m.user

    let (hostName, config) = try buildConfig(host: resolvedHost, user: user)
    let scriptB64 = Data(script.utf8).base64EncodedString()
    let cmd = "echo \(scriptB64) | base64 -d | bash"

    return try await withCheckedThrowingContinuation { cont in
      var hasResumed = false
      var stdoutData = Data()
      let token = ObjectIdentifier(NSObject())

      let pub = SSHPool.dial(hostName, with: config, withProxy: BlinkSSH.executeProxyCommand)
        .flatMap { client in
          client.requestExec(command: cmd)
        }
        .flatMap { stream -> AnyPublisher<DispatchData, Error> in
          stream.read(max: 4 * 1024 * 1024)
        }

      let cancel = pub.sink(
        receiveCompletion: { [weak self] completion in
          self?.releaseBag(token)
          guard !hasResumed else { return }
          hasResumed = true
          switch completion {
          case .finished:
            let s = String(data: stdoutData, encoding: .utf8) ?? ""
            cont.resume(returning: s)
          case .failure(let err):
            cont.resume(throwing: BlinkAssistantError.execFailed("\(err)"))
          }
        },
        receiveValue: { dispatchData in
          dispatchData.enumerateBytes { region, _, _ in
            stdoutData.append(contentsOf: region)
          }
        }
      )
      self.retainBag(token, cancel)
    }
  }

  /// 按行流式 exec：把远端 stdout 按 \n 切，每行调一次 onLine。Writer 协议在 BlinkFiles。
  private func execRemoteStream(script: String, onLine: @escaping (String) -> Void) async throws {
    guard let m = await MainActor.run(body: { BlinkMachineStore.shared.currentMachine }) else {
      throw BlinkAssistantError.noMachine
    }
    let resolvedHost = await MainActor.run { BlinkMachineStore.bestHost(for: m) }
    let user = m.user
    let (hostName, config) = try buildConfig(host: resolvedHost, user: user)
    let scriptB64 = Data(script.utf8).base64EncodedString()
    let cmd = "echo \(scriptB64) | base64 -d | bash"

    return try await withCheckedThrowingContinuation { cont in
      var hasResumed = false
      let token = ObjectIdentifier(NSObject())
      let writer = LineStreamWriter { line in
        DispatchQueue.main.async { onLine(line) }
      }

      let pub = SSHPool.dial(hostName, with: config, withProxy: BlinkSSH.executeProxyCommand)
        .flatMap { client in client.requestExec(command: cmd) }
        .flatMap { stream -> AnyPublisher<Int, Error> in
          stream.writeTo(writer)
        }

      let cancel = pub.sink(
        receiveCompletion: { [weak self] completion in
          self?.releaseBag(token)
          // writer 里还可能残留最后一行没换行的内容
          writer.flush()
          guard !hasResumed else { return }
          hasResumed = true
          switch completion {
          case .finished: cont.resume()
          case .failure(let err): cont.resume(throwing: BlinkAssistantError.execFailed("\(err)"))
          }
        },
        receiveValue: { _ in /* writer 在自己 write 里推 onLine */ }
      )
      self.retainBag(token, cancel)
    }
  }

  private func buildConfig(host: String, user: String) throws -> (String, SSHClientConfig) {
    let params: [String: Any] = ["user": user]
    let commandHost: BKSSHHost
    do { commandHost = try BKSSHHost(content: params) }
    catch { throw BlinkAssistantError.configFailed("BKSSHHost: \(error)") }

    let resolved: (hostName: String, host: BKSSHHost)
    do { resolved = try BKConfig().resolveHost(alias: host, extending: commandHost) }
    catch { throw BlinkAssistantError.configFailed("resolveHost: \(error)") }

    let device = TermDevice()
    let config: SSHClientConfig
    do { config = try SSHClientConfigProvider.config(host: resolved.host, using: device) }
    catch { throw BlinkAssistantError.configFailed("config: \(error)") }
    return (resolved.hostName, config)
  }

  private func retainBag(_ token: ObjectIdentifier, _ c: AnyCancellable) {
    bagsLock.lock(); defer { bagsLock.unlock() }
    liveBags[token] = c
  }
  private func releaseBag(_ token: ObjectIdentifier) {
    bagsLock.lock(); defer { bagsLock.unlock() }
    liveBags.removeValue(forKey: token)
  }
}

// MARK: - Cell

/// 巡检员工行：整行可点（点了让助手给这位员工拍板），按下时灰色高亮
private final class PatrolRowControl: UIControl {
  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? UIColor.systemFill.withAlphaComponent(0.5) : .clear }
  }
}

private final class BlinkAssistantBubbleCell: UITableViewCell {
  static let reuseId = "AsstBubble"

  private let bubble = UIView()
  private let label = UILabel()
  private let dotsContainer = UIStackView()
  private let dot1 = UIView()
  private let dot2 = UIView()
  private let dot3 = UIView()
  private let decisionStack = UIStackView()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var dotsHeightConstraint: NSLayoutConstraint!
  private var labelTopConstraint: NSLayoutConstraint!
  private var labelBottomConstraint: NSLayoutConstraint!
  private var decisionStackTopConstraint: NSLayoutConstraint!
  private var decisionStackBottomConstraint: NSLayoutConstraint!
  var onLongPress: ((String) -> Void)?
  var onDecision: ((BlinkAssistantDecision.DecisionOption) -> Void)?
  var onPendingTap: ((BlinkAssistantPending.Item) -> Void)?
  var onPatrolTap: ((BlinkAssistantPatrol.Item) -> Void)?
  private var currentDecision: BlinkAssistantDecision?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    bubble.translatesAutoresizingMaskIntoConstraints = false
    bubble.layer.cornerRadius = 18
    bubble.layer.cornerCurve = .continuous
    bubble.layer.masksToBounds = false  // 让阴影能露出来
    contentView.addSubview(bubble)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 15)
    bubble.addSubview(label)

    // 三跳点（弹跳 loading，跟文字 inline）
    [dot1, dot2, dot3].forEach { d in
      d.translatesAutoresizingMaskIntoConstraints = false
      d.backgroundColor = .secondaryLabel
      d.layer.cornerRadius = 4
      d.widthAnchor.constraint(equalToConstant: 7).isActive = true
      d.heightAnchor.constraint(equalToConstant: 7).isActive = true
    }
    dotsContainer.translatesAutoresizingMaskIntoConstraints = false
    dotsContainer.axis = .horizontal
    dotsContainer.spacing = 5
    dotsContainer.alignment = .center
    dotsContainer.addArrangedSubview(dot1)
    dotsContainer.addArrangedSubview(dot2)
    dotsContainer.addArrangedSubview(dot3)
    bubble.addSubview(dotsContainer)

    decisionStack.translatesAutoresizingMaskIntoConstraints = false
    decisionStack.axis = .vertical
    decisionStack.spacing = 8
    decisionStack.isHidden = true
    bubble.addSubview(decisionStack)

    leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14)
    trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14)
    labelTopConstraint = label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 11)
    labelBottomConstraint = label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -11)
    dotsHeightConstraint = dotsContainer.heightAnchor.constraint(equalToConstant: 0)
    decisionStackTopConstraint = decisionStack.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 0)
    decisionStackBottomConstraint = decisionStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 0)

    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),

      labelTopConstraint,
      label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
      label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),

      dotsContainer.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
      dotsContainer.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
      dotsHeightConstraint,

      decisionStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
      decisionStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
    ])
    labelBottomConstraint.isActive = true
    decisionStackTopConstraint.isActive = false
    decisionStackBottomConstraint.isActive = false

    let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    lp.minimumPressDuration = 0.4
    bubble.addGestureRecognizer(lp)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    stopDots()
    bubble.transform = .identity
    bubble.alpha = 1
    decisionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    decisionStack.isHidden = true
    decisionStackTopConstraint.isActive = false
    decisionStackBottomConstraint.isActive = false
    labelBottomConstraint.isActive = true
    currentDecision = nil
    onDecision = nil
    onPendingTap = nil
    onPatrolTap = nil
  }

  func configure(with msg: BlinkAssistantMessage) {
    let isUser = msg.role == .user
    let isSystem = msg.role == .system

    if msg.isLoading {
      label.attributedText = nil
      label.text = ""
      label.isHidden = true
      dotsContainer.isHidden = false
      dotsHeightConstraint.constant = 22
      labelTopConstraint.constant = 0
      labelBottomConstraint.constant = 0
      startDots()
    } else {
      label.isHidden = false
      dotsContainer.isHidden = true
      dotsHeightConstraint.constant = 0
      labelTopConstraint.constant = 11
      labelBottomConstraint.constant = -11
      stopDots()
      // 只有 assistant 气泡走 markdown 渲染；user/system 保持纯文本
      if msg.role == .assistant {
        // 思考中前缀 💭，总结结句前缀 ✅；历史/无角色不加
        let iconPrefix: String
        switch msg.turnRole {
        case .intermediate: iconPrefix = "💭  "
        case .final:        iconPrefix = "✅  "
        case .none:         iconPrefix = ""
        }
        // iMessage 灰气泡：跟随深色模式（.label 自动黑/白）
        label.attributedText = AssistantMarkdown.render(iconPrefix + msg.text, baseFont: .systemFont(ofSize: 15), textColor: .label)
      } else {
        label.attributedText = nil
        label.text = msg.text
      }
    }

    if msg.role != .assistant || msg.isLoading {
      label.textColor = isUser ? .white : .label
      label.font = isSystem ? .italicSystemFont(ofSize: 13) : .systemFont(ofSize: 15)
    }

    // 去掉阴影
    bubble.layer.shadowOpacity = 0

    if isSystem {
      bubble.backgroundColor = UIColor.tertiarySystemBackground
      label.textColor = .secondaryLabel
      leadingConstraint.isActive = true
      trailingConstraint.isActive = true
      leadingConstraint.constant = 36
      trailingConstraint.constant = -36
    } else if isUser {
      bubble.backgroundColor = .systemBlue
      leadingConstraint.isActive = false
      trailingConstraint.isActive = true
      trailingConstraint.constant = -14
    } else {
      // assistant：iMessage 接收方灰（systemGray5 自适应深浅色：#E5E5EA / #2C2C2E）
      bubble.backgroundColor = .systemGray5
      leadingConstraint.isActive = true
      trailingConstraint.isActive = false
      leadingConstraint.constant = 14
    }

    // 决策卡片：在文字下面追加员工 header + 选项按钮
    currentDecision = msg.decision
    if let decision = msg.decision, !msg.isLoading {
      // 如果 cleanText 为空（DECISION 自带 question），用 decision.question 当 label 文本
      if msg.text.isEmpty {
        label.attributedText = AssistantMarkdown.render("❓  " + decision.question,
                                                          baseFont: .systemFont(ofSize: 15),
                                                          textColor: .label)
      }
      decisionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

      // header：醒目展示这是给谁的决策（cc-target · machine）
      if let headerText = decision.headerText {
        let header = makeDecisionHeader(text: headerText)
        decisionStack.addArrangedSubview(header)
        decisionStack.setCustomSpacing(10, after: header)
      }

      // context 单独一段（可选）
      if let ctx = decision.context, !ctx.isEmpty, !msg.text.contains(ctx) {
        let ctxLabel = UILabel()
        ctxLabel.numberOfLines = 0
        ctxLabel.font = .systemFont(ofSize: 13)
        ctxLabel.textColor = .secondaryLabel
        ctxLabel.text = ctx
        decisionStack.addArrangedSubview(ctxLabel)
      }
      for option in decision.options {
        let btn = UIButton(type: .system)
        var cfg = UIButton.Configuration.tinted()
        cfg.title = option.label
        cfg.cornerStyle = .medium
        cfg.titleAlignment = .leading
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        cfg.background.backgroundColor = .systemBackground
        cfg.baseForegroundColor = (option.isAlways == true) ? .systemPurple : .systemBlue
        btn.configuration = cfg
        btn.contentHorizontalAlignment = .leading
        btn.tag = decision.options.firstIndex(of: option) ?? 0
        btn.addAction(UIAction { [weak self] _ in
          guard let self else { return }
          self.onDecision?(option)
        }, for: .touchUpInside)
        decisionStack.addArrangedSubview(btn)
      }
      decisionStack.isHidden = false
      labelBottomConstraint.isActive = false
      decisionStackTopConstraint.constant = 10
      decisionStackBottomConstraint.constant = -11
      decisionStackTopConstraint.isActive = true
      decisionStackBottomConstraint.isActive = true
    } else if let patrol = msg.patrol, !patrol.segments.isEmpty, !msg.isLoading {
      // 巡检报告（按状态分 3 段渲染）
      decisionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
      if let t = patrol.title, !t.isEmpty {
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = t
        decisionStack.addArrangedSubview(titleLabel)
        decisionStack.setCustomSpacing(8, after: titleLabel)
      }
      // 三段固定顺序：等待中 → 干活中 → 没在干活
      let order: [BlinkAssistantPatrol.Status] = [.waiting, .working, .idle]
      let byStatus = Dictionary(grouping: patrol.segments, by: { $0.status })
      for st in order {
        guard let segs = byStatus[st], let first = segs.first else { continue }
        let items = segs.flatMap { $0.items }
        guard !items.isEmpty else { continue }
        let seg = makePatrolSegment(status: st, items: items)
        decisionStack.addArrangedSubview(seg)
        decisionStack.setCustomSpacing(10, after: seg)
        _ = first
      }
      // 末尾如果还有 PENDING 也接上（可点回复）
      if let pending = msg.pending, !pending.items.isEmpty {
        for item in pending.items {
          decisionStack.addArrangedSubview(makePendingRow(item: item))
        }
      }
      decisionStack.isHidden = false
      labelBottomConstraint.isActive = false
      decisionStackTopConstraint.constant = 10
      decisionStackBottomConstraint.constant = -11
      decisionStackTopConstraint.isActive = true
      decisionStackBottomConstraint.isActive = true
    } else if let pending = msg.pending, !pending.items.isEmpty, !msg.isLoading {
      // 待处理列表：每条挂一个「回复」按钮
      decisionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
      for item in pending.items {
        let row = makePendingRow(item: item)
        decisionStack.addArrangedSubview(row)
      }
      decisionStack.isHidden = false
      labelBottomConstraint.isActive = false
      decisionStackTopConstraint.constant = 10
      decisionStackBottomConstraint.constant = -11
      decisionStackTopConstraint.isActive = true
      decisionStackBottomConstraint.isActive = true
    } else {
      decisionStack.isHidden = true
      decisionStackTopConstraint.isActive = false
      decisionStackBottomConstraint.isActive = false
      labelBottomConstraint.isActive = true
    }
  }

  // MARK: - Patrol segment (方案 B)

  /// 一个状态段：head（emoji + 标题 + count）+ 多个员工 row，全部装在一张白卡里
  private func makePatrolSegment(status: BlinkAssistantPatrol.Status,
                                  items: [BlinkAssistantPatrol.Item]) -> UIView {
    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = .systemBackground
    card.layer.cornerRadius = 14
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true

    let stack = UIStackView()
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: card.topAnchor),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    // head
    let head = makePatrolSegmentHeader(status: status, count: items.count)
    stack.addArrangedSubview(head)
    stack.addArrangedSubview(makeHairline())

    // rows
    for (i, item) in items.enumerated() {
      let row = makePatrolEmployeeRow(item: item, status: status)
      stack.addArrangedSubview(row)
      if i < items.count - 1 { stack.addArrangedSubview(makeHairline()) }
    }
    return card
  }

  private func makePatrolSegmentHeader(status: BlinkAssistantPatrol.Status, count: Int) -> UIView {
    let v = UIView()
    let emoji = UILabel()
    emoji.font = .systemFont(ofSize: 17)
    emoji.text = status.emoji
    emoji.translatesAutoresizingMaskIntoConstraints = false

    let title = UILabel()
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.text = status.title
    title.textColor = .label
    title.translatesAutoresizingMaskIntoConstraints = false

    let badge = UILabel()
    badge.font = .systemFont(ofSize: 12, weight: .semibold)
    badge.text = "\(count)"
    badge.textColor = .secondaryLabel
    badge.textAlignment = .center
    badge.backgroundColor = UIColor.tertiarySystemFill
    badge.layer.cornerRadius = 8
    badge.layer.masksToBounds = true
    badge.translatesAutoresizingMaskIntoConstraints = false

    v.addSubview(emoji); v.addSubview(title); v.addSubview(badge)
    NSLayoutConstraint.activate([
      emoji.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
      emoji.centerYAnchor.constraint(equalTo: v.centerYAnchor),

      title.leadingAnchor.constraint(equalTo: emoji.trailingAnchor, constant: 8),
      title.centerYAnchor.constraint(equalTo: v.centerYAnchor),

      badge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
      badge.centerYAnchor.constraint(equalTo: v.centerYAnchor),
      badge.heightAnchor.constraint(equalToConstant: 18),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

      v.heightAnchor.constraint(equalToConstant: 38),
    ])
    return v
  }

  /// 权威 role 映射：org.md 钦定的 4 个 role，iOS 端兜底，避免 cc 写"iOS/产品/运营/后端/前端/语音/基建"等细分
  private static let authoritativeRoles: [String: String] = [
    "tom":   "CTO",
    "candy": "产品经理",
    "bella": "行政",
    "apple": "开发",
    "jack":  "开发",
    "dave":  "开发",
    "adam":  "开发",
    "alice": "开发",
  ]

  private static func roleText(for employee: String, fallback: String?) -> String? {
    if let r = authoritativeRoles[employee.lowercased()] { return r }
    // 不在权威表里就用 cc 给的（但通常用户每个员工都在表里）
    return fallback?.isEmpty == false ? fallback : nil
  }

  private func makePatrolEmployeeRow(item: BlinkAssistantPatrol.Item,
                                      status: BlinkAssistantPatrol.Status) -> UIView {
    let row = PatrolRowControl()

    // 头像：用户在 ⚙️→员工头像 里设过 → 用自定义；没设过 → 首字母色块（不再 fall back 到默认 DiceBear，省得几个员工脸都一样）
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.backgroundColor = .tertiarySystemFill
    iv.layer.cornerRadius = 18
    iv.clipsToBounds = true
    iv.contentMode = .scaleAspectFill
    if let custom = BlinkPeopleStore.shared.customIcon(for: item.employee) {
      iv.image = custom
    } else {
      iv.image = Self.fallbackAvatar(for: item.employee)
    }

    // 名字（粗）+ role（小灰 chip）
    let nameLabel = UILabel()
    nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    nameLabel.text = item.employee
    nameLabel.textColor = .label
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    let roleChip = UILabel()
    roleChip.font = .systemFont(ofSize: 11)
    roleChip.textColor = .secondaryLabel
    roleChip.text = Self.roleText(for: item.employee, fallback: item.role)
    roleChip.translatesAutoresizingMaskIntoConstraints = false

    // 项目摘要：每个 project 一行 "<name>: <desc>"，最多 4 行
    let descLabel = UILabel()
    descLabel.numberOfLines = 0
    descLabel.font = .systemFont(ofSize: 13)
    descLabel.textColor = .secondaryLabel
    let lines: [String] = item.projects.prefix(4).map { p in
      var line = "\(p.name): \(p.desc)"
      if status == .waiting, let w = p.waitingFor, !w.isEmpty {
        line += "（等 \(w)）"
      }
      return line
    }
    descLabel.text = lines.joined(separator: "\n")
    descLabel.translatesAutoresizingMaskIntoConstraints = false

    // 右侧 chevron：提示整行可点（点了让助手给这位员工拍板）
    let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    chevron.tintColor = .tertiaryLabel
    chevron.translatesAutoresizingMaskIntoConstraints = false

    [iv, nameLabel, roleChip, descLabel, chevron].forEach { row.addSubview($0) }

    NSLayoutConstraint.activate([
      iv.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
      iv.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
      iv.widthAnchor.constraint(equalToConstant: 36),
      iv.heightAnchor.constraint(equalToConstant: 36),

      nameLabel.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 10),
      nameLabel.topAnchor.constraint(equalTo: iv.topAnchor),

      roleChip.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
      roleChip.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
      roleChip.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

      descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      descLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
      descLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
      descLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),

      chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
      chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 12),
    ])

    row.addAction(UIAction { [weak self] _ in
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      self?.onPatrolTap?(item)
    }, for: .touchUpInside)
    return row
  }

  private func makeHairline() -> UIView {
    let v = UIView()
    v.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
    v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
    return v
  }

  /// 头像未加载完前的占位：员工名首字母大写圆形
  private static func fallbackAvatar(for name: String) -> UIImage? {
    let size = CGSize(width: 72, height: 72)
    let letter = String(name.prefix(1)).uppercased()
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      // 背景按名字 hash 选色
      let palette: [UIColor] = [
        UIColor.systemBlue, .systemPurple, .systemTeal, .systemIndigo,
        .systemGreen, .systemOrange, .systemPink, .systemBrown,
      ]
      let hash = abs(name.hashValue)
      let bg = palette[hash % palette.count]
      ctx.cgContext.setFillColor(bg.cgColor)
      ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
        .foregroundColor: UIColor.white,
      ]
      let str = NSAttributedString(string: letter, attributes: attrs)
      let bounds = str.size()
      str.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                            y: (size.height - bounds.height) / 2))
    }
  }

  /// 待处理项的一行：标题 + 副标题 + 右侧 "回复 →" 按钮，整行可点
  private func makePendingRow(item: BlinkAssistantPending.Item) -> UIView {
    let container = UIControl()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .systemBackground
    container.layer.cornerRadius = 10
    container.layer.cornerCurve = .continuous

    let head = UILabel()
    head.font = .systemFont(ofSize: 13, weight: .semibold)
    head.textColor = .systemBlue
    head.text = (item.machine.map { "\(item.target) · \($0)" } ?? item.target)
    head.numberOfLines = 1
    head.translatesAutoresizingMaskIntoConstraints = false

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 14)
    titleLabel.textColor = .label
    titleLabel.text = item.title
    titleLabel.numberOfLines = 2
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    let chevron = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.right.fill",
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
    chevron.tintColor = .systemBlue
    chevron.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(head)
    container.addSubview(titleLabel)
    container.addSubview(chevron)

    NSLayoutConstraint.activate([
      head.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      head.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      head.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

      titleLabel.leadingAnchor.constraint(equalTo: head.leadingAnchor),
      titleLabel.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 2),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
      titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

      chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 18),
      chevron.heightAnchor.constraint(equalToConstant: 18),
    ])
    container.addAction(UIAction { [weak self] _ in
      self?.onPendingTap?(item)
    }, for: .touchUpInside)
    return container
  }

  /// 决策卡的"这是给谁拍板"header pill
  private func makeDecisionHeader(text: String) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .systemBlue.withAlphaComponent(0.12)
    container.layer.cornerRadius = 10
    container.layer.cornerCurve = .continuous

    let icon = UIImageView(image: UIImage(systemName: "person.crop.circle.badge.questionmark",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
    icon.tintColor = .systemBlue
    icon.translatesAutoresizingMaskIntoConstraints = false

    let titleHint = UILabel()
    titleHint.font = .systemFont(ofSize: 11, weight: .semibold)
    titleHint.textColor = .systemBlue
    titleHint.text = "等你拍板"
    titleHint.translatesAutoresizingMaskIntoConstraints = false

    let nameLabel = UILabel()
    nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    nameLabel.textColor = .label
    nameLabel.text = text
    nameLabel.numberOfLines = 1
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(icon)
    container.addSubview(titleHint)
    container.addSubview(nameLabel)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 20),
      icon.heightAnchor.constraint(equalToConstant: 20),

      titleHint.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      titleHint.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),

      nameLabel.leadingAnchor.constraint(equalTo: titleHint.leadingAnchor),
      nameLabel.topAnchor.constraint(equalTo: titleHint.bottomAnchor, constant: 1),
      nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      nameLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
    ])
    return container
  }

  // MARK: 弹跳点动画（CABasicAnimation 错峰 translateY）
  private func startDots() {
    let dots = [dot1, dot2, dot3]
    for (i, d) in dots.enumerated() {
      d.layer.removeAllAnimations()
      let bounce = CABasicAnimation(keyPath: "transform.translation.y")
      bounce.fromValue = 0
      bounce.toValue = -6
      bounce.duration = 0.45
      bounce.autoreverses = true
      bounce.repeatCount = .infinity
      bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bounce.beginTime = CACurrentMediaTime() + Double(i) * 0.15
      d.layer.add(bounce, forKey: "bounce")
    }
  }
  private func stopDots() {
    [dot1, dot2, dot3].forEach { $0.layer.removeAllAnimations() }
  }

  @objc private func handleLongPress(_ rec: UILongPressGestureRecognizer) {
    guard rec.state == .began, let text = label.text, !text.isEmpty else { return }
    UIView.animate(withDuration: 0.15, animations: { self.bubble.alpha = 0.55 }) { _ in
      UIView.animate(withDuration: 0.2) { self.bubble.alpha = 1 }
    }
    onLongPress?(text)
  }
}

// MARK: - Chat VC

@objc final class BlinkAssistantChatViewController: UIViewController {

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let inputBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
  private let inputBarSeparator = UIView()
  private let textView = UITextView()
  private let sendButton = UIButton(type: .system)
  private let micButton = UIButton(type: .system)
  private let atButton = UIButton(type: .system)
  private let placeholderLabel = UILabel()
  // @ 提及缓存的标签列表
  private var cachedTabs: [BlinkAssistantBackend.TabRef] = []
  // 语音识别（复用 GLMASRClient / AITextPolisher）
  private var asrRecorder: AVAudioRecorder?
  private var asrFileURL: URL?
  private var isAsrRecording = false
  private let statusLabel = UILabel()
  private let emptyStateView = UIView()
  private var textViewHeightConstraint: NSLayoutConstraint!

  private var messages: [BlinkAssistantMessage] = []
  private var isSending = false {
    didSet { updateStatus() }
  }
  private enum Status { case idle, thinking }
  private var status: Status = .idle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground

    setupNavTitle()
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(closeTapped))

    setupTable()
    setupInputBar()
    setupEmptyState()
    updateStatus()
    updateSendButtonState()

    // 点击聊天空白区收键盘
    let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKb))
    tap.cancelsTouchesInView = false
    tableView.addGestureRecognizer(tap)

    Task {
      await loadHistory()
      // 把 machines 列表推到远端，让 cc 知道 peer 怎么 ssh
      try? await BlinkAssistantBackend.shared.syncMachinesToRemote()
      await maybeReloadOnMarkdownChange()
    }
  }

  private static let kMarkdownMtimeKey = "BlinkAssistant.CLAUDEMd.mtime"

  private func maybeReloadOnMarkdownChange() async {
    guard let mtime = try? await BlinkAssistantBackend.shared.remoteMarkdownMtime(), mtime > 0 else { return }
    let last = UserDefaults.standard.integer(forKey: Self.kMarkdownMtimeKey)
    UserDefaults.standard.set(mtime, forKey: Self.kMarkdownMtimeKey)
    // 首次记录就不触发；只有 mtime 变大才 reload
    guard last > 0, mtime > last else { return }
    await MainActor.run {
      self.appendMessage(BlinkAssistantMessage(role: .system, text: "🔄 CLAUDE.md 有更新，正在让助手重新读…"))
    }
    autoSend("请重新读一下 ~/blink-assistant/CLAUDE.md（有更新），从这一轮开始按新规则。一句话告诉我你看到的关键变化就好。")
  }

  /// 自动发消息（带 user 气泡可见，跟手动发一样走 sendStreaming）
  private func autoSend(_ text: String) {
    guard !isSending else { return }
    appendMessage(BlinkAssistantMessage(role: .user, text: text))
    appendMessage(BlinkAssistantMessage(role: .assistant, text: "", isLoading: true))
    let loadingIdx = messages.count - 1
    var loadingPending = true
    var turnAssistantIndices: [Int] = []
    isSending = true
    Task {
      defer { self.isSending = false }
      do {
        try await BlinkAssistantBackend.shared.sendStreaming(text) { [weak self] event in
          guard let self else { return }
          switch event {
          case .text(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let newMsg = BlinkAssistantMessage.assistant(text: trimmed, turnRole: .intermediate)
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: newMsg)
              turnAssistantIndices.append(loadingIdx)
              loadingPending = false
            } else {
              let appendIdx = self.messages.count
              self.appendMessage(newMsg)
              turnAssistantIndices.append(appendIdx)
            }
          case .done:
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "（这轮没文本输出）"))
              loadingPending = false
            } else if let lastIdx = turnAssistantIndices.last {
              self.markAsFinal(at: lastIdx)
            }
          case .error(let e):
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: e))
              loadingPending = false
            } else {
              self.appendMessage(BlinkAssistantMessage(role: .system, text: e))
            }
          }
        }
      } catch {
        await MainActor.run {
          if loadingPending {
            self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "出错了：\(error.localizedDescription)"))
          }
        }
      }
    }
  }

  private func setupNavTitle() {
    let titleStack = UIStackView()
    titleStack.axis = .vertical
    titleStack.alignment = .center
    titleStack.spacing = 1
    let title = UILabel()
    title.text = "助手"
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
    statusLabel.textColor = .systemGreen
    titleStack.addArrangedSubview(title)
    titleStack.addArrangedSubview(statusLabel)
    navigationItem.titleView = titleStack
  }

  private func setupEmptyState() {
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    let icon = UIImageView(image: UIImage(systemName: "sparkles"))
    icon.tintColor = .systemPurple
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    let label = UILabel()
    label.text = "随便聊点什么\n问「状态」就能看所有 tab 的进度"
    label.font = .systemFont(ofSize: 15)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.addSubview(icon)
    emptyStateView.addSubview(label)
    view.insertSubview(emptyStateView, belowSubview: tableView)
    NSLayoutConstraint.activate([
      emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
      icon.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
      icon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
      icon.widthAnchor.constraint(equalToConstant: 48),
      icon.heightAnchor.constraint(equalToConstant: 48),
      label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
      label.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),
      label.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor),
      emptyStateView.widthAnchor.constraint(equalToConstant: 280),
    ])
    emptyStateView.alpha = 0
  }

  private func updateStatus() {
    status = isSending ? .thinking : .idle
    switch status {
    case .idle:
      statusLabel.text = "● 在线"
      statusLabel.textColor = .systemGreen
    case .thinking:
      statusLabel.text = "● 思考中…"
      statusLabel.textColor = .systemOrange
    }
  }

  private func updateSendButtonState() {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    sendButton.isEnabled = hasText && !isSending
    UIView.animate(withDuration: 0.15) {
      self.sendButton.tintColor = self.sendButton.isEnabled ? .systemBlue : UIColor.systemGray3
    }
  }

  private func refreshEmptyState() {
    let isEmpty = messages.isEmpty || (messages.count == 1 && messages[0].role == .system)
    UIView.animate(withDuration: 0.25) {
      self.emptyStateView.alpha = isEmpty ? 1 : 0
    }
  }

  @objc private func dismissKb() {
    view.endEditing(true)
  }

  // 进入不自动弹键盘，点输入框才弹

  private func setupTable() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.separatorStyle = .none
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(BlinkAssistantBubbleCell.self, forCellReuseIdentifier: BlinkAssistantBubbleCell.reuseId)
    tableView.estimatedRowHeight = 60
    tableView.rowHeight = UITableView.automaticDimension
    tableView.keyboardDismissMode = .interactive
    tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    view.addSubview(tableView)
  }

  private func setupInputBar() {
    inputBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(inputBar)
    let content = inputBar.contentView

    // 顶部 hairline
    inputBarSeparator.translatesAutoresizingMaskIntoConstraints = false
    inputBarSeparator.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
    content.addSubview(inputBarSeparator)

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.font = .systemFont(ofSize: 15)
    textView.backgroundColor = .systemBackground
    textView.layer.cornerRadius = 18
    textView.layer.cornerCurve = .continuous
    textView.layer.borderWidth = 0.5
    textView.layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor
    textView.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
    textView.isScrollEnabled = false
    textView.delegate = self
    textView.returnKeyType = .send
    content.addSubview(textView)

    placeholderLabel.text = "跟助手说话…"
    placeholderLabel.font = .systemFont(ofSize: 15)
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    textView.addSubview(placeholderLabel)

    // 实心圆背景 + 白色箭头
    var cfg = UIButton.Configuration.filled()
    cfg.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
    cfg.baseBackgroundColor = .systemBlue
    cfg.baseForegroundColor = .white
    cfg.cornerStyle = .capsule
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
    sendButton.configuration = cfg
    sendButton.translatesAutoresizingMaskIntoConstraints = false
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    sendButton.addTarget(self, action: #selector(sendPressed), for: .touchDown)
    sendButton.addTarget(self, action: #selector(sendReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    content.addSubview(sendButton)

    micButton.translatesAutoresizingMaskIntoConstraints = false
    micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
    content.addSubview(micButton)
    updateMicAppearance()

    var atCfg = UIButton.Configuration.plain()
    atCfg.image = UIImage(systemName: "at", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
    atCfg.baseForegroundColor = .systemBlue
    atCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
    atButton.configuration = atCfg
    atButton.translatesAutoresizingMaskIntoConstraints = false
    atButton.addTarget(self, action: #selector(atTapped), for: .touchUpInside)
    content.addSubview(atButton)

    textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 38)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

      inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      inputBarSeparator.topAnchor.constraint(equalTo: content.topAnchor),
      inputBarSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      inputBarSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      inputBarSeparator.heightAnchor.constraint(equalToConstant: 0.5),

      micButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      micButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
      micButton.widthAnchor.constraint(equalToConstant: 34),
      micButton.heightAnchor.constraint(equalToConstant: 34),

      atButton.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 0),
      atButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
      atButton.widthAnchor.constraint(equalToConstant: 34),
      atButton.heightAnchor.constraint(equalToConstant: 34),

      textView.leadingAnchor.constraint(equalTo: atButton.trailingAnchor, constant: 4),
      textView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
      textView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
      textViewHeightConstraint,

      sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
      sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
      sendButton.widthAnchor.constraint(equalToConstant: 34),
      sendButton.heightAnchor.constraint(equalToConstant: 34),

      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
      placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 9),
    ])
  }

  @objc private func sendPressed() {
    UIView.animate(withDuration: 0.08) {
      self.sendButton.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
    }
  }
  @objc private func sendReleased() {
    UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
      self.sendButton.transform = .identity
    }
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  // MARK: messages

  private func loadHistory() async {
    do {
      let hist = try await BlinkAssistantBackend.shared.loadHistory()
      messages = hist
      if hist.isEmpty {
        messages.append(BlinkAssistantMessage(role: .system, text: "Hi，我是 Blink 助手（cc on cc）。问我「状态」可以看所有 tab 的进度，问「让 X tab 做 Y」我会帮你发命令。破坏性操作我会先确认。"))
      }
      tableView.reloadData()
      scrollToBottom(animated: false)
      refreshEmptyState()
    } catch {
      messages.append(BlinkAssistantMessage(role: .system, text: "历史加载失败：\(error.localizedDescription)"))
      tableView.reloadData()
      refreshEmptyState()
    }
  }

  // 单条插入用 insertRows 触发滑入动画
  private func appendMessage(_ msg: BlinkAssistantMessage, animated: Bool = true) {
    messages.append(msg)
    let row = messages.count - 1
    let ip = IndexPath(row: row, section: 0)
    if animated {
      tableView.insertRows(at: [ip], with: .fade)
    } else {
      tableView.reloadData()
    }
    refreshEmptyState()
    scrollToBottom(animated: true)
  }

  private func replaceMessage(at row: Int, with msg: BlinkAssistantMessage) {
    guard messages.indices.contains(row) else { return }
    messages[row] = msg
    tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .fade)
    scrollToBottom(animated: true)
  }

  /// 把 turn 末尾那条 assistant 气泡升级成 .final（✅ 总结图标）
  private func markAsFinal(at row: Int) {
    guard messages.indices.contains(row) else { return }
    messages[row].turnRole = .final
    tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
  }

  // MARK: @ 提及：选某台机的某个 tab 让助手转发消息

  @objc private func atTapped() {
    let loading = UIAlertController(title: "拉取 tab 列表…", message: nil, preferredStyle: .actionSheet)
    if let pop = loading.popoverPresentationController {
      pop.sourceView = atButton; pop.sourceRect = atButton.bounds
    }
    present(loading, animated: true)
    Task {
      let refs: [BlinkAssistantBackend.TabRef]
      do {
        refs = try await BlinkAssistantBackend.shared.listAllTabs()
      } catch {
        await MainActor.run {
          loading.dismiss(animated: true) {
            let alert = UIAlertController(title: "拉取失败", message: "\(error)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self.present(alert, animated: true)
          }
        }
        return
      }
      await MainActor.run {
        self.cachedTabs = refs
        loading.dismiss(animated: true) {
          self.presentTabPicker(refs)
        }
      }
    }
  }

  private func presentTabPicker(_ refs: [BlinkAssistantBackend.TabRef]) {
    guard !refs.isEmpty else {
      let alert = UIAlertController(title: "没找到 tab", message: "本机和 peer 都没有 cc-* session", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "好", style: .default))
      present(alert, animated: true)
      return
    }
    let sheet = UIAlertController(title: "选择要 @ 的 tab", message: nil, preferredStyle: .actionSheet)
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = atButton; pop.sourceRect = atButton.bounds
    }
    // 按机器名分组排序
    let grouped = Dictionary(grouping: refs) { $0.machine }
    let machines = grouped.keys.sorted()
    for m in machines {
      for ref in grouped[m]!.sorted(by: { $0.tab < $1.tab }) {
        let title = "[\(ref.machine)] \(ref.tab)"
        sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
          self?.insertMention(ref)
        })
      }
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    present(sheet, animated: true)
  }

  private func insertMention(_ ref: BlinkAssistantBackend.TabRef) {
    let tag = "@\(ref.machine):\(ref.tab) "
    // 插到 textView 当前文本前面（如果已经有 @ 前缀就替换）
    let current = textView.text ?? ""
    let stripped: String
    if let r = current.range(of: #"^@[^\s]+\s+"#, options: .regularExpression) {
      stripped = String(current[r.upperBound...])
    } else {
      stripped = current
    }
    textView.text = tag + stripped
    textViewDidChange(textView)
    updateSendButtonState()
    textView.becomeFirstResponder()
    // 光标移到末尾
    let end = textView.endOfDocument
    textView.selectedTextRange = textView.textRange(from: end, to: end)
  }

  /// 如果消息以 `@<machine>:<tab> ` 开头，包装成给助手的转发指令
  private func wrapMessageIfMention(_ text: String) -> String {
    guard let r = text.range(of: #"^@([^:\s]+):([^\s]+)\s+"#, options: .regularExpression) else {
      return text
    }
    let tag = String(text[text.startIndex..<r.upperBound])
    let body = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let m = tag.range(of: #"@([^:\s]+):([^\s]+)"#, options: .regularExpression) else { return text }
    let inner = String(tag[m]).dropFirst()  // 去掉 @
    let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return text }
    let machine = String(parts[0])
    let tab = String(parts[1])
    return """
    请把下面这段话作为我的话直接转发给 \(machine) 机器上的 cc 标签 `cc-\(tab)`（如果是 peer，先 ssh 过去；本机就直接 tmux send-keys）。

    转发的内容：
    \(body)

    发完后告诉我：
    1. 发出去了没（有没有报错）
    2. 不用等回执，先告诉我已经发出去；具体回复让我下次来问
    """
  }

  // MARK: 语音识别（复用 VoiceInputView 里的 GLMASRClient + AITextPolisher）

  private func updateMicAppearance() {
    var cfg = UIButton.Configuration.plain()
    let imgName = isAsrRecording ? "mic.fill" : "mic"
    cfg.image = UIImage(systemName: imgName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
    cfg.baseForegroundColor = isAsrRecording ? .systemRed : .systemBlue
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
    micButton.configuration = cfg
  }

  @objc private func micTapped() {
    if isAsrRecording {
      stopAsrRecording()
    } else {
      requestMicPermissionThenRecord()
    }
  }

  private func requestMicPermissionThenRecord() {
    let handler: (Bool) -> Void = { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted else {
          self.flashPlaceholder("麦克风权限被拒绝", isError: true)
          return
        }
        self.beginAsrRecording()
      }
    }
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: handler)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(handler)
    }
  }

  private func beginAsrRecording() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      flashPlaceholder("音频会话失败", isError: true)
      return
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
      flashPlaceholder("录音启动失败", isError: true)
      return
    }
    r.prepareToRecord()
    r.record()
    asrRecorder = r
    asrFileURL = url
    isAsrRecording = true
    updateMicAppearance()
    placeholderLabel.text = "正在听 · 再点麦克风结束"
    placeholderLabel.textColor = .systemRed
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  private func stopAsrRecording() {
    guard isAsrRecording, let r = asrRecorder, let url = asrFileURL else {
      isAsrRecording = false
      updateMicAppearance()
      resetPlaceholder()
      return
    }
    isAsrRecording = false
    r.stop()
    asrRecorder = nil
    asrFileURL = nil
    updateMicAppearance()

    let apiKey = AITextPolisher.shared.apiKey
    guard !apiKey.isEmpty else {
      try? FileManager.default.removeItem(at: url)
      flashPlaceholder("未配置 GLM API key（设置→AI 配置）", isError: true)
      return
    }

    placeholderLabel.text = "识别中…"
    placeholderLabel.textColor = .secondaryLabel
    placeholderLabel.isHidden = !textView.text.isEmpty

    GLMASRClient.transcribe(fileURL: url, apiKey: apiKey) { [weak self] result in
      DispatchQueue.main.async {
        try? FileManager.default.removeItem(at: url)
        guard let self else { return }
        switch result {
        case .success(let raw):
          self.applyAsrResult(raw)
        case .failure(let err):
          self.flashPlaceholder("识别失败: \(err.localizedDescription)", isError: true)
        }
      }
    }
  }

  /// 把 ASR 原文先填进 textView，开 polish；polish 完再覆盖
  private func applyAsrResult(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      resetPlaceholder()
      return
    }
    fillTextView(with: trimmed)
    AITextPolisher.shared.recordHistory(trimmed)

    guard AITextPolisher.shared.enabled, !AITextPolisher.shared.apiKey.isEmpty else {
      resetPlaceholder()
      return
    }
    placeholderLabel.text = "AI 整理中…"
    placeholderLabel.textColor = .secondaryLabel
    placeholderLabel.isHidden = !textView.text.isEmpty
    AITextPolisher.shared.polish(trimmed) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        if case .success(let polished) = result {
          let cleaned = polished.trimmingCharacters(in: .whitespacesAndNewlines)
          if !cleaned.isEmpty {
            AITextPolisher.shared.recordCorrection(asrRaw: trimmed, final: cleaned)
            self.fillTextView(with: cleaned)
          }
        }
        self.resetPlaceholder()
      }
    }
  }

  private func fillTextView(with text: String) {
    textView.text = text
    textViewDidChange(textView)
    updateSendButtonState()
  }

  private func resetPlaceholder() {
    placeholderLabel.text = "跟助手说话…"
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.isHidden = !textView.text.isEmpty
  }

  private func flashPlaceholder(_ msg: String, isError: Bool = false) {
    placeholderLabel.text = msg
    placeholderLabel.textColor = isError ? .systemRed : .secondaryLabel
    placeholderLabel.isHidden = !textView.text.isEmpty
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.resetPlaceholder()
    }
  }

  // MARK: 待处理项回复

  /// 弹一个 sheet：左边显示助手建议、textView 预填同样内容方便改、底部「按建议发」/「取消」
  private func presentPendingReply(for item: BlinkAssistantPending.Item) {
    let vc = PendingReplyEditorViewController(item: item)
    vc.onSend = { [weak self] finalText in
      self?.sendPendingReply(item: item, text: finalText)
    }
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func sendPendingReply(item: BlinkAssistantPending.Item, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // 跟 @ 转发同样的链路：包装成"把这话发给 target tab"
    let machine = item.machine ?? ""
    let display = "@\(machine.isEmpty ? "" : "\(machine):")\(item.target) \(trimmed)"
    let payload: String
    if !machine.isEmpty {
      payload = """
      请把下面这段话作为我的话直接转发给 \(machine) 机器上的 cc 标签 `cc-\(item.target)`（peer 先 ssh 过去；本机直接 tmux send-keys）。

      转发的内容：
      \(trimmed)

      发完后告诉我：发出去了没（报错的话告诉我），不用等回执。
      """
    } else {
      payload = """
      请把下面这段话作为我的话直接转发给本机 cc 标签 `cc-\(item.target)`（tmux send-keys）。

      转发的内容：
      \(trimmed)

      发完告诉我：发出去了没。
      """
    }
    runSend(display: display, payload: payload)
  }

  // MARK: 巡检行点击 → 让助手给这位员工拍板

  /// 点了巡检列表里的某个员工 → 让助手针对 ta 当前最阻塞的事输出一张决策卡（DECISION）
  private func requestDecision(forPatrolItem item: BlinkAssistantPatrol.Item) {
    guard !isSending else { return }
    let stateLines = item.projects.prefix(6).map { p -> String in
      var line = "- \(p.name): \(p.desc)"
      if let w = p.waitingFor, !w.isEmpty { line += "（等 \(w)）" }
      return line
    }.joined(separator: "\n")

    let display = "给 \(item.employee) 拍板"
    let payload = """
    我点了员工「\(item.employee)」想给 ta 拍板。请**只输出一张决策卡**（用 <<<DECISION>>>{json}<<<END_DECISION>>> 格式），针对 ta 当前最需要我拍板 / 最阻塞的那一件事，给 2-3 个我能直接点的选项（label 要短、能直接执行）。decision 的 target 写 ta 对应的 tab customTitle，machine 写 ta 所在机器。

    \(item.employee) 现在的状态：
    \(stateLines)

    如果 ta 现在没有需要我拍板的事，就用一句话告诉我「\(item.employee) 暂时不用拍板」，别硬编决策。
    """
    runSend(display: display, payload: payload)
  }

  // MARK: 决策卡片回调

  private func handleDecisionPicked(at row: Int, option: BlinkAssistantDecision.DecisionOption) {
    guard row < messages.count, !isSending else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    // 1) 把这个气泡的 decision 清掉，避免重复点
    messages[row].decision = nil
    tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)

    // 2) 拼回给助手的文本
    var payload = "【用户已选择】\(option.label)（key=\(option.key)）"
    if option.isAlways == true {
      payload += "\n\n请把这条规则追加到 ~/.blink/permissions.md（带今天的日期 + 一行描述用户允许了什么），以后遇到同类决策先 Read 这个文件，命中就直接执行，别再弹决策卡了。"
    }

    // 3) 走正常的发送链路（用户气泡显示用户的选择）
    runSend(display: option.label, payload: payload)
  }

  /// 抽出 sendTapped 的实际发送逻辑，方便决策卡片复用
  private func runSend(display: String, payload: String) {
    textView.text = ""
    placeholderLabel.isHidden = false
    textViewDidChange(textView)
    updateSendButtonState()
    textView.resignFirstResponder()

    appendMessage(BlinkAssistantMessage(role: .user, text: display))
    appendMessage(BlinkAssistantMessage(role: .assistant, text: "", isLoading: true))
    let loadingIdx = messages.count - 1
    var loadingPending = true
    var turnAssistantIndices: [Int] = []

    isSending = true
    Task {
      defer { self.isSending = false }
      do {
        try await BlinkAssistantBackend.shared.sendStreaming(payload) { [weak self] event in
          guard let self else { return }
          switch event {
          case .text(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let newMsg = BlinkAssistantMessage.assistant(text: trimmed, turnRole: .intermediate)
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: newMsg)
              turnAssistantIndices.append(loadingIdx)
              loadingPending = false
            } else {
              let appendIdx = self.messages.count
              self.appendMessage(newMsg)
              turnAssistantIndices.append(appendIdx)
            }
          case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let lastIdx = turnAssistantIndices.last {
              self.markAsFinal(at: lastIdx)
            } else if loadingPending {
              self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "（远端没回任何输出）"))
            }
          case .error(let s):
            self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: s))
          }
        }
      } catch {
        await MainActor.run {
          self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "出错了: \(error.localizedDescription)"))
        }
      }
    }
  }

  @objc private func sendTapped() {
    let display = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !display.isEmpty, !isSending else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    // @<machine>:<tab> 前缀 → 包装成给助手的转发指令；用户气泡仍显示原文
    let payload = wrapMessageIfMention(display)

    textView.text = ""
    placeholderLabel.isHidden = false
    textViewDidChange(textView)
    updateSendButtonState()
    textView.resignFirstResponder()

    appendMessage(BlinkAssistantMessage(role: .user, text: display))
    // loading 占位先放着，第一条 .text 进来就替换它
    appendMessage(BlinkAssistantMessage(role: .assistant, text: "", isLoading: true))
    let loadingIdx = messages.count - 1
    var loadingPending = true
    var turnAssistantIndices: [Int] = []  // 本轮所有 assistant 气泡下标

    isSending = true
    Task {
      defer { self.isSending = false }
      do {
        try await BlinkAssistantBackend.shared.sendStreaming(payload) { [weak self] event in
          guard let self else { return }
          switch event {
          case .text(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let newMsg = BlinkAssistantMessage.assistant(text: trimmed, turnRole: .intermediate)
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: newMsg)
              turnAssistantIndices.append(loadingIdx)
              loadingPending = false
            } else {
              let appendIdx = self.messages.count
              self.appendMessage(newMsg)
              turnAssistantIndices.append(appendIdx)
            }
          case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "（这轮没文本输出）"))
              loadingPending = false
            } else if let lastIdx = turnAssistantIndices.last {
              // 把这一轮最后一条 assistant 提成 .final（变 ✅ 总结图标）
              self.markAsFinal(at: lastIdx)
            }
          case .error(let e):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if loadingPending {
              self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: e))
              loadingPending = false
            } else {
              self.appendMessage(BlinkAssistantMessage(role: .system, text: e))
            }
          }
        }
      } catch {
        await MainActor.run {
          UINotificationFeedbackGenerator().notificationOccurred(.error)
          if loadingPending {
            self.replaceMessage(at: loadingIdx, with: BlinkAssistantMessage(role: .system, text: "出错了：\(error.localizedDescription)"))
          } else {
            self.appendMessage(BlinkAssistantMessage(role: .system, text: "出错了：\(error.localizedDescription)"))
          }
        }
      }
    }
  }

  private func scrollToBottom(animated: Bool) {
    guard !messages.isEmpty else { return }
    let last = IndexPath(row: messages.count - 1, section: 0)
    tableView.scrollToRow(at: last, at: .bottom, animated: animated)
  }
}

extension BlinkAssistantChatViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
  func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = tv.dequeueReusableCell(withIdentifier: BlinkAssistantBubbleCell.reuseId, for: ip) as! BlinkAssistantBubbleCell
    cell.configure(with: messages[ip.row])
    cell.onDecision = { [weak self] option in
      self?.handleDecisionPicked(at: ip.row, option: option)
    }
    cell.onPendingTap = { [weak self] item in
      self?.presentPendingReply(for: item)
    }
    cell.onPatrolTap = { [weak self] item in
      self?.requestDecision(forPatrolItem: item)
    }
    cell.onLongPress = { [weak self] text in
      UIPasteboard.general.string = text
      let banner = UILabel()
      banner.text = "已复制"
      banner.textColor = .white
      banner.font = .systemFont(ofSize: 13, weight: .medium)
      banner.textAlignment = .center
      banner.backgroundColor = UIColor.black.withAlphaComponent(0.78)
      banner.layer.cornerRadius = 14
      banner.layer.masksToBounds = true
      banner.alpha = 0
      banner.translatesAutoresizingMaskIntoConstraints = false
      self?.view.addSubview(banner)
      if let v = self?.view {
        NSLayoutConstraint.activate([
          banner.centerXAnchor.constraint(equalTo: v.centerXAnchor),
          banner.centerYAnchor.constraint(equalTo: v.centerYAnchor),
          banner.widthAnchor.constraint(equalToConstant: 80),
          banner.heightAnchor.constraint(equalToConstant: 28),
        ])
      }
      UIView.animate(withDuration: 0.2, animations: { banner.alpha = 1 }) { _ in
        UIView.animate(withDuration: 0.3, delay: 0.6, options: [], animations: { banner.alpha = 0 }) { _ in
          banner.removeFromSuperview()
        }
      }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    return cell
  }
}

extension BlinkAssistantChatViewController: UITextViewDelegate {
  func textViewDidChange(_ tv: UITextView) {
    placeholderLabel.isHidden = !tv.text.isEmpty
    let size = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .infinity))
    let h = max(38, min(140, size.height))
    if abs(textViewHeightConstraint.constant - h) > 0.5 {
      textViewHeightConstraint.constant = h
    }
    tv.isScrollEnabled = (size.height > 140)
    updateSendButtonState()
  }
  func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if text == "\n" {
      sendTapped()
      return false
    }
    return true
  }
}

// MARK: - 待处理项回复编辑器（sheet）

final class PendingReplyEditorViewController: UIViewController, UITextViewDelegate {
  private let item: BlinkAssistantPending.Item
  var onSend: ((String) -> Void)?

  private let headerLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let suggestionTitleLabel = UILabel()
  private let suggestionBox = UITextView()
  private let editorTitleLabel = UILabel()
  private let editorTextView = UITextView()
  private let editorPlaceholder = UILabel()

  init(item: BlinkAssistantPending.Item) {
    self.item = item
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "回复 \(item.target)"
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                        target: self, action: #selector(cancelTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "发送", style: .done,
                                                         target: self, action: #selector(sendTapped))

    headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    headerLabel.textColor = .label
    headerLabel.text = item.machine.map { "\(item.target) · \($0)" } ?? item.target

    subtitleLabel.font = .systemFont(ofSize: 14)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 0
    var sub = item.title
    if let ctx = item.context, !ctx.isEmpty { sub += "\n\(ctx)" }
    subtitleLabel.text = sub

    suggestionTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    suggestionTitleLabel.textColor = .secondaryLabel
    suggestionTitleLabel.text = "助手建议回复"

    suggestionBox.font = .systemFont(ofSize: 14)
    suggestionBox.textColor = .label
    suggestionBox.isEditable = false
    suggestionBox.isSelectable = true
    suggestionBox.backgroundColor = .secondarySystemBackground
    suggestionBox.layer.cornerRadius = 10
    suggestionBox.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    suggestionBox.text = item.suggestedReply ?? "（助手没给建议，自己写吧）"

    editorTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    editorTitleLabel.textColor = .secondaryLabel
    editorTitleLabel.text = "你要发的内容（可改）"

    editorTextView.font = .systemFont(ofSize: 15)
    editorTextView.textColor = .label
    editorTextView.backgroundColor = .secondarySystemBackground
    editorTextView.layer.cornerRadius = 10
    editorTextView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    editorTextView.text = item.suggestedReply ?? ""
    editorTextView.delegate = self
    editorTextView.keyboardDismissMode = .interactive

    editorPlaceholder.font = .systemFont(ofSize: 15)
    editorPlaceholder.textColor = .placeholderText
    editorPlaceholder.text = "在这里写你想发的内容…"
    editorPlaceholder.isHidden = !(editorTextView.text ?? "").isEmpty

    for v: UIView in [headerLabel, subtitleLabel, suggestionTitleLabel, suggestionBox,
                      editorTitleLabel, editorTextView, editorPlaceholder] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }

    NSLayoutConstraint.activate([
      headerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

      subtitleLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
      subtitleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),

      suggestionTitleLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
      suggestionTitleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),

      suggestionBox.topAnchor.constraint(equalTo: suggestionTitleLabel.bottomAnchor, constant: 6),
      suggestionBox.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
      suggestionBox.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
      suggestionBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
      suggestionBox.heightAnchor.constraint(lessThanOrEqualToConstant: 160),

      editorTitleLabel.topAnchor.constraint(equalTo: suggestionBox.bottomAnchor, constant: 16),
      editorTitleLabel.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),

      editorTextView.topAnchor.constraint(equalTo: editorTitleLabel.bottomAnchor, constant: 6),
      editorTextView.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
      editorTextView.trailingAnchor.constraint(equalTo: headerLabel.trailingAnchor),
      editorTextView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
      editorTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

      editorPlaceholder.topAnchor.constraint(equalTo: editorTextView.topAnchor, constant: 10),
      editorPlaceholder.leadingAnchor.constraint(equalTo: editorTextView.leadingAnchor, constant: 16),
    ])
  }

  func textViewDidChange(_ textView: UITextView) {
    editorPlaceholder.isHidden = !(textView.text ?? "").isEmpty
  }

  @objc private func cancelTapped() { dismiss(animated: true) }

  @objc private func sendTapped() {
    let text = (editorTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    dismiss(animated: true) { [weak self] in
      self?.onSend?(text)
    }
  }
}
