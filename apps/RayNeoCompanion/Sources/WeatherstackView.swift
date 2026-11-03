import SwiftUI

struct WeatherstackView: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var automatic: AutomaticWeather
    @StateObject private var weather = WeatherstackController()
    @State private var city = "Beijing, China"
    @State private var key = ""
    @State private var rawIcon = ""
    @State private var acknowledgedIcon = false
    @State private var confirmQuery = false
    @State private var confirmSend = false
    @State private var lookup: Task<Void,Never>?

    var body: some View {
        Form {
            Section("認証接続後に自動同期") {
                Text("旧バージョンの設定はQWeatherのダッシュボード天気に引き継がれ、接続イベントでこのサービスが自動的にトリガーされることはなくなりました。このページの検索と再試行は手動操作です。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("接続 / 再接続後にホーム画面の天気を同期", isOn: Binding(
                    get: { automatic.configuration.enabled },
                    set: { automatic.configure(city: automatic.configuration.city, enabled: $0) }))
                    .accessibilityIdentifier("weather-auto-enabled")
                Text("選択中の都市：\(automatic.configuration.city)").font(.caption)
                Text(automatic.status).font(.caption).accessibilityIdentifier("weather-auto-status")
                Text("認証接続後にのみ取得して送信します。新しい結果は再接続時に使えます。ダッシュボードのレイアウトは変更しません。録音、会話、プロンプターの使用中は延期されます。天気専用キーと確認済みのアイコンマッピングが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("自動同期を再試行") { automatic.retry() }.disabled(automatic.busy)
                    .accessibilityIdentifier("weather-auto-retry")
                if let result = automatic.snapshot {
                    Text("自動検索：\(result.city) \(result.lensTemperature)°C · \(result.description) · 天気コード \(result.providerCode)").font(.caption)
                }
            }
            Section("Weatherstack · リアルタイム天気") {
                Text("検索では入力した都市のみをWeatherstackへ送信し、クォータを消費する場合があります。スマホの位置情報は取得せず、チャット、録音、グラスの識別情報も送信しません。")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(weather.hasKey ? "新しいKey（空欄で現在のKeyを保持）" : "Weatherstack API Key",text:$key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("weather-key")
                HStack {
                    Button("Keyを安全に保存") { weather.saveKey(key); key = ""; automatic.retry() }.disabled(key.isEmpty || weather.busy)
                    Spacer()
                    Button("Keyを削除",role:.destructive) { weather.removeKey(); automatic.retry() }.disabled(!weather.hasKey || weather.busy)
                }
                TextField("都市と国",text:$city).autocorrectionDisabled().accessibilityIdentifier("weather-city")
                Button("自動同期の都市として保存") {
                    automatic.configure(city:city, enabled:automatic.configuration.enabled)
                }.accessibilityIdentifier("weather-auto-city-save")
                Button(weather.busy ? "検索中…" : "検索してプレビュー（送信しません）") { confirmQuery = true }
                    .disabled(weather.busy || !weather.hasKey || city.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("weather-query")
                Button("提供された2019年のサンプルを表示") { weather.previewSample() }
                    .disabled(weather.busy).accessibilityIdentifier("weather-sample")
                Text(weather.message).font(.caption).accessibilityIdentifier("weather-status")
            }
            if let result = automatic.snapshot, !result.isSample {
                Section("自動天気アイコンの確認") {
                    Text("Weatherstackの天気コード \(result.providerCode) に対して検証済みのファームウェアアイコンを保存します。天気タイプが変わった場合、未確認の新しいコードは送信を一時停止します。")
                        .font(.caption)
                    TextField("ファームウェアアイコン番号", text:$rawIcon).keyboardType(.numberPad)
                    Toggle("このアイコンマッピングを確認済み", isOn:$acknowledgedIcon)
                    Button("アイコンマッピングを保存して再試行") {
                        guard acknowledgedIcon, let icon = validIcon else { return }
                        automatic.confirmIcon(providerCode:result.providerCode, firmwareCode:icon)
                    }.disabled(!acknowledgedIcon || validIcon == nil || automatic.busy)
                }
            }
            if let snapshot = weather.snapshot {
                Section(snapshot.isSample ? "過去のサンプル · 送信不可" : "検索結果 · 未同期") {
                    LabeledContent(snapshot.city,value:String(format:"%g °C",snapshot.celsius))
                        .accessibilityIdentifier("weather-preview")
                    Text(snapshot.description)
                    Text("現地時間：\(snapshot.sourceLocalTime.isEmpty ? "なし" : snapshot.sourceLocalTime)").font(.caption)
                    Text("Weatherstackコード：\(snapshot.providerCode)（グラスのアイコン番号ではありません）").font(.caption)
                    if snapshot.usedLegacyTemperatureKey {
                        Text("サンプルの temparature という綴りにも対応しますが、正式な temperature フィールドを優先します。").font(.caption2)
                    }
                    Text("ホーム画面のプロトコルは場所、整数の気温、ファームウェアアイコンのみを扱います。風速、空気質、月齢などのフィールドはまだ送信しません。").font(.caption)
                }
                Section("ホーム画面の天気を同期") {
                    TextField("検証済みのファームウェア元アイコン番号",text:$rawIcon).keyboardType(.numberPad)
                    Toggle("このファームウェアアイコンコードを確認済み",isOn:$acknowledgedIcon)
                    Text("プロバイダのコードには検証済みの自動マッピングがないため、122でグラスのアイコンを推測しません。気温は整数に四捨五入します。既存のダッシュボードレイアウトは置き換えません。").font(.caption)
                    Button("検索結果をグラスへ同期") { confirmSend = true }
                        .disabled(!voice.ready || !snapshot.canSend(at:Date()) || !acknowledgedIcon || validIcon == nil || weather.busy)
                        .accessibilityIdentifier("weather-send")
                    Text(features.status).font(.caption)
                    if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                }
            }
        }.navigationTitle("Weatherstack天気")
        .confirmationDialog("入力した都市をWeatherstackへ送信して1回検索しますか？プランのクォータを消費する場合があります。",isPresented:$confirmQuery) {
            Button("1回検索") { lookup = Task { await weather.refresh(city:city) } }
        }
        .confirmationDialog("プレビューの気温と指定したファームウェアアイコンをグラスのホーム画面へ送信しますか？",isPresented:$confirmSend) {
            Button("同期を確定") {
                guard let snapshot = weather.snapshot, acknowledgedIcon, let icon = validIcon else { return }
                features.sendWeatherstack(snapshot,icon:icon)
            }
        }
        .onChange(of:rawIcon) { _ in acknowledgedIcon = false }
        .onAppear { city = automatic.configuration.city }
        .onDisappear { lookup?.cancel(); key = "" }
    }
    private var validIcon: Int? { guard let n = Int(rawIcon), (0...999).contains(n) else { return nil }; return n }
}
