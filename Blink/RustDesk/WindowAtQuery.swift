import Foundation

/// 远端窗口命中测试:SSH 到目标机跑 windowat,拿点(px,py)所在最上层窗口的像素 rect。
/// windowat 源码内嵌在这(base64);首次查询自动上传到 ~/.blink/windowat 并 swiftc 编译,
/// 之后直接跑(几秒编译只在第一次)。目标机需 macOS + 有 swiftc(Xcode/CLT)。
enum WindowAtQuery {
  /// windowat.swift 源码的 base64(见 mac-daemon/windowat/windowat.swift)。
  private static let sourceB64 = "Ly8gd2luZG93YXQg4oCU4oCUIOi/nOerr+eql+WPo+WRveS4rea1i+ivleWKqeaJiyjooqvmjqcgTWFjIOS4iui/kOihjCnjgIIKLy8KLy8g55So6YCUOlJ1c3REZXNrIOWuouaIt+err+eCueS6huWxj+W5leafkOeCuSzmg7PnvKnmlL7liLDpgqPkuKrnqpflj6PjgIJSdXN0RGVzayDljY/orq7kuI3luKbnqpflj6Pkv6Hmga8sCi8vIOaJgOS7peeUsei/nOerr+i3kei/meS4quWKqeaJizrnu5nlrprlg4/ntKDlnZDmoIcs55SoIENHV2luZG93TGlzdCDmib7lh7ror6XngrnmnIDkuIrlsYLnmoTmma7pgJrnqpflj6MsCi8vIOi/lOWbnuWug+eahOi+ueeVjCjlg4/ntKAp44CC5a6i5oi356uv5ou/5YiwIHJlY3Qg5YaN57yp5pS+44CCCi8vCi8vIOeUqOazlTogIHdpbmRvd2F0IDx4X3B4PiA8eV9weD4KLy8g6L6T5Ye6OiAg5ZG95LitIOKGkiB7IngiOi4uLCJ5IjouLiwidyI6Li4sImgiOi4uLCJvd25lciI6Ii4uIiwidGl0bGUiOiIuLiJ9KOWDj+e0oCzlhajlsYDlt6bkuIrljp/ngrkpCi8vICAgICAgICDmnKrlkb3kuK0g4oaSIHt9Ci8vCi8vIOadg+mZkDpDR1dpbmRvd0xpc3Qg55qEIGJvdW5kcy9vd25lciDkuI3pnIDopoHpop3lpJbmnYPpmZA756qX5Y+j5qCH6aKYKHRpdGxlKemcgOimgeWxj+W5leW9leWItuadg+mZkCwKLy8gICAgICBSdXN0RGVzayDooqvmjqfnq6/mnKzmnaXlsLHmnIks5ou/5LiN5Yiw5pe2IHRpdGxlIOeVmeepuuOAgeS4jeW9seWTjSByZWN044CCCgppbXBvcnQgRm91bmRhdGlvbgppbXBvcnQgQ29yZUdyYXBoaWNzCmltcG9ydCBBcHBLaXQKCmxldCBhcmdzID0gQ29tbWFuZExpbmUuYXJndW1lbnRzCmd1YXJkIGFyZ3MuY291bnQgPj0gMywgbGV0IHB4ID0gRG91YmxlKGFyZ3NbMV0pLCBsZXQgcHkgPSBEb3VibGUoYXJnc1syXSkgZWxzZSB7CiAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKERhdGEoInVzYWdlOiB3aW5kb3dhdCA8eF9weD4gPHlfcHg+XG4iLnV0ZjgpKQogIGV4aXQoMikKfQoKLy8gUnVzdERlc2sg5Lyg55qE5piv5YOP57SgO0NHV2luZG93Qm91bmRzIOaYr+eCuShwb2ludCnjgILmjInkuLvlsY8gYmFja2luZ1NjYWxlIOaNoueul+OAggovLyDljZXmmL7npLrlmaggKyDkuLvlsY/lgYforr465aSa5bGP5Y6f54K55YGP56e75pqC5LiN5aSE55CG44CCCmxldCBzY2FsZSA9IE5TU2NyZWVuLm1haW4/LmJhY2tpbmdTY2FsZUZhY3RvciA/PyAyLjAKbGV0IHB0WCA9IHB4IC8gc2NhbGUKbGV0IHB0WSA9IHB5IC8gc2NhbGUKCmxldCBvcHRzOiBDR1dpbmRvd0xpc3RPcHRpb24gPSBbLm9wdGlvbk9uU2NyZWVuT25seSwgLmV4Y2x1ZGVEZXNrdG9wRWxlbWVudHNdCmd1YXJkIGxldCBsaXN0ID0gQ0dXaW5kb3dMaXN0Q29weVdpbmRvd0luZm8ob3B0cywga0NHTnVsbFdpbmRvd0lEKSBhcz8gW1tTdHJpbmc6IEFueV1dIGVsc2UgewogIHByaW50KCJ7fSIpCiAgZXhpdCgwKQp9CgovLyDliJfooajmjInliY3lkI7pobrluo8o5YmN6Z2i55qE5Zyo5pu05LiK5bGCKeOAguWPluesrOS4gOS4qiBsYXllcj09MCjmma7pgJrlupTnlKjnqpflj6Mp5LiU5YyF5ZCr6K+l54K555qE44CCCmZvciB3IGluIGxpc3QgewogIGd1YXJkIGxldCBsYXllciA9IHdba0NHV2luZG93TGF5ZXIgYXMgU3RyaW5nXSBhcz8gSW50LCBsYXllciA9PSAwIGVsc2UgeyBjb250aW51ZSB9CiAgZ3VhcmQgbGV0IGIgPSB3W2tDR1dpbmRvd0JvdW5kcyBhcyBTdHJpbmddIGFzPyBbU3RyaW5nOiBBbnldLAogICAgICAgIGxldCB4ID0gYlsiWCJdIGFzPyBEb3VibGUsIGxldCB5ID0gYlsiWSJdIGFzPyBEb3VibGUsCiAgICAgICAgbGV0IHd3ID0gYlsiV2lkdGgiXSBhcz8gRG91YmxlLCBsZXQgaGggPSBiWyJIZWlnaHQiXSBhcz8gRG91YmxlLAogICAgICAgIHd3ID4gMSwgaGggPiAxIGVsc2UgeyBjb250aW51ZSB9CiAgaWYgcHRYID49IHgsIHB0WCA8PSB4ICsgd3csIHB0WSA+PSB5LCBwdFkgPD0geSArIGhoIHsKICAgIGxldCBvdXQ6IFtTdHJpbmc6IEFueV0gPSBbCiAgICAgICJ4IjogKHggKiBzY2FsZSkucm91bmRlZCgpLAogICAgICAieSI6ICh5ICogc2NhbGUpLnJvdW5kZWQoKSwKICAgICAgInciOiAod3cgKiBzY2FsZSkucm91bmRlZCgpLAogICAgICAiaCI6IChoaCAqIHNjYWxlKS5yb3VuZGVkKCksCiAgICAgICJvd25lciI6IHdba0NHV2luZG93T3duZXJOYW1lIGFzIFN0cmluZ10gYXM/IFN0cmluZyA/PyAiIiwKICAgICAgInRpdGxlIjogd1trQ0dXaW5kb3dOYW1lIGFzIFN0cmluZ10gYXM/IFN0cmluZyA/PyAiIiwKICAgIF0KICAgIGlmIGxldCBkID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBvdXQpIHsKICAgICAgcHJpbnQoU3RyaW5nKGRlY29kaW5nOiBkLCBhczogVVRGOC5zZWxmKSkKICAgIH0KICAgIGV4aXQoMCkKICB9Cn0KCnByaW50KCJ7fSIpCg=="

  struct Rect { let x, y, w, h: CGFloat; let owner: String }

  /// 返回命中窗口的 rect;未命中/失败返回 nil。
  static func query(host: String, user: String, px: Int, py: Int) async -> Rect? {
    // 自包含命令:没编过就写源码+编译,然后跑。stderr 丢弃,只要 stdout 的 JSON。
    let cmd = """
    D="$HOME/.blink"; B="$D/windowat";     [ -x "$B" ] || { mkdir -p "$D"; echo \(sourceB64) | base64 -d > "$B.swift" && swiftc "$B.swift" -o "$B" 2>/dev/null; };     "$B" \(px) \(py) 2>/dev/null
    """
    guard let out = try? await RemoteShell.run(host: host, user: user, command: cmd) else { return nil }
    guard let data = out.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let x = obj["x"] as? Double, let y = obj["y"] as? Double,
          let w = obj["w"] as? Double, let h = obj["h"] as? Double,
          w > 1, h > 1 else { return nil }
    return Rect(x: CGFloat(x), y: CGFloat(y), w: CGFloat(w), h: CGFloat(h),
               owner: obj["owner"] as? String ?? "")
  }
}
