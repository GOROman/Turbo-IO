import SwiftUI

struct RecordingRecoveryView: View {
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @State private var selected: String?
    @State private var raw: URL?
    var body: some View {
        List {
            Section("Turbo IO のローカルファイルだけを処理します") {
                Text("App 再起動後に受信ファイルを取り戻すための機能です。グラスへの接続、録音開始、オフライン分の再送リクエスト、元ファイルの削除は行いません。パッケージ化済みの古いタスク、または終了記録が残り欠損なくカバーされたタスクだけが、復旧を試せます。")
                    .font(.caption)
                Button("ローカルの受信フォルダをスキャン") { Task { await features.loadRecoveryEntries() } }
                    .disabled(features.recoveryBusy || features.recordingID != nil).accessibilityIdentifier("recovery-scan")
                Text(features.recoveryStatus).font(.caption).accessibilityIdentifier("recovery-status")
                if features.recoveryBusy { ProgressView() }
            }
            if features.recoveryEntries.isEmpty {
                Text("一覧表示できるローカル受信記録がありません").foregroundStyle(.secondary).accessibilityIdentifier("recovery-empty")
            }
            ForEach(features.recoveryEntries) { entry in
                Section("ローカル受信：" + entry.createdAt.formatted(date:.abbreviated,time:.shortened)) {
                    Text(entry.status).font(.subheadline)
                    Text("記録済み \(ByteCountFormatter.string(fromByteCount:Int64(entry.receivedBytes),countStyle:.file)) · ローカルID \(entry.id.prefix(8))").font(.caption)
                    Button("再検証、デコードしてアーカイブ") { selected = entry.id }
                        .disabled(!entry.mayRecover || features.recoveryBusy || features.recordingID != nil)
                    Button("生の rawopus を共有用に準備（完全性は未検証）") {
                        Task { raw = await features.recoveryRawFile(entry.id) }
                    }.disabled(features.recoveryBusy || features.recordingID != nil)
                }
            }
            if let raw {
                Section("生データであり、再生可能な録音の証明ではありません") {
                    Text("この rawopus は不完全な可能性があります。バックアップ／研究用に限ります。音声修復や ASR は行いません。共有パネルを開いても、相手に届いたことにはなりません。").font(.caption)
                    ShareLink(item:raw) { Label("選択した生ファイルを共有",systemImage:"square.and.arrow.up") }
                }
            }
        }.navigationTitle("ローカル受信の復旧")
        .task { await features.loadRecoveryEntries() }
        .onDisappear { raw = nil }
        .confirmationDialog("このローカルファイル1件だけを復旧します：再検証、デコード、アーカイブを行い、アップロードや削除はしません。",isPresented:Binding(get:{ selected != nil },set:{ if !$0 { selected = nil } })) {
            Button("ローカル復旧を試す") {
                if let id = selected { Task { await features.recoverRecording(id) } }
                selected = nil
            }
        }
    }
}
