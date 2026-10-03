////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// #27 起轮保障端到端测试（真机 + 真 blinkd）。
//
// 不 mock 任何一层：BlinkdSession 真连 Mac 端 daemon（--exec 帧起独立 zsh，
// 不碰用户的 tmux/claude 会话），SmartKeys 注入路径照抄 SmarterTermInput
// .didCommitText 的写法（write(text) + 0.18s 回车 + TurnGuarantee.begin）。
// 命令落 Mac 侧 ~/.tg_e2e_count，测试跑完后在 Mac 上 `wc -l` 断言执行遍数：
// 正常路径 = 1 遍（观察窗判活、不补刀）；补偿链误触发 = ≥2 遍。
//
////////////////////////////////////////////////////////////////////////////////

import XCTest

@testable import Blink

final class TurnGuaranteeE2ETests: XCTestCase {

  /// 主 runloop 友好的 sleep：TurnGuarantee 的补偿链全部排在 main queue，
  /// 用 Thread.sleep 会把 runloop 卡死、整条链冻住，必须用 expectation 挂等。
  private func tgWait(_ seconds: TimeInterval) {
    let exp = expectation(description: "wait \(seconds)s")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
    wait(for: [exp], timeout: seconds + 5)
  }

  func testTurnGuaranteeE2EOnRealBlinkd() throws {
    // 真机 app 里已配置的 blinkd 机器（前会话配置，会话列表里的 claude 会话就靠它）
    guard
      let machine = BlinkMachineStore.shared.currentMachine,
      let cfg = machine.blinkdConfig
    else {
      throw XCTSkip("真机未配置 blinkd 机器，跳过（模拟器 / 无配置环境不适用本 E2E）")
    }

    // 独立 zsh PTY：不进 tmux / claude，注入的命令只落计数文件，不污染用户会话
    let zshScript = "exec zsh -i"
    let zshB64 = Data(zshScript.utf8).base64EncodedString()
    let connectArgs = "blinkd \(cfg.host) \(cfg.port) \(cfg.token) --exec \(zshB64)"

    let device = TermDevice()
    guard let session = BlinkdSession(device: device, andParams: nil) else {
      throw XCTSkip("BlinkdSession 创建失败")
    }

    // 等连接 ready：attach 回放 / zsh 提示符的第一批字节到达才算活链路
    // （LAN 回落 Tailscale 可能要 ~10s，盲等固定秒数会把命令写进未连上的管道）。
    // executeAttachedWithArgs 内部 pthread_join 会阻塞调用线程直到会话结束，
    // 必须丢后台线程跑，主线程留着跑 runloop / TurnGuarantee 的 main queue 链。
    let firstByte = expectation(description: "blinkd 首批输出到达")
    device.onPTYOutput = { _ in firstByte.fulfill() }
    DispatchQueue.global().async {
      session.executeAttached(withArgs: connectArgs)
    }
    wait(for: [firstByte], timeout: 25)
    device.onPTYOutput = nil
    tgWait(1)

    // 清掉上一轮（可能存在的）计数文件：直接写，不走 TurnGuarantee，不干扰被测对象
    device.write("rm -f ~/.tg_e2e_count")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { device.write("\r") }
    tgWait(1.5)

    // === 被测注入：与 SmarterTermInput.didCommitText 同款时序 ===
    let mark = "TG\(Int(Date().timeIntervalSince1970))"
    let text = "echo \(mark) >> ~/.tg_e2e_count"
    var gaveUp = false
    device.write(text)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { device.write("\r") }
    TurnGuarantee.shared.begin(device: device, text: text) {
      gaveUp = true
    }

    // 全补偿链时序 ≈ 4.5s（settle+窗口 ×3 + 层2 两段延时），等到 9s 全部落定
    tgWait(9)

    // 正常路径：zsh 对注入命令有回显与输出，观察窗判活，不应走到 giveUp。
    // （补偿链是否误重发不在手机侧断言——Mac 上 `grep <mark> ~/.tg_e2e_count
    //  | wc -l` == 1 才是只跑一遍的铁证，== 2 说明层 2 误触发重打。）
    XCTAssertFalse(gaveUp, "正常起轮被判死走到了 giveUp —— 补偿链误判")

    // 留给 Mac 侧核查的标记：跑完后 `grep <mark> ~/.tg_e2e_count | wc -l`
    print("TG_E2E_MARK=\(mark)")

    // 不调 session.kill()：kill 会 fclose device 拥有的 _stream.in，pollLoop
    // 随后 feof() 已释放的 FILE* 是 use-after-free（真机上实测即崩）。测试自然
    // 结束、device 释放即拆链路。
    _ = session
  }
}
