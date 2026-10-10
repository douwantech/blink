import Foundation

/// 假网络复现 Tom 点名的那条时序（#101 review）：
///   voice POST 悬挂 → 期间用户改了休息开关 / agents → POST 返回 →
///   个人改动**仍待上传**，并在下一轮**真的发出去**。
///
/// 跑的是产品代码同一份 `VoiceSyncCore.runUpload`（app 侧只把 `post` 换成 URLSession、
/// `uploadPersonalIfNeeded` 换成真实上传），所以测的是产品路径而不是布尔公式。
/// 不连生产、不真机。
@main struct VoiceSyncCoreTests {

  /// 逃逸闭包要改的可变状态。
  final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
  }

  /// 宿主（iOS ServerConfigSync）侧状态：`dirty` 对应 `BlinkServer.personalDirty`。
  final class Host {
    var dirty = false
    var personalUploads: [[String: String]] = []
    var postCalls = 0
  }

  static func waitFor(_ label: String, _ condition: @escaping () -> Bool) async {
    for _ in 0..<3000 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    fatalError("timed out waiting for \(label)")
  }

  static func main() async {
    let suiteName = "BlinkVoiceSyncTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let account = VoiceInputAccount(defaults: defaults)

    account.prepareAccount("alice")
    account.adopt(AccountVoiceInput(favorites: ["old"]), username: "alice")
    account.perform("addFavorite", text: "new favorite")
    precondition(account.pending(username: "alice").count == 1)

    let core = VoiceSyncCore(account: account)
    let host = Host()
    let started = Box(false)
    let release = Box(false)

    // 假网络：voice POST 先挂住，等宿主放行再返回。响应头 13 = 那一刻服务端的个人版本真值。
    let post: ([AccountVoiceOperation]) async throws -> (AccountVoiceInput, String?) = { ops in
      host.postCalls += 1
      started.value = true
      while !release.value { try? await Task.sleep(nanoseconds: 1_000_000) }
      var doc = AccountVoiceInput(favorites: ["old"])
      for op in ops { doc.apply(op) }
      return (doc, "13")
    }

    // 一轮 = 宿主 uploadVoiceInput 做的事：把 dirty 镜像进 core，然后跑共享序列。
    func pass() async -> VoiceSyncCore.Outcome {
      core.pendingPersonal = host.dirty
      return await core.runUpload(
        username: "alice",
        activeRefreshes: 0,
        uploading: false,
        pending: { account.pending(username: "alice") },
        uploadPersonalIfNeeded: {
          host.personalUploads.append(["restSessions": "tom"])
          host.dirty = false
        },
        post: post,
        acknowledge: { ops, doc, _ in
          account.acknowledge(ops, remote: doc, username: "alice")
        })
    }

    // ① POST 悬挂
    let first = Task { await pass() }
    await waitFor("voice POST to start") { started.value }
    // ② 期间用户改了休息开关 / agents（dirty 置位）
    host.dirty = true
    // ③ POST 返回
    release.value = true
    let firstOutcome = await first.value
    precondition(firstOutcome == .uploaded("13"), "POST 返回后应记为 uploaded")
    precondition(host.dirty, "voice POST 在途期间的个人改动必须仍是待上传状态")
    precondition(host.personalUploads.isEmpty, "这一轮还没到推送个人改动的时机")
    precondition(account.snapshot.favorites == ["old", "new favorite"])

    // ④ 下一轮：个人改动真的发出去
    let secondOutcome = await pass()
    precondition(secondOutcome == .empty)
    precondition(host.personalUploads.count == 1, "个人改动必须在下一轮真的发出去")
    precondition(host.personalUploads[0]["restSessions"] == "tom")
    precondition(!host.dirty)
    precondition(host.postCalls == 1, "没有待发操作就不再 POST")

    // ⑤ runUpload 里用响应头（"13"）推的下限：在途 GET 带着旧收藏 7:12 回来也采纳不了
    precondition(!account.adopt(AccountVoiceInput(favorites: ["old"]), version: "7:12", username: "alice"),
                 "a late in-flight snapshot older than the header floor must not be adopted")
    precondition(account.snapshot.favorites == ["old", "new favorite"])

    // ⑥ 宿主 apply() 对刚落地那份快照的判定：+1 判定落空（并发/重试）时，
    //    响应头下限也要保住待上传的个人改动。
    precondition(VoiceInputAccount.keepPendingPersonal(
      localDirty: true, snapshotVersion: "7:13", ownVersion: nil, acknowledgedPersonal: 13),
      "the header floor must protect pending personal edits when the +1 rule misses")

    // ⑦ 宿主同步入口的门（iOS syncFromServer 的顺序：先判旧不旧，再写 cache /
    //    更新 appliedVersion / 采纳 rest·agents）。假 cache 就是离线兼底那份文件。
    var offlineCache: (version: String, favorites: [String]) = ("7:13", ["old", "new favorite"])
    var appliedVersion = "7:13"
    var adoptedAgents = ["old-agent"]
    var appliedSnapshots = 0

    func hostApply(version: String, favorites: [String], agents: [String]) {
      // ← 这一行是产品代码（VoiceInputAccount.isStaleSnapshot），其余是同序的假宿主
      //   （真实宿主在这道门之后就写 cache / 更新 appliedVersion / adopt()）
      guard !account.isStaleSnapshot(version: version, username: "alice") else { return }
      appliedSnapshots += 1
      offlineCache = (version, favorites)
      appliedVersion = version
      adoptedAgents = agents
    }

    // 在途 GET / 乱序回包带着旧快照回来：一道都不能进
    hostApply(version: "7:12", favorites: ["old"], agents: ["stale-agent"])
    precondition(appliedSnapshots == 0, "旧快照不能进采纳路径")
    precondition(appliedVersion == "7:13", "旧快照不许回退 appliedVersion")
    precondition(offlineCache.favorites == ["old", "new favorite"], "离线缓存不能倒退")
    precondition(adoptedAgents == ["old-agent"], "旧快照不许采纳 rest/agents")

    // 正常前进的快照照旧采纳
    hostApply(version: "7:14", favorites: ["old", "new favorite", "other"], agents: ["new-agent"])
    precondition(appliedSnapshots == 1)
    precondition(appliedVersion == "7:14")
    precondition(offlineCache.favorites == ["old", "new favorite", "other"])
    precondition(adoptedAgents == ["new-agent"])

    // ⑧ 有 refresh 在途：让位并重排，不能把待发队列丢掉
    account.perform("recordHistory", text: "typed while refresh in flight")
    precondition(account.pending(username: "alice").count == 1)
    let deferred = await core.runUpload(
      username: "alice", activeRefreshes: 1, uploading: false,
      pending: { account.pending(username: "alice") },
      uploadPersonalIfNeeded: {},
      post: post,
      acknowledge: { _, _, _ in })
    precondition(deferred == .deferred)
    precondition(host.postCalls == 1, "让位时不能真的发 POST")
    precondition(account.pending(username: "alice").count == 1, "让位不能把待发队列丢掉")

    print("PASS: in-flight voice POST → personal edit stays pending → actually re-sent; header floor + defer; host stale-snapshot/cache gate")
  }
}
