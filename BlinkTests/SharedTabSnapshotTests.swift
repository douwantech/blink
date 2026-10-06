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
         {"id":"\(sharedA)","machineId":"machine-1","tmuxSession":"alice-alpha","shared":true},
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

  func testPersistingViewportsDropsSharedKeys() throws {
    // `_persistTabsToStore` 用的就是这一刀：屏幕上「公用在前 + 自有在后」的顺序进去，
    // 落到 TabState 的只剩自有，且原顺序不变。
    let ordered = SharedTabLayout.ordered(
      shared: [UUID(uuidString: sharedA)!, UUID(uuidString: sharedB)!, UUID(uuidString: sharedC)!],
      own: [UUID(uuidString: ownA)!, UUID(uuidString: ownB)!])
    let sharedKeys: Set<UUID> = [UUID(uuidString: sharedA)!, UUID(uuidString: sharedB)!, UUID(uuidString: sharedC)!]

    XCTAssertEqual(ordered.count, 5)
    XCTAssertEqual(SharedTabLayout.ownOnly(ordered, sharedKeys: sharedKeys).map { $0.uuidString.lowercased() },
                   [ownA, ownB])
    XCTAssertEqual(SharedTabLayout.ownOnly(ordered, sharedKeys: []).count, 5, "没有公用标签时一刀不切")
  }

  // MARK: - ③ 屏幕顺序与节标题

  func testSharedTabsComeFirstOnScreen() throws {
    let shared = [UUID(uuidString: sharedA)!, UUID(uuidString: sharedB)!]
    let own = [UUID(uuidString: ownA)!]
    XCTAssertEqual(SharedTabLayout.ordered(shared: shared, own: own), shared + own)
  }

  func testRowsLabelBothSectionsWhenBothArePresent() throws {
    let shared = [UUID(uuidString: sharedA)!, UUID(uuidString: sharedB)!]
    let own = [UUID(uuidString: ownA)!, UUID(uuidString: ownB)!]
    let keys = SharedTabLayout.ordered(shared: shared, own: own)
    let rows = SharedTabLayout.rows(keys: keys, sharedKeys: Set(shared))

    XCTAssertEqual(rows.count, 4, "节标题是行上的字段，不该多出额外的行（tag 必须仍等于下标）")
    XCTAssertEqual(rows[0].header, "公用标签 (2)", "第一条公用标签前是公用节标题，且带条数")
    XCTAssertEqual(rows[1].header, nil, "第二条公用标签不再重复标题")
    XCTAssertEqual(rows[2].header, "我的标签", "第一条自有标签前是自有节标题")
    XCTAssertEqual(rows[3].header, nil)
    XCTAssertEqual(rows.map(\.isShared), [true, true, false, false])
  }

  func testRowsAddNoHeadersWhenThereIsNothingToSplit() throws {
    let own = [UUID(uuidString: ownA)!, UUID(uuidString: ownB)!]
    XCTAssertEqual(SharedTabLayout.rows(keys: own, sharedKeys: []),
                   [SharedTabLayout.Row(header: nil, isShared: false),
                    SharedTabLayout.Row(header: nil, isShared: false)],
                   "只有自有标签时不插任何标题，跟改动前一样")

    let shared = [UUID(uuidString: sharedA)!]
    XCTAssertEqual(SharedTabLayout.rows(keys: shared, sharedKeys: Set(shared)),
                   [SharedTabLayout.Row(header: nil, isShared: true)],
                   "只有公用标签时也不插标题")
  }
}
