import SwiftUI

struct ConversationTimelineView: View {
    @EnvironmentObject private var timeline: ConversationTimeline
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var exporting = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Turbo IO 内の実際の AI 会話だけを記録します。認識テキスト、回答、時刻を含みます。他の App のチャットは読み取りません。フロー用のデモをチャット記録として扱うこともありません。")
                    .font(.caption).foregroundStyle(Palette.muted)
                if let error = timeline.storageError { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                PrimaryButton(title: exporting ? "エクスポートを準備中…" : "タイムライン全体をエクスポート", icon: "square.and.arrow.up", enabled: !timeline.turns.isEmpty && !exporting) {
                    exporting = true
                    Task { defer { exporting = false }; do { exportURL = try await timeline.export() } catch { self.error = "エクスポートに失敗しました。履歴は削除されていません。" } }
                }.accessibilityIdentifier("timeline-export")
                if let exportURL {
                    ShareLink(item: exportURL) { Label("共有 / ファイルに保存（Markdown）", systemImage: "doc") }
                    Text("これはエクスポートをタップした時点のスナップショットです。その後の新しい会話は再エクスポートが必要です。システムの共有からファイル、NAS ファイルプロバイダ、Obsidian に保存できます。")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
                if timeline.turns.isEmpty {
                    Card { EmptyState(icon: "clock", title: "まだ会話がありません", detail: "実際の会話は時刻順に自動でこのデバイスに記録されます。\nライブ画面を閉じても履歴は削除されません。") }
                }
                ForEach(timeline.turns.reversed()) { turn in
                    Card {
                        HStack { Text(turn.startedAt.formatted(date: .abbreviated, time: .standard)).font(.caption); Spacer(); Badge(text: turn.outcome) }
                        Label("自分", systemImage: "person").font(.caption.bold()).foregroundStyle(Palette.green)
                        Text(turn.question.isEmpty ? "有効な認識テキストを受信していません" : turn.question).font(.subheadline).textSelection(.enabled)
                        Divider().overlay(Palette.line)
                        Label("AI", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(Palette.green)
                        Text(turn.answer.isEmpty ? "回答が生成されていません" : turn.answer).font(.subheadline).textSelection(.enabled)
                    }.privacySensitive()
                }
            }.padding(24)
        }.background(Palette.background).navigationTitle("会話タイムライン").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .alert("エクスポート", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("わかった") {} } message: { Text(error ?? "") }
    }
}
