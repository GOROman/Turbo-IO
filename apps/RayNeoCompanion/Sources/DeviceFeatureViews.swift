import SwiftUI

struct GlassesRecordingCard: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var confirmStart = false
    @State private var expanded = false
    var body: some View {
        Card {
            DisclosureGroup(isExpanded:$expanded) {
              VStack(alignment:.leading,spacing:12) {
                Text(features.recordingStatus).font(.caption).foregroundStyle(Palette.muted)
                if features.recordingBytes > 0 { Text("受信済み \(ByteCountFormatter.string(fromByteCount:Int64(features.recordingBytes),countStyle:.file))").font(.caption.monospacedDigit()) }
                Toggle("グラスからの録音をこの端末に保存することを許可",isOn:Binding(get:{features.acceptsEyeRecording},set:{features.enableEyeRecording($0)}))
                    .font(.caption).disabled(features.recordingID != nil || !voice.ready)
                if features.recordingID == nil {
                    Button("グラスで録音を開始") { confirmStart = true }.disabled(!voice.ready)
                } else {
                    HStack {
                        Button("一時停止") { features.recordingControl(8) }
                        Button("再開") { features.recordingControl(9) }
                        Button("マーク") { features.recordingControl(11) }
                        Button("停止") { features.recordingControl(4) }
                    }.disabled(!voice.ready)
                }
                Text("録音中は音声待機を一時停止します。音声だけを保存し、ASR・アップロード・グラス側ファイルの削除は自動で行いません。終了後は会話ページで待機を再開できます。オフライン滞留分のインポートは別途確認します。").font(.caption2).foregroundStyle(Palette.muted)
                if let file = features.completedRecording {
                    HStack { ShareLink(item:file) { Label("WAVを共有",systemImage:"square.and.arrow.up") }; Button("アーカイブ再試行") { Task { await features.archiveReceivedRecording() } } }.font(.caption)
                } else if features.recordingID != nil {
                    Button("完了メッセージ後に再検証") { features.retryRecordingFinish() }.font(.caption)
                }
                if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
              }.padding(.top,12)
            } label: {
                VStack(alignment:.leading,spacing:6) {
                    Label("グラス録音",systemImage:"mic.badge.plus").font(.headline)
                    Text(features.recordingID == nil ? "録音コントロールを開く · デフォルトでは録音しません" : features.recordingStatus).font(.caption2).foregroundStyle(Palette.muted)
                }
            }.accessibilityIdentifier("recording-controls").padding(18)
            NavigationLink("再起動前の端末内受信ファイルを探す") { RecordingRecoveryView() }
                .font(.caption).padding(.horizontal,18).padding(.bottom,14).accessibilityIdentifier("recording-recovery")
        }
        .confirmationDialog("グラス録音を開始してTurbo IOに保存しますか？AI音声待機を一時停止します。自動アップロードはしません。",isPresented:$confirmStart) {
            Button("録音を開始") { features.startRecording() }
        }
        .onAppear { features.prepare() }
        .onChange(of:features.recordingID) { if $0 != nil { expanded = true } }
    }
}

struct GlassesTodoSyncCard: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var confirm = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Button("この端末のToDoをグラスに同期") { confirm = true }.disabled(!voice.ready)
            Text(features.todoStatus).font(.caption).foregroundStyle(Palette.muted)
            Text("初回同期は確認後に行います。関連付け済みの項目はオンライン編集時に送信を試み、オフライン変更は再試行のため保持します。状態の競合でスマホ側の変更は上書きしません。送信待ちと競合の処理で確認してください。削除はこの端末にのみ有効で、グラス側の旧項目は削除しません。").font(.caption2).foregroundStyle(Palette.muted)
            if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
        }
        .confirmationDialog("削除していないこの端末のToDoを現在のグラスに送信しますか？公式の他のタスクは上書きしません。",isPresented:$confirm) {
            Button("この端末のToDoを送信") { features.syncTodos() }
        }.onAppear { features.prepare() }
    }
}

struct GlassesPrompterControls: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    let text: String
    @State private var speed = 120.0
    @State private var confirm = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("グラス プロンプター · 等速モード").font(.headline)
            Text(features.teleprompterStatus).font(.caption).foregroundStyle(Palette.muted)
            HStack { Text("スクロール速度"); Spacer(); Text("\(Int(speed)) 字／分の候補").monospacedDigit() }.font(.caption)
            Slider(value:$speed,in:60...240,step:10)
            if features.teleprompterID == nil {
                Button("現在の原稿を準備して送信") { confirm = true }.disabled(!voice.ready || text.isEmpty)
            } else {
                HStack {
                    Button("開始") { features.teleprompterControl(3) }
                    Button("一時停止") { features.teleprompterControl(4) }
                    Button("再開") { features.teleprompterControl(5) }
                    Button("終了") { features.teleprompterControl(6) }
                }.disabled(!voice.ready)
                Button("スクロール速度を適用") { features.teleprompterControl(7,speed:Int(speed)) }.disabled(!voice.ready)
            }
            Text("現在の区間だけを送信します（最大 12,000 字）。本全体は送信しません。受領応答を受けてから開始できます。グラスが報告する元の進捗を使い、スマホのページ区切りと同一とは扱いません。スマート追従読み上げは未有効です。").font(.caption2).foregroundStyle(Palette.muted)
            if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
        }.padding(16).background(.white,in:RoundedRectangle(cornerRadius:16))
        .confirmationDialog("現在のテキストをグラスに送信しますか？AI待機を一時停止します。テキストはローカル接続でのみ送信します。",isPresented:$confirm) {
            Button("現在の原稿を準備") { features.prepareTeleprompter(text,speed:Int(speed)) }
        }.onAppear { features.prepare() }
    }
}

struct GlassesSettingsView: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var location = "プロトコルテスト都市"
    @State private var temperature = 27
    @State private var icon = "100"
    @State private var description = "カスタムテスト天気"
    @State private var confirmWeather = false
    var body: some View {
        Form {
            Section("接続と実際の状態") {
                Text(voice.ready ? "認証済み接続" : "未接続（シミュレータは送信しません）")
                LabeledContent("電池残量",value:features.battery.map { "\($0)%" } ?? "未読み取り")
                LabeledContent("明るさ",value:features.brightness.map(String.init) ?? "未読み取り")
                Button("グラスから状態と設定を読み取る") { features.refreshSettings() }.disabled(!voice.ready)
                Text(features.status).font(.caption)
            }
            Section("天気サービス") {
                NavigationLink("ダッシュボードのリアルタイム天気 · QWeather") { QWeatherDashboardView() }.accessibilityIdentifier("qweather-entry")
                NavigationLink("旧 Weatherstack 手動照会") { WeatherstackView() }.accessibilityIdentifier("weatherstack-entry")
                Text("専用Key · 手動照会 · プレビュー後に同期を確認。位置情報の権限は不要です。").font(.caption)
            }
            Section("確認済みの設定入口") {
                HStack { Button("明るさ 7") { features.setBrightness(7) }; Spacer(); Button("明るさ 8") { features.setBrightness(8) } }
                HStack { Button("スリープ 15 秒") { features.setSleep(15) }; Spacer(); Button("スリープ 25 秒") { features.setSleep(25) } }
                Button("ヘッドコントロール ON · モード 0") { features.setHeadControl(true,mode:0) }
                Button("ヘッドコントロール OFF") { features.setHeadControl(false,mode:0) }
                Button("ダブルタップでToDoを開く") { features.setDoubleTapTodo(true) }
                Button("ダブルタップでAIに戻す") { features.setDoubleTapTodo(false) }
                Button("表示の高さ 段階 1") { features.setDisplay(height:1) }
                Button("表示の高さ 段階 3") { features.setDisplay(height:3) }
                Button("表示の距離 段階 1") { features.setDisplay(distance:1) }
                Button("表示の距離 段階 2") { features.setDisplay(distance:2) }
                Text("値域の根拠があるサブセットのみ公開しています。不明なプライバシー項目は変更しません。ボタンの送信は、グラスの物理的な効果が確認済みであることを意味しません。").font(.caption)
            }.disabled(!voice.ready)
            Section("カスタム天気 · リアルタイム気象サービスではありません") {
                TextField("都市ラベル",text:$location)
                Stepper("気温 \(temperature)",value:$temperature,in:-80...60)
                TextField("ファームウェア元のアイコン番号",text:$icon).keyboardType(.numberPad)
                TextField("天気テキスト",text:$description)
                Button("ホーム用のテスト天気を送信") { confirmWeather = true }.disabled(!voice.ready || Int(icon) == nil)
                Text("内容だけを送信し、既存のダッシュボードレイアウトは置き換えません。ホームの小さい天気と都市カードは別の経路です。アイコン番号とレンズ効果は実機で再確認が必要です。現在、位置の自動取得・オンライン天気取得・バックグラウンド更新はありません。").font(.caption)
            }
            if let error = features.error { Section("操作のヒント") { Text(error).foregroundStyle(Palette.amber) } }
        }.navigationTitle("天気とデバイス設定")
        .confirmationDialog("テストと明示したこの天気をグラスに送信しますか？",isPresented:$confirmWeather) {
            Button("カスタムデータを送信") { features.sendWeather(location:location,temperature:temperature,icon:Int(icon) ?? 100,description:description) }
        }.onAppear { features.prepare() }
    }
}
