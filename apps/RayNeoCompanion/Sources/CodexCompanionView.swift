import SwiftUI

struct CodexCompanionView: View {
    @EnvironmentObject private var codex: CodexCompanion
    @EnvironmentObject private var push: CodexPush
    @EnvironmentObject private var notifications: CompanionNotifications
    @Environment(\.scenePhase) private var scenePhase
    @State private var endpoint = ""
    @State private var token = ""
    @State private var voiceTools = false
    @State private var prompt = ""
    @State private var error: String?
    @State private var approval: CodexApproval?
    @State private var answers: [String: String] = [:]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Label("あなたのPC、グラスの中の Codex", systemImage: "terminal").font(.headline)
                    Text("タスクを送り、進捗を見て、会話を続けられます。実行はPC側で独立して行われ、グラスの音声が待ち続ける必要はありません。承認はこのページでの明示的な確認だけで、モデルによる代行承認は受け付けません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text(codex.status).font(.caption).accessibilityIdentifier("codex-status")
                    if let state = codex.state {
                        Text(state.workspace).font(.caption2).textSelection(.enabled)
                        Badge(text: state.readOnly ? "読み取り専用テスト" : "ワークスペース書き込み可")
                    }
                }
                Card {
                    Text("PCブリッジ").font(.headline)
                    TextField("HTTPS アドレス", text: $endpoint).accessibilityIdentifier("codex-endpoint")
                    SecureField("専用アクセストークン（空欄なら保持）", text: $token).privacySensitive().accessibilityIdentifier("codex-token")
                    Toggle("DeepSeek による Codex ツール呼び出しを許可", isOn: $voiceTools).accessibilityIdentifier("codex-voice-tools")
                    Text("オンにすると、音声のタスク文がこのPCと Codex へ送られる場合があります。マイクの生音声はアップロードされません。既存のデスクトップのタスクを引き継ぐこともありません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Button("設定を保存（タスクは開始しない）") {
                        do { try codex.save(endpoint: endpoint, token: token, voiceTools: voiceTools); token = "" }
                        catch { self.error = error.localizedDescription; token = "" }
                    }.disabled(codex.busy || codex.hasUnknownDelivery).accessibilityIdentifier("codex-save")
                    Button("接続／状態を更新") { Task { await codex.refresh() } }
                        .disabled(!codex.configured).accessibilityIdentifier("codex-refresh")
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Card {
                    Toggle("Codex の完了と確認待ちを能動的に知らせる", isOn: Binding(get: { push.enabled }, set: { push.setEnabled($0) }))
                        .accessibilityIdentifier("codex-push-enabled")
                    Text(push.status).font(.caption).accessibilityIdentifier("codex-push-status")
                    Text(notifications.testStatus).font(.caption2).accessibilityIdentifier("codex-push-delivery")
                    NavigationLink("グラス通知のスイッチと送信テスト") { NotificationCenterView() }
                    Text("オンにすると新しいイベントだけを知らせます。完了結果は要約を表示し、全文はこのページで見られます。音声、録音、プロンプターの使用中は空くまで待ち、画面を奪いません。通知は承認ではありません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("グラス通知が許可済みなら、接続後にこのメインスイッチが復元されます。他のAppの送信元フィルタ設定を置き換えることはありません。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    Text("現在はAppの実行が許可されている間、約2秒ごとに確認します。APNsには未対応で、システムによる suspend や強制終了の後は即時の通知を保証できません。PCブリッジのメモリは最大128件まで、完了イベントは1時間保持し、再起動で消去されます。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
                if codex.hasUnknownDelivery {
                    Card {
                        Label("前回の送信結果が未確認", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
                        Text("同じリクエスト番号を保持し、2つ目のタスクを自動で作ることはありません。ネットワーク復旧後にまず確認してください。未確認の内容はこの端末に一時保存され、確認後に消去されます。")
                            .font(.caption)
                        Button("前回の送信を確認") { Task { await codex.retryPending() } }.disabled(codex.busy)
                    }
                }
                Card {
                    HStack {
                        Text("現在のタスク").font(.headline); Spacer()
                        Button("新規タスクに切り替え") { codex.select(nil) }.disabled(codex.busy || codex.hasUnknownDelivery)
                    }
                    Text(codex.selectedTaskID.map { "タスク " + String($0.prefix(8)) } ?? "次は新規タスクを作成します").font(.caption)
                    TextField("Codex への依頼…", text: $prompt, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("codex-prompt")
                    Button("ランダムな検証テストを入力") {
                        prompt = "これはTurbo IOの接続テストです。ファイルの読み書きやツールの実行はせず、次の文だけを返してください：Turbo IO Codex検証 " + String(UUID().uuidString.prefix(6))
                    }.accessibilityIdentifier("codex-fixture")
                    HStack {
                        Button("PCへ送信") { Task { do { _ = try await codex.message(prompt); prompt = "" } catch { self.error = error.localizedDescription } } }
                            .disabled(!codex.configured || codex.busy || codex.hasUnknownDelivery || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("codex-send")
                        Spacer()
                        Button("タスクを停止", role: .destructive) { Task { do { try await codex.stop() } catch { self.error = error.localizedDescription } } }
                            .disabled(codex.selected?.turnId == nil || codex.busy || codex.hasUnknownDelivery)
                    }
                }
                if let task = codex.selected {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(task.status).font(.headline)
                        Text(task.answer.isEmpty ? "Codex の出力はまだ届いていません" : task.answer).textSelection(.enabled).privacySensitive()
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Palette.mint)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("codex-output")
                    ForEach(task.pending) { request in
                        Card {
                            Label(request.kind == "question" ? "Codex があなたの回答を求めています" : "Codex が1回限りの承認を求めています", systemImage: "hand.raised").font(.headline)
                            Text(request.summary).font(.caption).textSelection(.enabled)
                            Text("リクエスト \(request.id.prefix(8)) · 2分以内に有効").font(.caption2)
                            if request.kind == "question" {
                                ForEach(request.questions) { q in
                                    Text(q.question).font(.subheadline)
                                    ForEach(q.options, id: \.self) { option in Button(option) { answers[q.id] = option } }
                                    TextField("あなたの回答", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
                                }
                                Button("これらの回答を送信") { decide(request, accept: false) }
                                    .disabled(codex.busy || request.questions.contains(where: { answers[$0.id, default: ""].isEmpty }))
                            } else {
                                HStack {
                                    Button("今回だけ承認") { approval = request }
                                    Button("拒否", role: .destructive) { decide(request, accept: false) }
                                }.disabled(codex.busy || codex.hasUnknownDelivery)
                            }
                        }
                    }
                }
                if let tasks = codex.state?.tasks, !tasks.isEmpty {
                    Card {
                        Text("ブリッジが管理するタスク").font(.headline)
                        ForEach(tasks) { task in
                            Button("\(task.id.prefix(8)) · \(task.status)") { codex.select(task.id) }
                                .disabled(codex.busy || codex.hasUnknownDelivery)
                        }
                    }
                }
                Text("ページが前面にある間は2秒ごとに更新します。ページを閉じてもPCのタスクは止まりません。この版では iOS のバックグラウンドでのリアルタイム通知は保証しません。音声で「Codexの進捗は？」と聞けます。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(22)
        }.background(Palette.background).navigationTitle("Codex コンソール").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .onAppear { endpoint = codex.endpoint; voiceTools = codex.voiceToolsEnabled }
            .task {
                while !Task.isCancelled {
                    if scenePhase == .active { await codex.refresh() }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
            .confirmationDialog("このリクエストだけを承認します。セッション全体への権限は与えません。", isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
                Button("今回の承認を確定") { if let request = approval { decide(request, accept: true) }; approval = nil }
            } message: { Text(approval?.summary ?? "") }
            .alert("Codex ブリッジ", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }
    private func decide(_ request: CodexApproval, accept: Bool) {
        Task { do { try await codex.decide(request, approve: accept, answers: answers); answers = [:] } catch { self.error = error.localizedDescription } }
    }
}
