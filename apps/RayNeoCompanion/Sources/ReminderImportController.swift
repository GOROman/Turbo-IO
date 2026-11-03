import Foundation
import Combine

@MainActor final class ReminderImportController: ObservableObject {
    @Published private(set) var lists: [SystemReminderList] = []
    @Published private(set) var rows: [SystemReminderSnapshot] = []
    @Published private(set) var busy = false
    @Published private(set) var activeList: String?
    @Published private(set) var status = "システムのリマインダーはまだ読み込んでいません"
    @Published private(set) var error: String?
    @Published private(set) var selected: Set<String> = []
    let isFixture: Bool
    private let reader: SystemReminderReading
    private var generation = UUID()

    init(reader: SystemReminderReading, isFixture: Bool = false) { self.reader = reader; self.isFixture = isFixture }
    static func forCurrentLaunch() -> ReminderImportController {
        #if DEBUG && !COMPANION_DEVICE
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-reminders-fixture"), let index = args.firstIndex(of: "--ui-test-scope"),
           args.indices.contains(index + 1), UUID(uuidString: args[index + 1]) != nil {
            return ReminderImportController(reader: FixtureReminderReader(), isFixture: true)
        }
        #endif
        return ReminderImportController(reader: EventKitReminderReader())
    }
    private func begin() -> UUID {
        cancel(); generation = UUID(); busy = true; error = nil
        return generation
    }
    func loadLists() async {
        let token = begin(); lists = []; activeList = nil
        status = "許可を待ってリスト名を読み込み中…"
        defer { if generation == token { busy = false } }
        do {
            try await reader.requestAccess()
            guard generation == token, !Task.isCancelled else { return }
            lists = try reader.lists()
            status = lists.isEmpty ? "読み込めるシステムリストがありません" : "リストを1つ選んでから項目を読み込んでください"
        } catch { if generation == token { fail(error) } }
    }
    func loadReminders(listID: String) async {
        let token = begin(); activeList = listID
        status = "選択したリストを読み込み中…"
        defer { if generation == token { busy = false } }
        do {
            guard lists.contains(where: { $0.id == listID }) else { throw SystemReminderError.unavailable }
            guard reader.canRead else { throw SystemReminderError.denied }
            let result = try await reader.reminders(in: listID)
            guard generation == token, !Task.isCancelled else { return }
            guard reader.canRead else { throw SystemReminderError.denied }
            guard result.count <= 500 else { throw SystemReminderError.limit }
            guard Set(result.map(\.id)).count == result.count else { throw SystemReminderError.selection }
            rows = result.sorted { lhs, rhs in
                if lhs.completed != rhs.completed { return !lhs.completed }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            status = "\(rows.count) 件のスナップショットを読み込みました。チェックしたものだけをインポートし、継続同期はしません"
        } catch { if generation == token { fail(error) } }
    }
    func toggle(_ id: String) {
        guard !busy, rows.contains(where: { $0.id == id }) else { return }
        if selected.contains(id) { selected.remove(id) }
        else if selected.count < 100 { selected.insert(id) }
        else { error = SystemReminderError.limit.localizedDescription }
    }
    func clearSelection() { selected = [] }
    func importSelected(into store: CompanionStore) {
        guard !busy else { return }
        do {
            guard reader.canRead else { throw SystemReminderError.denied }
            let report = try store.importSystemReminders(rows, selectedIDs: selected)
            selected = []; error = nil
            status = "\(report.imported) 件をインポートし、インポート済みの \(report.skipped) 件をスキップしました。保存先はTurbo IOのみです"
        } catch { fail(error) }
    }
    func cancel() {
        generation = UUID(); reader.cancel(); busy = false
        rows = []; selected = []
    }
    func discardPreview() {
        cancel(); lists = []; activeList = nil; error = nil
        status = "読み込みプレビューを消去しました。Turbo IOにインポート済みのローカルToDoには影響しません"
    }
    private func fail(_ failure: Error) {
        rows = []; selected = []
        if case SystemReminderError.denied = failure { lists = []; activeList = nil }
        error = (failure as? SystemReminderError)?.localizedDescription ?? SystemReminderError.failed.localizedDescription
        status = "システムのリマインダーはインポートも変更もしていません"
    }
}

#if DEBUG && !COMPANION_DEVICE
@MainActor private final class FixtureReminderReader: SystemReminderReading {
    var canRead = true
    func requestAccess() async throws {}
    func lists() throws -> [SystemReminderList] { [SystemReminderList(id: "synthetic-list", title: "合成リスト · システムデータは読みません")] }
    func reminders(in listID: String) async throws -> [SystemReminderSnapshot] {
        [SystemReminderSnapshot(id: "synthetic-reminder", title: "合成システムToDo · インポートテスト", completed: false,
            dueComponents: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 9))]
    }
    func cancel() {}
}
#endif
