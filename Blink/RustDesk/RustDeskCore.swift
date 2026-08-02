import UIKit

/// RustDesk 核心库的 Swift 封装:一次性初始化 + 事件回调分发。
/// Rust 侧事件经 rd_register_event_cb 的 C 回调进来(Rust 线程),
/// 这里按 port(流 id)分发给各订阅者;字符串在回调内同步拷贝。
final class RustDeskCore {
  static let shared = RustDeskCore()

  /// kind: 0=JSON 事件 1=RGBA 帧(n1=display) 2=Texture 3=流关闭 4=错误
  typealias EventHandler = (_ kind: Int32, _ s: String?, _ n1: Int64, _ n2: Int64) -> Void

  private var inited = false
  private var nextPort: Int64 = 100
  private var handlers: [Int64: EventHandler] = [:]
  private let lock = NSLock()

  private init() {}

  /// 幂等;第一次调用时初始化核心(设备信息、配置目录、全局事件流)。
  func ensureInit() {
    lock.lock()
    let need = !inited
    inited = true
    lock.unlock()
    guard need else { return }

    rd_register_event_cb(rdEventTrampoline)

    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    let devId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    rd_init(devId, UIDevice.current.name, docs, docs)

    // 全局事件流(软件更新提示等,阶段 1 只记日志防止事件堆积)
    let gport = allocPort { kind, s, _, _ in
      if kind == 0, let s { print("[rustdesk global] \(s.prefix(200))") }
    }
    _ = rd_start_global_event_stream(gport, "main")
  }

  /// 分配一个流 port 并注册处理器,返回 port。
  func allocPort(_ handler: @escaping EventHandler) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    nextPort += 1
    handlers[nextPort] = handler
    return nextPort
  }

  func releasePort(_ port: Int64) {
    lock.lock()
    handlers[port] = nil
    lock.unlock()
  }

  fileprivate func dispatch(port: Int64, kind: Int32, s: String?, n1: Int64, n2: Int64) {
    lock.lock()
    let h = handlers[port]
    lock.unlock()
    h?(kind, s, n1, n2)
  }
}

/// C 回调跳板(Rust 线程直呼)。s 在这里立即拷贝成 Swift String。
private func rdEventTrampoline(port: Int64, kind: Int32, s: UnsafePointer<CChar>?, n1: Int64, n2: Int64) {
  let str = s.map { String(cString: $0) }
  RustDeskCore.shared.dispatch(port: port, kind: kind, s: str, n1: n1, n2: n2)
}
