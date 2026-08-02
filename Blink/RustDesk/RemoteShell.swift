import Foundation
import Combine
import SSH
import BlinkConfig

/// 一次性 SSH exec:连到 host 跑一条命令,收集 stdout 返回。
/// 复用 Blink 的 SSH 栈(SSHPool.dial + requestExec),认证走 Blink 现有 key/agent 体系
/// (和终端 ssh 一样,免密靠 AutoMac key)。用法参照 BlinkAssistantChat.execRemote。
enum RemoteShellError: Error { case config(String), exec(String) }

final class RemoteShell {
  private static var bags: [ObjectIdentifier: AnyCancellable] = [:]
  private static let lock = NSLock()

  static func run(host: String, user: String, command: String) async throws -> String {
    let (hostName, config) = try buildConfig(host: host, user: user)
    return try await withCheckedThrowingContinuation { cont in
      var resumed = false
      var out = Data()
      let token = ObjectIdentifier(NSObject())

      let pub = SSHPool.dial(hostName, with: config, withProxy: BlinkSSH.executeProxyCommand)
        .flatMap { $0.requestExec(command: command) }
        .flatMap { stream -> AnyPublisher<DispatchData, Error> in
          stream.read(max: 1024 * 1024)
        }

      let cancel = pub.sink(
        receiveCompletion: { c in
          lock.lock(); bags[token] = nil; lock.unlock()
          guard !resumed else { return }
          resumed = true
          switch c {
          case .finished:
            cont.resume(returning: String(data: out, encoding: .utf8) ?? "")
          case .failure(let e):
            cont.resume(throwing: RemoteShellError.exec("\(e)"))
          }
        },
        receiveValue: { dd in
          dd.enumerateBytes { region, _, _ in out.append(contentsOf: region) }
        }
      )
      lock.lock(); bags[token] = cancel; lock.unlock()
    }
  }

  private static func buildConfig(host: String, user: String) throws -> (String, SSHClientConfig) {
    let params: [String: Any] = ["user": user]
    guard let commandHost = try? BKSSHHost(content: params) else {
      throw RemoteShellError.config("BKSSHHost")
    }
    guard let resolved = try? BKConfig().resolveHost(alias: host, extending: commandHost) else {
      throw RemoteShellError.config("resolveHost")
    }
    let device = TermDevice()
    guard let config = try? SSHClientConfigProvider.config(host: resolved.host, using: device) else {
      throw RemoteShellError.config("config")
    }
    return (resolved.hostName, config)
  }
}
