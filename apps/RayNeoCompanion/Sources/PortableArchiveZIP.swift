import Foundation
import CryptoKit
import ZIPFoundation
import RayNeoArchive
import Darwin

enum PortableArchiveError: LocalizedError {
    case invalidSnapshot, changed, capacity
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "エクスポート用スナップショットの構造が要件を満たさないため、ZIP は公開していません。"
        case .changed: return "スナップショットまたは ZIP の内容再確認に失敗しました。元のアーカイブは保持し、共有ファイルは公開していません。"
        case .capacity: return "ローカルのエクスポートフォルダが上限の 20 回に達しています。ZIP エクスポートコピーのページで整理してください。古いパッケージは自動削除しません。"
        }
    }
}

/// Runs on the repository actor. Uses a verified independent snapshot, never zips the live archive root.
enum PortableArchiveZIP {
    struct Expected { let path: String; let size: Int64; let hash: String }
    static func create(_ snapshot: ArchiveSnapshotReceipt) throws -> URL {
        guard snapshot.manifest.schemaVersion == 1, snapshot.manifest.files.count <= 101,
              snapshot.totalByteCount > 0, snapshot.totalByteCount <= 1_073_741_824 else { throw PortableArchiveError.invalidSnapshot }
        let base = snapshot.directoryURL
        let folder = "RayNeo-" + snapshot.snapshotID.uuidString.lowercased()
        let partial = base.deletingLastPathComponent().appendingPathComponent(folder + ".zip.partial")
        let output = base.deletingLastPathComponent().appendingPathComponent(folder + ".zip")
        guard !FileManager.default.fileExists(atPath:partial.path), !FileManager.default.fileExists(atPath:output.path) else { throw PortableArchiveError.invalidSnapshot }
        var expected = snapshot.manifest.files.map { Expected(path:$0.relativePath,size:$0.byteCount,hash:$0.sha256) }
        let metadataSize = try snapshot.manifestURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        expected.append(Expected(path:"snapshot-manifest.json",size:Int64(metadataSize),hash:snapshot.manifestSHA256))
        guard expected.allSatisfy({ validPath($0.path) && $0.size > 0 }), Set(expected.map(\.path)).count == expected.count else { throw PortableArchiveError.invalidSnapshot }
        // Unique private path is retained on failure for inspection, never offered to the share sheet.
        try write(partial,base:base,folder:folder,expected:expected)
        let verifiedEntries = expected + [Expected(path:"README.md",size:Int64(readme.count),hash:hex(SHA256.hash(data:readme)))]
        try verify(partial,folder:folder,expected:verifiedEntries)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:partial,to:output) // Exclusive destination, no replacement.
        return output
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator:"/",omittingEmptySubsequences:false)
        return !path.isEmpty && path.utf8.count <= 512 && !path.contains("\\") && !path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func write(_ url: URL, base: URL, folder: String, expected: [Expected]) throws {
        let zip = try ZIPFoundation.Archive(url:url,accessMode:.create)
        try FileManager.default.setAttributes([.posixPermissions:0o600,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
        for item in expected {
            try Task.checkCancellation()
            let source = base.appendingPathComponent(item.path)
            let fd = open(source.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
            guard fd >= 0 else { throw PortableArchiveError.changed }
            let input = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer { try? input.close() }
            var st = stat()
            guard fstat(fd,&st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size == item.size else { throw PortableArchiveError.changed }
            var hash = SHA256(), consumed: Int64 = 0
            try zip.addEntry(with:folder + "/" + item.path,type:.file,uncompressedSize:item.size,permissions:0o600,
                             compressionMethod:.none,bufferSize:65_536) { position,size in
                try Task.checkCancellation()
                guard position == consumed, size <= 65_536, Int64(size) <= item.size - consumed else { throw PortableArchiveError.changed }
                let chunk = try input.read(upToCount:size) ?? Data()
                guard chunk.count == size else { throw PortableArchiveError.changed }
                hash.update(data:chunk); consumed += Int64(chunk.count)
                return chunk
            }
            guard consumed == item.size, hex(hash.finalize()) == item.hash else { throw PortableArchiveError.changed }
        }
        try zip.addEntry(with:folder + "/README.md",type:.file,uncompressedSize:Int64(readme.count),permissions:0o600) { position,size in
            try Task.checkCancellation(); return readme.subdata(in:Int(position)..<(Int(position)+size))
        }
    }
    private static let readme = Data("""
        # Turbo IO ポータブルアーカイブ

        解凍後、RayNeo フォルダ全体を Obsidian ボルトにコピーし、notes/ と audio/ を同じ階層に保ってください。
        Markdown 内の ../audio/ リンクには対応する音声が必要です。ノートだけをコピーしないでください。
        snapshot-manifest.json には選択した項目の長さと SHA-256 が記載されており、NAS で独立に再確認できます。
        このパッケージには明示的に選択した録音と修正のみが含まれます。他の会話、キー、デバイスのバインド、リアルタイム録音キャッシュは含まれません。
        パッケージの検証は、音声がデコード可能、無線でロスがない、文字が正確、サーバーが受信済み、Obsidian が索引済み、を意味しません。
        この操作では通信、自動認識、元の削除は行いません。コピー先デバイスでファイルを確認してから、コピーをご自身で整理してください。
        """.utf8)
    static func verify(_ url: URL, folder: String, expected: [Expected]) throws {
        let zip = try ZIPFoundation.Archive(url:url,accessMode:.read)
        let names = zip.map(\.path)
        let required = Set(expected.map { folder + "/" + $0.path })
        guard Set(names) == required, names.count == required.count else { throw PortableArchiveError.changed }
        for item in expected {
            try Task.checkCancellation()
            guard let entry = zip[folder + "/" + item.path], entry.type == .file, entry.uncompressedSize == item.size else { throw PortableArchiveError.changed }
            var count: Int64 = 0, hash = SHA256()
            let crc = try zip.extract(entry,bufferSize:65_536) { chunk in
                try Task.checkCancellation()
                guard count <= item.size - Int64(chunk.count) else { throw PortableArchiveError.changed }
                count += Int64(chunk.count); hash.update(data:chunk)
            }
            guard crc == entry.checksum, count == item.size, hex(hash.finalize()) == item.hash else { throw PortableArchiveError.changed }
        }
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format:"%02x",$0) }.joined() }
}
