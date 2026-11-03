import SwiftUI

struct PortableExportCopiesView: View {
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var selected: PortableExportCopy?
    var body: some View {
        List {
            Section {
                Text("ZIP エクスポート時に生成されたコピーのフォルダ（スナップショットと失敗した一時パッケージを含む）だけを管理します。録音の元アーカイブ、受信キャッシュ、文字の修正には触れません。")
                Text("一時保管箱へ移すと復元でき、エクスポート回数の枠も空きますが、ディスク容量は解放されません。両方とも上限 20 件で、自動削除や完全削除はありません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("フォルダのスキャンは内容の検証ではありません。再共有する場合は録音の詳細に戻り、新しい検証パッケージを生成してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("コピー一覧を更新") { Task { await archive.loadExportCopies() } }.disabled(archive.isBusy)
                if archive.exportCopies.unrecognized > 0 {
                    Text("\(archive.exportCopies.unrecognized) 件の異常または不明なフォルダはそのまま残し、移動操作は提供しません。")
                        .foregroundStyle(Palette.amber)
                }
                if let error = archive.errorMessage { Text(error).foregroundStyle(Palette.amber) }
                if let status = archive.statusMessage { Text(status).font(.caption) }
            }
            ForEach([false, true], id: \.self) { trash in
                Section(trash ? "復元可能な一時保管箱" : "エクスポートコピー") {
                    let rows = archive.exportCopies.copies.filter { $0.inTrash == trash }
                    if rows.isEmpty { Text(trash ? "一時保管箱は空です" : "生成済みのエクスポートコピーはありません") }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("エクスポート " + row.id.uuidString.prefix(8)).font(.headline)
                            Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened) + " · " + ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)).font(.caption)
                            Button(trash ? "このコピーを復元" : "復元可能な一時保管箱へ移動") { selected = row }
                                .disabled(archive.isBusy).buttonStyle(.borderless)
                                .accessibilityIdentifier("export-copy-move-\(row.id.uuidString)")
                        }
                    }
                }
            }
        }.navigationTitle("ZIP エクスポートコピー").navigationBarTitleDisplayMode(.inline)
            .task { await archive.loadExportCopies() }
            .confirmationDialog(selected.map { "\($0.inTrash ? "復元" : "一時保管")エクスポートコピー \($0.id.uuidString.prefix(8))？派生コピーだけを移動し、元のアーカイブは変わりません。" } ?? "操作の確認",
                isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let row = selected {
                    Button(row.inTrash ? "復元する" : "一時保管箱へ移す") {
                        selected = nil
                        Task { await archive.moveExportCopy(row.id, toTrash: !row.inTrash) }
                    }
                }
            }
    }
}
