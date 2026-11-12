import SwiftUI
import WebRTC

@main
struct LabApp: App {
    @StateObject private var model = LabModel()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        #if os(macOS)
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--lab-role") { LabCLI.run() }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            LabView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    #if os(iOS)
                    if phase == .background { model.stop() }
                    #endif
                }
        }
    }
}

struct LabView: View {
    @ObservedObject var model: LabModel
    @State private var showLicense = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("传输实验室").font(.largeTitle.bold())
                    Text("先验证连接和视频，再验证窗口体验。H.264 SDR 基线 · WebRTC M157")
                        .foregroundStyle(.secondary)
                    ZStack {
                        Color.black
                        if let track = model.track { RemoteVideo(track: track) }
                        else {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.connected.to.line.below").font(.largeTitle)
                                Text(model.mode == "host" && model.running ? "动态测试源已就绪，等待远端接收" : "连接主机后显示测试画面")
                            }.foregroundStyle(.white)
                        }
                    }.aspectRatio(16/9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    Text(model.status).font(.headline)
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    GroupBox("连接") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("主机地址，如 Mac 的 Tailscale IP 或 name.sgponte", text: $model.host)
                                .textFieldStyle(.roundedBorder)
                            TextField("信令端口", text: $model.port).textFieldStyle(.roundedBorder)
                            Picker("媒体路径", selection: $model.mediaRoute) {
                                ForEach(MediaRoute.allCases) { Text($0.title).tag($0) }
                            }.disabled(model.running)
                            if model.mediaRoute == .ponteUDP {
                                TextField("主机 UDP 媒体端口", text: $model.mediaPort).textFieldStyle(.roundedBorder).disabled(model.running)
                            }
                            if model.mode == "host" && model.running {
                                Text("本次配对码（仅交给测试接收端）").font(.caption)
                                Text(model.pairingKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            } else { SecureField("粘贴主机显示的完整配对码", text: $model.pairingKey).textFieldStyle(.roundedBorder) }
                            Picker("测试网络标签", selection: $model.networkLabel) {
                                ForEach(["LAN", "Tailscale", "Surge Ponte", "本机回环（不代表远程网络）"], id: \.self) { Text($0) }
                            }
                            Text("Ponte 模式将媒体送到填写的主机名和主机配置的 UDP 端口；两端需选择相同模式。网络标签仅用于记录，无法判断 Ponte 外层通道。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("连接主机") { model.connect() }.buttonStyle(.borderedProminent).disabled(model.running)
                                #if os(macOS)
                                Button("启动 Mac 测试源") { model.startHost() }.disabled(model.running)
                                #endif
                                Button("停止") { model.stop() }.disabled(!model.running)
                            }
                        }.padding(4)
                    }
                    GroupBox("发送端参数 · 连接前设置") {
                        VStack {
                            Picker("像素尺寸", selection: $model.resolution) {
                                ForEach(["1280×720", "1920×1080", "2560×1440"], id: \.self) { Text($0) }
                            }
                            Picker("帧率", selection: $model.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                            Picker("测试内容", selection: $model.pattern) {
                                ForEach(PatternKind.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("视频码率上限", selection: $model.megabits) {
                                ForEach([8, 20, 25, 45, 80, 120], id: \.self) { Text("\($0) Mbps").tag($0) }
                            }
                            Text("实际码率随内容、编码器和拥塞控制变化。接收端这些设置不改变远端参数。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.disabled(model.running).padding(4)
                    }
                    GroupBox("实时测量") {
                        VStack(alignment: .leading, spacing: 8) {
                            metric("视频有效载荷", String(format: "%.2f Mbps", model.sample.videoMbps))
                            metric("实际像素 / 帧率", "\(model.sample.width)×\(model.sample.height) / \(Int(model.sample.fps)) fps")
                            metric("控制消息往返 / P95", "\(ms(model.sample.controlRTTMilliseconds)) / \(ms(model.sample.controlP95Milliseconds))")
                            metric("ICE 网络 RTT", ms(model.sample.networkRTTMilliseconds))
                            metric("累计丢包 / NACK", "\(model.sample.packetsLost) / \(model.sample.nackCount)")
                            metric("解码帧数", "\(model.sample.framesDecoded)")
                            metric("候选类型", model.sample.candidatePair)
                            metric("实际编码", model.sample.codec)
                            metric("解码 / 抖动缓冲", "\(ms(model.sample.decodeMilliseconds)) / \(ms(model.sample.jitterBufferMilliseconds))")
                            metric("丢帧 / 冻结", "\(model.sample.framesDropped) / \(model.sample.freezeCount)")
                            if let bridge = model.sample.bridge {
                                metric("UDP 认证 / 探测 RTT", "\(bridge.authenticated ? "已通过" : "等待") / \(ms(bridge.probeRTTMilliseconds))")
                                metric("UDP 队列丢弃 / 超时分片", "\(bridge.queueDrops) / \(bridge.expiredAssemblies)")
                                Text(bridge.endpointScope).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("往返时间不等于输入到显示延迟。此版本不采集桌面、不注入键鼠、不验证 HEVC/HDR。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(4)
                    }
                    HStack {
                        Button("本机回环自检") { model.startLocalDemo() }.disabled(model.running)
                        Button("生成测试报告") { model.exportReport() }
                        if let url = model.exportedReport { ShareLink("分享 JSON", item: url) }
                    }
                    Text("本机自检会在当前设备建立两端真实 WebRTC 会话，供安装验证与审核使用；它不代表远程 iPad 或覆盖网性能。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("第三方许可") { showLicense = true }.font(.caption)
                }.padding(24).frame(maxWidth: 1000)
            }.sheet(isPresented: $showLicense) {
                ScrollView { Text(license).font(.caption).textSelection(.enabled).padding() }
                    .frame(minWidth: 300, minHeight: 350)
            }
        }
    }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
    private func metric(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "WebRTC-LICENSE", withExtension: "txt") else { return "许可证资源缺失" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取许可证"
    }
}

final class VideoCoordinator {
    var track: RTCVideoTrack?
    func bind(_ next: RTCVideoTrack, to renderer: RTCVideoRenderer) {
        guard track !== next else { return }
        track?.remove(renderer); track = next; next.add(renderer)
    }
}

#if os(macOS)
struct RemoteVideo: NSViewRepresentable {
    let track: RTCVideoTrack
    func makeCoordinator() -> VideoCoordinator { VideoCoordinator() }
    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero); context.coordinator.bind(track, to: view); return view
    }
    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) { context.coordinator.bind(track, to: view) }
    static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: VideoCoordinator) { coordinator.track?.remove(view) }
}
#else
struct RemoteVideo: UIViewRepresentable {
    let track: RTCVideoTrack
    func makeCoordinator() -> VideoCoordinator { VideoCoordinator() }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero); view.videoContentMode = .scaleAspectFit
        context.coordinator.bind(track, to: view); return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) { context.coordinator.bind(track, to: view) }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: VideoCoordinator) { coordinator.track?.remove(view) }
}
#endif
