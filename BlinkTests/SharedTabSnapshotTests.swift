import XCTest

@testable import Blink

/// 服务端读时注入的全局公用标签（`"shared": true`）在客户端这一跳的契约测试。
/// 三件事必须由这几条测试钉住：①解码边界把公用标签摘出来单独返回；②摘过之后的
/// `TabState` 里再也不含任何公用标签 —— 落盘/上传都从它出发；③屏幕顺序是「公用在前」。
final class SharedTabSnapshotTests: XCTestCase {

  // 服务端下发的公用标签：稳定 UUIDv5 + 机器 + `员工-项目` 会话，没有 workDirId。
  private let sharedA = "11111111-1111-5111-8111-111111111111"
  private let sharedB = "22222222-2222-5222-8222-222222222222"
  private let sharedC = "33333333-3333-5333-8333-333333333333"
  // 账号自己的两个标签。
  private let ownA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private let ownB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  /// 前 3 条 `shared`，后 2 条自有；墓碑里同时点了一个公用 ID 和一个自有 ID。
  private var snapshotWithShared: String {
    """
    {"version":"17:1","machines":[],
     "tabs":{"version":1,
       "tabs":[
         {"id":"\(sharedA)","machineId":"machine-1","tmuxSession":"alice-alpha","workDir":"/Users/apple/Codes/jack","shared":true},
         {"id":"\(sharedB)","machineId":"machine-2","tmuxSession":"bob-beta","shared":true},
         {"id":"\(sharedC)","machineId":"machine-1","tmuxSession":"carol-gamma","shared":true},
         {"id":"\(ownA)","machineId":"machine-9","tmuxSession":"mine-one","selectOnLoad":true},
         {"id":"\(ownB)","machineId":"machine-9","workDirId":"wd-1"}
       ],
       "currentId":"\(ownA)","updatedAt":1759700000.0,
       "closedIds":["\(sharedA)","\(ownB)"]},
     "recentSelection":{},"agents":{},
     "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false}}
    """
  }

  /// 老服务端 / 老缓存：没有任何 `shared` 键。
  private let snapshotWithoutShared = """
  {"version":"16:9","machines":[],
   "tabs":{"version":1,"tabs":[{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","machineId":"m","tmuxSession":"legacy"}]},
   "recentSelection":{},"agents":{},
   "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false}}
  """

  /// 公用条目少了 machineId/tmuxSession（服务端不该发，但防御上必须仍然摘掉）。
  private let snapshotWithIncompleteShared = """
  {"version":"17:2","machines":[],
   "tabs":{"version":1,"tabs":[
     {"id":"44444444-4444-5444-8444-444444444444","shared":true},
     {"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","machineId":"m","tmuxSession":"mine"}]},
   "recentSelection":{},"agents":{},
   "user":{"id":7,"username":"alice","isAdmin":false,"canWrite":false}}
  """

  private func decode(_ json: String) throws -> (snapshot: ServerSnapshot, shared: [SharedTab]) {
    try ServerSnapshotDecoder.decode(Data(json.utf8))
  }

  // MARK: - ① 解码/拆分契约

  func testSharedTabsAreStrippedFromTheSnapshotInServerOrder() throws {
    let decoded = try decode(snapshotWithShared)

    XCTAssertEqual(decoded.snapshot.tabs.tabs.map { $0.id.uuidString.lowercased() }, [ownA, ownB],
                   "公用标签不能留在账号自己的 tab 列表里")
    XCTAssertEqual(decoded.shared.map { $0.id.uuidString.lowercased() }, [sharedA, sharedB, sharedC],
                   "公用标签要按服务端给的顺序单独拿出来")
    XCTAssertEqual(decoded.shared.map(\.machineId), ["machine-1", "machine-2", "machine-1"])
    XCTAssertEqual(decoded.shared.map(\.tmuxSession), ["alice-alpha", "bob-beta", "carol-gamma"])
    XCTAssertEqual(decoded.shared.map(\.workDir), ["/Users/apple/Codes/jack", nil, nil])
  }

  func testOwnTabsSurviveTheStripUntouched() throws {
    let own = try decode(snapshotWithShared).snapshot.tabs.tabs
    XCTAssertEqual(own.first?.tmuxSession, "mine-one")
    XCTAssertEqual(own.last?.workDirId, "wd-1", "自有标签的 workDirId 要原样保留")
    XCTAssertEqual(try decode(snapshotWithShared).snapshot.tabs.currentId?.uuidString.lowercased(), ownA)
  }

  func testSharedIdsAreDroppedFromTheTombstonesButOwnOnesKept() throws {
    let closed = try XCTUnwrap(try decode(snapshotWithShared).snapshot.tabs.closedIds)
    XCTAssertEqual(closed.map { $0.uuidString.lowercased() }, [ownB],
                   "墓碑里点到公用 ID 时是本地误记，必须剔除；自有墓碑照留")
  }

  func testSnapshotWithoutSharedKeyIsUntouched() throws {
    let decoded = try decode(snapshotWithoutShared)
    XCTAssertTrue(decoded.shared.isEmpty)
    XCTAssertEqual(decoded.snapshot.tabs.tabs.count, 1, "老服务端的快照一条都不能少")
  }

  func testIncompleteSharedEntryIsStillStripped() throws {
    // machineId 缺失的条目进不了 sharedTabs（UI 没法绑会话），但也绝不能留在自有列表里 ——
    // 留着就会被落盘并回传，正好是这次要防的污染。
    let decoded = try decode(snapshotWithIncompleteShared)
    XCTAssertTrue(decoded.shared.isEmpty)
    XCTAssertEqual(decoded.snapshot.tabs.tabs.count, 1)
    XCTAssertEqual(decoded.snapshot.tabs.tabs.first?.tmuxSession, "mine")
  }

  // MARK: - ② 回传/落盘不变式

  func testEncodedTabStateCarriesNoTraceOfSharedTabs() throws {
    let state = try decode(snapshotWithShared).snapshot.tabs
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
    let lowercased = json.lowercased()

    for id in [sharedA, sharedB, sharedC] {
      XCTAssertFalse(lowercased.contains(id), "落盘/上传的 TabState 里出现了公用标签 ID")
    }
    for session in ["alice-alpha", "bob-beta", "carol-gamma"] {
      XCTAssertFalse(json.contains(session), "落盘/上传的 TabState 里出现了公用标签的会话名")
    }
    // 自有标签照旧在（别把过滤写成清空）。
    XCTAssertTrue(lowercased.contains(ownA))
    XCTAssertTrue(lowercased.contains(ownB))
  }

  // 客户端这一侧已经没有「落盘前剔公用」的第二道刀了（`_persistTabsToStore` 随自有标签
  // 一起删掉）：红线现在**只有**解码边界这一处守卫，上面 `testSharedTabsAreStrippedFrom-
  // TheSnapshotInServerOrder` 与 `testEncodedTabStateCarriesNoTraceOfSharedTabs` 两条
  // 钉的就是它。要再加落盘路径，必须同时加回这一刀。

  // MARK: - ③ 屏幕顺序与坞里的行

  func testSharedTabsComeFirstOnScreen() throws {
    let shared = [UUID(uuidString: sharedA)!, UUID(uuidString: sharedB)!]
    let own = [UUID(uuidString: ownA)!]
    XCTAssertEqual(SharedTabLayout.ordered(shared: shared, own: own), shared + own)
  }

  func testDockTakesOnlyTomsTabsFromTheSharedList() throws {
    // 老板掉头后的口径（2026-10-06）：坞 = 服务端公用标签里 employee 前缀为 tom 的那几条，
    // 写死常量、不做筛选器。「其余 28 条不上坞」就是这条 —— 它们仍然是注册过的会话
    //（「员工状态 · N 人休息中」要数它们），只是不铺进坞、不进滑动集合。
    let tom = ["tom-ben", "tom-huum", "tom-lotly", "tom-printer", "tom-speakenglish", "tom-talkai"]
    for s in tom {
      XCTAssertTrue(SharedTabLayout.isDockTab(tmuxSession: s), "\(s) 是 tom 的，该上坞")
    }
    for s in ["jack-talkai", "carl-brain", "bob-beta", "alice-alpha"] {
      XCTAssertFalse(SharedTabLayout.isDockTab(tmuxSession: s), "\(s) 不是 tom 的，不该上坞")
    }
    XCTAssertEqual(SharedTabLayout.dockEmployee, "tom", "口径就锁在这个常量上")
  }

  func testDockEmployeeParsingEdges() throws {
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: "tom-ben"), "tom")
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: "TOM-BEN"), "tom", "大小写归一")
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: "tom"), "tom", "没有 '-' 时整段就是员工")
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: "-orphan"), nil, "空前缀不算员工")
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: ""), nil)
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: nil), nil)
    // 近似（见交付说明的边界）：服务端允许 employeeId 自带 '-'，这里会截短。
    XCTAssertEqual(SharedTabLayout.employee(ofTmuxSession: "tom-x-ben"), "tom")
    XCTAssertTrue(SharedTabLayout.isDockTab(tmuxSession: "tom-x-ben"), "截短后仍归到 tom")
  }

  func testDockIsEmptyWhenNothingBelongsToTom() throws {
    // 老板口径「不保留退路」：没有 tom 的标签就是空坞，不拿本地标签顶上、不铺提示行。
    XCTAssertFalse(SharedTabLayout.isDockTab(tmuxSession: "jack-talkai"))
    XCTAssertFalse(SharedTabLayout.isDockTab(tmuxSession: nil))
  }
}
