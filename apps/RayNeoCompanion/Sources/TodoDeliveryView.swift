import SwiftUI

struct TodoDeliveryView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var confirmRetry = false
    private var rows: [LocalTodo] { store.todos.filter { $0.archivedAt == nil } }
    var body: some View {
        List {
            Section {
                Text("この端末での編集は次回送信まで保持されます。再接続しても一括で再送はしません。新規項目の初回送信はToDoホームでの確認が必要です。")
                Text("送信済みはグラス側の項目ごとの確認ではありません。完了状態の返信では、タイトルの版が届いたことまでは証明できません。予定時刻は送信されません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("連携済み項目の未送信の変更を再試行") { confirmRetry = true }
                    .disabled(!voice.ready || !rows.contains { $0.wireID != nil && $0.delivery?.pending == true })
                    .accessibilityIdentifier("todo-retry-pending")
                Text(features.todoStatus).font(.caption)
                if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
            }
            Section("この端末の送信履歴") {
                if rows.isEmpty { Text("ToDoの送信履歴はまだありません").accessibilityIdentifier("todo-delivery-empty") }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.title).font(.headline)
                        Text(row.deliveryDescription).font(.caption)
                        if let date = row.delivery?.submittedAt {
                            Text("前回送信：" + date.formatted(date: .abbreviated, time: .standard)).font(.caption2)
                        }
                        if let observed = row.delivery?.conflict {
                            Text("スマホ：\(row.completed ? "完了" : "未完了") · グラスの返信：\(observed.completed ? "完了" : "未完了")")
                                .font(.caption)
                            Text("重要フラグ：スマホ \((row.important ?? false) ? "はい" : "いいえ") · グラス \(observed.important.map { $0 ? "はい" : "いいえ" } ?? "なし")")
                                .font(.caption)
                            Text("この端末のタイトルと予定時刻は保持されます。以下の選択はこの端末の競合を解決するだけで、すぐには送信しません。")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button("スマホの状態を保持し、送信待ちに追加") { store.resolveTodoConflict(row.id, useGlassesStatus: false) }
                                .buttonStyle(.borderless)
                            Button("グラスの状態を採用し、この端末のタイトルを保持") { store.resolveTodoConflict(row.id, useGlassesStatus: true) }
                                .buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle("送信待ちと競合").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("現在のグラスと連携済みの未送信の変更を再試行しますか？スマホだけにある新規項目は送信されません。", isPresented: $confirmRetry) {
                Button("送信待ちを再試行") { features.syncTodos(pendingOnly: true) }
            }
    }
}
