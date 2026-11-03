import Foundation
import UIKit
import RayNeoProtocol

/// Main queue only. Standby VAD decodes bounded audio in memory only.
/// Legacy one-shot fixtures remain metadata-only; no disk/network audio output.
final class VoiceHandshakeProbe {
    var log: ((String) -> Void)?
    var send: ((String, Data) throws -> Void)?
    // Ephemeral presentation only; reports accepted send submission, not lens ACK.
    var onSubmittedCommand: ((StandbyVoiceSession.Command) -> Void)?
    var onArchiveTranscript: ((UUID,String,Bool) -> Void)?
    let standby = StandbyVoiceSession()
    private let cloud = CloudVoicePipeline()
    var cloudTools: (() -> [[String: Any]])? { didSet { cloud.toolDefinitions = cloudTools } }
    var executeCloudTool: ((String, String, UUID) async -> String)? { didSet { cloud.executeTool = executeCloudTool } }
    private var incrementalFixtureUntil: TimeInterval?
    private var nativeVAD = RNVoiceVADCreate()
    private var vadPackets = 0
    private var vadFrames = 0
    private var vadVoiced = 0
    private var lastAudioArrival: TimeInterval?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var deviceID: String?
    private var nonce: UUID?
    private var recording = false
    private var packets = 0
    private var bytes = 0
    private var auditDeviceID: String?
    private var postStopPackets = 0
    private var auditGeneration: UUID?
    private var deadline: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var text = ""
    private var displaySeconds: TimeInterval = 3

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object:nil, queue:.main) { [weak self] _ in
                if self?.standby.enabled != true { self?.stopDisplayTest() }
            }
        standby.log = { [weak self] in self?.log?($0) }
        cloud.log = { [weak self] in self?.log?($0) }
        cloud.onArchiveTranscript = { [weak self] id, text, final in self?.onArchiveTranscript?(id,text,final) }
        cloud.onEndpoint = { [weak self] id in self?.standby.cloudEndpoint(id:id,now:ProcessInfo.processInfo.systemUptime) }
        cloud.onTranscript = { [weak self] id, text, final in self?.standby.cloudTranscript(text,final:final,id:id) }
        cloud.onText = { [weak self] id, text, final in self?.standby.cloudText(text,final:final,id:id,now:ProcessInfo.processInfo.systemUptime) }
        cloud.onError = { [weak self] id in self?.standby.cloudFailed(id:id) }
        cloud.onUtteranceBegan = { [weak self] turn, session in
            self?.standby.cloudUtteranceBegan(id:turn,session:session,now:ProcessInfo.processInfo.systemUptime)
        }
        cloud.onEmptyUtterance = { [weak self] id in
            self?.standby.cloudEmptyUtterance(id:id,now:ProcessInfo.processInfo.systemUptime)
        }
        standby.send = { [weak self] target, command in
            guard let send = self?.send else { return false }
            do {
                let payload: Data
                switch command {
                case .startAudio: payload = AssistantRecorderPrototype.control(start:true)
                case .stopAudio: payload = AssistantRecorderPrototype.control(start:false)
                case .vadStart: payload = AssistantVADPrototype.status(.start)
                case .vadStop: payload = AssistantVADPrototype.status(.stop)
                case .vadTimeout: payload = AssistantVADPrototype.status(.timeout)
                case .text(let text): payload = try AssistantTextPrototype.asrText(text, isFinal:true)
                case .streamText(let text, let final): payload = try AssistantTextPrototype.asrText(text,isFinal:final)
                case .answer(let text, let final, let id, let query):
                    payload = try AssistantAnswerPrototype.chat(text,isFinal:final,roundID:id,query:query,
                        timestampMilliseconds:Int64(Date().timeIntervalSince1970 * 1000))
                case .responseComplete: payload = AssistantResponseCompletePrototype.complete()
                case .exit: payload = AssistantExitPrototype.normalExit()
                }
                try send(target, payload)
                self?.onSubmittedCommand?(command)
                return true
            } catch { return false }
        }
        standby.phaseChanged = { [weak self] phase in
            guard let self else { return }
            if phase == .recording {
                let sameASR = self.standby.continuousASREnabled && self.cloud.id != nil && self.cloud.id == self.standby.cloudSessionID
                if !sameASR {
                    self.vadPackets = 0; self.vadFrames = 0; self.vadVoiced = 0
                    self.lastAudioArrival = nil
                }
                if self.standby.vadEnabled && !sameASR {
                    let rc = RNVoiceVADReset(self.nativeVAD)
                    self.log?(self.standby.continuousASREnabled ? "継続ASR Opusデコーダを初期化 rc=\(rc)；デコードのみで、ローカルVAD分類はしません" : "VADローカル初期化 rc=\(rc) Opus出力16k/mono WebRTCモード2；PCMはディスクに保存しません")
                    if rc != 0 {
                        self.standby.audioFailed()
                        return
                    }
                }
                if let id = self.standby.cloudSessionID, self.standby.cloudEnabled, !sameASR {
                    if let until = self.incrementalFixtureUntil, ProcessInfo.processInfo.systemUptime <= until {
                        self.incrementalFixtureUntil = nil
                        self.runIncrementalFixture(id:id)
                    } else {
                        self.incrementalFixtureUntil = nil
                        self.cloud.start(id:id)
                    }
                }
            } else if self.vadPackets > 0 && !self.standby.continuousASREnabled {
                self.log?("VAD本ラウンドのサマリー packets=\(self.vadPackets) frames10ms=\(self.vadFrames) voiced=\(self.vadVoiced)；音声本文なし")
                self.vadPackets = 0
            }
            if phase == .displaying, self.standby.cloudEnabled, !self.standby.continuousASREnabled {
                // Output is complete on the phone. Do not keep a background
                // task whose expiry could close a still-rendering lens page.
                self.cloud.cancel()
                self.endBackgroundTask()
            } else if phase == .recording || phase == .processing || phase == .displaying {
                if self.backgroundTask == .invalid {
                    self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"RayNeo synthetic voice round") { [weak self] in
                        self?.standby.executionExpired()
                        self?.endBackgroundTask()
                    }
                }
            } else {
                self.cloud.cancel(clearHistory:phase == .disabled || phase == .waitingForConnection)
                self.endBackgroundTask()
            }
        }
    }
    func armIncrementalFixture() {
        guard standby.enabled, standby.cloudEnabled, standby.phase == .idle, !standby.continuousASREnabled else {
            log?("増分セグメントテストには旧クラウドモードが接続済みでウェイクアップ待機中であることが必要です；先に継続ASR実験をオフにしてください"); return
        }
        incrementalFixtureUntil = ProcessInfo.processInfo.systemUptime + 90
        log?("次回90秒以内のウェイクアップ：A1-A4はすべてwireFinal=false、12秒時点で独立したtype12；クラウドへ送らず、音声は保存しません")
    }
    private func runIncrementalFixture(id: UUID) {
        cloud.cancel()
        let marker = String(id.uuidString.prefix(4))
        log?("合成増分テスト開始 marker=\(marker)；固定の非プライベートテキストのみ送信し、ASR/モデルリクエストは開始していません")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self] in
            guard let self, self.standby.cloudRoundID == id, self.standby.phase == .recording else { return }
            self.standby.cloudTranscript("セグメントテスト \(marker)",final:true,id:id)
            self.standby.cloudEndpoint(id:id,now:ProcessInfo.processInfo.systemUptime)
        }
        let chunks = ["A1：これは第1段落です。一度だけ表示されるはずです。", "A2：これは第2段落です。後ろに続いているか確認してください。",
                      "A3：これは第3段落です。前の内容が繰り返し表示されてはいけません。", "A4：末尾チェック \(marker)、これで完全に終了です。"]
        for (index, text) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline:.now()+1+Double(index)*2) { [weak self] in
                guard let self, self.standby.cloudRoundID == id, self.standby.phase == .processing else { return }
                self.log?("合成セグメントを送信 index=\(index+1)/4 marker=\(marker)")
                self.standby.cloudText(text,final:false,id:id,now:ProcessInfo.processInfo.systemUptime)
            }
        }
        // Diagnostic separation only, not a production reading-time estimate.
        // A4 at +7s, completion at +12s: correlate lens exit to either event.
        DispatchQueue.main.asyncAfter(deadline:.now()+12) { [weak self] in
            guard let self, self.standby.cloudRoundID == id, self.standby.phase == .processing else { return }
            self.log?("合成セグメントが独立して完了 marker=\(marker)；A4予定の5秒後、type12を送信")
            self.standby.cloudComplete(id:id,now:ProcessInfo.processInfo.systemUptime)
        }
    }
    deinit {
        cloud.cancel()
        RNVoiceVADDestroy(nativeVAD)
        deadline?.cancel()
        pendingExit?.cancel()
        endBackgroundTask()
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }
    func arm(deviceID: String, fixture: DisplayBoundaryFixture? = nil) {
        precondition(Thread.isMainThread)
        guard !standby.enabled else { log?("先に継続待機をオフにしてから単項目の表示テストを行ってください"); return }
        guard nonce == nil, auditDeviceID == nil else { log?("音声テストは準備済み/進行中/停止確認中のいずれかのため、重ねて開始しません"); return }
        let id = UUID()
        // Synthetic response, never a transcript or model answer. New value for
        // each explicitly armed run lets the wearer detect stale lens content.
        text = fixture?.text ?? ("テスト " + id.uuidString.prefix(8))
        displaySeconds = fixture == nil ? 3 : 10
        if let fixture {
            log?("表示境界 case=\(fixture.id) utf8Bytes=\(fixture.text.utf8.count) lines=\(fixture.text.split(separator:"\n", omittingEmptySubsequences:false).count) holdSeconds=10；合成した固定コンテンツ、未送信")
        }
        nonce = id; self.deviceID = deviceID; recording = false; packets = 0; bytes = 0
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.nonce == id else { return }
            self?.finish(reason:"90秒以内に能動的なウェイクアップを受信せず", display:false)
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline:.now()+90, execute:timeout)
        log?("ワンショット音声テストの準備完了：実際のtype1ウェイクアップを待機、90秒で期限切れ；収音はまだリクエストしていません")
    }
    func receive(deviceID: String, metadata: BusinessEnvelopeMetadata, audio: Data? = nil,
                 arrival: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        precondition(Thread.isMainThread)
        if standby.enabled {
            standby.receive(from:deviceID, type:metadata.messageType ?? 0,
                audioBytes:metadata.dataBytes ?? 0, now:ProcessInfo.processInfo.systemUptime)
            if standby.vadEnabled, (standby.phase == .recording || (standby.continuousASREnabled && standby.active)),
               standby.target == deviceID, metadata.messageType == 3 {
                processAudio(audio, arrival:arrival)
            }
            return
        }
        if auditDeviceID == deviceID, [UInt32(1), 8, 11].contains(metadata.messageType ?? 0), pendingExit != nil {
            pendingExit?.cancel(); pendingExit = nil
            log?("新しいウェイクアップ/ラウンド、またはグラスの終了を受信。旧セッションの遅延終了をキャンセル")
        }
        if nonce == nil, auditDeviceID == deviceID, metadata.messageType == 3 {
            postStopPackets += 1
        }
        guard nonce != nil, self.deviceID == deviceID else { return }
        if metadata.messageType == 1 && !recording {
            guard let send else { finish(reason:"送信経路なし", display:false); return }
            do { try send(deviceID, AssistantRecorderPrototype.control(start:true)) }
            catch { finish(reason:"開始コマンドの送信に失敗", display:false); return }
            recording = true
            log?("実際のウェイクアップを受信し、type2 rc=1を送信済み；最大8秒、実際のtype3音声を待機")
            deadline?.cancel()
            let id = nonce
            let timeout = DispatchWorkItem { [weak self] in
                guard self?.nonce == id else { return }
                self?.finish(reason:"8秒テストがタイムアップ", display:true)
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline:.now()+8, execute:timeout)
        } else if metadata.messageType == 3 && recording {
            packets += 1; bytes += metadata.dataBytes ?? 0
            if packets == 1 { log?("単独テストで最初のtype3を受信、dataBytes=\(metadata.dataBytes ?? 0)；本文は保存しません") }
        } else if metadata.messageType == 8 {
            finish(reason:"グラス側から終了", display:false)
        }
    }
    func finish(reason: String, display: Bool) {
        precondition(Thread.isMainThread)
        guard nonce != nil else {
            pendingExit?.cancel(); pendingExit = nil
            return
        }
        deadline?.cancel(); deadline = nil
        let wasRecording = recording, target = deviceID
        nonce = nil; deviceID = nil; recording = false
        if wasRecording, let target, let send {
            auditDeviceID = target; postStopPackets = 0
            do {
                try send(target, AssistantRecorderPrototype.control(start:false))
                log?("type2 rc=2の停止リクエストを送信済み；グラスの後続音声が止まったか確認が必要です")
            } catch { log?("停止リクエストの送信に成功しなかったため、リモート側が停止したとは認定できません；グラスの音声画面を終了してください") }
            if display && packets > 0 && bytes > 0 {
                do {
                    try send(target, AssistantTextPrototype.asrText(text,isFinal:true))
                    log?("type5の合成テストテキストを送信済み utf8Bytes=\(text.utf8.count) holdSeconds=\(Int(displaySeconds))；認識結果でもモデルの結果でもなく、表示は確認待ち")
                    let exit = DispatchWorkItem { [weak self] in
                        guard let self, self.auditDeviceID == target, let send = self.send else { return }
                        self.pendingExit = nil
                        do {
                            try send(target, AssistantExitPrototype.normalExit())
                            self.log?("表示保持期間が終了し、type7 rc=1で正常終了を送信済み；グラスのページが自動で隠れるか確認待ち")
                        } catch { self.log?("正常終了コマンドの送信に成功しませんでした；グラスの音声画面を手動で終了してください") }
                    }
                    pendingExit = exit
                    DispatchQueue.main.asyncAfter(deadline:.now()+displaySeconds, execute:exit)
                } catch { log?("固定テキストの送信に成功しませんでした") }
            } else if display {
                log?("空でないtype3音声を観測しなかったため、ランダム回答は送信せず、音声アップリンクが通過したとは認定しません")
                do { try send(target, AssistantExitPrototype.normalExit()) }
                catch { log?("音声なしテストの終了送信に成功しませんでした；グラスの音声画面を手動で終了してください") }
            }
            let auditSeconds = max(5, displaySeconds + 2)
            let auditID = UUID()
            auditGeneration = auditID
            DispatchQueue.main.asyncAfter(deadline:.now()+auditSeconds) { [weak self] in
                guard let self, self.auditGeneration == auditID else { return }
                self.log?("停止後\(Int(auditSeconds))秒の観察：新規type3=\(self.postStopPackets)；コールバックのみ集計し、マイクの電気的状態については主張しません")
                self.auditDeviceID = nil
                self.auditGeneration = nil
            }
        }
        log?("ワンショット音声テスト終了：\(reason)、type3観察数=\(packets)、data総バイト数=\(bytes)、音声保存=0")
    }

    func stopDisplayTest() {
        precondition(Thread.isMainThread)
        finish(reason:"表示テストを手動で終了", display:false)
        if let target = auditDeviceID, let send {
            pendingExit?.cancel(); pendingExit = nil
            do { try send(target, AssistantExitPrototype.normalExit()) }
            catch { log?("手動終了リクエストに失敗；グラスのボタンで終了してください") }
        }
    }

    func enableStandby(deviceID: String) {
        stopDisplayTest()
        // Cancel the old audit identity before switching ownership to the service.
        auditDeviceID = nil
        auditGeneration = nil
        standby.vadEnabled = true
        standby.enable(target:deviceID, connected:true)
    }
    func setCloudMode(_ enabled: Bool) {
        standby.cancelCurrentRound()
        cloud.cancel(clearHistory:true)
        standby.cloudEnabled = enabled
        standby.continuousASREnabled = false; cloud.continuousASR = false
        log?(enabled ? "クラウドモードをオンにしました：音声→ユーザーのAlibaba Cloud、テキスト→DeepSeek；文末はクラウドが判定し、ローカルの900ms切り捨ては使いません" : "クラウドモードをオフにしました：ローカルVADのランダムテキストに戻り、アップロードしません")
    }
    func setContinuousASR(_ enabled: Bool) {
        guard !enabled || (standby.enabled && standby.cloudEnabled) else {
            log?("継続ASR実験には、接続済みの待機状態とユーザーのクラウドモードが必要です"); return
        }
        standby.cancelCurrentRound(); cloud.cancel()
        incrementalFixtureUntil = nil
        standby.continuousASREnabled = enabled; cloud.continuousASR = enabled
        log?(enabled ? "継続ASR並行実験を有効化しました：次回のウェイクアップでは音声を継続してユーザーのASRへ、クラウドの発話開始で割り込み、文末でモデルを並行実行；ローカルVADなし、120秒ガード" : "継続ASR実験をオフにしました。検証済みのターン制対話に復帰")
    }
    private func processAudio(_ audio: Data?, arrival: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        // Lost/delayed transport is not silence; don't endpoint on missing data.
        guard now - arrival <= 0.5 else { standby.audioDiscontinuity(); return }
        if let previous = lastAudioArrival, arrival - previous > 0.2 {
            standby.audioDiscontinuity()
        }
        lastAudioArrival = arrival
        guard let audio, !audio.isEmpty else { standby.audioFailed(); return }
        var mask: UInt32 = 0
        var pcm = [Int16](repeating:0,count:1920)
        let frames = audio.withUnsafeBytes { bytes in
            if standby.cloudEnabled {
                return pcm.withUnsafeMutableBufferPointer { samples in
                    if standby.continuousASREnabled {
                        return RNVoiceDecodePCM(nativeVAD,bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count,samples.baseAddress,samples.count)
                    }
                    return RNVoiceVADProcessPCM(nativeVAD,bytes.bindMemory(to:UInt8.self).baseAddress,bytes.count,&mask,samples.baseAddress,samples.count)
                }
            }
            return RNVoiceVADProcess(nativeVAD, bytes.bindMemory(to:UInt8.self).baseAddress, bytes.count, &mask)
        }
        guard frames > 0, frames <= 12 else {
            log?("VAD音声処理に失敗 rc=\(frames) packetBytes=\(audio.count)；破損パケットは保存しません")
            standby.audioFailed(); return
        }
        vadPackets += 1; vadFrames += Int(frames); vadVoiced += mask.nonzeroBitCount
        if vadPackets == 1 { log?("VAD初回パケットのデコードに成功 packetBytes=\(audio.count) samples=\(frames * 160) frames10ms=\(frames)") }
        if standby.cloudEnabled {
            let data = pcm.withUnsafeBytes { Data($0.prefix(Int(frames) * 160 * 2)) }
            cloud.appendPCM(data)
        }
        guard !standby.continuousASREnabled else { return }
        for index in 0..<Int(frames) {
            standby.vadFrame(speech:(mask & (1 << index)) != 0, now:now)
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
