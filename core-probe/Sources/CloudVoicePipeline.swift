import Foundation

/// Main-queue owned, one round at a time. Credentials/audio/text never logged.
/// ASR/LLM use fixed origins. Optional tools are provided by the consented host;
/// there is no arbitrary URL, shell, or approval tool. No redirects.
final class CloudVoicePipeline {
    var log: ((String) -> Void)?
    var onEndpoint: ((UUID) -> Void)?
    var onTranscript: ((UUID,String,Bool) -> Void)?
    var onArchiveTranscript: ((UUID,String,Bool) -> Void)?
    var onText: ((UUID,String,Bool) -> Void)?
    var onError: ((UUID) -> Void)?
    var onUtteranceBegan: ((UUID,UUID) -> Void)?
    var onEmptyUtterance: ((UUID) -> Void)?
    var continuousASR = false // Set only while stopped; experimental opt-in.
    var toolDefinitions: (() -> [[String: Any]])?
    var executeTool: ((String, String, UUID) async -> String)?
    private(set) var id: UUID?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void,Never>?, sender: Task<Void,Never>?, modelTask: Task<Void,Never>?
    private var queue: [Data] = [], queueBytes = 0, totalBytes = 0
    private var ready = false, finishing = false, asrDone = false
    private var parts: [Int:String] = [:]
    private var history: [[String:String]] = []
    private var lastTranscript = ""
    private var lastTranscriptUpdate = 0.0
    private var turns = StreamingASRTurns()
    private var modelID: UUID?
    private let noRedirect = NoCloudRedirect()

    func start(id: UUID) {
        precondition(Thread.isMainThread)
        cancel()
        self.id = id
        guard let key = CloudVoiceKeys.get(CloudVoiceKeys.asrService), CloudVoiceKeys.get(CloudVoiceKeys.llmService) != nil else { fail(id,"Keychain の認証情報がありません"); return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = continuousASR ? 135 : 35
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration:config,delegate:noRedirect,delegateQueue:nil)
        self.session = session
        var request = URLRequest(url:URL(string:"wss://\(CloudVoiceKeys.asrHost)/api-ws/v1/inference")!)
        request.setValue("bearer " + key,forHTTPHeaderField:"Authorization")
        let ws = session.webSocketTask(with:request); ws.maximumMessageSize = 32768
        socket = ws; ws.resume()
        let taskID = id.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let command: [String:Any] = ["header":["action":"run-task","task_id":taskID,"streaming":"duplex"],
            "payload":["task_group":"audio","task":"asr","function":"recognition",
                       "model":"qwen-audio-3.0-asr-flash-streaming",
                       "parameters":["format":"pcm","sample_rate":16000],"input":[:]]]
        receiver = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await ws.send(.dataJSON(command))
                guard self.id == id else { return }
                self.log?("クラウドASR run-task 送信済み；PCM16/16k/mono；サービス既定のVAD")
                var events = 0
                while !Task.isCancelled, self.id == id {
                    let message = try await ws.receive()
                    guard self.id == id else { return }
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw CloudError.invalid }
                    guard data.count <= 32768, let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let header = object["header"] as? [String:Any], header["task_id"] as? String == taskID else { throw CloudError.invalid }
                    events += 1; guard events <= (self.continuousASR ? 10000 : 2000) else { throw CloudError.limit }
                    switch header["event"] as? String {
                    case "task-started":
                        self.ready = true; self.log?("クラウドASR task-started、メモリ上の音声の送信を開始")
                        self.drain(id)
                    case "result-generated":
                        let payload = object["payload"] as? [String:Any]
                        let output = payload?["output"] as? [String:Any]
                        if let sentence = output?["sentence"] as? [String:Any],
                           let text = sentence["text"] as? String {
                            guard text.utf8.count <= 8192 else { throw CloudError.limit }
                            let final = sentence["sentence_end"] as? Bool == true
                            if self.continuousASR {
                                if sentence["heartbeat"] as? Bool == true { continue }
                                guard let number = sentence["sentence_id"] as? NSNumber,
                                      number.doubleValue == Double(number.intValue) else { throw CloudError.invalid }
                                self.log?("継続ASRイベント sentence=\(number.intValue) characters=\(text.count) begin=\(sentence["sentence_begin"] as? Bool ?? false) end=\(final)；本文はログに記録しません")
                                let turnEvents = try self.turns.accept(sentenceID:number.intValue,text:text,
                                    begin:sentence["sentence_begin"] as? Bool ?? false,end:final,
                                    heartbeat:false,now:ProcessInfo.processInfo.systemUptime)
                                for event in turnEvents {
                                    guard self.id == id else { return }
                                    switch event {
                                    case .began(let turn):
                                        self.modelID = nil; self.modelTask?.cancel(); self.modelTask = nil
                                        self.log?("継続ASRで有効な文字の新しい文。旧モデルの送信世代をキャンセル；空のBOSは無視、ローカルVADではありません")
                                        self.onUtteranceBegan?(turn,id)
                                    case .transcript(let turn, let transcript, let isFinal):
                                        self.onArchiveTranscript?(turn,transcript,isFinal)
                                        self.onTranscript?(turn,Self.lensText(transcript),isFinal)
                                    case .ended(let turn, let transcript):
                                        if transcript.isEmpty { self.onEmptyUtterance?(turn); continue }
                                        self.onEndpoint?(turn)
                                        guard self.id == id else { return }
                                        self.log?("継続ASRの文の区切りが完了 characters=\(transcript.count)；finish-task は送らず、モデルを並行起動")
                                        self.startModel(id,transcript:transcript,turnID:turn)
                                    }
                                }
                                continue
                            }
                            self.log?("クラウドASR文字イベント characters=\(text.count) sentenceEnd=\(final)")
                            let visible = Self.lensText(text)
                            self.onArchiveTranscript?(id,text,final)
                            let now = ProcessInfo.processInfo.systemUptime
                            if !self.finishing, !visible.isEmpty,
                               final || (visible != self.lastTranscript && now - self.lastTranscriptUpdate >= 0.5) {
                                self.onTranscript?(id,visible,final)
                                guard self.id == id else { return }
                                self.lastTranscript = visible; self.lastTranscriptUpdate = now
                            }
                            if final, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                                let index = (sentence["sentence_id"] as? NSNumber)?.intValue ?? 0
                                guard self.parts.count < 16 || self.parts[index] != nil else { throw CloudError.limit }
                                self.parts[index] = text
                                if !self.finishing {
                                    self.finishing = true
                                    self.log?("クラウドASRで自然な文末に到達；ローカルの900msでの打ち切りではありません")
                                    self.onEndpoint?(id)
                                    guard self.id == id else { return }
                                    self.drain(id)
                                }
                            }
                        }
                    case "task-finished":
                        if self.continuousASR { throw CloudError.remote }
                        self.asrDone = true
                        let transcript = self.parts.keys.sorted().compactMap { self.parts[$0] }.joined()
                        guard self.finishing, !transcript.isEmpty, transcript.utf8.count <= 8192 else { throw CloudError.invalid }
                        ws.cancel(with:.normalClosure,reason:nil)
                        self.log?("クラウドASR task-finished characters=\(transcript.count)；DeepSeek へ引き継ぎ、文字のみ")
                        self.startModel(id,transcript:transcript)
                        return
                    case "task-failed": throw CloudError.remote
                    default: break
                    }
                }
            } catch { if self.id == id && !Task.isCancelled { self.fail(id,"ASR の接続またはプロトコルに失敗") } }
        }
    }
    /// ローカルASR (LocalSpeechPipeline) から確定文を受け取り、モデルだけを実行する。
    /// ASR 用 WebSocket は開かない。必要なのは LLM キーと URLSession のみ。
    func runModel(id: UUID, transcript: String) {
        precondition(Thread.isMainThread)
        if session == nil {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 35
            config.urlCache = nil; config.httpCookieStorage = nil
            session = URLSession(configuration: config, delegate: noRedirect, delegateQueue: nil)
        }
        self.id = id
        startModel(id, transcript: transcript)
    }
    func appendPCM(_ data: Data) {
        precondition(Thread.isMainThread)
        guard let id, !finishing, !data.isEmpty else { return }
        guard data.count <= 3840, data.count % 2 == 0, queueBytes + data.count <= 96000,
              totalBytes + data.count <= (continuousASR ? 3_900_000 : 704000) else { fail(id,"音声キュー／総量の上限を超過"); return }
        queue.append(data); queueBytes += data.count; totalBytes += data.count
        drain(id)
    }
    private func drain(_ current: UUID) {
        guard id == current, ready, sender == nil, !asrDone, let ws = socket else { return }
        sender = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.id == current { self.sender = nil } }
            do {
                while self.id == current && !Task.isCancelled {
                    if !self.queue.isEmpty {
                        let data = self.queue.removeFirst(); self.queueBytes -= data.count
                        try await ws.send(.data(data))
                    } else {
                        if self.finishing {
                            let taskID = current.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
                            try await ws.send(.dataJSON(["header":["action":"finish-task","task_id":taskID,"streaming":"duplex"],"payload":["input":[:]]]))
                            if self.id == current { self.ready = false; self.log?("クラウドASR finish-task 送信済み、最終完了を待機中") }
                        }
                        return
                    }
                }
            } catch { if self.id == current && !self.asrDone && !Task.isCancelled { self.fail(current,"ASR 音声の送信に失敗") } }
        }
    }
    private func startModel(_ current: UUID, transcript: String, turnID: UUID? = nil) {
        guard id == current, let session, let key = CloudVoiceKeys.get(CloudVoiceKeys.llmService) else { fail(current,"モデルの認証情報がありません"); return }
        let responseID = turnID ?? current
        modelTask?.cancel(); modelID = responseID
        var request = URLRequest(url:URL(string:"https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let tools = toolDefinitions?() ?? []
        let allowed = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let toolPolicy = tools.isEmpty ? "ツール実行能力はありません。リマインダーやToDoを作成した、操作を実行したなどと主張してはいけません。" : "提供された Codex ツールは、ユーザーが明示的に求めたときだけ呼び出し、1ターンに最大1つまで。通常の会話には直接答えること。実行成功を捏造してはいけません。ユーザーの代わりに権限を承認してはいけません。読み上げの停止や話題の変更を求められても、Codex タスクの停止を意味しません。タスクはバックグラウンドで実行できます。進捗の確認には codex_status を使い、承認は Turbo IO でユーザーが確認するよう案内すること。ToDo や天気などの他のツールはまだ未接続なので、実行したと主張してはいけません。"
        let messages = [["role":"system","content":"あなたはグラス上の日本語音声アシスタントです。日本語で、純テキストで回答してください。Markdownは使わないでください。既定では簡潔に答え、ユーザーが明示的に長さを求めたときだけそれに従ってください（例：約300字）。" + toolPolicy]] + history.suffix(6) + [["role":"user","content":transcript]]
        var body: [String: Any] = ["model":"deepseek-v4-flash","thinking":["type":"disabled"],"stream":true,"max_tokens":1024,"messages":messages]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto"; body["parallel_tool_calls"] = false }
        do { request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        catch { fail(current,"モデルリクエストのエンコードに失敗"); return }
        modelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (bytes,response) = try await session.bytes(for:request)
                guard self.id == current, self.modelID == responseID else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.remote }
                self.log?("DeepSeek HTTP200：flash/thinking disabled/stream true")
                var line = Data(), text = "", received = 0
                var coalescer = AnswerDeltaCoalescer()
                var finishReason = "unreported"
                var toolCall = VoiceToolCallAccumulator()
                var done = false, reasoning = 0
                for try await byte in bytes {
                    guard self.id == current, self.modelID == responseID, !Task.isCancelled else { return }
                    received += 1; guard received <= 262144 else { throw CloudError.limit }
                    if byte != 10 { line.append(byte); guard line.count <= 32768 else { throw CloudError.limit }; continue }
                    defer { line.removeAll(keepingCapacity:true) }
                    guard let string = String(data:line,encoding:.utf8), string.hasPrefix("data:") else { continue }
                    let value = string.dropFirst(5).trimmingCharacters(in:.whitespacesAndNewlines)
                    if value == "[DONE]" { done = true; break }
                    guard let object = try JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any],
                          let choices = object["choices"] as? [[String:Any]] else { throw CloudError.invalid }
                    for choice in choices {
                        if let reason = choice["finish_reason"] as? String {
                            finishReason = ["stop","length","content_filter","tool_calls"].contains(reason) ? reason : "other"
                        }
                        let delta = choice["delta"] as? [String:Any]
                        try toolCall.append(delta?["tool_calls"])
                        if let extra = delta?["reasoning_content"] as? String { reasoning += extra.count }
                        let addition = delta?["content"] as? String ?? ""
                        text += addition
                        guard text.utf8.count <= 8192 else { throw CloudError.limit }
                        for chunk in try coalescer.append(addition,now:ProcessInfo.processInfo.systemUptime) {
                            guard self.id == current, self.modelID == responseID else { return }
                            self.onText?(responseID,chunk.text,chunk.final)
                        }
                    }
                }
                guard self.id == current, self.modelID == responseID else { return }
                guard done else { throw CloudError.invalid }
                if toolCall.present {
                    let (name, arguments) = try toolCall.validated(allowed: allowed, finishReason: finishReason)
                    guard let execute = self.executeTool, self.id == current, self.modelID == responseID, !Task.isCancelled else { throw CloudError.invalid }
                    self.log?("Codex ツールを送信；引数／本文は記録しません。自動承認は含みません")
                    let result = await execute(name, arguments, responseID)
                    guard self.id == current, self.modelID == responseID, !Task.isCancelled else { return }
                    let addition = (text.isEmpty ? "" : "\n") + result
                    text += addition
                    for chunk in try coalescer.append(addition, now: ProcessInfo.processInfo.systemUptime) {
                        self.onText?(responseID, chunk.text, chunk.final)
                    }
                }
                guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CloudError.invalid }
                self.log?("DeepSeek ストリーム完了 characters=\(text.count) reasoningCharacters=\(reasoning) finishReason=\(finishReason)；本文はログに記録しません")
                self.history.append(["role":"user","content":String(transcript.prefix(1000))])
                self.history.append(["role":"assistant","content":String(text.prefix(1000))])
                self.history = Array(self.history.suffix(6))
                for chunk in try coalescer.append("",final:true,now:ProcessInfo.processInfo.systemUptime) {
                    guard self.id == current, self.modelID == responseID else { return }
                    self.onText?(responseID,chunk.text,chunk.final)
                }
            } catch { if self.id == current && self.modelID == responseID && !Task.isCancelled { self.fail(current,"モデルリクエストまたはストリーム応答に失敗") } }
        }
    }
    static func lensText(_ source: String) -> String {
        let text = source.trimmingCharacters(in:.whitespacesAndNewlines)
        var result = ""
        for char in text {
            let item = String(char)
            if result.utf8.count + item.utf8.count > 500 { return result + "…" }
            result += item
        }
        return result
    }
    func cancel(clearHistory: Bool = false) {
        precondition(Thread.isMainThread)
        id = nil
        modelID = nil; turns = StreamingASRTurns()
        receiver?.cancel(); sender?.cancel(); modelTask?.cancel()
        receiver = nil; sender = nil; modelTask = nil
        socket?.cancel(with:.goingAway,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        queue.removeAll(); queueBytes = 0; totalBytes = 0; parts.removeAll()
        ready = false; finishing = false; asrDone = false
        lastTranscript = ""; lastTranscriptUpdate = 0
        if clearHistory { history.removeAll() }
    }
    private func fail(_ current: UUID, _ reason: String) {
        guard id == current else { return }
        log?("クラウド経路の失敗：\(reason)；サーバー側のエラー本文は記録していません")
        cancel(); onError?(current)
    }
    private enum CloudError: Error { case invalid, remote, limit }
}
private final class NoCloudRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private extension URLSessionWebSocketTask.Message {
    static func dataJSON(_ object: [String:Any]) throws -> Self {
        .string(String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self))
    }
}
