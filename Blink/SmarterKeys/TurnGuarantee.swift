import Foundation

/// 手机端注入消息的「起轮保障」（#27）。
///
/// claude TUI 偶发吞掉注入消息的回车：文字停在幽灵回显位、轮次不启动、transcript
/// 不落，用户看着发出去了实际石沉大海（2026-10-03 两例：Jack MBP 空 Enter 可救、
/// xiaobai 机空 Enter 无效只能 C-u 清行重打）。
///
/// 检测：数 PTY 输出字节。起轮必有持续的 spinner / 气泡重绘，幽灵态则注入文本的
/// 回显流完后完全静止。两种判据（真机 E2E 实测教训，见各函数注释）：
/// - 阶段 0「静默窗」：settle 让这轮写入的回显流完并清零，观察窗里看「回显之后
///   还有没有新东西」——起轮 spinner = 有，普通 shell 快命令 / 幽灵态 = 无；
/// - 补偿后「累计回应」：从补偿动作写出起累计一切回应、中途不清零——普通 shell
///   对空 `\r` 至少回一个新提示符，幽灵态对补偿完全无字节。
/// blinkd 会话回显要过 tailnet 往返（实测 RTT 150ms 量级），settle 取 0.6s 覆盖
/// 回显路径；窗口 0.8s 里起轮 spinner 必有字节。
///
/// 补偿两层：先补一记回车（多数有效），仍静止再 C-u 清行 + 重打原文 + 回车。
/// 全失败回调 onGiveUp 让 UI 提示用户手动重发。
///
/// 已知边界（接受，均有注释或工单可查）：
/// - 斜杠命令（/rewind /compact …）不保障：它们弹的是静态菜单，渲染完窗口内同样
///   静止，补回车会把菜单选项直接确认掉——比丢一条命令更糟；
/// - 普通 shell 里跑长静默命令（sleep）时发消息，层 2 理论上可能重发一次——claude
///   起轮必产 spinner 字节不会误触发，本保障守护的正是 claude 场景。
final class TurnGuarantee {
  static let shared = TurnGuarantee()

  /// 阶段 0 判活阈值：幽灵态在干净窗口里是绝对 0 字节，阈值只防迟到回显尾巴
  /// （慢链路上注入文本的回显可能拖进观察窗），宁小勿大（起轮 spinner 一帧就超标）。
  private let threshold = 60
  /// 补偿后判活阈值：普通 shell 对层 1 的 `\r` 回「换行 + 新提示符」≈12 字节，
  /// 8 能稳稳盖住；幽灵态对补偿动作完全无字节。
  private let liveThreshold = 8
  /// 干预后的静默等待：让这轮写入本身的回显/重绘先流完再清零计数。
  private let settle = 0.6
  /// 观察窗长度：起轮后 spinner 持续重绘，窗内必有字节。
  private let window = 0.8

  private var accum = 0
  private let lock = NSLock()
  private var workItem: DispatchWorkItem?
  private weak var device: TermDevice?
  private var onGiveUp: (() -> Void)?
  private var generation = 0   // 新一次 begin 让旧观察链全部作废

  private init() {}

  /// 注入文本写入 PTY 后立刻调（文本与第一记 0.18s 回车由调用方发，这里只管
  /// 观察与补偿）。同一时刻只有一条观察链在跑，用户连发时自动作废旧链。
  func begin(device: TermDevice, text: String, onGiveUp: @escaping () -> Void) {
    finish()   // 作废可能还在跑的旧链
    if text.hasPrefix("/") {
      return   // 斜杠命令弹静态菜单，补回车会确认菜单选项，宁可不保障
    }
    generation &+= 1
    let gen = generation
    self.device = device
    self.onGiveUp = onGiveUp
    lock.lock(); accum = 0; lock.unlock()

    device.onPTYOutput = { [weak self] count in
      guard let self else { return }
      self.lock.lock(); self.accum += Int(count); self.lock.unlock()
    }

    func bytes() -> Int { lock.lock(); defer { lock.unlock() }; return accum }
    func mark() { lock.lock(); accum = 0; lock.unlock() }
    /// 主线程排下一步；gen 不匹配说明已被新 begin 取代，整条链静默终止。
    func after(_ delay: TimeInterval, _ step: @escaping () -> Void) {
      let w = DispatchWorkItem {
        guard gen == self.generation else { return }
        step()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
      workItem = w
    }
    /// 阶段 0 判活：settle 让这轮写入的回显流完并清零，观察窗里看「回显之后
    /// 还有没有新东西」。起轮的 spinner 持续重绘 = 有；普通 shell 的快命令执行
    /// 完就静默、幽灵态不重绘 = 无。有 = 收工，无 = 走补偿。
    func observeQuiet(then next: @escaping () -> Void) {
      after(settle) {
        mark()
        after(self.window) { [weak self] in
          guard let self else { return }
          if bytes() >= self.threshold { self.finish(); return }
          next()
        }
      }
    }
    /// 补偿后判活：从补偿动作写出起累计它换来的一切回应，settle 中途**不**清零。
    /// 补偿的回应是短促的一次性回显（普通 shell 对层 1 的 `\r` 至少回一个新
    /// 提示符 ≈12 字节）——清零再开窗会把它整个吃掉、把活链路判死（真机 E2E
    /// 实测的翻车点：普通 shell 命令被执行两遍）。幽灵态对补偿则完全无字节。
    func observeEcho(then next: @escaping () -> Void) {
      mark()   // 补偿字节尚未产生，先清上一窗残响
      after(settle + window) { [weak self] in
        guard let self else { return }
        if bytes() >= self.liveThreshold { self.finish(); return }
        next()
      }
    }

    // 阶段 0：注入文本 + 0.18s 回车都已写出，先纯观察一轮。
    observeQuiet { [weak self] in
      guard let self, let d = self.device else { return }
      d.write("\r")                       // 层 1：补一记回车（多数情况这就能救活）
      observeEcho { [weak self] in
        guard let self, let d = self.device else { return }
        d.write("\u{15}")                 // 层 2：C-u 清行 + 重打原文 + 回车
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          guard gen == self.generation, let d = self.device else { return }
          d.write(text)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard gen == self.generation, let d = self.device else { return }
            d.write("\r")
          }
        }
        observeEcho { [weak self] in
          self?.finish(gaveUp: true)      // 两层都没救活：提示用户手动重发
        }
      }
    }
  }

  private func finish(gaveUp: Bool = false) {
    workItem?.cancel()
    workItem = nil
    device?.onPTYOutput = nil
    generation &+= 1   // 让仍在飞的零散 asyncAfter 全部失效
    let cb = onGiveUp
    onGiveUp = nil
    if gaveUp, let cb {
      DispatchQueue.main.async { cb() }
    }
  }
}
