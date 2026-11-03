import Foundation
import SwiftUI
import RayNeoDisplay

/// A deliberately isolated, on-device test for the observed suggestion-card
/// lifecycle. It does not call a network service, execute a tool, or turn a
/// head gesture into an approval outside this test page.
@MainActor
final class HeadControlNotificationTest: ObservableObject {
    @Published private(set) var status = "テストカードは未送信"
    @Published private(set) var lastDecision: String?
    @Published private(set) var error: String?
    @Published private(set) var pendingID: String?
    @Published private(set) var expiresAt: Date?

    private let device: () -> String?
    private let available: () -> Bool
    private let transport: (UInt8, Data) throws -> Void
    private let now: () -> Date
    private let timeout: TimeInterval
    private let scheduleTimers: Bool
    private var pendingDevice: String?
    private var expiryTask: Task<Void, Never>?
    private let cardCodec = SuggestionCardJSONCodec()
    private let operationCodec = SuggestionJSONCodec()

    init(device: @escaping () -> String?, available: @escaping () -> Bool,
         transport: @escaping (UInt8, Data) throws -> Void,
         now: @escaping () -> Date = Date.init, timeout: TimeInterval = 30,
         scheduleTimers: Bool = true) {
        self.device = device
        self.available = available
        self.transport = transport
        self.now = now
        self.timeout = timeout
        self.scheduleTimers = scheduleTimers
    }

    deinit { expiryTask?.cancel() }

    var canSend: Bool { pendingID == nil && device() != nil && available() }
    var hasPendingCard: Bool { pendingID != nil }

    func send(title: String, source: String, content: String) {
        guard canSend, let connectedDevice = device() else {
            error = "接続済みで空いているグラスが1つだけ必要です。テストカードは送信していません。"
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanSource.isEmpty, !cleanContent.isEmpty else {
            error = "タイトル・出典・内容はいずれも空にできません。"
            return
        }

        let id = UUID().uuidString.lowercased()
        do {
            try sendMessage(cardCodec.encodeAppRequest(.add(
                suggestUID: id, suggestType: .todo,
                title: cleanTitle, source: cleanSource, content: cleanContent,
                timeRange: nil)))
            pendingID = id
            pendingDevice = connectedDevice
            expiresAt = now().addingTimeInterval(timeout)
            lastDecision = nil
            error = nil
            status = "テストカードを送信済み。うなずきか首振りを待っています（(Int(timeout)) 秒）"
            scheduleExpiry(for: id)
        } catch {
            self.error = "テストカードは送信されませんでした：\(error.localizedDescription)"
        }
    }

    /// Explicitly removes only the card created by this page. No acknowledgement
    /// or external action is emitted for a locally cancelled test.
    func cancel() {
        guard let id = pendingID else { return }
        do {
            try sendMessage(cardCodec.encodeAppRequest(.delete(suggestUID: id, suggestType: .todo)))
            clearPending(status: "テストカードの削除をリクエスト済み", decision: nil)
        } catch {
            self.error = "テストカードを削除できませんでした：\(error.localizedDescription)"
        }
    }

    func connectionChanged() {
        guard pendingID != nil else { return }
        clearPending(status: "接続が変わりました。このテストカードの待機を停止しました", decision: nil)
    }

    func receive(device incomingDevice: String, wire: DeviceBusinessWire) {
        guard wire.type == 34, let id = pendingID, incomingDevice == pendingDevice else { return }
        do {
            let payload = try JSONSerialization.data(withJSONObject: wire.json, options: [.sortedKeys])
            guard case let .operation(operation) = try operationCodec.decodeGlassesOperation(type: 34, payload: payload),
                  operation.suggestUID == id, operation.suggestType == SuggestionCardCategory.todo.rawValue else { return }
            switch operation.command {
            case .accept: complete(id: id, decision: "うなずきによる確認を受信（テスト用コールバックのみ）")
            case .reject: complete(id: id, decision: "首振りによるキャンセルを受信（テスト用コールバックのみ）")
            case .unknown: return
            }
        } catch {
            self.error = "一致しないヘッドコントロールの応答を無視しました。"
        }
    }

    private func complete(id: String, decision: String) {
        // Consume locally before outbound cleanup so duplicate BLE delivery can
        // never turn into a second decision or second acknowledgement.
        clearPending(status: decision, decision: decision)
        do {
            try sendMessage(cardCodec.encodeAppRequest(.delete(suggestUID: id, suggestType: .todo)))
            try sendMessage(operationCodec.encodeAppAcknowledgement(
                suggestUID: id, suggestType: SuggestionCardCategory.todo.rawValue, code: .success))
            error = nil
        } catch {
            self.error = "ヘッドコントロールの結果は記録しましたが、クリーンアップ/応答は送信されませんでした：\(error.localizedDescription)"
        }
    }

    private func scheduleExpiry(for id: String) {
        expiryTask?.cancel()
        guard scheduleTimers else { return }
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expire(id: id)
        }
    }

    private func expire(id: String) {
        guard pendingID == id else { return }
        do { try sendMessage(cardCodec.encodeAppRequest(.delete(suggestUID: id, suggestType: .todo))) }
        catch let caught { self.error = "テストはタイムアウトしましたが、削除リクエストは送信されませんでした：\(caught.localizedDescription)" }
        clearPending(status: "テストはタイムアウトしました。操作は実行しません", decision: nil)
    }

    private func clearPending(status: String, decision: String?) {
        expiryTask?.cancel(); expiryTask = nil
        pendingID = nil; pendingDevice = nil; expiresAt = nil
        self.status = status
        if let decision { lastDecision = decision }
    }

    private func sendMessage(_ message: DisplayJSONMessage) throws {
        guard let json = try JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else {
            throw DeviceFeatureError.invalidPacket
        }
        try transport(21, DeviceBusinessWire.encode(type: UInt32(message.type), json: json))
    }
}

struct HeadControlNotificationTestView: View {
    @EnvironmentObject private var test: HeadControlNotificationTest
    @State private var title = "ヘッドコントロールテスト"
    @State private var source = "Turbo IO"
    @State private var content = "うなずいて確認、首を振ってキャンセル。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Label("本機ヘッドコントロールテスト", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Text("ToDo の提案カードを1枚だけ送信します。うなずき/首振りの結果はこのページにだけ表示され、ネットワーク・Core・自動化を呼ぶことは決してありません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    TextField("タイトル", text: $title).textInputAutocapitalization(.never)
                    TextField("出典", text: $source).textInputAutocapitalization(.never)
                    TextField("内容", text: $content, axis: .vertical).lineLimit(2...4)
                    Button("30秒のヘッドコントロールテストカードを送信") { test.send(title: title, source: source, content: content) }
                        .disabled(!test.canSend).accessibilityIdentifier("head-control-test-send")
                    if test.hasPendingCard {
                        Button("テストカードを今すぐ削除", role: .destructive) { test.cancel() }
                            .accessibilityIdentifier("head-control-test-cancel")
                    }
                }
                Card {
                    Text(test.status).font(.subheadline).accessibilityIdentifier("head-control-test-status")
                    if let decision = test.lastDecision { Text(decision).font(.caption).foregroundStyle(Palette.green) }
                    if let error = test.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("プロトコル範囲：業務 21。送信は type 33、一致する type 34 の応答後に削除し type 35 の応答を送信。未検証の応答は無視されます。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
            }.padding(22)
        }
        .background(Palette.background)
        .navigationTitle("ヘッドコントロール通知テスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
    }
}
