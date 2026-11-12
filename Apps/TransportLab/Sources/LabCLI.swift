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
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let known: Set<String> = ["--lab-role", "--route", "--host", "--port", "--media-port", "--key-file", "--duration", "--resolution", "--fps", "--mbps", "--pattern", "--report", "--host-report", "--pacing", "--receive-depth", "--bridge-transport", "--window-id", "--frame-preview"]
            var flags = Set<String>()
            var options: [String: String] = [:], i = 0
            while i < args.count {
                if ["--self-test", "--persistent-host", "--list-windows"].contains(args[i]) {
                    guard flags.insert(args[i]).inserted else { throw LabError.message("重复参数") }
                    i += 1; continue
                }
                guard known.contains(args[i]), i + 1 < args.count, !args[i + 1].hasPrefix("--"), options[args[i]] == nil else {
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
            guard let route = MediaRoute(rawValue: options["--route"] ?? MediaRoute.ponteUDP.rawValue),
                  let duration = Double(options["--duration"] ?? "35"), duration >= 5, duration <= (persistentHost ? 86400 : 3600),
                  let fps = Int(options["--fps"] ?? "60"), [30, 60].contains(fps),
                  let mbps = Int(options["--mbps"] ?? "25"), (1...120).contains(mbps),
                  let pattern = PatternKind(rawValue: options["--pattern"] ?? "grid") else { throw LabError.message("测试参数无效") }
            guard let pacing = PacingMode(rawValue: options["--pacing"] ?? "interactive") else { throw LabError.message("无效 pacing 模式") }
            guard let depth = Int(options["--receive-depth"] ?? "16"), [1, 16].contains(depth) else { throw LabError.message("接收深度必须为 1 或 16") }
            guard let transport = BridgeTransportKind(rawValue: options["--bridge-transport"] ?? "network") else { throw LabError.message("无效 UDP 传输实现") }
            model.bridgeTransport = transport
            model.bridgeReceiveDepth = depth
            WebRTCRuntime.initialize(pacing)
            let resolution = options["--resolution"] ?? "1920x1080"
            guard ["1280x720", "1920x1080", "2560x1440"].contains(resolution) else { throw LabError.message("不支持的尺寸") }
            model.mediaRoute = route; model.host = options["--host"] ?? "127.0.0.1"
            model.port = options["--port"] ?? "45990"; model.mediaPort = options["--media-port"] ?? "45991"
            model.resolution = resolution.replacingOccurrences(of: "x", with: "×")
            model.fps = fps; model.megabits = mbps; model.pattern = pattern
            let selfTest = args.contains("--self-test")
            reportURL = options["--report"].map { URL(fileURLWithPath: $0) }
            hostReportURL = options["--host-report"].map { URL(fileURLWithPath: $0) }
            let role = options["--lab-role"] ?? (selfTest ? "self-test" : "")
            guard !selfTest || role == "self-test" else { throw LabError.message("self-test 不能与 lab-role 混用") }
            guard !persistentHost || role == "host" else { throw LabError.message("常驻模式仅用于独立主机") }
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
            if let reportURL { model.exportReport(to: reportURL) }
            if let path = options["--host-report"] { model.exportLocalHostReport(to: URL(fileURLWithPath: path)) }
            if let error = model.error { throw LabError.message(error) }
            if let path = options["--frame-preview"] { try model.saveDecodedPreview(to: URL(fileURLWithPath: path)) }
            if persistentHost {
                print("LAB_HOST_STOPPED videoSessions=\(completedVideoSessions + (passed ? 1 : 0))"); fflush(stdout)
                model.stop(); exit(0)
            }
            guard passed, Date().timeIntervalSince(lastProgress) < 3,
                  let controlAge = model.sample.controlResponseAgeMilliseconds, controlAge < 3000 else {
                throw LabError.message("未达到持续视频及控制回声通过条件：\(model.status)")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let metrics = String(data: try encoder.encode(model.sample), encoding: .utf8) ?? "{}"
            print("LAB_PASSED role=\(role) route=\(route.rawValue) metrics=\(metrics)")
            model.stop(); exit(0)
        } catch {
            // Preserve diagnostics even when the other process disconnects or UDP negotiation fails.
            if let hostReportURL { model.exportLocalHostReport(to: hostReportURL) }
            if let reportURL { model.exportReport(to: reportURL) }
            print("LAB_FAILED: \(error.localizedDescription)")
            if let data = try? JSONEncoder().encode(model.sample), let text = String(data: data, encoding: .utf8) { print(text) }
            model.stop(); exit(1)
        }
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
