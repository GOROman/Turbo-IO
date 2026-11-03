import Foundation
import Combine
import CryptoKit
import RayNeoArchive

struct ArchiveLibrarySnapshot: Sendable {
    let recordings: [ArchivedRecording]
    let recovery: RecoveryReport
}

enum LocalArchiveError: LocalizedError {
    case busy, fixtureUnavailable, coordinationFailed, noteMissing, noteChanged
    var errorDescription: String? {
        switch self {
        case .busy: return "アーカイブが別の操作を処理中です。しばらくお待ちください。"
        case .fixtureUnavailable: return "合成サンプルは隔離された Debug 検証専用です。"
        case .coordinationFailed: return "ファイルプロバイダから読み取り可能なコピーを取得できませんでした。ファイルのダウンロード完了後に再試行してください。"
        case .noteMissing: return "この Markdown リビジョンが見つかりません。共有の準備はしていません。"
        case .noteChanged: return "Markdown ファイルが保存済みの検証記録と一致しません。共有を停止しました。ファイルは上書きしていません。"
        }
    }
}

/// Only local file work. No glasses transport, microphone, ASR, network or upload implementation.
actor LocalArchiveRepository {
    private let explicitRoot: URL?
    private let limits: ArchiveLimits
    private var archive: ArchiveStore?
    private var portableExportActive = false

    init(rootDirectory: URL?, limits: ArchiveLimits = ArchiveLimits()) {
        explicitRoot = rootDirectory
        self.limits = limits
    }

    private func open() throws -> ArchiveStore {
        if let archive { return archive }
        let root: URL
        if let explicitRoot { root = explicitRoot }
        else {
            root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("VerifiedRecordingArchiveV1", isDirectory: true)
        }
        // Never point this at the old ImportedRecordings directory or a File Provider/NAS destination.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let created = try ArchiveStore(rootDirectory: root, limits: limits)
        archive = created
        return created
    }

    func load() async throws -> ArchiveLibrarySnapshot {
        let store = try open()
        let recovery = try await store.recover()
        let rows = try await store.listRecordings().sorted { $0.importedAt > $1.importedAt }
        return ArchiveLibrarySnapshot(recordings: rows, recovery: recovery)
    }

    func importFile(_ source: URL, title: String? = nil) async throws -> ArchiveReceipt {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let staging = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        // The coordinator accessor must remain synchronous. Materialize a bounded local copy before
        // awaiting the archive actor, keeping the source's access scope open through the entire call.
        var coordinationError: NSError?
        var copied: Result<LocalRecording, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
            copied = Result {
                try RecordingFileImporter.copy(source: readableURL, to: staging, maximumBytes: Int(limits.maximumFileBytes))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let copied else { throw LocalArchiveError.coordinationFailed }
        let localCopy = try copied.get()
        let archive = try open()
        return try await archive.importFile(at: staging.appendingPathComponent(localCopy.storedFilename),
                                            title: Self.defaultTitle(title ?? source.deletingPathExtension().lastPathComponent))
    }

    func saveTranscript(recordingID: UUID, text: String, title: String) async throws -> NoteReceipt {
        try await open().exportTranscript(for: recordingID, text: text, title: title)
    }

    func verify(_ id: UUID) async throws -> ArchiveReceipt {
        let receipt = try await open().verifyRecording(id)
        for revision in receipt.recording.transcripts {
            _ = try verifiedNoteURL(receipt: receipt, revisionID: revision.id)
        }
        return receipt
    }

    func sourceForContainerInspection(_ identity: AudioInspectionIdentity) async throws -> AudioInspectionSource {
        let receipt = try await open().verifyRecording(identity.recordingID)
        guard AudioInspectionIdentity(receipt.recording) == identity else { throw AudioContainerHostError.sourceMismatch }
        return AudioInspectionSource(identity: identity, url: receipt.audioURL)
    }

    func prepareNoteShare(recordingID: UUID, revisionID: UUID) async throws -> URL {
        let receipt = try await open().verifyRecording(recordingID)
        return try verifiedNoteURL(receipt: receipt, revisionID: revisionID)
    }

    func preparePortableShare(recordingID: UUID, revisions: SnapshotRevisionSelection) async throws -> URL {
        guard !portableExportActive else { throw LocalArchiveError.busy }
        portableExportActive = true
        defer { portableExportActive = false }
        let store = try open()
        let receipt = try await store.verifyRecording(recordingID)
        let exports = receipt.audioURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PortableArchiveExportsV1",isDirectory:true)
        try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:true,
            attributes:[.posixPermissions:0o700,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        guard try exports.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw PortableArchiveError.invalidSnapshot }
        guard try FileManager.default.contentsOfDirectory(atPath:exports.path).count < 20 else { throw PortableArchiveError.capacity }
        let parent = exports.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,
            attributes:[.posixPermissions:0o700,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        let snapshot = try await store.exportSnapshot(recordingID:recordingID,revisions:revisions,toParentDirectory:parent)
        return try PortableArchiveZIP.create(snapshot)
    }

    private func exportCopies() -> PortableExportCopies {
        PortableExportCopies(parent: explicitRoot?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }
    func exportCopyCatalog() throws -> PortableExportCatalog {
        guard !portableExportActive else { throw LocalArchiveError.busy }
        return try exportCopies().catalog()
    }
    func moveExportCopy(_ id: UUID, toTrash: Bool) throws {
        guard !portableExportActive else { throw LocalArchiveError.busy }
        try exportCopies().move(id, toTrash: toTrash)
    }

    private func verifiedNoteURL(receipt: ArchiveReceipt, revisionID: UUID) throws -> URL {
        try Task.checkCancellation()
        guard let revision = receipt.recording.transcripts.first(where: { $0.id == revisionID }),
              let relative = receipt.recording.noteRelativePath(for: revision) else { throw LocalArchiveError.noteMissing }
        // The library has checked the pinned root location before providing this audio URL.
        let root = receipt.audioURL.deletingLastPathComponent().deletingLastPathComponent()
        let noteURL = root.appendingPathComponent(relative)
        let values = try noteURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == Int(revision.byteCount), revision.byteCount <= Int64(limits.maximumTranscriptBytes) * 8 + 8_192 else {
            throw LocalArchiveError.noteChanged
        }
        let input = try FileHandle(forReadingFrom: noteURL)
        defer { try? input.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= revision.byteCount else { throw LocalArchiveError.noteChanged }
            digest.update(data: chunk)
        }
        guard count == revision.byteCount,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == revision.noteSHA256 else { throw LocalArchiveError.noteChanged }
        return noteURL
    }

    #if DEBUG
    func importContainerFixture(_ fixture: ContainerSyntheticFixture) async throws -> ArchiveReceipt {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic-container-\(fixture.rawValue).ogg")
        try fixture.bytes().write(to: source, options: .withoutOverwriting)
        return try await importFile(source, title: fixture.title)
    }

    func importSyntheticFixture() async throws -> ArchiveReceipt {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Simulator-QA-not-valid-audio.wav")
        // Deliberately not decodable audio: the test proves copy/checksum, not recording or ASR.
        try Data(String(repeating: "SYNTHETIC BYTES; NOT VALID AUDIO.\n", count: 31).utf8).write(to: source, options: .withoutOverwriting)
        return try await importFile(source, title: "合成検証サンプル · 無効な音声")
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-archive-incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return directory
    }

    static func defaultTitle(_ value: String) -> String {
        let sanitized = value.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in sanitized {
            guard result.utf8.count + String(character).utf8.count <= 256 else { break }
            result.append(character)
        }
        return result.isEmpty ? "ローカル録音" : result
    }
}

@MainActor
final class LocalArchiveController: ObservableObject {
    @Published private(set) var recordings: [ArchivedRecording] = [] {
        didSet { audioInspection.reconcile(recordings: recordings, issues: verificationIssues) }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var activity = ""
    @Published private(set) var exportCopies = PortableExportCatalog()
    @Published private(set) var statusMessage: String?
    @Published private(set) var latestVerifications: [UUID: Date] = [:]
    @Published private(set) var verificationIssues: [UUID: String] = [:] {
        didSet { audioInspection.reconcile(recordings: recordings, issues: verificationIssues) }
    }
    let audioInspection: AudioContainerInspectionController
    @Published var errorMessage: String?
    let allowsTestFixture: Bool
    private let repository: LocalArchiveRepository

    init(rootDirectory: URL?, allowsTestFixture: Bool = false, limits: ArchiveLimits = ArchiveLimits()) {
        let repository = LocalArchiveRepository(rootDirectory: rootDirectory, limits: limits)
        self.repository = repository
        audioInspection = AudioContainerInspectionController { identity in try await repository.sourceForContainerInspection(identity) }
        self.allowsTestFixture = allowsTestFixture
        audioInspection.onIntegrityFailure = { [weak self] identity, error in
            self?.recordContainerIntegrityFailure(identity, error: error)
        }
    }

    func load() async {
        guard !isBusy else { return }
        await perform("ローカルアーカイブを読み取り中…") {
            let snapshot = try await self.repository.load()
            self.recordings = snapshot.recordings
            if snapshot.recovery.recoveredTransactions > 0 || snapshot.recovery.retainedUnjournaledFiles > 0 {
                self.statusMessage = "トランザクション \(snapshot.recovery.recoveredTransactions) 件を復旧しました。未登録の一時ファイル \(snapshot.recovery.retainedUnjournaledFiles) 件は保持し、自動削除はしていません。"
            }
        }
    }

    func loadExportCopies() async {
        guard !isBusy else { return }
        await perform("エクスポートコピーを読み取り中…") { self.exportCopies = try await self.repository.exportCopyCatalog() }
    }
    func moveExportCopy(_ id: UUID, toTrash: Bool) async {
        guard !isBusy else { return }
        await perform("エクスポートコピーを整理中…") {
            try await self.repository.moveExportCopy(id, toTrash: toTrash)
            self.exportCopies = try await self.repository.exportCopyCatalog()
            self.statusMessage = toTrash ? "本機の一時保管箱へ移動しました。復元できます。ファイルは削除しておらず、ディスク容量も解放されません。" : "エクスポートコピーを復元しました。他のファイルは上書きしていません。"
        }
    }

    @discardableResult func importFile(_ source: URL, title: String? = nil) async -> Bool {
        var imported = false
        await perform("ローカルファイルをコピーして検証中…") {
            self.accept(try await self.repository.importFile(source, title: title))
            self.recordings = try await self.repository.load().recordings
            imported = true
        }
        return imported
    }

    func verify(_ id: UUID) async -> URL? {
        var output: URL?
        await perform("音声と登録済みノートを再検証中…", recordingID: id) {
            self.latestVerifications.removeValue(forKey: id)
            let receipt = try await self.repository.verify(id)
            self.latestVerifications[id] = receipt.verifiedAt
            self.verificationIssues.removeValue(forKey: id)
            self.statusMessage = "音声と登録済みノートのバイト再確認が通りました。デコード・認識・アップロードはしていません。"
            output = receipt.audioURL
        }
        return output
    }

    func saveTranscript(recordingID: UUID, text: String, title: String) async -> NoteReceipt? {
        var output: NoteReceipt?
        await perform("ローカル Markdown リビジョンを保存中…", recordingID: recordingID) {
            self.latestVerifications.removeValue(forKey: recordingID)
            let receipt = try await self.repository.saveTranscript(recordingID: recordingID, text: text, title: title)
            self.recordings = try await self.repository.load().recordings
            self.statusMessage = receipt.reusedExistingRevision
                ? "同じテキストとタイトルのものが既にあるため、第 \(receipt.revision.number) 版を再利用しました。旧稿は上書きしていません。"
                : "第 \(receipt.revision.number) 版の Markdown を本機に保存しました。アップロードはしていません。"
            output = receipt
        }
        return output
    }

    func prepareNoteShare(recordingID: UUID, revisionID: UUID) async -> URL? {
        var output: URL?
        await perform("Markdown ファイルを確認中…", recordingID: recordingID) {
            self.latestVerifications.removeValue(forKey: recordingID)
            output = try await self.repository.prepareNoteShare(recordingID: recordingID, revisionID: revisionID)
        }
        return output
    }

    func preparePortableShare(recordingID: UUID, revisions: SnapshotRevisionSelection) async -> URL? {
        var output: URL?
        await perform("独立スナップショットを作成し ZIP を検証中…",recordingID:recordingID) {
            self.latestVerifications.removeValue(forKey:recordingID)
            output = try await self.repository.preparePortableShare(recordingID:recordingID,revisions:revisions)
            self.statusMessage = "ポータブル ZIP を項目ごとに展開して検証しました。音声と選択したリビジョンは同じパッケージ内です。アップロードはしていません。Obsidian のインデックスは未検証です。"
        }
        return output
    }

    func importTestFixture() async {
        #if DEBUG
        guard allowsTestFixture else { errorMessage = LocalArchiveError.fixtureUnavailable.localizedDescription; return }
        await perform("明示的にマークした合成サンプルをインポート中…") {
            self.accept(try await self.repository.importSyntheticFixture())
            self.recordings = try await self.repository.load().recordings
        }
        #endif
    }

    #if DEBUG
    func importContainerFixture(_ fixture: ContainerSyntheticFixture) async {
        guard allowsTestFixture else { errorMessage = LocalArchiveError.fixtureUnavailable.localizedDescription; return }
        await perform("合成コンテナバイトを作成してインポート中…") {
            self.accept(try await self.repository.importContainerFixture(fixture))
            self.recordings = try await self.repository.load().recordings
        }
    }
    #endif

    private func accept(_ receipt: ArchiveReceipt) {
        latestVerifications[receipt.recording.id] = receipt.verifiedAt
        statusMessage = receipt.reusedExistingContent ? "同じバイト列を検出したため、元のアーカイブを再利用しました。元のソースと項目は変更していません。" : "本機コピーをコピーして検証しました。デコード・認識・アップロードはしていません。"
    }

    private func recordContainerIntegrityFailure(_ identity: AudioInspectionIdentity, error: Error) {
        guard let current = recordings.first(where: { $0.id == identity.recordingID }),
              AudioInspectionIdentity(current) == identity, Self.isIntegrityFailure(error) else { return }
        latestVerifications.removeValue(forKey: identity.recordingID)
        verificationIssues[identity.recordingID] = Self.describe(error)
    }

    private func perform(_ activity: String, recordingID: UUID? = nil, operation: () async throws -> Void) async {
        guard !isBusy else { errorMessage = LocalArchiveError.busy.localizedDescription; return }
        isBusy = true; self.activity = activity; errorMessage = nil; statusMessage = nil
        defer { isBusy = false; self.activity = "" }
        do { try await operation() }
        catch {
            if let recordingID, Self.isIntegrityFailure(error) {
                verificationIssues[recordingID] = Self.describe(error)
                latestVerifications.removeValue(forKey: recordingID)
            }
            errorMessage = Self.describe(error) + "\nこの App はソースファイルを変更も削除もしていません。送信済みの復旧ログは次回の更新時に完了する場合があります。失敗時のロールバックは保証しません。"
        }
    }

    private static func isIntegrityFailure(_ error: Error) -> Bool {
        if let value = error as? AudioContainerHostError {
            switch value {
            case .fileChanged, .sourceMismatch, .unreadable: return true
            case .tooLarge: return false
            }
        }
        if let value = error as? ArchiveError {
            switch value {
            case .archivedContentChanged, .destinationConflict, .archiveLocationChanged, .missingRecoveryData,
                 .invalidManifest, .invalidJournal, .recordingNotFound, .io: return true
            default: return false
            }
        }
        if let value = error as? LocalArchiveError {
            switch value {
            case .noteChanged, .noteMissing: return true
            default: return false
            }
        }
        return (error as NSError).domain == NSCocoaErrorDomain
    }

    static func describe(_ error: Error) -> String {
        guard let archiveError = error as? ArchiveError else { return error.localizedDescription }
        switch archiveError {
        case .emptySource: return "選択したファイルが空です。"
        case .fileSizeLimitExceeded: return "音声がローカルアーカイブのサイズ上限（デフォルト 512 MiB）を超えています。"
        case .unsupportedFileType, .invalidFileURL: return "書き込みが完了した通常のローカルファイルを選んでください。"
        case .sourceChangedDuringCopy: return "コピー中にソースが変化しました。録音の書き込みが終わってから再試行してください。"
        case .invalidTitle: return "タイトルは UTF-8 で1〜256バイトの1行テキストにしてください。"
        case .invalidTranscript: return "空でないテキストを指定してください。改行とタブ以外の制御文字は使えません。"
        case .transcriptSizeLimitExceeded: return "テキストが 1 MiB を超えています。分割して整理してから再試行してください。"
        case .recordingLimitExceeded, .revisionLimitExceeded, .manifestSizeLimitExceeded: return "アーカイブ容量またはリビジョン数の上限に達しました。元の資料は保持されています。"
        case .archivedContentChanged, .destinationConflict: return "保存済みファイルがアーカイブ記録と一致しないか競合しています。操作を停止しました。元のファイルは上書きしていません。"
        case .archiveBusy: return "アーカイブディレクトリが別の操作で使用中です。しばらくしてから更新してください。"
        case .archiveLocationChanged: return "アーカイブディレクトリが移動または置換されました。操作を停止しました。元のディレクトリに戻してから再試行してください。"
        case .recordingNotFound: return "その録音は現在のアーカイブ記録にありません。更新してください。"
        case .invalidManifest, .invalidJournal, .missingRecoveryData: return "アーカイブ記録または復旧データの確認が必要です。既存のファイルは保持し、自動修復での上書きはしていません。"
        case .invalidLimits, .targetDirectoryRequired: return "ローカルアーカイブのディレクトリまたは容量設定が無効です。"
        case .io: return "本機のファイル操作に失敗しました。空き容量、デバイスのロック解除状態、ファイル権限を確認してください。"
        }
    }
}
