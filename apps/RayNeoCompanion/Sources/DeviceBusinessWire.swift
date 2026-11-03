import Foundation
import CoreFoundation
import RayNeoProtocol

/// Version-pinned business envelope. Never a transport frame or authentication API.
struct DeviceBusinessWire {
    let type: UInt32
    let json: [String: Any]
    let bytes: Data
    static func encode(type: UInt32, json: [String: Any], bytes: Data = Data()) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        guard body.count <= 65_536, bytes.count <= 65_536 else { throw DeviceFeatureError.invalidPacket }
        var out = Data([8, 1, 16]); put(UInt64(type), into: &out)
        out.append(26); put(UInt64(body.count), into: &out); out.append(body)
        if !bytes.isEmpty { out.append(34); put(UInt64(bytes.count), into: &out); out.append(bytes) }
        return out
    }
    init(_ packet: Data) throws {
        let meta = try BusinessEnvelopeMetadata.inspect(packet)
        guard meta.version == 1, let type = meta.messageType,
              (meta.messageBytes ?? 0) <= 65_536, (meta.dataBytes ?? 0) <= 65_536 else { throw DeviceFeatureError.invalidPacket }
        self.type = type
        let a = [UInt8](packet); var i = 0; var body = Data(); var audio = Data()
        func read() -> UInt64 {
            var n: UInt64 = 0, shift = 0
            while i < a.count { let b = a[i]; i += 1; n |= UInt64(b & 127) << shift; if b < 128 { break }; shift += 7 }
            return n
        }
        // inspect above has already checked every varint, range and singular tag.
        while i < a.count {
            let key = read()
            switch key & 7 {
            case 0: _ = read()
            case 1: i += 8
            case 5: i += 4
            default:
                let n = Int(read()); let data = Data(a[i..<(i+n)]); i += n
                if key >> 3 == 3 { body = data }; if key >> 3 == 4 { audio = data }
            }
        }
        if body.isEmpty { json = [:] }
        else {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw DeviceFeatureError.invalidPacket }
            json = object
        }
        bytes = audio
    }
    private static func put(_ value: UInt64, into data: inout Data) {
        var n = value
        while n >= 128 { data.append(UInt8(n & 127) | 128); n >>= 7 }; data.append(UInt8(n))
    }
    static func integer(_ json: [String: Any], _ key: String) -> Int64? {
        guard let n = json[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded(.towardZero) == n.doubleValue,
              n.doubleValue >= -9_007_199_254_740_991, n.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return n.int64Value
    }
    static func identifier(_ json: [String: Any], _ key: String) -> String? {
        guard let s = json[key] as? String, !s.isEmpty, s.utf8.count <= 128,
              s.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }; return s
    }
    static func boolean(_ json: [String:Any], _ key: String) -> Bool? {
        guard let n = json[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}

enum DeviceFeatureError: LocalizedError {
    case invalidPacket, disconnected, busy, noSession, incomplete, conflictingBytes, storageLimit, unsupportedFile
    var errorDescription: String? {
        switch self {
        case .invalidPacket: return "プロトコルのフィールドが無効なため、送信も適用もしていません。"
        case .disconnected: return "認証済みのグラスへの単一接続が必要です。シミュレータはパケットを送信しません。"
        case .busy: return "先に音声会話または現在のグラスのタスクを終了してください。"
        case .noSession: return "一致するローカルタスクがありません。他のデバイスの内容は変更していません。"
        case .incomplete: return "録音の完了メッセージがないか、データに欠落があります。元のファイルは保持し、完全とはマークしません。"
        case .conflictingBytes: return "同じ録音位置で異なるバイトを受信したため、パッケージ化を停止し、元のファイルを保持しました。"
        case .storageLimit: return "ローカルの受信上限を超えたため、新規受信を停止しました。グラス側のファイルは削除していません。"
        case .unsupportedFile: return "音声パッケージの形式が検証を通りませんでした。元のファイルを保持し、見かけだけの音声は生成しません。"
        }
    }
}
