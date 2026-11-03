import Foundation

/// Pure, clock-driven service/session separation. Receives metadata only.
/// The host owns transport, background execution and the single serial queue.
final class StandbyVoiceSession {
    enum Command: Equatable { case startAudio, stopAudio, vadStart, vadStop, vadTimeout, text(String), streamText(String, Bool), answer(String, Bool, UUID, String), responseComplete, exit }
    enum Phase: String { case disabled, waitingForConnection, idle, recording, processing, displaying }
    var send: ((String, Command) -> Bool)?
    var log: ((String) -> Void)?
    var phaseChanged: ((Phase) -> Void)?
    var makeText: () -> String = { "待機テスト " + UUID().uuidString.prefix(8) }
    var vadEnabled = false // Set before enabling; legacy fixtures stay unchanged.
    var cloudEnabled = false
    var continuousASREnabled = false // Explicit experimental opt-in, not persisted.
    private(set) var cloudSessionID: UUID?
    private(set) var cloudRoundID: UUID?
    private var sessionDeadline: TimeInterval?
    private var followupWait: (round: UUID, deadline: TimeInterval)?
    private var lastDuplexAudio: TimeInterval?
    private var duplexPackets = 0
    private var endpoint = SpeechEndpointDetector()
    private var noSpeechDeadline: TimeInterval?
    private(set) var target: String?
    private(set) var phase: Phase = .disabled
    private var deadline: TimeInterval?
    private var packets = 0
    private var bytes = 0
    private var response = ""
    private var transcript = ""
    private var transcriptFinal = false
    private var answerBytes = 0
    private var round = 0
    var enabled: Bool { target != nil }
    var active: Bool { phase == .recording || phase == .processing || phase == .displaying }

    func enable(target: String, connected: Bool) {
        disable()
        self.target = target
        setPhase(connected ? .idle : .waitingForConnection)
        log?("継続サービスを開始しました；実際のウェイクアップを待機中、90秒のarmタイムアウトなし；収音は未リクエスト")
    }
    func disable() {
        closeRound(sendExit: true)
        target = nil
        setPhase(.disabled)
    }
    func connection(_ ready: Bool) {
        guard enabled else { return }
        if !ready, phase != .waitingForConnection {
            // No write to an invalid/replaced transport; remote stop not guaranteed.
            deadline = nil
            followupWait = nil
            sessionDeadline = nil; cloudSessionID = nil; cloudRoundID = nil
            setPhase(.waitingForConnection)
            log?("継続サービスの接続準備ができていません。本ラウンドをキャンセルします；リモート側が停止したとは主張しません")
        } else if ready, phase == .waitingForConnection {
            setPhase(.idle)
            log?("継続サービスの認証済み接続が復旧し、待機に戻りました；自動では収音しません")
        }
    }
    func receive(from source: String, type: UInt32, audioBytes: Int, now: TimeInterval) {
        guard source == target, phase != .waitingForConnection, phase != .disabled else { return }
        if type == 8 {
            log?("グラス側からtype8で終了 phase=\(phase.rawValue)；終了を尊重し、自動では再点灯しません")
            closeRound(sendExit: false)
            return
        }
        if type == 3 {
            if continuousASREnabled, active, audioBytes > 0 {
                lastDuplexAudio = now
                if phase != .recording {
                    duplexPackets += 1
                    if duplexPackets == 1 || duplexPackets % 100 == 0 {
                        log?("継続ASR出力中の音声 packets=\(duplexPackets) phase=\(phase.rawValue)；長さのみ集計")
                    }
                }
            }
            guard phase == .recording, audioBytes > 0 else { return }
            packets += 1
            bytes += min(audioBytes, 1_048_576)
            if packets == 1 { log?("継続セッションで最初の空でないtype3を受信；長さのみ集計し、音声は保存しません") }
            return
        }
        if continuousASREnabled, active, type == 11 {
            // Next-turn request, NOT a render-complete ACK. Completion owns
            // the idle deadline; early/missing/duplicate requests cannot change it.
            log?("継続ASRでtype11を受信 phase=\(phase.rawValue)；回答完了後の無音タイマーは変更しません")
            return
        }
        // 0x0B is a next-round event, not permission to start from idle.
        guard type == 1 || (type == 11 && phase == .displaying) else { return }
        guard phase == .idle || phase == .displaying || (cloudEnabled && phase == .processing) else { return }
        deadline = nil // Supersede the old display exit; never closes a newer round.
        followupWait = nil
        endpoint = SpeechEndpointDetector()
        noSpeechDeadline = vadEnabled && !continuousASREnabled ? now + 5 : nil
        packets = 0; bytes = 0; round += 1; response = makeText()
        cloudRoundID = cloudEnabled ? UUID() : nil
        cloudSessionID = cloudRoundID
        sessionDeadline = continuousASREnabled ? now + 120 : nil
        lastDuplexAudio = now; duplexPackets = 0
        transcript = ""; transcriptFinal = false
        answerBytes = 0
        guard write(.startAudio) else { failRound(); return }
        deadline = now + (cloudEnabled ? 20 : 8)
        setPhase(.recording)
        log?("継続セッション round=\(round) type\(type)→type2/rc1；\(cloudEnabled ? 20 : 8)秒上限 cloud=\(cloudEnabled)")
    }
    func vadFrame(speech: Bool, now: TimeInterval) {
        guard vadEnabled, !continuousASREnabled, phase == .recording else { return }
        tick(now:now)
        guard phase == .recording else { return }
        switch endpoint.accept(speech:speech) {
        case .none: break
        case .began: log?("VADが音声開始を検出；120ms/200msウィンドウ")
        case .ended:
            if cloudEnabled { log?("ローカルVADのバイパスでポーズを観測；文末はクラウドが決定し、切り捨てません"); return }
            log?("VADが音声終了を検出；900ms連続で非音声；早期に停止")
            finishRecording(now:now, reply:true)
        }
    }
    func audioDiscontinuity() { endpoint.discontinuity() }
    func audioFailed() {
        guard vadEnabled, (phase == .recording || (continuousASREnabled && active)) else { return }
        log?("VADのデコード/分類に失敗。本ラウンドを停止し回答は生成しません；無音判定ではありません")
        closeRound(sendExit:true)
    }
    func tick(now: TimeInterval) {
        if continuousASREnabled, active {
            if let sessionDeadline, now >= sessionDeadline {
                log?("継続ASR実験が120秒上限に到達。収音を停止して終了"); closeRound(sendExit:true); return
            }
            if let lastDuplexAudio, now-lastDuplexAudio > 5 {
                log?("継続ASRで5秒を超えて音声コールバックなし。キャンセルします；ストリーム欠落を無音の文末とは扱いません"); closeRound(sendExit:true); return
            }
        }
        if phase == .displaying, let wait = followupWait,
           wait.round == cloudRoundID, now >= wait.deadline {
            followupWait = nil
            log?("回答完了後10秒間、有効な続きの発話なし→音声停止/終了；サービスは待機を維持")
            if continuousASREnabled, !write(.vadTimeout) { failRound(); return }
            closeRound(sendExit:true)
            return
        }
        if vadEnabled, phase == .recording, !endpoint.hasSpeech,
           let noSpeechDeadline, now >= noSpeechDeadline {
            log?("VADが5秒待っても音声を確認できず。終了し回答は生成しません")
            closeRound(sendExit:true)
            return
        }
        guard let deadline, now >= deadline else { return }
        self.deadline = nil
        if phase == .recording {
            if cloudEnabled {
                log?("クラウド対話が20秒の収音ガードに到達；本ラウンドをキャンセルし、タイムアウトをクラウドの文末とは扱いません")
                closeRound(sendExit:true)
                return
            }
            if vadEnabled { log?("VADが8秒のガード上限に到達；文末を検出したわけではありません") }
            finishRecording(now:now, reply:!vadEnabled || endpoint.hasSpeech)
        } else if phase == .processing {
            log?("クラウド対話の処理が30秒を超過。キャンセルして終了")
            closeRound(sendExit:true)
        } else if phase == .displaying {
            guard write(.exit) else { failRound(); return }
            setPhase(.idle)
            log?("継続セッションのtype7終了を送信済み。サービスは継続中で、次回のウェイクアップを待機")
        }
    }
    func cloudEndpoint(id: UUID, now: TimeInterval) {
        guard cloudEnabled, cloudRoundID == id, phase == .recording else { return }
        guard write(continuousASREnabled ? .vadStop : .stopAudio) else { failRound(); return }
        deadline = now + 30
        setPhase(.processing)
        log?(continuousASREnabled ? "クラウドASRの文末→type4/rc2；収音を継続しながら並行してモデルを待機し、ASRタスクは終了しません" : "クラウドASRの文末→type2/rc2で収音を停止し、クラウドの回答を待機；音声はディスクに保存しません")
    }
    func cloudUtteranceBegan(id: UUID, session: UUID, now: TimeInterval) {
        guard continuousASREnabled, cloudEnabled, active, cloudSessionID == session,
              cloudRoundID != id else { return }
        let interrupting = phase == .processing || phase == .displaying
        if followupWait != nil { log?("有効な新しい発話により、旧ラウンドの続き発話の終了タイマーをキャンセル") }
        followupWait = nil
        cloudRoundID = id; transcript = ""; transcriptFinal = false; answerBytes = 0
        deadline = now + 20
        guard write(.vadStart) else { failRound(); return }
        setPhase(.recording)
        log?("クラウドの発話開始→type4/rc1、回答の世代を更新 interrupting=\(interrupting)；ASRセッションを保持し、ローカルVADは使いません")
    }
    func cloudEmptyUtterance(id: UUID, now: TimeInterval) {
        guard continuousASREnabled, cloudRoundID == id, phase == .recording else { return }
        // Reached only if earlier partial text already committed a new turn.
        // An empty final retracts it; do not invent a final or leave loading.
        log?("有効な暫定テキストの後にクラウドが空の発話を取り消し。本ラウンドを終了してloading状態を回避；暫定テキストからは回答を生成しません")
        closeRound(sendExit:true)
    }
    func cloudTranscript(_ text: String, final: Bool, id: UUID) {
        guard cloudEnabled, cloudRoundID == id, phase == .recording, !transcriptFinal,
              !text.isEmpty, text.utf8.count <= 512 else { return }
        guard write(.streamText(text,final)) else { failRound(); return }
        transcript = text; transcriptFinal = final
        log?("クラウド認識type5を送信 utf8Bytes=\(text.utf8.count) wireKey=final final=\(final)；本文はログに記録しません")
    }
    func cloudText(_ text: String, final: Bool, id: UUID, now: TimeInterval) {
        guard cloudEnabled, cloudRoundID == id, phase == .processing,
              (!text.isEmpty || (final && answerBytes > 0)), text.utf8.count <= 512 else { return }
        guard answerBytes + text.utf8.count <= 8192 else { failRound(); return }
        // Cloud EOF is NOT the wire answer.isFinal flag. Official successful
        // workflow/chat sessions sent only false text chunks, then type12.
        // An empty EOF flush must not invent an empty wire-final packet.
        if !text.isEmpty {
            guard write(.answer(text, false, id, transcript)) else { failRound(); return }
            answerBytes += text.utf8.count
            // Processing timeout measures a stalled stream, not total answer length.
            deadline = now + 30
            log?("増分回答type32を送信 chunkBytes=\(text.utf8.count) totalBytes=\(answerBytes) wireFinal=false cloudEOF=\(final)；本文はログに記録しません")
        }
        if final { cloudComplete(id:id,now:now) }
    }
    func cloudComplete(id: UUID, now: TimeInterval) {
        guard cloudEnabled, cloudRoundID == id, phase == .processing, answerBytes > 0 else { return }
        guard write(.responseComplete) else { failRound(); return }
        deadline = nil
        // The coalescer has flushed all deltas before this call. This is SDK
        // submission completion, not a lens render ACK. Never start at first token.
        followupWait = (id, now + 10)
        setPhase(.displaying)
        log?("workflow回答type12の完了を送信済み；10秒の無音終了タイマーを開始し、有効な新しい発話でキャンセル；レンズ描画の受領確認ではありません")
    }
    func cloudFailed(id: UUID) {
        guard cloudRoundID == id || cloudSessionID == id, active else { return }
        log?("クラウド対話が失敗またはキャンセル。本ラウンドを終了；モデルの回答を偽装しません")
        closeRound(sendExit:true)
    }
    private func finishRecording(now: TimeInterval, reply: Bool) {
        deadline = nil
        guard write(.stopAudio) else { failRound(); return }
        log?("継続セッションtype2/rc2を送信済み packets=\(packets) dataBytes=\(bytes) 音声保存=0")
        guard reply, packets > 0, bytes > 0 else { closeRound(sendExit:true); return }
        guard write(.text(response)) else { failRound(); return }
        deadline = now + 10
        setPhase(.displaying)
        log?("継続セッションtype5の合成ランダムテキストを送信済み。10秒表示；認識結果でもモデルの回答でもありません")
    }
    func executionExpired() {
        guard active else { return }
        log?("システムのバックグラウンド実行時間が期限切れ。本ラウンドを停止し、待機の意図は保持；バックグラウンド動作は保証されません")
        closeRound(sendExit: true)
    }
    func cancelCurrentRound() { if active { closeRound(sendExit:true) } }
    private func closeRound(sendExit: Bool) {
        let wasActive = active
        var ok = true
        if phase == .recording || (continuousASREnabled && wasActive) { ok = write(.stopAudio) }
        if wasActive && sendExit { ok = write(.exit) && ok }
        deadline = nil
        cloudRoundID = nil
        followupWait = nil
        cloudSessionID = nil; sessionDeadline = nil; lastDuplexAudio = nil
        answerBytes = 0
        if enabled { setPhase(ok ? .idle : .waitingForConnection) }
        if !ok { log?("継続セッションの停止/終了の送信に失敗；接続の再確認が必要で、リモート側が停止したとは主張しません") }
    }
    private func failRound() {
        // Best-effort bounded cleanup; no repeated sends or automatic recording.
        _ = write(.stopAudio); _ = write(.exit)
        deadline = nil
        cloudRoundID = nil
        followupWait = nil
        cloudSessionID = nil; sessionDeadline = nil; lastDuplexAudio = nil
        answerBytes = 0
        setPhase(.waitingForConnection)
        log?("継続セッションの送信に失敗。本ラウンドをキャンセルし、接続の再確認を待機")
    }
    private func write(_ command: Command) -> Bool {
        guard let target else { return false }
        return send?(target, command) ?? false
    }
    private func setPhase(_ value: Phase) {
        guard phase != value else { return }
        phase = value
        phaseChanged?(value)
    }
}

/// Bounded retries of an already bonded target. No scanning, pairing or unbind.
struct StandbyReconnectPolicy {
    private(set) var attempts = 0
    private var next: TimeInterval = 0
    mutating func reset() { attempts = 0; next = 0 }
    mutating func shouldAttempt(now: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, attempts < 8, now >= next else { return false }
        next = now + [5.0, 10, 20, 40, 60, 60, 60, 60][attempts]
        attempts += 1
        return true
    }
}
