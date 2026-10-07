import Foundation
import Security

private struct ServerLoginResponse: Decodable { let token: String }
private struct ServerVoiceConfig: Decodable { let model: String; let baseURL: String; let apiKey: String; let debounce: Double }
private struct ServerAIConfig: Decodable { let userGlossary: String; let voice: ServerVoiceConfig? }
private struct ServerSnapshot: Decodable { let aiConfig: ServerAIConfig? }

/// macOS reads the same account token as the iOS client. Local UserDefaults are
/// intentionally untouched when the server is unavailable, so dictation keeps
/// its existing offline fallback.
final class VoiceServerConfigSync {
    static let shared = VoiceServerConfigSync()
    private let baseURL = URL(string: "https://blink-api.douwantech.com")!
    private init() {}

    func refresh() {
        guard let token = readToken() else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/config"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let snapshot = try? JSONDecoder().decode(ServerSnapshot.self, from: data),
                  let ai = snapshot.aiConfig else { return }
            if let voice = ai.voice { AITextPolisher.shared.applySharedEngineConfig(model: voice.model, baseURL: voice.baseURL, apiKey: voice.apiKey, debounce: voice.debounce) }
            AITextPolisher.shared.setSharedGlossary(ai.userGlossary)
        }.resume()
    }

    func login(username: String, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/login")); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let value = try? JSONDecoder().decode(ServerLoginResponse.self, from: data) else { completion(.failure(NSError(domain: "VoiceServer", code: 401))); return }
            let token = Data(value.token.utf8)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.douwantech.blink.config-server", kSecAttrAccount as String: "session", kSecValueData as String: token]
            SecItemDelete(query as CFDictionary); let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { self.refresh(); completion(.success(())) } else { completion(.failure(NSError(domain: "VoiceServer", code: Int(status)))) }
        }.resume()
    }

    private func readToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.douwantech.blink.config-server", kSecAttrAccount as String: "session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
