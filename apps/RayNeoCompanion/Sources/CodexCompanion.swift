import Foundation
import Combine
import Security

enum CodexBridgeError: LocalizedError {
    case configuration, missingKey, offline, invalidResponse, rejected(String), unknownDelivery
    var errorDescription: String? {
        switch self {
        case .configuration: return "アカウントやクエリパラメータを含まない HTTPS のブリッジアドレスを入力してください。HTTP のループバックアドレスはシミュレータでのみ許可されます。"
        case .missingKey: return "先にこのブリッジアドレス用の専用トークンを保存してください。"
        case .offline: return "ブリッジに接続していません。PCのサービスとネットワークを確認してください。"
        case .invalidResponse: return "ブリッジの応答が無効か、バージョンが一致しません。"
        case .rejected(let code): return "ブリッジがリクエストを受け付けませんでした（\(code)）。自動再試行はしません。"
        case .unknownDelivery: return "前回の送信結果が不明です。「前回の送信を確認」を押してください。タスクを重複して作らないでください。"
        }
    }
}

enum CodexEndpoint {
    static func normalize(_ text: String, allowLoopback: Bool = false) throws -> String {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.url != nil, c.path.isEmpty || c.path == "/",
              c.scheme == "https" || (allowLoopback && c.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)) else { throw CodexBridgeError.configuration }
        c.path = ""; c.host = host.lowercased()
        return c.string!
    }
    static var simulatorLoopback: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

enum CodexTokenVault {
    static func get(_ endpoint: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.turboio.codex", kSecAttrAccount as String: endpoint, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, endpoint: String) throws {
        guard token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw CodexBridgeError.missingKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.turboio.codex", kSecAttrAccount as String: endpoint]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let rc = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if rc == errSecItemNotFound {
            guard SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw CodexBridgeError.missingKey }
        } else if rc != errSecSuccess { throw CodexBridgeError.missingKey }
    }
}

struct CodexQuestion: Decodable, Identifiable { let id: String; let question: String; let options: [String] }
struct CodexApproval: Decodable, Identifiable {
    let id: String; let taskId: String; let turnId: String; let kind: String; let summary: String
    let questions: [CodexQuestion]; let expiresAt: Double
}
struct CodexTaskState: Decodable, Identifiable {
    let id: String; let threadId: String; let turnId: String?; let status: String; let answer: String; let pending: [CodexApproval]
}
struct CodexBridgeState: Decodable {
    let protocolVersion: Int; let online: Bool; let workspace: String; let readOnly: Bool; let tasks: [CodexTaskState]
    let events: [CodexPushEvent]?
}
private final class CodexNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CodexHTTP {
    static func call(endpoint: String, token: String, path: String, body: Data?) async throws -> Data {
        let allowed = ["/v1/state", "/v1/message", "/v1/stop", "/v1/decision"]
        guard allowed.contains(path), token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil else { throw CodexBridgeError.configuration }
        let base = try CodexEndpoint.normalize(endpoint, allowLoopback: CodexEndpoint.simulatorLoopback)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35; config.timeoutIntervalForResource = 40
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: CodexNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexBridgeError.invalidResponse }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); data.append(byte); guard data.count <= 2_097_152 else { throw CodexBridgeError.invalidResponse } }
        guard http.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let raw = object?["error"] as? String ?? "http_\(http.statusCode)"
            let safe = raw.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil ? raw : "request_failed"
            throw CodexBridgeError.rejected(safe)
        }
        return data
    }
}

/// One catalogue supplies both the model request and the read-only tools UI.
struct CodexToolDescriptor: Identifiable {
    let id: String
    let title: String
    let description: String
    let example: String
    let requiresText: Bool
    var definition: [String: Any] {
        ["type": "function", "function": ["name": id, "description": description,
            "parameters": ["type": "object", "properties": requiresText ? ["text": ["type": "string", "description": "ユーザーがCodexへ渡す完全な依頼文。権限を付け加えないこと"]] : [:],
                "required": requiresText ? ["text"] : [], "additionalProperties": false]]]
    }
    var schemaJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: definition, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "ツール定義を表示できません" }
        return text
    }
    static let all: [Self] = [
        .init(id: "codex_message", title: "タスクを開始 / 継続", description: "ユーザーがCodexにプログラミングタスクの実行や継続を明示的に求めたときだけ呼び出すこと。Appで選択中のタスクへ送り、未選択の場合のみ新規作成する。通常の雑談や権限の承認には使わない。", example: "Codexにこのプロジェクトのディレクトリ構成を調べてもらって", requiresText: true),
        .init(id: "codex_status", title: "進捗と結果を照会", description: "ユーザーがCodexの現在のタスクの進捗や結果を尋ねたときに呼び出すこと。", example: "Codexは終わった？結果は？", requiresText: false),
        .init(id: "codex_stop", title: "現在のタスクを停止", description: "ユーザーがCodexの現在のタスクの停止を明示的に求めたときだけ呼び出すこと。返答の読み上げを止めることはCodexの停止とは違う。", example: "Codexの現在のタスクを止めて", requiresText: false)
    ]
}

/// Tool calls cannot approve: approvals only enter through the explicit native UI.
@MainActor final class CodexCompanion: ObservableObject {
    @Published private(set) var endpoint: String
    @Published private(set) var voiceToolsEnabled: Bool
    @Published private(set) var state: CodexBridgeState?
    @Published private(set) var status = "PCブリッジに未接続"
    @Published private(set) var busy = false
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var hasUnknownDelivery = false
    private let defaults: UserDefaults
    private let key: (String) -> String?
    private let send: (String, String, String, Data?) async throws -> Data
    private var refreshing = false
    private var generation = UUID()
    private let prefix = "companion.codex.v1."
    var selected: CodexTaskState? { state?.tasks.first { $0.id == selectedTaskID } }
    var configured: Bool { !endpoint.isEmpty && key(endpoint) != nil }
    init(defaults: UserDefaults = .standard, key: @escaping (String) -> String? = CodexTokenVault.get,
         send: @escaping (String, String, String, Data?) async throws -> Data = CodexHTTP.call) {
        self.defaults = defaults; self.key = key; self.send = send
        endpoint = defaults.string(forKey: "companion.codex.v1.endpoint") ?? ""
        voiceToolsEnabled = defaults.bool(forKey: "companion.codex.v1.voiceTools")
        selectedTaskID = defaults.string(forKey: "companion.codex.v1.selected")
        hasUnknownDelivery = defaults.data(forKey: "companion.codex.v1.pending") != nil
    }
    func save(endpoint input: String, token: String, voiceTools: Bool) throws {
        guard !busy, !hasUnknownDelivery else { throw CodexBridgeError.unknownDelivery }
        let normalized = try CodexEndpoint.normalize(input, allowLoopback: CodexEndpoint.simulatorLoopback)
        if !token.isEmpty { try CodexTokenVault.save(token, endpoint: normalized) }
        guard key(normalized) != nil else { throw CodexBridgeError.missingKey }
        if normalized != endpoint { selectedTaskID = nil; defaults.removeObject(forKey: prefix + "selected") }
        generation = UUID(); state = nil; endpoint = normalized; voiceToolsEnabled = voiceTools
        defaults.set(endpoint, forKey: prefix + "endpoint"); defaults.set(voiceTools, forKey: prefix + "voiceTools")
        status = "設定を保存しました。まだ接続していません。音声ツールは\(voiceTools ? "許可" : "オフ")です"
    }
    func select(_ id: String?) {
        guard !busy, !hasUnknownDelivery, id == nil || state?.tasks.contains(where: { $0.id == id }) == true else { return }
        selectedTaskID = id; defaults.set(id, forKey: prefix + "selected")
    }
    func refresh() async {
        guard !refreshing, configured else { return }; refreshing = true; defer { refreshing = false }
        let current = generation, base = endpoint
        do {
            let data = try await send(base, key(base)!, "/v1/state", nil)
            let value = try JSONDecoder().decode(CodexBridgeState.self, from: data)
            guard current == generation else { return }
            guard value.protocolVersion == 1, value.tasks.count <= 16, (value.events?.count ?? 0) <= 128 else { throw CodexBridgeError.invalidResponse }
            state = value; status = value.online ? "PCブリッジはオンライン · \(value.readOnly ? "読み取り専用テスト" : "ワークスペース書き込み可、承認が必要な場合は項目ごとに確認")" : "Codex プロセスはオフライン"
        } catch {
            guard current == generation else { return }; state = nil
            status = (error as? CodexBridgeError)?.localizedDescription ?? "ブリッジ接続に失敗しました。タスクは自動送信していません"
        }
    }
    private func mutate(_ path: String, body: [String: Any]) async throws -> String {
        guard !busy else { throw CodexBridgeError.rejected("bridge_busy") }
        guard !hasUnknownDelivery else { throw CodexBridgeError.unknownDelivery }
        guard let token = key(endpoint), !endpoint.isEmpty else { throw CodexBridgeError.missingKey }
        let data = try JSONSerialization.data(withJSONObject: body)
        let pending = try JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "path": path, "body": body])
        // At-most-once recovery retains user text locally until outcome is resolved.
        defaults.set(pending, forKey: prefix + "pending"); hasUnknownDelivery = true
        return try await deliver(path, data: data, token: token)
    }
    private func deliver(_ path: String, data: Data, token: String) async throws -> String {
        busy = true; defer { busy = false }
        do {
            let response = try await send(endpoint, token, path, data)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object["accepted"] as? Bool == true, let id = object["taskId"] as? String else { throw CodexBridgeError.invalidResponse }
            selectedTaskID = id; defaults.set(id, forKey: prefix + "selected")
            defaults.removeObject(forKey: prefix + "pending"); hasUnknownDelivery = false
            status = "送信しました。実際の実行結果はタスク状態で確認してください"; await refresh(); return id
        } catch { status = "送信結果は未確認です。自動で再送はしません"; throw error }
    }
    func retryPending() async {
        guard !busy, let pending = defaults.data(forKey: prefix + "pending"),
              let object = (try? JSONSerialization.jsonObject(with: pending)) as? [String: Any],
              object["endpoint"] as? String == endpoint, let path = object["path"] as? String,
              let body = object["body"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: body), let token = key(endpoint) else { return }
        do { _ = try await deliver(path, data: data, token: token) } catch { status = "前回の送信はまだ未確認です。元のリクエスト番号を保持し、重複タスクは作っていません" }
    }
    func message(_ text: String, requestID: String = UUID().uuidString) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192 else { throw CodexBridgeError.rejected("invalid_text") }
        var body: [String: Any] = ["text": text, "requestId": requestID]
        if let id = selectedTaskID { body["taskId"] = id }
        return try await mutate("/v1/message", body: body)
    }
    func stop(requestID: String = UUID().uuidString) async throws {
        guard let id = selectedTaskID else { throw CodexBridgeError.rejected("no_selected_task") }
        _ = try await mutate("/v1/stop", body: ["taskId": id, "requestId": requestID])
    }
    func decide(_ request: CodexApproval, approve: Bool, answers: [String: String] = [:]) async throws {
        guard let task = selected, task.id == request.taskId, task.pending.contains(where: { $0.id == request.id }),
              request.expiresAt > Date().timeIntervalSince1970 * 1000 else { throw CodexBridgeError.rejected("stale_request") }
        _ = try await mutate("/v1/decision", body: ["taskId": task.id, "approvalId": request.id, "decision": approve ? "accept" : "decline", "answers": answers, "requestId": UUID().uuidString])
    }
    var toolDefinitions: [[String: Any]] {
        guard voiceToolsEnabled, configured else { return [] }
        return CodexToolDescriptor.all.map(\.definition)
    }
    func executeTool(name: String, arguments: String, requestID: UUID) async -> String {
        guard voiceToolsEnabled, configured, !Task.isCancelled else { return "Codex ツールがオンになっていません。" }
        do {
            guard arguments.utf8.count <= 9000, let obj = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw CodexBridgeError.invalidResponse }
            switch name {
            case "codex_message":
                guard obj.count == 1, let text = obj["text"] as? String else { throw CodexBridgeError.invalidResponse }
                let id = try await message(text, requestID: requestID.uuidString)
                return "Codexへ渡しました。タスク番号は\(id.prefix(4))です。タスクは実行を続けます。進捗は後で聞けます。承認が必要な場合はスマホで確認してください。"
            case "codex_status":
                guard obj.isEmpty else { throw CodexBridgeError.invalidResponse }; await refresh()
                guard state?.online == true, let task = selected else { return "現在のCodexタスクの状態をまだ取得できていません。Turbo IOのCodexページで接続し、タスクを選択してください。" }
                return "Codex：\(task.status)。\(String(task.answer.suffix(350)))" + (task.pending.isEmpty ? "" : "具体的な質問や承認はスマホで確認してください。")
            case "codex_stop":
                guard obj.isEmpty else { throw CodexBridgeError.invalidResponse }; try await stop(requestID: requestID.uuidString)
                return "Codexへ現在のタスクの停止を依頼しました。最終状態はタスクページで確認してください。"
            default: return "このツールには対応していません。何も実行していません。"
            }
        } catch { return "Codexのリクエストの成功を確認できませんでした。スマホで確認してください。自動再試行も承認もしていません。" }
    }
}
