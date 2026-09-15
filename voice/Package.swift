// swift-tools-version: 6.0
import PackageDescription

// 独立的 macOS 语音输入 app：按地球键（Fn/🌐）在任何应用里语音转文字，
// 文字直接粘到当前光标处。纯系统框架（SwiftUI/AppKit/Speech/AVFoundation），
// 无外部依赖。日常开发 `make run`；正式签名版 `make install`（辅助功能/麦克风
// TCC 授权要认签名身份，测试请用 install 的正式版）。
let package = Package(
    name: "VoiceKey",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceKey", targets: ["VoiceKey"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceKey",
            path: "Sources/VoiceKey"
        )
    ],
    swiftLanguageModes: [.v5]
)
