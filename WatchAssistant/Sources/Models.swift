import SwiftUI

// 腕上助手的一条「标签在等你」消息。真数据由 RelayItem 映射而来。
struct Msg: Identifiable, Equatable {
  let id = UUID()
  let sid: String            // tmux 会话 id，回写指令用
  let emp: String
  let proj: String
  let branch: String
  let colorHex: String
  let assist: String         // 助手一句话导语
  let head: String           // 【项目 · 分支】
  let body: String           // 卡点/最后一段话
  let speak: String          // 口语化播报全文（TTS 念这个）
  let chips: [String]        // 快捷回复
  let urgent: Bool

  static func == (a: Msg, b: Msg) -> Bool { a.sid == b.sid }

  private static let palette = ["F5B24A", "7FB2FF", "54D583", "FF8FA0", "C89BFF", "5FE0C6"]
  static func color(for s: String) -> String {
    let h = abs(s.hashValue)
    return palette[h % palette.count]
  }

  init(item: RelayItem) {
    sid = item.id
    emp = item.emp.isEmpty ? "员工" : item.emp
    proj = item.proj
    branch = item.branch
    colorHex = Msg.color(for: item.emp + item.proj)
    assist = item.urgent ? "\(item.emp) 遇到点情况，等你拿主意" : "\(item.emp) 等你拍一下"
    head = item.head
    body = item.body
    speak = item.speak
    chips = item.chips.isEmpty ? ["继续", "先停一下"] : item.chips
    urgent = item.urgent
  }

  // 离线/连不上时的占位演示
  static func demo() -> Msg {
    Msg(item: RelayItem(id: "demo", emp: "jack", proj: "blink", branch: "bin",
                        head: "【blink · bin】", body: "连不上后端，先给你看个样子。",
                        speak: "现在连不上后端。检查一下 Mac 上的 watchrelay 有没有在跑，地址对不对。",
                        chips: ["重试", "看设置"], urgent: false, ts: 0))
  }
}

// 配色（表屏恒黑 + 语义色）
extension Color {
  init(hex: String) {
    let s = Scanner(string: hex)
    var v: UInt64 = 0
    s.scanHexInt64(&v)
    let r = Double((v >> 16) & 0xff) / 255
    let g = Double((v >> 8) & 0xff) / 255
    let b = Double(v & 0xff) / 255
    self.init(red: r, green: g, blue: b)
  }
  static let wTeal  = Color(hex: "4FD6C4")
  static let wAmber = Color(hex: "F5B24A")
  static let wGreen = Color(hex: "54D583")
  static let wInk   = Color(hex: "EEF1F6")
  static let wInk2  = Color(hex: "98A1B2")
  static let wSurf  = Color(hex: "12151C")
  static let wLine  = Color(hex: "262C38")
}
