#if os(iOS)
import SwiftUI

/// The video stays mounted while settings and diagnostic sheets are presented.
struct IOSLabView: View {
    @ObservedObject var model: LabModel
    @StateObject private var preferences = ConnectionPreferences()
    @StateObject private var viewport = MobileInteractionSession(directScroll:true,locksWholeWindow:UIDevice.current.userInterfaceIdiom == .phone)
    @StateObject private var edgeAppearance = WindowEdgeAppearance()
    @AppStorage("viewerDesktopColors") private var desktopColors=true
    @Environment(\.scenePhase) private var scenePhase
    @State private var resumeProfile: ConnectionProfile?
    @State private var resumeWindow: RemoteWindow?
    @State private var awaitingResumeCatalog = false
    @State private var resumeTask: Task<Void,Never>?
    @State private var interactionPractice = false
    @State private var phonePreview = false
    @State private var xPreview = false
    #if targetEnvironment(simulator)
    private struct WPSReview: Decodable {
        let port: UInt16
        let pairingKey: String
        let windowNumber: UInt32
        let title: String
    }
    @State private var wpsReview: WPSReview?
    @State private var wpsReviewLoaded = false
    @State private var wpsTrimPadding = true
    #endif
    @State private var phoneWindows = false
    @StateObject private var phoneText = MobileTextSession()
    @State private var remotePointer: CGPoint?
    @State private var remotePressed: CGPoint?
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    @State private var page = 0
    @State private var fullscreen = false
    @State private var diagnostics = false
    @State private var licenseVisible = false
    @State private var showCode = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale

    private let background = Color(uiColor: .systemGroupedBackground)
    private let surface = Color(uiColor: .secondarySystemGroupedBackground)
    private var hasVideo: Bool { model.running && !model.windowBusy && model.sample.framesDecoded > 0 }
    private var hasSample: Bool { model.running && model.lastSampleAt != nil }
    private var currentHost: String { model.running ? model.connectedHost : preferences.profile.host }
    private var network: String { model.running ? model.connectedNetworkLabel : preferences.profile.network }

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            #if WPS_INTERACTIVE_REVIEW
            if CommandLine.arguments.contains("--wps-interactive-review") { WPSWorkspace() }
            else { simulatorWorkspace }
            #else
            simulatorWorkspace
            #endif
            #else
            clientWorkspace
            #endif
        }
        .background {
            if isPhone {
                edgeAppearance.background.ignoresSafeArea()
                    .background(WindowSceneBackground(color:edgeAppearance.color))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(get: { isPhone && page == 1 }, set: { if !$0 { page = 0 } })) {
            NavigationStack {
                settings.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { page = 0 } } }
            }
        }
        .sheet(isPresented: $phoneWindows) { RemoteWindowsView(model: model) { phoneWindows = false } }
        .sheet(isPresented: $diagnostics) { diagnosticSheet }
        .sheet(isPresented: $licenseVisible) { licenseSheet }
        .sheet(isPresented: $interactionPractice) { MobileInputPracticeView() }
        .onChange(of: page) { _, _ in viewport.invalidate() }
        .onChange(of:model.canControl) { _,enabled in viewport.enableRemoteInput(enabled);if !enabled { phoneText.cancel();remotePressed=nil } }
        .onChange(of:model.controlError) { _,error in if error != nil { phoneText.cancel() } }
        .onChange(of: model.windowBusy) { _, busy in if busy { viewport.fit() } }
        .onChange(of: model.remoteWindows) { _, windows in
            if awaitingResumeCatalog && !model.catalogLoading { restoreViewing(from:windows) }
            #if targetEnvironment(simulator)
            if let review = wpsReview, model.selectedRemoteWindow == nil,
               let window = windows.first(where: { $0.number == review.windowNumber && $0.title == review.title && $0.application == "WPS Office" }) {
                model.selectRemoteWindow(window)
            }
            #endif
        }
        .onChange(of: model.catalogLoading) { _, loading in
            if !loading && awaitingResumeCatalog { restoreViewing(from:model.remoteWindows) }
        }
        .onChange(of: model.track.map(ObjectIdentifier.init)) { _, _ in edgeAppearance.bind(model.track);sampleVisibleEdge() }
        .onChange(of: viewport.geometry.contentRect) { _, _ in sampleVisibleEdge() }
        .onChange(of: videoSourceSize) { _, _ in sampleVisibleEdge() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                resumeTask?.cancel();resumeTask = nil
                if model.running && model.mode == "viewer" {
                    var profile = preferences.profile
                    profile.host = model.host;profile.pairingCode = model.pairingKey
                    profile.port = model.port;profile.mediaPort = model.mediaPort
                    profile.route = model.mediaRoute;profile.transport = model.bridgeTransport
                    profile.network = model.networkLabel
                    resumeProfile = profile;resumeWindow = model.selectedRemoteWindow
                }
                awaitingResumeCatalog = false;phoneWindows = false;model.stop()
                edgeAppearance.bind(nil)
            } else if phase == .active, let profile = resumeProfile {
                guard !model.running,profile.validationError == nil else { return }
                // The existing persistent Host releases media before reopening
                // its listener (one second). Do not race that teardown on a quick return.
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(for:.milliseconds(1500))
                    guard !Task.isCancelled,scenePhase == .active,!model.running else { return }
                    resumeProfile = nil
                    awaitingResumeCatalog = true;profile.apply(to:model);model.connect()
                    resumeTask = nil
                }
            }
        }
        .onChange(of: preferences.profile) { _, _ in preferences.save() }
        .onChange(of: model.running) { _, running in UIApplication.shared.isIdleTimerDisabled = running }
        .onAppear {
            viewport.enableRemoteInput(model.canControl)
            viewport.onEvent=handleRemoteInput
            if preferences.profile.validationError == nil { preferences.save() }
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--offline-interaction-review") { interactionPractice = true }
            if CommandLine.arguments.contains("--iphone-workspace-review") { phonePreview = true }
            if CommandLine.arguments.contains("--x-preview-url") { xPreview = true }
            if CommandLine.arguments.contains("--wps-window-review") { startWPSReview() }
            #endif
        }
        .overlay(alignment:.topLeading) {
            if CommandLine.arguments.contains("--viewer-ui-review") {
                Color.clear.frame(width:1,height:1).accessibilityElement()
                    .accessibilityLabel("Viewer state").accessibilityValue(viewerMetadata)
                    .accessibilityIdentifier("viewerState").allowsHitTesting(false)
            }
        }
    }

    #if targetEnvironment(simulator)
    @ViewBuilder private var simulatorWorkspace: some View {
        if xPreview { IPhoneXPreview(close: { xPreview = false }) }
        else if phonePreview { IPhoneOfflineWorkspace(close: { phonePreview = false }) }
        else { clientWorkspace }
    }
    #endif

    @ViewBuilder private var clientWorkspace: some View {
        if isPhone { phoneWorkspace } else { labWorkspace }
    }

    private var phoneWorkspace: some View {
        IPhoneWindowWorkspace(title: model.selectedRemoteWindow?.title ?? "KKRemote",
            subtitle: model.windowBusy ? "正在切换窗口…" : (hasVideo ? (model.canControl ? "轻点操作 · 滑动滚动" : "接收中 · 当前仅支持观看") :
                (model.windowSupported ? "已连接 · 当前仅支持观看" : (model.running ? "连接中" : "未连接"))),
            symbol: "macwindow", target: model.selectedRemoteWindow?.id ?? "none",
            hasWindow: hasVideo,
            canChooseWindow: model.running && model.windowSupported && !model.windowBusy,
            interaction: viewport, text: phoneText, directKeyboard:true,
            onKeyboardFocus:{ model.sendInput(kind:"focus") },
            onKeyboardText:{ model.sendInput(kind:"insertText",text:$0) },
            onKeyboardKey:{ model.sendInput(kind:"key",key:$0) },
            canEnterText:model.directKeyboardSupported,edgeColor:edgeAppearance.color,
            chooseWindow: { phoneWindows = true; model.refreshRemoteWindows() }) {
                Picker("画面显示",selection:$desktopColors) {
                    Text("桌面").tag(true)
                    Text("HDR").tag(false)
                }
                if let warning=model.windowError { Text(warning) }
                if model.canControl {
                    Button("回车",systemImage:"return") { model.sendInput(kind:"key",key:"return") }
                    Button("退格",systemImage:"delete.left") { model.sendInput(kind:"key",key:"backspace") }
                    Button("取消编辑",systemImage:"escape") { model.sendInput(kind:"key",key:"escape") }
                }
                Button("连接设置", systemImage: "gearshape") { page = 1 }
                    .accessibilityIdentifier("phoneConnectionSettingsMenu")
                Button("详细数据", systemImage: "waveform.path.ecg") { diagnostics = true }
                if model.track != nil && model.windowSupported {
                    Button("停止观看，保留连接",systemImage:"stop.circle") { model.selectRemoteWindow(nil) }
                        .disabled(model.windowBusy || model.catalogLoading).accessibilityIdentifier("phoneStopViewing")
                }
                #if targetEnvironment(simulator)
                if wpsReview != nil {
                    Toggle("去除编码留黑", isOn: $wpsTrimPadding)
                    Text("真实桌面 WPS · 当前只读")
                }
                Button("iPhone 离线预览", systemImage: "iphone") { phonePreview = true }.disabled(model.running)
                #endif
                if model.running || resumeTask != nil { Button(resumeTask != nil ? "取消重连" : "断开连接", systemImage: "xmark.circle", role: .destructive) { resumeTask?.cancel();resumeTask = nil;resumeProfile = nil;awaitingResumeCatalog = false;model.stop() } }
            } content: {
                if model.track != nil || model.running || resumeTask != nil { streamContent }
                else {
                    VStack(spacing: 18) {
                        Spacer()
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 46, weight: .light)).foregroundStyle(.tint)
                        VStack(spacing: 10) {
                            Text("把桌面窗口，带到手边").font(.title2.bold())
                            Text("连接 Mac，选择一个应用窗口开始。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.multilineTextAlignment(.center)
                        Button("连接主机", action: connectOrStop).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("phoneConnect")
                        Button("连接设置") { page = 1 }.font(.subheadline)
                        if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                        #if targetEnvironment(simulator)
                        Button("体验 iPhone 离线预览") { phonePreview = true }.font(.subheadline)
                            .accessibilityIdentifier("openPhonePreview")
                        #endif
                        Spacer()
                        Text("未连接").font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                    }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(.keyboard,edges:phoneText.focused ? []:.bottom)
    }

    private var labWorkspace: some View {
        VStack(spacing: 0) {
            header.frame(height: fullscreen ? 0 : nil).clipped().accessibilityHidden(fullscreen)
                .allowsHitTesting(!fullscreen)
            GeometryReader { geometry in
                ZStack {
                    dashboard(size: geometry.size)
                        .accessibilityHidden(page != 0).allowsHitTesting(page == 0)
                    if page == 1 { settings.background(background) }
                }
            }
            tabs.frame(height: fullscreen ? 0 : 56).clipped().accessibilityHidden(fullscreen)
                .allowsHitTesting(!fullscreen)
        }
        .background(fullscreen ? Color.black : background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(page == 0 ? "KKRemote" : "设置").font(.title2.bold())
                    Text("LAB").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
                Text(page == 0 ? "\(currentHost.isEmpty ? "尚未设置主机" : currentHost) · \(network)" : "连接与测试设置")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Label(model.windowBusy ? "切换中" : (hasVideo ? "接收中" :
                (model.windowSupported ? "已连接" : (model.running ? "连接中" : "未连接"))), systemImage: "circle.fill")
                .font(.caption).foregroundStyle(hasVideo ? Color.green : Color.secondary)
                .labelStyle(.titleAndIcon)
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func dashboard(size: CGSize) -> some View {
        let wide = size.width > size.height && !typeSize.isAccessibilitySize && !fullscreen
        let sideWidth = min(320.0, size.width * 0.38)
        let videoWidth = max(1, size.width - (wide ? sideWidth + 44 : 32))
        let videoHeight = fullscreen ? max(1, size.height) : min(videoWidth * videoSourceSize.height / videoSourceSize.width,
            max(120, size.height - (wide ? 92 : 414)))
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(spacing: fullscreen ? 0 : 10))
        return ScrollView {
            layout {
                VStack(spacing: 0) {
                    RemoteWindowControls(model: model)
                        .frame(height: fullscreen ? 0 : 52).clipped().accessibilityHidden(fullscreen)
                        .allowsHitTesting(!fullscreen)
                    videoPane.frame(height: videoHeight)
                    formatRow.frame(height: fullscreen ? 0 : 32).clipped().accessibilityHidden(fullscreen)
                }.frame(maxWidth: .infinity)
                statistics
                    .frame(width: wide && !fullscreen ? sideWidth : nil, height: fullscreen ? 0 : nil)
                    .opacity(fullscreen ? 0 : 1).clipped().accessibilityHidden(fullscreen)
                    .allowsHitTesting(!fullscreen)
            }
            .padding(.horizontal, fullscreen ? 0 : 16)
        }.scrollBounceBehavior(.basedOnSize).scrollDisabled(fullscreen)
    }

    private var streamContent: some View {
        ZStack {
            edgeAppearance.background
            if model.windowBusy {
                VStack(spacing: 10) { ProgressView(); Text("正在切换窗口…") }
                    .foregroundStyle(.primary)
            } else if let track = model.track {
                MobileViewport(session: viewport, source: workspaceSourceSize,
                    target: "\(model.selectedRemoteWindow?.id ?? "default")-\(ObjectIdentifier(track))",background:edgeAppearance.background,encodedPixels: pixelAlignmentSource,geometryContent: { geometry in
                    // Host aspect-fits at the encoded canvas origin; remove only
                    // known padding. The same source-point geometry drives touch mapping.
                    let size = geometry.contentSize
                    let scale = max(size.width/videoSourceSize.width,size.height/videoSourceSize.height)
                    let rendererSize = geometry.pixelExact ? size : CGSize(width:videoSourceSize.width*scale,height:videoSourceSize.height*scale)
                    ColorManagedVideo(track:track,desktopColors:isPhone && desktopColors).id(isPhone && desktopColors)
                        .frame(width:rendererSize.width,height:rendererSize.height)
                        .frame(width:size.width,height:size.height,alignment:.topLeading).clipped()
                        // HEVC is opaque: the captured macOS corner surround cannot
                        // reveal the App background until the window silhouette is clipped.
                        .clipShape(RoundedRectangle(cornerRadius:isPhone && model.selectedRemoteWindow != nil ? 20*size.width/workspaceSourceSize.width:0,style:.continuous))
                })
                .allowsHitTesting(hasVideo)
                .opacity(hasVideo ? 1 : 0)
                .overlay { if !hasVideo { ProgressView("等待首帧…").padding(12).background(.regularMaterial,in:Capsule()) } }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display").font(.title)
                    Text(resumeTask != nil ? "正在恢复连接…" : (model.windowSupported ? "请选择远端窗口" :
                        (model.running ? "等待远端画面" : "准备开始测试"))).font(.headline)
                    Text(model.windowError ?? (model.windowSupported ? model.windowStatus :
                        (model.running ? model.status : "使用已保存的连接设置"))).font(.caption).multilineTextAlignment(.center)
                }.foregroundStyle(.primary).padding()
            }
        }
        .overlay(alignment:.top) {
            if let error=model.controlError {
                Text(error).font(.caption).padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(8).allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { if isPhone && !phoneWindows && !phoneText.focused { model.updateWindowViewport(proxy.size,displayScale:Double(displayScale)) } }
                    .onChange(of:proxy.size) { _,size in if isPhone && !phoneWindows && !phoneText.focused { model.updateWindowViewport(size,displayScale:Double(displayScale)) } }
            }
        }
    }

    private var videoPane: some View {
        streamContent
        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 12))
        .overlay(alignment: .bottomLeading) {
            if viewport.zoom > 1, model.track != nil {
                Button { viewport.fit() } label: {
                    Label("完整显示", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).padding(10).background(.black.opacity(0.65)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.padding(8).accessibilityIdentifier("viewportFit")
            }
        }
        .overlay(alignment: fullscreen ? .topTrailing : .bottomTrailing) {
            Button { fullscreen.toggle() } label: {
                Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44).background(.black.opacity(0.55)).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏查看画面")
                .padding(fullscreen ? 8 : 0)
        }
        .overlay(alignment: .topLeading) {
            if fullscreen {
                Text("\(number(model.sample.fps, available: hasVideo)) fps · \(number(model.sample.videoMbps, available: hasVideo)) Mbps · 往返 \(milliseconds(model.sample.controlRTTMilliseconds))")
                    .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).padding(8).foregroundStyle(.white)
                    .background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(8)
                    .padding(.trailing, 60)
            }
        }
    }

    // Statistics can size a local viewing surface, but do not authorize remote
    // input. MobileInteractionSession defaults to read-only and has no transport.
    private var workspaceSourceSize: CGSize {
        #if targetEnvironment(simulator)
        if wpsReview != nil && wpsTrimPadding, let window = model.selectedRemoteWindow,
           window.widthPoints > 0, window.heightPoints > 0 {
            return CGSize(width:window.widthPoints,height:window.heightPoints)
        }
        #endif
        if let window = model.selectedRemoteWindow,window.widthPoints>0,window.heightPoints>0 {
            return CGSize(width:window.widthPoints,height:window.heightPoints)
        }
        return videoSourceSize
    }

    private func handleRemoteInput(_ event:MobileInputEvent) {
        guard model.canControl else { remotePressed=nil;return }
        switch event {
        case let .move(point): remotePointer=point
        case .buttonDown: remotePressed=remotePointer
        case .buttonUp:
            if let point=remotePressed { model.sendInput(kind:"click",x:point.x,y:point.y) }
            remotePressed=nil
        case let .secondaryClick(point): model.sendInput(kind:"secondary",x:point.x,y:point.y)
        case let .scroll(delta):
            if let point=remotePointer { model.queueInputScroll(point:point,delta:delta) }
        case .scrollEnd: model.flushInputScroll()
        case let .text(text,id): model.sendInput(kind:"insertText",text:text,id:id.uuidString)
        case .cancel: remotePressed=nil
        }
    }

    private func sampleVisibleEdge() { edgeAppearance.update(geometry:viewport.geometry,encoded:videoSourceSize) }
    private func restoreViewing(from windows:[RemoteWindow]) {
        guard model.windowSupported,!model.catalogLoading,!model.windowBusy else { return }
        awaitingResumeCatalog = false
        if let old = resumeWindow,let fresh = windows.first(where: {
            $0.number == old.number && $0.processID == old.processID && $0.title == old.title
        }) { model.selectRemoteWindow(fresh) }
        else { phoneWindows = true }
        resumeWindow = nil
    }
    private var viewerMetadata:String {
        let g = viewport.geometry
        let presentation=model.sample.receiverDetails?.presentations.last(where:{$0.active})
        let fields:[String:Any] = ["running":model.running,"supported":model.windowSupported,
            "ready":hasVideo,"busy":model.windowBusy,"selected":model.selectedRemoteWindow?.title ?? "",
            "selectedID":model.selectedRemoteWindow?.id ?? "","frames":model.sample.framesDecoded,
            "codec":model.sample.codec,"transfer":model.sample.decodedPixelFormat?["transfer"] ?? "",
            "width":model.sample.width,"height":model.sample.height,"zoom":viewport.zoom,
            "controllable":model.canControl,"inputAcknowledged":model.inputAcknowledged,
            "keyboardSupported":model.directKeyboardSupported,"keyboardFocusReady":model.controlState?.focus != nil,
            "controlError":model.controlError ?? "","inputQueueCount":model.inputQueueCount,
            "keyboardWidthLocked":viewport.fitsKeyboardWidth,"keyboardFocused":phoneText.focused,
            "displayPixelWidth":model.sample.receiverDetails?.presentations.last(where:{$0.active})?.outputWidth ?? 0,
            "displayPixelHeight":model.sample.receiverDetails?.presentations.last(where:{$0.active})?.outputHeight ?? 0,
            "displayOneToOne":presentation?.pixelOneToOne ?? false,
            "surfacePixelWidth":presentation?.surfacePixelWidth ?? 0,"surfacePixelHeight":presentation?.surfacePixelHeight ?? 0,
            "surfacePixelX":presentation?.surfacePixelX ?? 0,"surfacePixelY":presentation?.surfacePixelY ?? 0,
            "locked":viewport.locksWholeWindow,"layoutSupported":model.windowLayoutSupported,
            "sourceWidth":workspaceSourceSize.width,"sourceHeight":workspaceSourceSize.height,
            "viewportWidth":g.viewport.width,"viewportHeight":g.viewport.height,
            "contentWidth":g.contentRect.width,"contentHeight":g.contentRect.height,
            "pixelExact":hasVideo && g.pixelExact,"displayScale":g.displayScale,
            "contentPixelWidth":g.contentSize.width*g.displayScale,"contentPixelHeight":g.contentSize.height*g.displayScale,
            "contentPixelX":g.contentRect.minX*g.displayScale,"contentPixelY":g.contentRect.minY*g.displayScale,
            "layoutWarning":model.windowError ?? "",
            "fill":viewport.fillsViewport,"x":g.contentRect.minX,"y":g.contentRect.minY,
            "edgeReady":edgeAppearance.ready,"nativeEdgeReady":edgeAppearance.nativeColor != nil,"edgeRed":edgeAppearance.color.red,
            "edgeGreen":edgeAppearance.color.green,"edgeBlue":edgeAppearance.color.blue,"desktopColors":desktopColors,
            "nativeLuma":edgeAppearance.nativeColor.flatMap { HDRFormat.lumaSamples($0) } ?? [:],
            "displayHeadroom":UIScreen.main.currentEDRHeadroom,"potentialHeadroom":UIScreen.main.potentialEDRHeadroom,
            "displayEnqueued":model.sample.receiverDetails?.presentations.filter { $0.active }.reduce(0) { $0+$1.enqueued } ?? 0,
            "displayFailures":model.sample.receiverDetails?.presentations.filter { $0.active }.reduce(0) { $0+$1.failures } ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject:fields),let value = String(data:data,encoding:.utf8) else { return "{}" }
        return value
    }

    #if targetEnvironment(simulator)
    private func startWPSReview() {
        guard !wpsReviewLoaded else { return }
        wpsReviewLoaded = true
        do {
            let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            let data = try Data(contentsOf:documents.appendingPathComponent("WPSWindowReview.json"))
            let review = try JSONDecoder().decode(WPSReview.self,from:data)
            guard review.port > 0, review.port != 45990, !review.pairingKey.isEmpty,
                  review.title.hasPrefix("KKRemote-WPS-Test-") else { return }
            wpsReview = review
            wpsTrimPadding = !CommandLine.arguments.contains("--wps-full-frame")
            model.host = "127.0.0.1"; model.port = String(review.port)
            model.pairingKey = review.pairingKey
            model.mediaRoute = .directICE
            model.networkLabel = "WPS 模拟器隔离测试"
            model.connect()
        } catch { model.error = "独立 WPS 测试配置不可用" }
    }
    #endif

    private var pixelAlignmentSource: CGSize? {
        guard hasVideo, model.selectedRemoteWindow != nil, model.sample.width > 0, model.sample.height > 0 else { return nil }
        return CGSize(width:model.sample.width,height:model.sample.height)
    }

    private var videoSourceSize: CGSize {
        guard model.sample.width > 0, model.sample.height > 0 else { return CGSize(width: 1280, height: 720) }
        return CGSize(width: model.sample.width, height: model.sample.height)
    }

    private var formatRow: some View {
        HStack {
            Text(hasVideo ? "\(model.sample.width) × \(model.sample.height)" : "等待视频")
            Spacer()
            Text(hasVideo ? "\(codecName) · \(colorName)" : "连接后显示实际格式")
        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    private var codecName: String {
        if model.sample.codec.lowercased().contains("h265") { return "HEVC" }
        if model.sample.codec.lowercased().contains("h264") { return "H.264" }
        return model.sample.codec
    }
    private var colorName: String {
        guard let format = model.sample.decodedPixelFormat else { return "色彩待确认" }
        return format["transfer"] == "SMPTE_ST_2084_PQ" ? "10 位 PQ" : "SDR"
    }

    private var statistics: some View {
        VStack(spacing: 9) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                stat("接收帧率", number(model.sample.fps, available: hasVideo), "fps")
                stat("实际视频码率", number(model.sample.videoMbps, available: hasVideo), "Mbps")
                stat("控制消息往返", number(model.sample.controlRTTMilliseconds, available: hasSample), "ms")
                stat("接收缓冲", number(model.sample.jitterBufferMilliseconds, available: hasVideo), "ms")
            }
            HStack(spacing: 0) {
                counter("冻结", model.sample.freezeCount)
                Divider().frame(height: 22)
                counter("解码丢帧", model.sample.framesDropped)
                Divider().frame(height: 22)
                counter("RTP 丢包", model.sample.packetsLost)
            }.padding(.vertical, 10).background(surface, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Label("屏幕 HDR 余量", systemImage: "sun.max")
                Spacer()
                Text(hasVideo ? model.sample.displayHeadroom.map { String(format: "%.1f×%@", $0, $0 > 1 ? "" : " · SDR") } ?? "—" : "—")
                    .monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 3)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.windowError {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button { diagnostics = true } label: { Label("详细数据", systemImage: "waveform.path.ecg").frame(maxWidth: .infinity, minHeight: 26) }
                    .buttonStyle(.bordered)
                Button(action: connectOrStop) {
                    Text(model.running ? (hasVideo || model.windowSupported ? "断开连接" : "取消连接") : "连接主机").frame(maxWidth: .infinity, minHeight: 26)
                }.buttonStyle(.borderedProminent)
            }.font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let stale = model.running && model.lastSampleAt.map { context.date.timeIntervalSince($0) > 3 } == true
                Text(stale ? "数据已暂停 · 请检查媒体连接" : "往返 ≠ 画面端到端延迟 · 每秒更新")
                    .font(.system(size: 11)).foregroundStyle(stale ? Color.orange : Color.secondary)
            }
        }
    }
    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background(surface, in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .combine)
    }
    private func counter(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 5) {
            Text(hasVideo ? "\(value)" : "—").font(.headline).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            tab("测试", image: "play.rectangle", index: 0)
            tab("设置", image: "slider.horizontal.3", index: 1)
        }.padding(.top, 6).background(surface).overlay(alignment: .top) { Divider() }
    }
    private func tab(_ title: String, image: String, index: Int) -> some View {
        Button { page = index } label: {
            VStack(spacing: 2) { Image(systemName: image).font(.system(size: 20)); Text(title).font(.system(size: 11)) }
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.foregroundStyle(page == index ? Color.accentColor : Color.secondary)
            .accessibilityAddTraits(page == index ? .isSelected : [])
    }

    private var settings: some View {
        Form {
            Section {
                TextField("主机地址", text: $preferences.profile.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityLabel("主机地址")
                HStack {
                    Text("配对码")
                    if showCode { TextField("配对码", text: $preferences.profile.pairingCode).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { SecureField("配对码", text: $preferences.profile.pairingCode) }
                    Button(showCode ? "隐藏" : "显示") { showCode.toggle() }.font(.caption).buttonStyle(.borderless)
                }
                portField("信令端口", value: $preferences.profile.port)
                portField("媒体端口", value: $preferences.profile.mediaPort)
            } header: { Text("常用连接 · 自动保存到此设备") }
              footer: { Text(preferences.saveError ?? "修改会保留，下次连接时生效。") }
            Section("传输设置") {
                Picker("媒体路径", selection: $preferences.profile.route) {
                    Text("固定 UDP v2").tag(MediaRoute.ponteUDP)
                    Text("原生 ICE").tag(MediaRoute.directICE)
                    Text("固定 UDP v1").tag(MediaRoute.ponteUDPv1)
                }
                if preferences.profile.route != .directICE {
                    Picker("UDP 实现", selection: $preferences.profile.transport) {
                        Text("UDP socket").tag(BridgeTransportKind.socket)
                        Text("Network.framework").tag(BridgeTransportKind.network)
                    }
                }
                Picker("网络标签", selection: $preferences.profile.network) {
                    ForEach(["Surge Ponte", "LAN", "Tailscale"], id: \.self) { Text($0) }
                }
            }
            Section {
                Button("恢复测试默认值") { preferences.restoreDefaults() }
            } footer: {
                Text("分辨率、帧率和码率由 Mac 主机控制。首页显示实际收到的视频数据。网络标签只用于记录。")
            }
            Section {
                #if targetEnvironment(simulator)
                Button("离线交互练习") { viewport.invalidate(); interactionPractice = true }
                    .accessibilityIdentifier("openInteractionPractice")
                #endif
                Button("本机回环自检") { preferences.profile.apply(to: model); model.startLocalDemo(); page = 0 }.disabled(model.running)
                Button("第三方许可") { licenseVisible = true }
                LabeledContent("版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")）")
            } header: { Text("测试工具") }
              footer: { Text("本机自检不代表 Ponte 远程性能。当前测试不包含音频或键鼠控制。") }
        }.scrollDismissesKeyboard(.interactively)
    }
    private func portField(_ title: String, value: Binding<String>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, text: value).multilineTextAlignment(.trailing).keyboardType(.numberPad).frame(width: 110) }
    }
    private func connectOrStop() {
        resumeTask?.cancel();resumeTask = nil
        resumeProfile = nil;awaitingResumeCatalog = false;resumeWindow = nil
        if model.running { model.stop(); return }
        guard preferences.save() else { page = 1; return }
        preferences.profile.apply(to: model)
        model.connect()
    }

    private var diagnosticSheet: some View {
        NavigationStack {
            List {
                Section("画面") {
                    row("接收帧率", "\(number(model.sample.fps, available: hasVideo)) fps")
                    row("实际码率", "\(number(model.sample.videoMbps, available: hasVideo)) Mbps")
                    row("分辨率", hasVideo ? "\(model.sample.width) × \(model.sample.height)" : "—")
                    row("接收缓冲", milliseconds(model.sample.jitterBufferMilliseconds))
                    row("冻结 / 解码丢帧 / RTP 丢包", hasVideo ? "\(model.sample.freezeCount) / \(model.sample.framesDropped) / \(model.sample.packetsLost)" : "—")
                }
                Section("当前会话") {
                    row("连接状态", model.status)
                    row("控制消息往返 / P95", "\(milliseconds(model.sample.controlRTTMilliseconds)) / \(milliseconds(model.sample.controlP95Milliseconds))")
                    row("解码耗时", milliseconds(model.sample.decodeMilliseconds))
                    row("ICE RTT", milliseconds(model.sample.networkRTTMilliseconds))
                    row("NACK / 重传包", hasSample ? "\(model.sample.nackCount) / \(model.sample.retransmittedPacketsReceived.map(String.init) ?? "—")" : "—")
                    row("帧间隔 P95 / 最大", "\(milliseconds(model.sample.frameGapP95Milliseconds)) / \(milliseconds(model.sample.frameGapMaxMilliseconds))")
                    row("首帧耗时", milliseconds(model.sample.firstFrameMilliseconds))
                    row("实际编码", hasVideo ? model.sample.codec : "—")
                    row("色域", hasVideo ? model.sample.decodedPixelFormat?["primaries"] ?? "—" : "—")
                    row("传递函数", hasVideo ? model.sample.decodedPixelFormat?["transfer"] ?? "—" : "—")
                    if let bridge = model.sample.bridge, hasSample {
                        row("UDP 队列丢弃 / 超时分片", "\(bridge.queueDrops) / \(bridge.expiredAssemblies)")
                        row("UDP 探测 RTT", milliseconds(bridge.probeRTTMilliseconds))
                    }
                }
                Section {
                    Button("生成本次测试报告") { model.exportReport() }
                    if let report = model.exportedReport { ShareLink("分享 JSON 报告", item: report) }
                } footer: { Text("接收帧率来自解码回调。往返时间与接收缓冲不等于输入到显示延迟；无法获得的指标显示“—”。") }
            }.navigationTitle("详细数据").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { diagnostics = false } } }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).font(.subheadline).monospacedDigit()
    }
    private var licenseSheet: some View {
        NavigationStack {
            ScrollView {
                Text(Bundle.main.url(forResource: "WebRTC-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "许可证资源缺失")
                    .font(.caption).textSelection(.enabled).padding()
            }.navigationTitle("第三方许可").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { licenseVisible = false } } }
        }
    }
    private func number(_ value: Double?, available: Bool) -> String {
        guard available, let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }
    private func milliseconds(_ value: Double?) -> String {
        guard hasSample, let value else { return "—" }
        return String(format: "%.1f ms", value)
    }
}
#endif
