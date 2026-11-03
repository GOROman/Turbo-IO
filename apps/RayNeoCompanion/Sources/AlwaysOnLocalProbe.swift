import Foundation
import Combine
import UIKit
import SwiftUI

/// Experimental iOS 1.0.2 LifeLog commands. Not the ordinary recording protocol.
enum AlwaysOnWire {
    static func launcher(_ command: String, enabled: Bool) throws -> Data {
        guard ["life_log_guide", "life_log_switch"].contains(command) else { throw DeviceFeatureError.invalidPacket }
        return try DeviceBusinessWire.encode(type: 20, json: ["cmd": command,
            "payload": ["value": enabled ? 1 : 0, "mode": 0,
                        "data": command == "life_log_switch" && enabled ? "{\"delay\":2}" : ""]])
    }
    static func start(_ id: String) throws -> Data {
        guard DeviceBusinessWire.identifier(["taskId": id], "taskId") != nil else { throw DeviceFeatureError.invalidPacket }
        return try DeviceBusinessWire.encode(type: 162, json: ["taskId": id, "idleTimeoutSec": 30])
    }
    static func exit() throws -> Data { try DeviceBusinessWire.encode(type: 166, json: ["rc": 2]) }
    static func page(_ visible: Bool) throws -> Data { try DeviceBusinessWire.encode(type: 168, json: ["inRealtimePage": visible]) }
    static func batchSummary(_ wire: DeviceBusinessWire) -> (frames: Int, unusedBytes: Int) {
        let keys = ["frameCount", "mode", "vpuMask", "vadMask"]
        guard keys.contains(where: { wire.json[$0] != nil }) else { return (wire.bytes.isEmpty ? 0 : 1, 0) }
        let available = wire.bytes.count / 240
        let declared = DeviceBusinessWire.integer(wire.json, "frameCount") ?? Int64(available)
        let frames = Int(min(31, min(Int64(available), max(0, declared))))
        return (frames, wire.bytes.count - frames * 240)
    }
}

/// Small bounded diagnostic capture: original length-prefixed envelopes, not a playable .opus claim.
@MainActor final class AlwaysOnLocalProbe: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var pendingStop: Bool
    @Published private(set) var status = "未開始。録音もアップロードもしません"
    @Published private(set) var packetCount = 0
    @Published private(set) var audioBytes = 0
    @Published private(set) var receivedPackets = 0
    @Published private(set) var receivedAudioBytes = 0
    @Published private(set) var droppedPackets = 0
    @Published private(set) var droppedAudioBytes = 0
    @Published private(set) var tailPackets = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var unusedBytes = 0
    @Published private(set) var remaining = 0
    @Published private(set) var events: [String] = []
    @Published private(set) var directory: URL?
    @Published private(set) var error: String?
    @Published private(set) var stopResultAcknowledged = false
    private let defaults: UserDefaults
    private let root: URL
    private let device: () -> String?
    private let available: () -> Bool
    private let send: (UInt8, Data) throws -> Void
    private let suspendVoice: () -> Void
    private let now: () -> TimeInterval
    private let scheduleTimers: Bool
    private var target: String?
    private var taskID = ""
    private var a2Sent = false
    private var offObserved = false
    private var stopAt: TimeInterval?
    private var lastStopRequest: TimeInterval?
    private var deadline: TimeInterval = 0
    private var acceptingAudio = false
    private var dropReasons: [String: Int] = [:]
    private func dropReasonLabel(_ reason: String) -> String {
        switch reason {
        case "保存失败": return "保存に失敗"
        case "接收已结束或异常中止": return "受信が終了したか異常終了"
        case "超过接收截止": return "受信期限を超過"
        case "未应答A2": return "A2への応答なし"
        case "缺少有效taskId": return "有効なtaskIdがありません"
        case "其他taskId": return "別のtaskId"
        default: return reason
        }
    }
    private var saveDeadline: TimeInterval { min(deadline + 5, stopAt.map { $0 + 5 } ?? deadline + 5) }
    private var lastAudio: TimeInterval = 0
    private var file: FileHandle?
    private var storedBytes = 0
    private var timer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let pendingKey = "companion.alwaysOn.localProbe.pendingDevice"
    var occupied: Bool { active || pendingStop }
    var canStart: Bool { device() != nil && available() && !occupied }
    var canConfirmPhysicalStop: Bool {
        pendingStop && !active && stopResultAcknowledged && target != nil && device() == target
    }
    init(defaults: UserDefaults, root: URL, device: @escaping () -> String?, available: @escaping () -> Bool,
         suspendVoice: @escaping () -> Void, send: @escaping (UInt8, Data) throws -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, scheduleTimers: Bool = true) {
        self.defaults = defaults; self.root = root; self.device = device; self.available = available
        self.suspendVoice = suspendVoice; self.send = send
        self.now = now; self.scheduleTimers = scheduleTimers
        target = defaults.string(forKey: pendingKey); pendingStop = target != nil
        if pendingStop { status = "前回の停止が未確認です。同じグラスを再接続し、停止の再送を押してください。自動では開始しません。" }
    }
    private func note(_ text: String) {
        events.append("\(Date().formatted(date: .omitted, time: .standard)) \(text)")
        events = Array(events.suffix(80))
    }
    func start() {
        guard canStart, let id = device() else { error = "グラスを接続し、音声、通常録音、プロンプターを終了してください。未確認の停止を先に処理してください。"; return }
        do {
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let path = dir.appendingPathComponent("envelopes.rnp")
            try Data().write(to: path, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            file = try FileHandle(forWritingTo: path); directory = dir
        } catch { self.error = "この端末のファイルを用意できず、開始しませんでした。"; return }
        suspendVoice()
        target = id; taskID = UUID().uuidString; a2Sent = false; offObserved = false; stopAt = nil
        lastStopRequest = nil; stopResultAcknowledged = false
        packetCount = 0; audioBytes = 0; frameCount = 0; unusedBytes = 0; storedBytes = 0; events = []; error = nil
        receivedPackets = 0; receivedAudioBytes = 0; droppedPackets = 0; droppedAudioBytes = 0; tailPackets = 0
        dropReasons = [:]; acceptingAudio = true
        active = true; pendingStop = true; defaults.set(id, forKey: pendingKey)
        deadline = now() + 25; lastAudio = 0; remaining = 25
        if scheduleTimers {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LifeLogBoundedStop") { [weak self] in
            Task { @MainActor in self?.stop(reason: "バックグラウンド実行時間の終了"); self?.finishCapture() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        }
        do {
            try send(15, AlwaysOnWire.launcher("life_log_guide", enabled: true)); note("設定の準備を送信（録音開始の受信確認ではありません）")
            try send(15, AlwaysOnWire.launcher("life_log_switch", enabled: true)); note("終日記録スイッチ ON を送信")
            status = "グラスのスイッチ返信 / A1 を待機中。25秒で停止を依頼し、30秒以内に今回分の残りパケットを受け取ります"
        } catch { acceptingAudio = false; self.error = "開始の送信に失敗しました。停止は試みます。"; stop(reason: "開始失敗") }
    }
    func stop(reason: String = "手動停止") {
        guard pendingStop || active else { return }
        if stopAt == nil { stopAt = now(); note("停止：\(reason)") }
        remaining = active ? max(0, Int(ceil(saveDeadline - now()))) : 0
        status = "停止を依頼済み。制限時間内に今回分の残りパケットを受け取り、オフの返信を待ちます"
        stopResultAcknowledged = false; lastStopRequest = nil
        guard let target, device() == target else { status = "接続が切れ、停止は未確認です。同じグラスを再接続してから停止を再送してください"; return }
        lastStopRequest = now()
        // Attempt each stop independently: an A6 failure must not suppress switch OFF.
        for (business, packet) in [(UInt8(13), try? AlwaysOnWire.exit()), (15, try? AlwaysOnWire.launcher("life_log_switch", enabled: false)),
                                   (15, try? AlwaysOnWire.launcher("life_log_guide", enabled: false))] {
            do { if let packet { try send(business, packet) } } catch { self.error = "一部の停止コマンドを送信できませんでした。グラスが停止したとは断定できません。" }
        }
        if !active { status = "停止を再送しました。グラスのオフ状態を待機中です。再録音はしていません" }
    }
    func connectionChanged() {
        if device() != target { acceptingAudio = false; stopResultAcknowledged = false; lastStopRequest = nil }
        if active, device() != target { stop(reason: "接続先の変更") }
    }
    /// Explicit lens inspection, not a protocol-confirmed OFF claim. No recording or packet send.
    func confirmPhysicalStop() {
        guard canConfirmPhysicalStop else { return }
        let report: [String: Any] = ["confirmedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "user-observed-glasses-off-after-stop-result", "protocolOffObserved": offObserved,
            "stopResultAcknowledged": true, "events": events]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("stop-confirmation-\(UUID().uuidString).json"),
                           options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "手動の停止確認を保存できず、処理待ちの状態を保持します。"; return }
        pendingStop = false; defaults.removeObject(forKey: pendingKey)
        status = "ユーザーがグラスのオフを確認しました。今回は終了です（プロトコルの OFF 状態は未受信）"
        note(status)
    }
    func lostMessages() {
        guard active else { return }; acceptingAudio = false
        error = "受信キューでパケットが欠落しました。元のパケットは保持しますが、完全とは記録できません。"; stop(reason: "受信が不完全")
    }
    func receive(device id: String, business: UInt8, packet: Data) {
        guard target == id, device() == id, active || pendingStop else { return }
        do {
            let wire = try DeviceBusinessWire(packet)
            if business == 15 {
                guard let cmd = wire.json["cmd"] as? String, cmd.hasPrefix("life_log_"),
                      let p = wire.json["payload"] as? [String: Any] else { return }
                let value = DeviceBusinessWire.integer(p, "value")
                note("\(cmd) value=\(value.map(String.init) ?? "なし") mode=\(DeviceBusinessWire.integer(p, "mode").map(String.init) ?? "なし")")
                if cmd == "life_log_switch_result", value == 0,
                   let request = lastStopRequest, now() - request >= 0, now() - request <= 10 {
                    stopResultAcknowledged = true
                    if !active { status = "スイッチ成功の受信確認が届きました。グラスがオフになったか目視で確認してから、終了を確定してください" }
                }
                if cmd == "life_log_switch", value == 0, stopAt != nil {
                    offObserved = true
                    if !active { pendingStop = false; defaults.removeObject(forKey: pendingKey); status = "オフ状態を受信しました。再録音はしていません" }
                }
                if cmd == "life_log_switch_result", let value, value != 0, stopAt == nil {
                    error = [1: "グラスにマイクの権限がありません", 2: "テンプル（つる）を開いてください", 3: "グラスの電池が残りわずかです"][Int(value)] ?? "グラスが終日記録スイッチを拒否しました。結果コード \(value)"
                    stop(reason: "グラスが拒否")
                }
                return
            }
            guard business == 13, (161...168).contains(wire.type) else { return }
            if wire.type == 161 {
                note("A1 ウェイクアップを受信")
                guard active, stopAt == nil, !a2Sent, now() < deadline else { return }
                a2Sent = true
                try send(13, AlwaysOnWire.start(taskID)); try send(13, AlwaysOnWire.page(false))
                note("A2 録音 / A8 非リアルタイムページを送信"); status = "グラスのウェイクアップに応答しました。ローカル音声を待機中"
            } else if wire.type == 163 || wire.type == 164 {
                let now = now()
                receivedPackets += 1; receivedAudioBytes += wire.bytes.count
                var saved = false
                var dropReason = "保存失败"
                defer {
                    if !saved {
                        droppedPackets += 1; droppedAudioBytes += wire.bytes.count
                        dropReasons[dropReason, default: 0] += 1
                        if droppedPackets <= 3 || droppedPackets % 50 == 0 {
                            note("音声を保存できませんでした：\(dropReasonLabel(dropReason))、このパケットは\(wire.bytes.count)バイト、破棄累計\(droppedPackets)パケット")
                        }
                    }
                }
                lastAudio = now
                if stopAt != nil { stopResultAcknowledged = false }
                guard active, acceptingAudio else { dropReason = "接收已结束或异常中止"; return }
                guard now < saveDeadline else { dropReason = "超过接收截止"; return }
                guard a2Sent else { dropReason = "未应答A2"; return }
                guard let incoming = DeviceBusinessWire.identifier(wire.json, "taskId") else {
                    dropReason = "缺少有效taskId"; return
                }
                guard incoming == taskID else { dropReason = "其他taskId"; return }
                guard storedBytes + packet.count + 4 <= 8 * 1_024 * 1_024, packetCount < 4096 else { throw DeviceFeatureError.storageLimit }
                var length = UInt32(packet.count).littleEndian
                let prefix = withUnsafeBytes(of: &length) { Data($0) }
                guard let file else { throw DeviceFeatureError.invalidPacket }
                try file.write(contentsOf: prefix + packet)
                storedBytes += packet.count + 4; packetCount += 1; audioBytes += wire.bytes.count
                saved = true
                if stopAt != nil || now >= deadline { tailPackets += 1 }
                let summary = AlwaysOnWire.batchSummary(wire)
                frameCount += summary.frames; unusedBytes += summary.unusedBytes
                if packetCount == 1 || packetCount % 50 == 0 { note("A\(wire.type - 160) パケット \(packetCount)、音声累計 \(audioBytes) バイト") }
                status = stopAt == nil ? "音声をこの端末に保存しました。デコード可否や完全性は未検証です" : "停止を依頼済み。今回分の残りパケットは保存しました。終了処理を待機中"
            } else if wire.type == 165 { note("A5 終了を受信 rc=\(DeviceBusinessWire.integer(wire.json, "rc").map(String.init) ?? "なし")"); if stopAt == nil { stop(reason: "グラスが終了") } }
        } catch { acceptingAudio = false; self.error = "終日記録プロトコルまたは書き込みの異常です。受信済みの元パケットを保持して停止します。"; stop(reason: "受信エラー") }
    }
    func tick() {
        guard active else { return }
        let now = now()
        if stopAt == nil { remaining = max(0, Int(ceil(deadline - now))); if now >= deadline { stop(reason: "25秒の上限") } }
        if stopAt != nil { remaining = max(0, Int(ceil(saveDeadline - now))) }
        if now >= saveDeadline { finishCapture() }
    }
    private func finishCapture() {
        guard active else { return }
        timer?.invalidate(); timer = nil; active = false; acceptingAudio = false; remaining = 0
        let quiet = lastAudio == 0 || now() - lastAudio >= 3
        if offObserved && quiet { pendingStop = false; defaults.removeObject(forKey: pendingKey) }
        status = pendingStop ? "この端末での保存は停止しました。グラスの停止はまだ十分に確認できていません。停止を再送し、グラスを確認してください" : "オフ状態を受信し、末尾の時間枠に新しい音声はありませんでした。ローカルテストを終了します"
        if pendingStop && stopResultAcknowledged { status = "スイッチ成功の受信確認が届きました。グラスがオフになったか目視で確認してから、終了を確定してください" }
        note(status)
        do {
            try file?.synchronize(); try file?.close(); file = nil
            if let directory {
                let data = try JSONSerialization.data(withJSONObject: ["createdAt": ISO8601DateFormatter().string(from: Date()),
                    "taskId": taskID, "packets": packetCount, "audioBytes": audioBytes, "frames": frameCount,
                    "unusedBytes": unusedBytes, "offObserved": offObserved, "quietTail": quiet, "stopPending": pendingStop,
                    "stopResultAcknowledged": stopResultAcknowledged,
                    "receivedPackets": receivedPackets, "receivedAudioBytes": receivedAudioBytes,
                    "droppedPackets": droppedPackets, "droppedAudioBytes": droppedAudioBytes,
                    "savedTailPackets": tailPackets, "dropReasons": dropReasons,
                    "stopRequestLimitSeconds": 25, "receiveLimitSeconds": 30,
                    "format": "uint32le length + original business envelope; NOT verified opus/wav", "events": events], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch { self.error = "ローカルファイルの終了処理に失敗しました。既存の元パケットは保持します。完全とは記録できません。" }
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}

struct AlwaysOnLocalProbeView: View {
    @ObservedObject var probe: AlwaysOnLocalProbe
    @State private var consent = false
    @State private var confirmPhysicalStop = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Text("終日記録 · ローカル短時間テスト").font(.headline)
                    Text("独立した A1–A8 プロトコルの検証で、完成した終日録音機能ではありません。25秒で停止を依頼し、遅くとも30秒で今回分の残りパケットの受信を終えます。位置情報、カレンダー、クラウド文字起こしは使いません。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text(probe.status).accessibilityIdentifier("always-on-status")
                    Text("現在のフェーズの残り \(probe.remaining) 秒\n受信 \(probe.receivedPackets) パケット / \(probe.receivedAudioBytes) バイト\n保存 \(probe.packetCount) パケット / \(probe.audioBytes) バイト（残りパケット \(probe.tailPackets)）\n破棄 \(probe.droppedPackets) パケット / \(probe.droppedAudioBytes) バイト")
                        .font(.caption).accessibilityIdentifier("always-on-counters")
                    if let error = probe.error { Text(error).foregroundStyle(Palette.amber) }
                    Toggle("今回の音声をこの端末だけに保存することに同意", isOn: $consent).disabled(probe.occupied).accessibilityIdentifier("always-on-consent")
                    Button("30秒のローカルテストを開始") { probe.start(); consent = false }
                        .disabled(!consent || !probe.canStart).accessibilityIdentifier("always-on-start")
                    Button("停止 / オフを再送", role: .destructive) { probe.stop() }
                        .disabled(!probe.occupied).accessibilityIdentifier("always-on-stop")
                    if probe.canConfirmPhysicalStop {
                        Button("グラスがオフなのを確認しました") { confirmPhysicalStop = true }
                            .accessibilityIdentifier("always-on-confirm-off")
                        Text("グラスの終日記録がオフになったのを目視で確認した場合にだけ使ってください。スイッチ成功の受信確認は OFF 状態とは別物です。手動確認は別途記録されます。")
                            .font(.caption).foregroundStyle(Palette.amber)
                    }
                    Text("開始前に周囲の人へ知らせ、テスト用の文を使ってください。AI音声の待機は一時停止します。終了後にクラウド録音が自動で再開することはありません。切断や強制終了では遠隔側の即時停止を保証できません。グラスとスマホの接続を保ち、様子を見てください。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                if let path = probe.directory { Text("この端末の元パケット：\(path.lastPathComponent)\n形式を検証するまでは再生可能な録音とは扱いません。グラスの古いキャッシュの照会や削除もしません。").font(.caption) }
                Card {
                    Text("プロトコルイベント（音声本文なし）").font(.headline)
                    ForEach(Array(probe.events.enumerated()), id: \.offset) { _, event in Text(event).font(.system(.caption, design: .monospaced)) }
                }
            }.padding(22)
        }.background(Palette.background).navigationTitle("終日記録").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .confirmationDialog("グラスを見て、終日記録がオフになっているのを確認しましたか？手動確認として記録され、プロトコル検証の合格とは記録されません。", isPresented: $confirmPhysicalStop) {
                Button("グラスがオフなのを確認") { probe.confirmPhysicalStop() }
                Button("キャンセル", role: .cancel) {}
            }
    }
}
