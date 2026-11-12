#if os(macOS)
import Foundation

/// Uses the same model as the app. Keys are passed in private files, never argv or reports.
enum LabCLI {
    static func run() -> Never {
        let model = LabModel()
        var reportURL: URL?
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let known: Set<String> = ["--lab-role", "--route", "--host", "--port", "--media-port", "--key-file", "--duration", "--resolution", "--fps", "--mbps", "--pattern", "--report", "--host-report", "--pacing"]
            var options: [String: String] = [:], i = 0
            while i < args.count {
                if args[i] == "--self-test" { i += 1; continue }
                guard known.contains(args[i]), i + 1 < args.count, !args[i + 1].hasPrefix("--"), options[args[i]] == nil else {
                    throw LabError.message("未知、重复或缺值参数：\(args[i])")
                }
                options[args[i]] = args[i + 1]; i += 2
            }
            guard let route = MediaRoute(rawValue: options["--route"] ?? MediaRoute.ponteUDP.rawValue),
                  let duration = Double(options["--duration"] ?? "35"), duration >= 5, duration <= 3600,
                  let fps = Int(options["--fps"] ?? "60"), [30, 60].contains(fps),
                  let mbps = Int(options["--mbps"] ?? "25"), (1...120).contains(mbps),
                  let pattern = PatternKind(rawValue: options["--pattern"] ?? "grid") else { throw LabError.message("测试参数无效") }
            guard let pacing = PacingMode(rawValue: options["--pacing"] ?? "interactive") else { throw LabError.message("无效 pacing 模式") }
            WebRTCRuntime.initialize(pacing)
            let resolution = options["--resolution"] ?? "1920x1080"
            guard ["1280x720", "1920x1080", "2560x1440"].contains(resolution) else { throw LabError.message("不支持的尺寸") }
            model.mediaRoute = route; model.host = options["--host"] ?? "127.0.0.1"
            model.port = options["--port"] ?? "45990"; model.mediaPort = options["--media-port"] ?? "45991"
            model.resolution = resolution.replacingOccurrences(of: "x", with: "×")
            model.fps = fps; model.megabits = mbps; model.pattern = pattern
            let selfTest = args.contains("--self-test")
            reportURL = options["--report"].map { URL(fileURLWithPath: $0) }
            let role = options["--lab-role"] ?? (selfTest ? "self-test" : "")
            guard !selfTest || role == "self-test" else { throw LabError.message("self-test 不能与 lab-role 混用") }
            if selfTest { model.startLocalDemo(endpoint: model.host, useCurrentPreset: true) }
            else {
                guard ["host", "viewer"].contains(role), let keyFile = options["--key-file"] else {
                    throw LabError.message("独立进程需要 --lab-role host|viewer 和 --key-file 路径")
                }
                if role == "host" {
                    // O_EXCL prevents clobbering credentials or following an existing symlink.
                    let fd = open(keyFile, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                    guard fd >= 0 else { throw LabError.message("配对码文件必须是可创建的新文件") }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    model.startHost()
                    guard model.running else { throw LabError.message(model.error ?? "主机启动失败") }
                    try handle.write(contentsOf: Data(model.pairingKey.utf8)); try handle.close()
                } else {
                    model.pairingKey = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    model.connect()
                }
            }
            let deadline = Date().addingTimeInterval(duration)
            var passed = false
            var lastFrames = 0, lastProgress = Date()
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let error = model.error ?? model.localHostError { throw LabError.message(error) }
                let frames = role == "host" ? model.sample.framesEncoded : model.decodedFrames
                if frames > lastFrames { lastFrames = frames; lastProgress = Date() }
                let video = role == "host" ? model.sample.videoMbps > 0 : model.decodedFrames >= 60
                if video, model.sample.controlRTTMilliseconds != nil,
                   route == .directICE || model.sample.bridge?.authenticated == true {
                    passed = true
                    if selfTest && options["--duration"] == nil { break }
                }
            }
            if let reportURL { model.exportReport(to: reportURL) }
            if let path = options["--host-report"] { model.exportLocalHostReport(to: URL(fileURLWithPath: path)) }
            if let error = model.error { throw LabError.message(error) }
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
            if let reportURL { model.exportReport(to: reportURL) }
            print("LAB_FAILED: \(error.localizedDescription)")
            if let data = try? JSONEncoder().encode(model.sample), let text = String(data: data, encoding: .utf8) { print(text) }
            model.stop(); exit(1)
        }
    }
}
#endif
