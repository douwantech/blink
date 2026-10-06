import SwiftUI
import AppKit

/// 设置窗（Cmd-,）：权限、触发键、识别语言、GLM 后端。
struct SettingsView: View {
    @State private var apiKey = AITextPolisher.shared.apiKey
    @State private var model = AITextPolisher.shared.model
    @State private var baseURL = AITextPolisher.shared.baseURL
    @State private var aiEnabled = AITextPolisher.shared.enabled
    @State private var localeID = DictationController.shared.localeID
    @State private var inputUID = DictationController.shared.selectedInputUID
    @State private var devices = DictationController.inputDevices()
    @State private var globeOn = HotkeyMonitor.shared.globeEnabled
    @State private var optSpaceOn = HotkeyMonitor.shared.optSpaceEnabled
    @State private var axTrusted = AccessibilityPermission.isTrusted
    @State private var serverUser = ""
    @State private var serverPassword = ""
    @State private var serverStatus = ""

    // 我的词表（行内可编辑）。id 用一次性 UUID：编辑中 wrong/right 变了 id 不变，
    // 行不重建、焦点不丢；count 只在重拉时刷新。
    private struct TermRow: Identifiable {
        let id = UUID()
        var wrong: String
        var right: String
        var count: Int
    }
    @State private var rows: [TermRow] = []
    @State private var newWrong = ""
    @State private var newRight = ""

    private let locales: [(String, String)] = [
        ("zh-CN", "中文（普通话）"),
        ("en-US", "English (US)"),
        ("ja-JP", "日本語"),
        ("yue-CN", "粤语"),
    ]

    var body: some View {
        Form {
            Section("权限") {
                HStack {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(axTrusted ? .green : .orange)
                    Text(axTrusted ? "辅助功能：已授权" : "辅助功能：未授权（地球键与自动粘贴需要它）")
                    Spacer()
                    if !axTrusted {
                        Button("去授权") {
                            AccessibilityPermission.prompt()
                            AccessibilityPermission.openSettings()
                        }
                    }
                    Button("刷新") { axTrusted = AccessibilityPermission.isTrusted }
                }
                Text("授权后建议在「系统设置 → 键盘 → 按下🌐键用于」里设成「无操作」，避免地球键同时弹表情。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("触发键") {
                Toggle("地球键 / Fn 🌐 触发听写", isOn: $globeOn)
                    .onChange(of: globeOn) { _, v in HotkeyMonitor.shared.globeEnabled = v }
                Toggle("⌥Space 兜底触发", isOn: $optSpaceOn)
                    .onChange(of: optSpaceOn) { _, v in HotkeyMonitor.shared.optSpaceEnabled = v }
                Text("按一下开始听写，再按一下结束并转写；Esc 取消。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("麦克风") {
                Picker("输入设备", selection: $inputUID) {
                    Text("自动（跳过虚拟声卡）").tag("")
                    ForEach(devices, id: \.uniqueID) { d in
                        Text(d.localizedName + (DictationController.isVirtualDevice(d) ? "（虚拟）" : "")).tag(d.uniqueID)
                    }
                }
                .onChange(of: inputUID) { _, v in DictationController.shared.selectedInputUID = v }
                Button("刷新设备列表") { devices = DictationController.inputDevices() }
                Text("如果录不到声音，多半是默认输入被 BlackHole/Loopback 等虚拟声卡占了，这里手动选你的真麦克风。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("识别语言") {
                Picker("语言", selection: $localeID) {
                    ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: localeID) { _, v in DictationController.shared.localeID = v }
            }

            Section("GLM 后端优化（可选）") {
                Toggle("启用 GLM 精转 + 润色", isOn: $aiEnabled)
                    .onChange(of: aiEnabled) { _, v in AITextPolisher.shared.enabled = v }
                SecureField("智谱 API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, v in AITextPolisher.shared.apiKey = v.trimmingCharacters(in: .whitespacesAndNewlines) }
                TextField("润色模型", text: $model)
                    .onChange(of: model) { _, v in AITextPolisher.shared.model = v }
                TextField("Chat Base URL", text: $baseURL)
                    .onChange(of: baseURL) { _, v in AITextPolisher.shared.baseURL = v }
                Text("不填 Key 也能用——只走苹果本地识别。填了 Key 会额外走智谱 GLM-ASR 精转 + GLM 润色（同音纠错更准）。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("账号同步") {
                TextField("账号", text: $serverUser)
                SecureField("密码", text: $serverPassword)
                HStack { Button("登录并同步") { VoiceServerConfigSync.shared.login(username: serverUser, password: serverPassword) { result in DispatchQueue.main.async { serverStatus = (try? result.get()) == nil ? "登录失败" : "已同步" } } }; Text(serverStatus).font(.caption).foregroundColor(.secondary) }
                Text("登录后从服务器读取公共语音模型、API key、词表；离线继续使用本机配置。").font(.caption).foregroundColor(.secondary)
            }

            Section("我的词表（听成 → 实际想说）") {
                if rows.isEmpty {
                    Text("词表是空的——加几条你常被听错的词，立刻生效。")
                        .font(.callout).foregroundColor(.secondary)
                }
                ForEach($rows) { $row in
                    HStack {
                        TextField("听成", text: $row.wrong)
                            .onChange(of: row.wrong) { old, new in
                                LearningStore.shared.renameTerm(oldWrong: old, newWrong: new, right: row.right)
                            }
                        Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                        TextField("实际想说", text: $row.right)
                            .onChange(of: row.right) { old, new in
                                LearningStore.shared.retargetTerm(wrong: row.wrong, oldRight: old, newRight: new)
                            }
                        Text(row.count > 0 ? "\(row.count) 次" : "—")
                            .font(.caption).foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .help("本地替换命中的次数")
                        Button {
                            LearningStore.shared.removeTerm(wrong: row.wrong, right: row.right)
                            reloadTerms()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("删除这条")
                    }
                }
                HStack {
                    TextField("听成", text: $newWrong)
                    Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                    TextField("实际想说", text: $newRight)
                    Button("加一条") {
                        LearningStore.shared.setTerm(newWrong, right: newRight)
                        newWrong = ""; newRight = ""
                        reloadTerms()
                    }
                    .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty
                              || newRight.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("改完立即生效：① 喂给系统识别器，从源头少听错 ② 转写后本地直接替换，不开 GLM 也管用。首次自带一批常用预置词（蒸鸡→真机、糖床→弹窗…），可删可改。这份词表和手机 / 鸿蒙共用一份（~/.blink/sync/blink_config.json），一端改了，其他端下次同步自动带上。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("学习数据（删 app 也不丢）") {
                Text("\(LearningStore.shared.history.count) 条历史 · \(LearningStore.shared.corrections.count) 条修正 · \(LearningStore.shared.terms.count) 个错词")
                    .font(.callout)
                HStack {
                    Text(LearningStore.shared.storePath)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("在访达显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LearningStore.shared.storePath)])
                    }
                }
                Text("每次语音提交的文字都会记进这个文件，随时间让 GLM 润色更懂你的常用词。存在用户数据目录，卸载 app 不会删。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Text(versionLine).font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
        .onAppear {
            axTrusted = AccessibilityPermission.isTrusted
            reloadTerms()
            Diag.log("SettingsView 出现：词表 \(rows.count) 行")
        }
    }

    private func reloadTerms() {
        rows = LearningStore.shared.allTermPairs().map { TermRow(wrong: $0.wrong, right: $0.right, count: $0.count) }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var t = ""
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            t = " · 构建 " + f.string(from: date)
        }
        return "语音键 v\(short) (\(build))\(t)"
    }
}
