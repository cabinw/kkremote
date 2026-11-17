#if os(macOS)
import Foundation
import AppKit

/// Uses the same model as the app. Keys are passed in private files, never argv or reports.
enum LabCLI {
    static func run() -> Never {
        // CLI capture still needs an AppKit/WindowServer connection before SCStream starts.
        _ = NSApplication.shared
        let model = LabModel()
        var reportURL: URL?
        var hostReportURL: URL?
        var interrupted = false
        var terminationSource: DispatchSourceSignal?
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let known: Set<String> = ["--lab-role", "--route", "--host", "--port", "--media-port", "--key-file", "--duration", "--resolution", "--fps", "--mbps", "--pattern", "--report", "--host-report", "--pacing", "--playout", "--receive-depth", "--capture-depth", "--bridge-transport", "--window-id", "--frame-preview", "--window-cycle", "--frame-trace-dir", "--hevc-keyframe-seconds", "--simulate-outage-ms", "--diagnostic-impairment", "--report-history-limit"]
            let qualityOptions: Set<String> = ["--hevc-max-qp", "--native-workspace-display-id"]
            var flags = Set<String>()
            var options: [String: String] = [:], i = 0
            while i < args.count {
                if ["--window-text-quality", "--mobile-window-control", "--mobile-window-layout", "--self-test", "--persistent-host", "--list-windows", "--hdr", "--simulate-loss", "--sdr-receiver", "--sdk-drop-diagnostics", "--disable-frame-dropper", "--sample-journal"].contains(args[i]) {
                    guard flags.insert(args[i]).inserted else { throw LabError.message("重复参数") }
                    i += 1; continue
                }
                guard known.union(qualityOptions).contains(args[i]), i + 1 < args.count, !args[i + 1].hasPrefix("--"), options[args[i]] == nil else {
                    throw LabError.message("未知、重复或缺值参数：\(args[i])")
                }
                options[args[i]] = args[i + 1]; i += 2
            }
            if flags.contains("--list-windows") {
                guard flags.count == 1, options.keys.allSatisfy({ $0 == "--report" }) else {
                    throw LabError.message("list-windows 只能与 --report 混用")
                }
                listWindows(to: options["--report"])
            }
            let persistentHost = flags.contains("--persistent-host")
            guard let historyLimit = Int(options["--report-history-limit"] ?? "3600"), [60, 300, 3600].contains(historyLimit),
                  historyLimit == 3600 || flags.contains("--sample-journal") else {
                throw LabError.message("缩短报告历史必须同时启用 sample-journal；容量为 60、300 或 3600")
            }
            model.diagnosticHistoryLimit = historyLimit
            if flags.contains("--sample-journal") {
                guard !persistentHost, let path = options["--report"] else { throw LabError.message("sample-journal 需要独立单会话报告，不能与 persistent-host 混用") }
                try model.beginSampleJournal(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("samples.jsonl"))
            }
            model.enablesWindowLayout = flags.contains("--mobile-window-layout")
            model.enablesWindowControl = flags.contains("--mobile-window-control")
            model.hdr = flags.contains("--hdr")
            if let value=options["--native-workspace-display-id"] {
                guard let id=UInt32(value),id>0,model.enablesWindowLayout,
                      !flags.contains("--window-text-quality") else {throw LabError.message("原生像素工作区需要有效显示 ID 和窗口布局；不能与插值画质路径混用")}
                model.nativeWorkspaceDisplayID=id
            }
            WebRTCRuntime.windowTextQuality=flags.contains("--window-text-quality")
            guard !WebRTCRuntime.windowTextQuality || (model.hdr && model.enablesWindowLayout) else {
                throw LabError.message("window-text-quality 需要 HDR 和 mobile-window-layout")
            }
            model.frameTraceDirectory = options["--frame-trace-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            guard let route = MediaRoute(rawValue: options["--route"] ?? MediaRoute.ponteUDP.rawValue),
                  let duration = Double(options["--duration"] ?? "35"), duration >= 5, duration <= (persistentHost ? 86400 : 3600),
                  let fps = Int(options["--fps"] ?? "60"), [30, 60].contains(fps),
                  let mbps = Int(options["--mbps"] ?? "25"), (1...120).contains(mbps),
                  let pattern = PatternKind(rawValue: options["--pattern"] ?? "grid") else { throw LabError.message("测试参数无效") }
            guard let pacing = PacingMode(rawValue: options["--pacing"] ?? "interactive") else { throw LabError.message("无效 pacing 模式") }
            guard let depth = Int(options["--receive-depth"] ?? "16"), [1, 16].contains(depth) else { throw LabError.message("接收深度必须为 1 或 16") }
            guard let captureDepth = Int(options["--capture-depth"] ?? "3"), [3, 5, 8].contains(captureDepth) else {
                throw LabError.message("本地捕获缓冲对照仅支持 3、5 或 8")
            }
            WindowCaptureSource.diagnosticQueueDepth = captureDepth
            guard let transport = BridgeTransportKind(rawValue: options["--bridge-transport"] ?? "network") else { throw LabError.message("无效 UDP 传输实现") }
            model.bridgeTransport = transport
            model.bridgeReceiveDepth = depth
            guard let playout = PlayoutMode(rawValue: options["--playout"] ?? "adaptive") else {
                throw LabError.message("无效 playout 模式，应为 adaptive 或 realtime")
            }
            guard !flags.contains("--disable-frame-dropper") || flags.contains("--self-test") else {
                throw LabError.message("disable-frame-dropper 仅允许本机 self-test 的因果对照")
            }
            guard let keyframeSeconds = Int32(options["--hevc-keyframe-seconds"] ?? String(WebRTCRuntime.hevcKeyframeSeconds)), [2, 10].contains(keyframeSeconds) else {
                throw LabError.message("hevc-keyframe-seconds 仅支持 2 或 10")
            }
            WebRTCRuntime.hevcKeyframeSeconds = keyframeSeconds
            if let value=options["--hevc-max-qp"] {
                guard let qp=Int(value),(0...51).contains(qp),model.hdr else {throw LabError.message("hevc-max-qp 需要 HDR，范围为 0–51")}
                WebRTCRuntime.hevcMaximumFrameQP=qp
            }
            guard !flags.contains("--sdk-drop-diagnostics") || model.frameTraceDirectory != nil else {
                throw LabError.message("sdk-drop-diagnostics 需要 frame-trace-dir")
            }
            WebRTCRuntime.sdkDropDiagnostics = flags.contains("--sdk-drop-diagnostics")
            WebRTCRuntime.disableFrameDropperForSelfTest = flags.contains("--disable-frame-dropper")
            WebRTCRuntime.initialize(pacing, playout: playout)
            let resolution = options["--resolution"] ?? "1920x1080"
            guard ["1280x720", "1920x1080", "2560x1440"].contains(resolution) else { throw LabError.message("不支持的尺寸") }
            model.mediaRoute = route; model.host = options["--host"] ?? "127.0.0.1"
            model.port = options["--port"] ?? "45990"; model.mediaPort = options["--media-port"] ?? "45991"
            model.resolution = resolution.replacingOccurrences(of: "x", with: "×")
            model.fps = fps; model.megabits = mbps; model.pattern = pattern
            let selfTest = args.contains("--self-test")
            guard !flags.contains("--simulate-loss") || selfTest else { throw LabError.message("simulate-loss 仅允许本机 self-test") }
            guard options["--simulate-outage-ms"] == nil || (selfTest && flags.contains("--simulate-loss")),
                  let outage = Int(options["--simulate-outage-ms"] ?? "200"), [200, 1200].contains(outage) else {
                throw LabError.message("simulate-outage-ms 仅用于丢包 self-test，支持 200 或 1200")
            }
            DatagramBridge.simulatedOutageMilliseconds = outage
            DatagramBridge.simulateLossInSelfTest = flags.contains("--simulate-loss")
            model.sdrReceiver = flags.contains("--sdr-receiver")
            reportURL = options["--report"].map { URL(fileURLWithPath: $0) }
            hostReportURL = options["--host-report"].map { URL(fileURLWithPath: $0) }
            // A source guard can stop an invalid experiment without losing its bounded diagnostics.
            // No work runs in a POSIX signal handler; the main run loop performs normal shutdown.
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { interrupted = true }
            termination.resume(); terminationSource = termination
            let role = options["--lab-role"] ?? (selfTest ? "self-test" : "")
            guard let impairment = TransportImpairmentProfile(rawValue: options["--diagnostic-impairment"] ?? "none"),
                  impairment == .none || ((selfTest || role == "host") && !flags.contains("--simulate-loss") && reportURL != nil) else {
                throw LabError.message("diagnostic-impairment 仅用于显式本地主机 / 回环测试，必须提供报告且不能与旧丢包工具混用")
            }
            DatagramBridge.diagnosticImpairment = impairment
            guard !selfTest || role == "self-test" else { throw LabError.message("self-test 不能与 lab-role 混用") }
            guard !persistentHost || role == "host" else { throw LabError.message("常驻模式仅用于独立主机") }
            var windowProbe: WindowSwitchProbe?
            if let values = options["--window-cycle"] {
                let targets = values.split(separator: ",").compactMap { UInt32($0) }
                guard role == "viewer", targets.count == 2, targets[0] != targets[1] else {
                    throw LabError.message("window-cycle 仅用于 viewer，填写两个不同的窗口 ID")
                }
                windowProbe = WindowSwitchProbe(targets: targets, requireHDR: model.hdr)
            }
            if options["--frame-preview"] != nil {
                guard selfTest || role == "viewer" else { throw LabError.message("frame-preview 仅用于接收端") }
                model.keepDecodedPreview = true
            }
            if let rawID = options["--window-id"] {
                guard role == "host" || selfTest, let id = UInt32(rawID), id > 0 else {
                    throw LabError.message("window-id 必须是主机捕获列表中的有效窗口 ID")
                }
                model.captureWindowID = id
            }
            var hostKey: String?
            if selfTest { model.startLocalDemo(endpoint: model.host, useCurrentPreset: true) }
            else {
                guard ["host", "viewer"].contains(role), let keyFile = options["--key-file"] else {
                    throw LabError.message("独立进程需要 --lab-role host|viewer 和 --key-file 路径")
                }
                if role == "host" {
                    hostKey = try LabHostKey.loadOrCreate(at: keyFile, reuseExisting: persistentHost)
                    model.startHost(pairingKey: hostKey)
                    guard model.running else { throw LabError.message(model.error ?? "主机启动失败") }
                } else {
                    model.pairingKey = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    model.connect()
                }
            }
            let deadline = Date().addingTimeInterval(duration)
            var passed = false
            var lastFrames = 0, lastProgress = Date()
            var sessionNumber = 1, completedVideoSessions = 0
            var nextSnapshot = Date().addingTimeInterval(5)
            var retryAt: Date?
            if persistentHost { print("LAB_HOST_LISTENING session=1"); fflush(stdout) }
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if interrupted { throw LabError.message("测试被终止；保留诊断，不计为完成") }
                if let due = retryAt {
                    if Date() < due { continue }
                    retryAt = nil
                    model.startHost(pairingKey: hostKey)
                    print("LAB_HOST_LISTENING session=\(sessionNumber)"); fflush(stdout)
                }
                if let error = model.error ?? model.localHostError {
                    guard persistentHost else { throw LabError.message(error) }
                    if let reportURL {
                        // Preserve the ended session before startHost clears its samples.
                        let archived = reportURL.deletingPathExtension()
                            .appendingPathExtension(String(format: "session-%03d.json", sessionNumber))
                        model.exportReport(to: archived)
                    }
                    if passed { completedVideoSessions += 1 }
                    print("LAB_HOST_SESSION_ENDED session=\(sessionNumber) video=\(passed) reason=\(error)"); fflush(stdout)
                    sessionNumber += 1; passed = false; lastFrames = 0; lastProgress = Date()
                    // Yield to cancellation callbacks before binding the same ports again.
                    retryAt = Date().addingTimeInterval(1)
                    continue
                }
                let frames = role == "host" ? model.sample.framesEncoded : model.decodedFrames
                if let windowProbe {
                    try windowProbe.tick(model)
                    if windowProbe.passed { passed = true; lastProgress = Date(); break }
                }
                if frames > lastFrames { lastFrames = frames; lastProgress = Date() }
                let video = role == "host" ? model.sample.videoMbps > 0 : model.decodedFrames >= 60
                if video, model.sample.controlRTTMilliseconds != nil,
                   route == .directICE || model.sample.bridge?.authenticated == true {
                    passed = true
                    if selfTest && options["--duration"] == nil { break }
                }
                if persistentHost, let reportURL, Date() >= nextSnapshot {
                    // Keep periodic encoding/writes bounded during latency tests.
                    model.exportReport(to: reportURL, recentSamples: 5)
                    if let error = model.error { throw LabError.message(error) }
                    nextSnapshot = Date().addingTimeInterval(5)
                }
            }
            guard model.finishSampleJournal() else { throw LabError.message("统计 journal 不完整；不能将本轮用于完整验收") }
            if let reportURL { model.exportReport(to: reportURL) }
            if let path = options["--host-report"] { model.exportLocalHostReport(to: URL(fileURLWithPath: path)) }
            if let error = model.error { throw LabError.message(error) }
            if let path = options["--frame-preview"] { try model.saveDecodedPreview(to: URL(fileURLWithPath: path)) }
            if persistentHost {
                print("LAB_HOST_STOPPED videoSessions=\(completedVideoSessions + (passed ? 1 : 0))"); fflush(stdout)
                stopAndExit(model, code: 0)
            }
            guard passed, Date().timeIntervalSince(lastProgress) < 3,
                  let controlAge = model.sample.controlResponseAgeMilliseconds, controlAge < 3000 else {
                throw LabError.message("未达到持续视频及控制回声通过条件：\(model.status)")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let metrics = String(data: try encoder.encode(model.sample), encoding: .utf8) ?? "{}"
            print("LAB_PASSED role=\(role) route=\(route.rawValue) metrics=\(metrics)")
            stopAndExit(model, code: 0)
        } catch {
            withExtendedLifetime(terminationSource) {}
            _ = model.finishSampleJournal()
            // Preserve diagnostics even when the other process disconnects or UDP negotiation fails.
            if let hostReportURL { model.exportLocalHostReport(to: hostReportURL) }
            if let reportURL { model.exportReport(to: reportURL) }
            print("LAB_FAILED: \(error.localizedDescription)")
            if let data = try? JSONEncoder().encode(model.sample), let text = String(data: data, encoding: .utf8) { print(text) }
            stopAndExit(model, code: 1)
        }
    }

    private static func stopAndExit(_ model: LabModel, code: Int32) -> Never {
        model.stop()
        let deadline = Date().addingTimeInterval(10)
        // Bridge shutdown completes on main. Keep it running until trace exports are drained,
        // including an engine already detached by a disconnect before the CLI stopped.
        while FrameTrace.awaitingShutdown, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if FrameTrace.awaitingShutdown { print("FRAME_TRACE_EXPORT_FAILED: shutdown timeout"); exit(1) }
        exit(code)
    }

    private static func listWindows(to path: String?) -> Never {
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do {
                let windows = try await WindowCaptureSource.windows()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(windows)
                if let path { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                else { print(String(decoding: data, as: UTF8.self)) }
            } catch { failure = error }
            finished = true
        }
        let deadline = Date().addingTimeInterval(60)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let failure { print("LAB_FAILED: \(failure.localizedDescription)"); exit(1) }
        guard finished else { print("LAB_FAILED: 窗口列表超时，请在系统设置中允许屏幕录制后重试"); exit(1) }
        exit(0)
    }
}
#endif
