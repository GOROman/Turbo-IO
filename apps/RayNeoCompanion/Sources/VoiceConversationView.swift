import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var timeline: ConversationTimeline
    @State private var showKeys = false
    @State private var showConfiguration = false
    @State private var showSimulation = false
    @State private var showDiagnostics = false
    @State private var useCloud = true
    @State private var continuous = true
    @State private var confirmStart = false
    var body: some View {
        Screen(title: "音声会話", eyebrow: "クラウド文区切り · ストリーミング会話") {
            HStack {
                Label(runtime.phaseLabel, systemImage: runtime.enabled ? "waveform" : "moon")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(); Badge(text: runtime.supportsDevice ? (runtime.ready ? "認証済み" : "未接続") : "シミュレータプレビュー")
            }.foregroundStyle(Palette.ink).padding(16).background(Palette.mint.opacity(0.2), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 18) {
                Label("あなたの発話", systemImage: "mic").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.transcript.isEmpty ? "起動後、認識したテキストがここに表示されます" : runtime.transcript)
                    .font(.system(size: 18)).foregroundStyle(.white).privacySensitive()
                Divider().overlay(Palette.mint.opacity(0.3))
                Label("DeepSeek Flash", systemImage: "sparkles").font(.caption).foregroundStyle(Palette.mint.opacity(0.7))
                Text(runtime.answer.isEmpty ? "回答は1文字ずつ表示されます。話しかけて中断できます" : runtime.answer)
                    .font(.system(size: 16)).foregroundStyle(Palette.mint).lineSpacing(6).privacySensitive()
                if runtime.modelComplete { Text("モデルの出力は完了 · レンズ描画の完了とは異なります").font(.caption2).foregroundStyle(Palette.mint.opacity(0.6)) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("live-voice-content")
            if !runtime.enabled {
                Text("マイク未有効 · 音声は送信されていません").font(.caption).foregroundStyle(Palette.muted)
            } else {
                Text(runtime.phase == "idle" || runtime.phase == "waitingForConnection" ? "サービス待機中です。終日録音ではなく、グラスからの起動を待っています。" : "今回の音声を処理中です。待機をオフにすると今回分と以降の自動応答を停止します。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            HStack {
                Button("モデル設定") { if runtime.supportsDevice { showKeys = true } else { showConfiguration = true } }.accessibilityIdentifier("model-settings")
                Spacer()
                Button("ローカルフロー デモ") { showSimulation = true }.accessibilityIdentifier("open-session-lab")
            }.font(.subheadline)
            NavigationLink { CodexCompanionView() } label: {
                Label("Codex タスクと承認", systemImage: "terminal")
            }.accessibilityIdentifier("codex-conversation-entry")
            NavigationLink { ModelToolsView() } label: {
                Label("AI Tools · モデルが使えるツールを表示", systemImage: "wrench.and.screwdriver")
            }.accessibilityIdentifier("model-tools-conversation-entry")
            if let error = timeline.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber)
            }
            NavigationLink { ConversationTimelineView() } label: {
                Card { FeatureRow(icon: "clock.arrow.circlepath", title: "会話タイムライン", subtitle: "この端末の会話を自動記録 · エクスポートと共有", status: "ローカル保存", active: true) }
            }.buttonStyle(.plain).accessibilityIdentifier("conversation-timeline")
            Card {
                Text("動作確認済みの音声方式").font(.headline).foregroundStyle(Palette.ink)
                FeatureRow(icon: "waveform", title: "Alibaba Cloud ストリーミング ASR", subtitle: "クラウドVADで文を区切ります。ローカルの無音切断は重ねません", status: "プロトタイプ確認済み")
                Divider().overlay(Palette.line)
                FeatureRow(icon: "bolt", title: "DeepSeek V4 Flash", subtitle: "思考オフ · ストリーミング文字 · デフォルトではWeb検索しません", status: "プロトタイプ確認済み")
                Divider().overlay(Palette.line)
                Text("継続ASRは起動中の会話で維持され、クラウドで有効な新しい文が出たときだけ前の回答を中断します。空の文では中断しません。1回の会話には120秒の保護があります。Codexツールは個別の設定と許可が必要です。現在TTSはありません。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if runtime.supportsDevice {
                Card {
                    Toggle("実際のクラウド会話を使う", isOn: $useCloud).disabled(runtime.enabled)
                    Toggle("継続ASR · 割り込み許可", isOn: $continuous).disabled(runtime.enabled || !useCloud).accessibilityIdentifier("voice-continuous-draft")
                    Text(runtime.enabled ? (runtime.cloud && runtime.continuous ? "実行中：継続ASR · 有効な新しい文で中断" : "実行中：非継続モード · 出力中の割り込みは保証しません") : "上のスイッチは次回起動時の設定で、まだ実行していません")
                        .font(.caption).foregroundStyle(Palette.amber).accessibilityIdentifier("voice-effective-policy")
                    Text(useCloud ? "起動後の音声は指定したAlibaba Cloud ASRへ、認識テキストはDeepSeekへ送られます。課金される場合があります。" : "この端末のWebRTC VAD検出のみ。返答は毎回ランダムなテスト文字列で、認識もアップロードもしません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Button(runtime.hasCredentials ? "音声サービスのキーを管理" : "ASRとモデルのキーを設定") { showKeys = true }
                        .disabled(runtime.enabled)
                }
                if runtime.enabled {
                    PrimaryButton(title: "待機をオフ", icon: "stop.circle") { runtime.stop() }
                    Button("今回分を終了し、待機は維持") { runtime.endRound() }
                } else {
                    PrimaryButton(title: "グラスの音声待機を開始", icon: "waveform", enabled: runtime.ready && (!useCloud || runtime.hasCredentials)) { confirmStart = true }
                }
                Button("接続と登録解除の管理") { showDiagnostics = true }
                Text(runtime.latestEvent).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            } else {
                Text("このビルドはグラス通信ライブラリを読み込まず、クラウドサービスも呼びません。実機ではRayNeoCompanionDeviceビルドを使ってください。下のデモは実際の収音を示すものではありません。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Text("回答の全断片と完了メッセージを送信した後、有効な新しい文が10秒ないと自動で終了します。話し続けると前のタイマーは取り消されます。最初の文字から数えるわけではなく、送信完了はレンズ描画の完了とは異なります。")
                .font(.caption).foregroundStyle(Palette.amber)
            Button("今回の画面テキストを消去") { runtime.clearText() }.font(.caption)
        }
        .onAppear { runtime.prepare(); reflectRunningPolicy() }
        .onChange(of: runtime.enabled) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.cloud) { _ in reflectRunningPolicy() }
        .onChange(of: runtime.continuous) { _ in reflectRunningPolicy() }
        .sheet(isPresented: $showConfiguration) { ModelConfigurationView() }
        .sheet(isPresented: $showSimulation) { SessionSimulationView() }
        .sheet(isPresented: $showKeys) { LiveVoiceKeysView() }
        #if COMPANION_DEVICE
        .sheet(isPresented: $showDiagnostics, onDismiss: { runtime.refresh() }) {
            NavigationStack { VoiceDiagnosticsView(runtime: runtime).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showDiagnostics = false } } } }
        }
        #endif
        .confirmationDialog(useCloud ? "開始後、能動的な起動で音声がAlibaba Cloudへ、テキストがDeepSeekへ送信されます。サービスは課金される場合があります。" : "ローカルのランダム返答テストを開始します。音声はアップロードしません。", isPresented: $confirmStart) {
            Button("待機開始を確認") { runtime.start(cloud: useCloud, continuous: continuous) }
        }
        .alert("音声サービス", isPresented: Binding(get: { runtime.error != nil }, set: { if !$0 { runtime.error = nil } })) {
            Button("了解", role: .cancel) {}
        } message: { Text(runtime.error ?? "") }
    }
    private func reflectRunningPolicy() {
        guard runtime.enabled else { return }
        useCloud = runtime.cloud; continuous = runtime.continuous
    }
}

struct LiveVoiceKeysView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var asr = ""
    @State private var host = CloudASRHostSettings.current()
    @State private var llm = ""
    @State private var enableDefault = true
    var body: some View {
        NavigationStack {
            Form {
                Section("確認済みのサービス組み合わせ") {
                    Text("Alibaba Cloud qwen-audio-3.0-asr-flash-streaming\nDeepSeek V4 Flash · 思考オフ · ストリーミング")
                    Text("自分のAlibaba Cloud ASR Hostを入力してください。サービスがこのモデルとDashScopeストリーミングタスクプロトコルに対応している必要があります。DeepSeekは公式の固定エンドポイントを使います。他のモデル設定ページはまだ下書きです。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("このApp専用のキーチェーン") {
                    TextField("あなたのASR Host（https:// は含めない）", text: $host)
                        .accessibilityIdentifier("live-asr-host").keyboardType(.URL)
                    Text("Hostを変更すると、他のホストのKeyは引き継ぎません。ソースには開発者のテナントアドレスやキーは含まれていません。")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Alibaba Cloud API Key（空欄で保持）", text: $asr)
                        .accessibilityIdentifier("live-asr-key")
                    SecureField("DeepSeek API Key（空欄で保持）", text: $llm)
                        .accessibilityIdentifier("live-llm-key")
                    Text("公式AppやテストAppのキーは読みません。初回ロック解除後、この端末のバックグラウンド音声に使えます。同期せず、元の値も表示しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Toggle("保存後、デフォルトでクラウド会話と継続割り込みを有効化", isOn: $enableDefault).accessibilityIdentifier("live-default-voice")
                Text("デフォルトの待機は接続後に起動を待つだけであり、継続録音ではありません。手動で待機をオフにすると自動では再開しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(enableDefault ? "保存してデフォルト待機を開始" : "キーだけ保存し、会話は開始しない") {
                    let saved = runtime.saveKeys(asr: asr, llm: llm, host: host, enableDefault: enableDefault)
                    asr = ""; llm = ""
                    if saved { dismiss() }
                }.accessibilityIdentifier("live-save-keys")
                if let error = runtime.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.navigationTitle("音声サービスのキー").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
        }
    }
}
