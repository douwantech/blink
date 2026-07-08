import UIKit

final class BlinkMachine: Codable {
  let id: String
  var name: String
  var host: String
  var host2: String?
  var lanHost: String?
  var user: String
  // 连接方式:"ssh" / "blinkd";nil=默认(内置机器走 blinkd,其余走 ssh)。可选,向后兼容旧数据。
  var transport: String?
  // 走 blinkd 时的 daemon 连接信息(daemon 常是独立 tsnet 节点,和上面 host 不同)
  var blinkdHost: String?
  var blinkdPort: Int?
  var blinkdToken: String?

  init(id: String = UUID().uuidString, name: String = "", host: String, host2: String? = nil, lanHost: String? = nil, user: String,
       transport: String? = nil, blinkdHost: String? = nil, blinkdPort: Int? = nil, blinkdToken: String? = nil) {
    self.id = id
    self.name = name
    self.host = host
    self.host2 = host2
    self.lanHost = lanHost
    self.user = user
    self.transport = transport
    self.blinkdHost = blinkdHost
    self.blinkdPort = blinkdPort
    self.blinkdToken = blinkdToken
  }

  var displayName: String {
    name.isEmpty ? "\(user)@\(host)" : name
  }

  // ---- 连接方式判定 ----
  // 内置默认(gitignored xcconfig → Info.plist):哪台机器默认走 blinkd + 它的 daemon 连接信息
  static func blinkdInfoPlist(_ key: String) -> String? {
    guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
          !v.isEmpty, !v.hasPrefix("$(") else { return nil }
    return v
  }
  // 这台机器是否走 blinkd:显式 transport 优先,否则内置默认机器走 blinkd、其余 ssh
  var usesBlinkd: Bool {
    if transport == "blinkd" { return true }
    if transport == "ssh" { return false }
    return name == BlinkMachine.blinkdInfoPlist("BLINKD_AUTO_MACHINE")
  }
  // 走 blinkd 时的连接信息:机器自己配的优先,否则回退内置默认(仅内置机器);都没有则 nil→实际回退 ssh
  var blinkdConfig: (host: String, port: Int, token: String)? {
    guard usesBlinkd else { return nil }
    if let h = blinkdHost, !h.isEmpty, let t = blinkdToken, !t.isEmpty {
      return (h, blinkdPort ?? 7777, t)
    }
    if name == BlinkMachine.blinkdInfoPlist("BLINKD_AUTO_MACHINE"),
       let h = BlinkMachine.blinkdInfoPlist("BLINKD_AUTO_HOST"),
       let t = BlinkMachine.blinkdInfoPlist("BLINKD_AUTO_TOKEN") {
      return (h, Int(BlinkMachine.blinkdInfoPlist("BLINKD_AUTO_PORT") ?? "") ?? 7777, t)
    }
    return nil
  }
}

enum HostReachability {
  private struct Cached { let reachable: Bool; let ts: Date }
  private static var cache: [String: Cached] = [:]
  private static let lock = NSLock()
  private static let ttl: TimeInterval = 30
  static let defaultTimeout: TimeInterval = 0.3

  static func isReachable(host: String, port: UInt16 = 22, timeout: TimeInterval = defaultTimeout) -> Bool {
    let key = "\(host):\(port)"
    let now = Date()
    lock.lock()
    if let c = cache[key], now.timeIntervalSince(c.ts) < ttl {
      lock.unlock()
      return c.reachable
    }
    lock.unlock()
    let ok = probe(host: host, port: port, timeout: timeout)
    lock.lock(); cache[key] = Cached(reachable: ok, ts: now); lock.unlock()
    return ok
  }

  static func invalidate() {
    lock.lock(); cache.removeAll(); lock.unlock()
  }

  private static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
    var hints = addrinfo(
      ai_flags: AI_NUMERICSERV,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
      return false
    }
    defer { freeaddrinfo(res) }
    for ai in sequence(first: first.pointee, next: { $0.ai_next?.pointee }) {
      if tryConnect(ai: ai, timeout: timeout) { return true }
    }
    return false
  }

  private static func tryConnect(ai: addrinfo, timeout: TimeInterval) -> Bool {
    let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
    if fd < 0 { return false }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let r = connect(fd, ai.ai_addr, ai.ai_addrlen)
    if r == 0 { return true }
    if errno != EINPROGRESS { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let n = poll(&pfd, 1, Int32(timeout * 1000))
    if n <= 0 { return false }
    if (pfd.revents & Int16(POLLOUT)) == 0 { return false }
    var sockErr: Int32 = 0
    var len: socklen_t = socklen_t(MemoryLayout<Int32>.size)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &len) < 0 { return false }
    return sockErr == 0
  }
}

@objc final class BlinkMachineStore: NSObject {
  @objc static let shared = BlinkMachineStore()

  private let kMachines = "BlinkMachineStore.machines"

  private override init() { super.init() }

  var machines: [BlinkMachine] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kMachines),
            let arr = try? JSONDecoder().decode([BlinkMachine].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kMachines)
      }
    }
  }

  var currentMachine: BlinkMachine? { machines.first }

  @objc var hasAnyMachine: Bool { !machines.isEmpty }

  @objc func currentSshCommand(tmuxSession: String?) -> String? {
    sshCommand(forMachineId: nil, tmuxSession: tmuxSession)
  }

  @objc func sshCommand(forMachineId machineId: String?, tmuxSession: String?) -> String? {
    sshCommand(forMachineId: machineId, workDirId: nil, tmuxSession: tmuxSession, useTmux: Self.useTmuxMode)
  }

  @objc func sshCommand(forMachineId machineId: String?, workDirId: String?, tmuxSession: String?) -> String? {
    sshCommand(forMachineId: machineId, workDirId: workDirId, tmuxSession: tmuxSession, useTmux: Self.useTmuxMode)
  }

  @objc func sshCommand(forMachineId machineId: String?, workDirId: String?, tmuxSession: String?, useTmux: Bool) -> String? {
    let arr = machines
    let m: BlinkMachine?
    if let id = machineId, let found = arr.first(where: { $0.id == id }) {
      m = found
    } else {
      m = currentMachine
    }
    guard let m else { return nil }

    let host = Self.bestHost(for: m)
    let workPath = BlinkWorkDirStore.shared.workDir(forId: workDirId)?.path

    var session = Self.effectiveTmuxSessionName(workDirId: workDirId, tmuxSession: tmuxSession)
    session = session.replacingOccurrences(of: "\"", with: "\\\"").lowercased()

    // 算 TITLE = customTitle，跟 transcriptCommand 保持一致：
    // 默认 <basename(workPath)>-<session>；session 已是 basename 或 basename- 开头则不再 prepend。
    // workPath 缺省时 basename 退化到 machine.user。
    let dirBasename: String
    if let wp = workPath, !wp.isEmpty {
      dirBasename = (wp as NSString).lastPathComponent.lowercased()
    } else {
      dirBasename = m.user.lowercased()
    }
    let title: String
    if session == dirBasename || session.hasPrefix("\(dirBasename)-") {
      title = session
    } else {
      title = "\(dirBasename)-\(session)"
    }
    // 每个 tab 的外层 tmux session 名固定 cc-<TITLE>，跟 jsonl customTitle 一一对应——
    // 助手 cc 可以 `tmux send-keys -t cc-<TITLE>` 直接往任意 tab 注入。
    let outerSession = "cc-\(title)"

    // cc --resume <name> 找不到 customTitle 时会弹 cc 自己的 resume 选择器（光标停在那等输入），
    // 不会以非零退出，所以 || cc 兜不住。改成先在 jsonl 里查 customTitle 拿 UUID 直接 resume，
    // 找不到就起新会话并 send-keys 注入 /title <name> 自动命名（这样下次开能直接 resume）。
    // 用 find 替代 glob 避开 zsh nomatch；不用 exec 以兼容 cc 是 alias 的情形。
    let resumeOrNew: (String) -> String = { cdTarget in
      // inner 被外层 `$SHELL -ic '...'` 单引号包裹，里面只能用双引号；TITLE 由 Swift 端预先算好。
      #"cd \#(cdTarget) && { CUR=$(pwd | sed "s:[/.]:-:g"); PROJ="$HOME/.claude/projects/$CUR"; TITLE="\#(title)"; ID=""; if [ -d "$PROJ" ]; then M=$(find "$PROJ" -maxdepth 1 -name "*.jsonl" -type f -exec grep -lF "\"customTitle\":\"$TITLE\"" {} + 2>/dev/null | head -1); [ -n "$M" ] && ID=$(basename "$M" .jsonl); fi; if [ -n "$ID" ]; then cc --resume "$ID"; else if [ -n "$TMUX" ]; then (sleep 1.5; tmux send-keys "/rename $TITLE" Enter) >/dev/null 2>&1 & cc; else TN="cc-$TITLE"; (sleep 1.5; tmux send-keys -t "$TN" "/rename $TITLE" Enter) >/dev/null 2>&1 & tmux new-session -A -s "$TN" "$SHELL -ic \"cc\""; fi; fi; }"#
    }

    // 老的 tmux session 名是 `<session>`（比如 talkai），新方案叫 `cc-<title>`（比如 cc-jack-talkai）。
    // 升级时如果旧 session 还在跑（里面有 cc），rename 一下以保活，避免用户丢上下文。
    let migrate = #"if [ "\#(session)" != "\#(outerSession)" ] && tmux has-session -t "\#(session)" 2>/dev/null && ! tmux has-session -t "\#(outerSession)" 2>/dev/null; then tmux rename-session -t "\#(session)" "\#(outerSession)" 2>/dev/null; fi"#

    if useTmux {
      let detectSock = #"S=$(sh -c 'for p in $(ls -t /tmp/ssh-*/agent.* 2>/dev/null) $TMPDIR/com.apple.launchd.*/Listeners /private/tmp/com.apple.launchd.*/Listeners $HOME/.ssh/agent.sock; do [ -S $p ] && { echo $p; break; }; done'); case x$S in x) ;; *) export SSH_AUTH_SOCK=$S; tmux set-environment -g SSH_AUTH_SOCK $S 2>/dev/null;; esac"#
      let pathArg = (workPath?.isEmpty == false) ? workPath! : "$HOME"
      let inner = resumeOrNew(pathArg)
      let remoteScript = """
      \(detectSock)
      PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
      \(migrate)
      exec tmux new-session -A -s \(outerSession) $SHELL -ic '\(inner)'
      """
      let encoded = Data(remoteScript.utf8).base64EncodedString()
        // 必须用 -- 隔开，否则 Blink 的 SSHCommand 会把后面的 -d / -p / -L 等当本地选项解析
      return "ssh -t \(m.user)@\(host) -- \"echo \(encoded) | base64 -d > /tmp/.blink-tmux-$$.sh && exec bash /tmp/.blink-tmux-$$.sh\""
    }

    guard let workPath, !workPath.isEmpty else {
      return "ssh -t \(m.user)@\(host)"
    }
    // 非 tmux 分支也要用 base64 包裹，否则 Blink 本地 shell 会把 $HOME / $(pwd) 等先在
    // iOS 沙箱里展开掉再传给远端，导致 inner 里全是空值或 iOS 路径。
    let inner = resumeOrNew(workPath)
    let remoteScript = "exec $SHELL -ic '\(inner)'"
    let encoded = Data(remoteScript.utf8).base64EncodedString()
    return "ssh -t \(m.user)@\(host) -- \"echo \(encoded) | base64 -d > /tmp/.blink-cc-$$.sh && exec bash /tmp/.blink-cc-$$.sh\""
  }

  // ---- blinkd 传输层(替代 SSH):不走 sshd,走 blinkd socket 连 mac daemon ----
  // 复用 sshCommand 生成的远端脚本(tmux + claude resume),只把 `ssh -t user@host --`
  // 换成 `blinkd <host> <port> <token> --exec <script-base64>`。daemon 收到 exec 帧后
  // fork 一个独立 PTY 跑同一段脚本 —— 体验和 SSH 完全一致,只是绕过 sshd / MDM 防火墙。
  // 走 blinkd 的自动连接命令:改成 per-machine —— 这台机器走 SSH(machine.blinkdConfig==nil)
  // 就返回 nil,调用方回退 sshCommand。连接方式在每台机器的编辑页里选(SSH / Socket)。
  @objc func blinkdCommand(forMachineId machineId: String?, workDirId: String?, tmuxSession: String?, useTmux: Bool) -> String? {
    let arr = machines
    let m = (machineId.flatMap { id in arr.first { $0.id == id } }) ?? currentMachine
    guard let m, let cfg = m.blinkdConfig else { return nil }
    // 复用 sshCommand 生成的远端脚本 base64(`echo <B64> | base64 -d`),只换传输层(ssh -t → blinkd socket)。
    // 依赖 sshCommand 的输出格式,两者要一起维护。
    guard let ssh = sshCommand(forMachineId: machineId, workDirId: workDirId, tmuxSession: tmuxSession, useTmux: useTmux) else { return nil }
    if let r1 = ssh.range(of: "echo "), let r2 = ssh.range(of: " | base64 -d") {
      let b64 = String(ssh[r1.upperBound..<r2.lowerBound])
      return "blinkd \(cfg.host) \(cfg.port) \(cfg.token) --exec \(b64)"
    }
    // sshCommand 是纯 `ssh -t user@host`(无远端脚本) → blinkd 跑默认 shell
    return "blinkd \(cfg.host) \(cfg.port) \(cfg.token)"
  }

  @objc static var useTmuxMode: Bool {
    // 没设过 key 时默认 true：重新打开标签默认走 tmux 模式（外层 cc-<TITLE> session，可被助手 send-keys 注入）
    get {
      // 强制全部 tab 走 tmux + cc（T 开关已移除）；旧的 BlinkUseTmuxMode 设置一律忽略
      return true
    }
    set { UserDefaults.standard.set(newValue, forKey: "BlinkUseTmuxMode") }
  }

  @objc func transcriptCommand(forMachineId machineId: String?, workDirId: String?, baseName: String) -> String? {
    let arr = machines
    let m: BlinkMachine?
    if let id = machineId, let found = arr.first(where: { $0.id == id }) {
      m = found
    } else {
      m = currentMachine
    }
    guard let m else { return nil }

    let host = Self.bestHost(for: m)
    let workPath = BlinkWorkDirStore.shared.workDir(forId: workDirId)?.path ?? "/Users/\(m.user)"
    let cwdEncoded = workPath
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    // cc 写入 jsonl 的 customTitle 跟 sshCommand 里 /rename 注入的 TITLE 保持一致：
    // 默认 "<basename(workPath)>-<session>"；若 session 已以 basename- 开头或就是 basename，则不再 prepend，
    // 避免 jack-jack-talkai 这种重复前缀。
    let session = baseName.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "").lowercased()
    let dirBasename = (workPath as NSString).lastPathComponent.lowercased()
    let name: String
    if session == dirBasename || session.hasPrefix("\(dirBasename)-") {
      name = session
    } else {
      name = "\(dirBasename)-\(session)"
    }

    let remoteScript = """
    export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
    PROJ=~/.claude/projects
    DIR=$PROJ/\(cwdEncoded)
    pick_latest_by_mtime() {
      while read f; do
        [ -z "$f" ] && continue
        printf '%d\\t%s\\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" "$f"
      done | sort -rn | head -1 | cut -f2-
    }
    # 多 tab 共用同一 workDir 时（比如 Jack:talkai / Jack:printer 都在 /Users/apple/Codes/Jack），
    # 所有 cc session 的 jsonl 都堆在同一个项目目录下，单纯 "mtime 最新" 会拉到别 tab 刚活跃过的 session。
    # 所以以 customTitle 精确匹配为主：sshCommand 在新建 cc 时会自动 /rename <TITLE>，cc 把 TITLE 写入 jsonl。
    TITLE='\(name)'
    # Step 1: 同目录 customTitle 精确匹配（取 mtime 最新，防同 TITLE 多份残留）
    F=$(grep -lF "\\"customTitle\\":\\"$TITLE\\"" "$DIR"/*.jsonl 2>/dev/null | pick_latest_by_mtime)
    # Step 2: 同前缀目录（cc 实际 cwd 比配的 workDir 深一层）
    if [ -z "$F" ]; then
      F=$(grep -lF "\\"customTitle\\":\\"$TITLE\\"" "$DIR"*/*.jsonl 2>/dev/null | pick_latest_by_mtime)
    fi
    # Step 3: 全局兜底（cc 启动时 cwd 跟 workDir 不一致）
    if [ -z "$F" ]; then
      F=$(grep -rlF "\\"customTitle\\":\\"$TITLE\\"" "$PROJ" --include='*.jsonl' 2>/dev/null | pick_latest_by_mtime)
    fi
    # Step 4: customTitle 还没写入（cc 刚建、/rename 没生效）才退回同目录 mtime 最新
    WARN=""
    if [ -z "$F" ]; then
      F=$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -1)
      [ -n "$F" ] && WARN="⚠️  customTitle '$TITLE' 未匹配，回退到同目录 mtime 最新 jsonl（可能是别 tab 的 session）"
    fi
    if [ -z "$F" ]; then
      F=$(ls -t "$DIR"*/*.jsonl 2>/dev/null | head -1)
      [ -n "$F" ] && WARN="⚠️  customTitle '$TITLE' 未匹配，回退到同前缀目录 mtime 最新 jsonl"
    fi
    if [ -z "$F" ]; then
      HINT=$(ls "$PROJ" 2>/dev/null | head -20 | tr '\\n' ' ')
      MATCHES=$(grep -rlE '"customTitle"' "$PROJ" --include='*.jsonl' 2>/dev/null | head -5 | xargs -I{} sh -c 'jq -r ".customTitle // empty" {} 2>/dev/null | head -1' | sort -u | tr '\\n' ',' )
      MSG="NOT_FOUND customTitle='\(name)' in $DIR (含全局/前缀/最近 fallback 都没匹配)\\n\\n要让历史能拉到，二选一：\\n  A) cc 里跑一次 \\\"/title \(name)\\\" 给 session 命名（推荐，命过一次就稳）\\n  B) 把 Blink 的 workDir 改成 cc 真实启动目录（cd 完哪里就配哪里）\\n\\n候选项目目录: $HINT\\n附近已有 customTitle: $MATCHES"
      B64=$(printf '%s' "$MSG" | base64 | tr -d '\\n')
      printf '\\033]52;c;%s\\a' "$B64"
      echo READY
      exit 1
    fi
    BODY=$( { [ -n "$WARN" ] && echo "$WARN"; echo "=== $F ==="; } ; jq -s -r '
      [.[]
        | select(.type=="user" or .type=="assistant")
        | . as $d
        | (if (.message.content | type) == "string" then
             .message.content
           else
             [.message.content[]? | select(.type=="text") | .text] | join("\\n")
           end) as $rawBody
        | ($rawBody
            | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
            | gsub("(?s)<task-notification>.*?</task-notification>"; "")
            | gsub("(?s)<local-command-stdout>.*?</local-command-stdout>"; "")
            | gsub("(?s)<local-command-stderr>.*?</local-command-stderr>"; "")
            | gsub("(?s)<command-name>.*?</command-name>"; "")
            | gsub("(?s)<command-message>.*?</command-message>"; "")
            | gsub("(?s)<command-args>.*?</command-args>"; "")
            | gsub("(?s)<user-prompt-submit-hook>.*?</user-prompt-submit-hook>"; "")
            | gsub("(?s)<bash-input>.*?</bash-input>"; "")
            | gsub("(?s)<bash-stdout>.*?</bash-stdout>"; "")
            | gsub("(?s)<bash-stderr>.*?</bash-stderr>"; "")
            | sub("^\\\\s+"; "")
            | sub("\\\\s+$"; "")
          ) as $body
        | select(($body | length) > 0)
        | select($body != "Continue from where you left off."
                 and $body != "No response requested."
                 and ($body | test("^\\\\[Request interrupted by user[^\\\\]]*\\\\]") | not))
        | {type: .type, body: $body}
      ] |
      .[-100:] |
      .[] |
      (if .type == "user" then "▶ You" else "◆ Claude" end), .body, ""
    ' "$F")
    B64=$(printf '%s' "$BODY" | base64 | tr -d '\\n')
    printf '\\033]52;c;%s\\a' "$B64"
    echo READY
    """
    let encoded = Data(remoteScript.utf8).base64EncodedString()
    // 走 blinkd 的机器：跟 tab 一样用 socket 传输拉历史，不走 ssh
    // （--exec 的 b64 被 BlinkdSession 解码成脚本，daemon 侧 bash -c 跑，等价 ssh 版 echo|base64 -d|bash）
    if let cfg = m.blinkdConfig {
      return "blinkd \(cfg.host) \(cfg.port) \(cfg.token) --exec \(encoded)"
    }
    return "ssh -t \(m.user)@\(host) \"echo \(encoded) | base64 -d | bash\""
  }

  static func resolveHost(for m: BlinkMachine) -> (host: String, source: String) {
    let lan = (m.lanHost ?? "").trimmingCharacters(in: .whitespaces)
    let host2 = (m.host2 ?? "").trimmingCharacters(in: .whitespaces)
    if !lan.isEmpty, HostReachability.isReachable(host: lan) { return (lan, "LAN") }
    let lanNote = lan.isEmpty ? "" : "（LAN 不通）"
    if host2.isEmpty {
      return (m.host, "外网1\(lanNote)")
    }
    if HostReachability.isReachable(host: m.host) { return (m.host, "外网1\(lanNote)") }
    if HostReachability.isReachable(host: host2) { return (host2, "外网2（外网1\(lan.isEmpty ? "" : "/LAN")不通）") }
    return (m.host, "外网1 fallback（全部不通）")
  }

  static func bestHost(for m: BlinkMachine) -> String { resolveHost(for: m).host }

  /// 清主机可达性缓存（重连前调，强制重新探测，避免用 30s 陈旧缓存里的坏 LAN）
  @objc func invalidateHostReachabilityCache() {
    HostReachability.invalidate()
  }

  @objc func chosenHostInfo(forMachineId machineId: String?) -> String? {
    let arr = machines
    let m: BlinkMachine?
    if let id = machineId, let found = arr.first(where: { $0.id == id }) { m = found }
    else { m = currentMachine }
    guard let m else { return nil }
    let r = Self.resolveHost(for: m)
    let lan = (m.lanHost ?? "").trimmingCharacters(in: .whitespaces)
    let h2 = (m.host2 ?? "").trimmingCharacters(in: .whitespaces)
    let cfg = "LAN=\(lan.isEmpty ? "-" : lan) 外网1=\(m.host) 外网2=\(h2.isEmpty ? "-" : h2)"
    var line = "[blink] 选用 \(r.host) (\(r.source))  ·  \(cfg)"
    let warns = Self.hostWarnings(for: m)
    if !warns.isEmpty {
      line += "\r\n[blink] ⚠️  " + warns.joined(separator: "；")
    }
    return line
  }

  /// 配置异常检测：返回需要警示的项，空数组表示一切正常
  private static func hostWarnings(for m: BlinkMachine) -> [String] {
    let host = m.host.trimmingCharacters(in: .whitespaces)
    let lan = (m.lanHost ?? "").trimmingCharacters(in: .whitespaces)
    let h2 = (m.host2 ?? "").trimmingCharacters(in: .whitespaces)

    func looksMalformed(_ s: String) -> Bool {
      if s.isEmpty { return false }
      let allDotDigit = s.allSatisfy { $0.isNumber || $0 == "." }
      if allDotDigit {
        let parts = s.split(separator: ".")
        if parts.count != 4 { return true }
        for p in parts {
          if let n = Int(p), n >= 0, n <= 255 { continue }
          return true
        }
        return false
      }
      // 含字母 → 当域名，至少要有点
      return !s.contains(".")
    }

    var warns: [String] = []
    if !lan.isEmpty, looksMalformed(lan) { warns.append("LAN「\(lan)」不是合法 IP/域名") }
    if looksMalformed(host) { warns.append("外网1「\(host)」不是合法 IP/域名") }
    if !h2.isEmpty, looksMalformed(h2) { warns.append("外网2「\(h2)」不是合法 IP/域名") }
    if !h2.isEmpty, h2 == host { warns.append("外网2 跟外网1 一样") }
    if !lan.isEmpty, lan == host { warns.append("LAN 跟外网1 一样") }
    if !lan.isEmpty, !h2.isEmpty, lan == h2 { warns.append("LAN 跟外网2 一样") }
    return warns
  }

  @objc static func effectiveTmuxSessionName(workDirId: String?, tmuxSession: String?) -> String {
    if let s = tmuxSession, !s.isEmpty { return s }
    if let wid = workDirId, !wid.isEmpty { return "blink-\(wid.prefix(8))" }
    return "blink"
  }

  @objc func machineExists(forId machineId: String?) -> Bool {
    guard let id = machineId else { return false }
    return machines.contains { $0.id == id }
  }

  @objc var currentMachineId: String? { machines.first?.id }

  func addOrUpdate(_ machine: BlinkMachine) {
    var arr = machines
    if let idx = arr.firstIndex(where: { $0.id == machine.id }) {
      arr[idx] = machine
    } else {
      arr.append(machine)
    }
    machines = arr
  }

  func delete(id: String) {
    machines.removeAll { $0.id == id }
    var m = avatarMap; m.removeValue(forKey: id); avatarMap = m
  }

  // MARK: 机器头像（[machineId: PNG]）
  private let kAvatars = "BlinkMachineStore.avatars"
  private var avatarMap: [String: Data] {
    get {
      guard let dict = UserDefaults.standard.dictionary(forKey: kAvatars) as? [String: String] else { return [:] }
      var out: [String: Data] = [:]
      for (k, v) in dict { if let d = Data(base64Encoded: v) { out[k] = d } }
      return out
    }
    set { UserDefaults.standard.set(newValue.mapValues { $0.base64EncodedString() }, forKey: kAvatars) }
  }

  func avatarImage(forId id: String) -> UIImage? {
    guard let d = avatarMap[id], let img = UIImage(data: d) else { return nil }
    return img
  }

  func setAvatar(_ data: Data, forId id: String) {
    var m = avatarMap; m[id] = data; avatarMap = m
  }

  @objc static func presentAddMachineIfNeeded() {
    guard !shared.hasAnyMachine else { return }
    DispatchQueue.main.async {
      presentMachineList()
    }
  }

  @objc static func presentMachineList() {
    let scenes = UIApplication.shared.connectedScenes
    guard let window = scenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
    var top = window.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    let list = MachineListViewController()
    let nav = UINavigationController(rootViewController: list)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    top?.present(nav, animated: true)
  }
}

final class MachineListViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "机器"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(closeTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add, target: self, action: #selector(addTapped)
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }

  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    BlinkMachineStore.shared.machines.count
  }

  override func tableView(_ tv: UITableView, titleForFooterInSection section: Int) -> String? {
    "点选机器进入编辑/删除。列表第一项即新建标签页的默认机器。\nAutoMac 公钥：\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGEpZhB+3m9GZYDzN3vi7cotb/32yyGMe3rp2/aHvZz0 blink-sim"
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    cell.textLabel?.text = m.displayName
    cell.detailTextLabel?.text = "\(m.user)@\(m.host)"
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = .detailButton
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    pushForm(editing: m)
  }

  override func tableView(_ tv: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
    let m = BlinkMachineStore.shared.machines[indexPath.row]
    pushForm(editing: m)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func addTapped() {
    pushForm(editing: nil)
  }

  private func pushForm(editing machine: BlinkMachine?) {
    let form = MachineFormViewController(editing: machine)
    navigationController?.pushViewController(form, animated: true)
  }
}

final class MachineFormViewController: UITableViewController, UITextFieldDelegate {
  private var machine: BlinkMachine
  private let isNew: Bool

  private let nameField = UITextField()
  private let hostField = UITextField()
  private let host2Field = UITextField()
  private let lanHostField = UITextField()
  private let userField = UITextField()

  // 连接方式(SSH / Socket) + blinkd 的 daemon 连接信息
  private let transportControl = UISegmentedControl(items: ["SSH", "Socket"])
  private let blinkdHostField = UITextField()
  private let blinkdPortField = UITextField()
  private let blinkdTokenField = UITextField()
  private var useBlinkdSelected = false

  init(editing machine: BlinkMachine?) {
    if let m = machine {
      self.machine = m
      self.isNew = false
    } else {
      self.machine = BlinkMachine(host: "", user: "")
      self.isNew = true
    }
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = isNew ? "添加机器" : "编辑机器"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .save, target: self, action: #selector(saveTapped)
    )

    configureField(nameField, placeholder: "可选，留空显示 user@host", value: machine.name, returnKey: .next, keyboard: .default)
    configureField(hostField, placeholder: "外网/Tailscale，如 mac.tail.ts.net", value: machine.host, returnKey: .next, keyboard: .URL)
    configureField(host2Field, placeholder: "可选，备用外网 IP/域名", value: machine.host2 ?? "", returnKey: .next, keyboard: .URL)
    configureField(lanHostField, placeholder: "可选，局域网 IP，如 192.168.1.10", value: machine.lanHost ?? "", returnKey: .next, keyboard: .URL)
    configureField(userField, placeholder: "apple", value: machine.user, returnKey: .done, keyboard: .default)

    useBlinkdSelected = machine.usesBlinkd
    transportControl.selectedSegmentIndex = useBlinkdSelected ? 1 : 0
    transportControl.addTarget(self, action: #selector(transportChanged), for: .valueChanged)
    configureField(blinkdHostField, placeholder: "daemon 地址,如 100.96.88.80", value: machine.blinkdHost ?? "", returnKey: .next, keyboard: .URL)
    configureField(blinkdPortField, placeholder: "7777", value: machine.blinkdPort.map(String.init) ?? "", returnKey: .next, keyboard: .numberPad)
    configureField(blinkdTokenField, placeholder: "daemon token", value: machine.blinkdToken ?? "", returnKey: .done, keyboard: .default)
  }

  @objc private func transportChanged() {
    useBlinkdSelected = transportControl.selectedSegmentIndex == 1
    tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if isNew {
      hostField.becomeFirstResponder()
    }
  }

  private func configureField(_ tf: UITextField, placeholder: String, value: String, returnKey: UIReturnKeyType, keyboard: UIKeyboardType) {
    tf.placeholder = placeholder
    tf.text = value
    tf.autocapitalizationType = .none
    tf.autocorrectionType = .no
    tf.spellCheckingType = .no
    tf.returnKeyType = returnKey
    tf.keyboardType = keyboard
    tf.delegate = self
    tf.clearButtonMode = .whileEditing
  }

  // section 0=SSH 基础字段, 1=连接方式(SSH/Socket + blinkd 配置), 2=删除(非新建)
  override func numberOfSections(in tv: UITableView) -> Int { isNew ? 2 : 3 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 5
    case 1: return 1 + (useBlinkdSelected ? 3 : 0)   // 连接方式 + (选 Socket 才显 地址/端口/token)
    default: return 1                                 // 删除
    }
  }
  override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == 1 ? "连接方式" : nil
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection section: Int) -> String? {
    switch section {
    case 0:
      return "连接顺序：内网（300ms 探测）→ 外网1 → 外网2，第一个可达的拿来用。\n登录使用 AutoMac 内置 SSH key。如需免密，把 AutoMac 公钥加到目标机器的 ~/.ssh/authorized_keys。"
    case 1:
      return useBlinkdSelected
        ? "Socket：手机直连这台机器的 blinkd daemon，不走 SSH（绕过 MDM）。填 daemon 的地址/端口/token。"
        : "SSH：走系统 sshd（默认）。选 Socket 需要这台机器上跑着 blinkd daemon。"
    default:
      return nil
    }
  }

  override func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    // 删除 section(非新建时的最后一个 section = 2)
    if indexPath.section == 2 {
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "删除机器"
      cell.textLabel?.textColor = .systemRed
      cell.textLabel?.textAlignment = .center
      return cell
    }
    // 连接方式 section
    if indexPath.section == 1 {
      if indexPath.row == 0 {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        transportControl.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(transportControl)
        NSLayoutConstraint.activate([
          transportControl.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
          transportControl.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
          transportControl.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
          transportControl.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
      }
      let (label, field): (String, UITextField) = {
        switch indexPath.row {
        case 1: return ("地址", blinkdHostField)
        case 2: return ("端口", blinkdPortField)
        default: return ("Token", blinkdTokenField)
        }
      }()
      return makeFieldCell(label: label, field: field)
    }
    // SSH 基础字段 section 0
    let (label, field): (String, UITextField) = {
      switch indexPath.row {
      case 0: return ("名称", nameField)
      case 1: return ("外网1", hostField)
      case 2: return ("外网2", host2Field)
      case 3: return ("内网", lanHostField)
      case 4: return ("用户", userField)
      default: return ("", UITextField())
      }
    }()
    return makeFieldCell(label: label, field: field)
  }

  // 字段 cell 布局(SSH 字段 + blinkd 字段复用)
  private func makeFieldCell(label: String, field: UITextField) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.selectionStyle = .none
    let titleLabel = UILabel()
    titleLabel.text = label
    titleLabel.font = .systemFont(ofSize: 16)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 16)
    cell.contentView.addSubview(titleLabel)
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
      titleLabel.widthAnchor.constraint(equalToConstant: 60),

      field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])
    return cell
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === nameField { hostField.becomeFirstResponder() }
    else if textField === hostField { host2Field.becomeFirstResponder() }
    else if textField === host2Field { lanHostField.becomeFirstResponder() }
    else if textField === lanHostField { userField.becomeFirstResponder() }
    else { saveTapped() }
    return false
  }

  override func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
    tv.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 2 else { return }
    let alert = UIAlertController(title: "删除机器？", message: machine.displayName, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      guard let self else { return }
      BlinkMachineStore.shared.delete(id: self.machine.id)
      HostReachability.invalidate()
      self.navigationController?.popViewController(animated: true)
    })
    present(alert, animated: true)
  }

  @objc private func saveTapped() {
    let host = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
    let host2 = (host2Field.text ?? "").trimmingCharacters(in: .whitespaces)
    let lan = (lanHostField.text ?? "").trimmingCharacters(in: .whitespaces)
    let user = (userField.text ?? "").trimmingCharacters(in: .whitespaces)
    let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
    if host.isEmpty || user.isEmpty {
      let alert = UIAlertController(title: "缺少字段", message: "外网1 和用户必填", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "确定", style: .default))
      present(alert, animated: true)
      return
    }
    machine.name = name
    machine.host = host
    machine.host2 = host2.isEmpty ? nil : host2
    machine.lanHost = lan.isEmpty ? nil : lan
    machine.user = user
    // 连接方式
    machine.transport = useBlinkdSelected ? "blinkd" : "ssh"
    if useBlinkdSelected {
      let bh = (blinkdHostField.text ?? "").trimmingCharacters(in: .whitespaces)
      let bt = (blinkdTokenField.text ?? "").trimmingCharacters(in: .whitespaces)
      machine.blinkdHost = bh.isEmpty ? nil : bh
      machine.blinkdToken = bt.isEmpty ? nil : bt
      machine.blinkdPort = Int((blinkdPortField.text ?? "").trimmingCharacters(in: .whitespaces))
    }
    BlinkMachineStore.shared.addOrUpdate(machine)
    HostReachability.invalidate()
    navigationController?.popViewController(animated: true)
  }
}

@objc protocol BlinkTabBarDelegate: AnyObject {
  func tabBarDidSelect(index: Int)
  func tabBarDidRequestNew()
  func tabBarDidRequestClose(index: Int)
  func tabBarDidRequestSettings()
  func tabBarDidRequestMachineFilter()
  func tabBarDidRequestAssistant()
  /// 顶栏 sparkles 入口 → 打开气泡 chat UI（与 kAssistantTabTag 的终端 tab 互补）
  func tabBarDidRequestAssistantChat()
}

final class HorizontalOnlyScrollView: UIScrollView {
  override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
    if gr === panGestureRecognizer, let pan = gr as? UIPanGestureRecognizer {
      let v = pan.velocity(in: self)
      if abs(v.y) > abs(v.x) { return false }
    }
    return super.gestureRecognizerShouldBegin(gr)
  }
}

@objc final class BlinkTabBar: UIView {
  @objc weak var delegate: BlinkTabBarDelegate?

  private let scrollView = HorizontalOnlyScrollView()
  private let stack = UIStackView()
  private let rowsStack = UIStackView()
  private let topRow = UIView()
  private let addButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private let filterChipButton = UIButton(type: .system)
  private let assistantButton = UIButton(type: .system)

  @objc init() {
    super.init(frame: .zero)
    setupUI()
  }
  required init?(coder: NSCoder) { fatalError() }

  private func setupUI() {
    backgroundColor = UIColor(white: 0.12, alpha: 1.0)

    settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
    settingsButton.tintColor = .systemBlue
    settingsButton.translatesAutoresizingMaskIntoConstraints = false
    settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

    addButton.setImage(UIImage(systemName: "plus"), for: .normal)
    addButton.tintColor = .systemBlue
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

    // 顶栏的 sparkles 按钮：打开气泡 chat UI（跟新加的"助手 tab"=终端 互补）
    assistantButton.setImage(UIImage(systemName: "sparkles"), for: .normal)
    assistantButton.tintColor = .systemPurple
    assistantButton.translatesAutoresizingMaskIntoConstraints = false
    assistantButton.addTarget(self, action: #selector(assistantTapped), for: .touchUpInside)

    var chipCfg = UIButton.Configuration.plain()
    chipCfg.title = "全部"
    chipCfg.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
    chipCfg.imagePadding = 4
    chipCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10)
    chipCfg.baseForegroundColor = .systemTeal
    filterChipButton.configuration = chipCfg
    filterChipButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    filterChipButton.layer.cornerRadius = 6
    filterChipButton.layer.borderWidth = 1
    filterChipButton.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.5).cgColor
    filterChipButton.translatesAutoresizingMaskIntoConstraints = false
    filterChipButton.addTarget(self, action: #selector(filterTapped), for: .touchUpInside)

    topRow.translatesAutoresizingMaskIntoConstraints = false
    topRow.addSubview(settingsButton)
    topRow.addSubview(filterChipButton)
    topRow.addSubview(assistantButton)
    topRow.addSubview(addButton)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsHorizontalScrollIndicator = false
    stack.axis = .horizontal
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)

    rowsStack.axis = .vertical
    rowsStack.spacing = 6
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    rowsStack.addArrangedSubview(topRow)
    rowsStack.addArrangedSubview(scrollView)
    addSubview(rowsStack)

    NSLayoutConstraint.activate([
      settingsButton.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: 8),
      settingsButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      settingsButton.widthAnchor.constraint(equalToConstant: 32),
      settingsButton.heightAnchor.constraint(equalToConstant: 28),

      filterChipButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 6),
      filterChipButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      filterChipButton.heightAnchor.constraint(equalToConstant: 26),

      addButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -8),
      addButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 32),
      addButton.heightAnchor.constraint(equalToConstant: 28),

      assistantButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
      assistantButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      assistantButton.widthAnchor.constraint(equalToConstant: 32),
      assistantButton.heightAnchor.constraint(equalToConstant: 28),

      topRow.heightAnchor.constraint(equalToConstant: 28),

      rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
      stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
  }

  @objc private func settingsTapped() {
    delegate?.tabBarDidRequestSettings()
  }

  @objc private func assistantTapped() {
    delegate?.tabBarDidRequestAssistantChat()
  }

  @objc func reload(titles: [String], unread: [Bool], currentIndex: Int) {
    reload(titles: titles, icons: nil, unread: unread,
           tags: Array(0..<titles.count), filterTitle: nil, currentTag: currentIndex)
  }

  @objc func reload(titles: [String], unread: [Bool], tags: [Int], filterTitle: String?, currentTag: Int) {
    reload(titles: titles, icons: nil, unread: unread, tags: tags,
           filterTitle: filterTitle, currentTag: currentTag)
  }

  /// 主入口：可选传 icons 给每个 tab 加前置头像图
  func reload(titles: [String], icons: [UIImage?]?, unread: [Bool], tags: [Int], filterTitle: String?, currentTag: Int) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    var newCfg = filterChipButton.configuration
    newCfg?.title = filterTitle ?? "全部"
    filterChipButton.configuration = newCfg

    var visibleIndexOfCurrent = -1
    for (i, title) in titles.enumerated() {
      let isUnread = i < unread.count && unread[i]
      let tag = i < tags.count ? tags[i] : i
      let icon: UIImage? = (icons.flatMap { i < $0.count ? $0[i] : nil }) ?? nil
      let btn = makeTabButton(title: title, icon: icon, index: tag,
                              isCurrent: tag == currentTag, hasUnread: isUnread)
      if tag == currentTag { visibleIndexOfCurrent = i }
      stack.addArrangedSubview(btn)
    }
    layoutIfNeeded()
    if visibleIndexOfCurrent >= 0 {
      scrollToVisibleTab(at: visibleIndexOfCurrent, animated: true)
    }
  }

  private func scrollToVisibleTab(at visibleIndex: Int, animated: Bool) {
    guard stack.arrangedSubviews.indices.contains(visibleIndex) else { return }
    let btn = stack.arrangedSubviews[visibleIndex]
    let frameInScroll = btn.convert(btn.bounds, to: scrollView)
    let pad: CGFloat = 24
    let target = frameInScroll.insetBy(dx: -pad, dy: 0)
    scrollView.scrollRectToVisible(target, animated: animated)
  }

  @objc private func filterTapped() {
    delegate?.tabBarDidRequestMachineFilter()
  }

  private func makeTabButton(title: String, icon: UIImage?, index: Int, isCurrent: Bool, hasUnread: Bool) -> UIButton {
    var cfg = UIButton.Configuration.plain()
    cfg.title = title
    if let icon {
      cfg.image = icon
      cfg.imagePadding = 6
      cfg.imagePlacement = .leading
    }
    let leadingInset: CGFloat = icon != nil ? 8 : 12
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: leadingInset, bottom: 4, trailing: hasUnread ? 18 : 12)
    cfg.baseForegroundColor = isCurrent ? .label : .secondaryLabel
    let btn = UIButton(configuration: cfg)
    btn.titleLabel?.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
    btn.layer.cornerRadius = 6
    btn.layer.masksToBounds = false
    btn.backgroundColor = isCurrent ? UIColor.systemBlue.withAlphaComponent(0.18) : .clear
    btn.tag = index
    btn.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(tabLongPressed(_:)))
    longPress.minimumPressDuration = 0.4
    btn.addGestureRecognizer(longPress)
    if hasUnread {
      let dot = UIView()
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.backgroundColor = .systemRed
      dot.layer.cornerRadius = 4
      dot.isUserInteractionEnabled = false
      btn.addSubview(dot)
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 8),
        dot.heightAnchor.constraint(equalToConstant: 8),
        dot.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -4),
        dot.topAnchor.constraint(equalTo: btn.topAnchor, constant: 4),
      ])
    }
    return btn
  }

  @objc private func tabTapped(_ sender: UIButton) {
    delegate?.tabBarDidSelect(index: sender.tag)
  }

  @objc private func tabLongPressed(_ rec: UILongPressGestureRecognizer) {
    guard rec.state == .began, let btn = rec.view as? UIButton else { return }
    delegate?.tabBarDidRequestClose(index: btn.tag)
  }

  @objc private func addTapped() {
    delegate?.tabBarDidRequestNew()
  }
}

// MARK: - WorkDir

final class BlinkWorkDir: Codable {
  let id: String
  var name: String
  var path: String
  /// 选中头像的 PNG 字节（来自 DiceBear），离线可用
  var iconImageData: Data?

  init(id: String = UUID().uuidString, name: String = "", path: String, iconImageData: Data? = nil) {
    self.id = id
    self.name = name
    self.path = path
    self.iconImageData = iconImageData
  }

  var iconImage: UIImage? {
    guard let d = iconImageData else { return nil }
    return UIImage(data: d)
  }

  var displayName: String {
    name.isEmpty ? path : name
  }
}

@objc final class BlinkWorkDirStore: NSObject {
  @objc static let shared = BlinkWorkDirStore()
  private let kKey = "BlinkWorkDirStore.workDirs"
  @objc static let assistantWorkDirId = "seed-blink-assistant"
  @objc static let assistantTmuxSession = "blink-assistant"

  /// 助手 workDir 是 seed 之一；如果用户老版本升级后 store 里没有，自动补一条
  func ensureAssistantWorkDir() -> BlinkWorkDir {
    if let existing = workDir(forId: Self.assistantWorkDirId) { return existing }
    let wd = BlinkWorkDir(id: Self.assistantWorkDirId, name: "助手", path: "/Users/apple/blink-assistant")
    addOrUpdate(wd)
    return wd
  }

  private override init() {
    super.init()
    let seeds: [BlinkWorkDir] = [
      BlinkWorkDir(id: "seed-blink", name: "blink", path: "/Users/apple/Codes/IPHONE/blink"),
      BlinkWorkDir(id: "seed-talkai", name: "talkAI", path: "/Users/apple/Codes/IPHONE/talkai"),
      BlinkWorkDir(id: Self.assistantWorkDirId, name: "助手", path: "/Users/apple/blink-assistant"),
    ]
    if let data = try? JSONEncoder().encode(seeds) {
      UserDefaults.standard.register(defaults: [kKey: data])
    }
  }

  var workDirs: [BlinkWorkDir] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kKey),
            let arr = try? JSONDecoder().decode([BlinkWorkDir].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kKey)
      }
    }
  }

  func workDir(forId id: String?) -> BlinkWorkDir? {
    guard let id else { return nil }
    return workDirs.first { $0.id == id }
  }

  func addOrUpdate(_ wd: BlinkWorkDir) {
    var arr = workDirs
    if let idx = arr.firstIndex(where: { $0.id == wd.id }) {
      arr[idx] = wd
    } else {
      arr.append(wd)
    }
    workDirs = arr
  }

  func delete(id: String) {
    workDirs.removeAll { $0.id == id }
  }

  @discardableResult
  func duplicate(id: String) -> BlinkWorkDir? {
    var arr = workDirs
    guard let src = arr.first(where: { $0.id == id }) else { return nil }
    let copy = BlinkWorkDir(name: src.name.isEmpty ? "" : "\(src.name) 副本", path: src.path)
    if let idx = arr.firstIndex(where: { $0.id == id }) {
      arr.insert(copy, at: idx + 1)
    } else {
      arr.append(copy)
    }
    workDirs = arr
    return copy
  }
}

final class WorkDirListViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkWorkDirStore.shared.workDirs.count
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    "新建标签时可选这里的目录，ssh 后会先 cd 进去再起 tmux。"
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    cell.textLabel?.text = wd.displayName
    cell.detailTextLabel?.text = wd.path
    cell.detailTextLabel?.textColor = .secondaryLabel
    if let img = wd.iconImage {
      cell.imageView?.image = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 36, height: 36))
    } else {
      cell.imageView?.image = UIImage(systemName: "folder")
      cell.imageView?.tintColor = .tertiaryLabel
    }
    cell.accessoryType = .detailButton
    return cell
  }

  override func tableView(_ tv: UITableView, accessoryButtonTappedForRowWith ip: IndexPath) {
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    let form = WorkDirFormViewController(editing: wd)
    navigationController?.pushViewController(form, animated: true)
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    if editingStyle == .delete {
      let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
      BlinkWorkDirStore.shared.delete(id: wd.id)
      tv.deleteRows(at: [ip], with: .automatic)
    }
  }

  override func tableView(_ tv: UITableView, leadingSwipeActionsConfigurationForRowAt ip: IndexPath) -> UISwipeActionsConfiguration? {
    let wd = BlinkWorkDirStore.shared.workDirs[ip.row]
    let dup = UIContextualAction(style: .normal, title: "复制") { [weak self] _, _, done in
      guard let self else { done(false); return }
      let copy = BlinkWorkDirStore.shared.duplicate(id: wd.id)
      tv.reloadData()
      done(true)
      if let copy {
        self.navigationController?.pushViewController(WorkDirFormViewController(editing: copy), animated: true)
      }
    }
    dup.backgroundColor = .systemBlue
    dup.image = UIImage(systemName: "doc.on.doc")
    let copyPath = UIContextualAction(style: .normal, title: "复制路径") { _, _, done in
      UIPasteboard.general.string = wd.path
      done(true)
    }
    copyPath.backgroundColor = .systemGray
    copyPath.image = UIImage(systemName: "doc.on.clipboard")
    return UISwipeActionsConfiguration(actions: [dup, copyPath])
  }

  @objc private func addTapped() {
    let form = WorkDirFormViewController(editing: nil)
    navigationController?.pushViewController(form, animated: true)
  }
}

final class PeopleListViewController: UITableViewController {
  init() { super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "员工头像"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add, target: self, action: #selector(addTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkPeopleStore.shared.knownNames.count
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    "助手在 PATROL 巡检报告里就用这里的头像。点员工换一张 DiceBear。"
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    let name = BlinkPeopleStore.shared.knownNames[ip.row]
    cell.textLabel?.text = name
    if let img = BlinkPeopleStore.shared.iconSync(for: name, size: 72) {
      cell.imageView?.image = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 36, height: 36))
    } else {
      cell.imageView?.image = UIImage(systemName: "person.crop.circle.dashed")
      cell.imageView?.tintColor = .tertiaryLabel
      // 异步取一次默认 DiceBear，下次进来就有了
      BlinkPeopleStore.shared.iconAsync(for: name, size: 72) { [weak tv] _ in
        tv?.reloadData()
      }
    }
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    let name = BlinkPeopleStore.shared.knownNames[ip.row]
    let picker = AvatarPickerViewController()
    picker.title = "选 \(name) 的头像"
    picker.onPick = { [weak self] data in
      BlinkPeopleStore.shared.setIcon(data, for: name, style: AvatarPickerViewController.lastPickedStyle)
      self?.tableView.reloadData()
    }
    navigationController?.pushViewController(picker, animated: true)
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    if editingStyle == .delete {
      let name = BlinkPeopleStore.shared.knownNames[ip.row]
      BlinkPeopleStore.shared.removeName(name)
      tv.deleteRows(at: [ip], with: .automatic)
    }
  }

  @objc private func addTapped() {
    let alert = UIAlertController(title: "添加员工", message: "输入员工名（小写英文，如 dave）", preferredStyle: .alert)
    alert.addTextField { tf in
      tf.placeholder = "name"
      tf.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
      let name = alert.textFields?.first?.text ?? ""
      BlinkPeopleStore.shared.addName(name)
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }
}

final class WorkDirFormViewController: UITableViewController, UITextFieldDelegate {
  private var wd: BlinkWorkDir
  private let isNew: Bool
  private let nameField = UITextField()
  private let pathField = UITextField()
  var onSaved: ((BlinkWorkDir) -> Void)?

  init(editing wd: BlinkWorkDir?) {
    if let wd {
      self.wd = wd
      self.isNew = false
    } else {
      self.wd = BlinkWorkDir(path: "")
      self.isNew = true
    }
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = isNew ? "添加工作目录" : "编辑工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

    [nameField, pathField].forEach {
      $0.autocapitalizationType = .none
      $0.autocorrectionType = .no
      $0.spellCheckingType = .no
      $0.delegate = self
      $0.font = .systemFont(ofSize: 16)
      $0.translatesAutoresizingMaskIntoConstraints = false
      $0.clearButtonMode = .whileEditing
    }
    nameField.placeholder = "可选名称（如 blink）"
    nameField.text = wd.name
    nameField.returnKeyType = .next
    pathField.placeholder = "/Users/apple/Codes/blink 或 ~/Codes/blink"
    pathField.text = wd.path
    pathField.returnKeyType = .done
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if isNew { pathField.becomeFirstResponder() }
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { 3 }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    if ip.row == 2 {
      let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
      cell.textLabel?.text = "头像"
      cell.textLabel?.font = .systemFont(ofSize: 16)
      if let img = wd.iconImage {
        cell.detailTextLabel?.text = "已选"
        cell.imageView?.image = AvatarRenderer.roundedThumbnail(from: img, size: CGSize(width: 36, height: 36))
      } else {
        cell.detailTextLabel?.text = "未选"
        cell.imageView?.image = UIImage(systemName: "person.crop.circle.dashed")
        cell.imageView?.tintColor = .tertiaryLabel
      }
      cell.accessoryType = .disclosureIndicator
      return cell
    }
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.selectionStyle = .none
    let (label, field): (String, UITextField) = ip.row == 0 ? ("名称", nameField) : ("路径", pathField)
    let titleLabel = UILabel()
    titleLabel.text = label
    titleLabel.font = .systemFont(ofSize: 16)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(titleLabel)
    cell.contentView.addSubview(field)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
      titleLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
      titleLabel.widthAnchor.constraint(equalToConstant: 60),
      field.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
      field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
      field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    guard ip.row == 2 else { return }
    let picker = AvatarPickerViewController()
    picker.onPick = { [weak self] data in
      self?.wd.iconImageData = data
      self?.tableView.reloadRows(at: [ip], with: .none)
    }
    navigationController?.pushViewController(picker, animated: true)
  }

  func textFieldShouldReturn(_ tf: UITextField) -> Bool {
    if tf === nameField { pathField.becomeFirstResponder() } else { saveTapped() }
    return false
  }

  @objc private func saveTapped() {
    let path = (pathField.text ?? "").trimmingCharacters(in: .whitespaces)
    if path.isEmpty {
      let a = UIAlertController(title: "缺少字段", message: "路径必填", preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "确定", style: .default))
      present(a, animated: true)
      return
    }
    wd.name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
    wd.path = path
    BlinkWorkDirStore.shared.addOrUpdate(wd)
    onSaved?(wd)
    navigationController?.popViewController(animated: true)
  }
}

final class BlinkSessionPreset: Codable {
  let id: String
  var machineId: String
  var workDirId: String?
  var baseName: String

  init(id: String = UUID().uuidString, machineId: String, workDirId: String?, baseName: String) {
    self.id = id
    self.machineId = machineId
    self.workDirId = workDirId
    self.baseName = baseName
  }

  var sessionName: String {
    BlinkSessionPreset.sanitize(baseName.isEmpty ? "blink" : baseName)
  }

  private static func sanitize(_ s: String) -> String {
    s
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: ".", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }

  var displayTitle: String {
    let m = BlinkMachineStore.shared.machines.first { $0.id == machineId }
    let w = workDirId.flatMap { id in BlinkWorkDirStore.shared.workDirs.first { $0.id == id } }
    let mName: String = m.flatMap { $0.name.isEmpty ? $0.user : $0.name } ?? "?"
    let wName: String = w.map { ($0.path as NSString).lastPathComponent } ?? "home"
    let base = baseName.isEmpty ? "blink" : baseName
    return "\(base) · \(mName)/\(wName)"
  }
}

@objc final class BlinkSessionPresetStore: NSObject {
  @objc static let shared = BlinkSessionPresetStore()
  private let kKey = "BlinkSessionPresetStore.presets"

  private override init() { super.init() }

  var presets: [BlinkSessionPreset] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kKey),
            let arr = try? JSONDecoder().decode([BlinkSessionPreset].self, from: data) else {
        return []
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kKey)
      }
    }
  }

  @discardableResult
  func upsert(machineId: String, workDirId: String?, baseName: String) -> BlinkSessionPreset {
    let cleanBase = baseName.trimmingCharacters(in: .whitespaces)
    var arr = presets
    if let existing = arr.first(where: { $0.machineId == machineId && $0.workDirId == workDirId && $0.baseName == cleanBase }) {
      return existing
    }
    let p = BlinkSessionPreset(machineId: machineId, workDirId: workDirId, baseName: cleanBase)
    arr.append(p)
    presets = arr
    return p
  }

  func delete(id: String) {
    presets.removeAll { $0.id == id }
  }
}

final class NewTabViewController: UITableViewController {
  private var machineId: String?
  private var workDirId: String?
  private var tmuxName: String?
  var onCreate: ((String, String?, String?) -> Void)?
  var customTitle: String = "新建标签"
  var actionTitle: String = "创建"

  private struct PresetGroup {
    let machineId: String
    let machineDisplayName: String
    var presets: [BlinkSessionPreset]
  }
  private var presetGroups: [PresetGroup] = []

  init(machineId: String? = nil, workDirId: String? = nil, tmuxName: String? = nil) {
    super.init(style: .insetGrouped)
    self.machineId = machineId ?? BlinkMachineStore.shared.currentMachineId
    self.workDirId = workDirId
    self.tmuxName = tmuxName
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = customTitle
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(closeTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: actionTitle, style: .done, target: self, action: #selector(createTapped))
    _installVersionFooter()
  }

  /// 表格底部显示版本号 + 构建时间，方便确认装的是不是最新包
  private func _installVersionFooter() {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    // 可执行文件 mtime 每次重新构建都会变，作为「构建时间」指纹
    var buildTime = ""
    if let exe = Bundle.main.executableURL,
       let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
       let date = attrs[.modificationDate] as? Date {
      let f = DateFormatter()
      f.dateFormat = "MM-dd HH:mm"
      buildTime = " · 构建 " + f.string(from: date)
    }
    let label = UILabel()
    label.text = "Blink v\(short) (\(build))\(buildTime)"
    label.font = .systemFont(ofSize: 12)
    label.textColor = .tertiaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44)
    tableView.tableFooterView = label
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    _reloadGroups()
    tableView.reloadData()
  }

  private func _reloadGroups() {
    let all = BlinkSessionPresetStore.shared.presets
    var map: [String: [BlinkSessionPreset]] = [:]
    for p in all { map[p.machineId, default: []].append(p) }
    var groups: [PresetGroup] = []
    var consumed = Set<String>()
    for m in BlinkMachineStore.shared.machines {
      guard let ps = map[m.id], !ps.isEmpty else { continue }
      let dn = m.name.isEmpty ? "\(m.user)@\(m.host)" : m.name
      groups.append(PresetGroup(machineId: m.id, machineDisplayName: dn, presets: ps))
      consumed.insert(m.id)
    }
    for (mid, ps) in map where !consumed.contains(mid) {
      groups.append(PresetGroup(machineId: mid, machineDisplayName: "未知机器", presets: ps))
    }
    presetGroups = groups
  }

  private var _newSection: Int { presetGroups.isEmpty ? 1 : presetGroups.count }

  override func numberOfSections(in tv: UITableView) -> Int {
    (presetGroups.isEmpty ? 1 : presetGroups.count) + 1
  }
  override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
    if s == _newSection { return "新建" }
    if presetGroups.isEmpty { return "已有会话" }
    return presetGroups[s].machineDisplayName
  }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    if s == _newSection { return 3 }
    if presetGroups.isEmpty { return 1 }
    return presetGroups[s].presets.count
  }
  override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
    s == _newSection ? "tmux 会话名：相同名字会 attach 进已存在的会话，否则新建。组合会保存到上方列表。" : nil
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    if ip.section != _newSection {
      if presetGroups.isEmpty {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "暂无（在下方填一组并点 \(actionTitle)）"
        cell.textLabel?.textColor = .secondaryLabel
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.selectionStyle = .none
        return cell
      }
      let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
      let p = presetGroups[ip.section].presets[ip.row]
      cell.textLabel?.text = p.displayTitle
      cell.detailTextLabel?.text = p.sessionName
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = .disclosureIndicator
      return cell
    }
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.accessoryType = .disclosureIndicator
    switch ip.row {
    case 0:
      cell.textLabel?.text = "机器"
      let m = BlinkMachineStore.shared.machines.first { $0.id == machineId }
      cell.detailTextLabel?.text = m.map { $0.displayName } ?? "（必选）"
      cell.detailTextLabel?.textColor = (m == nil) ? .systemRed : .secondaryLabel
    case 1:
      cell.textLabel?.text = "工作目录"
      let w = BlinkWorkDirStore.shared.workDirs.first { $0.id == workDirId }
      cell.detailTextLabel?.text = w.map { $0.displayName } ?? "（默认 home）"
    case 2:
      cell.textLabel?.text = "tmux 会话"
      cell.detailTextLabel?.text = (tmuxName?.isEmpty == false) ? tmuxName : "（自动 blink）"
    default: break
    }
    return cell
  }

  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    if ip.section != _newSection {
      guard !presetGroups.isEmpty,
            ip.section < presetGroups.count,
            ip.row < presetGroups[ip.section].presets.count else { return }
      let p = presetGroups[ip.section].presets[ip.row]
      let cb = onCreate
      dismiss(animated: true) {
        cb?(p.machineId, p.workDirId, p.sessionName)
      }
      return
    }
    switch ip.row {
    case 0:
      let picker = NewTabMachinePickerViewController(currentId: machineId)
      picker.onSelect = { [weak self] id in
        self?.machineId = id
        self?.tableView.reloadData()
      }
      navigationController?.pushViewController(picker, animated: true)
    case 1:
      let picker = NewTabWorkDirPickerViewController(currentId: workDirId)
      picker.onSelect = { [weak self] id in
        self?.workDirId = id
        self?.tableView.reloadData()
      }
      navigationController?.pushViewController(picker, animated: true)
    case 2:
      promptTmuxName()
    default: break
    }
  }

  override func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
    guard editingStyle == .delete, ip.section != _newSection else { return }
    guard !presetGroups.isEmpty,
          ip.section < presetGroups.count,
          ip.row < presetGroups[ip.section].presets.count else { return }
    BlinkSessionPresetStore.shared.delete(id: presetGroups[ip.section].presets[ip.row].id)
    _reloadGroups()
    tv.reloadData()
  }

  override func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool {
    ip.section != _newSection && !presetGroups.isEmpty
  }

  private func promptTmuxName() {
    let alert = UIAlertController(title: "tmux 会话名", message: "存在则 attach，不存在则新建。留空使用默认。", preferredStyle: .alert)
    alert.addTextField { [weak self] tf in
      tf.text = self?.tmuxName ?? ""
      tf.placeholder = "blink"
      tf.autocapitalizationType = .none
      tf.autocorrectionType = .no
      tf.spellCheckingType = .no
      tf.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
      let v = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
      self?.tmuxName = v.isEmpty ? nil : v
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  @objc private func createTapped() {
    guard let mid = machineId else {
      let a = UIAlertController(title: "请先选机器", message: nil, preferredStyle: .alert)
      a.addAction(UIAlertAction(title: "确定", style: .default))
      present(a, animated: true)
      return
    }
    let preset = BlinkSessionPresetStore.shared.upsert(
      machineId: mid,
      workDirId: workDirId,
      baseName: tmuxName ?? ""
    )
    let cb = onCreate
    dismiss(animated: true) {
      cb?(preset.machineId, preset.workDirId, preset.sessionName)
    }
  }
}

final class NewTabMachinePickerViewController: UITableViewController {
  private let currentId: String?
  var onSelect: ((String) -> Void)?

  init(currentId: String?) {
    self.currentId = currentId
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选机器"
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkMachineStore.shared.machines.count
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let m = BlinkMachineStore.shared.machines[ip.row]
    cell.textLabel?.text = m.displayName
    cell.detailTextLabel?.text = "\(m.user)@\(m.host)"
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = (m.id == currentId) ? .checkmark : .none
    return cell
  }
  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    onSelect?(BlinkMachineStore.shared.machines[ip.row].id)
    navigationController?.popViewController(animated: true)
  }
}

final class NewTabWorkDirPickerViewController: UITableViewController {
  private let currentId: String?
  var onSelect: ((String?) -> Void)?

  init(currentId: String?) {
    self.currentId = currentId
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选工作目录"
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    tableView.reloadData()
  }

  override func numberOfSections(in tv: UITableView) -> Int { 1 }
  override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
    BlinkWorkDirStore.shared.workDirs.count + 1  // +1 for "无"
  }
  override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    if ip.row == 0 {
      cell.textLabel?.text = "（无 / home）"
      cell.detailTextLabel?.text = "不 cd"
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = (currentId == nil) ? .checkmark : .none
    } else {
      let wd = BlinkWorkDirStore.shared.workDirs[ip.row - 1]
      cell.textLabel?.text = wd.displayName
      cell.detailTextLabel?.text = wd.path
      cell.detailTextLabel?.textColor = .secondaryLabel
      cell.accessoryType = (wd.id == currentId) ? .checkmark : .none
    }
    return cell
  }
  override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
    tv.deselectRow(at: ip, animated: true)
    if ip.row == 0 {
      onSelect?(nil)
    } else {
      onSelect?(BlinkWorkDirStore.shared.workDirs[ip.row - 1].id)
    }
    navigationController?.popViewController(animated: true)
  }

  @objc private func addTapped() {
    let form = WorkDirFormViewController(editing: nil)
    form.onSaved = { [weak self] wd in
      self?.onSelect?(wd.id)
      DispatchQueue.main.async {
        self?.navigationController?.popViewController(animated: true)
      }
    }
    navigationController?.pushViewController(form, animated: true)
  }
}

// MARK: - 头像渲染辅助

enum AvatarRenderer {
  /// 把图片裁成圆角缩略图，方便 UITableViewCell.imageView 用
  static func roundedThumbnail(from image: UIImage, size: CGSize, cornerRadius: CGFloat? = nil) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      let rect = CGRect(origin: .zero, size: size)
      let r = cornerRadius ?? min(size.width, size.height) / 2  // 默认正圆
      let path = UIBezierPath(roundedRect: rect, cornerRadius: r)
      path.addClip()
      image.draw(in: rect)
    }
  }
}

// MARK: - 头像选择器（DiceBear，公开 API）

final class AvatarPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

  /// 每个 style 提供这一组 seed，组合出 ~150 个头像
  static let seeds: [String] = [
    "aria","bear","cloud","dream","echo","flame","glow","halo","iris","jade",
    "kite","lake","moon","nova","ocean","peach","quartz","river","star","tide",
  ]
  /// DiceBear 9.x 风格，每行 = (展示名, style id)
  static let styles: [(title: String, id: String)] = [
    ("人物（卡通）", "adventurer"),
    ("人物（线条）", "lorelei"),
    ("人物（圆润）", "micah"),
    ("人物（Notion）", "notionists"),
    ("人物（Memoji）", "personas"),
    ("Avataaars", "avataaars"),
    ("Big Smile", "big-smile"),
    ("机器人", "bottts"),
    ("Emoji", "fun-emoji"),
    ("像素", "pixel-art"),
  ]

  /// 选择头像列表用 Alohe 免费头像包（A 风格：Memoji / 立体卡通），CDN 直链
  static let aloheSections: [(title: String, prefix: String, count: Int)] = [
    ("Memoji", "memo", 35),
    ("立体卡通", "vibrent", 27),
  ]
  static func aloheURL(prefix: String, index: Int) -> URL {
    URL(string: "https://cdn.jsdelivr.net/gh/alohe/avatars/png/\(prefix)_\(index).png")!
  }

  var onPick: ((Data) -> Void)?
  /// 最近一次选过的 style id，调用方需要时可读（人物头像 store 用它）
  static var lastPickedStyle: String = "adventurer"
  private let collectionView: UICollectionView

  init() {
    let layout = UICollectionViewFlowLayout()
    layout.itemSize = CGSize(width: 68, height: 68)
    layout.minimumLineSpacing = 12
    layout.minimumInteritemSpacing = 12
    layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
    layout.headerReferenceSize = CGSize(width: 0, height: 36)
    self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "选择头像"
    view.backgroundColor = .systemBackground
    collectionView.backgroundColor = .systemBackground
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(AvatarCell.self, forCellWithReuseIdentifier: "avatar")
    collectionView.register(AvatarSectionHeader.self,
                            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                            withReuseIdentifier: "h")
    collectionView.frame = view.bounds
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(collectionView)
  }

  func numberOfSections(in cv: UICollectionView) -> Int { Self.aloheSections.count }

  func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
    Self.aloheSections[s].count
  }

  func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
    let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h", for: ip) as! AvatarSectionHeader
    h.titleLabel.text = Self.aloheSections[ip.section].title
    return h
  }

  func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
    let cell = cv.dequeueReusableCell(withReuseIdentifier: "avatar", for: ip) as! AvatarCell
    let url = Self.aloheURL(prefix: Self.aloheSections[ip.section].prefix, index: ip.item + 1)
    cell.load(url: url)
    return cell
  }

  func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
    let url = Self.aloheURL(prefix: Self.aloheSections[ip.section].prefix, index: ip.item + 1)
    DiceBearLoader.shared.fetch(url: url) { [weak self] data in
      guard let self, let data else { return }
      DispatchQueue.main.async {
        self.onPick?(data)
        self.navigationController?.popViewController(animated: true)
      }
    }
  }

  static func urlFor(style: String, seed: String, size: Int) -> URL {
    var comps = URLComponents(string: "https://api.dicebear.com/9.x/\(style)/png")!
    comps.queryItems = [
      URLQueryItem(name: "seed", value: seed),
      URLQueryItem(name: "size", value: String(size)),
    ]
    return comps.url!
  }
}

/// 员工头像 store：员工名 → PNG 数据。没自定义就 fallback 到 DiceBear 自动生成（seed = 员工名）
@objc final class BlinkPeopleStore: NSObject {
  @objc static let shared = BlinkPeopleStore()
  private let kKey = "BlinkPeopleStore.avatars"   // [name: Data] base64-string
  private let kStyleKey = "BlinkPeopleStore.styles"  // [name: styleId]
  private let kNamesKey = "BlinkPeopleStore.names"   // [String]，员工名单（手动维护）
  static let defaultStyle = "thumbs"
  static let defaultNames = ["tom", "candy", "bella", "apple", "jack", "dave", "adam", "alice"]

  private override init() {
    super.init()
    if let data = try? JSONEncoder().encode(Self.defaultNames) {
      UserDefaults.standard.register(defaults: [kNamesKey: data])
    }
  }

  var knownNames: [String] {
    get {
      guard let data = UserDefaults.standard.data(forKey: kNamesKey),
            let arr = try? JSONDecoder().decode([String].self, from: data) else {
        return Self.defaultNames
      }
      return arr
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: kNamesKey)
      }
    }
  }

  func addName(_ name: String) {
    let n = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !n.isEmpty else { return }
    var arr = knownNames
    if !arr.contains(n) { arr.append(n); knownNames = arr }
  }

  func removeName(_ name: String) {
    let n = name.lowercased()
    knownNames = knownNames.filter { $0 != n }
    var m = avatarMap; m.removeValue(forKey: n); avatarMap = m
    var sm = styleMap; sm.removeValue(forKey: n); styleMap = sm
  }

  private var avatarMap: [String: Data] {
    get {
      guard let dict = UserDefaults.standard.dictionary(forKey: kKey) as? [String: String] else { return [:] }
      var out: [String: Data] = [:]
      for (k, v) in dict { if let d = Data(base64Encoded: v) { out[k] = d } }
      return out
    }
    set {
      let encoded = newValue.mapValues { $0.base64EncodedString() }
      UserDefaults.standard.set(encoded, forKey: kKey)
    }
  }

  private var styleMap: [String: String] {
    get { (UserDefaults.standard.dictionary(forKey: kStyleKey) as? [String: String]) ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: kStyleKey) }
  }

  func customIcon(for name: String) -> UIImage? {
    guard let d = avatarMap[name.lowercased()], let img = UIImage(data: d) else { return nil }
    return img
  }

  func setIcon(_ data: Data, for name: String, style: String? = nil) {
    var m = avatarMap; m[name.lowercased()] = data; avatarMap = m
    if let s = style { var sm = styleMap; sm[name.lowercased()] = s; styleMap = sm }
  }

  func style(for name: String) -> String {
    styleMap[name.lowercased()] ?? Self.defaultStyle
  }

  /// 取头像（同步 fast-path）：先看自定义；没有就看 DiceBear 缓存；都没有返 nil（让调用方异步 fetch）
  func iconSync(for name: String, size: Int = 96) -> UIImage? {
    if let img = customIcon(for: name) { return img }
    let url = AvatarPickerViewController.urlFor(style: style(for: name), seed: name.lowercased(), size: size)
    if let d = DiceBearLoader.shared.cached(url: url), let img = UIImage(data: d) { return img }
    return nil
  }

  /// 异步取头像：custom > 缓存 > 远端 fetch
  func iconAsync(for name: String, size: Int = 96, completion: @escaping (UIImage?) -> Void) {
    if let img = iconSync(for: name, size: size) { completion(img); return }
    let url = AvatarPickerViewController.urlFor(style: style(for: name), seed: name.lowercased(), size: size)
    DiceBearLoader.shared.fetch(url: url) { data in
      DispatchQueue.main.async { completion(data.flatMap { UIImage(data: $0) }) }
    }
  }
}

/// 简单的 URL→Data 内存缓存 + 单飞合并
final class DiceBearLoader {
  static let shared = DiceBearLoader()
  private let cache = NSCache<NSURL, NSData>()
  private let queue = DispatchQueue(label: "dicebear.loader")
  private var inflight: [NSURL: [(Data?) -> Void]] = [:]

  init() { cache.countLimit = 300 }

  func cached(url: URL) -> Data? {
    cache.object(forKey: url as NSURL) as Data?
  }

  func fetch(url: URL, completion: @escaping (Data?) -> Void) {
    if let d = cached(url: url) { completion(d); return }
    queue.async {
      if var arr = self.inflight[url as NSURL] {
        arr.append(completion)
        self.inflight[url as NSURL] = arr
        return
      }
      self.inflight[url as NSURL] = [completion]
      URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let self else { return }
        if let data { self.cache.setObject(data as NSData, forKey: url as NSURL) }
        self.queue.async {
          let callbacks = self.inflight.removeValue(forKey: url as NSURL) ?? []
          for cb in callbacks { cb(data) }
        }
      }.resume()
    }
  }
}

final class AvatarCell: UICollectionViewCell {
  private let iv = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var currentURL: URL?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.layer.cornerRadius = 12
    contentView.backgroundColor = .secondarySystemBackground
    contentView.clipsToBounds = true

    iv.contentMode = .scaleAspectFit
    iv.translatesAutoresizingMaskIntoConstraints = false
    spinner.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(iv)
    contentView.addSubview(spinner)
    NSLayoutConstraint.activate([
      iv.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      iv.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
      iv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      iv.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    iv.image = nil
    currentURL = nil
    spinner.stopAnimating()
  }

  func load(url: URL) {
    currentURL = url
    if let d = DiceBearLoader.shared.cached(url: url) {
      iv.image = UIImage(data: d)
      spinner.stopAnimating()
      return
    }
    spinner.startAnimating()
    DiceBearLoader.shared.fetch(url: url) { [weak self] data in
      DispatchQueue.main.async {
        guard let self, self.currentURL == url else { return }  // cell 已复用
        self.spinner.stopAnimating()
        if let data { self.iv.image = UIImage(data: data) }
      }
    }
  }
}

final class AvatarSectionHeader: UICollectionReusableView {
  let titleLabel = UILabel()
  override init(frame: CGRect) {
    super.init(frame: frame)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabel
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
}
