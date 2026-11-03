import Foundation
import Combine

/// Opt-in, bounded, memory-only telemetry. No audio, credentials, raw JSON or device IDs.
@MainActor final class DisplayObservation: ObservableObject {
    static let shared = DisplayObservation()
    @Published var enabled = false
    @Published var includesText = false { didSet { if !includesText { question = ""; answer = ""; events.removeAll() } } }
    private(set) var connected = false
    private(set) var phase = "unknown"
    private(set) var page: [String: Any] = [:]
    private(set) var screen: Int64?
    private(set) var question = ""
    private(set) var answer = ""
    private var round: String?
    private(set) var events: [[String: Any]] = []
    private var sequence = 0
    private(set) var session = UUID().uuidString
    private var lastInbound: Double?
    private static func bounded(_ text: String, bytes: Int) -> String {
        // Bound bytes, not grapheme clusters (a single cluster may contain many scalars).
        String(decoding:text.utf8.prefix(bytes),as:UTF8.self)
    }
    func newUtterance() { guard enabled else { return }; question = ""; answer = ""; round = nil }
    private let apps = ["com.rayneo.liteos.recorder":"録音", "com.rayneo.liteos.aiSubtitle":"字幕",
        "com.rayneo.liteos.conversationAssist":"リアルタイムヒント", "com.rayneo.liteos.todo":"ToDo",
        "com.rayneo.liteos.prompter":"プロンプター", "com.rayneo.liteos.ai_memory":"終日記録"]
    func reset() {
        page = [:]; screen = nil; question = ""; answer = ""; round = nil
        events = []; sequence = 0; lastInbound = nil; session = UUID().uuidString
    }
    func connection(_ ready: Bool, phase: String) {
        if connected != ready {
            connected = ready
            if enabled { event("connection", detail: ready ? "単一のグラスが認証済み" : "グラス接続が利用できません。古いレポートは無効です") }
            // A new link must earn a new page observation; never label old data current.
            page = [:]; screen = nil; lastInbound = nil; question = ""; answer = ""; round = nil
        }
        self.phase = String(phase.prefix(60))
    }
    func loss() { guard enabled else { return }; page = [:]; screen = nil; event("loss", detail: "受信キューでパケットロス。ページ状態は不明です") }
    func voiceMetadata(type: UInt32) {
        guard enabled, connected, ![3,163,164].contains(type) else { return }
        lastInbound = Date().timeIntervalSince1970
        event("received",detail:"アシスタント上りタイプ \(type) · タイプのみ観察",business:13,type:type)
    }
    func packet(_ data: Data, business: UInt8, inbound: Bool) {
        guard enabled, connected, data.count <= 131_100,
              [13,14,15,20,21,22].contains(business), let wire = try? DeviceBusinessWire(data) else { return }
        if business == 13, [3,163,164].contains(wire.type) { return } // Never retain audio.
        if business == 14, !wire.bytes.isEmpty { return }
        let now = Date().timeIntervalSince1970
        if inbound { lastInbound = now }
        var detail = "業務 \(business) / タイプ \(wire.type) · \(data.count) B"
        let j = wire.json
        if inbound, business == 15, wire.type == 24, j["cmd"] as? String == "glass_preview",
           let payload = j["payload"] as? [String: Any], let raw = payload["data"] as? String,
           raw.utf8.count <= 16_384, let bytes = raw.data(using: .utf8),
           let p = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let scene = DeviceBusinessWire.integer(p,"scence") ?? DeviceBusinessWire.integer(p,"scene") {
            var result: [String:Any] = ["scene":scene,"name":[0:"ダッシュボード",1:"アプリメニュー",2:"アプリページ"][scene] ?? "不明なシーン", "at":now]
            if let index = DeviceBusinessWire.integer(p,"index") { result["index"] = index }
            if let app = p["app"] as? [String:Any] {
                result["app"] = apps[app["name"] as? String ?? ""] ?? "不明なアプリ"
                if let action = DeviceBusinessWire.integer(app,"action") { result["action"] = action }
            }
            // Exit is an event, not evidence that the exited app remains on screen.
            if result["action"] as? Int64 == 2 { result["name"] = "アプリは終了しました。次のページを待機中" }
            page = result; detail = "glass_preview · \(result["name"] ?? "不明") · \(result["app"] ?? "")"
        }
        if inbound, business == 15, j["cmd"] as? String == "screen_status",
           let payload = j["payload"] as? [String:Any], let value = DeviceBusinessWire.integer(payload,"value") {
            screen = value; detail = "screen_status 生の値 \(value)（ピクセルは推定しません）"
        }
        var text: String?
        if !inbound, includesText {
            if business == 13, wire.type == 5, let value = j["text"] as? String {
                question = Self.bounded(value,bytes:4096); text = question
            }
            if business == 13, wire.type == 32, let payload = j["answer"] as? [String:Any], let value = payload["text"] as? String {
                let next = j["uuid"] as? String
                if next != round { answer = ""; round = next }
                answer = Self.bounded(answer + value,bytes:16384); text = value
            }
            if business == 21, wire.type == 2 {
                text = ["title","subtitle","content"].compactMap { j[$0] as? String }.joined(separator:"\n")
            }
        }
        event(inbound ? "received" : "submitted", detail: detail, business: business, type: wire.type, text: text)
    }
    private func event(_ kind: String, detail: String, business: UInt8? = nil, type: UInt32? = nil, text: String? = nil) {
        sequence += 1
        var e: [String:Any] = ["id":sequence,"at":Date().timeIntervalSince1970,"kind":kind,"detail":detail]
        if let business { e["business"] = business }; if let type { e["type"] = type }
        if includesText, let text, !text.isEmpty {
            e["text"] = Self.bounded(text,bytes:256)
            e["textTruncated"] = text.utf8.count > 256
        }
        events.append(e); if events.count > 80 { events.removeFirst(events.count - 80) }
    }
    func snapshot() -> [String:Any] {
        var value: [String:Any] = ["version":1,"session":session,"sampledAt":Date().timeIntervalSince1970,
            "connected":connected,"phase":phase,"includesText":includesText,"page":page,
            "question":includesText ? question : "","answer":includesText ? answer : "","events":events,
            "notice":"ページは状態の再描画であり、レンズのスクリーンショットではありません。submitted は SDK への送信成功のみを意味します。"]
        if let screen { value["screenRaw"] = screen }; if let lastInbound { value["lastInbound"] = lastInbound }
        return value
    }
}
