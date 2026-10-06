import SwiftUI
import AppKit

/// 设置窗（Cmd-,）：权限、触发键、识别语言、AI 整理开关。
///
/// 2026-10-06 收窄（对齐 iOS #22 `a581e685`）：**只留开关，不留参数编辑** ——
/// GLM 的 Key / 模型 / Base URL 由服务器下发（`VoiceServerConfigSync` 的
/// `applySharedEngineConfig` 只写不读走，本机 UserDefaults 里的存量值仍是未登录时的兜底），
/// 「我的词表」也退成只读计数（学习与上传链路一个字没动）。
/// **删过的东西别再往设置页加回来**：改参数 = 改服务器，不是改这里。
struct SettingsView: View {
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
                Text("登录后由服务器下发模型与 Key（见「账号同步」）；未登录只走苹果本地识别。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("账号同步") {
                TextField("账号", text: $serverUser)
                SecureField("密码", text: $serverPassword)
                HStack { Button("登录并同步") { VoiceServerConfigSync.shared.login(username: serverUser, password: serverPassword) { result in DispatchQueue.main.async { serverStatus = (try? result.get()) == nil ? "登录失败" : "已同步" } } }; Text(serverStatus).font(.caption).foregroundColor(.secondary) }
                Text("登录后从服务器读取公共语音模型、API key、词表；离线继续使用本机配置。").font(.caption).foregroundColor(.secondary)
            }

            // 只读计数（对齐 iOS「个人纠正词 (N)」）：词表由语音自动积累 + 三端共享同步，
            // 没有手工编辑入口了。
            Section("我的词表") {
                Text("已学习 \(LearningStore.shared.allTermPairs().count) 个错词 · 随语音自动积累")
                    .font(.callout)
                Text("喂给系统识别器（从源头少听错）+ 转写后本地直接替换，不开 GLM 也管用。这份词表和手机 / 鸿蒙共用一份（~/.blink/sync/blink_config.json），一端学到的，其他端下次同步自动带上。")
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
            // 这一行同时是 TERMTEST 的「视图真求值过」证据（见 App.swift）。
            Diag.log("SettingsView 出现：已学习 \(LearningStore.shared.allTermPairs().count) 个错词")
        }
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
