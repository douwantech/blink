import SwiftUI
import AVFoundation
import WatchKit

enum Screen { case home, broadcast, reading, sent }

// 腕上助手：轮询 Mac relay 拿真数据 → TTS 播报 → 你回决定 → 真打回 tmux。
@MainActor
final class Assistant: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  @Published var screen: Screen = .home
  @Published var queue: [Msg] = []
  @Published var cur: Msg = Msg.demo()
  @Published var speaking = false
  @Published var showChips = false
  @Published var showInput = false
  @Published var sentInstruction = ""
  @Published var bcTag = "助手播报中"
  @Published var now = Date()
  @Published var connected = false
  @Published var sending = false
  @Published var diag = "启动中…"

  private let synth = AVSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var advToken = 0
  private var announced = Set<String>()   // 已播报过的会话 id，避免重复打扰
  private var clock: Timer?

  override init() {
    super.init()
    synth.delegate = self
    clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.now = Date() }
    }
    startPolling()
  }

  var pendingText: String {
    if !connected { return "连接中…" }
    return queue.isEmpty ? "都处理完了" : "\(queue.count) 个标签在等你"
  }

  // MARK: 轮询
  func startPolling() {
    Task { [weak self] in
      while true {
        await self?.poll()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }
  }

  func poll() async {
    diag = "探测入口…"
    guard let items = await Relay.fetch() else {
      connected = false
      diag = "连不上: \(RelayConfig.lastErr)"
      return
    }
    connected = true
    diag = "OK · \(RelayConfig.base ?? "?")"
    let msgs = items.map(Msg.init(item:))
    queue = msgs
    // 有没在忙的时候，把第一条没播过的推上来
    if screen == .home, !speaking {
      if let m = msgs.first(where: { !announced.contains($0.sid) }) {
        broadcast(m)
      }
    }
  }

  // MARK: 播报（优先在线自然人声，失败回落系统合成）
  func speakMsg(_ m: Msg) {
    stopAll()
    speaking = true
    let my = advToken
    Task {
      var b = RelayConfig.base
      if b == nil { b = await RelayConfig.resolveBase() }
      if let base = b,
         let sid = m.sid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
         let url = URL(string: "\(base)/audio?token=\(RelayConfig.token)&id=\(sid)") {
        do {
          var req = URLRequest(url: url); req.timeoutInterval = 25
          let (data, resp) = try await URLSession.shared.data(for: req)
          guard my == advToken else { return }               // 期间切了消息就丢弃
          if (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 200 {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
            return
          }
        } catch { /* 落到本地合成 */ }
      }
      if my == advToken { fallbackSpeak(m.speak) }
    }
  }

  // 系统合成兜底
  func fallbackSpeak(_ text: String) {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try? AVAudioSession.sharedInstance().setActive(true)
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    u.rate = AVSpeechUtteranceDefaultSpeechRate
    speaking = true
    synth.speak(u)
  }

  func stopAll() {
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    player?.stop(); player = nil
    speaking = false
  }
  func stopSpeak() { stopAll() }

  private func onSpeakFinished() {
    speaking = false
    guard screen == .broadcast else { return }
    bcTag = "播报完了 · 看看？"
    let my = advToken
    Task {
      try? await Task.sleep(nanoseconds: 1_300_000_000)
      if my == advToken, screen == .broadcast { openReading() }
    }
  }

  nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    Task { @MainActor in onSpeakFinished() }
  }
  nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully f: Bool) {
    Task { @MainActor in onSpeakFinished() }
  }

  // MARK: 流程
  func broadcast(_ m: Msg) {
    cur = m
    announced.insert(m.sid)
    advToken += 1
    bcTag = m.urgent ? "助手播报 · 有点急" : "助手播报中"
    screen = .broadcast
    WKInterfaceDevice.current().play(.notification)
    speakMsg(m)
  }

  func openReading() {
    advToken += 1; stopSpeak(); showChips = false
    screen = .reading
  }

  func goHome() {
    advToken += 1; stopSpeak(); showChips = false
    screen = .home
  }

  func replayBroadcast() { speakMsg(cur) }

  // 回写真指令到 tmux
  func dispatch(_ instr: String) {
    guard !instr.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    sentInstruction = instr
    showChips = false; showInput = false
    sending = true
    let sid = cur.sid
    Task {
      let ok = await Relay.reply(id: sid, text: instr)
      sending = false
      if ok {
        queue.removeAll { $0.sid == sid }
        announced.remove(sid)
        screen = .sent
        WKInterfaceDevice.current().play(.success)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let f = queue.first { broadcast(f) } else { goHome() }
      } else {
        WKInterfaceDevice.current().play(.failure)
      }
    }
  }

  func refresh() { Task { await poll() } }
}
