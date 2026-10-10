import Foundation

/// 收藏上传的时序核心（Foundation-only，不依赖 UIKit/SwiftUI/AppKit）。
///
/// 抽出来只有一个目的：**能用假网络把真实时序跑起来**。这类 bug 全在「谁先谁后」上，
/// 只测布尔公式证明不了 —— 例如「voice POST 悬挂 → 期间改了休息开关 / agents →
/// POST 返回 → 个人改动仍待上传，并在下一轮真的发出去」。app 侧
/// （iOS `ServerConfigSync.uploadVoiceInput` / Mac `ServerSync.uploadVoiceInput`）
/// 调用的就是这个 `runUpload`，所以测它 = 测产品路径。
///
/// 三件事：
///  1. **让位**：有 refresh 在途或自己正在上传时不发，交给宿主重排（不能丢）；
///  2. **版本下限**：用**有效响应头** `X-Personal-Version` 推进已见下限
///     （`VoiceInputAccount.noteAcknowledged`），比下限旧的快照一律不采纳；
///  3. **上传序列**：先推未上传的个人改动（休息开关 / agents）再 POST，拿到响应后
///     记下限并 ack。
final class VoiceSyncCore {
  static let shared = VoiceSyncCore()

  /// 宿主状态：个人配置（休息开关 / agents …）是否有未上传改动。
  /// 只做时序、不读 UserDefaults，所以由宿主在每轮开跑前镜像进来。
  var pendingPersonal: Bool = false

  /// 队列与已见版本下限的唯一真源（账号隔离、落盘）。
  private let account: VoiceInputAccount

  init(account: VoiceInputAccount = .shared) { self.account = account }

  enum Gate: Equatable { case go, deferToHost }
  enum Outcome: Equatable { case uploaded(String?), empty, deferred, failed }

  /// 收藏上传现在能不能发。在途 refresh / 正在上传都让位（宿主负责重排，不丢）。
  func gate(activeRefreshes: Int, uploading: Bool) -> Gate {
    if uploading { return .deferToHost }
    return activeRefreshes > 0 ? .deferToHost : .go
  }

  /// `"7:12"` → 12。
  static func personalComponent(_ version: String?) -> UInt64? {
    guard let parts = version?.split(separator: ":"), parts.count == 2 else { return nil }
    return UInt64(parts[1])
  }

  /// 响应头 `X-Personal-Version` 是裸数字 —— 那一刻服务端的个人版本真值。
  static func personalFromHeader(_ header: String?) -> UInt64? {
    guard let header else { return nil }
    return UInt64(header.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 真实的收藏上传序列。`pending` / `uploadPersonalIfNeeded` / `post` / `acknowledge`
  /// 由调用方注入：app 用 URLSession + 真实上传，测试用假网络。
  ///
  /// `post` 返回 `(服务器文档, X-Personal-Version 响应头)`。版本下限取**响应头真值**，
  /// 不是 previous+1 —— 并发别的设备写入 / 幂等重试时 +1 不成立，但头里的值仍可靠。
  func runUpload(username: String,
                 activeRefreshes: Int,
                 uploading: Bool,
                 pending: () -> [AccountVoiceOperation],
                 uploadPersonalIfNeeded: () async -> Void,
                 post: ([AccountVoiceOperation]) async throws -> (AccountVoiceInput, String?),
                 acknowledge: ([AccountVoiceOperation], AccountVoiceInput, String?) -> Void) async -> Outcome {
    if gate(activeRefreshes: activeRefreshes, uploading: uploading) == .deferToHost {
      return .deferred
    }
    // 先把未上传的个人改动推上去：收藏 POST 会推进个人版本，personal 没站稳会被这版盖掉。
    if pendingPersonal { await uploadPersonalIfNeeded() }
    let ops = pending()
    guard !ops.isEmpty else { return .empty }
    do {
      let (document, personalHeader) = try await post(ops)
      account.noteAcknowledged(personalHeader: personalHeader, username: username)
      acknowledge(ops, document, personalHeader)
      return .uploaded(personalHeader)
    } catch {
      return .failed
    }
  }
}
