import Foundation

/// 用系统 `/usr/bin/ssh` 在远端跑一条命令并收集输出（枚举会话 / 探测状态用）。
///
/// BlinkMac 不带 SSH 库——但 Mac 本身就是台真电脑，有 ssh 客户端和用户 ~/.ssh 里的密钥/agent。
/// 用 BatchMode=yes：能免密就跑，不能就立刻失败（不弹密码卡住），调用方回退 KV 里手机配的标签。
enum SSHExec {
    /// 非交互执行，返回 stdout。连不上 / 无免密 / 超时 → 空串。
    static func run(user: String, host: String, command: String, timeout: TimeInterval = 8) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let target = user.isEmpty ? host : "\(user)@\(host)"
            // 命令(含单引号)base64 传，远端解码跑；经登录 shell(-lc)起 ssh 才拿得到 SSH_AUTH_SOCK(agent)。
            let b64 = Data(command.utf8).base64EncodedString()
            let remote = "echo \(b64) | base64 -d | bash"
            let sshCmd = "exec /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=6 "
                + "-o StrictHostKeyChecking=accept-new -T \(target) '\(remote)'"
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-lc", sshCmd]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = Pipe()   // 吞掉 stderr，别混进输出

            let lock = NSLock()
            var finished = false
            func finish(_ s: String) {
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if already { return }
                cont.resume(returning: s)
            }
            p.terminationHandler = { _ in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                finish(String(decoding: data, as: UTF8.self))
            }
            do { try p.run() } catch { finish(""); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}
