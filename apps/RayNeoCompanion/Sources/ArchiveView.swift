import SwiftUI
import UniformTypeIdentifiers
import UIKit
import RayNeoArchive

struct ArchiveView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var showImporter = false
    @State private var showWorkflow = false
    @State private var filter = "全部"
    private func filterLabel(_ value: String) -> String {
        switch value {
        case "全部": return "すべて"
        case "待文字": return "テキスト待ち"
        case "有笔记": return "ノートあり"
        default: return value
        }
    }
    private var visibleRecordings: [ArchivedRecording] {
        archive.recordings.filter { filter == "全部" || (filter == "待文字" ? $0.transcripts.isEmpty : !$0.transcripts.isEmpty) }
    }
    var body: some View {
        Screen(title: "録音アーカイブ", eyebrow: "ローカル録音管理", headerIcon: "square.and.arrow.up", headerAction: { showWorkflow = true }) {
            GlassesRecordingCard()
            NavigationLink("ZIPエクスポートコピーと復旧用ステージング") { PortableExportCopiesView() }
                .accessibilityIdentifier("export-copies-open")
            HStack(spacing: 0) {
                ForEach(["全部", "待文字", "有笔记"], id: \.self) { value in
                    Button { filter = value } label: {
                        Text(filterLabel(value)).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(filter == value ? .white : Palette.ink)
                            .background(filter == value ? Palette.ink : .clear, in: Capsule())
                    }
                }
            }.padding(3).background(Palette.line.opacity(0.35), in: Capsule())
            ArchiveFeedbackView()
            if archive.recordings.isEmpty {
                Card {
                    EmptyState(icon: "waveform.badge.magnifyingglass", title: "録音がまだありません", detail: "ローカル音声を手動でインポートできます\nグラスの録音には本体での受信を先に有効化してください")
                        .padding(.top, 25).padding(.bottom, 10)
                    importButton("ローカル音声をインポート").padding(.horizontal, 20).padding(.bottom, 20)
                }
            } else {
                SectionLabel(title: "検証済みアーカイブ", trailing: "\(archive.recordings.count) 件のローカルコピー")
                if visibleRecordings.isEmpty {
                    Card { EmptyState(icon: "line.3.horizontal.decrease.circle", title: "このカテゴリには記録がありません", detail: "テキストは手動で用意してください。ここでは自動で文字起こししません。") }
                }
                ForEach(visibleRecordings) { recording in
                    NavigationLink { ArchiveDetailView(original: recording) } label: {
                        Card {
                            HStack(alignment: .top, spacing: 13) {
                                Image(systemName: "waveform").foregroundStyle(Palette.green).frame(width: 38, height: 44).background(Palette.background, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(recording.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                                    Text("\(recording.importedAt.formatted(date: .abbreviated, time: .shortened)) インポート · \(ByteCountFormatter.string(fromByteCount: recording.byteCount, countStyle: .file))")
                                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                    Badge(text: archive.verificationIssues[recording.id] != nil ? "検証エラー · 要再確認" : (recording.transcripts.isEmpty ? "検証済みコピー · テキスト未提供" : "\(recording.transcripts.count) 版のローカルMarkdown"), active: archive.verificationIssues[recording.id] == nil)
                                    if archive.verificationIssues[recording.id] != nil {
                                        Label("アーカイブ検証エラー、詳細を確認", systemImage: "exclamationmark.triangle")
                                            .font(.caption2).foregroundStyle(Palette.amber)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                            }.contentShape(Rectangle())
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("archive-row-\(recording.id.uuidString)")
                }
                importButton("インポートを続ける")
            }
            if archive.allowsTestFixture {
                Button { Task { await archive.importTestFixture() } } label: {
                    Label("合成テストサンプルをインポート", systemImage: "testtube.2").font(.footnote)
                }.disabled(archive.isBusy).accessibilityIdentifier("archive-import-fixture")
                Text("分離されたDebug検証用入口。有効な音声ではなく、タップ後に作成されます。")
                    .font(.caption2).foregroundStyle(Palette.amber)
                #if DEBUG
                Menu {
                    ForEach(ContainerSyntheticFixture.allCases) { fixture in
                        Button(fixture.title) { Task { await archive.importContainerFixture(fixture) } }
                            .accessibilityIdentifier("container-fixture-\(fixture.rawValue)")
                    }
                } label: {
                    Label("合成コンテナサンプルを選択", systemImage: "testtube.2").font(.footnote)
                }.disabled(archive.isBusy).accessibilityIdentifier("container-fixture-menu")
                #endif
            }
            if !store.recordings.isEmpty {
                NavigationLink { LegacyRecordingsView() } label: {
                    Card { FeatureRow(icon: "folder", title: "旧バージョンのインポートコピー", subtitle: "\(store.recordings.count) 件のファイルを元の場所に保持し、自動移行しません", status: "表示") }
                }.buttonStyle(.plain).accessibilityIdentifier("legacy-recordings")
            }
            Button { showWorkflow = true } label: {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("エクスポート先").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text("NAS / Obsidian").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
                        Label("ローカルMarkdownは共有可能 · アップロードは未接続", systemImage: "clock").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 5)
                    }
                    Spacer(); Image(systemName: "server.rack").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.green)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 20))
            }.buttonStyle(.plain)
            Button("ローカルアーカイブを更新・復旧") { Task { await archive.load() } }.font(.caption).disabled(archive.isBusy)
            Text("手動インポート · 自動文字起こしなし · 自動アップロードなし").font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
        }
        .task { await archive.load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, UTType(filenameExtension: "ogg") ?? .audio]) { result in
            switch result {
            case .success(let url): Task { await archive.importFile(url) }
            case .failure(let error): archive.errorMessage = "ファイル選択に失敗しました：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showWorkflow) { ArchiveWorkflowView() }
    }
    private func importButton(_ title: String) -> some View {
        PrimaryButton(title: archive.isBusy ? "アーカイブ処理中…" : title, icon: "square.and.arrow.down", enabled: !archive.isBusy) { showImporter = true }
            .accessibilityIdentifier("archive-import-file")
    }
}

struct ArchiveDetailView: View {
    @EnvironmentObject private var archive: LocalArchiveController
    let original: ArchivedRecording
    @State private var mode = "归档证据"
    @State private var title = ""
    @State private var transcript = ""
    @State private var share: ArchiveShareItem?
    @State private var confirmBundle = false
    @State private var bundleTask: Task<Void,Never>?
    @FocusState private var editing: Bool
    private var recording: ArchivedRecording { archive.recordings.first { $0.id == original.id } ?? original }
    private var integrityIssue: String? { archive.verificationIssues[original.id] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("本体で検証済みアーカイブ", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Palette.mint)
                    Text(recording.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text("音声のデコード、認識、リモートアップロードは行っていません").font(.system(size: 11)).foregroundStyle(Palette.mint.opacity(0.8))
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
                Picker("アーカイブ詳細", selection: $mode) {
                    Text("アーカイブ証拠").tag("归档证据"); Text("テキストと改訂").tag("文字与修订")
                }.pickerStyle(.segmented)
                ArchiveFeedbackView()
                if let integrityIssue {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("このアーカイブには検証エラーがあります", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.medium))
                        Text(integrityIssue).font(.caption)
                        Text("更新やエラーを閉じてもこの異常は消えません。完全な再検証に合格すると復旧します。過去の検証記録は保持されます。")
                            .font(.caption2)
                    }.foregroundStyle(Palette.amber).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.99, green: 0.95, blue: 0.85), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("archive-persistent-integrity-issue")
                }
                if mode == "归档证据" { evidenceContent } else { transcriptContent }
            }.padding(24)
        }.background(Palette.background).scrollDismissesKeyboard(.interactively)
            .navigationTitle("録音の詳細").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .onAppear { if title.isEmpty { title = recording.title } }
            .sheet(item: $share) { item in ArchiveShareView(item: item) }
            .onDisappear { bundleTask?.cancel() }
            .confirmationDialog("この録音と選択したリビジョンのみをエクスポートします。他の資料は含みません。追加のローカルコピーが作成されます。",isPresented:$confirmBundle) {
                if let latest = recording.transcripts.last {
                    Button("音声 + 最新のノート") { exportBundle(.selected([latest.id])) }
                    Button("音声 + すべてのノートリビジョン") { exportBundle(.all) }
                }
                Button("音声と検証リストのみ") { exportBundle(.selected([])) }.accessibilityIdentifier("archive-bundle-audio-only")
            }
    }
    private var evidenceContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                evidenceRow("1", title: "ソースコピーを複製済み", detail: "ソースは移動していません。グラスの無線転送の完全性を保証するものではありません", complete: recording.evidence.sourceCopied, id: "evidence-copy")
                Divider().overlay(Palette.line)
                evidenceRow("2", title: integrityIssue == nil ? "アーカイブのバイトは検証に合格済み" : "アーカイブ内容の確認が必要です", detail: "過去のSHA-256と長さの記録です。音声がデコード可能であることを保証しません", complete: recording.evidence.checksumVerified && integrityIssue == nil, id: "evidence-checksum")
                Divider().overlay(Palette.line)
                evidenceRow("3", title: recording.evidence.transcriptProvided ? "ユーザーのテキストを保存済み" : "ユーザーのテキスト待ち", detail: "このアプリは音声認識を行っていません", complete: recording.evidence.transcriptProvided, id: "evidence-transcript")
                Divider().overlay(Palette.line)
                evidenceRow("4", title: recording.evidence.noteExported ? "ローカルMarkdownを生成済み" : "Markdown生成待ち", detail: "NASが受信済み、またはObsidianがインデックス済みであることを保証しません", complete: recording.evidence.noteExported, id: "evidence-note")
            }
            Card {
                Text("検証記録").font(.headline).foregroundStyle(Palette.ink)
                Text("保存時の検証：\(recording.checksumVerifiedAt.formatted(date: .abbreviated, time: .standard))")
                if let date = archive.latestVerifications[recording.id] {
                    Text("今回の実行での再検証：\(date.formatted(date: .abbreviated, time: .standard))")
                } else { Text("一覧には過去の記録を表示します。一覧の更新ではすべての音声を再読み込みしません。") }
                Text("録音日時：\(recording.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? "不明。インポート日時で代用しません")")
                Text("SHA-256\n\(recording.sha256)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }.font(.caption).foregroundStyle(Palette.muted)
            NavigationLink { AudioContainerInspectionView(recordingID: recording.id) } label: {
                Card { FeatureRow(icon: "waveform.path.ecg", title: "音声コンテナ検査", subtitle: "Ogg / Opusの構造を手動で検査します。デコードや認識はしません", status: "ローカルツール", active: true) }
            }.buttonStyle(.plain).accessibilityIdentifier("archive-open-container-check")
            PrimaryButton(title: "音声とノートを再検証", icon: "checkmark.shield", enabled: !archive.isBusy) {
                Task { _ = await archive.verify(recording.id) }
            }.accessibilityIdentifier("archive-verify")
            Button("検証して音声コピーを共有") {
                Task { if let url = await archive.verify(recording.id) { share = ArchiveShareItem(url: url, isMarkdown: false) } }
            }.disabled(archive.isBusy).font(.subheadline).accessibilityIdentifier("archive-share-audio")
            Button("Obsidian / NAS用ポータブルZIPをエクスポート") { confirmBundle = true }
                .disabled(archive.isBusy).font(.subheadline).accessibilityIdentifier("archive-export-bundle")
            Text("展開後も notes/ と audio/ の相対ディレクトリを保持します。APIキーや他の会話は含みません。エクスポートはアップロードやインデックスの成功を意味しません。").font(.caption).foregroundStyle(Palette.muted)
        }
    }
    private func exportBundle(_ selection: SnapshotRevisionSelection) {
        bundleTask = Task {
            if let url = await archive.preparePortableShare(recordingID:recording.id,revisions:selection), !Task.isCancelled {
                share = ArchiveShareItem(url:url,isMarkdown:false,isBundle:true)
            }
        }
    }
    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("テキストは手動入力 · ASRは起動しません", systemImage: "pencil.line").font(.caption).foregroundStyle(Palette.green)
            Card { ManualRecordingASRView(id: recording.id, title: recording.title) }
            Card {
                Text("ノートのタイトル").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                TextField("1行のタイトル、最大256 UTF-8バイト", text: $title).textInputAutocapitalization(.never)
                    .padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("archive-note-title").focused($editing)
                Text("入力したテキスト").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                TextEditor(text: $transcript).frame(minHeight: 170).scrollContentBackground(.hidden)
                    .padding(8).background(Palette.background, in: RoundedRectangle(cornerRadius: 12)).focused($editing).accessibilityIdentifier("archive-transcript")
                Text("現在 \(transcript.utf8.count) バイト / 1 MiB。未保存のテキストはこのページを離れると失われます。")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            PrimaryButton(title: "ローカルMarkdownリビジョンとして保存", icon: "doc.badge.plus", enabled: !archive.isBusy && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                editing = false
                Task { _ = await archive.saveTranscript(recordingID: recording.id, text: transcript, title: title) }
            }.accessibilityIdentifier("archive-save-note")
            Text("テキストやタイトルを変更すると新しいリビジョンを作成します。同じ入力では旧版を再利用し、旧稿は上書きしません。")
                .font(.caption).foregroundStyle(Palette.muted)
            SectionLabel(title: "ローカルリビジョン", trailing: "\(recording.transcripts.count) 版")
            if recording.transcripts.isEmpty {
                Text("Markdownリビジョンがまだありません").font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("archive-no-revisions")
            }
            ForEach(recording.transcripts.reversed()) { revision in
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("第\(revision.number)版 · \(revision.title)").font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).accessibilityIdentifier("archive-revision-\(revision.number)")
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button {
                            Task { if let url = await archive.prepareNoteShare(recordingID: recording.id, revisionID: revision.id) { share = ArchiveShareItem(url: url, isMarkdown: true) } }
                        } label: { Image(systemName: "square.and.arrow.up").frame(width: 36, height: 36) }
                            .disabled(archive.isBusy).accessibilityLabel("第\(revision.number)版のMarkdownを確認して共有").accessibilityIdentifier("archive-share-note-\(revision.number)")
                    }
                }
            }
        }
    }
    private func evidenceRow(_ number: String, title: String, detail: String, complete: Bool, id: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle").foregroundStyle(complete ? Palette.green : Palette.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink).accessibilityIdentifier(id)
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ArchiveFeedbackView: View {
    @EnvironmentObject private var archive: LocalArchiveController
    var body: some View {
        if archive.isBusy { ProgressView(archive.activity).font(.caption).frame(maxWidth: .infinity).padding(8) }
        if let error = archive.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("ローカル操作が完了しませんでした", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.medium))
                Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("エラー説明を閉じる") { archive.errorMessage = nil }.font(.caption)
            }.foregroundStyle(Palette.amber).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.99, green: 0.95, blue: 0.85), in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("archive-error")
        } else if let message = archive.statusMessage {
            Text(message).font(.caption).foregroundStyle(Palette.green).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("archive-status")
        }
    }
}

struct LegacyRecordingsView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var selected: LocalRecording?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("旧コピーは元のディレクトリに保持されます。自動移行、削除、SHA-256成功マークの追加は行いません。明示的に1件を選択した場合のみ、新しい検証済みアーカイブへコピーします。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                ArchiveFeedbackView()
                ForEach(store.recordings) { recording in
                    Card {
                        Text(recording.name).font(.headline).foregroundStyle(Palette.ink)
                        Badge(text: "旧バージョンのコピー · 新アーカイブ未検証")
                        if let url = store.recordingURL(recording) {
                            Button("検証済みアーカイブへコピー（旧コピーは保持）") { selected = recording }.disabled(archive.isBusy)
                            ShareLink(item: url) { Label("旧音声コピーを共有", systemImage: "square.and.arrow.up") }.font(.caption)
                        } else { Text("旧コピーは現在読み取れません。メタデータは保持されています。").font(.caption).foregroundStyle(Palette.amber) }
                    }
                }
            }.padding(24)
        }.background(Palette.background).navigationTitle("旧バージョンのインポートコピー").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .confirmationDialog("この1件のみを新しい検証済みアーカイブへコピーします。旧コピーは削除も移動もしません。", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                Button("コピーを確定し、旧コピーを保持") {
                    if let recording = selected, let url = store.recordingURL(recording) { Task { await archive.importFile(url, title: recording.name) } }
                    selected = nil
                }
                Button("キャンセル", role: .cancel) { selected = nil }
            }
    }
}

struct ArchiveShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let isMarkdown: Bool
    var isBundle = false
}

struct ArchiveShareView: View {
    @Environment(\.dismiss) private var dismiss
    let item: ArchiveShareItem
    @State private var presentation: ArchiveExportKind?
    @State private var exportError: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Label("ローカルファイルのみを共有", systemImage: "square.and.arrow.up").font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(item.isBundle
                     ? "ZIPは項目ごとに展開し、長さ、CRC、SHA-256を確認済みです。選択した音声、ノート、検証リストを含みます。展開後はフォルダ全体をObsidianに入れ、notes/ と audio/ を同じ階層に保持してください。NASへのアップロードやインデックスの検証は行っていません。"
                     : item.isMarkdown
                     ? "Markdownは共有前にハッシュを確認済みです。ノート単体の共有には音声添付は含まれません。Obsidianに入れる場合は対応する音声も一緒に保存し、notes/ と audio/ の相対ディレクトリを保持してください。"
                     : "このファイルはバイト再検証済みのローカルコピーです。デコード可能性は検証しておらず、バックグラウンドアップロードも行っていません。")
                    .font(.subheadline).foregroundStyle(Palette.muted).lineSpacing(5)
                Text("システム共有パネルを開いてもリモート側が受信したことにはなりません。対象アプリで保存結果を確認してください。")
                    .font(.caption).foregroundStyle(Palette.amber)
                Button { open(.share) } label: {
                    Label("システム共有を開く", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity).padding(17).background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                }.accessibilityIdentifier("archive-system-share")
                Button { open(.files) } label: {
                    Label("ファイルに保存", systemImage: "folder").frame(maxWidth: .infinity).padding(15)
                }.accessibilityIdentifier("archive-save-files")
                Spacer()
            }.padding(24).background(Palette.background).navigationTitle("ローカルファイル共有").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
        .sheet(item: $presentation) { kind in
            NativeArchiveExportSheet(url: item.url, kind: kind) { error in
                presentation = nil
                if let error { exportError = error }
            }
        }
        .alert("ファイル共有を開けません", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("了解しました", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }
    private func open(_ kind: ArchiveExportKind) {
        guard item.url.isFileURL, FileManager.default.isReadableFile(atPath: item.url.path) else {
            exportError = "ファイルは現在読み取れません。録音の詳細に戻って再検証してからお試しください。元の録音は変更されていません。"; return
        }
        presentation = kind
    }
}

enum ArchiveExportKind: String, Identifiable {
    case share, files
    var id: String { rawValue }
}

/// Present from SwiftUI's actual sheet host, not a guessed root controller.
/// UIKit directly receives the verified local URL; no Transferable metadata hop.
struct NativeArchiveExportSheet: UIViewControllerRepresentable {
    let url: URL
    let kind: ArchiveExportKind
    let completion: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIViewController {
        let coordinator = context.coordinator
        if kind == .files {
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = coordinator
            return picker
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak coordinator] _, _, _, error in
            DispatchQueue.main.async {
                coordinator?.completion(error == nil ? nil : "システム共有が完了しませんでした。再試行するか、ファイルに保存してください。元のファイルは保持されています。")
            }
        }
        return activity
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (String?) -> Void
        init(completion: @escaping (String?) -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(nil) // Destination provider owns the copy; never delete source.
        }
    }
}

struct ArchiveWorkflowView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("音声から、自分の知識へ。").font(.title2.bold()).foregroundStyle(Palette.ink)
                    Text("ユーザーがソースを選択し、まず安定した本体専用ディレクトリへコピーして、バイトを個別に確認します。テキストは手動で用意してください。変更のたびに新しいノートを作成し、旧稿は上書きしません。")
                        .font(.subheadline).foregroundStyle(Palette.muted).lineSpacing(5)
                    Card {
                        FeatureRow(icon: "1.circle", title: "グラスからスマホへ", subtitle: "録音の同期、完全性、レジューム転送は別途接続が必要です")
                        FeatureRow(icon: "2.circle", title: "本体で検証済みアーカイブ", subtitle: "ファイルを明示的に選択、ソース保持、SHA-256で重複排除", status: "ローカル利用可", active: true)
                        FeatureRow(icon: "3.circle", title: "手動テキストとMarkdown", subtitle: "ローカルリビジョンとシステム共有、自動認識なし", status: "ローカル利用可", active: true)
                        FeatureRow(icon: "4.circle", title: "NAS と Obsidian", subtitle: "リモート転送、添付のマッピング、実際のインデックスは未検証です")
                    }
                    Text("検証はコピー後のバイトのみが対象で、音声のデコード、元の無線カバレッジ、テキストの正確さを証明しません。NASアドレスのプリセットはなく、公式の認証情報も読み取りません。")
                        .font(.footnote).foregroundStyle(Palette.green)
                }.padding(24)
            }.background(Palette.background).navigationTitle("アーカイブの流れ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}
