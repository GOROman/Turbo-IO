import Foundation
import Combine
import RayNeoDisplay
import RayNeoProtocol
import UIKit

@MainActor final class CompanionDeviceFeatures: ObservableObject {
    @Published private(set) var status = "接続後にグラス機能が使えます。自動では録音を開始しません"
    @Published private(set) var recordingStatus = "グラス録音の受信は未有効"
    @Published private(set) var recordingID: String?
    @Published private(set) var recordingBytes = 0
    @Published private(set) var acceptsEyeRecording = false
    @Published private(set) var todoStatus = "未同期"
    @Published private(set) var battery: Int?
    @Published private(set) var brightness: Int?
    @Published private(set) var settings: [String: Any] = [:]
    @Published private(set) var completedRecording: URL?
    @Published private(set) var recoveryEntries: [GlassesRecordingInbox.Entry] = []
    @Published private(set) var recoveryBusy = false
    @Published private(set) var recoveryStatus = "この端末だけをスキャンし、グラスにはアクセスしません。"
    @Published var error: String?
    let voice: CompanionVoiceRuntime
    private weak var store: CompanionStore?
    private let inbox: GlassesRecordingInbox
    private let io = DispatchQueue(label: "companion.recording.inbox", qos: .utility)
    private let writeSlots = DispatchSemaphore(value:64)
    private var failedRecordings = Set<String>()
    private var captureDevice: String?
    private var recordTimeRaw: Int64?
    private var finishing = Set<String>()
    private var finalizationInFlight = false
    private var pendingSettings: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    var canControl: Bool { voice.ready && !recoveryBusy && store?.alwaysOn.occupied != true && !["recording", "processing", "displaying"].contains(voice.phase) }
    init(voice: CompanionVoiceRuntime, store: CompanionStore, root: URL) {
        self.voice = voice; self.store = store; inbox = GlassesRecordingInbox(root: root)
        voice.onBusiness = { [weak self] in self?.receive(device: $0, business: $1, data: $2) }
        voice.onBusinessLoss = { [weak self] in self?.lostMessages(); self?.store?.alwaysOn.lostMessages() }
        // One automatic weather owner. Legacy Weatherstack stays manual to avoid overwrites.
        voice.onRuntimeRefresh = { [weak self] in self?.store?.qweather.tick() }
        voice.featureIsBusy = { [weak self] in self?.recordingID != nil || self?.teleprompterID != nil || self?.store?.alwaysOn.occupied == true }
        voice.onConnectionChange = { [weak self] device in
            guard let self else { return }
            self.store?.notifications.connectionChanged()
            self.store?.headControlTest.connectionChanged()
            self.store?.alwaysOn.connectionChanged()
            self.pendingSettings.removeAll(); self.settings = [:]; self.battery = nil; self.brightness = nil
            if self.recordingID != nil { self.recordingStatus = device == self.captureDevice ? "接続が復旧しました。同じ録音の状態／データを待機中です。再送完了とは自動で判定しません" : "接続が切断されました。元の録音は保持し、同じグラスの復旧を待っています" }
            if self.teleprompterID != nil, device != self.teleprompterDevice {
                self.teleprompterPrepared = false
                self.teleprompterStatus = "プロンプターの接続が切断されました。自動操作を停止します。接続を復旧してから終了し、再準備してください"
            }
        }
        for (name, foreground) in [(UIApplication.didEnterBackgroundNotification,false),(UIApplication.didBecomeActiveNotification,true)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingID != nil, self.voice.deviceID == self.captureDevice else { return }
                    self.perform { try self.send(14,14,["isAppForeground":foreground]) }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func prepare() { voice.prepare(); voice.refresh() }
    private func send(_ business: UInt8, _ type: UInt32, _ json: [String: Any]) throws {
        guard voice.deviceID != nil else { throw DeviceFeatureError.disconnected }
        try voice.sendBusiness(business, payload: DeviceBusinessWire.encode(type: type, json: json))
    }
    func perform(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "操作に失敗しました。グラスの完了は未確認です。" }
    }
    func enableEyeRecording(_ enabled: Bool) {
        guard recordingID == nil else { error = "まず録音を停止し、ファイル受信の終了をお待ちください。"; return }
        acceptsEyeRecording = enabled
        recordingStatus = enabled ? "受信を許可しました。グラスで録音を開始してください。この端末にのみ保存します" : "グラス録音の受信は未有効"
    }
    func startRecording() {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            // Voice standby is explicitly suspended so an unsolicited wake cannot steal the microphone.
            if voice.enabled { voice.stop() }
            acceptsEyeRecording = true
            let id = UUID().uuidString
            captureDevice = device; recordingID = id; recordingBytes = 0; completedRecording = nil; recordTimeRaw = nil
            recordingStatus = "この端末の受信フォルダを準備中"
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device, id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform {
                            try self.send(14,14,["isAppForeground": true])
                            try self.send(14,1,["uuid":id,"action":1,"code":1])
                            self.recordingStatus = "開始をリクエストしました。グラスの応答を待っています"
                        }
                    }
                } catch { DispatchQueue.main.async { self?.error = "受信フォルダの作成に失敗したため、グラス録音はリクエストしていません。"; self?.recordingID = nil } }
            }
        }
    }
    func recordingControl(_ type: UInt32) {
        perform {
            guard let id = recordingID, voice.deviceID == captureDevice, [4,8,9,11].contains(type) else { throw DeviceFeatureError.noSession }
            var body: [String: Any] = ["uuid": id, "action": type == 11 ? 2 : 1, "code": type == 4 ? 2 : 1]
            // Preserve a reported raw time; never invent an epoch/elapsed-time conversion.
            if type == 9, let time = recordTimeRaw { body["time"] = time }
            try send(14,type,body)
            recordingStatus = type == 4 ? "停止をリクエストしました。末尾の音声と完了メッセージを待っています" : "コントロールを送信しました。グラスの応答を待っています"
        }
    }
    func receive(device: String, business: UInt8, data: Data) {
        guard voice.deviceID == device else { return }
        if business == 13 || business == 15 { store?.alwaysOn.receive(device: device, business: business, packet: data) }
        do {
            let wire = try DeviceBusinessWire(data)
            switch business {
            case 14: try recording(device,wire)
            case 22: try todo(device,wire)
            case 15:
                store?.qweather.receive(device:device,wire:wire)
                launcher(wire)
            case 20: try teleprompterReceive(device,wire)
            case 21:
                store?.notifications.receive(device: device, wire: wire)
                store?.headControlTest.receive(device: device, wire: wire)
            default: break
            }
        } catch {
            self.error = "未識別または不一致の業務データを受信しました。成功とは扱っていません。"
            if business == 14 { lostMessages() }
        }
    }
    private func recording(_ device: String, _ wire: DeviceBusinessWire) throws {
        let j = wire.json, type = wire.type
        if type == 12 { recordingStatus = "同期リストを受信しました。このバージョンではオフラインの滞留分を自動インポート／削除しません"; return }
        guard let id = DeviceBusinessWire.identifier(j,"uuid") else { return }
        if type == 3, finishing.contains(id), recordingID != id, captureDevice == device {
            error = "パッケージ済みの録音に対して遅延データが届きました。コピーを保持して再確認してください。完全性は保証できません。"
            io.async { [inbox] in inbox.invalidate(device:device,id:id) }
            return
        }
        let action = DeviceBusinessWire.integer(j,"action"), code = DeviceBusinessWire.integer(j,"code")
        if type == 1, action == 1 {
            guard acceptsEyeRecording, teleprompterID == nil, recordingID == nil || (recordingID == id && captureDevice == device), canControl else { return }
            if voice.enabled { voice.stop() }
            recordingID = id; captureDevice = device; recordingBytes = 0; completedRecording = nil
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device,id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform { try self.send(14,1,["uuid":id,"action":2,"code":1]); self.recordingStatus = "グラス録音を受け付けました。データを待っています" }
                    }
                } catch { DispatchQueue.main.async { self?.error = "グラス録音用の端末内ストレージを準備できません。" } }
            }
            return
        }
        guard recordingID == id, captureDevice == device else { return }
        if let time = DeviceBusinessWire.integer(j,"time") { recordTimeRaw = time }
        if type == 1, action == 2 {
            if code == 1 { recordingStatus = "グラスが録音開始を確認しました" }
            else { recordingStatus = "グラスが開始を拒否しました。code=\(code ?? -1)。プライバシー／競合を自動では回避しません"; recordingID = nil }
        } else if type == 3 {
            guard let offset = DeviceBusinessWire.integer(j,"offset"), offset >= 0,
                  offset <= GlassesRecordingInbox.limit, !wire.bytes.isEmpty else { throw DeviceFeatureError.invalidPacket }
            guard writeSlots.wait(timeout:.now()) == .success else { lostMessages(); return }
            io.async { [weak self, inbox, writeSlots] in
                defer { writeSlots.signal() }
                do { let count = try inbox.append(device:device,id:id,offset:Int(offset),data:wire.bytes)
                    DispatchQueue.main.async { self?.recordingBytes = count; self?.recordingStatus = "元の音声を受信して保存中" }
                } catch { inbox.invalidate(device:device,id:id); DispatchQueue.main.async { self?.error = "音声の書き込みまたは完全性チェックに失敗しました。元のファイルは保持しますが、完全とは表示しません。" } }
            }
        } else if type == 6, DeviceBusinessWire.boolean(j,"completed") == true, !finishing.contains(id) {
            // Persist the observed completion before queued finalization, so a restart cannot invent or lose it.
            io.async { [inbox] in
                do { try inbox.recordCompletion(device:device,id:id) }
                catch { inbox.invalidate(device:device,id:id) }
            }
            finishing.insert(id); recordingStatus = "グラスが完了を報告しました。受信範囲を確認してパッケージ中"
            // Small grace for callbacks delivered after completion. Late data is never silently merged into a published file.
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.finishRecording(device:device,id:id) }
        } else if type == 4 {
            if action == 1 { try send(14,4,["uuid":id,"action":2,"code":code ?? 1]) }
            recordingStatus = "停止イベントを受信しました。音声の完了を待っています"
        } else if type == 11 {
            if action == 1 { try send(14,11,["uuid":id,"action":2,"code":1]) }
            let time = DeviceBusinessWire.integer(j,"time") ?? 0
            io.async { [inbox] in try? inbox.mark(device:device,id:id,time:time) }
        } else if type == 8 || type == 9 {
            if action == 1 { try send(14,type,["uuid":id,"action":2,"code":1]) }
            recordingStatus = code == 1 ? (type == 8 ? "グラスが一時停止しました" : "グラスが再開しました") : "コントロール応答 code=\(code ?? -1)"
        } else if type == 5 { recordingStatus = "同じ録音の再接続状態を受信しました。offsetで検証を続けます" }
    }
    private func finishRecording(device: String, id: String) {
        guard !finalizationInFlight else { return }
        finalizationInFlight = true
        io.async { [weak self, inbox] in
            do {
                _ = try inbox.finish(device:device,id:id)
                let output = try inbox.decodedDerivative(device:device,id:id)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finalizationInFlight = false
                    self.completedRecording = output; self.recordingID = nil
                    self.recordingStatus = "受信範囲とパケット毎のデコードに合格しました。WAVはアーカイブ待ちです。元の音声／Oggは保持します。無線の原音が無損失であることを意味しません。"
                    // Archive copy + checksum, not ASR or upload. Ogg structure is not proof of acoustic completeness.
                    Task { await self.archiveReceivedRecording() }
                }
            } catch {
                DispatchQueue.main.async { self?.finalizationInFlight = false; self?.recordingStatus = "パッケージを完了できませんでした。元のバイトと受信範囲の記録は保持しています"; self?.error = "録音が完全性チェックに合格しなかったため、完全な音声とは表示しません。" }
            }
        }
    }
    private func lostMessages() {
        store?.notifications.lostMessages()
        if let id = recordingID, let device = captureDevice, failedRecordings.insert(id).inserted { io.async { [inbox] in inbox.invalidate(device:device,id:id) } }
        error = "業務受信キューが溢れたか、録音形式が一致しません。今回の録音は完全とは表示できません。"
    }
    func archiveReceivedRecording() async {
        guard let file = completedRecording, let store else { return }
        let imported = await store.archive.importFile(file,title:"グラス録音 " + Date().formatted(date:.abbreviated,time:.shortened))
        recordingStatus = imported ? "WAVを検証してアーカイブしました。元の音声／Oggは保持し、文字起こしやアップロードはしていません" : "WAVは保存しましたが、アーカイブに失敗しました。アーカイブの再試行かファイル共有ができます"
    }
    func retryRecordingFinish() {
        guard let id = recordingID, let device = captureDevice, finishing.contains(id) else { error = "グラスの完了メッセージをまだ受け取っていないため、完了として扱うことはできません。"; return }
        finishRecording(device:device,id:id)
    }
    func loadRecoveryEntries() async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { recoveryStatus = "受信タスクがあります。終了してからスキャンしてください。"; return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let catalog: GlassesRecordingInbox.Catalog = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.catalog() }) }
            }
            recoveryEntries = catalog.entries
            recoveryStatus = "この端末に \(catalog.entries.count) 件。読み取れないフォルダ \(catalog.unreadable) 件はそのまま保持しています。スキャンは完全性の合格を意味しません。"
        } catch { recoveryStatus = "この端末の受信フォルダを読み取れません。消去・再作成・削除はしていません。" }
    }
    func recoverRecording(_ entryID: String) async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let file: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.recoverDecoded(entryID) }) }
            }
            guard let store else { return }
            let imported = await store.archive.importFile(file,title:"復旧したグラス録音")
            recoveryStatus = imported ? "再確認・デコードしてアーカイブしました。文字起こし・アップロード・元ファイルの削除はしていません。" : "WAVは復旧しましたが、アーカイブはまだ成功していません。元のファイルは保持し、再試行できます。"
        } catch { recoveryStatus = "復旧チェックに合格しないか、このビルドがデコードに対応していません。元ファイルは保持しますが、完全とは表示しません。" }
    }
    func recoveryRawFile(_ entryID: String) async -> URL? {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return nil }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.exportRawCopy(entryID) }) }
            }
            return url
        } catch { recoveryStatus = "元のファイルを読み取れないため、共有入口は作成していません。"; return nil }
    }
    func syncTodos(pendingOnly: Bool = false) {
        perform {
            guard canControl, let device = voice.deviceID, let store else { throw DeviceFeatureError.disconnected }
            let rows = try store.todoCandidates(device: device, pendingOnly: pendingOnly)
            guard rows.count <= 100 else { throw DeviceFeatureError.storageLimit }
            for row in rows { try sendTodo(row, device:device) }
            todoStatus = "ToDo \(rows.count) 件を送信しました。グラスの状態／操作の受領を待っています。レンズに表示されたことを意味しません"
        }
    }
    func localTodoChanged(_ row: LocalTodo) {
        guard canControl, row.archivedAt == nil, row.wireDeviceID == voice.deviceID,
              row.wireID != nil, row.delivery?.conflict == nil else { return }
        perform { guard let device = voice.deviceID else { throw DeviceFeatureError.disconnected }; try sendTodo(row,device:device) }
    }
    private func sendTodo(_ row: LocalTodo, device: String) throws {
        guard let store else { throw DeviceFeatureError.noSession }
        let current = try store.prepareTodoSubmission(row.id, device: device)
        guard let id = current.wireID, let revision = current.delivery?.revision else { throw TodoDeliveryError.missing }
        let seconds = Int64(Date().timeIntervalSince1970)
        let body: [String:Any] = ["eventType":1,"eventID":id,"createTime":Int64(current.createdAt.timeIntervalSince1970),
            "title":current.title,"isImportant":current.important ?? false,"status":current.completed ? 1 : 0,"lastModifiedTime":seconds]
        try send(22,2,body)
        store.markTodoSubmitted(row.id, device: device, revision: revision)
    }
    private func todo(_ device: String, _ wire: DeviceBusinessWire) throws {
        if wire.type == 14 { todoStatus = "グラス操作の受領：成功 \(DeviceBusinessWire.integer(wire.json,"successCount") ?? 0)。項目毎のレンズ確認としては扱いません"; return }
        guard wire.type == 4 || wire.type == 10 else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        let message = try TodoJSONCodec().decodeGlassesMessage(type:UInt16(wire.type),payload:data)
        var changes = 0
        switch message {
        case .status(let s): changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0
        case .batch(let b):
            for entry in b.eventList.value ?? [] { if case .todo(let s) = entry { changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0 } }
        default: break
        }
        todoStatus = "グラスの状態を \(changes) 件適用しました。オフライン変更の競合は送信待ちリストを確認してください。不明なIDはインポートしません"
    }
    func refreshSettings() {
        perform {
            try voice.sendBusiness(15,payload:LauncherControlPrototype.encode(.requestGeneralStatus))
            try send(15,4,["cmd":"request_general_settings","payload":["value":0,"mode":0,"data":""]])
            status = "照会しました。グラスの状態を待っています"
        }
    }
    func setBrightness(_ value: Int) { command(type:2,cmd:"brightness_change",value:value,allowed:7...8) }
    func setHeadControl(_ enabled: Bool, mode: Int) {
        guard [0,1].contains(mode) else { return }; command(type:5,cmd:"head_gestures",value:enabled ? 1:0,mode:mode)
    }
    func setSleep(_ seconds: Int) { guard [15,25].contains(seconds) else { return }; command(type:5,cmd:"auto_lock_time",value:seconds) }
    func setDoubleTapTodo(_ todo: Bool) {
        guard let crown = settings["crownConfig"] as? [String:Any] ?? settings["crown_config"] as? [String:Any],
              let long = DeviceBusinessWire.integer(crown,"longPress") else { error = "元の長押し設定を上書きしないよう、まずノブ設定をすべて読み取ってください。"; return }
        perform { let body = try JSONSerialization.data(withJSONObject:["double":todo ? 8:0,"longPress":long]); try submitCommand(type:5,cmd:"crown_config",value:0,mode:0,data:String(decoding:body,as:UTF8.self)) }
    }
    func setDisplay(height: Int? = nil, distance: Int? = nil) {
        guard let config = settings["displayConfig"] as? [String:Any] ?? settings["display_config"] as? [String:Any],
              let oldHeight = DeviceBusinessWire.integer(config,"height"), let oldDistance = DeviceBusinessWire.integer(config,"distance"),
              height == nil || [1,3,5].contains(height!), distance == nil || [1,2].contains(distance!) else {
            error = "まず表示設定を読み取ってください。根拠のある段階のみ対応し、他のパラメータは上書きしません。"; return
        }
        perform {
            let data = try JSONSerialization.data(withJSONObject:["height":height.map(Int64.init) ?? oldHeight,"distance":distance.map(Int64.init) ?? oldDistance])
            try submitCommand(type:5,cmd:"display_config",value:0,mode:0,data:String(decoding:data,as:UTF8.self))
        }
    }
    func sendWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) {
        perform { try submitWeatherstack(snapshot, icon: icon) }
    }
    func submitWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) throws {
        guard snapshot.canSend(at:Date()) else { throw WeatherstackError.stale }
        guard (0...999).contains(icon) else { throw WeatherstackError.icon }
        try submitWeather(location:snapshot.city,temperature:snapshot.lensTemperature,icon:icon,description:snapshot.description)
    }
    func sendWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) {
        perform { try submitWeather(location:location,temperature:temperature,icon:icon,description:description,current:current) }
    }
    private func submitWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) throws {
            guard canControl, !location.isEmpty, location.utf8.count <= 80, (-80...60).contains(temperature), (0...999).contains(icon) else { throw DeviceFeatureError.invalidPacket }
            let update = SelectedCityWeatherRawUpdate(items:[CityWeatherRawItem(location:location,locationID:"companion-custom",temperatureRaw:Int64(temperature),iconRaw:Int64(icon),descriptionRaw:description,temperatureRangeRaw:"",hourly:[])],timestampRaw:String(Int64(Date().timeIntervalSince1970)))
            let msg = try current ? WeatherJSONCodec().encodeCurrentWeatherUpdate(CurrentWeatherRawUpdate(location:location,temperatureRaw:Int64(temperature),iconRaw:Int64(icon),timestampRaw:update.timestampRaw)) : CityWeatherJSONCodec().encodeUpdate(update)
            try voice.sendBusiness(15,payload:DeviceBusinessWire.encode(type:UInt32(msg.type),json:JSONSerialization.jsonObject(with:msg.payload) as! [String:Any]))
            pendingSettings[current ? "current_weather_update" : "weather_update"] = Date(); status = "カスタム天気データを送信しました。ダッシュボード部品のレイアウトは変更せず、受領を待っています"
    }
    private func command(type: UInt32, cmd: String, value: Int, mode: Int = 0, allowed: ClosedRange<Int>? = nil) {
        perform { if let allowed, !allowed.contains(value) { throw DeviceFeatureError.invalidPacket }; try submitCommand(type:type,cmd:cmd,value:value,mode:mode,data:"") }
    }
    private func submitCommand(type: UInt32, cmd: String, value: Int, mode: Int, data: String) throws {
        guard canControl else { throw DeviceFeatureError.busy }
        if let since = pendingSettings[cmd], Date().timeIntervalSince(since) < 8 { throw DeviceFeatureError.busy }
        try send(15,type,["cmd":cmd,"payload":["value":value,"mode":mode,"data":data]])
        pendingSettings[cmd] = Date(); status = "設定を送信しました。グラスの報告を待っています。表示値は先行して変更しません"
    }
    private func launcher(_ wire: DeviceBusinessWire) {
        let j = wire.json
        if wire.type == 1 {
            let state = j["generalStatus"] as? [String:Any] ?? j
            if let n = DeviceBusinessWire.integer(state,"battery") { battery = Int(n) }
            if let n = DeviceBusinessWire.integer(state,"brightness") { brightness = Int(n) }
        }
        if wire.type == 4 { settings = j["generalSettings"] as? [String:Any] ?? j; status = "グラスの共通設定を受信しました" }
        guard let cmd = j["cmd"] as? String, let p = j["payload"] as? [String:Any] else { return }
        if wire.type == 3, cmd == "brightness_change", let n = DeviceBusinessWire.integer(p,"value") { brightness = Int(n) }
        if [3,6,17,19].contains(wire.type) {
            if wire.type == 6, let body = p["data"] as? String, let bytes = body.data(using:.utf8),
               let config = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
               let key = ["display_config":"displayConfig","crown_config":"crownConfig","privacy_config":"privacyConfig"][cmd] {
                settings[key] = config
            }
            pendingSettings.removeValue(forKey:cmd)
            status = "グラス報告 \(cmd.prefix(45))：\(DeviceBusinessWire.integer(p,"value") ?? -1)（レンズ効果は未検証）"
        }
    }

    // Teleprompter state/transport is implemented in the dedicated extension below.
    @Published private(set) var teleprompterStatus = "原稿はまだ送信していません"
    @Published private(set) var teleprompterID: String?
    @Published private(set) var teleprompterOffset: Int64 = 0
    var teleprompterFile: URL?
    var teleprompterDevice: String?
    var teleprompterPrepared = false
    var teleprompterSentFile = false
    var teleprompterTransferTask: String?
}

extension CompanionDeviceFeatures {
    func prepareTeleprompter(_ text: String, speed: Int) {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count <= 12_000,
                  text.utf8.count <= 48_000, (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }
            if voice.enabled { voice.stop() }
            let did = UUID().uuidString
            let dir = inbox.root.deletingLastPathComponent().appendingPathComponent("TeleprompterOutboxV1")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            guard try FileManager.default.contentsOfDirectory(atPath:dir.path).count < 100 else { throw DeviceFeatureError.storageLimit }
            let url = dir.appendingPathComponent(did + ".txt")
            try Data(text.utf8).write(to:url,options:[.withoutOverwriting,.completeFileProtectionUntilFirstUserAuthentication])
            teleprompterID = did; teleprompterDevice = device; teleprompterFile = url
            teleprompterOffset = 0; teleprompterPrepared = false; teleprompterSentFile = false
            // Optional layout fields intentionally omitted: never guess pixel/gear defaults.
            try send(20,2,["action":1,"did":did,"total":text.utf8.count,"scroll":2,"speed":speed,"pageOffset":0,"highLightOffset":0])
            teleprompterStatus = "原稿の準備をリクエストしました。グラスの応答を待っています。今回は追従読み上げ／マイクは有効化しません"
            DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in
                guard let self, self.teleprompterID == did, !self.teleprompterPrepared else { return }
                self.teleprompterStatus = "準備がタイムアウトしました。受領は未確認で、自動ではスクロールを開始しません。終了をタップして今回分をキャンセルできます。"
            }
        }
    }
    func teleprompterControl(_ type: UInt32, speed: Int = 120) {
        perform {
            guard let did = teleprompterID, teleprompterDevice == voice.deviceID,
                  type == 6 || teleprompterPrepared else { throw DeviceFeatureError.noSession }
            guard [3,4,5,6,7].contains(type) else { throw DeviceFeatureError.invalidPacket }
            var body: [String:Any] = ["action":1,"did":did]
            if type == 4 { body["offset"] = teleprompterOffset; body["code"] = 1; body["isCompleted"] = false }
            if type == 7 { guard (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }; body["scroll"] = 2; body["speed"] = speed }
            try send(20,type,body)
            if type == 6, let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            teleprompterStatus = "コントロール type\(type) を送信しました。グラスの応答を待っています"
        }
    }
    private func teleprompterReceive(_ device: String, _ wire: DeviceBusinessWire) throws {
        guard let did = DeviceBusinessWire.identifier(wire.json,"did"), did == teleprompterID, teleprompterDevice == device else { return }
        let action = DeviceBusinessWire.integer(wire.json,"action"), code = DeviceBusinessWire.integer(wire.json,"code")
        if wire.type == 2, action == 2 {
            guard code == 1 || code == 7 else { teleprompterStatus = "準備が拒否されました。code=\(code ?? -1)。競合は自動では処理しません"; return }
            if !teleprompterSentFile {
                guard let file = teleprompterFile else { throw DeviceFeatureError.noSession }
                teleprompterTransferTask = try voice.sendFile(file,id:did)
                teleprompterSentFile = true
                teleprompterStatus = "専用ファイル経路に送信しました。業務側の受領確認を待っています。再生はまだ開始していません"
            } else { teleprompterPrepared = true; teleprompterStatus = "ファイル送信後に業務側の成功応答を受信しました。開始をテストできます。独立したファイル検証／レンズでの証明はまだありません" }
            return
        }
        if wire.type == 3, action == 2 { teleprompterStatus = "プロンプター開始の応答 code=\(code ?? -1)"; return }
        guard let control = TeleprompterControlType(rawValue: UInt16(clamping:wire.type)) else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        if action == 1 {
            let event = try TeleprompterJSONCodec().decodeGlassesRequest(type:control.rawValue,payload:data)
            switch event {
            case .progress(let p): teleprompterOffset = p.pageOffset; teleprompterStatus = "グラスの進捗報告：UTF-8 元のオフセット \(p.pageOffset)"
            case .pause: teleprompterStatus = "グラスが一時停止をリクエストしました"
            case .resume: teleprompterStatus = "グラスが再開をリクエストしました"
            case .stop: teleprompterStatus = "グラスが終了をリクエストしました"
            default: return
            }
            let ack = try TeleprompterJSONCodec().encodeAppResponse(type:control,did:did,code:.accepted)
            try voice.sendBusiness(20,payload:DeviceBusinessWire.encode(type:UInt32(ack.type),json:JSONSerialization.jsonObject(with:ack.payload) as! [String:Any]))
        } else if action == 2 { teleprompterStatus = "グラスの応答 type\(wire.type) code=\(code ?? -1)" }
        if control == .stop, action == 1 || code == 1 {
            if let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            teleprompterID = nil; teleprompterPrepared = false; teleprompterFile = nil
        }
    }
}
