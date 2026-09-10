import Foundation

/// 轻量调试日志，追加到 ~/Library/Caches/voicekey-debug.log。
/// 语音 app 在别人机器上没法边说边看，出问题只能靠日志复盘。
enum Diag {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("voicekey-debug.log")
    }()

    private static let q = DispatchQueue(label: "voicekey.diag")
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ msg: String) {
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        q.async {
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
