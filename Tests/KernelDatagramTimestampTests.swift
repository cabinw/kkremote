import Foundation
import Darwin

// UDPSocket's dependencies without loading WebRTC in this socket-level test.
enum LabError: Error { case message(String) }
enum MediaDatagramCodec { static let maximumWireBytes = 1280 }

@main struct KernelDatagramTimestampTests {
    static func main() throws {
        precondition(KernelDatagramTimestamp.nanoseconds(ticks: 3, numerator: 125, denominator: 3) == 125)
        precondition(KernelDatagramTimestamp.nanoseconds(ticks: .max, numerator: 1, denominator: 1) == .max)
        precondition(KernelDatagramTimestamp.nanoseconds(ticks: .max, numerator: 125, denominator: 3) == nil)
        precondition(KernelDatagramTimestamp.nanoseconds(ticks: 5, numerator: 1, denominator: 0) == nil)
        var header = cmsghdr(cmsg_len: 20, cmsg_level: SOL_SOCKET, cmsg_type: SCM_TIMESTAMP_MONOTONIC)
        var tick: UInt64 = mach_absolute_time()
        var control = withUnsafeBytes(of: &header) { Data($0) }
        control.append(withUnsafeBytes(of: &tick) { Data($0) })
        let parsed = control.withUnsafeBytes { KernelDatagramTimestamp.parse($0) }
        precondition(parsed != nil && parsed! <= DispatchTime.now().uptimeNanoseconds)
        for size in 0..<20 { precondition(control.prefix(size).withUnsafeBytes { KernelDatagramTimestamp.parse($0) } == nil) }
        // SCM_RIGHTS before the timestamp: walk native 4-byte aligned records.
        var other = cmsghdr(cmsg_len: 16, cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
        var multiple = withUnsafeBytes(of: &other) { Data($0) }; multiple.append(Data(repeating:0,count:4)); multiple.append(control)
        precondition(multiple.withUnsafeBytes { KernelDatagramTimestamp.parse($0) } == parsed)
        control[0] = 0
        precondition(control.withUnsafeBytes { KernelDatagramTimestamp.parse($0) } == nil)

        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        precondition(descriptor >= 0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        precondition(withUnsafePointer(to: &address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            Darwin.bind(descriptor,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        precondition(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            getsockname(descriptor,$0,&length) } } == 0)
        Darwin.close(descriptor)
        let queue = DispatchQueue(label:"test.kernel.arrival")
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), received = DispatchSemaphore(value:0)
        let receiver = try UDPSocket(queue:queue,host:nil,port:UInt16(bigEndian:address.sin_port),traceKernelArrival:true)
        precondition(receiver.kernelTimestampEnabled)
        receiver.onPacket = { data, _, timestamp in
            precondition(data == Data([1,2,3]))
            precondition(timestamp != nil)
            let now = DispatchTime.now().uptimeNanoseconds
            precondition(now >= timestamp! && now - timestamp! >= 100_000_000)
            received.signal()
        }
        queue.async { entered.signal(); release.wait() }
        receiver.start(); entered.wait()
        let sender = Darwin.socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)
        let payload: [UInt8] = [1,2,3]
        precondition(withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            Darwin.sendto(sender,payload,payload.count,0,$0,length) } } == 3)
        usleep(150_000); release.signal()
        precondition(received.wait(timeout:.now()+2) == .success)
        queue.sync { precondition(receiver.kernelTimestampPackets == 1 && receiver.kernelTimestampMissing == 0); receiver.stop() }
        Darwin.close(sender)
        print("KERNEL_TIMESTAMP_TESTS_PASSED: native CMSG parsing, ticks/timebase, malformed metadata, delayed queue distinguishes kernel arrival")
    }
}
