import SwiftUI

struct ToolsView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var showModel = false
    @State private var showLab = false
    var body: some View {
        Screen(title: "ツールボックス", eyebrow: "ローカルツールと実験") {
            NavigationLink { DisplayObserverView() } label: {
                Card { FeatureRow(icon: "eyeglasses", title: "表示オブザーバー", subtitle: "USB · 画面の報告と送信テキスト · スクリーンショットではありません", status: "読み取り専用") }
            }.buttonStyle(.plain).accessibilityIdentifier("display-observer-entry")
            NavigationLink { AlwaysOnLocalProbeView(probe: store.alwaysOn) } label: {
                Card { FeatureRow(icon: "waveform.path", title: "終日記録", subtitle: "音声のみ · 30秒のローカルプロトコルテスト", status: "実験") }
            }.buttonStyle(.plain).accessibilityIdentifier("always-on-entry")
            NavigationLink { ModelToolsView() } label: {
                Card { FeatureRow(icon: "wrench.and.screwdriver", title: "AI Tools", subtitle: "モデルのツール · 引数 · 利用条件", status: "表示") }
            }.buttonStyle(.plain).accessibilityIdentifier("model-tools-entry")
            NavigationLink { CodexCompanionView() } label: {
                Card { FeatureRow(icon: "terminal", title: "Codex コンソール", subtitle: "PCのタスク · 進捗 · 都度承認", status: "PCに接続") }
            }.buttonStyle(.plain).accessibilityIdentifier("codex-tool")
            Card {
                NavigationLink { TodoView() } label: {
                    FeatureRow(icon: "checklist", title: "ToDoリスト", subtitle: "タスクを記録・管理", status: "ローカル利用可能", active: true)
                }.buttonStyle(.plain).accessibilityIdentifier("todo-tool")
                Divider().overlay(Palette.line)
                NavigationLink { PrompterView() } label: {
                    FeatureRow(icon: "text.alignleft", title: "プロンプター", subtitle: "原稿の編集とスマホプレビュー", status: "ローカル利用可能", active: true)
                }.buttonStyle(.plain).accessibilityIdentifier("prompter-tool")
            }
            Card {
                Button { showModel = true } label: { FeatureRow(icon: "gearshape", title: "モデル設定", subtitle: "ローカルモデルとサービスを設定", status: "設定") }.buttonStyle(.plain)
                Divider().overlay(Palette.line)
                Button { showLab = true } label: { FeatureRow(icon: "flask", title: "プロトコルラボ", subtitle: "プロトコルと機能の実験を探索", status: "ローカルシミュレーション") }.buttonStyle(.plain).accessibilityIdentifier("protocol-lab")
            }
            VStack(spacing: 12) {
                SectionLabel(title: "グラス機能", trailing: "実機接続 · 要再検証")
                Card {
                    NavigationLink { NotificationCenterView() } label: { FeatureRow(icon: "bell.badge", title: "通知センター", subtitle: "ソースのオン／オフとカスタム送信テスト", status: "実機") }.buttonStyle(.plain).accessibilityIdentifier("notification-tool")
                    Divider().overlay(Palette.line)
                    NavigationLink { HeadControlNotificationTestView() } label: { FeatureRow(icon: "person.crop.circle.badge.checkmark", title: "ヘッドコントロール通知テスト", subtitle: "ToDo提案カード · うなずく／首を振るはこのデバイスへのみ返送", status: "実機") }.buttonStyle(.plain).accessibilityIdentifier("head-control-test-entry")
                    Divider().overlay(Palette.line)
                    NavigationLink { GlassesSettingsView() } label: { FeatureRow(icon: "cloud", title: "天気とデバイス設定", subtitle: "カスタムデータ、状態の読み取りと設定", status: "実機") }.buttonStyle(.plain).accessibilityIdentifier("device-settings-tool")
                    Divider().overlay(Palette.line)
                    NavigationLink { GlassesSettingsView() } label: { FeatureRow(icon: "slider.vertical.3", title: "ヘッドコントロールとノブ", subtitle: "既存プロトコルの値域内の制御サブセット", status: "実機") }.buttonStyle(.plain)
                }
            }
            Label("デバイスの効果は実機での検証が正です", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.green).padding(15)
                .frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 15))
            HStack {
                NavigationLink("使い方") { HelpView() }
                Spacer()
                NavigationLink("できることの範囲") { ProtocolLabView() }
                Spacer()
                NavigationLink("環境設定") { SettingsView(embedded: true) }
            }.font(.system(size: 12)).padding(.horizontal, 5)
        }
        .sheet(isPresented: $showModel) { ModelConfigurationView() }
        .sheet(isPresented: $showLab) { SessionSimulationView() }
    }

    private func toolTile(_ icon: String, title: String, description: String, footnote: String, green: Bool) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Image(systemName: icon).font(.system(size: 25, weight: .light)); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(description).font(.system(size: 11)).opacity(0.7)
            }
            Text(footnote).font(.system(size: 10)).opacity(0.7)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 160)
            .foregroundStyle(green ? Palette.mint : Palette.ink)
            .background(green ? Palette.ink : Palette.mint.opacity(0.5), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct ModelToolsView: View {
    @EnvironmentObject private var codex: CodexCompanion
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @State private var refreshing = false
    @State private var expandedTools: Set<String> = []
    private var providedNames: Set<String> {
        Set(codex.toolDefinitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Label("DeepSeek のツール一覧", systemImage: "wrench.and.screwdriver").font(.headline)
                    Text("現在の設定では \(providedNames.count) / \(CodexToolDescriptor.all.count) 個のツールを提供します")
                        .accessibilityIdentifier("model-tools-count")
                    Text("これは次回のモデルリクエストに含められる tools です。リクエストを送信済み、ツールの実行成功、PCがオンライン、を意味しません。この画面は読み取り専用で、タスクは開始しません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text(codex.configured ? (codex.voiceToolsEnabled ? "ツールの権限：許可済み" : "ツールの権限：オフ") : "ツールの設定：ブリッジのアドレスまたはトークンが不足しています")
                        .font(.caption).accessibilityIdentifier("model-tools-configuration")
                    Text(runtime.supportsDevice ? "音声：\(runtime.phaseLabel) · \(runtime.cloud ? "クラウド会話" : "クラウド会話は動作していません")" : "シミュレータ：一覧の表示のみで、グラスの音声は動作しません")
                        .font(.caption)
                    Text("ブリッジの状態（前回の確認 / 設定結果）：\(codex.status)").font(.caption)
                        .accessibilityIdentifier("model-tools-bridge-state")
                    Button(refreshing ? "確認中…" : "ブリッジ接続を確認（タスクは送信しません）") {
                        refreshing = true
                        Task { await codex.refresh(); refreshing = false }
                    }.disabled(!codex.configured || refreshing).accessibilityIdentifier("model-tools-refresh")
                    NavigationLink("Codex ツールのオン／オフと接続を管理") { CodexCompanionView() }
                        .accessibilityIdentifier("model-tools-configure")
                }
                ForEach(CodexToolDescriptor.all) { tool in
                    Card {
                        Text(tool.title).font(.headline)
                        Text(tool.id).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("model-tool-name-\(tool.id)")
                        Badge(text: providedNames.contains(tool.id) ? "モデルリクエストに含めて提供" : "モデルには未提供")
                        Text(tool.description).font(.subheadline)
                        Text(tool.requiresText ? "引数：text（必須の文字列、タスクの内容）" : "引数：なし、現在選択中のタスクを使用")
                            .font(.caption).foregroundStyle(Palette.muted)
                        Text("こう言えます：「\(tool.example)」").font(.caption).foregroundStyle(Palette.green)
                        Button {
                            if expandedTools.contains(tool.id) { expandedTools.remove(tool.id) }
                            else { expandedTools.insert(tool.id) }
                        } label: {
                            HStack {
                                Text(expandedTools.contains(tool.id) ? "ツール定義（JSON）を閉じる" : "実際のツール定義（JSON）を表示")
                                Spacer()
                                Image(systemName: expandedTools.contains(tool.id) ? "chevron.down" : "chevron.right")
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("model-tool-details-\(tool.id)")
                            .accessibilityValue(expandedTools.contains(tool.id) ? "展開済み" : "折りたたみ済み")
                        if expandedTools.contains(tool.id) {
                            Text(tool.schemaJSON).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("model-tool-schema-\(tool.id)")
                        }
                    }
                }
                Text("現在使っているのは Function Calling で、MCP ではありません。ToDo、天気、録音などの App 機能はまだモデルツールとして登録されていません。権限の承認はスマホで明示的に確認する必要があり、自動承認するツールはありません。")
                    .font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("model-tools-boundary")
            }.padding(22)
        }.background(Palette.background).navigationTitle("AI Tools").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
    }
}

struct TodoView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var title = ""
    @State private var showCompleted = false
    @State private var editingTodo: LocalTodo?
    @FocusState private var inputFocused: Bool
    private var visibleTodos: [LocalTodo] { store.todos.filter { $0.archivedAt == nil && $0.completed == showCompleted } }
    private var markdown: String {
        "# Turbo IO ToDoリスト\n\n> このデバイスの現在のスナップショットです。グラスとの同期やレンズ表示の検証状態を表すものではありません。\n\n" + store.todos.filter { $0.archivedAt == nil }.map {
            "- [\($0.completed ? "x" : " ")] \($0.title.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                notice("まずこのデバイスに保存 · グラスとの同期には確認が必要です")
                NavigationLink("システムのリマインダーからインポート") { ReminderImportView() }
                    .accessibilityIdentifier("system-reminders-open")
                Picker("ToDoの絞り込み", selection: $showCompleted) {
                    Text("進行中").tag(false); Text("完了").tag(true)
                }.pickerStyle(.segmented)
                HStack(spacing: 12) {
                    TextField("ToDoを追加…", text: $title, axis: .vertical).lineLimit(1...3).accessibilityIdentifier("todo-input").focused($inputFocused)
                    Button {
                        store.addTodo(title); title = ""
                        inputFocused = false
                        showCompleted = false
                    } label: { Image(systemName: "plus").font(.system(size: 17, weight: .medium)).foregroundStyle(.white).frame(width: 36, height: 36).background(Palette.ink, in: Circle()) }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("このデバイスに保存")
                }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 0.75))
                if visibleTodos.isEmpty {
                    Card { EmptyState(icon: "checkmark.circle", title: showCompleted ? "完了したToDoはまだありません" : "進行中のToDoはまだありません", detail: "終わらせられる小さなことから始めましょう。\nここでは公式 App のToDoを表示・変更しません。") }
                } else {
                    ForEach(visibleTodos) { todo in
                        Button { store.toggleTodo(todo.id) } label: {
                            Card {
                                HStack(alignment: .top, spacing: 13) {
                                    Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 23)).foregroundStyle(Palette.green)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(todo.title).font(.system(size: 15)).strikethrough(todo.completed).foregroundStyle(todo.completed ? Palette.muted : Palette.ink)
                                        Text(todo.deliveryDescription).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                        if let day = SystemReminderSnapshot.dateOnlyLabel(todo.reminderDueComponents) {
                                            Text("予定：" + day).font(.caption2).foregroundStyle(Palette.muted)
                                        } else if let due = todo.dueAt { Text("予定：" + due.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Palette.muted) }
                                        if todo.reminderSourceID != nil { Text("システムのリマインダーからインポート · 独立したコピーで、書き戻しはしません").font(.caption2).foregroundStyle(Palette.muted) }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityLabel("\(todo.title)、\(todo.completed ? "このデバイスで完了" : "このデバイスで未完了")")
                            .contextMenu {
                                Button("内容と予定時刻を編集") { editingTodo = todo }
                                Button("削除済みへ移動", role: .destructive) { store.archiveTodo(todo.id, archived: true) }
                            }
                    }
                }
                HStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 7) {
                        GlassesTodoSyncCard()
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
                ShareLink(item: markdown) {
                    Label("ToDoリストをエクスポート（このデバイス）", systemImage: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(17)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                }.disabled(store.todos.isEmpty)
                Text("このデバイスの Markdown テキストを共有するだけで、グラスへは送信しません。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                NavigationLink("削除済みのToDo（復元可能）") { RemovedTodosView() }
                NavigationLink("送信待ちと競合") { TodoDeliveryView() }
                    .accessibilityIdentifier("todo-delivery-open")
                Text("項目を長押しすると編集・削除できます。予定時刻は記録のみで、システムのリマインダーは自動作成しません。").font(.caption).foregroundStyle(Palette.muted)
            }.padding(24)
        }.background(Palette.background).navigationTitle("ToDoリスト").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .sheet(item: $editingTodo) { TodoEditorView(todo: $0) }
    }
}

struct TodoEditorView: View {
    let todo: LocalTodo
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var hasDate = false
    @State private var due = Date()
    var body: some View {
        NavigationStack {
            Form {
                TextField("ToDoの内容", text: $title, axis: .vertical).accessibilityIdentifier("todo-edit-title")
                Toggle("予定時刻（自動では通知しません）", isOn: $hasDate)
                if hasDate { DatePicker("時刻", selection: $due) }
                Text("グラスに紐づいたタスクは、オンライン時に内容／完了状態の同期を試みます。予定時刻はこのデバイスにのみ保存し、通知は作成しません。").font(.caption)
            }.navigationTitle("ToDoを編集").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    store.editTodo(todo.id, title: title, dueAt: hasDate ? due : nil); dismiss()
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.onAppear { title = todo.title; hasDate = todo.dueAt != nil; due = todo.dueAt ?? Date() }
        }
    }
}

struct RemovedTodosView: View {
    @EnvironmentObject private var store: CompanionStore
    var body: some View {
        List {
            ForEach(store.todos.filter { $0.archivedAt != nil }) { todo in
                HStack { Text(todo.title); Spacer(); Button("復元") { store.archiveTodo(todo.id, archived: false) } }
            }
        }.navigationTitle("削除済みのToDo").toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
    }
}

struct PrompterView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var text = ""
    @State private var fontSize = 22.0
    @State private var mode = "编辑"
    @State private var page = 0
    @State private var saved = false
    private var pages: [String] { LocalPrompterPager.pages(text) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("プロンプターのモード", selection: $mode) { Text("編集").tag("编辑"); Text("スマホプレビュー").tag("手机预览") }.pickerStyle(.segmented)
                NavigationLink { BookShelfView() } label: {
                    Card { FeatureRow(icon: "books.vertical", title: "書籍のインポートと等速リーディング", subtitle: "TXT / EPUB · 章 · 再生速度 · 続きから読む", status: "ローカル利用可能", active: true) }
                }.buttonStyle(.plain).accessibilityIdentifier("book-shelf")
                if mode == "编辑" {
                    Card {
                        HStack { Text("マイ原稿").font(.headline).foregroundStyle(Palette.ink); Spacer(); Text("\(text.count) 文字").font(.caption).foregroundStyle(Palette.muted) }
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty { Text("話したいことを書いてください……").foregroundStyle(Palette.muted).padding(.top, 8).padding(.leading, 5) }
                            TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: 260).accessibilityIdentifier("prompter-input")
                        }.font(.system(size: 16)).padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Text("スマホレイアウトのプレビュー").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                    VStack {
                        ScrollView {
                            Text(pages.isEmpty ? "原稿がまだありません。まず編集画面で入力してください。" : pages[min(page, pages.count - 1)])
                                .font(.system(size: fontSize, weight: .medium)).foregroundStyle(Palette.mint).lineSpacing(14)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        }.frame(height: 210)
                        Text(pages.isEmpty ? "内容なし" : "スマホページ \(page + 1) / \(pages.count)").font(.system(size: 11)).foregroundStyle(Palette.mint.opacity(0.6)).padding(.bottom, 16)
                    }.background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
                    HStack { Text("文字サイズ"); Spacer(); Text("\(Int(fontSize))").monospacedDigit() }.font(.subheadline)
                    HStack { Text("A").font(.caption); Slider(value: $fontSize, in: 16...40, step: 1); Text("A").font(.title3) }
                    HStack {
                        Button { page = max(0, page - 1) } label: { Label("前のページ", systemImage: "chevron.left").frame(maxWidth: .infinity) }.disabled(page == 0)
                        Button { page = min(pages.count - 1, page + 1) } label: { Label("次のページ", systemImage: "chevron.right").frame(maxWidth: .infinity) }.disabled(page + 1 >= pages.count)
                    }.font(.system(size: 13)).padding(13).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    Text("1ページを140文字で区切っています。スマホで読みやすくするためで、グラスのページ区切りルールではありません。")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 12) {
                    Button { store.savePrompter(text); saved = true } label: {
                        Label(saved ? "保存済み" : "下書きを保存", systemImage: saved ? "checkmark" : "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("prompter-save")
                    ShareLink(item: text) { Label("原稿を共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.disabled(text.isEmpty)
                }.font(.system(size: 13, weight: .medium)).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.green, lineWidth: 0.75))
                GlassesPrompterControls(text:text)
                notice("レンズのレイアウトとノブ操作は実機検証が必要です")
            }.padding(24)
        }.background(Palette.background).navigationTitle("プロンプター").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .onAppear { text = store.prompterText }.onChange(of: text) { _ in saved = false; page = 0 }
    }
}

enum LocalPrompterPager {
    static func pages(_ text: String, charactersPerPage: Int = 140) -> [String] {
        guard !text.isEmpty, charactersPerPage > 0 else { return [] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: charactersPerPage, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

private func notice(_ text: String) -> some View {
    Label { Text(text).lineSpacing(4) } icon: { Image(systemName: "info.circle") }
        .font(.system(size: 12)).foregroundStyle(Palette.green).padding(14)
        .frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
}

struct ProtocolLabView: View {
    private let capabilities: [(String, String, String)] = [
        ("接続と認証", "スマホ → グラス / グラス → スマホ", "実機ビルドはプロトタイプの通信コアを再利用済みです。新しい Bundle のペアリング、バックグラウンド動作、ペアリング解除は実機での再検証が必要です。シミュレータはコアを読み込みません。"),
        ("音声のフルフロー", "ウェイク、音声、認識、応答、終了", "実機ビルドはクラウド ASR/VAD、Flash ストリーミング、連続した割り込み発話に対応します。まずキーを設定し、オンにすることを確認してください。新しい App のレンズ表示の検証はこれからです。"),
        ("ToDoの逆方向イベント", "グラスで完了 → スマホに統合", "ローカルでのチェックは逆方向プロトコルの証拠にはなりません。ID、更新時刻、重複イベント対策を保持する必要があります。"),
        ("プロンプターと表示", "スマホから送信 / グラスのノブ、ページ送り", "スマホプレビューはレンズ表示の検証の代わりにはなりません。ページ区切り、レイアウト、ヘッドコントロール、終了は実際の操作が必要です。"),
        ("録音とオフライン同期", "グラスのファイル → スマホにアーカイブ", "オンライン制御、offset 受信、Ogg/WAV とアーカイブは接続済みです。オフライン一覧のインポート、コールドスタート時の自動再開、新しい App での実機フルフローはこれからです。"),
        ("天気と通知", "スマホの内容 → グラスに表示", "送信成功とレンズ表示は分けて記録します。システム通知のミラーリングをカスタムプロトコルの実装とはみなしません。")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                notice("この画面は統合の境界を示す説明です。実験コマンドの送信や公式 App の読み取りは行いません。")
                ForEach(capabilities, id: \.0) { item in
                    Card {
                        HStack { Text(item.0).font(.headline).foregroundStyle(Palette.ink); Spacer(); Badge(text: "接続待ち / 検証待ち") }
                        Text(item.1).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.green)
                        Text(item.2).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                }
            }.padding(24)
        }.background(Palette.background).navigationTitle("プロトコルラボ").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var body: some View {
        if embedded { settingsContent } else {
            NavigationStack { settingsContent.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } } }
        }
    }
    private var settingsContent: some View {
        Form {
            Section {
                Toggle("画面デモを有効にする", isOn: $store.demoMode).disabled(store.voice.supportsDevice)
                Text("今回の起動時のみ有効です。デモ内容は明示し、音声の作成、モデルの起動、実際のデバイス状態の変更は行いません。")
                    .font(.footnote).foregroundStyle(Palette.muted)
            } header: { Text("デモモード") }
            Section("プライバシーとセキュリティ") {
                Label("マイクを自動で有効にしません", systemImage: "mic.slash")
                Label("音声や下書きを自動でアップロードしません", systemImage: "network.slash")
                Label("モデルのキーはシステムのキーチェーンにのみ保存します", systemImage: "key")
                Label("公式のログインや紐づけを引き継ぎません", systemImage: "lock.shield")
            }.font(.subheadline)
            Section("現在のビルド") {
                LabeledContent("バージョン", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0") + " · 研究版")
                LabeledContent("デバイス経路", value: store.voice.supportsDevice ? "ベンダーコアのアダプタ · 実機での再検証待ち" : "シミュレータでは無効")
                LabeledContent("最小システム", value: "iOS 16")
                Text("シミュレータとコンパイルの成功は、非脱獄の実機、ペアリング、レンズ表示の効果が検証済みであることを意味しません。")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }.navigationTitle("環境設定").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: embedded)
    }
}

struct HelpView: View {
    private let sections: [(String, String)] = [
        ("今使えるのは何ですか？", "このデバイスのToDoとプロンプター原稿。録音のコピーを手動で選んで検証し、手入力テキストから上書きできない Markdown リビジョンを生成してシステム共有すること。モデル設定の下書きと、隔離された Keychain のキーです。"),
        ("まだ正式な機能ではないのは？", "実際の Bluetooth 接続、独立した認証、音声の収録と認識、モデルの呼び出し、TTS、レンズ表示、逆方向イベント、NAS への自動アーカイブです。画面がこれらを成功として表示することはありません。"),
        ("録音はどこに保存されますか？", "新しいアーカイブは Turbo IO 自身のサンドボックス内の Documents/VerifiedRecordingArchiveV1 です。旧 ImportedRecordings は元の場所に残り、1件ずつ確認した場合だけ新しいアーカイブにコピーします。ソースは変更せず、自動再生、認識、アップロードはしません。"),
        ("デモでグラスが変わりますか？", "変わりません。デモはスマホ側の可視化と純粋なロジックの実験だけです。上部にはデモであることが常に表示されます。アプリを終了すると、既定で実際の未接続状態に戻ります。"),
        ("自分のモデルを接続するには？", "実機の音声画面では検証済みの Alibaba Cloud ASR と DeepSeek Flash を使い、音声サービスのキー画面で設定したあと、待機を明示的にオンにします。他のモデル設定は独立した下書きのままで、実際の音声サービスは変わりません。"),
        ("なぜリセットやアップグレードのボタンがないのですか？", "研究版では、画面を揃えるために危険な操作は追加しません。プロトコル、復旧経路、対象デバイスが確認できてから、確認ステップのある制御を開放します。"),
        ("本当に通じたと判断するには？", "コードのテスト、スマホでの動作、グラスの実際の表示、逆方向の操作を分けて検証します。最後に、自分の署名を使った非脱獄 iPhone で一通り検証する必要があります。")
    ]
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(sections, id: \.0) { item in
                    Card {
                        Text(item.0).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(item.1).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                }
            }.padding(24)
        }.background(Palette.background).navigationTitle("使い方").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
    }
}
