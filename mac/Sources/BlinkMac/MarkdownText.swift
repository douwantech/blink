import SwiftUI

/// 气泡正文的轻量 Markdown 渲染：块级自己解析（标题 / 列表 / 代码块 / 引用 / 表格 / 分隔线 /
/// 段落），行内（**粗** *斜* `码` [链接]）交给 AttributedString(markdown:)。够覆盖 claude 回复常见格式，
/// 不引第三方库、不破坏构建。
struct MarkdownText: View {
    let raw: String
    var base: Color = Theme.fg

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(MarkdownText.parse(raw)) { blk in
                block(blk)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: 块渲染

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let text):
            inline(text)
                .font(Theme.ui(level <= 1 ? 16 : level == 2 ? 15 : 14, level <= 2 ? .bold : .semibold))
                .foregroundColor(base)
                .padding(.top, 2)
        case .paragraph(let text):
            inline(text).font(Theme.ui(13.5)).foregroundColor(base).lineSpacing(3)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").font(Theme.ui(13.5)).foregroundColor(Theme.sub)
                        inline(it).font(Theme.ui(13.5)).foregroundColor(base).lineSpacing(3)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(i + 1).").font(Theme.mono(12.5)).foregroundColor(Theme.sub)
                        inline(it).font(Theme.ui(13.5)).foregroundColor(base).lineSpacing(3)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(Theme.mono(12)).foregroundColor(Theme.fg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair))
        case .quote(let text):
            inline(text).font(Theme.ui(13.5)).foregroundColor(Theme.sub).lineSpacing(3)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.hair2).frame(width: 2) }
        case .table(let header, let rows):
            // 列用 Grid 对齐；单元格走行内 markdown（**粗** `码` 等）；空表头不显示。
            let cols = max(header.count, rows.map { $0.count }.max() ?? 0)
            let hasHeader = header.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 5) {
                    if hasHeader {
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                inline(c < header.count ? header[c] : "")
                                    .font(Theme.ui(12.5, .semibold)).foregroundColor(base)
                            }
                        }
                        Rectangle().fill(Theme.hair).frame(height: 1).gridCellColumns(cols)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                inline(c < r.count ? r[c] : "")
                                    .font(Theme.ui(12.5)).foregroundColor(base).lineSpacing(2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair))
        case .rule:
            Rectangle().fill(Theme.hair).frame(height: 1).padding(.vertical, 2)
        }
    }

    /// 行内 markdown → Text（**粗** *斜* `码` [文字](链接)）。解析失败退化为纯文本。
    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    // MARK: 块解析

    enum MDBlock: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case ordered([String])
        case code(String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
        var id: String {
            switch self {
            case .heading(_, let t): return "h:" + t
            case .paragraph(let t): return "p:" + String(t.prefix(20)) + "\(t.count)"
            case .bullet(let it): return "b:\(it.count):" + (it.first ?? "")
            case .ordered(let it): return "o:\(it.count):" + (it.first ?? "")
            case .code(let c): return "c:\(c.count):" + String(c.prefix(16))
            case .quote(let t): return "q:" + String(t.prefix(20))
            case .table(let h, let r): return "t:\(h.count):\(r.count)"
            case .rule: return "rule\(UUID().uuidString)"
            }
        }
    }

    static func parse(_ raw: String) -> [MDBlock] {
        let lines = raw.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func hasBullet(_ s: String) -> Range<String.Index>? { s.range(of: #"^[-*+]\s+"#, options: .regularExpression) }
        func hasOrdered(_ s: String) -> Range<String.Index>? { s.range(of: #"^\d+\.\s+"#, options: .regularExpression) }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("```") {
                flush(); i += 1; var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                i += 1
                blocks.append(.code(code.joined(separator: "\n"))); continue
            }
            if t == "---" || t == "***" || t == "___" { flush(); blocks.append(.rule); i += 1; continue }
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = t.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level: min(level, 6), text: String(t[r.upperBound...]))); i += 1; continue
            }
            // 表格：本行含 | 且下一行是分隔行 |---|
            if line.contains("|"), i + 1 < lines.count,
               lines[i + 1].contains("-"),
               lines[i + 1].range(of: #"^\s*\|?[\s:|-]+\|?\s*$"#, options: .regularExpression) != nil {
                flush()
                func cells(_ s: String) -> [String] {
                    var x = s.trimmingCharacters(in: .whitespaces)
                    if x.hasPrefix("|") { x.removeFirst() }
                    if x.hasSuffix("|") { x.removeLast() }
                    return x.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(line); i += 2; var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows)); continue
            }
            if hasBullet(t) != nil {
                flush(); var items: [String] = []
                while i < lines.count {
                    let tt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let r = hasBullet(tt) else { break }
                    items.append(String(tt[r.upperBound...])); i += 1
                }
                blocks.append(.bullet(items)); continue
            }
            if hasOrdered(t) != nil {
                flush(); var items: [String] = []
                while i < lines.count {
                    let tt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let r = hasOrdered(tt) else { break }
                    items.append(String(tt[r.upperBound...])); i += 1
                }
                blocks.append(.ordered(items)); continue
            }
            if t.hasPrefix(">") {
                flush(); var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var tt = lines[i].trimmingCharacters(in: .whitespaces); tt.removeFirst()
                    q.append(tt.trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n"))); continue
            }
            if t.isEmpty { flush(); i += 1; continue }
            para.append(line); i += 1
        }
        flush()
        return blocks
    }
}
