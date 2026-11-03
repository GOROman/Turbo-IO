import Foundation

/// Local bookkeeping only. These versions and observation times are never wire timestamps/ACKs.
struct TodoDelivery: Codable, Equatable {
    struct Observation: Codable, Equatable {
        var completed: Bool
        var important: Bool?
    }
    var revision = UUID()
    var pending = true
    var submittedRevision: UUID?
    var submittedAt: Date?
    var conflict: Observation?

    mutating func edited() { revision = UUID(); pending = true }
}

enum TodoDeliveryError: LocalizedError {
    case differentDevice, conflict, missing
    var errorDescription: String? {
        switch self {
        case .differentDevice: return "リストに別のグラスに紐づいたToDoが含まれているため、どの項目も送信しませんでした。グラス間の移行は未対応です。"
        case .conflict: return "まず「送信待ちと競合」の画面で状態の競合を確認してください。今回は送信を続けませんでした。"
        case .missing: return "ToDoが削除されたかバージョンが変わっています。確認してから送信してください。"
        }
    }
}

extension LocalTodo {
    var deliveryDescription: String {
        if delivery?.conflict != nil { return "状態が競合 · ローカルの変更は保持済み" }
        guard wireID != nil else { return completed ? "このデバイスで完了 · 未同期" : "スマホにのみ保存" }
        if delivery?.pending == true { return "送信待ち · ローカルの変更は保存済み" }
        if delivery?.submittedAt != nil { return "送信済み · 項目ごとの確認はなし" }
        return "グラスに紐づき済み · 報告が正"
    }
}
