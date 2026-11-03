import UIKit
import CoreBluetooth
import ExternalAccessory
import RayNeoProtocol

#if !COMPANION_DEVICE
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
#endif

final class ProbeController: UIViewController, CBCentralManagerDelegate, StreamDelegate {
    private let output = UITextView(usingTextLayoutManager: false)
    private var core: CoreHandle?
    private var central: CBCentralManager?
    private var seen = Set<UUID>()
    private var scanRequested = false
    private var devices: [UUID: CBPeripheral] = [:]
    private var eaSession: EASession?
    private var sdkDeviceIDs = Set<String>()
    private var parsedAdvertisements = Set<UUID>()
    private var sdkPeripherals: [UUID: NSObject] = [:]
    private var logLines: [String] = []
    private var renderPending = false
    private var modelCatalog: [String: Any]?
    private var messageReceiver: CoreMessageReceiver?
    private let voiceProbe = VoiceHandshakeProbe()
    private var standbyTimer: Timer?
    private var standbyButton: UIButton?
    private var reconnectPolicy = StandbyReconnectPolicy()
    private var standbyWasReady = false
    private var nextWakeInit: TimeInterval = 0
    private var standbyLifecycle: NSObjectProtocol?
    private let standbyPreferenceKey = "syntheticStandbyTarget.v1"

    #if COMPANION_DEVICE
    private var deviceConnectionTimer: Timer?
    private var deviceConnectionPolicy = BondedConnectionPolicy()
    // Thin host adapter: shared proven engine, no duplicate protocol implementation.
    var companionCommand: ((StandbyVoiceSession.Command) -> Void)?
    var companionTranscript: ((UUID,String,Bool) -> Void)?
    var companionLog: ((String) -> Void)?
    var companionBusiness: ((String, UInt8, Data) -> Void)?
    var companionBusinessLoss: (() -> Void)?
    var companionDeviceID: String? { companionReady ? core?.linkedDevices()?.first?.deviceID() : nil }
    func companionSendFile(_ url: URL, id: String) throws -> String {
        guard companionReady, RNProbeMessageImageMatches(), let device = companionDeviceID,
              let task = core?.shareFile(url, device, 0, id), !task.isEmpty else {
            throw NSError(domain: "CompanionFileSend", code: 1)
        }
        return task
    }
    func companionCancelFile(_ task: String) {
        guard companionReady, let device = companionDeviceID else { return }
        core?.cancelShare(device, task)
    }
    func companionSendBusiness(_ index: UInt8, payload: Data) throws {
        guard companionReady, let core, let target = companionDeviceID,
              let business = MessageBusinessIndex(rawValue: index), [13,14,15,20,21,22].contains(index) else {
            throw NSError(domain: "CompanionBusinessConnection", code: 1)
        }
        if index == 13 {
            let meta = try BusinessEnvelopeMetadata.inspect(payload)
            guard let type = meta.messageType, [162,166,168].contains(type) else {
                throw NSError(domain: "CompanionAlwaysOnCommand", code: 1)
            }
        }
        try core.sendMessage(MessageFactory.make(payload: payload, deviceID: target, business: business, messageID: UUID().uuidString))
        DisplayObservation.shared.packet(payload,business:index,inbound:false)
    }
    func companionDiscover() { loadViewIfNeeded(); loadCore(); sdkDiscovery(); scan() }
    var companionTools: (() -> [[String: Any]])?
    var companionExecuteTool: ((String, String, UUID) async -> String)?
    func companionConnect() { loadViewIfNeeded(); connectSDK() }
    func companionReconnectBonded() {
        loadViewIfNeeded()
        deviceConnectionPolicy.resetBudget()
        startDeviceConnectionMaintenance()
        if companionReady { log("紐づけ済みのグラスは認証接続済みです。再接続は不要です") }
    }
    private func startDeviceConnectionMaintenance() {
        if core == nil { loadCore() }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if deviceConnectionTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.deviceConnectionTick() }
            deviceConnectionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            log("デバイス接続の維持を開始しました：音声とは独立に、本 App の唯一の既存バインドにのみ再接続します")
        }
        deviceConnectionTick()
    }
    private func deviceConnectionTick() {
        guard let core else { return }
        // Re-read SDK objects on every attempt; never retain a stale handle.
        let bonded = core.bondedDevices() ?? []
        let linked = core.linkedDevices() ?? []
        let candidate = bonded.count == 1
            ? (linked.first(where: { $0.deviceID() == bonded[0].deviceID() }) ?? bonded[0]) : nil
        let peripheralState = candidate?.transport().rnSDKPeripheral()?.state
        let busy = peripheralState.map { $0 != .disconnected } ?? false
        guard let target = deviceConnectionPolicy.reconnectTarget(
            now: ProcessInfo.processInfo.systemUptime,
            bonded: bonded.map { $0.deviceID() }, linked: linked.map { $0.deviceID() },
            authenticated: companionReady, bluetoothOn: central?.state == .poweredOn,
            transportBusy: busy), let candidate, candidate.deviceID() == target else { return }
        do {
            try core.connectBLE(candidate)
            log("独立デバイス再接続 attempt=\(deviceConnectionPolicy.attempts)/8；音声/録音を開始せず、認証を待機中")
        } catch { log("独立デバイス再接続の送信に失敗；バインドを保持してバックオフします") }
        if deviceConnectionPolicy.attempts == 8 {
            log("今回のデバイス再接続の試行枠を使い切りました；フォアグラウンド復帰、Bluetooth の復旧、または手動再接続で再試行できます。自動で再ペアリングはしません")
        }
    }
    var companionReady: Bool {
        let linked = core?.linkedDevices() ?? []
        return linked.count == 1 && linked[0].isConnected() && linked[0].bleStateByte() == 9
    }
    var companionPhase: String { voiceProbe.standby.phase.rawValue }
    var companionEnabled: Bool { voiceProbe.standby.enabled }
    var companionContinuous: Bool { voiceProbe.standby.continuousASREnabled }
    var companionCloud: Bool { voiceProbe.standby.cloudEnabled }
    var companionLocalASR: Bool { voiceProbe.localASREnabled }
    func companionStart(cloud: Bool, continuous: Bool) -> Bool {
        companionStart(cloud: cloud, continuous: continuous, localASR: false)
    }
    func companionStart(cloud: Bool, continuous: Bool, localASR: Bool) -> Bool {
        loadViewIfNeeded()
        guard companionReady, let device = core?.linkedDevices()?.first,
              !cloud || CloudVoiceKeys.ready else { return false }
        UserDefaults.standard.set(true, forKey: "companion.autoVoice.v1")
        voiceProbe.setCloudMode(cloud || localASR)
        if localASR { voiceProbe.setLocalASRMode(true) }
        UserDefaults.standard.set(cloud, forKey: CloudVoiceKeys.enabledKey)
        UserDefaults.standard.set(localASR, forKey: "companion.localASR.v1")
        UserDefaults.standard.set(continuous && cloud, forKey: "companion.continuousASR.v1")
        UserDefaults.standard.set(device.deviceID(), forKey: standbyPreferenceKey)
        startStandby(target: device.deviceID())
        if cloud && continuous { voiceProbe.setContinuousASR(true) }
        return true
    }
    func companionStop() {
        UserDefaults.standard.set(false, forKey: "companion.autoVoice.v1")
        disableStandby()
    }
    func companionEnableDefaultCloudVoice() {
        guard CloudVoiceKeys.ready else { return }
        UserDefaults.standard.set(true, forKey: "companion.autoVoice.v1")
        UserDefaults.standard.set(true, forKey: CloudVoiceKeys.enabledKey)
        UserDefaults.standard.set(false, forKey: "companion.localASR.v1")
        UserDefaults.standard.set(true, forKey: "companion.continuousASR.v1")
        companionRestoreAutomaticVoice()
    }
    private func companionRestoreAutomaticVoice() {
        let localASRDefault = UserDefaults.standard.bool(forKey: "companion.localASR.v1")
        guard !voiceProbe.standby.enabled, CloudVoiceKeys.ready || localASRDefault,
              UserDefaults.standard.bool(forKey: "companion.autoVoice.v1") else { return }
        loadCore()
        guard let bonded = core?.bondedDevices(), bonded.count == 1 else {
            log("自動音声は許可済み；唯一の紐づけ済みグラスを待機中。自動ペアリングやバインドの奪取はしません"); return
        }
        let target = bonded[0].deviceID()
        let cloudDefault = UserDefaults.standard.bool(forKey: CloudVoiceKeys.enabledKey)
        voiceProbe.setCloudMode(cloudDefault || localASRDefault)
        if localASRDefault { voiceProbe.setLocalASRMode(true) }
        UserDefaults.standard.set(target, forKey: standbyPreferenceKey)
        startStandby(target: target)
        if voiceProbe.standby.cloudEnabled, !localASRDefault {
            voiceProbe.setContinuousASR(UserDefaults.standard.bool(forKey: "companion.continuousASR.v1"))
        }
        log("ユーザーのデフォルト音声待機を復元；ウェイクアップ後のみ収音し、紐づけ済みの対象へ自動再接続します")
    }
    func companionEndRound() { voiceProbe.standby.cancelCurrentRound() }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = "RayNeo Core Probe"
        title.font = .preferredFont(forTextStyle: .title1)
        stack.addArrangedSubview(title)
        for (title, action) in [("1 · コアを読み込む／状態を更新", #selector(loadCore)), ("2 · BLE を読み取り専用で検出", #selector(scan)), ("3 · MFi セッションを確認", #selector(accessories)), ("4 · SDK 検出", #selector(sdkDiscovery)), ("5 · SDK BLE 接続を検証", #selector(connectSDK)), ("6 · 紐づけ解除（グラスのデータを消去）", #selector(confirmUnbind)), ("7 · 表示境界テスト／終了", #selector(showDisplayBoundaryTests)), ("8 · 音声ウェイクアップを有効化", #selector(confirmVoiceWakeup)), ("9 · 継続待機：オフ", #selector(toggleStandby)), ("10 · クラウド対話／キー設定",#selector(showCloudSettings))] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.addTarget(self, action: action, for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
            if title.hasPrefix("9 ·") { standbyButton = button }
        }
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(output)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        log("独立 Bundle / 独立サンドボックス\nHook なし、SSH なし、脱獄呼び出しなし\nBLE 状態 9 のみが authSuccess；通常の接続は認証成功とはみなしません。")
        log("旧 getBTState 入口は実際にパケットを送信しないことを確認済みのため、業務インターフェースとしては表示しません。")
        RNProbeSetLogSink { [weak self] line in self?.log(line) }
        voiceProbe.log = { [weak self] in self?.log($0) }
        #if COMPANION_DEVICE
        voiceProbe.onSubmittedCommand = { [weak self] in self?.companionCommand?($0) }
        voiceProbe.onArchiveTranscript = { [weak self] id, text, final in self?.companionTranscript?(id,text,final) }
        voiceProbe.cloudTools = { [weak self] in self?.companionTools?() ?? [] }
        voiceProbe.executeCloudTool = { [weak self] name, args, id in
            guard let execute = self?.companionExecuteTool else { return "Codex が未設定のため、実行しませんでした。" }
            return await execute(name, args, id)
        }
        #endif
        voiceProbe.setCloudMode(UserDefaults.standard.bool(forKey:CloudVoiceKeys.enabledKey) && CloudVoiceKeys.ready)
        voiceProbe.send = { [weak self] deviceID, payload in
            guard let core = self?.core, let linked = core.linkedDevices(), linked.count == 1,
                  let device = linked.first, device.deviceID() == deviceID,
                  device.isConnected(), device.bleStateByte() == 9 else {
                throw NSError(domain:"VoiceProbeConnection", code:1)
            }
            try core.sendMessage(MessageFactory.make(payload:payload, deviceID:deviceID,
                business:.voiceAssistant, messageID:UUID().uuidString))
            #if COMPANION_DEVICE
            DisplayObservation.shared.packet(payload,business:13,inbound:false)
            #endif
        }
        standbyLifecycle = NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,
            object:nil, queue:.main) { [weak self] _ in
                #if COMPANION_DEVICE
                self?.deviceConnectionPolicy.resetBudget()
                self?.startDeviceConnectionMaintenance()
                #endif
                self?.standbyTick()
            }
        DispatchQueue.main.async { [weak self] in
            #if COMPANION_DEVICE
            self?.startDeviceConnectionMaintenance()
            #endif
            self?.restoreStandbyIfRequested()
        }
    }

    deinit {
        #if COMPANION_DEVICE
        deviceConnectionTimer?.invalidate()
        #endif
        standbyTimer?.invalidate()
        if let standbyLifecycle { NotificationCenter.default.removeObserver(standbyLifecycle) }
    }

    @objc private func toggleStandby() {
        if voiceProbe.standby.enabled { disableStandby(); return }
        guard let linked = core?.linkedDevices(), linked.count == 1, let device = linked.first,
              device.isConnected(), device.bleStateByte() == 9 else {
            log("継続待機を有効化するには唯一の認証済みデバイスが必要です。先に接続してください"); return
        }
        let target = device.deviceID()
        let message = voiceProbe.standby.cloudEnabled
            ? "現在はクラウド対話です：ウェイクアップ後の音声は指定済みの Alibaba Cloud スペースへ送信され、認識テキストは DeepSeek Flash へ送られます（思考オフ/ストリーミング）。文末はクラウド側で判定；ローカル側は無音5秒/収音20秒/処理30秒の保護があります。TTS なし、ツール実行なし。ログに本文は記録しません。サービスは課金される場合があります。App を再起動するとスイッチが復元します。ボタン9でオフにします。"
            : "実際のウェイクアップのたびに、本機でデコードと音声検出を行います；約0.9秒間無音が続くとランダムなテキストで返信し、10秒間表示した後に待機します。5秒間無音で終了し、収音は最長8秒です。認識やモデルによる回答ではありません。音声は保存/アップロードしません。バックグラウンド処理は許可しますが、システムにより中断される場合があります。紐づけ済みのグラスへの限定的な再接続のみを行い、自動ペアリングやリセットはしません。App を再起動するとスイッチが復元します。ボタン9でオフにします。"
        let alert = UIAlertController(title:"継続待機を有効化しますか？", message:message, preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"キャンセル", style:.cancel))
        alert.addAction(UIAlertAction(title:"継続待機を有効化", style:.default) { [weak self] _ in
            guard let self, let linked = self.core?.linkedDevices(), linked.count == 1,
                  let current = linked.first, current.deviceID() == target,
                  current.isConnected(), current.bleStateByte() == 9 else { return }
            UserDefaults.standard.set(target, forKey:self.standbyPreferenceKey)
            self.startStandby(target:target)
        })
        present(alert, animated:true)
    }
    @objc private func showCloudSettings() {
        let controller = CloudVoiceSettingsController()
        controller.changed = { [weak self] enabled in
            self?.voiceProbe.setCloudMode(enabled)
            self?.standbyTick()
        }
        present(controller,animated:true)
    }

    private func restoreStandbyIfRequested() {
        #if COMPANION_DEVICE
        companionRestoreAutomaticVoice()
        if voiceProbe.standby.enabled { return }
        #endif
        guard let target = UserDefaults.standard.string(forKey:standbyPreferenceKey) else { return }
        loadCore()
        guard let matches = core?.bondedDevices()?.filter({ $0.deviceID() == target }), matches.count == 1 else {
            UserDefaults.standard.removeObject(forKey:standbyPreferenceKey)
            log("旧継続サービスの対象は既に紐づけられていないため、復元せず、自動ペアリングもしません"); return
        }
        log("保存済みのユーザースイッチに基づき継続サービスを復元；システムが App を自動起動できることを意味しません")
        startStandby(target:target)
        #if COMPANION_DEVICE
        if voiceProbe.standby.cloudEnabled, UserDefaults.standard.bool(forKey: "companion.continuousASR.v1") {
            voiceProbe.setContinuousASR(true)
        }
        #endif
    }

    private func startStandby(target: String) {
        reconnectPolicy.reset(); standbyWasReady = false; nextWakeInit = 0
        voiceProbe.enableStandby(deviceID:target)
        if central == nil { central = CBCentralManager(delegate:self, queue:.main) }
        standbyTimer?.invalidate()
        let timer = Timer(timeInterval:0.5, repeats:true) { [weak self] _ in self?.standbyTick() }
        standbyTimer = timer
        RunLoop.main.add(timer, forMode:.common)
        standbyTick()
    }

    private func disableStandby() {
        UserDefaults.standard.removeObject(forKey:standbyPreferenceKey)
        voiceProbe.standby.disable()
        standbyTimer?.invalidate(); standbyTimer = nil
        standbyWasReady = false
        standbyButton?.setTitle("9 · 継続待機：オフ", for:.normal)
        #if COMPANION_DEVICE
        log("音声待機はオフになりました。自動応答はしません；デバイスの独立再接続は維持し、グラスのウェイクアップスイッチ/バインドは変更していません")
        #else
        log("継続サービスはオフになりました。自動応答や再接続はしません；グラスのウェイクアップスイッチ/バインドは変更していません")
        #endif
    }

    private func standbyTick() {
        guard let target = voiceProbe.standby.target, let core else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let linked = core.linkedDevices() ?? []
        let ready = linked.count == 1 && linked.first?.deviceID() == target
            && linked.first?.isConnected() == true && linked.first?.bleStateByte() == 9
        // Retain no credential or stale RNDevice handle. Resolve each time.
        guard let bonded = core.bondedDevices()?.filter({ $0.deviceID() == target }), bonded.count == 1 else {
            log("継続サービスの対象がバインド一覧にないため、安全にオフにしました；再バインドはしません")
            disableStandby(); return
        }
        voiceProbe.standby.connection(ready)
        if ready {
            reconnectPolicy.reset()
            if !standbyWasReady && now >= nextWakeInit {
                nextWakeInit = now + 5
                do {
                    let payload = try LauncherControlPrototype.encode(.enableVoiceWakeup)
                    try core.sendMessage(MessageFactory.make(payload:payload, deviceID:target,
                        business:.launcher, messageID:UUID().uuidString))
                    standbyWasReady = true
                    log("継続サービスの接続準備が完了し、ウェイクアップ初期化を送信しました；グラスからの true 応答は別途確認します")
                } catch { log("継続サービスの初期化送信に失敗。5秒後に再確認します") }
            }
        } else {
            if standbyWasReady { log("継続サービスが唯一の認証済み接続を失いました；今回のラウンドを一時停止し、再接続の意図は保持します") }
            standbyWasReady = false
            #if !COMPANION_DEVICE
            // Existing bond only; never steal another active target or race an
            // already connecting peripheral. SDK owns its background heartbeat.
            let candidate = linked.first(where:{ $0.deviceID() == target }) ?? bonded[0]
            let eligible = linked.allSatisfy({ $0.deviceID() == target }) && central?.state == .poweredOn
                && candidate.transport().rnSDKPeripheral()?.state == .disconnected
            if reconnectPolicy.shouldAttempt(now:now, eligible:eligible) {
                do {
                    try core.connectBLE(candidate)
                    log("継続サービス：紐づけ済みの対象へ再接続 attempt=\(reconnectPolicy.attempts)/8；認証成功ではありません")
                } catch { log("継続サービスの再接続送信に失敗；上限付きでバックオフし、デバイスはリセットしません") }
                if reconnectPolicy.attempts == 8 { log("今回の再接続の試行枠を使い切りました；SDK がまだ復旧していない場合は、継続サービスをオフにしてから再度オンにしてください") }
            }
            #endif
        }
        voiceProbe.standby.tick(now:now)
        let labels: [StandbyVoiceSession.Phase:String] = [.disabled:"オフ", .waitingForConnection:"接続待機中", .idle:"ウェイクアップ待機中", .recording:"収音中", .processing:"クラウド回答中", .displaying:"表示中"]
        standbyButton?.setTitle("9 · 継続待機：\(labels[voiceProbe.standby.phase] ?? "不明")", for:.normal)
    }

    private func log(_ text: String) {
        #if COMPANION_DEVICE
        companionLog?(text)
        #endif
        logLines.append(text)
        if logLines.count > 100 { logLines.removeFirst(logLines.count - 100) }
        // Bound the visible buffer; full privacy-filtered output also goes to
        // NSLog. Avoid a growing accessibility text tree during live tests.
        NSLog("[CoreProbe] %@", text)
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.output.text = self.logLines.suffix(28).map { String($0.prefix(180)) }.joined(separator: "\n")
            self.output.layoutIfNeeded()
            self.output.setContentOffset(CGPoint(x: 0, y: max(0, self.output.contentSize.height - self.output.bounds.height)), animated: false)
        }
    }

    @objc private func loadCore() {
        guard RNProbeMessageImageMatches() else { log("SDK のバージョンが一致しないため、読み込みを拒否しました"); return }
        log("SDK version: \(coreVersion() ?? "nil")")
        core = coreShared()
        if messageReceiver == nil {
            let receiver = CoreMessageReceiver()
            receiver.onMetadata = { [weak self] in self?.log($0) }
            #if COMPANION_DEVICE
            receiver.onBusinessEnvelope = { [weak self] id, business, payload in
                guard let self, self.companionDeviceID == id else { return }
                DisplayObservation.shared.connection(true,phase:self.companionPhase)
                DisplayObservation.shared.packet(payload,business:business,inbound:true)
                self.companionBusiness?(id, business, payload)
            }
            receiver.onBusinessLoss = { [weak self] in DisplayObservation.shared.loss(); self?.companionBusinessLoss?() }
            #endif
            receiver.onVoiceEnvelope = { [weak self] deviceID, metadata, audio, arrival in
                #if COMPANION_DEVICE
                if self?.companionDeviceID == deviceID, let type = metadata.messageType {
                    DisplayObservation.shared.voiceMetadata(type:type)
                }
                #endif
                if metadata.messageType == 1 || metadata.messageType == 11 { self?.standbyTick() }
                self?.voiceProbe.receive(deviceID:deviceID, metadata:metadata, audio:audio, arrival:arrival)
            }
            messageReceiver = receiver
            core?.addMessageDelegate(receiver)
            log("本 App のネイティブメッセージコールバックを登録しました（種別/長さのみ記録）")
        }
        if modelCatalog == nil { modelCatalog = sdkModelCatalog() }
        log("SDK 内蔵の機種カタログ利用可能=\(modelCatalog != nil)")
        log("独立 SDK instance を作成しました")
        let bonded = core?.bondedDevices() ?? []
        let linked = core?.linkedDevices() ?? []
        log("本 App に保存されたデバイス: \(bonded.count)；SDK 接続済みデバイス: \(linked.count)")
        for device in linked { logDeviceState(device, prefix: "現在の接続") }
    }

    @objc private func confirmVoiceProbe() {
        guard let core, let linked = core.linkedDevices(), linked.count == 1,
              let device = linked.first, device.isConnected(), device.bleStateByte() == 9 else {
            log("唯一の認証済み接続がないため、音声テストの準備ができていません"); return
        }
        let deviceID = device.deviceID()
        let alert = UIAlertController(title:"8秒間の音声テストを準備しますか？", message:"能動的にウェイクアップした後にのみ音声を要求します；空でない音声を受信した場合に限り、8秒後に今回のランダムなテスト文字列を表示します（内容は話したこととは無関係です）。さらに3秒後にページの終了を要求します。音声認識やモデルによる回答ではありません。種別/長さのみを記録し、保存・アップロードはしません；90秒間ウェイクアップがなければ自動的にキャンセルします。", preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"キャンセル", style:.cancel))
        alert.addAction(UIAlertAction(title:"テストを準備", style:.default) { [weak self] _ in
            guard let current = core.linkedDevices()?.first(where: { $0.deviceID() == deviceID }),
                  current.isConnected(), current.bleStateByte() == 9 else {
                self?.log("接続が変化したため、音声テストをキャンセルしました"); return
            }
            self?.voiceProbe.arm(deviceID:deviceID)
        })
        present(alert, animated:true)
    }

    @objc private func showDisplayBoundaryTests() {
        if voiceProbe.standby.enabled {
            let menu = UIAlertController(title:"継続待機の表示テスト",message:"次回のウェイクアップ時に A1 から A4 までの4区間の合成テキストを送信し、最後の区間にはチェックコードを付けます；クラウドサービスへのリクエストはしません。10秒での強制終了はなく、グラス自身の終了動作を確認します。",preferredStyle:.actionSheet)
            menu.addAction(UIAlertAction(title:"次回のウェイクアップ：A1–A4 増分テスト",style:.default) { [weak self] _ in self?.voiceProbe.armIncrementalFixture() })
            let duplex = voiceProbe.standby.continuousASREnabled
            menu.addAction(UIAlertAction(title:duplex ? "継続ASR並行実験をオフ" : "継続ASR並行実験をオン（120秒）",style:.default) { [weak self] _ in self?.voiceProbe.setContinuousASR(!duplex) })
            menu.addAction(UIAlertAction(title:"今回の表示を終了",style:.default) { [weak self] _ in self?.voiceProbe.standby.cancelCurrentRound() })
            menu.addAction(UIAlertAction(title:"キャンセル",style:.cancel))
            menu.popoverPresentationController?.sourceView = view
            menu.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:440,width:1,height:1)
            present(menu,animated:true)
            return
        }
        let menu = UIAlertController(title:"表示境界：音声テキストページ", message:"ファームウェアの既存テキストページのみをテストします。画像や任意の UI ではありません。各項目には能動的なウェイクアップが必要で、8秒後に表示し、10秒間保持した後に終了します。", preferredStyle:.actionSheet)
        for fixture in DisplayBoundaryFixture.all {
            menu.addAction(UIAlertAction(title:"\(fixture.id) · \(fixture.name)", style:.default) { [weak self] _ in
                self?.confirmDisplayFixture(fixture)
            })
        }
        menu.addAction(UIAlertAction(title:"現在のテストを終了", style:.destructive) { [weak self] _ in self?.voiceProbe.stopDisplayTest() })
        menu.addAction(UIAlertAction(title:"キャンセル", style:.cancel))
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1)
        present(menu, animated:true)
    }

    private func confirmDisplayFixture(_ fixture: DisplayBoundaryFixture) {
        guard let core, let linked = core.linkedDevices(), linked.count == 1,
              let device = linked.first, device.isConnected(), device.bleStateByte() == 9 else {
            log("唯一の認証済み接続がないため、表示境界テストを開始しません"); return
        }
        let deviceID = device.deviceID()
        let alert = UIAlertController(title:"\(fixture.id) · \(fixture.name)", message:"\(fixture.text)\n\n能動的なウェイクアップ後のみ短時間収音し、保存/アップロードはしません。8秒後に上記の合成テキストを送信し、10秒後に自動で終了します。毎回この項目のみを検証します。90秒間ウェイクアップがなければキャンセルします。", preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"キャンセル", style:.cancel))
        alert.addAction(UIAlertAction(title:"この項目のテストを準備", style:.default) { [weak self] _ in
            guard let linked = core.linkedDevices(), linked.count == 1,
                  let current = linked.first, current.deviceID() == deviceID,
                  current.isConnected(), current.bleStateByte() == 9 else {
                self?.log("接続が変化したため、表示テストの準備ができていません"); return
            }
            self?.voiceProbe.arm(deviceID:deviceID, fixture:fixture)
        })
        present(alert, animated:true)
    }

    @objc private func confirmVoiceWakeup() {
        guard let core, let linked = core.linkedDevices(), linked.count == 1,
              let device = linked.first, device.isConnected(), device.bleStateByte() == 9 else {
            log("唯一の認証済み接続がないため、音声ウェイクアップを有効化していません"); return
        }
        let deviceID = device.deviceID()
        let alert = UIAlertController(title: "このグラスの音声ウェイクアップを有効化しますか？", message: "公式に実測済みの Launcher/type16：set_ai_voice_wakeup、mode=1 を送信します。ウェイクアップスイッチのみを変更します；録音やアップロードはしません。グラスからのステータス応答と、人が実際にウェイクアップできるかの確認が必要です。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "テストを有効化", style: .default) { [weak self] _ in
            guard let current = core.linkedDevices()?.first(where: { $0.deviceID() == deviceID }),
                  current.isConnected(), current.bleStateByte() == 9 else {
                self?.log("接続が変化したため、有効化をキャンセルしました"); return
            }
            do {
                let payload = try LauncherControlPrototype.encode(.enableVoiceWakeup)
                let message = try MessageFactory.make(payload: payload, deviceID: deviceID,
                    business: .launcher, messageID: UUID().uuidString)
                try core.sendMessage(message)
                self?.log("Launcher/type16 set_ai_voice_wakeup mode=1 bytes=\(payload.count) を送信しました；グラスからの応答を待機中であり、ウェイクアップ成功ではありません")
            } catch { self?.log("音声ウェイクアップの送信に失敗しました（元のエラーは記録しません）") }
        })
        present(alert, animated: true)
    }

    @objc private func confirmTextTest() {
        guard let core, let linked = core.linkedDevices(), linked.count == 1,
              let device = linked.first, device.isConnected(), device.bleStateByte() == 9 else {
            log("唯一の認証済み接続がないため、メッセージを送信していません"); return
        }
        let deviceID = device.deviceID()
        let text = "カスタム接続テスト 1730"
        let alert = UIAlertController(title:"固定の ASR テキストを送信しますか？", message:"内容：\(text)\nこれは voiceAssistant/type=5 であり、ANCS 通知ではありません。先にグラスのウェイクアップが必要な場合があります；実際の表示は本人確認が必要です。", preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"キャンセル", style:.cancel))
        alert.addAction(UIAlertAction(title:"テストを送信", style:.default) { [weak self] _ in
            guard let current = core.linkedDevices()?.first(where: { $0.deviceID() == deviceID }),
                  current.isConnected(), current.bleStateByte() == 9 else {
                self?.log("接続が変化したため、送信をキャンセルしました"); return
            }
            do {
                let payload = try AssistantTextPrototype.asrText(text, isFinal:true)
                let message = try MessageFactory.make(payload:payload, deviceID:deviceID,
                                                     business:.voiceAssistant, messageID:UUID().uuidString)
                try core.sendMessage(message)
                self?.log("本 App→グラス type=5 bytes=\(payload.count) の呼び出しが戻りました；コールバックと実際の表示を待機中")
            } catch { self?.log("テキストテストの送信に失敗しました（エラーの本文は記録していません）") }
        })
        present(alert, animated:true)
    }

    @objc private func scan() {
        scanRequested = true
        seen.removeAll()
        parsedAdvertisements.removeAll()
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { beginScan() }
    }

    private func beginScan() {
        guard central?.state == .poweredOn else { return }
        scanRequested = false
        central?.scanForPeripherals(withServices: [CBUUID(string: "B81D")], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("検証済みの B81D サービスをスキャン中（15秒、接続/書き込みなし）")
        for p in central!.retrieveConnectedPeripherals(withServices: [CBUUID(string: "B81D")]) {
            devices[p.identifier] = p
            log("システム接続済みの RayNeo サービス: \(p.name ?? "unnamed")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.central?.stopScan()
            self?.log("スキャン終了")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CoreBluetooth state=\(central.state.rawValue)")
        #if COMPANION_DEVICE
        if central.state == .poweredOn { deviceConnectionPolicy.resetBudget() }
        deviceConnectionTick()
        if scanRequested { beginScan() }
        if voiceProbe.standby.enabled { standbyTick() }
        #else
        if voiceProbe.standby.enabled { standbyTick() } else { beginScan() }
        #endif
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        devices[peripheral.identifier] = peripheral
        if seen.insert(peripheral.identifier).inserted {
            log("検出: \(peripheral.name ?? "unnamed") RSSI=\(RSSI)")
            log("アドバタイズメントフィールド: \(advertisementData.keys.sorted().joined(separator: ", "))")
        }
        if !parsedAdvertisements.contains(peripheral.identifier), let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            parsedAdvertisements.insert(peripheral.identifier)
            log("メーカーアドバタイズメント長=\(data.count)。ObjC の解析エントリを呼び出します")
            if let id = RNProbeIdentifier(data, (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false) {
                sdkDeviceIDs.insert(id)
                if let sdkPeripheral = RNProbeSDKPeripheral(peripheral.identifier), let modelCatalog {
                    sdkPeripherals[peripheral.identifier] = RNProbePeripheral(data, sdkPeripheral, advertisementData, modelCatalog)
                    log("SDK 自身の CBCentralManager によりペリフェラルオブジェクトを解析済み")
                } else { log("SDK central の準備がまだできていません。読み込み後に再スキャンしてください") }
                log("SDK アドバタイズメント解析に成功。プロトコルのデバイス識別子を取得済み（元の値は表示しません）")
            } else { log("SDK アドバタイズメント解析がデバイス識別子を返しませんでした: \(RNProbeDiagnosis())") }
        }
    }

    @objc private func accessories() {
        let matches = EAAccessoryManager.shared().connectedAccessories.filter { $0.name.localizedCaseInsensitiveContains("rayneo") }
        log("本 App から見える RayNeo MFi アクセサリ: \(matches.count)")
        for a in matches { log("\(a.name) protocols=\(a.protocolStrings.joined(separator: ","))") }
        guard eaSession == nil, let accessory = matches.first,
              accessory.protocolStrings.contains("com.rayneo.venus.pub") else { return }
        eaSession = EASession(accessory: accessory, forProtocol: "com.rayneo.venus.pub")
        guard let session = eaSession else { log("EASession の作成に失敗"); return }
        log("EASession を作成済み；ストリームを開くテストのみを行い、業務メッセージは送信しません")
        for stream in [session.inputStream as Stream?, session.outputStream as Stream?].compactMap({$0}) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self, let session = self.eaSession else { return }
            for stream in [session.inputStream as Stream?, session.outputStream as Stream?].compactMap({$0}) {
                stream.close()
                stream.remove(from: .main, forMode: .default)
                stream.delegate = nil
            }
            self.eaSession = nil
            self.log("MFi テストストリームを閉じました")
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        let direction = aStream === eaSession?.inputStream ? "input" : "output"
        if eventCode.contains(.openCompleted) { log("MFi \(direction) openCompleted") }
        if eventCode.contains(.errorOccurred) { log("MFi \(direction) error: \(aStream.streamError?.localizedDescription ?? "unknown")") }
    }

    @objc private func sdkDiscovery() {
        if core == nil { loadCore() }
        guard let core else { return }
        do { try core.discover(); log("SDK discoverStart の呼び出しに成功（認証成功を意味しません）") }
        catch { log("SDK discovery error: \(error)") }
    }

    @objc private func connectSDK() {
        guard !voiceProbe.standby.enabled else { log("継続サービスが接続を管理中です。先にオフにしてから手動で接続してください"); return }
        guard let core else { log("先に通信コアを読み込み、グラスを検出してください"); return }
        // findCoreDevice compares CBPeripheral.identifier.uuidString, NOT the
        // 6-byte identifier carried in the manufacturer's advertisement.
        let found = sdkPeripherals.compactMap { uuid, peripheral in
            let id = uuid.uuidString
            return (core.findDevice(id) ?? convertPeripheral(peripheral)).map { (id, $0) }
        }
        guard found.count == 1, let (id, target) = found.first else { log("SDK キャッシュの一致デバイス数=\(found.count)。接続していません"); return }
        do {
            // No account/token/key copied from the official app. Normal SDK path.
            try core.connectBLE(target)
            log("SDK BLE リクエストを送信済み。デバイスの認証状態を待機中")
            for delay in [2.0,5.0,10.0,20.0,30.0,45.0] {
                DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
                    let linked = core.linkedDevices() ?? []
                    let cached = core.findDevice(id)
                    let live = linked.first { $0.deviceID() == target.deviceID() }
                    let fresh = live ?? cached
                    self?.log("\(Int(delay))s SDK linkedCount=\(linked.count), connected=\(fresh?.isConnected() ?? false), BLE状態バイト=\(fresh?.bleStateByte() ?? 255)")
                    if let live, let cached, live.bleStateByte() != cached.bleStateByte() {
                        self?.log("SDK キャッシュオブジェクトの状態が不一致：linked=\(live.bleStateByte()), findDevice=\(cached.bleStateByte())；上記は linked オブジェクトを表示しています")
                    }
                }
            }
        } catch { log("SDK BLE 接続エラー: \(error)") }
    }

    @objc private func confirmUnbind() {
        guard let core, let device = core.linkedDevices()?.first, device.isConnected(), device.bleStateByte() == 9 else {
            log("認証済み接続がないため、紐づけ解除を実行していません")
            return
        }
        let targetID = device.deviceID()
        let alert = UIAlertController(title: "このテスト用グラスのバインドを解除しますか？", message: "別のスマートフォンへ切り戻すための操作です。グラスの内容が消去される場合があります；PC の録音コピーには影響しません。実行後は本 App を停止し、システムの Bluetooth でデバイスを無視してください。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "紐づけ解除を確認", style: .destructive) { [weak self] _ in
            // The alert can remain open while the glasses disconnect. Re-fetch
            // the target and validate its real CBPeripheral immediately before
            // calling the SDK, which otherwise silently performs local cleanup.
            guard let self, let fresh = core.linkedDevices()?.first(where: { $0.deviceID() == targetID }),
                  fresh.isConnected(), fresh.bleStateByte() == 9 else {
                self?.log("確認時点で認証済み接続が無効でした；オフラインのローカルクリーンアップをグラスの紐づけ解除とみなすことを拒否しました")
                return
            }
            self.logDeviceState(fresh, prefix: "紐づけ解除前の再確認")
            self.disableStandby()
            let transport = fresh.transport()
            guard transport.rnSDKPeripheral()?.state == .connected,
                  [UInt8(1), UInt8(3)].contains(transport.rnSDKTransportState()) else {
                self.log("低レイヤ BLE が SDK のオンライン紐づけ解除の条件を満たさないため、実行しませんでした；再試行のために本 App のバインドを保持します")
                return
            }
            do {
                self.central?.stopScan()
                try core.unbind(fresh)
                self.log("SDK unbound の呼び出しが戻りました。リモート側の証拠を待機中；ローカル件数がゼロになってもリモート側の成功を意味しません")
                for delay in [2.0,5.0,10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in
                        self?.log("紐づけ解除 \(Int(delay))s：本 App のバインド数=\(core.bondedDevices()?.count ?? 0)、接続数=\(core.linkedDevices()?.count ?? 0)")
                    }
                }
            } catch { self.log("紐づけ解除リクエストエラー: \(error)") }
        })
        present(alert, animated: true)
    }

    private func logDeviceState(_ device: DeviceHandle, prefix: String) {
        let transport = device.transport()
        log("\(prefix)：connected=\(device.isConnected()) / BLE=\(device.bleStateByte()) / transport=\(transport.rnSDKTransportState()) / CB=\(transport.rnSDKPeripheral()?.state.rawValue ?? -1)")
    }

}
