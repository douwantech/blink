import XCTest

@testable import Blink

/// 设置页收窄口径（2026-10-06）的回归测试。三件事：①唯一的设置页只剩老板点名的那几段；
/// ②「个人纠正词」页只剩两节、没有词表编辑；③删 UI 不伤链路 —— 词表的**学习与上传**
/// 照旧（`termsPayload` / `replaceTerms` / `PUT /v1/config/voice-corrections`）。
///
/// 这套测试的价值在「删过的东西不会再回来」：谁要是把 AI 配置编辑器、词表编辑或实验段
/// 加回设置页，这里会红。
final class SettingsLayoutTests: XCTestCase {

  private func sections(username: String? = "alice",
                        aiEnabled: Bool = true,
                        autoReconnect: Bool = true,
                        corrections: Int = 3,
                        machine: (user: String, host: String)? = (user: "root", host: "10.0.0.9"),
                        workDirCount: Int = 2,
                        language: String = "中文（普通话）") -> [SettingsSection] {
    SettingsLayout.sections(username: username, aiEnabled: aiEnabled, autoReconnect: autoReconnect,
                            corrections: corrections, machine: machine,
                            workDirCount: workDirCount, language: language)
  }

  // MARK: - ① 唯一的设置页只剩点名的那几段

  func testSectionsAreExactlyTheNarrowedSet() throws {
    XCTAssertEqual(sections().map(\.title),
                   ["账号", "语音", "个人纠正词", "键盘快捷键", "机器", "工作目录", "识别语言", "关于与支持"])
    XCTAssertEqual(SettingsLayout.titles,
                   ["账号", "语音", "个人纠正词", "键盘快捷键", "机器", "工作目录", "识别语言", "关于与支持"])
  }

  func testEveryLabelThatWasCutIsGone() throws {
    let labels = sections().flatMap { $0.rows.map(\.label) }

    // 老板拍板删掉的：引擎参数、词表编辑、实验段。
    for gone in ["AI 配置", "AI 历史 / 修正 / 词表", "高频错读词表", "清空词表",
                 "测试 GLM-ASR", "测试 Whisper"] {
      XCTAssertFalse(labels.contains(gone), "「\(gone)」不该再出现在设置页上")
    }
    // 段名里也不能再出现「实验」。
    XCTAssertFalse(sections().contains { $0.title.contains("实验") })

    // 「切换机器条」：浮动机器条随标签坞掉头一起移除后，这个开关不再控制任何东西，
    // 留一个按了没反应的开关比没有更糟 —— 别再让它回到设置页（Mac 看的是 rail，与它无关）。
    XCTAssertFalse(labels.contains("切换机器条"), "浮动机器条已移除，这个开关不该再出现")
    XCTAssertFalse(SettingsToggle.allCases.contains { $0.rawValue == "machineBar" })
  }

  func testSurvivingRowsKeepTheirBehaviour() throws {
    let all = sections()
    XCTAssertEqual(all[0].rows, [.account(username: "alice"), .logout])
    XCTAssertEqual(all[1].rows, [.toggle(.ai, isOn: true)])
    XCTAssertEqual(all[2].rows, [.personalCorrections(count: 3)])
    XCTAssertEqual(all[3].rows, [.shortcuts])
    XCTAssertEqual(all[4].rows, [.machine(user: "root", host: "10.0.0.9"),
                                 .toggle(.autoReconnect, isOn: true)])
    XCTAssertEqual(all[5].rows, [.workDirs(count: 2)])
    XCTAssertEqual(all[6].rows, [.language(title: "中文（普通话）")])
    XCTAssertEqual(all[7].rows, [.about])
  }

  func testLoggedOutAccountSectionOffersLoginOnly() throws {
    let account = sections(username: nil)[0]
    XCTAssertEqual(account.title, "账号")
    XCTAssertEqual(account.rows, [.login])
    // 用户名是空串（历史数据里出现过）也按未登录处理。
    XCTAssertEqual(sections(username: "")[0].rows, [.login])
  }

  func testRowsThatPushAndRowsThatDoNot() throws {
    XCTAssertEqual(sections().flatMap { $0.rows }.filter(\.pushes),
                   [.personalCorrections(count: 3), .shortcuts,
                    .machine(user: "root", host: "10.0.0.9"), .workDirs(count: 2),
                    .language(title: "中文（普通话）"), .about])
    XCTAssertFalse(SettingsRow.account(username: "alice").pushes)
    XCTAssertFalse(SettingsRow.logout.pushes)
    XCTAssertFalse(SettingsRow.toggle(.ai, isOn: false).pushes)
  }

  func testRowLabelsAndDetails() throws {
    XCTAssertEqual(SettingsRow.account(username: "alice").detail, "alice")
    XCTAssertEqual(SettingsRow.personalCorrections(count: 7).detail, "7 对")
    XCTAssertEqual(SettingsRow.workDirs(count: 0).detail, "0 个")
    XCTAssertEqual(SettingsRow.machine(user: "root", host: "10.0.0.9").detail, "root@10.0.0.9")
    XCTAssertEqual(SettingsRow.machine(user: "", host: "").detail, "未配置", "没配机器时显示未配置")
    XCTAssertEqual(SettingsRow.language(title: "—").detail, "—", "识别语言显示不出来时保留占位符")
    XCTAssertEqual(SettingsRow.toggle(.ai, isOn: true).label, "AI 整理")
    XCTAssertEqual(SettingsRow.shortcuts.label, "键盘快捷键")
  }

  func testToggleTagsMatchTheirIndex() throws {
    // 开关行靠 tag 找回自己是哪个开关（cellForRowAt 里写 tag，toggleSwitched 里读回来）。
    XCTAssertEqual(SettingsToggle.allCases, [.ai, .autoReconnect])
    for (i, t) in SettingsToggle.allCases.enumerated() {
      XCTAssertEqual(SettingsToggle.allCases.firstIndex(of: t), i)
    }
  }

  // MARK: - ② 个人纠正词页只剩两节

  func testPersonalCorrectionsPageHasNoTermSection() throws {
    XCTAssertEqual(PersonalCorrectionsSection.allCases.map(\.title), ["提交记录", "整句修正对"])
    let copy = (PersonalCorrectionsSection.allCases.map(\.title)
                + PersonalCorrectionsSection.allCases.map(\.footer)).joined()
    XCTAssertFalse(copy.contains("词表"), "词表那节的标题与说明文案都不该还在")
    XCTAssertTrue(copy.contains("整句修正对"))
    XCTAssertTrue(PersonalCorrectionsSection.corrections.footer.contains("修正习惯"),
                  "整句修正对的说明保留")
  }

  // MARK: - ③ 删 UI 不伤链路：词表照旧学习 + 回传

  func testTermPayloadSurvivesAndReplaceTermsStillWorks() throws {
    let polisher = AITextPolisher.shared
    let before = polisher.termsPayload
    defer { polisher.replaceTerms(before) }   // 别把真实 UserDefaults 留脏

    polisher.replaceTerms(["对账": ["对帐": 2]])
    XCTAssertEqual(polisher.termsPayload, ["对账": ["对帐": 2]])
    XCTAssertEqual(polisher.termEntries.first?.wrong, "对账",
                   "termEntries 仍是 polish prompt 的只读数据源")

    polisher.replaceTerms([:])
    XCTAssertTrue(polisher.termsPayload.isEmpty)
  }

  func testThePayloadTheUploaderSendsIsStillTheLearnedTable() throws {
    // 回传链路读的就是 `AITextPolisher.shared.termsPayload`（`ServerConfigSync.uploadPersonal`
    // 里 ("voice-corrections", …) 那一条读它），形状必须是 错词 → { 对词: 频次 }。
    // 删掉的只是手工编辑入口，这里钉住链路本身。
    let polisher = AITextPolisher.shared
    let before = polisher.termsPayload
    defer { polisher.replaceTerms(before) }   // 别把真实 UserDefaults 留脏

    polisher.replaceTerms(["对账": ["对帐": 2], "jira": ["JIRA": 1]])
    let body = try JSONEncoder().encode(polisher.termsPayload)
    XCTAssertEqual(try JSONDecoder().decode([String: [String: Int]].self, from: body),
                   ["对账": ["对帐": 2], "jira": ["JIRA": 1]])
    XCTAssertTrue(try XCTUnwrap(String(data: body, encoding: .utf8)).contains("对帐"))
  }
}
