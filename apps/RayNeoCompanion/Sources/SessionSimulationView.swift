import SwiftUI
import RayNeoSession

@MainActor
final class SessionLabModel: ObservableObject {
    @Published private var machine = VoiceSessionMachine(configuration: .init(asrPolicy: .preferCloudWithLocalFallback, ttsMode: .enabled))
    @Published private(set) var events: [String] = []
    @Published private(set) var staleCallbackResult: String?
    private var previousRound: RoundToken?
    var snapshot: SessionSnapshot { machine.snapshot }

    func send(_ event: VoiceSessionEvent, label: String) {
        let effects = machine.handle(event)
        events.insert("\(label) → \(effects.count) 件の意図", at: 0)
        for effect in effects.reversed() {
            events.insert("  \(effectName(effect))", at: 1)
        }
        events = Array(events.prefix(60))
    }

    func connect() { send(.connected, label: "接続をシミュレーション") }
    func wake() { send(.wake, label: "ウェイクアップをシミュレーション") }
    func network(_ available: Bool) { send(.networkChanged(isAvailable: available), label: available ? "ネットワーク接続をシミュレーション" : "ネットワーク切断をシミュレーション") }
    func transcript() {
        guard let round = snapshot.currentRound, let source = snapshot.asrSource else { return }
        send(.audioEnded(round: round), label: "音声終了をシミュレーション")
        send(.asrResult(round: round, source: source, result: .init(revision: 1, text: "3 たす 4 はいくつですか？", isFinal: true)), label: "サンプル認識テキストを注入")
    }
    func answer() {
        guard let round = snapshot.currentRound else { return }
        send(.modelText(round: round, update: .init(revision: 1, text: "3 たす 4 は 7 です。")), label: "サンプルモデル回答を注入")
        send(.modelFinished(round: round), label: "モデル完了をシミュレーション")
        send(.ttsStarted(round: round), label: "TTS開始をシミュレーション")
    }
    func finishSpeech() {
        guard let round = snapshot.currentRound else { return }
        send(.ttsInputFinished(round: round), label: "TTS入力完了をシミュレーション")
        send(.ttsPlaybackDrained(round: round), label: "再生バッファ枯渇をシミュレーション")
    }
    func nextRound() {
        guard let round = snapshot.currentRound else { return }
        previousRound = round
        send(.nextRound(round: round), label: "グラスの次ラウンドをシミュレーション")
    }
    func interrupt() {
        guard let round = snapshot.currentRound else { return }
        previousRound = round
        send(.interrupt(round: round), label: "割り込みと次ラウンド開始をシミュレーション")
    }
    func staleCallback() {
        guard let round = previousRound else { return }
        let before = snapshot
        let effects = machine.handle(.modelText(round: round, update: .init(revision: 99, text: "無効になったサンプル回答")))
        staleCallbackResult = effects.isEmpty && before == snapshot ? "前ラウンドのコールバックは無視され、現在の会話は変わっていません" : "前ラウンドのコールバックで状態が変わりました。コアを確認してください"
        events.insert(staleCallbackResult ?? "", at: 0)
    }
    func exit() { send(.exitRequested(reason: .normal), label: "終了をシミュレーション") }
    var canTestStale: Bool { previousRound != nil }

    private func effectName(_ effect: VoiceSessionEffect) -> String {
        switch effect {
        case .startRecognition: return "認識を開始（未実行）"
        case .feedRecognition: return "音声を提供（未実行）"
        case .finishRecognition: return "認識入力を終了（未実行）"
        case .cancelRecognition: return "認識をキャンセル（未実行）"
        case .startCapture: return "収録を開始（未実行）"
        case .stopCapture: return "収録を停止（未実行）"
        case .requestModel: return "モデルへリクエスト（未実行）"
        case .synthesizeAndPlay: return "合成して再生（未実行）"
        case .cancelWork: return "現在のラウンドの処理をキャンセル（未実行）"
        case .invalidateToolApprovals: return "現在のラウンドのツール承認を無効化（未実行）"
        case .displayTranscript: return "認識テキストを表示（未送信）"
        case .displayResponse: return "回答を表示（未送信）"
        case .reportTTSStatus: return "TTS状態を同期（未送信）"
        case .responseComplete: return "応答完了の意図（未送信、終了ではありません）"
        case .requestExit: return "ページ終了の意図（未送信）"
        case .scheduleTimeout: return "タイムアウトを設定（実験ではタイマーは動作しません）"
        case .cancelTimeout: return "タイムアウトをキャンセル（実験ではタイマーは動作しません）"
        case .reportFailure: return "エラーを報告（ローカルの意図のみ）"
        }
    }
}

struct SessionSimulationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lab = SessionLabModel()
    private var phaseName: String {
        switch lab.snapshot.phase {
        case .disconnected: return "未開始"
        case .idle: return "シミュレーション接続の準備完了"
        case .listening: return "シミュレーション聞き取り中"
        case .awaitingTranscript: return "サンプル認識結果を待機中"
        case .generating: return "サンプルモデル結果を待機中"
        case .speaking: return "シミュレーションTTS応答中"
        case .awaitingNextRound: return "次ラウンドを待機中"
        case .awaitingToolApproval: return "ツールの確認を待機中（状態のみ）"
        case .closed: return "会話は終了しました"
        }
    }
    private var isActive: Bool { ![.disconnected, .idle, .closed].contains(lab.snapshot.phase) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("ロジックのみのシミュレーション · 録音なし、通信なし、グラス操作なし", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amber).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 0.98, green: 0.92, blue: 0.77), in: RoundedRectangle(cornerRadius: 14))
                    Card {
                        HStack { Text("音声会話フロー").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink); Spacer(); Badge(text: phaseName, active: true) }
                        VStack(spacing: 0) {
                            timelineRow("ウェイクアップ", active: [.idle, .listening].contains(lab.snapshot.phase), complete: [.awaitingTranscript, .generating, .speaking, .awaitingNextRound, .closed].contains(lab.snapshot.phase), last: false)
                            timelineRow("認識", active: [.listening, .awaitingTranscript].contains(lab.snapshot.phase), complete: [.generating, .speaking, .awaitingNextRound].contains(lab.snapshot.phase), last: false)
                            timelineRow("モデル応答", active: [.generating, .speaking].contains(lab.snapshot.phase), complete: lab.snapshot.phase == .awaitingNextRound, last: false)
                            timelineRow("終了処理", active: lab.snapshot.phase == .awaitingNextRound, complete: lab.snapshot.phase == .closed, last: true)
                        }
                        HStack {
                            Text("ラウンド \(lab.snapshot.currentRound.map { $0.index + 1 } ?? 0)")
                            Spacer()
                            Text("\(lab.snapshot.completedRoundCount) ラウンド完了")
                        }.font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        Toggle("ネットワーク接続をシミュレーション", isOn: Binding(get: { lab.snapshot.networkAvailable }, set: { lab.network($0) }))
                            .font(.subheadline).disabled(isActive)
                        Text("これはこのアプリのクラウド優先 / ローカルフォールバック戦略の実験であり、公式アプリの認識結果ではありません。切り替えてもスマホのネットワークは変わりません。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                        if let source = lab.snapshot.asrSource {
                            Label(source == .local ? "戦略の選択：ローカル認識" : "戦略の選択：クラウド認識", systemImage: source == .local ? "iphone" : "cloud")
                                .font(.caption).foregroundStyle(Palette.green)
                        }
                        if !lab.snapshot.transcript.isEmpty {
                            Text("サンプルの質問：\(lab.snapshot.transcript)").font(.subheadline).foregroundStyle(Palette.ink)
                        }
                        if !lab.snapshot.response.isEmpty {
                            Text("サンプルの回答：\(lab.snapshot.response)").font(.subheadline).foregroundStyle(Palette.green)
                        }
                        mainAction
                        if isActive {
                            HStack {
                                Button("割り込みをシミュレーション") { lab.interrupt() }.accessibilityIdentifier("lab-interrupt")
                                Spacer()
                                Button("終了をシミュレーション") { lab.exit() }.accessibilityIdentifier("lab-exit")
                            }.font(.system(size: 13, weight: .medium))
                        }
                        if lab.canTestStale {
                            Button("前ラウンドの遅延コールバックを注入") { lab.staleCallback() }.font(.caption).accessibilityIdentifier("lab-stale")
                        }
                        if let result = lab.staleCallbackResult { Text(result).font(.caption).foregroundStyle(Palette.green) }
                    }
                    Card {
                        DisclosureGroup("意図の履歴（副作用は実行されません）") {
                            if lab.events.isEmpty {
                                Text("シミュレーションを手動で開始すると、コアが返した意図を表示します。音声、モデル、ツール、Bluetoothの操作は実行しません。")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).padding(.top, 10)
                            } else {
                                ForEach(Array(lab.events.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                                }
                            }
                        }.font(.system(size: 13, weight: .medium))
                    }
                    Card {
                        Text("ツール承認の保護").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.green)
                        FeatureRow(icon: "link", title: "リクエストの紐付け", subtitle: "実際のツールリクエストには未接続", status: "未実行")
                        FeatureRow(icon: "checkmark.shield", title: "有効期限チェック", subtitle: "承認の発行・使用は行っていません", status: "未実行")
                        FeatureRow(icon: "square.on.square", title: "重複防止", subtitle: "イベントを表示するのみで、ツールは実行しません", status: "未実行")
                    }
                }.padding(24)
            }.background(Palette.background).navigationTitle("プロトコルラボ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }

    private func timelineRow(_ title: String, active: Bool, complete: Bool, last: Bool) -> some View {
        HStack(spacing: 15) {
            VStack(spacing: 0) {
                Image(systemName: complete ? "checkmark.circle.fill" : active ? "play.circle.fill" : "circle")
                    .font(.system(size: 21)).foregroundStyle(active || complete ? Palette.green : Palette.muted.opacity(0.5))
                    .frame(height: 27)
                if !last { Rectangle().fill(Palette.line).frame(width: 1, height: 16) }
            }
            Text(title).font(.system(size: 14)).foregroundStyle(active || complete ? Palette.ink : Palette.muted)
            Spacer()
            Text(complete ? "シミュレーション完了" : active ? "現在のステップ" : "待機中").font(.system(size: 11)).foregroundStyle(active || complete ? Palette.green : Palette.muted)
        }
    }

    @ViewBuilder private var mainAction: some View {
        switch lab.snapshot.phase {
        case .disconnected: PrimaryButton(title: "シミュレーション接続を手動で開始") { lab.connect() }.accessibilityIdentifier("lab-connect")
        case .idle, .closed: PrimaryButton(title: "ウェイクアップをシミュレーション") { lab.wake() }.accessibilityIdentifier("lab-wake")
        case .listening, .awaitingTranscript: PrimaryButton(title: "サンプル認識結果を注入") { lab.transcript() }.accessibilityIdentifier("lab-asr")
        case .generating: PrimaryButton(title: "サンプル回答を注入 + TTS開始") { lab.answer() }.accessibilityIdentifier("lab-answer")
        case .speaking: PrimaryButton(title: "TTS入力終了 + 再生バッファ枯渇をシミュレーション") { lab.finishSpeech() }.accessibilityIdentifier("lab-tts-finish")
        case .awaitingNextRound: PrimaryButton(title: "グラスの次ラウンド開始をシミュレーション") { lab.nextRound() }.accessibilityIdentifier("lab-next")
        case .awaitingToolApproval:
            Text("ツールの確認を待機中 · 状態表示のみで、承認エグゼキュータには未接続")
                .font(.caption).foregroundStyle(Palette.amber).accessibilityIdentifier("lab-tool-approval-pending")
        }
    }
}
