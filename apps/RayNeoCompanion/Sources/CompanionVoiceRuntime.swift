import SwiftUI
import Combine

@MainActor final class CompanionVoiceRuntime: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var enabled = false
    @Published private(set) var phase = "disabled"
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var transcriptFinal = false
    @Published private(set) var modelComplete = false
    @Published private(set) var hasCredentials = false
    @Published private(set) var continuous = false
    @Published private(set) var cloud = false
    @Published private(set) var localASR = false
    @Published private(set) var audioLevels: [Float] = []
    @Published private(set) var latestEvent = "デバイス通信コアはまだ読み込まれていません"
    @Published var error: String?
    private let timeline: ConversationTimeline?
    weak var codex: CodexCompanion?
    private var activeTurn: UUID?
    var onBusiness: ((String, UInt8, Data) -> Void)?
    var onBusinessLoss: (() -> Void)?
    var featureIsBusy: (() -> Bool)?
    var onConnectionChange: ((String?) -> Void)?
    var onRuntimeRefresh: (() -> Void)?
    private var previousDeviceID: String?
    var deviceID: String? {
        #if COMPANION_DEVICE
        return controller.companionDeviceID
        #else
        return nil
        #endif
    }
    func sendBusiness(_ index: UInt8, payload: Data) throws {
        #if COMPANION_DEVICE
        prepare(); try controller.companionSendBusiness(index, payload: payload)
        #else
        throw DeviceFeatureError.disconnected
        #endif
    }
    func sendFile(_ url: URL, id: String) throws -> String {
        #if COMPANION_DEVICE
        return try controller.companionSendFile(url,id:id)
        #else
        throw DeviceFeatureError.disconnected
        #endif
    }
    func cancelFile(_ task: String) {
        #if COMPANION_DEVICE
        controller.companionCancelFile(task)
        #endif
    }
    init(timeline: ConversationTimeline? = nil) { self.timeline = timeline }
    deinit {
        #if COMPANION_DEVICE
        poll?.invalidate()
        #endif
    }
    #if COMPANION_DEVICE
    let controller = ProbeController()
    private var poll: Timer?
    #endif
    var supportsDevice: Bool {
        #if COMPANION_DEVICE
        return true
        #else
        return false
        #endif
    }
    var phaseLabel: String {
        ["disabled": "待機オフ", "waitingForConnection": "認証済み接続を待機中", "idle": "グラスのウェイクアップ待ち",
         "recording": "聞き取り中", "processing": "回答を生成中", "displaying": "回答の送信完了。続けて話せます"] [phase] ?? "状態待ち"
    }
    func prepare() {
        #if COMPANION_DEVICE
        guard poll == nil else { refresh(); return }
        controller.companionBusiness = { [weak self] in self?.onBusiness?($0,$1,$2) }
        controller.companionTools = { [weak self] in self?.codex?.toolDefinitions ?? [] }
        controller.companionExecuteTool = { [weak self] name, arguments, id in
            guard let codex = self?.codex else { return "Codex ツールが未設定のため、実行していません。" }
            return await codex.executeTool(name: name, arguments: arguments, requestID: id)
        }
        controller.companionBusinessLoss = { [weak self] in self?.onBusinessLoss?() }
        controller.companionLog = { [weak self] line in self?.latestEvent = String(line.prefix(200)) }
        controller.companionAudioLevel = { [weak self] level in
            guard let self else { return }
            self.audioLevels.append(level)
            if self.audioLevels.count > 56 { self.audioLevels.removeFirst(self.audioLevels.count - 56) }
        }
        controller.companionTranscript = { [weak self] id, text, final in
            guard let self, !text.isEmpty else { return }
            if self.activeTurn != id { self.finishTimelineTurn(); self.activeTurn = id }
            self.timeline?.record(ConversationEvent(id: id, kind: .transcript, text: text, final: final))
        }
        controller.companionCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .startAudio, .vadStart:
                DisplayObservation.shared.newUtterance()
                self.finishTimelineTurn()
                self.clearText()
            case .streamText(let text, let final): self.transcript = text; self.transcriptFinal = final
            case .text(let text): self.answer = text
            case .answer(let text, _, let id, _):
                self.answer = String((self.answer + text).prefix(8192))
                self.timeline?.record(ConversationEvent(id: id, kind: .answerDelta, text: text))
            case .responseComplete:
                self.modelComplete = true
                if let id = self.activeTurn { self.timeline?.record(ConversationEvent(id: id, kind: .completed)) }
            default: break
            }
        }
        controller.loadViewIfNeeded()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        poll = timer; RunLoop.main.add(timer, forMode: .common); refresh()
        #endif
    }
    func refresh() {
        #if COMPANION_DEVICE
        ready = controller.companionReady; enabled = controller.companionEnabled
        phase = controller.companionPhase; hasCredentials = CloudVoiceKeys.ready
        DisplayObservation.shared.connection(ready, phase:phase)
        if ["disabled", "waitingForConnection", "idle"].contains(phase) { finishTimelineTurn() }
        continuous = controller.companionContinuous; cloud = controller.companionCloud
        localASR = controller.companionLocalASR
        let current = deviceID
        if previousDeviceID != current { previousDeviceID = current; onConnectionChange?(current) }
        onRuntimeRefresh?()
        #endif
    }
    func discover() {
        #if COMPANION_DEVICE
        prepare(); controller.companionDiscover(); refresh()
        #endif
    }
    func connect() {
        #if COMPANION_DEVICE
        prepare(); controller.companionConnect(); refresh()
        #endif
    }
    func reconnectBonded() {
        #if COMPANION_DEVICE
        prepare(); controller.companionReconnectBonded(); refresh()
        #endif
    }
    func start(cloud: Bool, continuous: Bool) {
        start(cloud: cloud, continuous: continuous, localASR: false)
    }
    func start(cloud: Bool, continuous: Bool, localASR: Bool) {
        guard featureIsBusy?() != true else { error = "グラスの録音またはプロンプターのタスクを先に終了してから、音声待機をオンにしてください。"; return }
        #if COMPANION_DEVICE
        prepare()
        guard controller.companionStart(cloud: cloud, continuous: continuous, localASR: localASR) else {
            error = localASR ? "認証済みのグラスが1台必要です。" : "認証済みのグラスが1台必要です。クラウド会話には、このアプリ用の2つのキーも必要です。"; refresh(); return
        }
        refresh()
        #endif
    }
    func stop() {
        #if COMPANION_DEVICE
        controller.companionStop(); refresh()
        #endif
    }
    func endRound() {
        #if COMPANION_DEVICE
        controller.companionEndRound(); refresh()
        #endif
    }
    func saveKeys(asr: String, llm: String, host: String, enableDefault: Bool = false) -> Bool {
        #if COMPANION_DEVICE
        guard !enabled else { error = "先に待機をオフにしてから、クラウド資格情報を変更してください。"; return false }
        guard let target = CloudASRHostSettings.normalize(host) else { error = "ご自身の Alibaba Cloud ASR ホスト名（aliyuncs.com）を入力してください。プロトコル、パス、ポートは含めません。"; return false }
        let service = CloudASRHostSettings.service(for: target)
        let a = asr.isEmpty ? CloudVoiceKeys.get(service) != nil : CloudVoiceKeys.save(asr, service: service)
        let b = llm.isEmpty ? CloudVoiceKeys.get(CloudVoiceKeys.llmService) != nil : CloudVoiceKeys.save(llm, service: CloudVoiceKeys.llmService)
        if a && b {
            CloudASRHostSettings.save(target)
            if enableDefault { controller.companionEnableDefaultCloudVoice() }
        }
        refresh()
        if !a || !b { error = "キーを完全に保存できませんでした。クラウドアップロードは有効化していません。" }
        return a && b
        #else
        error = "シミュレータは実機の音声資格情報を保存しません。"; return false
        #endif
    }
    func clearText() { transcript = ""; answer = ""; transcriptFinal = false; modelComplete = false; audioLevels = [] }
    private func finishTimelineTurn() {
        if let id = activeTurn { timeline?.record(ConversationEvent(id: id, kind: .interrupted)); activeTurn = nil }
    }
}

#if COMPANION_DEVICE
struct VoiceDiagnosticsView: UIViewControllerRepresentable {
    let runtime: CompanionVoiceRuntime
    func makeUIViewController(context: Context) -> ProbeController { runtime.prepare(); return runtime.controller }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}
}
#endif
