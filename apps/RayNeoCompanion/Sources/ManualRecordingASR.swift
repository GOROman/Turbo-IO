import Foundation
import AVFoundation
import Combine
import SwiftUI

enum RecordingASRError: LocalizedError {
    case unsupported, limit, credentials, remote, empty
    var errorDescription: String? {
        switch self {
        case .unsupported: return "この音声は iOS でデコードできません。有効な WAV・M4A・MP3 などシステム対応形式を使ってください。グラスの元のコンテナは追加変換が必要な場合があります。"
        case .limit: return "手動文字起こしは当面、音声10分 / デコード PCM 32 MiB までです。"
        case .credentials: return "まず実機の音声ページで Alibaba Cloud ASR のキーを保存してください。シミュレータは実際の音声サービスを呼びません。"
        case .remote: return "ASR の接続・タイムアウト・プロトコルのいずれかが失敗しました。成功した文字起こしとしては保存していません。再試行できます。"
        case .empty: return "ASR から有効な最終テキストが返らなかったため、空のノートは作っていません。"
        }
    }
}

enum RecordingPCMDecoder {
    static func decode(_ url: URL, inputChannel: Int? = nil, diagnostic: (String) -> Void = { _ in }) throws -> Data {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { diagnostic("open-failed"); throw RecordingASRError.unsupported }
        let format = input.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, input.length > 0,
              format.channelCount > 0, format.channelCount <= 32,
              Double(input.length) / format.sampleRate <= 600 else { throw RecordingASRError.limit }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { diagnostic("converter-init-failed"); throw RecordingASRError.unsupported }
        if let channel = inputChannel {
            guard channel >= 0, channel < Int(format.channelCount) else { throw RecordingASRError.unsupported }
        }
        var pcm = Data(), failed = false
        for _ in 0..<10_000 {
            try Task.checkCancellation()
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { requested, status in
                do {
                    let remaining = input.length - input.framePosition
                    guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                    let count = min(requested, source.frameCapacity, AVAudioFrameCount(min(remaining, Int64(UInt32.max))))
                    try input.read(into: source, frameCount: count)
                    try mixToMono(source, into: mono, inputChannel: inputChannel)
                    status.pointee = source.frameLength == 0 ? .endOfStream : .haveData
                    return source.frameLength == 0 ? nil : mono
                } catch { failed = true; status.pointee = .endOfStream; return nil }
            }
            guard !failed, error == nil, result != .error else { diagnostic("convert-failed read=\(failed) status=\(result.rawValue) code=\(error?.code ?? 0)"); throw RecordingASRError.unsupported }
            if output.frameLength > 0, let samples = output.int16ChannelData {
                guard pcm.count + Int(output.frameLength) * 2 <= 32 * 1_024 * 1_024 else { throw RecordingASRError.limit }
                pcm.append(UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: Int(output.frameLength) * 2)
            }
            if result == .endOfStream {
                guard !pcm.isEmpty else { throw RecordingASRError.empty }
                return pcm
            }
        }
        throw RecordingASRError.limit
    }

    /// Explicit equal-weight downmix before resampling. AVAudioConverter's
    /// default channel mapping can select channel 0 instead of mixing stereo.
    /// Average rather than sum so full-scale in-phase channels cannot overflow.
    private static func mixToMono(_ source: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer, inputChannel: Int?) throws {
        guard let input = source.floatChannelData, let output = mono.floatChannelData,
              source.frameLength <= mono.frameCapacity else { throw RecordingASRError.unsupported }
        let channels = Int(source.format.channelCount)
        let selected = inputChannel.map { $0..<($0 + 1) } ?? (0..<channels)
        for frame in 0..<Int(source.frameLength) {
            var sum = 0.0
            for channel in selected {
                let value = Double(input[channel][frame])
                guard value.isFinite else { throw RecordingASRError.unsupported }
                sum += value
            }
            output[0][frame] = Float(max(-1, min(1, sum / Double(selected.count))))
        }
        mono.frameLength = source.frameLength
    }
}

struct FileASRAccumulator {
    private var sentences: [Int: String] = [:]
    mutating func accept(id: Int, text: String, final: Bool) throws {
        guard id >= 0, id <= 100_000, text.utf8.count <= 16_384 else { throw RecordingASRError.remote }
        guard final else { return }
        guard sentences.count < 6_000 || sentences[id] != nil else { throw RecordingASRError.limit }
        sentences[id] = text
        guard sentences.values.reduce(0, { $0 + $1.utf8.count }) <= 1_024 * 1_024 else { throw RecordingASRError.limit }
    }
    var text: String { sentences.keys.sorted().compactMap { sentences[$0] }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

private final class FileASRNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Explicit per-run local capture. No headers; redact the configured secret if
/// it is unexpectedly echoed by a remote error. The source recording is untouched.
final class FileASRDiagnostic {
    let directory: URL
    private let secret: String
    private let handle: FileHandle
    private var size = 0
    init(root: URL, pcm: Data, secret: String) throws {
        self.secret = secret
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try pcm.write(to: directory.appendingPathComponent("sent-16000-mono-s16le.pcm"), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        let events = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: events.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw RecordingASRError.remote }
        handle = try FileHandle(forWritingTo: events)
    }
    deinit { try? handle.close() }
    func record(_ event: String, _ body: String) throws {
        let safe = secret.isEmpty ? body : body.replacingOccurrences(of: secret, with: "[REDACTED]")
        var line = try JSONSerialization.data(withJSONObject: ["time": Date().timeIntervalSince1970, "event": event, "body": safe], options: [.sortedKeys])
        line.append(10)
        guard size + line.count <= 2_097_152 else { throw RecordingASRError.limit }
        try handle.write(contentsOf: line); try handle.synchronize()
        size += line.count
    }
}

@MainActor enum FileASRClient {
    // DashScope controls are UTF-8 text frames; only PCM is binary.
    static func controlMessage(_ object: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    static func transcribe(pcm: Data, key: String, host: String, diagnostic: FileASRDiagnostic? = nil, progress: @escaping (Double) -> Void) async throws -> String {
        guard let host = CloudASRHostSettings.normalize(host) else { throw RecordingASRError.credentials }
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 32 * 1_024 * 1_024 else { throw RecordingASRError.limit }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 660
        let session = URLSession(configuration: config, delegate: FileASRNoRedirect(), delegateQueue: nil)
        // The caller captures this host with its host-scoped credential before decoding.
        var request = URLRequest(url: URL(string: "wss://\(host)/api-ws/v1/inference")!)
        request.setValue("bearer " + key, forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: request); ws.maximumMessageSize = 65_536
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var sender: Task<Void, Error>?
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(Double(pcm.count) / 32_000 + 40) * 1_000_000_000)
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel(); sender?.cancel(); ws.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        ws.resume()
        return try await withTaskCancellationHandler {
            let run: [String: Any] = ["header": ["action": "run-task", "task_id": id, "streaming": "duplex"],
                "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": "qwen-audio-3.0-asr-flash-streaming",
                            "parameters": ["format": "pcm", "sample_rate": 16000], "input": [:]]]
            try diagnostic?.record("run-task", String(decoding: JSONSerialization.data(withJSONObject: run), as: UTF8.self))
            try await ws.send(controlMessage(run))
            var accumulator = FileASRAccumulator(), sentAll = false, events = 0
            while !Task.isCancelled {
                let message = try await ws.receive()
                let data: Data
                switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: throw RecordingASRError.remote }
                try diagnostic?.record("received", String(decoding: data, as: UTF8.self))
                events += 1
                guard events <= 30_000, data.count <= 65_536,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let header = object["header"] as? [String: Any], header["task_id"] as? String == id else { throw RecordingASRError.remote }
                switch header["event"] as? String {
                case "task-started":
                    guard sender == nil else { throw RecordingASRError.remote }
                    sender = Task { @MainActor in
                        do {
                            for offset in stride(from: 0, to: pcm.count, by: 3200) {
                                try Task.checkCancellation()
                                let end = min(pcm.count, offset + 3200)
                                try await ws.send(.data(pcm.subdata(in: offset..<end)))
                                progress(Double(end) / Double(pcm.count))
                                try await Task.sleep(nanoseconds: 100_000_000)
                            }
                            sentAll = true
                            try diagnostic?.record("sent-audio", "bytes=\(pcm.count) sample_rate=16000 channels=1 format=s16le")
                            try await ws.send(controlMessage(["header": ["action": "finish-task", "task_id": id, "streaming": "duplex"], "payload": ["input": [:]]]))
                        } catch { ws.cancel(with: .goingAway, reason: nil); throw error }
                    }
                case "result-generated":
                    if let payload = object["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                       let sentence = output["sentence"] as? [String: Any], sentence["heartbeat"] as? Bool != true,
                       let number = sentence["sentence_id"] as? NSNumber, number.doubleValue == Double(number.intValue),
                       let text = sentence["text"] as? String {
                        try accumulator.accept(id: number.intValue, text: text, final: sentence["sentence_end"] as? Bool == true)
                    }
                case "task-finished":
                    guard sentAll else { throw RecordingASRError.remote }
                    try await sender?.value
                    let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    try diagnostic?.record("parsed-final", "characters=\(text.count)")
                    guard !text.isEmpty else { throw RecordingASRError.empty }
                    return text
                case "task-failed": throw RecordingASRError.remote
                default: break
                }
            }
            throw CancellationError()
        } onCancel: { ws.cancel(with: .goingAway, reason: nil) }
    }
}

@MainActor final class ManualRecordingASR: ObservableObject {
    @Published private(set) var recordingID: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var resultText = ""
    @Published private var work: Task<Void, Never>?
    var busy: Bool { work != nil }
    func cancel() { work?.cancel(); status = "キャンセル中です。元の音声は保持します…" }
    func start(id: UUID, title: String, archive: LocalArchiveController, captureDiagnostic: Bool = false, rightChannelOnly: Bool = false) {
        guard work == nil else { return }
        recordingID = id; progress = 0; resultText = ""
        #if COMPANION_DEVICE
        guard let host = CloudASRHostSettings.normalize(CloudVoiceKeys.asrHost),
              let key = CloudVoiceKeys.get(CloudASRHostSettings.service(for: host)) else { status = RecordingASRError.credentials.localizedDescription; return }
        work = Task { @MainActor in
            defer { work = nil }
            var diagnostic: FileASRDiagnostic?
            do {
                status = "本機の音声を検証中…"
                guard let url = await archive.verify(id) else { throw RecordingASRError.unsupported }
                try Task.checkCancellation()
                status = "本機で 16 kHz モノラルへデコード中…"
                let decoder = Task.detached(priority: .userInitiated) { try RecordingPCMDecoder.decode(url, inputChannel: rightChannelOnly ? 1 : nil) }
                let pcm = try await withTaskCancellationHandler { try await decoder.value } onCancel: { decoder.cancel() }
                try Task.checkCancellation()
                if captureDiagnostic {
                    let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    diagnostic = try FileASRDiagnostic(root: root.appendingPathComponent("ManualASRDiagnosticsV1"), pcm: pcm, secret: key)
                    try diagnostic?.record("source", "recording=\(id.uuidString) decodedBytes=\(pcm.count) channel=\(rightChannelOnly ? "right-only" : "equal-weight-downmix")")
                }
                status = "手動文字起こし中。音声を Alibaba Cloud へ送信しています…"
                let text = try await FileASRClient.transcribe(pcm: pcm, key: key, host: host, diagnostic: diagnostic) { value in self.progress = value }
                try Task.checkCancellation()
                resultText = text
                status = "新しいテキストリビジョンを保存中…"
                guard await archive.saveTranscript(recordingID: id, text: text, title: String(("ASR · " + title).prefix(64))) != nil else {
                    status = "認識は完了しましたがノートは保存されませんでした。下のテキストをコピーできます。元の音声は保持します。"; return
                }
                status = "文字起こし完了。新しい Markdown リビジョンとして保存しました。認識内容を確認してください。"
            } catch is CancellationError { status = "後続処理をキャンセルしました。元の音声と送信済みリビジョンは保持します。" }
            catch {
                try? diagnostic?.record("client-error", "domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription)")
                status = (error as? RecordingASRError)?.localizedDescription ?? "文字起こしが完了しませんでした。ネットワーク切断またはキャンセルの可能性があります。元の音声は保持します。"
            }
        }
        #else
        status = RecordingASRError.credentials.localizedDescription
        #endif
    }
}

struct ManualRecordingASRView: View {
    let id: UUID, title: String
    @EnvironmentObject private var asr: ManualRecordingASR
    @EnvironmentObject private var archive: LocalArchiveController
    @State private var confirmation = false
    @State private var captureDiagnostic = false
    @State private var rightChannelOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("録音を文字起こし").font(.headline)
            Text("確認した場合にのみ、この本機音声を Alibaba Cloud ASR へ送信します。音声の長さに応じてストリーミング送信し、課金される場合があります。DeepSeek は不要で、自動要約もしません。成功するとテキストリビジョンを新規追加し、元の音声や旧稿は上書きしません。")
                .font(.caption).foregroundStyle(Palette.muted)
            Text("文字起こし中は App をフォアグラウンドに保ってください。長時間のバックグラウンド完了は未検証です。").font(.caption2).foregroundStyle(Palette.muted)
            Text("デフォルトでは全チャンネルをミックスして16kHzモノラルへ変換します。元の録音は保持し、音声は上書きしません。").font(.caption2).foregroundStyle(Palette.muted)
            Toggle("次回のみ ASR 診断を保存", isOn: $captureDiagnostic).disabled(asr.busy).accessibilityIdentifier("manual-asr-diagnostic")
            if captureDiagnostic { Text("今回送信する音声とサーバー応答（文字起こし本文を含む場合があります）を追加で保存します。保存先は本機のみ。リクエストヘッダーやキーは記録しません。").font(.caption2) }
            if captureDiagnostic {
                Toggle("診断：今回のみ右チャンネルを使用", isOn: $rightChannelOnly).disabled(asr.busy).accessibilityIdentifier("manual-asr-right-channel")
            }
            Button("ASR 文字起こしを手動で開始") { confirmation = true }.disabled(asr.busy || archive.isBusy).accessibilityIdentifier("manual-recording-asr")
            if asr.recordingID == id {
                Text(asr.status).font(.caption)
                if asr.busy { ProgressView(value: asr.progress); Button("文字起こしをキャンセル") { asr.cancel() } }
                if !asr.resultText.isEmpty { Text(asr.resultText).font(.caption).textSelection(.enabled).privacySensitive() }
            } else if asr.busy { Text("別の録音を文字起こし中です。完了してからお試しください。").font(.caption) }
        }.confirmationDialog("この録音を Alibaba Cloud ASR へ送信しますか？課金される場合があり、認識結果は目視確認が必要です。", isPresented: $confirmation) {
            Button("アップロードして文字起こしを確定") {
                let capture = captureDiagnostic, right = captureDiagnostic && rightChannelOnly
                captureDiagnostic = false; rightChannelOnly = false
                asr.start(id: id, title: title, archive: archive, captureDiagnostic: capture, rightChannelOnly: right)
            }
        }
    }
}
