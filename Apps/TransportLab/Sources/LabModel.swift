import Foundation
import WebRTC
import Combine

struct LabReport: Codable {
    let schemaVersion: Int
    let appVersion: String
    let build: String
    let backend: String
    let os: String
    let mode: String
    let networkLabel: String
    let actualOverlayPath: String
    let pacing: PacingMode
    let pacingParameters: String
    let playout: PlayoutMode
    let bridgeReceiveDepth: Int
    let bridgeTransport: BridgeTransportKind
    let mediaRoute: MediaRoute
    let preset: LabPreset
    let videoSource: String
    let notes: [String]
    let samples: [LabSample]
    var historyLimit: Int? = nil
    var sampleJournal: SampleJournalStatus? = nil
}

final class LabModel: ObservableObject {
    @Published var host = ""
    @Published var port = "45990"
    @Published var pairingKey = ""
    @Published var networkLabel = "Surge Ponte"
    @Published var mediaRoute = MediaRoute.ponteUDP
    @Published var mediaPort = "45991"
    @Published var resolution = "1920×1080"
    @Published var fps = 60
    @Published var megabits = 25
    @Published var pattern = PatternKind.grid
    @Published var hdr = false
    var sdrReceiver = false
    var nativeWorkspaceDisplayID: UInt32?
    // Explicit launch diagnostics only; no client preferences or wire-format changes.
    var frameTraceDirectory: URL?
    var diagnosticHistoryLimit = 3600
    private var sampleJournal: SampleJournal<LabSample>?
    func beginSampleJournal(to url: URL) throws { sampleJournal = try SampleJournal(url: url) }
    @discardableResult func finishSampleJournal() -> Bool { sampleJournal?.finish() ?? true }
    private var diagnosticRunDirectory: URL?
    private var diagnosticDuration: Double?
    private var diagnosticStopTimer: Timer?
    init() {
        #if os(iOS)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--media-diagnostics-run"), index + 1 < args.count {
            let name = args[index + 1]
            if name.range(of: "^[A-Za-z0-9_-]{1,60}$", options: .regularExpression) != nil,
               let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let directory = documents.appendingPathComponent("TransportDiagnostics", isDirectory: true).appendingPathComponent(name, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    diagnosticRunDirectory = directory
                    if args.contains("--media-frame-trace") { frameTraceDirectory = directory }
                    if let i = args.firstIndex(of: "--media-diagnostics-seconds"), i + 1 < args.count,
                       let seconds = Double(args[i + 1]), (30...3600).contains(seconds) { diagnosticDuration = seconds }
                } catch { print("MEDIA_DIAGNOSTICS_SETUP_FAILED") }
            }
        }
        #endif
    }
    @Published var captureWindowID: UInt32? = nil
    #if os(macOS)
    @Published var captureWindows: [CaptureWindow] = []
    func refreshCaptureWindows() {
        Task { @MainActor in
            do { captureWindows = try await WindowCaptureSource.windows() }
            catch { self.error = "无法列出窗口：\(error.localizedDescription)；请检查系统屏幕录制权限" }
        }
    }
    #endif
    var bridgeReceiveDepth = 16
    @Published var bridgeTransport = BridgeTransportKind.network
    @Published var running = false
    @Published var status = "准备连接"
    @Published var error: String?
    @Published var sample = LabSample()
    @Published var track: RTCVideoTrack?
    @Published var exportedReport: URL?
    @Published var mode = "viewer"
    @Published private(set) var lastSampleAt: Date?
    @Published private(set) var connectedHost = ""
    @Published private(set) var connectedNetworkLabel = ""
    private var signal: SignalTransport?
    private var engine: PeerEngine?
    private var demoHost: LabModel?
    private var samples: [LabSample] = []
    private var activePreset = LabPreset()
    private var activeRoute = MediaRoute.ponteUDP
    private var activeBridgeTransport = BridgeTransportKind.network
    private var activeReceiveDepth = 16
    private var activeVideoSource = "synthetic"
    private var generation = UUID()
    private var engineGeneration = UUID()
    private var windowSession = ""
    private var expectedMediaSession: String?
    private var activeHDR = false
    private var catalogRequestID: String?
    private var pendingWindowRequest: String?
    private var pendingWindowTarget: RemoteWindow?
    var enablesWindowControl = false
    @Published private(set) var windowControlSupported = false
    @Published private(set) var controlLease: String?
    @Published private(set) var controlState: WindowControlState?
    @Published private(set) var controlError: String?
    @Published private(set) var directKeyboardSupported = false
    @Published private(set) var inputQueueCount = 0
    private var queuedInputs:[WindowMessage] = []
    @Published private(set) var inputAcknowledged = 0
    private var inputSequence = 0
    private var scrollPoint=CGPoint.zero
    private var scrollDelta=CGSize.zero
    private var scrollWork:DispatchWorkItem?
    private var inputPending: [String:(String,String?,TimeInterval)] = [:]
    private var inputTimers: [String:DispatchWorkItem] = [:]
    var canControl: Bool { windowControlSupported && controlLease != nil && !windowBusy && running && sample.framesDecoded > 0 && selectedRemoteWindow != nil }
    var enablesWindowLayout = false
    @Published private(set) var windowLayoutSupported = false
    private var desiredWindowViewport: WindowViewport?
    private var appliedWindowViewport: WindowViewport?
    private var pendingWindowViewport: WindowViewport?
    private var layoutDebounce: DispatchWorkItem?
    private var hostMediaStopped = false
    private var viewerMediaStopped = false
    private var windowTimeout: DispatchWorkItem?
    @Published private(set) var windowSupported = false
    @Published private(set) var remoteWindows: [RemoteWindow] = []
    @Published private(set) var selectedRemoteWindow: RemoteWindow?
    @Published private(set) var windowBusy = false
    @Published private(set) var catalogLoading = false
    @Published private(set) var windowError: String?
    @Published private(set) var windowStatus = "连接后可查看远端窗口"
    #if os(macOS)
    private let windowCatalog = HostWindowCatalog()
    private var hostControl: HostWindowControl?
    #endif
    var decodedFrames: Int { engine?.frameCounter.received ?? 0 }
    var keepDecodedPreview = false
    #if os(macOS)
    func saveDecodedPreview(to url: URL) throws {
        guard let engine else { throw LabError.message("接收会话未运行") }
        try engine.frameCounter.savePreview(to: url)
    }
    #endif

    var preset: LabPreset {
        let size = resolution.split(separator: "×").compactMap { Int($0) }
        return LabPreset(width: size.first ?? 1920, height: size.last ?? 1080, fps: fps, megabits: megabits, pattern: pattern)
    }

    func startHost(pairingKey: String? = nil) { start(isHost: true, hostKey: pairingKey) }
    func connect() { start(isHost: false) }

    private func start(isHost: Bool, hostKey: String? = nil) {
        stop(); error = nil; samples.removeAll(); sample = LabSample(); exportedReport = nil
        lastSampleAt = nil
        connectedHost = host; connectedNetworkLabel = networkLabel
        guard let portNumber = UInt16(port), portNumber > 0 else { error = "端口应为 1–65535"; return }
        guard let mediaPortNumber = UInt16(mediaPort), mediaPortNumber > 0 else { error = "媒体端口应为 1–65535"; return }
        activePreset = preset; activeRoute = mediaRoute
        activeBridgeTransport = bridgeTransport; activeReceiveDepth = bridgeReceiveDepth
        activeHDR = hdr; windowSession = isHost ? UUID().uuidString : ""
        activeVideoSource = isHost ? (captureWindowID == nil ? "synthetic" : "window") : "remote"
        mode = isHost ? "host" : "viewer"
        let token = UUID(); generation = token
        do {
            if isHost { pairingKey = try hostKey ?? SignalTransport.newPairingKey() }
            let signal = SignalTransport()
            self.signal = signal
            try makeEngine(isHost: isHost)
            signal.onMessage = { [weak self] message in
                guard let self, self.generation == token else { return }
                self.receiveSignal(message)
            }
            signal.onReady = { [weak self] in
                guard let self, self.generation == token else { return }
                if isHost { self.engine?.startOffer() }
            }
            signal.onStatus = { [weak self] value in
                guard let self, self.generation == token else { return }; self.status = value
            }
            signal.onFailure = { [weak self] value in
                guard let self, self.generation == token else { return }
                self.stop(); self.error = value; self.status = "连接已结束"
            }
            if isHost { try signal.listen(key: pairingKey, port: portNumber) }
            else { try signal.connect(host: host, key: pairingKey, port: portNumber) }
            running = true; status = isHost ? "正在启动测试源" : "连接配对信令…"
            if !isHost, let diagnosticDuration {
                diagnosticStopTimer = Timer.scheduledTimer(withTimeInterval: diagnosticDuration, repeats: false) { [weak self] _ in
                    guard let self, self.generation == token else { return }; self.stop()
                }
            }
        } catch { stop(); self.error = error.localizedDescription }
    }

    private func makeEngine(isHost: Bool) throws {
        let token = generation, mediaToken = UUID()
        engineGeneration = mediaToken
        guard let mediaPortNumber = UInt16(mediaPort) else { throw LabError.message("无效媒体端口") }
        let engine = try PeerEngine(isHost: isHost, preset: activePreset, route: activeRoute,
            endpointHost: connectedHost, mediaPort: mediaPortNumber, receiveDepth: activeReceiveDepth,
            bridgeTransport: activeBridgeTransport, captureWindowID: isHost ? captureWindowID : nil,
            expectedWindowProcessID: isHost ? selectedRemoteWindow?.processID : nil,
            nativeWindowPixels:isHost && enablesWindowLayout, windowViewport:isHost ? pendingWindowViewport:nil,
            requiresNativeClientPixels:isHost && nativeWorkspaceDisplayID != nil,
            hdr: activeHDR, sdrReceiver: sdrReceiver,
            traceDirectory: frameTraceDirectory)
        self.engine = engine
        if keepDecodedPreview { engine.frameCounter.enablePreview() }
        engine.onSignal = { [weak self] original in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            var message = original
            if isHost && message.type == "offer" {
                message.windowProtocol = WindowMessage.version; message.windowSession = self.windowSession
                message.windowLayout = self.enablesWindowLayout
                message.windowControl = self.enablesWindowControl
                message.windowKeyboard = self.enablesWindowControl
            }
            self.signal?.send(message)
        }
        engine.onStatus = { [weak self] value in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            self.status = value
        }
        engine.onFailure = { [weak self] value in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            self.stop(); self.error = value; self.status = "连接已结束"
        }
        engine.onSourceFailure = { [weak self] value in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            guard isHost, self.windowSupported else { self.stop(); self.error = value; return }
            self.windowTimeout?.cancel(); self.pendingWindowRequest = nil
            self.windowBusy = false; self.selectedRemoteWindow = nil; self.captureWindowID = nil
            self.activeVideoSource = "none"
            self.stopMedia { [weak self] in
                guard let self, self.generation == token else { return }
                self.sendWindow(WindowMessage(action: "unavailable", requestID: UUID().uuidString,
                    error: "窗口已关闭或捕获中断，请选择其他窗口"))
            }
        }
        engine.onTrack = { [weak self] track in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            self.track = track
        }
        engine.onSample = { [weak self] value in
            guard let self, self.generation == token, self.engineGeneration == mediaToken else { return }
            self.sample = value; self.lastSampleAt = Date(); self.samples.append(value)
            self.sampleJournal?.append(value)
            if self.samples.count > self.diagnosticHistoryLimit { self.samples.removeFirst(self.samples.count - self.diagnosticHistoryLimit) }
            if !isHost, value.framesDecoded > 0, self.selectedRemoteWindow != nil {
                self.windowStatus = "正在观看 · 只读"
            }
        }
    }

    private func receiveSignal(_ message: SignalMessage) {
        if message.type == "window" {
            guard windowSession == message.session, let command = message.window else { return }
            receiveWindow(command); return
        }
        // Media generations are replaced only by the authenticated window transaction.
        // Late SDP/candidates from the previous stream cannot bind the next window.
        if let expectedMediaSession, expectedMediaSession != message.session { return }
        expectedMediaSession = message.session
        if mode != "host", message.type == "offer", message.windowProtocol == WindowMessage.version,
           let session = message.windowSession, !session.isEmpty {
            let first = !windowSupported
            windowSession = session; windowSupported = true
            windowLayoutSupported = message.windowLayout == true
            windowControlSupported = message.windowControl == true
            directKeyboardSupported = message.windowKeyboard == true
            windowStatus = "可选择远端窗口 · 只读"
            if first { refreshRemoteWindows() }
        }
        engine?.receive(message)
    }

    private func sendWindow(_ command: WindowMessage) {
        signal?.send(SignalMessage(type: "window", session: windowSession, window: command))
    }

    func refreshRemoteWindows() {
        guard running, mode != "host", windowSupported, !catalogLoading, !windowBusy else { return }
        catalogLoading = true; windowError = nil
        let request = UUID().uuidString
        catalogRequestID = request
        sendWindow(WindowMessage(action: "list", requestID: request))
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == token, self.catalogLoading, self.catalogRequestID == request else { return }
            self.catalogLoading = false; self.windowError = "窗口目录请求超时，请刷新重试"
        }
    }

    func queueInputScroll(point:CGPoint,delta:CGSize) {
        guard canControl else { return }
        scrollPoint=point;scrollDelta.width += delta.width;scrollDelta.height += delta.height
        guard scrollWork == nil else { return }
        let work=DispatchWorkItem { [weak self] in self?.flushInputScroll() }
        scrollWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:work)
    }
    func flushInputScroll() {
        scrollWork?.cancel();scrollWork=nil
        let delta=scrollDelta;scrollDelta = .zero
        guard delta != .zero else { return }
        sendInput(kind:"scroll",x:scrollPoint.x,y:scrollPoint.y,dx:max(-1000,min(1000,delta.width)),dy:max(-1000,min(1000,delta.height)))
    }
    @discardableResult func sendInput(kind:String,x:Double? = nil,y:Double? = nil,dx:Double? = nil,dy:Double? = nil,text:String? = nil,key:String? = nil,id:String = UUID().uuidString) -> Bool {
        guard canControl,let lease=controlLease,let window=selectedRemoteWindow,let media=expectedMediaSession else { return false }
        if controlError != nil,["insertText","key"].contains(kind) { return false }
        if ["insertText","key","focus"].contains(kind),!directKeyboardSupported { controlError="远端尚不支持直接键盘输入";return false }
        guard queuedInputs.count < 128,queuedInputs.reduce(0,{$0+($1.input?.text?.utf16.count ?? 0)})+(text?.utf16.count ?? 0)<=8192 else {
            failInput("输入积压，已暂停键盘，请重新点击窗口");return false
        }
        inputSequence += 1
        let input=WindowInput(lease:lease,sequence:inputSequence,kind:kind,x:x,y:y,dx:dx,dy:dy,text:text,focus:controlState?.focus ?? "pending",key:key)
        guard input.valid(width:window.widthPoints,height:window.heightPoints) else { failInput("输入内容超出限制，未发送");return false }
        controlError=nil
        queuedInputs.append(WindowMessage(action:"input",requestID:id,windowID:window.id,mediaSession:media,input:input))
        inputQueueCount=queuedInputs.count+inputPending.count
        sendNextInput();return true
    }
    private func sendNextInput() {
        guard inputPending.isEmpty,!queuedInputs.isEmpty,canControl,let lease=controlLease else { return }
        var command=queuedInputs.removeFirst()
        guard command.input?.lease == lease else { failInput("窗口已切换，输入已取消");return }
        if ["insertText","key"].contains(command.input?.kind ?? ""),controlState?.focus == nil {
            failInput("请先点击桌面输入位置或重新打开键盘");return
        }
        command.input?.focus=controlState?.focus
        let id=command.requestID
        inputPending[id]=(lease,command.input?.text,ProcessInfo.processInfo.systemUptime)
        inputQueueCount=queuedInputs.count+1
        sendWindow(command)
        let token=generation
        let timeout=DispatchWorkItem { [weak self] in
            guard let self,self.generation == token,self.inputPending.removeValue(forKey:id) != nil else { return }
            self.inputTimers[id]=nil
            self.failInput("输入回执超时，已暂停；未自动重发")
        }
        inputTimers[id]=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+5,execute:timeout)
    }
    private func failInput(_ message:String) {
        queuedInputs.removeAll();controlState=nil
        inputPending.removeAll();inputTimers.values.forEach{$0.cancel()};inputTimers.removeAll()
        inputQueueCount=0;controlError=message
    }
    private func resetControl() {
        scrollWork?.cancel();scrollWork=nil;scrollDelta = .zero
        #if os(macOS)
        hostControl?.invalidate();hostControl=nil
        #endif
        controlLease=nil;controlState=nil;controlError=nil;queuedInputs.removeAll();inputQueueCount=0
        inputPending.removeAll();inputTimers.values.forEach{$0.cancel()};inputTimers.removeAll();inputSequence=0
    }

    func updateWindowViewport(_ size: CGSize, displayScale: Double? = nil) {
        let next=WindowViewport(width:Double(size.width.rounded()),height:Double(size.height.rounded()),displayScale:displayScale)
        guard next.isValid,desiredWindowViewport != next else { return }
        desiredWindowViewport=next
        scheduleWindowLayout()
    }

    private func scheduleWindowLayout() {
        layoutDebounce?.cancel()
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.running,self.mode != "host",self.windowLayoutSupported,
                  !self.windowBusy,!self.catalogLoading,let window=self.selectedRemoteWindow,
                  let size=self.desiredWindowViewport,size != self.appliedWindowViewport else { return }
            self.windowBusy=true;self.windowError=nil
            self.windowStatus="正在适配窗口…"
            let request=UUID().uuidString
            self.pendingWindowRequest=request;self.pendingWindowViewport=size
            self.sendWindow(WindowMessage(action:"resize",requestID:request,windowID:window.id,viewport:size))
            self.armWindowTimeout(request)
        }
        layoutDebounce=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }

    func selectRemoteWindow(_ window: RemoteWindow?) {
        guard running, mode != "host", windowSupported, !windowBusy, !catalogLoading else { return }
        windowBusy = true; windowError = nil
        windowStatus = window == nil ? "正在停止观看…" : "正在切换窗口…"
        let request = UUID().uuidString
        pendingWindowRequest = request
        pendingWindowViewport = window != nil && windowLayoutSupported ? desiredWindowViewport : nil
        sendWindow(WindowMessage(action: window == nil ? "unsubscribe" : "select", requestID: request, windowID: window?.id, viewport:pendingWindowViewport))
        armWindowTimeout(request)
    }

    private func armWindowTimeout(_ request: String) {
        windowTimeout?.cancel()
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.pendingWindowRequest == request else { return }
            // Do not resume uncertain old content after a half-completed transaction.
            self.stop(); self.error = "窗口切换超时，请重新连接主机"
        }
        windowTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func stopMedia(completion: @escaping () -> Void) {
        resetControl()
        engineGeneration = UUID(); expectedMediaSession = nil
        track = nil; sample = LabSample(); lastSampleAt = nil
        // Peer statistics restart at zero for each selected window. Keep reports
        // within one media generation so rates/deltas never span that reset.
        samples.removeAll()
        let old = engine; engine = nil
        if let old { old.stop(completion: completion) } else { completion() }
    }

    private func receiveWindow(_ command: WindowMessage) {
        guard command.version == WindowMessage.version else {
            windowError = "远端窗口协议版本不兼容"; return
        }
        if mode == "host" { windowSupported = true; receiveHostWindow(command); return }
        switch command.action {
        case "inputResult":
            guard let pending=inputPending.removeValue(forKey:command.requestID),pending.0 == controlLease else { return }
            inputTimers.removeValue(forKey:command.requestID)?.cancel()
            if let error=command.error { failInput(error);return }
            controlError=nil
            if let state=command.controlState { controlState=state }
            inputAcknowledged += 1;inputQueueCount=queuedInputs.count
            sendNextInput()
        case "catalog":
            guard command.requestID == catalogRequestID else { return }
            catalogRequestID = nil; catalogLoading = false
            remoteWindows = Array((command.windows ?? []).prefix(256))
            windowError = command.error
            scheduleWindowLayout()
        case "error":
            guard command.requestID == pendingWindowRequest else { return }
            windowTimeout?.cancel(); pendingWindowRequest = nil; windowBusy = false
            windowError = command.error ?? "窗口操作失败"
            windowStatus = selectedRemoteWindow == nil ? "请选择远端窗口" : "正在观看 · 只读"
        case "prepare":
            guard command.requestID == pendingWindowRequest else { return }
            let token = generation
            stopMedia { [weak self] in
                guard let self, self.generation == token else { return }
                self.sendWindow(WindowMessage(action: "ready", requestID: command.requestID))
            }
        case "selected":
            guard command.requestID == pendingWindowRequest else { return }
            windowTimeout?.cancel(); pendingWindowRequest = nil
            selectedRemoteWindow = command.selected; windowBusy = false
            appliedWindowViewport=pendingWindowViewport;pendingWindowViewport=nil
            windowError=command.error
            scheduleWindowLayout()
            expectedMediaSession = command.mediaSession
            controlLease=command.controlLease;controlState=command.controlState;inputSequence=0
            if command.selected != nil {
                guard command.mediaSession != nil else { stop(); error = "主机未提供媒体会话"; return }
                windowStatus = "等待所选窗口的首帧…"
                do { try makeEngine(isHost: false) } catch { stop(); self.error = error.localizedDescription }
            } else { windowStatus = "已停止观看，可选择其他窗口" }
        case "unavailable":
            windowTimeout?.cancel(); pendingWindowRequest = nil
            windowBusy = false; selectedRemoteWindow = nil
            windowError = command.error; windowStatus = "窗口不可用，请重新选择"
            stopMedia(completion: {})
        default: break
        }
    }

    private func receiveHostWindow(_ command: WindowMessage) {
        #if os(macOS)
        let token = generation
        switch command.action {
        case "input":
            guard enablesWindowControl,!windowBusy,let executor=hostControl,
                command.windowID == selectedRemoteWindow?.id,command.mediaSession == expectedMediaSession,let input=command.input else {
                sendWindow(WindowMessage(action:"inputResult",requestID:command.requestID,error:"当前窗口暂不可操控"));return
            }
            executor.enqueue(id:command.requestID,input:input) { [weak self,weak executor] state,error in
                guard let self,let executor,self.generation == token,self.hostControl === executor else { return }
                self.sendWindow(WindowMessage(action:"inputResult",requestID:command.requestID,error:error,controlState:state))
            }
        case "list":
            guard !catalogLoading, !windowBusy else {
                sendWindow(WindowMessage(action: "catalog", requestID: command.requestID, error: "正在切换窗口，请稍后刷新")); return
            }
            catalogLoading = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.generation == token { self.catalogLoading = false } }
                do {
                    let windows = try await self.windowCatalog.refresh()
                    guard self.generation == token else { return }
                    self.sendWindow(WindowMessage(action: "catalog", requestID: command.requestID, windows: windows))
                } catch {
                    guard self.generation == token else { return }
                    self.sendWindow(WindowMessage(action: "catalog", requestID: command.requestID, error: "无法读取窗口目录，请检查主机屏幕录制权限"))
                }
            }
        case "select", "unsubscribe", "resize":
            guard !windowBusy, !catalogLoading else {
                sendWindow(WindowMessage(action: "error", requestID: command.requestID, error: "主机正在处理窗口操作，请稍后重试")); return
            }
            windowBusy = true; pendingWindowRequest = command.requestID
            armWindowTimeout(command.requestID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let target: RemoteWindow?
                    if command.action == "resize" {
                        guard self.enablesWindowLayout,let selected=self.selectedRemoteWindow,
                              selected.id == command.windowID,command.viewport?.isValid == true else {
                            throw LabError.message("窗口尺寸请求不可用")
                        }
                        target=try await self.windowCatalog.current(selected)
                    } else if command.action == "select" {
                        guard let handle = command.windowID else { throw LabError.message("缺少窗口引用") }
                        target = try await self.windowCatalog.resolve(handle)
                    } else { target = nil }
                    guard self.generation == token, self.pendingWindowRequest == command.requestID else { return }
                    if let viewport=command.viewport,!viewport.isValid { throw LabError.message("无效的窗口尺寸") }
                    self.pendingWindowViewport=self.enablesWindowLayout ? command.viewport:nil
                    self.pendingWindowTarget = target; self.hostMediaStopped = false; self.viewerMediaStopped = false
                    self.sendWindow(WindowMessage(action: "prepare", requestID: command.requestID))
                    self.stopMedia { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.hostMediaStopped = true; self.finishWindowSwitch()
                    }
                } catch {
                    guard self.generation == token else { return }
                    self.windowTimeout?.cancel(); self.pendingWindowRequest = nil; self.windowBusy = false
                    self.sendWindow(WindowMessage(action: "error", requestID: command.requestID, error: error.localizedDescription))
                }
            }
        case "ready":
            guard command.requestID == pendingWindowRequest else { return }
            viewerMediaStopped = true; finishWindowSwitch()
        default: break
        }
        #endif
    }

    private func finishWindowSwitch() {
        guard mode == "host", hostMediaStopped, viewerMediaStopped, let request = pendingWindowRequest else { return }
        // Both old media generations are stopped before changing desktop geometry.
        hostMediaStopped=false;viewerMediaStopped=false
        let token=generation
        let target=pendingWindowTarget,viewport=pendingWindowViewport
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.generation == token,self.pendingWindowRequest == request else { return }
            var accepted=target,warning:String?
            #if os(macOS)
            await HostWindowLayout.restoreNativeWindows(except:target).value
            guard self.generation == token,self.pendingWindowRequest == request else {return}
            if let target,let viewport,self.enablesWindowLayout {
                do { try await HostWindowLayout.resize(target,viewport:viewport,workspaceDisplayID:self.nativeWorkspaceDisplayID,maximumPixels:CGFloat(self.activePreset.width*self.activePreset.height),isCurrent:{self.generation==token && self.pendingWindowRequest==request}) }
                catch {
                    guard self.generation==token,self.pendingWindowRequest==request else {return}
                    if self.nativeWorkspaceDisplayID != nil {self.stop();self.error=error.localizedDescription;return}
                    warning=error.localizedDescription
                }
            }
            guard self.generation == token,self.pendingWindowRequest == request else { return }
            if let target {
                do { accepted=try await self.windowCatalog.current(target) }
                catch { self.stop();self.error=error.localizedDescription;return }
            }
            #endif
            guard self.generation == token,self.pendingWindowRequest == request else { return }
            self.windowTimeout?.cancel()
            self.captureWindowID=accepted?.number;self.selectedRemoteWindow=accepted
            self.activeVideoSource=accepted == nil ? "none":"window"
            do {
                if accepted != nil { try self.makeEngine(isHost:true) }
                self.expectedMediaSession=self.engine?.sessionID
                #if os(macOS)
                if self.enablesWindowControl,let accepted {
                    do { self.hostControl=try HostWindowControl(target:accepted) }
                    catch { warning=error.localizedDescription }
                    self.controlLease=self.hostControl?.lease
                }
                #endif
                self.sendWindow(WindowMessage(action:"selected",requestID:request,selected:accepted,
                    mediaSession:self.expectedMediaSession,error:warning,controlLease:self.controlLease))
                self.pendingWindowRequest=nil;self.pendingWindowTarget=nil;self.pendingWindowViewport=nil;self.windowBusy=false
                if accepted != nil { self.engine?.startOffer() }
            } catch { self.stop();self.error=error.localizedDescription }
        }
    }

    func startLocalDemo(endpoint: String = "127.0.0.1", useCurrentPreset: Bool = false) {
        stop()
        let local = LabModel()
        local.frameTraceDirectory = frameTraceDirectory
        local.bridgeTransport = bridgeTransport
        local.bridgeReceiveDepth = bridgeReceiveDepth
        local.mediaRoute = mediaRoute
        local.resolution = useCurrentPreset ? resolution : "1280×720"
        local.fps = useCurrentPreset ? fps : 30; local.megabits = useCurrentPreset ? megabits : 8
        local.pattern = useCurrentPreset ? pattern : .grid
        local.captureWindowID = captureWindowID
        local.hdr = hdr
        local.port = String(UInt16.random(in: 49000...59000))
        local.mediaPort = String(UInt16.random(in: 49000...59000))
        local.startHost()
        guard local.running else { error = local.error; return }
        host = endpoint; port = local.port; pairingKey = local.pairingKey; mediaPort = local.mediaPort
        resolution = local.resolution; fps = local.fps; megabits = local.megabits; pattern = local.pattern
        connect()
        demoHost = local; mode = "local-loopback"
        networkLabel = "本机回环（不代表远程网络）"
        connectedNetworkLabel = networkLabel
    }
    var localHostError: String? { demoHost?.error }
    func exportLocalHostReport(to destination: URL) {
        demoHost?.exportReport(to: destination)
        if let error = demoHost?.error { self.error = error }
    }

    func stop() {
        #if os(macOS)
        if nativeWorkspaceDisplayID != nil {
            if Thread.isMainThread { MainActor.assumeIsolated { _=HostWindowLayout.restoreNativeWindows() } }
            else {Task { @MainActor in await HostWindowLayout.restoreNativeWindows().value }}
        }
        #endif
        resetControl();windowControlSupported=false;directKeyboardSupported=false
        if running, let diagnosticRunDirectory {
            exportReport(to: diagnosticRunDirectory.appendingPathComponent(mode == "host" ? "host.json" : "viewer.json"))
        }
        generation = UUID(); engineGeneration = UUID()
        diagnosticStopTimer?.invalidate(); diagnosticStopTimer = nil
        windowTimeout?.cancel(); windowTimeout = nil; pendingWindowRequest = nil; pendingWindowTarget = nil
        expectedMediaSession = nil; windowSession = ""; windowSupported = false
        windowLayoutSupported=false; appliedWindowViewport=nil; pendingWindowViewport=nil;layoutDebounce?.cancel()
        windowBusy = false; catalogLoading = false; catalogRequestID = nil; remoteWindows = []; selectedRemoteWindow = nil
        windowError = nil; windowStatus = "连接后可查看远端窗口"
        engine?.stop(); engine = nil; signal?.stop(); signal = nil
        demoHost?.stop(); demoHost = nil
        track = nil; running = false; status = "已停止"
    }

    func exportReport(to destination: URL? = nil, recentSamples: Int? = nil) {
        let report = LabReport(schemaVersion: 10,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            backend: "libwebrtc M157 / H.264 SDR or VT HEVC Main10 PQ; see actual codec and pixel formats", os: ProcessInfo.processInfo.operatingSystemVersionString,
            mode: mode, networkLabel: networkLabel, actualOverlayPath: "unknown", pacing: WebRTCRuntime.mode,
            pacingParameters: WebRTCRuntime.mode.screenShareSettings, playout: WebRTCRuntime.playout, bridgeReceiveDepth: activeReceiveDepth, bridgeTransport: activeBridgeTransport, mediaRoute: activeRoute, preset: activePreset, videoSource: activeVideoSource,
            notes: [activeRoute != .directICE ? "Fixed UDP carries ICE/DTLS/SRTP/SCTP through the configured endpoint. The outer Ponte channel is not observed." : "Direct ICE can use any reachable adapter; the network label does not constrain it.",
                    "Control RTT is an echoed DataChannel round trip, not input-to-photon latency.",
                    "Playout is this process's sender policy. A remote sender may signal its own RTP playout-delay hint; it is not an end-to-end latency cap.",
                    "RTP, transport and bridge byte counters cover different layers; bridge bytes exclude the outer overlay and IP overhead. RTX receive counts may include payload padding/probes.",
                    "Send/decode/jitter-buffer delays are means over each stats interval; their P95 is not a per-frame P95. Encoder callback timing includes submission-to-callback work.",
                    "Pacing queue time is a drain target, not a hard packet lifetime. A full-size UDP probe proves delivery at setup, not the path IP MTU or sustained capacity.",
                    "Socket scope alone cannot prove physical topology: a remote overlay proxy can present a loopback endpoint. Local-demo mode is always a single-device test.",
                    "Socket transport is IPv4-only. Bridge sequence holes can include sender discards or reordering; they are not automatically permanent network loss. Frame gaps measure renderer callbacks, not display photons.",
                    "Queue age only covers the application adapter, not OS/overlay/encoder queues. P95 covers the latest 120 successful echoes; probe counters expose expiration.",
                    "Candidate host/UDP does not prove Tailscale direct or a Ponte channel type.",
                    "HEVC Main10 PQ is selected only with a new receiver's explicit format answer; legacy receivers fall back to H.264 SDR. For window and HDR ramp sources preset.pattern is unused.",
                    "Window capture follows display cadence and damage; RTCVideoSource caps output at preset.fps. Capture callbacks may exceed output fps. Idle frames are not encoder drops. WindowServer age ends at the capture callback, not remote display; source dimensions are sampled at capture start.",
                    "Report excludes pairing key, SDP, endpoint addresses, window identifiers/titles, user input and video content.",
                    "Window selection restarts media statistics. Reports retain only the current media generation; prior windows are not combined with reset counters."]
                    + ["Encoder asyncFailures are explicit VT/Annex-B outcomes. unmatchedExpired, resetPendingUnknown, trackingOverflow and outputWithoutInput are observation gaps, not proven encoder or network drops. Optional sender traces use exact weak RTC wrapper identity, never nearest-timestamp matching."]
                    + ["Receiver decoder callbacks, per-view main-queue dequeue and display enqueue are separately observed. Enqueue is API submission, not physical presentation. Presentation observer IDs isolate view bindings; timeout/collision counts are unknown, not proven decoder drops."]
                    + ["Resource CPU is process CPU with 100% per core; it excludes WindowServer/Surge. Thermal state is categorical, not measured degrees. GPU utilization is not observed. Diagnostic impairment affects host outbound RTP only; its delay/drop counters are separate from production bridge queues."]
                    + (recentSamples == nil ? [] : ["Live snapshot contains only the latest samples; session-end reports retain the current media generation's bounded history."]),
            samples: recentSamples.map { Array(samples.suffix(max(0, $0))) } ?? samples,
            historyLimit: diagnosticHistoryLimit, sampleJournal: sampleJournal?.snapshot())
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let path = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("KKRemote-Lab-\(UUID().uuidString.prefix(8)).json")
            try encoder.encode(report).write(to: path, options: .atomic)
            exportedReport = path
        } catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
}
