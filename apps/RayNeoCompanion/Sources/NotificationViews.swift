import SwiftUI

struct NotificationCenterView: View {
    @EnvironmentObject private var notifications: CompanionNotifications
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @State private var confirmSources = false
    var body: some View {
        Form {
            Section {
                Text("通知を、目の前へ届けよう").font(.title3.weight(.semibold))
                Text("システム通知の共有とカスタム業務通知は別の独立した経路です。このページでは他のAppの通知本文は収集しません。").font(.caption).foregroundStyle(Palette.muted)
                Text(voice.ready ? "グラス接続済み" : "グラス未接続 · 下書きの編集とプレビューは可能")
                    .accessibilityIdentifier("notification-connection")
            }
            Section("システム通知の共有 · ANCS") {
                Toggle("グラスの通知を許可", isOn: Binding(get: { notifications.preferences.enabled }, set: { notifications.setEnabled($0) }))
                    .accessibilityIdentifier("notification-master")
                Text("オンラインで待機中なら、メインスイッチはすぐ送信されます。オフラインでは下書きとして保存するだけです。iOSの通知許可が自動で変わることはありません。").font(.caption).foregroundStyle(Palette.muted)
                Button("現在のグラスにメインスイッチを適用") { notifications.applyMaster() }
                    .disabled(!notifications.canSend).accessibilityIdentifier("notification-apply-master")
                NavigationLink { NotificationSourcesView() } label: {
                    LabeledContent("許可するApp", value: "\(notifications.preferences.sources.filter(\.allowed).count)/\(notifications.preferences.sources.count)")
                }.accessibilityIdentifier("notification-sources-open")
                Picker("通知の表示時間", selection: Binding(get: { notifications.preferences.displayTime }, set: { notifications.setDisplayTime($0) })) {
                    ForEach([5,10,15,20,30], id: \.self) { seconds in Text("\(seconds) 秒").tag(seconds) }
                }.accessibilityIdentifier("notification-display-time")
                Button("15秒の下書きにする") { notifications.setDisplayTime(15) }
                    .accessibilityIdentifier("notification-duration-15")
                Text("新しい表示時間はレンズ側での計時確認が必要です。プロトコルでは表示時間と送信元フィルタが同じパケットに入るため、下書きを変えても自動送信はされません。適用前に送信元を確認してください。")
                    .font(.caption).foregroundStyle(Palette.muted)
                Text(notifications.sourcesNeedApply ? "送信元リスト：下書き未適用" : "送信元リスト：送信済み、効果は未確認")
                    .font(.caption).accessibilityIdentifier("notification-sources-state")
                Button("送信元設定をグラスに適用") { confirmSources = true }
                    .disabled(!notifications.canSend).accessibilityIdentifier("notification-apply-sources")
                Text(notifications.configurationStatus).font(.caption).accessibilityIdentifier("notification-settings-status")
                if let enabled = notifications.reportedEnabled {
                    Text("グラスの報告するメインスイッチ：\(enabled ? "オン" : "オフ")（送信元ごとの受信確認ではありません）").font(.caption)
                }
            }
            Section("手動テスト · サーバー不使用") {
                NavigationLink { NotificationTestView() } label: {
                    Label("テスト通知を作成して送信", systemImage: "paperplane")
                }.accessibilityIdentifier("notification-test-open")
                Text("グラスの業務チャンネルを直接使うため、スマホには通知は出ません。タイトルと本文を入力し、UID、状態、タイムアウトを確認できます。").font(.caption).foregroundStyle(Palette.muted)
            }
            Section("共有通知のチェック") {
                Text(notifications.availabilityStatus).accessibilityIdentifier("notification-ancs-status")
                Button("グラスの ANCS 状態を照会") { notifications.queryAvailability() }
                    .disabled(!notifications.canSend).accessibilityIdentifier("notification-query")
                Text("iPhoneの設定 → Bluetooth → グラスの詳細で、システム通知の共有を許可してください。送信元のAppにもシステム通知の権限が必要です。集中モードやプレビュー設定などが実際の表示に影響する場合があります。Turbo IOがこれらの設定を勝手に変更することはありません。").font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = notifications.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("notification-error") } }
        }
        .navigationTitle("通知センター").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .onAppear { features.prepare(); notifications.connectionChanged() }
        .onChange(of: voice.deviceID) { _ in notifications.connectionChanged() }
        .confirmationDialog("現在のグラスの通知送信元設定を置き換えますか？", isPresented: $confirmSources, titleVisibility: .visible) {
            Button("現在の設定を適用する") { notifications.applySources() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("メインスイッチ、リスト内の各App（電話を含む）のスイッチ、表示時間の下書きを適用します：displayTime=\(notifications.preferences.displayTime)、avoidDuplicate=false、intervalTime=2。グラスから読み戻した元の設定ではありません。リストにないAppがブロックされる保証はありません。")
        }
    }
}

struct NotificationSourcesView: View {
    @EnvironmentObject private var notifications: CompanionNotifications
    @State private var search = ""
    @State private var adding = false
    private var visible: [NotificationSource] {
        notifications.preferences.sources.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                Text("これらは設定可能な送信元で、スマホにインストール済みのApp一覧ではありません。プロトコルはオフにした項目の Bundle ID を送信します。未知のAppが自動で拒否されることはありません。初回適用で元の送信元フィルタ設定は置き換わります。")
                    .font(.caption).accessibilityIdentifier("notification-source-boundary")
                TextField("名前または Bundle ID で検索", text: $search)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("notification-source-search")
                Button("送信元Appを追加") { adding = true }.accessibilityIdentifier("notification-source-add")
            }
            Section("オンで許可 · 変更後は戻って適用") {
                ForEach(visible) { source in
                    Toggle(isOn: Binding(get: { notifications.preferences.sources.first(where: { $0.id == source.id })?.allowed ?? false },
                                         set: { notifications.setAllowed(source.id, $0) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                            Text(source.id).font(.caption2).foregroundStyle(Palette.muted)
                        }
                    }.accessibilityIdentifier("notification-source-\(source.id)")
                }
            }
            Section { Text("Bundle ID を間違えると、その送信元をフィルタできません。サードパーティAppのデータは読み取らず、通知を自動アップロードすることもありません。オフにした項目を戻すには、再びオンにして設定を適用してください。").font(.caption) }
        }
        .navigationTitle("許可するApp").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .sheet(isPresented: $adding) { NotificationSourceEditor() }
    }
}

private struct NotificationSourceEditor: View {
    @EnvironmentObject private var notifications: CompanionNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var id = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("App名", text: $name).accessibilityIdentifier("notification-source-name")
                TextField("Bundle ID（例：com.example.app）", text: $id)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("notification-source-id")
                Text("実際の Bundle ID を入力してください。表示名では識別子を代用できません。追加した項目は既定で許可され、保存後も戻って設定を適用する必要があります。").font(.caption)
                if let error = notifications.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("通知の送信元を追加").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送信元を保存") { if notifications.addSource(name: name, id: id) { dismiss() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !GlassesNotificationProtocol.validAppID(id))
                        .accessibilityIdentifier("notification-source-save")
                }
            }
        }
    }
}

struct NotificationTestView: View {
    @EnvironmentObject private var notifications: CompanionNotifications
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var title = "Turbo IO通知テスト"
    @State private var content = "これは独立Appの業務通知テストです。"
    @FocusState private var focused: Bool
    private var valid: Bool { (try? GlassesNotificationProtocol.notification(uid: "1", title: title, content: content)) != nil }
    var body: some View {
        Form {
            Section("テスト内容を編集") {
                Text("送信元はTurbo IO固定で、他のAppを装うことはありません。内容はこのページのメモリ内だけにあり、保存もサーバーへのアップロードもされません。").font(.caption).foregroundStyle(Palette.muted)
                TextField("タイトル（最大80文字）", text: $title, axis: .vertical)
                    .focused($focused).accessibilityIdentifier("notification-test-title")
                TextField("本文（最大500文字）", text: $content, axis: .vertical).lineLimit(3...8)
                    .focused($focused).accessibilityIdentifier("notification-test-content")
                Text("タイトル \(title.count)/80 · 本文 \(content.count)/500 · これはこの版のテスト上限で、レンズ側のレイアウトを保証するものではありません").font(.caption2)
                Button("ランダムな検証用テストデータを入力") {
                    let code = String(UUID().uuidString.prefix(6))
                    title = "Turbo IO通知テスト \(code)"; content = "1行目：独立業務通知\n2行目：検証コード \(code)\nグラスの文字を確認してください。"
                    focused = false
                }.accessibilityIdentifier("notification-test-sample")
            }
            Section("スマホのプレビュー · レンズのスクリーンショットではありません") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Turbo IO", systemImage: "bell.badge").font(.caption).foregroundStyle(Palette.green)
                    Text(title).font(.headline)
                    Text(content).font(.body)
                }.padding(.vertical, 8).accessibilityIdentifier("notification-test-preview")
            }
            Section {
                Button("グラスへ送信") {
                    focused = false; _ = notifications.send(title: title, content: content)
                }.disabled(!notifications.canTest || !valid).accessibilityIdentifier("notification-test-send")
                Text("認証済みの接続、グラス通知の許可、Turbo IO送信元のオン、メインスイッチの適用が先に必要です。音声、録音、プロンプターの使用中は割り込みません。ボタンは1回だけ送信し、自動再試行はしません。").font(.caption).foregroundStyle(Palette.muted)
                if let uid = notifications.lastUID { Text("直近の UID：\(uid)").font(.caption.monospaced()).accessibilityIdentifier("notification-test-uid") }
                Text(notifications.testStatus).accessibilityIdentifier("notification-test-status")
                if let operation = notifications.operationStatus { Text(operation).font(.caption) }
                if let error = notifications.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("notification-test-error") }
                Text("SDK呼び出しの戻り、グラスの状態返信、実際のレンズ表示は別の判定基準です。返信を受け取っても、上の検証コードを確認してください。従来の音声文字表示はこの項目の合格にはなりません。").font(.caption)
            }
        }
        .navigationTitle("カスタム通知テスト").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("編集を完了") { focused = false } } }
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .onChange(of: voice.deviceID) { _ in notifications.connectionChanged() }
    }
}
