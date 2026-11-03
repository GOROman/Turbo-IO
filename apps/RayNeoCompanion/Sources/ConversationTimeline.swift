import Foundation
import Combine

struct ConversationTurn: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var updatedAt: Date
    var question = ""
    var answer = ""
    var finalQuestion = false
    var outcome = "進行中"
}

struct ConversationEvent: Codable {
    enum Kind: String, Codable { case transcript, answerDelta, completed, interrupted }
    var id: UUID
    var date = Date()
    var kind: Kind
    var text = ""
    var final = false
}

enum TimelineReplay {
    static func apply(_ event: ConversationEvent, to turns: inout [ConversationTurn]) {
        if !turns.contains(where: { $0.id == event.id }) {
            turns.append(ConversationTurn(id: event.id, startedAt: event.date, updatedAt: event.date))
        }
        guard let index = turns.firstIndex(where: { $0.id == event.id }) else { return }
        turns[index].updatedAt = event.date
        switch event.kind {
        case .transcript:
            guard !turns[index].finalQuestion else { return }
            turns[index].question = event.text; turns[index].finalQuestion = event.final
        case .answerDelta: turns[index].answer += event.text
        case .completed: turns[index].outcome = "モデル完了"
        case .interrupted:
            if turns[index].outcome != "モデル完了" { turns[index].outcome = "中断／終了" }
        }
    }
    static func decode(_ data: Data) throws -> [ConversationTurn] {
        guard data.count <= 64 * 1_024 * 1_024 else { throw BookImportError.limit }
        var turns: [ConversationTurn] = []
        let rows = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, row) in rows.enumerated() where !row.isEmpty {
            guard row.count <= 65_536 else { throw BookImportError.limit }
            do { apply(try JSONDecoder().decode(ConversationEvent.self, from: Data(row)), to: &turns) }
            catch { if index == rows.count - 1 && data.last != 10 { break }; throw error }
        }
        for index in turns.indices where turns[index].outcome == "進行中" { turns[index].outcome = "前回未完了" }
        return turns
    }
    static func markdown(_ turns: [ConversationTurn]) -> String {
        let formatter = ISO8601DateFormatter()
        func literal(_ text: String) -> String {
            let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return fence + "text\n" + text + "\n" + fence
        }
        return "# Turbo IO 会話タイムライン\n\n> このアプリの会話のみを含みます。時刻はデバイスの記録時刻です。モデルの完了はレンズ表示の検証を意味しません。\n\n" + turns.sorted { $0.startedAt < $1.startedAt }.map {
            "## \(formatter.string(from: $0.startedAt))\n\nステータス：\($0.outcome)\n\n### 私\n\n\(literal($0.question))\n\n### AI\n\n\(literal($0.answer))\n"
        }.joined(separator: "\n")
    }
}

/// One serial disk queue preserves callback order. No network, audio, or keys.
final class TimelineJournal {
    let directory: URL
    private let queue = DispatchQueue(label: "companion.timeline.disk", qos: .utility)
    private var blocked = false
    init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("events.jsonl") }
    func load(_ completion: @escaping (Result<[ConversationTurn], Error>) -> Void) {
        queue.async {
            let result = Result { () -> [ConversationTurn] in
                guard FileManager.default.fileExists(atPath: self.file.path) else { return [] }
                let values = try self.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1_024 * 1_024 else { throw BookImportError.limit }
                let data = try Data(contentsOf: self.file)
                // A torn last line is readable, but never append to it. Preserve
                // the original journal and require explicit recovery, no truncation.
                if !data.isEmpty && data.last != 10 { self.blocked = true }
                return try TimelineReplay.decode(data)
            }
            if case .failure = result { self.blocked = true }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func append(_ event: ConversationEvent, completion: @escaping (Bool) -> Void) {
        queue.async {
            do {
                guard !self.blocked else { throw BookImportError.invalid }
                var data = try JSONEncoder().encode(event); data.append(10)
                guard data.count <= 65_536 else { throw BookImportError.limit }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                if !FileManager.default.fileExists(atPath: self.file.path) {
                    try Data().write(to: self.file, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
                }
                let handle = try FileHandle(forWritingTo: self.file); defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard size + UInt64(data.count) <= 64 * 1_024 * 1_024 else { throw BookImportError.limit }
                try handle.write(contentsOf: data); try handle.synchronize()
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.blocked = true
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
}

@MainActor final class ConversationTimeline: ObservableObject {
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var storageError: String?
    private let journal: TimelineJournal
    private var loaded = false
    private var pending: [ConversationEvent] = []
    init(root: URL? = nil) {
        journal = TimelineJournal(directory: root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ConversationTimelineV1"))
        journal.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(var turns):
                for event in self.pending { TimelineReplay.apply(event, to: &turns) }
                self.turns = turns
            case .failure: self.storageError = "履歴の読み込みに失敗しました。元のファイルは保持します。新しい内容は画面に一時的に残るので、早めにエクスポートしてください。"
            }
            self.loaded = true; self.pending = []
        }
    }
    func record(_ event: ConversationEvent) {
        if !loaded { pending.append(event) }
        TimelineReplay.apply(event, to: &turns)
        journal.append(event) { [weak self] success in
            if !success { self?.storageError = "会話をローカルへ完全に書き込めませんでした。現在のタイムラインをエクスポートしてください。ストレージ不足、ファイル破損、または 64 MiB 上限到達の可能性があります。古い記録は削除していません。" }
        }
    }
    func export() async throws -> URL {
        let text = TimelineReplay.markdown(turns)
        let directory = journal.directory.appendingPathComponent("Exports")
        return try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Turbo IO会話-\(UUID().uuidString).md")
            try Data(text.utf8).write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        }.value
    }
}
