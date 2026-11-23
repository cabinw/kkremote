#if os(iOS) && targetEnvironment(simulator)
import SwiftUI

/// Screenshot/event adapter for an isolated X browser tab. This is deliberately
/// simulator-only and does not use LabModel, Host ports or the media transport.
@MainActor
final class XBrowserPreview: ObservableObject {
    struct Search: Decodable { let x, y, width, height: CGFloat; let focused: Bool; let value: String }
    private struct Frame: Decodable {
        let image: String; let width, height, pixelRatio: CGFloat
        let search: Search?; let status: String; let sequence: Int; let scrollY: Double?
    }
    private struct Work { let body: [String: Any]; let generation: Int }
    @Published private(set) var image: UIImage?
    @Published private(set) var source = CGSize(width: 402, height: 657)
    @Published private(set) var status = "正在加载真实 X 页面…"
    @Published private(set) var search: Search?
    @Published private(set) var resizing = true
    @Published private(set) var sequence = 0
    @Published private(set) var scrollY = 0.0
    @Published private(set) var retryText: (String, UUID)?
    @Published private(set) var inputError = false
    private var pendingReplacement: (String, UUID)?
    private var generation = 0
    private var requested = CGSize.zero
    private var queue: [Work] = []
    private var worker: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private let endpoint: URL?
    private let token: String
    private var accumulatedScroll: CGFloat = 0
    private var scrollTask: Task<Void, Never>?
    private var tapped = false
    private var textTask: Task<Void, Never>?
    var onSearchRequested: (String) -> Void = { _ in }

    init() {
        func argument(_ name: String) -> String? {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let candidate = argument("--x-preview-url").flatMap(URL.init(string:))
        endpoint = candidate?.scheme == "http" && candidate?.host == "127.0.0.1" && candidate?.path == "/event" ? candidate : nil
        token = argument("--x-preview-token") ?? ""
    }

    func resize(_ size: CGSize) {
        guard size != requested else { return }
        scrollTask?.cancel(); scrollTask = nil
        requested = size; generation += 1; resizing = true; tapped = false; accumulatedScroll = 0
        queue.removeAll { !["text","replaceText"].contains($0.body["kind"] as? String ?? "") }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            enqueue(["kind":"resize", "width":size.width, "height":size.height])
        }
    }
    func replaceSearch(_ value: String) {
        textTask?.cancel()
        let id = UUID(); pendingReplacement = (value,id); inputError = false
        textTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            queue.removeAll { $0.body["kind"] as? String == "replaceText" }
            enqueue(["kind":"replaceText", "text":value, "id":id.uuidString])
        }
    }
    func refresh() { enqueue(["kind":"refresh"]) }
    func clearSearch() {
        textTask?.cancel(); textTask = nil
        pendingReplacement = nil; retryText = nil; inputError = false
        queue.removeAll { ["text","replaceText"].contains($0.body["kind"] as? String ?? "") }
        enqueue(["kind":"clear"])
    }
    func retry() {
        if let (value,id) = pendingReplacement {
            inputError = false; enqueue(["kind":"replaceText", "text":value, "id":id.uuidString]); return
        }
        guard let (value,id) = retryText else { return }
        enqueue(["kind":"text", "text":value, "id":id.uuidString])
    }
    func consume(_ event: MobileInputEvent, interaction: MobileInteractionSession) {
        guard !resizing else { return }
        switch event {
        case .buttonDown: tapped = !interaction.isDragging
        case .buttonUp:
            if tapped, let p = interaction.pointer {
                enqueue(["kind":"tap", "x":p.x, "y":p.y])
                if let field = search, CGRect(x:field.x,y:field.y,width:field.width,height:field.height).contains(p) {
                    onSearchRequested(field.value)
                }
            }
            tapped = false
        case let .scroll(delta):
            accumulatedScroll += delta.height
            if scrollTask == nil {
                scrollTask = Task { [weak self] in
                    try? await Task.sleep(for:.milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    flushScroll(); scrollTask = nil
                }
            }
        case .scrollEnd:
            scrollTask?.cancel(); scrollTask = nil; flushScroll()
        case let .text(value,id):
            retryText = (value,id)
            enqueue(["kind":"text", "text":value, "id":id.uuidString])
        case .cancel: tapped = false; accumulatedScroll = 0; scrollTask?.cancel(); scrollTask = nil
        default: break
        }
    }
    func stop() { textTask?.cancel(); scrollTask?.cancel(); resizeTask?.cancel(); worker?.cancel(); worker = nil; queue = [] }
    private func flushScroll() {
        if abs(accumulatedScroll) > 1 { enqueue(["kind":"scroll", "dy":accumulatedScroll]) }
        accumulatedScroll = 0
    }
    private func enqueue(_ body: [String: Any]) {
        if body["kind"] as? String == "scroll", let last = queue.last, last.body["kind"] as? String == "scroll" {
            queue.removeLast()
            queue.append(Work(body: ["kind":"scroll", "dy":(last.body["dy"] as? CGFloat ?? 0) + (body["dy"] as? CGFloat ?? 0)], generation:generation))
        } else { queue.append(Work(body:body,generation:generation)) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !queue.isEmpty && !Task.isCancelled {
                let work = queue.removeFirst()
                if work.generation != generation && !["text","replaceText"].contains(work.body["kind"] as? String ?? "") { continue }
                await perform(work)
            }
            worker = nil
        }
    }
    private func perform(_ work: Work) async {
        guard let endpoint, !token.isEmpty else { status = "预览适配器未启动"; resizing = false; return }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 25
            request.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
            request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:work.body)
            let (data,response) = try await URLSession.shared.data(for:request)
            guard !Task.isCancelled else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let value = (try? JSONSerialization.jsonObject(with:data)) as? [String:String]
                status = value?["error"] ?? "预览请求失败，可重试"
                if work.body["kind"] as? String == "replaceText" { inputError = true }
                if work.generation == generation { resizing = false }
                return
            }
            let frame = try JSONDecoder().decode(Frame.self, from:data)
            if let id = work.body["id"] as? String, retryText?.1.uuidString == id { retryText = nil }
            if let id = work.body["id"] as? String, pendingReplacement?.1.uuidString == id {
                pendingReplacement = nil; inputError = false
            }
            guard work.generation == generation else { return }
            guard frame.width > 0, frame.height > 0,
                  let bytes = Data(base64Encoded:frame.image), let decoded = UIImage(data:bytes),
                  let cgImage = decoded.cgImage,
                  frame.pixelRatio >= 1, frame.pixelRatio <= 3,
                  cgImage.width == Int((frame.width * frame.pixelRatio).rounded()),
                  cgImage.height == Int((frame.height * frame.pixelRatio).rounded()) else {
                status = "预览帧尺寸不匹配，请刷新"; resizing = false; return
            }
            source = CGSize(width:frame.width,height:frame.height); image = decoded
            search = frame.search; status = frame.status; sequence = frame.sequence; scrollY = frame.scrollY ?? 0
            resizing = false
        } catch {
            guard !Task.isCancelled else { return }
            status = "预览连接失败，可重试"
            if work.body["kind"] as? String == "replaceText" { inputError = true }
            if work.generation == generation { resizing = false }
        }
    }
}

struct IPhoneXPreview: View {
    let close: () -> Void
    @StateObject private var browser = XBrowserPreview()
    @StateObject private var interaction = MobileInteractionSession(localInputPreview:true, directScroll:true)
    @StateObject private var text = MobileTextSession()
    @State private var mode = MobileWindowSizing.Mode.adaptive
    @State private var available = CGSize.zero
    @State private var showDetails = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        IPhoneWindowWorkspace(title:"X", subtitle:"真实 x.com · 隔离预览", symbol:"globe",
            target:"x-explore", hasWindow:browser.image != nil && !browser.resizing,
            canChooseWindow:false, interaction:interaction, text:text, inlineInput:true, chooseWindow:{}) {
                Button(mode == .adaptive ? "对比桌面原比例" : "适配 iPhone 比例") {
                    interaction.invalidate(); text.cancel()
                    mode = mode == .adaptive ? .desktop : .adaptive; propose()
                }.accessibilityIdentifier("xToggleSizing")
                Button("预览详情") { showDetails = true }
                Button("刷新画面") { browser.refresh() }
                Button("清空测试搜索文字") { text.cancel(); browser.clearSearch() }
                Button("结束 X 预览", action:close)
            } content: {
                GeometryReader { proxy in
                    ZStack {
                        Color(uiColor:.systemBackground)
                        MobileViewport(session:interaction, source:browser.source, target:"x-explore", focusRect:focusRect) {
                            if let image = browser.image { Image(uiImage:image).resizable() }
                        }.allowsHitTesting(!browser.resizing)
                        if text.focused, let rect = editingRect(in:proxy.size) {
                            MobileTextEditor(session:text,inlineSearch:true)
                                .frame(width:rect.width,height:rect.height)
                                .position(x:rect.midX,y:rect.midY)
                        }
                        if browser.resizing { ProgressView("调整窗口比例…").padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }
                    }
                    .onAppear { available = proxy.size; propose() }
                    .onChange(of:proxy.size) { _, value in available = value; propose() }
                }
                .overlay(alignment:.topTrailing) {
                    if browser.inputError {
                        Button("重试输入") { browser.retry() }.buttonStyle(.borderedProminent).padding(8)
                    }
                }
                .overlay(alignment:.bottomLeading) {
                    // Simulator-only accessibility metadata, not a debug banner.
                    Color.clear.frame(width:1,height:1).accessibilityElement()
                        .accessibilityLabel("预览状态").accessibilityValue(snapshot)
                        .accessibilityIdentifier("xPreviewStatus").allowsHitTesting(false)
                }
            }
            .onAppear {
                text.onStableChange = { value in browser.replaceSearch(value) }
                browser.onSearchRequested = { value in text.beginEditing(value) }
                interaction.onEvent = { event in browser.consume(event,interaction:interaction) }
            }
            .onChange(of:text.focused) { _, focused in if !focused { propose() } }
            .onChange(of:phase) { _, value in
                if value != .active { interaction.invalidate(); text.cancel() }
            }
            .onDisappear { browser.stop() }
            .preferredColorScheme(.dark)
            .sheet(isPresented:$showDetails) {
                NavigationStack {
                    Form {
                        LabeledContent("窗口尺寸",value:"\(Int(browser.source.width)) × \(Int(browser.source.height))")
                            .accessibilityIdentifier("xSourceSize")
                        LabeledContent("画面序号",value:"\(browser.sequence)").accessibilityIdentifier("xFrameSequence")
                        LabeledContent("搜索框文字",value:browser.search?.value ?? "")
                            .accessibilityIdentifier("xSearchValue")
                        Text("浏览器截图与事件验证，不连接 Host；不代表串流帧率或延迟。测试只开放滚动与搜索框输入。")
                        if browser.retryText != nil { Button("重试未确认的文字") { browser.retry() } }
                    }.navigationTitle("X 预览详情").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showDetails = false } } }
                }
            }
    }
    private var snapshot: String {
        let value: [String: Any] = ["width":browser.source.width, "height":browser.source.height,
            "sequence":browser.sequence, "scrollY":browser.scrollY, "pending":browser.resizing, "value":browser.search?.value ?? "",
            "focused":browser.search?.focused ?? false,
            "searchX":browser.search?.x ?? 0, "searchY":browser.search?.y ?? 0,
            "searchWidth":browser.search?.width ?? 0, "searchHeight":browser.search?.height ?? 0]
        return (try? JSONSerialization.data(withJSONObject:value)).flatMap { String(data:$0,encoding:.utf8) } ?? "{}"
    }
    private var focusRect: CGRect? {
        guard text.focused, let r = browser.search else { return nil }
        return CGRect(x:r.x,y:r.y,width:r.width,height:r.height)
    }
    private func editingRect(in viewport: CGSize) -> CGRect? {
        guard let sourceRect = focusRect else { return nil }
        let g = ViewportGeometry(source:browser.source,viewport:viewport,zoom:interaction.zoom,offset:interaction.offset)
        return CGRect(origin:g.displayPoint(for:sourceRect.origin),
            size:CGSize(width:sourceRect.width*g.scale,height:sourceRect.height*g.scale))
    }
    private func propose() {
        // The keyboard temporarily occludes a stable window. Do not resize X on
        // each keyboard animation or invalidate a Chinese composition.
        guard !text.focused, let size = MobileWindowSizing.proposal(for:available,mode:mode) else { return }
        browser.resize(size)
    }
}
#endif
