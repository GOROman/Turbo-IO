import Foundation
import AVFoundation
import Speech

/// オンデバイス ASR パイプライン (iOS 26 SpeechAnalyzer / SpeechTranscriber, ja_JP)。
/// CloudVoicePipeline と同じコールバック面を持ち、VoiceHandshakeProbe から差し替え可能にする。
/// 音声は端末外に出ない。確定した文ごとに onTranscript(final) → onEndpoint を通知し、
/// モデル呼び出しは modelRunner (DeepSeek) に委ねる。LLM キーが無い場合は
/// 文字起こし自体を回答として表示する (onText)。
/// Main-queue owned, one round at a time. Credentials/audio/text never logged.
final class LocalSpeechPipeline {
    var log: ((String) -> Void)?
    var onEndpoint: ((UUID) -> Void)?
    var onTranscript: ((UUID, String, Bool) -> Void)?
    var onArchiveTranscript: ((UUID, String, Bool) -> Void)?
    var onText: ((UUID, String, Bool) -> Void)?
    var onError: ((UUID) -> Void)?
    var onUtteranceBegan: ((UUID, UUID) -> Void)?
    var onEmptyUtterance: ((UUID) -> Void)?
    /// 確定文をモデルへ渡す差し込み口。VoiceHandshakeProbe が CloudVoicePipeline.runModel を配線する。
    var modelRunner: ((UUID, String) -> Void)?
    /// LLM キーが無いとき true にすると、確定文をそのまま回答表示する。
    var echoTranscriptAsAnswer = false

    private(set) var id: UUID?
    private var engine: AnyObject?
    private var finished = false

    func start(id: UUID) {
        precondition(Thread.isMainThread)
        cancel()
        self.id = id
        finished = false
        guard #available(iOS 26.0, *) else { fail(id, "iOS 26 以上が必要です"); return }
        Task { @MainActor [weak self] in
            guard let self, self.id == id else { return }
            let authorized = await Self.requestAuthorization()
            guard self.id == id else { return }
            guard authorized else { self.fail(id, "音声認識の許可がありません"); return }
            let engine = SpeechAnalyzerEngine()
            engine.onPartial = { [weak self] text in
                guard let self, self.id == id, !self.finished else { return }
                self.onTranscript?(id, CloudVoicePipeline.lensText(text), false)
            }
            engine.onFinal = { [weak self] text in
                guard let self, self.id == id, !self.finished else { return }
                self.handleFinal(id: id, text: text)
            }
            engine.onFailure = { [weak self] in
                guard let self, self.id == id, !self.finished else { return }
                self.fail(id, "ローカルASRの結果取得に失敗")
            }
            self.engine = engine
            do {
                try await engine.start()
                guard self.id == id else { return }
                self.log?("ローカルASR開始 SpeechAnalyzer(ja_JP)；音声は端末外に出ません")
            } catch {
                if self.id == id { self.fail(id, "ローカルASRを開始できませんでした") }
            }
        }
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func handleFinal(id: UUID, text: String) {
        finished = true
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopEngine()
        if transcript.isEmpty {
            // cancel() は id を nil にするため、先に失敗を通知する。
            log?("ローカルASRの失敗：音声を文字起こしできませんでした")
            let failedID = id
            cancel()
            onError?(failedID)
            return
        }
        let visible = CloudVoicePipeline.lensText(transcript)
        onArchiveTranscript?(id, transcript, true)
        onTranscript?(id, visible, true)
        guard self.id == id else { return }
        log?("ローカルASRで文が確定 characters=\(transcript.count)；本文はログに記録しません")
        onEndpoint?(id)
        guard self.id == id else { return }
        if echoTranscriptAsAnswer {
            onText?(id, visible, true)
        } else {
            modelRunner?(id, transcript)
        }
    }

    func appendPCM(_ data: Data) {
        precondition(Thread.isMainThread)
        guard id != nil, !finished else { return }
        if #available(iOS 26.0, *) { (engine as? SpeechAnalyzerEngine)?.appendPCM(data) }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        id = nil
        finished = true
        stopEngine()
    }

    private func stopEngine() {
        if #available(iOS 26.0, *) { (engine as? SpeechAnalyzerEngine)?.stop() }
        engine = nil
    }

    private func fail(_ current: UUID, _ reason: String) {
        guard id == current else { return }
        log?("ローカルASRの失敗：\(reason)")
        cancel(); onError?(current)
    }
}

/// SpeechAnalyzer 本体。iOS 26 未満では生成されない。
@available(iOS 26.0, *)
private final class SpeechAnalyzerEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: (() -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var lastPartial = ""
    private var lastPartialAt = 0.0
    private var stopped = false

    private static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func start() async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "ja_JP"), preset: .progressiveTranscription)
        // 日本語アセットが未導入なら導入を試みる (失敗しても続行し、結果側で検出する)。
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        targetFormat = format
        if let format { converter = AVAudioConverter(from: Self.inputFormat, to: format) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        resultsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    if self.stopped { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.onFinal?(text)
                        return
                    } else if !text.isEmpty {
                        let now = ProcessInfo.processInfo.systemUptime
                        if text != self.lastPartial, now - self.lastPartialAt >= 0.5 {
                            self.lastPartial = text; self.lastPartialAt = now
                            self.onPartial?(text)
                        }
                    }
                }
            } catch {
                if !self.stopped { self.onFailure?() }
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func appendPCM(_ data: Data) {
        guard !stopped, !data.isEmpty, data.count % 2 == 0,
              let continuation, let converter, let targetFormat else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.inputFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        if let channel = buffer.int16ChannelData {
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress { channel[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames)) }
            }
        }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * targetFormat.sampleRate / Self.inputFormat.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        stopped = true
        continuation?.finish(); continuation = nil
        resultsTask?.cancel(); resultsTask = nil
        let analyzer = self.analyzer; self.analyzer = nil
        if let analyzer { Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() } }
    }
}
