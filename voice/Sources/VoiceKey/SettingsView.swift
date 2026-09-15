import SwiftUI

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

            Section {
                Text(versionLine).font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .onAppear { axTrusted = AccessibilityPermission.isTrusted }
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
