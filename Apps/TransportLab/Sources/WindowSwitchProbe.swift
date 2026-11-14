#if os(macOS)
import Foundation

/// Opt-in CLI integration probe; uses the same model and public messages as the UI.
/// Only selects the explicit window numbers supplied by the developer.
final class WindowSwitchProbe {
    private let targets: [UInt32]
    private let requireHDR: Bool
    private var phase = 0
    private var issued = false
    private var deadline = Date().addingTimeInterval(20)
    private var stale: RemoteWindow?
    private var oldHandle: String?
    private(set) var passed = false

    init(targets: [UInt32], requireHDR: Bool) {
        self.targets = targets; self.requireHDR = requireHDR
    }
    func tick(_ model: LabModel) throws {
        guard !passed else { return }
        guard Date() < deadline else { throw LabError.message("窗口回归超时 phase=\(phase)：\(model.windowError ?? model.windowStatus)") }
        if phase == 0 {
            guard model.windowSupported, !model.catalogLoading,
                  let first = model.remoteWindows.first(where: { $0.number == targets[0] }) else { return }
            stale = first; oldHandle = first.id; model.refreshRemoteWindows(); advance(); return
        }
        if phase == 1 {
            guard !model.catalogLoading, model.remoteWindows.first(where: { $0.number == targets[0] })?.id != oldHandle else { return }
            if !issued { model.selectRemoteWindow(stale); issued = true; return }
            guard !model.windowBusy, model.windowError != nil else { return }
            print("WINDOW_PROBE stale_handle_rejected"); advance(); return
        }
        // A -> B -> unsubscribe -> A: each subscription must decode a fresh generation.
        let sequence: [UInt32?] = [targets[0], targets[1], nil, targets[0]]
        let target = sequence[phase - 2]
        if !issued {
            if let target {
                guard let window = model.remoteWindows.first(where: { $0.number == target }) else {
                    throw LabError.message("指定测试窗口未在目录中")
                }
                model.selectRemoteWindow(window)
                // A second immediate tap must not supersede the in-flight transaction.
                model.selectRemoteWindow(nil)
            } else { model.selectRemoteWindow(nil) }
            issued = true; return
        }
        guard !model.windowBusy else { return }
        if let error = model.windowError { throw LabError.message(error) }
        guard model.selectedRemoteWindow?.number == target else { throw LabError.message("所选窗口身份不匹配") }
        if target != nil {
            guard model.decodedFrames > 0, model.sample.framesDecoded > 0,
                  model.sample.bridge?.authenticated == true, model.sample.controlRTTMilliseconds != nil else { return }
            if requireHDR {
                guard model.sample.codec == "video/H265",
                      model.sample.decodedPixelFormat?["transfer"] == "SMPTE_ST_2084_PQ" else {
                    throw LabError.message("切窗后未保留 HEVC / PQ")
                }
            }
        } else if model.track != nil || model.decodedFrames != 0 { throw LabError.message("取消订阅后仍有旧媒体") }
        print("WINDOW_PROBE phase=\(phase) selected=\(target.map(String.init) ?? "none") freshFrames=\(model.decodedFrames) codec=\(model.sample.codec)")
        fflush(stdout)
        if phase == 5 { passed = true; print("WINDOW_PROBE_PASSED") } else { advance() }
    }
    private func advance() { phase += 1; issued = false; deadline = Date().addingTimeInterval(20) }
}
#endif
