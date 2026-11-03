import Foundation
import Combine

/// One delivery per authenticated connection, never a discovery/BLE-only event.
@MainActor final class AutomaticWeather: ObservableObject {
    struct Configuration: Codable, Equatable {
        var city = "Beijing, China"
        var enabled = true
        // Explicitly verified provider-code → firmware-code pairs, not numeric equivalence.
        var icons: [String: Int] = [:]
    }
    @Published private(set) var configuration: Configuration
    @Published private(set) var status = "北京の天気：認証済み接続を待機中。天気 Key と検証済みアイコンの設定が必要です。"
    @Published private(set) var snapshot: WeatherstackSnapshot?
    @Published private(set) var busy = false
    private let defaults: UserDefaults
    private let device: () -> String?
    private let isBusy: () -> Bool
    private let readKey: () -> String?
    private let fetch: WeatherstackController.Fetch
    private let send: (WeatherstackSnapshot, Int) throws -> Void
    private let now: () -> Date
    private let storageKey = "companion.v1.automaticWeather"
    private var connectedDevice: String?
    private var generation = UUID()
    private var pending = false
    private var worker: Task<Void, Never>?
    private var cachedCity: String?
    private var lastFetch: Date?

    init(defaults: UserDefaults, device: @escaping () -> String?, isBusy: @escaping () -> Bool,
         readKey: @escaping () -> String? = WeatherstackVault.read,
         fetch: @escaping WeatherstackController.Fetch = WeatherstackClient.fetch,
         now: @escaping () -> Date = Date.init,
         send: @escaping (WeatherstackSnapshot, Int) throws -> Void) {
        self.defaults = defaults; self.device = device; self.isBusy = isBusy
        self.readKey = readKey; self.fetch = fetch; self.now = now; self.send = send
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data),
           (try? WeatherstackRequest.make(city: saved.city, key: "validation-only")) != nil,
           saved.icons.count <= 100, saved.icons.allSatisfy({ Int($0.key) != nil && (0...999).contains($0.value) }) {
            configuration = saved
        } else { configuration = Configuration() }
    }
    func configure(city: String, enabled: Bool) {
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? WeatherstackRequest.make(city: city, key: "validation-only")) != nil else {
            status = WeatherstackError.city.localizedDescription; return
        }
        configuration.city = city; configuration.enabled = enabled
        persist(); retry()
    }
    func confirmIcon(providerCode: Int, firmwareCode: Int) {
        guard (0...999).contains(firmwareCode), configuration.icons.count < 100 || configuration.icons[String(providerCode)] != nil else {
            status = WeatherstackError.icon.localizedDescription; return
        }
        configuration.icons[String(providerCode)] = firmwareCode
        persist(); retry()
    }
    private func persist() { if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: storageKey) } }
    /// Handles credentials added while the connection was already ready.
    func retry() { invalidate(); pending = true; tick() }
    private func invalidate() { generation = UUID(); worker?.cancel(); worker = nil; busy = false }

    /// Reuses the runtime poll; does not start another Bluetooth connection or timer.
    func tick() {
        let current = device()
        if current != connectedDevice { invalidate(); connectedDevice = current; pending = current != nil }
        guard configuration.enabled else { status = "接続時の自動同期はオフです。"; return }
        guard let current else { status = "天気はグラスの認証済み接続を待っています。"; return }
        guard pending, worker == nil else { return }
        guard !isBusy() else { status = "天気は現在の音声、録音、またはプロンプターの終了後に送信します。"; return }
        guard let key = readKey(), !key.isEmpty else {
            pending = false
            status = "\(configuration.city)：未送信です。Weatherstack Key がないか、キーチェーンがまだロック解除されていません。設定後に再試行してください。"
            return
        }
        let cached = cachedCity == configuration.city && snapshot?.canSend(at: now()) == true ? snapshot : nil
        // Reconnect storms must not turn into a paid request loop, including failed requests.
        if cached == nil, let lastFetch, now().timeIntervalSince(lastFetch) < 60 {
            status = "天気クエリの間隔保護：60 秒たってから再試行し、クエリ枠を重複消費しません。"; return
        }
        let token = generation, city = configuration.city
        busy = true; pending = false
        if cached == nil { lastFetch = now() }
        status = cached == nil ? "\(city) の現在の天気を取得中…" : "このセッションの新しい天気を再送信中…"
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.worker = nil; self.busy = false } }
            do {
                let result: WeatherstackSnapshot
                if let cached { result = cached } else { result = try await self.fetch(city, key) }
                guard !Task.isCancelled, self.generation == token, self.device() == current,
                      self.configuration.enabled, self.configuration.city == city else { return }
                guard result.canSend(at: self.now()) else { throw WeatherstackError.stale }
                self.snapshot = result; self.cachedCity = city
                guard let icon = self.configuration.icons[String(result.providerCode)] else {
                    self.status = "\(result.city) \(result.lensTemperature)°C を取得しました。未送信です：天気コード \(result.providerCode) のファームウェアアイコンが未確認です。"
                    return
                }
                guard !self.isBusy() else { self.pending = true; self.status = "天気を取得しました。グラスが空いたら送信します。"; return }
                try self.send(result, icon)
                self.status = "\(result.city) \(result.lensTemperature)°C をホームの天気に送信しました。受領確認はデバイスステータスを見てください。レンズ側の確認も必要です。"
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.status = (error as? WeatherstackError)?.localizedDescription ?? "天気の送信に失敗しました。グラスが受信したか未確認です。手動で再試行できます。"
            }
        }
    }
}
