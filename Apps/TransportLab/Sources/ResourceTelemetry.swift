import Foundation
import Darwin

struct ResourceSample: Codable {
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
    let cpuPercent: Double? // 100% = one CPU core; process only, not WindowServer/Surge.
    let thermalState: String
    let lowPowerMode: Bool
}

final class ResourceTelemetry {
    private var previous: (cpu: Double, wall: Double)?
    func snapshot() -> ResourceSample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let wall = ProcessInfo.processInfo.systemUptime
        var percent: Double?
        if usageOK, let previous, wall > previous.wall, cpu >= previous.cpu {
            percent = (cpu - previous.cpu) / (wall - previous.wall) * 100
        }
        if usageOK { previous = (cpu, wall) }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return ResourceSample(residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
            physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil,
            cpuPercent: percent, thermalState: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

struct SampleJournalStatus: Codable {
    var submitted = 0, written = 0, dropped = 0, writeFailures = 0
    var pending = 0, highWater = 0
    let capacity: Int
    var closed = false
}

/// Explicit CLI diagnostics. Bounded asynchronous JSONL avoids keeping an entire
/// long experiment in the media process; report analysis checks every sequence.
final class SampleJournal<Value: Encodable> {
    private struct Row: Encodable { let sequence: Int; let sample: Value }
    private let queue = DispatchQueue(label: "kkremote.sample-journal", qos: .utility)
    private let lock = NSLock()
    private let file: FileHandle
    private var state: SampleJournalStatus
    private var closing = false
    init(url: URL, capacity: Int = 8) throws {
        precondition(capacity > 0)
        state = SampleJournalStatus(capacity: capacity)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    @discardableResult func append(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { return false }
        let sequence = state.submitted; state.submitted += 1
        guard state.pending < state.capacity else { state.dropped += 1; return false }
        state.pending += 1; state.highWater = max(state.highWater, state.pending)
        queue.async { [self] in
            var success = false
            do {
                var bytes = try JSONEncoder().encode(Row(sequence: sequence, sample: value))
                bytes.append(10); try file.write(contentsOf: bytes); success = true
            } catch {}
            lock.lock()
            state.pending -= 1
            if success { state.written += 1 } else { state.writeFailures += 1 }
            lock.unlock()
        }
        return true
    }
    func snapshot() -> SampleJournalStatus { lock.lock(); defer { lock.unlock() }; return state }
    @discardableResult func finish() -> Bool {
        lock.lock(); let alreadyClosing = closing; closing = true; lock.unlock()
        queue.sync {
            if !alreadyClosing {
                do { try file.close() } catch { lock.lock(); state.writeFailures += 1; lock.unlock() }
                lock.lock(); state.closed = true; lock.unlock()
            }
        }
        let value = snapshot()
        return value.closed && value.pending == 0 && value.dropped == 0 && value.writeFailures == 0 && value.written == value.submitted
    }
}
