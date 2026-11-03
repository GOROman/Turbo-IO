import SwiftUI

struct ReminderImportView: View {
    @EnvironmentObject private var store: CompanionStore
    @StateObject private var reader = ReminderImportController.forCurrentLaunch()
    @State private var selectedList = ""
    @State private var confirmImport = false
    @State private var showCompleted = false
    var body: some View {
        List {
            Section {
                Text("iPhoneのリマインダーから選択したToDoを取り込む").font(.headline)
                Text("まず許可して、リストを選びます。チェックした項目のタイトル、完了状態、予定時刻だけをコピーします。メモ、添付、場所、連絡先は取り込みません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("iOS 17以降、システム権限の名前は「フルアクセス」ですが、Turbo IOは読み取りだけを行い、システムのToDoは変更しません。取り込んでもグラスへ自動送信はせず、通知も作成しません。")
                    .font(.caption).foregroundStyle(.secondary)
                if reader.isFixture {
                    Text("合成テストモード · システムデータは読み取りません").foregroundStyle(Palette.amber).accessibilityIdentifier("reminders-fixture-banner")
                }
                Button("許可してリストを読み込む") { Task { selectedList = ""; await reader.loadLists() } }
                    .disabled(reader.busy).accessibilityIdentifier("reminders-authorize")
                Text(reader.status).font(.caption).accessibilityIdentifier("reminders-status")
                if let error = reader.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                if reader.busy { ProgressView("読み込み中…") }
            }
            if !reader.lists.isEmpty {
                Section("リストを選択") {
                    Picker("システムのリスト", selection: Binding(get: { selectedList }, set: { selectedList = $0; reader.cancel() })) {
                        Text("選択してください").tag("")
                        ForEach(reader.lists) { list in Text(list.title).tag(list.id) }
                    }.disabled(reader.busy).accessibilityIdentifier("reminders-list-picker")
                    Button("選択したリストを読み込む") { Task { await reader.loadReminders(listID: selectedList) } }
                        .disabled(selectedList.isEmpty || reader.busy).accessibilityIdentifier("reminders-read-list")
                    Text("そのリストだけを読み込み、システムのスマートリストのルールは含みません。取り込み元のスナップショットは最大500件までです。上限を超えた場合は切り取って完全なリストのように見せることはしません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !reader.rows.isEmpty {
                Section("取り込む項目を選択") {
                    Toggle("完了済みを表示", isOn: $showCompleted)
                    Text("\(reader.selected.count) 件を選択中（最大100件）。完了済み項目を隠すと選択は解除され、誤って取り込むのを防ぎます。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(reader.rows.filter { showCompleted || !$0.completed }) { row in
                        Button { reader.toggle(row.id) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: reader.selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).foregroundStyle(Palette.ink)
                                    Text(row.completed ? "システムで完了" : "システムで未完了").font(.caption).foregroundStyle(.secondary)
                                    if let day = SystemReminderSnapshot.dateOnlyLabel(row.dueComponents) { Text(day).font(.caption) }
                                    else if let due = row.dueAt { Text(due.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                                }
                            }
                        }.accessibilityIdentifier("reminders-row-\(row.id)")
                    }
                    Button("選択分をTurbo IOへ取り込む（\(reader.selected.count)）") { confirmImport = true }
                        .disabled(reader.selected.isEmpty || reader.busy).accessibilityIdentifier("reminders-import")
                    Text("これは1回限りのコピーで、継続的な同期はしません。タイトルは最大300文字まで保持します。繰り返しルール、サブタスクの関係、メモ、システムのリマインダーはコピーしません。システム側の元データは変わりません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("読み込みプレビューを消去") { reader.discardPreview(); selectedList = "" }
                    .accessibilityIdentifier("reminders-clear")
                Text("同じ取り込み元IDの再取り込みはスキップされます。削除済みのこの端末のToDoも対象で、上書きも自動復元もしません。システム同期で取り込み元IDが作り直されると、新規項目とみなされる場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("システムのリマインダー").navigationBarTitleDisplayMode(.inline)
            .onChange(of: showCompleted) { _ in reader.clearSelection() }
            .onDisappear { reader.discardPreview() }
            .confirmationDialog("選択した項目をTurbo IOへコピーしますか？システムのリマインダーは変更せず、グラスへもすぐには送信しません。", isPresented: $confirmImport) {
                Button("Turbo IOへだけ取り込む") { reader.importSelected(into: store) }
            }
    }
}
