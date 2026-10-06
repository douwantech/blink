import XCTest

@testable import Blink

/// 标签坞「员工 × 机器」筛选模型（`SharedTabFilter` / `SharedTabFilterModel`）的契约测试。
/// 这一层是纯函数，坞铺什么、滑动能滑到哪、菜单显示什么，全由它决定：
/// ①员工只从 `tmuxSession` 的「员工-项目」前缀解析（服务端给不出结构化 employeeId）；
/// ②没选过 → 默认 tom×brain，该组合为空时退化成不过滤（绝不出现空坞）；
/// ③显式选过的组合照用（尊重 ✓），空结果由坞里的提示行兜底。
final class SharedTabFilterTests: XCTestCase {

  private func machine(_ id: String, _ name: String) -> BlinkMachine {
    BlinkMachine(id: id, name: name, host: "\(name).local", user: "u")
  }

  private let machines = [
    BlinkMachine(id: "m-brain", name: "brain", host: "brain.local", user: "u"),
    BlinkMachine(id: "m-mac", name: "mac", host: "mac.local", user: "u"),
    BlinkMachine(id: "m-jun", name: "Jun", host: "jun.local", user: "u"),
  ]

  private func tab(_ session: String, _ machineId: String) -> SharedTab {
    SharedTab(id: UUID(), machineId: machineId, tmuxSession: session)
  }

  /// 真实形状：tom 在 brain 上 6 条，jack 在 mac 上 2 条，tom 在 mac 上 1 条。
  private lazy var tabs: [SharedTab] = [
    tab("tom-ben", "m-brain"), tab("tom-huum", "m-brain"), tab("tom-lotly", "m-brain"),
    tab("tom-printer", "m-brain"), tab("tom-speakenglish", "m-brain"), tab("tom-talkai", "m-brain"),
    tab("jack-api", "m-mac"), tab("jack-web", "m-mac"),
    tab("tom-notes", "m-mac"),
  ]

  // MARK: - ① 员工解析

  func testEmployeeIsThePrefixBeforeTheFirstDash() {
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: "tom-ben"), "tom")
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: "JACK-API"), "jack", "大小写归一")
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: "tom"), "tom", "没有 '-' 时整段就是员工")
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: "-orphan"), nil, "空前缀不算员工")
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: ""), nil)
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: nil), nil)
  }

  func testEmployeeParseIsApproximateWhenTheEmployeeIdItselfHasADash() {
    // 服务端允许 employeeId 里带 "-"（README「Public tabs」），客户端只能取第一段 ——
    // 这是已知的近似，不是回归。要精确得服务端给每条注入的标签补 employeeId 字段。
    XCTAssertEqual(SharedTabFilterModel.employee(ofTmuxSession: "tom-x-ben"), "tom")
  }

  // MARK: - ② 匹配与可见集合

  func testMatchesHonoursBothDimensions() {
    let byEmployee = SharedTabFilter(employee: "tom", machineId: nil)
    let byMachine = SharedTabFilter(employee: nil, machineId: "m-brain")
    let both = SharedTabFilter(employee: "tom", machineId: "m-brain")
    let none = SharedTabFilter.none

    XCTAssertTrue(SharedTabFilterModel.matches(tmuxSession: "tom-ben", machineId: "m-mac", filter: byEmployee))
    XCTAssertFalse(SharedTabFilterModel.matches(tmuxSession: "jack-api", machineId: "m-mac", filter: byEmployee))
    XCTAssertTrue(SharedTabFilterModel.matches(tmuxSession: "jack-api", machineId: "m-brain", filter: byMachine))
    XCTAssertFalse(SharedTabFilterModel.matches(tmuxSession: "jack-api", machineId: "m-mac", filter: byMachine))
    XCTAssertTrue(SharedTabFilterModel.matches(tmuxSession: "tom-ben", machineId: "m-brain", filter: both))
    XCTAssertFalse(SharedTabFilterModel.matches(tmuxSession: "tom-ben", machineId: "m-mac", filter: both))
    XCTAssertTrue(SharedTabFilterModel.matches(tmuxSession: "whatever", machineId: "m-jun", filter: none))
  }

  func testVisibleKeepsServerOrder() {
    let visible = SharedTabFilterModel.visible(tabs, filter: SharedTabFilter(employee: "tom", machineId: "m-brain"))
    XCTAssertEqual(visible.map(\.tmuxSession),
                   ["tom-ben", "tom-huum", "tom-lotly", "tom-printer", "tom-speakenglish", "tom-talkai"],
                   "老板要的默认那 6 条，顺序跟服务端给的一致")
  }

  func testEmployeeAndMachineListsAreDedupedAndStable() {
    XCTAssertEqual(SharedTabFilterModel.employees(in: tabs), ["tom", "jack"], "首次出现顺序，去重")
    XCTAssertEqual(SharedTabFilterModel.machineIds(in: tabs, machineOrder: machines.map(\.id)),
                   ["m-brain", "m-mac"], "按机器清单顺序，只列真有标签的（Jun 没有）")
    // 机器清单还没同步到的新机器也不能漏
    XCTAssertEqual(SharedTabFilterModel.machineIds(in: [tab("x-y", "m-new")], machineOrder: ["m-brain"]),
                   ["m-new"])
  }

  // MARK: - ③ resolve 的四态

  func testUnsetDefaultsToTomOnBrain() {
    let f = SharedTabFilterModel.resolve(storedEmployee: nil, storedMachineId: nil,
                                         tabs: tabs, machines: machines)
    XCTAssertEqual(f, SharedTabFilter(employee: "tom", machineId: "m-brain"))
  }

  func testUnsetFallsBackToNoFilterWhenTheDefaultComboIsEmpty() {
    // 别的部署/新账号上 tom×brain 可能是空的 —— 那时退化成不过滤，绝不出现空坞。
    let f = SharedTabFilterModel.resolve(storedEmployee: nil, storedMachineId: nil,
                                         tabs: [tab("jack-api", "m-mac")], machines: machines)
    XCTAssertEqual(f, .none)
  }

  func testExplicitAllMeansNoFilter() {
    let f = SharedTabFilterModel.resolve(storedEmployee: SharedTabFilter.allValue,
                                         storedMachineId: SharedTabFilter.allValue,
                                         tabs: tabs, machines: machines)
    XCTAssertEqual(f, .none, "显式「全部」与「没选过」必须分得开")
    XCTAssertEqual(SharedTabFilterModel.visible(tabs, filter: f).count, tabs.count)
  }

  func testExplicitEmptyComboIsHonoured() {
    // 用户自己选的组合哪怕筛出来是空的也照用（尊重菜单里的 ✓），由坞里的提示行兜底。
    let f = SharedTabFilterModel.resolve(storedEmployee: "tom", storedMachineId: "m-jun",
                                         tabs: tabs, machines: machines)
    XCTAssertEqual(f, SharedTabFilter(employee: "tom", machineId: "m-jun"))
    XCTAssertTrue(SharedTabFilterModel.visible(tabs, filter: f).isEmpty)
  }

  func testPartialExplicitChoiceKeepsTheOtherDimensionDefaulted() {
    let f = SharedTabFilterModel.resolve(storedEmployee: nil, storedMachineId: "m-mac",
                                         tabs: tabs, machines: machines)
    XCTAssertEqual(f, SharedTabFilter(employee: "tom", machineId: "m-mac"),
                   "只选过机器时，员工维度仍走默认 tom")
  }

  func testDefaultMachineIsResolvedByNameNotByUUID() {
    XCTAssertEqual(SharedTabFilterModel.defaultMachineId(in: machines), "m-brain")
    XCTAssertEqual(SharedTabFilterModel.defaultMachineId(in: [machine("m-x", "BRAIN")]), "m-x", "名字大小写不敏感")
    XCTAssertNil(SharedTabFilterModel.defaultMachineId(in: [machine("m-y", "other")]))
  }

  func testTitleShowsTheEffectiveFilter() {
    XCTAssertEqual(SharedTabFilterModel.title(.none, machines: machines), "全部")
    XCTAssertEqual(SharedTabFilterModel.title(SharedTabFilter(employee: "tom", machineId: "m-brain"),
                                              machines: machines), "tom @ brain")
    XCTAssertEqual(SharedTabFilterModel.title(SharedTabFilter(employee: "tom", machineId: nil),
                                              machines: machines), "tom @ 全部机器")
  }
}
