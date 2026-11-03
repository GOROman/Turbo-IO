import SwiftUI

struct QWeatherDashboardView: View {
    @EnvironmentObject private var weather: QWeatherDashboard
    @State private var draft = QWeatherConfiguration()
    @State private var key = ""
    @State private var test = false
    @State private var confirmIcon = false
    var body: some View {
        Form {
            Section("ダッシュボード トップ · リアルタイム天気") {
                Text("ここではトップの小さな天気を更新します。お気に入り都市の天気カードは更新せず、ボードのレイアウトも変更しません。")
                    .font(.caption)
                Text(weather.status).accessibilityIdentifier("qweather-status")
                Text(weather.reply).font(.caption).accessibilityIdentifier("qweather-reply")
            }
            Section("QWeather サービス · 設定は本機に保存") {
                TextField("専用 API Host（https:// は不要）",text:$draft.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("qweather-host")
                SecureField("API Key（空欄でその Host の Key を保持）",text:$key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("qweather-key")
                TextField("地点名",text:$draft.location).accessibilityIdentifier("qweather-location")
                HStack {
                    TextField("緯度",text:$draft.latitude).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("qweather-latitude")
                    TextField("経度",text:$draft.longitude).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("qweather-longitude")
                }
                Toggle("認証接続後にダッシュボードを自動更新",isOn:$draft.enabled).accessibilityIdentifier("qweather-enabled")
                Button("保存して適用") {
                    draft.host = draft.host.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                    weather.save(draft,key:key.trimmingCharacters(in:.whitespacesAndNewlines)); key = ""
                }.disabled(weather.busy).accessibilityIdentifier("qweather-save")
                Text("保存後は接続中に入力した座標で照会します（クォータを消費する場合があります）。スマホの位置情報は取得しません。Key は Host ごとに分けて本機のキーチェーンに保存され、初回ロック解除後はバックグラウンドで読み取れます。録音やチャットは送信しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("照会と送信") {
                Button("再取得 / トップへの送信をリトライ") { weather.retry() }.disabled(weather.busy).accessibilityIdentifier("qweather-refresh")
                if let s = weather.snapshot {
                    Text("\(weather.configuration.location) · \(s.condition) · \(String(format:"%.2f",s.temperature))°C → レンズ \(s.lensTemperature)°C")
                        .accessibilityIdentifier("qweather-preview")
                    Text("取得：\(s.fetchedAt.formatted(date:.omitted,time:.standard))；本機キャッシュは最大10分。API に観測時刻はなく、取得時刻は観測時刻ではありません。")
                        .font(.caption)
                    Text("出典：QWeather").font(.caption)
                    ForEach(s.attributions,id:\.self) { Text($0).font(.caption2).textSelection(.enabled) }
                    Text("天気コード \(s.code) がそのままファームウェアのアイコンとは限りません。まず同番号の候補テストを送信し、目視で確認してから、この種類の自動送信を有効にしてください。")
                        .font(.caption)
                    Button("ダッシュボード候補テストを送信") { test = true }.disabled(weather.busy).accessibilityIdentifier("qweather-test-dashboard")
                    Button("レンズのアイコンを確認済み、マッピングを保存") { confirmIcon = true }.disabled(weather.busy).accessibilityIdentifier("qweather-confirm-icon")
                }
            }
        }
        .navigationTitle("ダッシュボード天気")
        .preference(key:CompanionTabBarHiddenPreference.self,value:true)
        .onAppear { draft = weather.configuration }
        .onDisappear { key = "" }
        .confirmationDialog("ダッシュボードのトップへ実際の気温と未検証の同番号アイコンを送信しますか？天気カードは変更しません。",isPresented:$test) {
            Button("トップテストを1回送信") { weather.testCandidate() }
        }
        .confirmationDialog("グラスのトップで気温と正しい天気アイコンを確認できた場合のみ承認してください。プロトコルの応答は目視確認の代わりにはなりません。",isPresented:$confirmIcon) {
            Button("目視でアイコンが正しいことを確認済み") { weather.confirmDisplayedIcon(); draft = weather.configuration }
        }
    }
}
