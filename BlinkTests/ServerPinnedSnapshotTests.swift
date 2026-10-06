import XCTest

@testable import Blink

/// 服务器共享书签 → 客户端这一跳的契约测试：快照带 `pinned` 就是权威（数组顺序即
/// 后台展示顺序），不带就保持本地清单不动（老缓存/离线兜底）。
final class ServerPinnedSnapshotTests: XCTestCase {
  private let snapshotWithPinned = """
  {"version":"7:3","machines":[],"tabs":{"version":1,"tabs":[]},"recentSelection":{},"agents":{},
   "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false},
   "pinned":[{"id":"one.test","title":"一号后台","url":"https://one.test/admin","authUser":"ops","authPassword":"s3cret"},
             {"id":"two.test","title":"二号后台","url":"https://two.test/"}]}
  """

  private let snapshotWithEmptyPinned = """
  {"version":"7:4","machines":[],"tabs":{"version":1,"tabs":[]},"recentSelection":{},"agents":{},
   "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false},"pinned":[]}
  """

  /// 老缓存快照（本次改动之前写下的那份）没有 pinned 字段。
  private let legacySnapshot = """
  {"version":"1:1","machines":[],"tabs":{"version":1,"tabs":[]},"recentSelection":{},"agents":{},
   "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false}}
  """

  private func decode(_ json: String) throws -> ServerSnapshot {
    try JSONDecoder().decode(ServerSnapshot.self, from: Data(json.utf8))
  }

  private func temporaryDefaults() throws -> UserDefaults {
    let name = "ServerPinnedSnapshotTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func testSnapshotCarriesSharedBookmarksInServerOrder() throws {
    let pinned = try XCTUnwrap(try decode(snapshotWithPinned).pinned)
    XCTAssertEqual(pinned.map(\.url), ["https://one.test/admin", "https://two.test/"])
    XCTAssertEqual(pinned.map(\.title), ["一号后台", "二号后台"])
    XCTAssertEqual(pinned.first?.authUser, "ops")
    XCTAssertEqual(pinned.first?.authPassword, "s3cret")
    XCTAssertNil(pinned.last?.authUser, "没配认证的条目不该被塞上空凭据")
  }

  func testSnapshotWithoutPinnedLeavesTheLocalListAlone() throws {
    XCTAssertNil(try decode(legacySnapshot).pinned, "老快照缺 pinned 时必须解成 nil，而不是空数组")
  }

  func testEmptySharedListIsAuthoritative() throws {
    let pinned = try XCTUnwrap(try decode(snapshotWithEmptyPinned).pinned)
    XCTAssertTrue(pinned.isEmpty, "服务器明确给了空数组：管理员清空了后台列表")
  }

  func testApplyingSnapshotFeedsTheBrowserPinnedList() throws {
    let defaults = try temporaryDefaults()
    let pinned = try XCTUnwrap(try decode(snapshotWithPinned).pinned)
    ServerPinnedStore.apply(pinned, to: defaults)

    let data = try XCTUnwrap(defaults.data(forKey: ServerPinnedStore.defaultsKey))
    let stored = try JSONDecoder().decode([PinnedTab].self, from: data)
    XCTAssertEqual(stored.map(\.title), ["一号后台", "二号后台"])
    XCTAssertEqual(stored.map(\.url), ["https://one.test/admin", "https://two.test/"])
    XCTAssertEqual(stored.first?.authUser, "ops")
    XCTAssertNil(stored.last?.authPassword)
  }

  func testEmptySharedListClearsTheLocalList() throws {
    let defaults = try temporaryDefaults()
    let pinned = try XCTUnwrap(try decode(snapshotWithPinned).pinned)
    ServerPinnedStore.apply(pinned, to: defaults)
    ServerPinnedStore.apply(try XCTUnwrap(try decode(snapshotWithEmptyPinned).pinned), to: defaults)

    let data = try XCTUnwrap(defaults.data(forKey: ServerPinnedStore.defaultsKey))
    XCTAssertEqual(try JSONDecoder().decode([PinnedTab].self, from: data), [])
  }

  func testStoreWritesTheKeyTheBrowserActuallyReads() throws {
    XCTAssertEqual(ServerPinnedStore.defaultsKey, "PinnedTabsStore.tabs")
    let defaults = try temporaryDefaults()
    ServerPinnedStore.apply([PinnedTab(title: "只有一个", url: "https://solo.test/", authUser: nil, authPassword: nil)], to: defaults)
    // PinnedTabsStore 读的是 UserDefaults.standard；这里换一套 defaults 只验证编码格式，
    // 真正读 standard 的那条路径由 key 名一致来保证。
    let data = try XCTUnwrap(defaults.data(forKey: "PinnedTabsStore.tabs"))
    XCTAssertEqual(try JSONDecoder().decode([PinnedTab].self, from: data).first?.url, "https://solo.test/")
  }
}
