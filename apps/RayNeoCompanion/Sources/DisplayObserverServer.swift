import Foundation
import Network
import SwiftUI

/// Loopback only, intended for a trusted USB usbmux tunnel, not a LAN service.
@MainActor final class DisplayObserverServer: ObservableObject {
    static let shared = DisplayObserverServer()
    @Published private(set) var running = false
    @Published private(set) var status = "閉じています。観察データはエクスポートしません"
    @Published private(set) var token = ""
    private var listener: NWListener?
    private var clients: [UUID:NWConnection] = [:]
    private var expiry: Timer?
    let observation = DisplayObservation.shared
    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 18765)
        do {
            let value = try NWListener(using: parameters)
            listener = value; token = UUID().uuidString.replacingOccurrences(of:"-",with:"")
            observation.reset(); observation.enabled = true; status = "起動中"
            value.stateUpdateHandler = { [weak self, weak value] state in
                Task { @MainActor in
                guard let self, self.listener === value else { return }
                switch state {
                case .ready: self.running = true; self.status = "USB 観察インターフェースがオン · 30 分後に自動で閉じます"
                case .failed: self.stop(); self.status = "インターフェースの起動に失敗しました。LAN ポートは公開していません"
                default: break
                }
                }
            }
            value.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listener != nil else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            value.start(queue:.main)
            expiry = Timer.scheduledTimer(withTimeInterval:1800,repeats:false) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        } catch { stop(); status = "観察インターフェースは利用できません" }
    }
    func stop() {
        expiry?.invalidate(); expiry = nil
        listener?.cancel(); listener = nil
        for c in clients.values { c.cancel() }; clients.removeAll()
        observation.enabled = false; observation.includesText = false; observation.reset()
        token = ""; running = false; status = "閉じて、今回の観察データを消去しました"
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.start(queue:.main)
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in self?.close(id) }
        read(connection,id:id,buffer:Data())
    }
    private func close(_ id: UUID) { clients.removeValue(forKey:id)?.cancel() }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] data, _, done, error in
            Task { @MainActor in
            guard let self, self.clients[id] != nil else { return }
            var all = buffer; if let data { all.append(data) }
            guard all.count <= 8192, error == nil else { self.close(id); return }
            if all.range(of:Data("\r\n\r\n".utf8)) != nil {
                let authorized = Self.authorized(all,token:self.token)
                let body = authorized ? (try? JSONSerialization.data(withJSONObject:self.observation.snapshot())) ?? Data("{}".utf8) : Data("{\"error\":\"unauthorized\"}".utf8)
                var response = Data("HTTP/1.1 \(authorized ? "200 OK" : "403 Forbidden")\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
                response.append(body)
                connection.send(content:response,completion:.contentProcessed { [weak self] _ in
                    Task { @MainActor in self?.close(id) }
                })
            } else if done { self.close(id) }
            else { self.read(connection,id:id,buffer:all) }
            }
        }
    }
    static func authorized(_ data: Data, token: String) -> Bool {
        guard token.count == 32, data.count <= 8192, let text = String(data:data,encoding:.utf8) else { return false }
        let lines = text.components(separatedBy:"\r\n")
        guard lines.first == "GET /snapshot HTTP/1.1", lines.last == "" else { return false }
        let headers = lines.dropFirst().filter { !$0.isEmpty }
        guard !headers.contains(where: { $0.lowercased().hasPrefix("origin:") || $0.lowercased().hasPrefix("transfer-encoding:") }) else { return false }
        let auth = headers.filter { $0.lowercased().hasPrefix("authorization:") }
        return auth.count == 1 && auth[0].dropFirst("authorization:".count).trimmingCharacters(in:.whitespaces) == "Bearer \(token)"
    }
}

struct DisplayObserverView: View {
    @ObservedObject private var server = DisplayObserverServer.shared
    @ObservedObject private var observation = DisplayObservation.shared
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("表示観察 · USB").font(.title2.bold())
                Text("ページ状態を読み取り専用で送り返します。シミュレータのプレビューはレンズのスクリーンショットではありません。録音を開始したり、モデルを呼び出したり、グラスのページを変更したりはしません。")
                Text(server.status).accessibilityIdentifier("display-observer-status")
                Toggle("今回送信する文字を含める",isOn:$observation.includesText).accessibilityIdentifier("display-observer-text")
                Text("オンの間だけ収集し、イベントは最大 80 件です。文字はログやディスクに書きません。閉じるとキャッシュとトークンを消去します。アプリが中断されると、PC 側ではデータ途絶と表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(server.running ? "観察インターフェースを閉じる" : "USB 観察インターフェースを開く") { server.running ? server.stop() : server.start() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("display-observer-toggle")
                if server.running {
                    Text("PC の観察ページにワンタイムトークンを入力：").font(.caption)
                    Text(server.token).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("display-observer-token")
                    Button("トークンをコピー") { UIPasteboard.general.setItems([["public.utf8-plain-text":server.token]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(120)]) }
                    Text("USB 転送ポート 18765 · ローカルループバックのみアクセス可 · 脱獄不要")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.navigationTitle("表示観察").navigationBarTitleDisplayMode(.inline)
    }
}
