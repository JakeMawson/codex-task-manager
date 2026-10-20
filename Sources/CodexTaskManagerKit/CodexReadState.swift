import CryptoKit
import Foundation

/// Codex Desktop's v1 read store is scoped to an authenticated identity and
/// execution host. Never union accounts or use its one-time migration record.
struct CodexReadContext: Equatable, Sendable {
    let identity: JSONValue
    let identityKey: String
    let executionHostKey: String

    var json: JSONValue {
        .object(["identity": identity, "executionHostKey": .string(executionHostKey)])
    }

    static func local(codexHome: URL) throws -> Self {
        let unavailable = CodexTaskRepositoryError.updateGlobalState(
            "Could not resolve Codex's current unread account. Open Codex and sign in, then refresh."
        )
        // Read only the identity claims. Tokens never leave this function or
        // enter IPC, logs, preferences, or Task Manager's persisted state.
        guard let data = try? Data(contentsOf: codexHome.appending(path: "auth.json")),
              let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw unavailable }
        let identity: JSONValue
        let identityParts: [String]
        if auth["auth_mode"] as? String == "chatgpt" {
            guard let tokens = auth["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String,
                  token.split(separator: ".").count == 3
            else { throw unavailable }
            var payload = String(token.split(separator: ".")[1])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let claimsData = Data(base64Encoded: payload),
                  let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
                  let principal = claims["https://api.openai.com/auth"] as? [String: Any],
                  let account = (principal["chatgpt_account_id"] ?? principal["account_id"]) as? String, !account.isEmpty,
                  let user = (principal["user_id"] ?? principal["chatgpt_user_id"]) as? String, !user.isEmpty
            else { throw unavailable }
            identity = .object(["kind": .string("chatgpt"), "accountId": .string(account), "userId": .string(user)])
            identityParts = ["chatgpt", account, user]
        } else if auth["auth_mode"] as? String == "apikey" {
            identity = .object(["kind": .string("execution-storage"), "authMode": .string("apikey")])
            identityParts = ["execution-storage", "apikey"]
        } else { throw unavailable }
        let identityData = try JSONSerialization.data(withJSONObject: identityParts, options: [.withoutEscapingSlashes])
        let hostData = Data(#"["local","local",null]"#.utf8)
        return Self(identity: identity, identityKey: hash(identityData), executionHostKey: "local:" + hash(hostData))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CodexUnreadState: Sendable {
    let ids: Set<String>
    let context: CodexReadContext?

    static func read(codexHome: URL) throws -> Self {
        let url = codexHome.appending(path: ".codex-global-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(ids: [], context: nil) }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        if let modern = root["electron-thread-read-state-v1"] {
            guard let store = modern as? [String: Any], store["version"] as? Int == 1,
                  let identities = store["unreadByIdentity"] as? [String: [String: [String]]]
            else { throw CodexTaskRepositoryError.query("Codex's unread-state format is unsupported. Refresh or update Task Manager.") }
            let context = try CodexReadContext.local(codexHome: codexHome)
            let hosts = identities[context.identityKey] ?? [:]
            if hosts[context.executionHostKey] == nil && hosts.keys.contains(where: { $0.hasPrefix("local:") }) {
                throw CodexTaskRepositoryError.query("Codex uses a different local execution host. Its unread state cannot be safely matched.")
            }
            return Self(ids: Set(hosts[context.executionHostKey] ?? []), context: context)
        }
        let persisted = root["electron-persisted-atom-state"] as? [String: Any]
        let hosts = persisted?["unread-thread-ids-by-host-v1"] as? [String: [String]]
        return Self(ids: Set(hosts?["local"] ?? []), context: nil)
    }
}
