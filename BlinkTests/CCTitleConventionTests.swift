import Foundation
import XCTest

@testable import Blink

/// ccTitle 三端统一约定（2026-10-05，iOS / 鸿蒙 / Mac 同步明确）：
/// tab 带 tmuxSession 就是权威会话名，sanitize 后原样返回，绝不拼目录/用户名前缀。
/// 回归背景：服务器快照不下发 workDirs（那是 KV 时代本地表），新装设备本地查不到
/// tab 的 workDirId 时 dirBasename 退化到 SSH 用户名——brain 的 user=app，手机点
/// tom-blink 去找 cc-app-tom-blink，tmux new-session -A 又建了个空会话。
/// （blinkd 通道按枚举名直连不踩坑，只有 SSH 通道暴露。）
final class CCTitleConventionTests: XCTestCase {
  /// brain 的 user=app，正是踩坑机器：修复前它会让 tom-blink 变 app-tom-blink
  private let brain = BlinkMachine(host: "47.237.122.99", user: "app")

  /// 老板真机场景：服务器 tab 带 workDirId，但本机 workDirs 表查不到（快照不下发）。
  /// 修复前此断言为红（返回 "app-tom-blink"）——它是本回归的 mutation 检查方向。
  func testTmuxSessionIsAuthoritativeWhenWorkDirUnresolvable() {
    XCTAssertEqual(
      BlinkMachineStore.ccTitle(machine: brain, workDirId: "wd-not-on-this-device", tmuxSession: "tom-blink"),
      "tom-blink",
      "带 tmuxSession 的 tab 必须原样用会话名，不得拼 user/workDir 前缀")
  }

  func testTmuxSessionIsAuthoritativeWithoutWorkDir() {
    XCTAssertEqual(
      BlinkMachineStore.ccTitle(machine: brain, workDirId: nil, tmuxSession: "tom-blink"),
      "tom-blink")
  }

  /// 权威名同样过 sanitize：小写、空格转 -、去引号（与连接命令 cc-<title> 的注入安全一致）
  func testTmuxSessionIsSanitized() {
    XCTAssertEqual(
      BlinkMachineStore.ccTitle(machine: brain, workDirId: nil, tmuxSession: "Tom Blink"),
      "tom-blink")
    XCTAssertEqual(
      BlinkMachineStore.ccTitle(machine: brain, workDirId: nil, tmuxSession: "a\"b"),
      "ab")
  }

  /// tmuxSession 为空（本地新建 tab 还没指定会话）保留本地生成规则：
  /// session 缺省 blink、workDir 查不到时 basename 退化 user → <user>-blink
  func testLocalGenerationStillUsesUserFallback() {
    XCTAssertEqual(
      BlinkMachineStore.ccTitle(machine: brain, workDirId: nil, tmuxSession: nil),
      "app-blink")
  }

  func testLocalGenerationWithUnknownWorkDirId() {
    let out = BlinkMachineStore.ccTitle(
      machine: brain, workDirId: "ABCDEF12-3456-7890-ABCD-EF1234567890", tmuxSession: nil)
    XCTAssertTrue(out.hasPrefix("app-blink-"), "本地生成应为 <user>-blink-<wid8>，实际 \(out)")
  }
}
