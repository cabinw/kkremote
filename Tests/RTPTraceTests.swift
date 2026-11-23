import Foundation

@main struct RTPTraceTests {
    static func main() {
        let config = RTPTraceConfiguration.parse("""
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100 101
        a=rtpmap:100 H265/90000
        a=rtpmap:101 rtx/90000
        a=fmtp:101 apt=100
        a=extmap:7 http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time
        """)
        precondition(config.primary[100] == "H265" && config.rtx[101] == 100 && config.captureExtensionID == 7)
        precondition(RTPTraceConfiguration.parse("m=video 9 UDP/TLS/RTP/SAVPF 100\na=extmap:/ \(RTPTraceConfiguration.captureURI)").captureExtensionID == nil)
        var packet = Data([0x90, 0xe4, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0, 0, 0, 9,
                           0xbe, 0xde, 0, 3, 0x77, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0xaa])
        let h = RTPTraceHeader.parse(packet, configuration: config)!
        precondition(h.sequence == .max && h.timestamp == .max - 1 && h.ssrc == 9 && h.marker)
        precondition(h.absoluteCaptureNtp == 0x0102030405060708 && h.kind == "primary")
        for size in 0..<28 { precondition(RTPTraceHeader.parse(packet.prefix(size), configuration: config) == nil) }
        var rtcp = packet; rtcp[1] = 205
        precondition(RTPTraceHeader.parse(rtcp, configuration: config) == nil)
        var unknown = packet; unknown[1] = 99
        precondition(RTPTraceHeader.parse(unknown, configuration: config) == nil)
        var overflow = packet; overflow[14] = 255
        precondition(RTPTraceHeader.parse(overflow, configuration: config) == nil)
        var csrc = packet; csrc[0] = 0x9f
        precondition(RTPTraceHeader.parse(csrc, configuration: config) == nil)
        var rtx = packet; rtx[1] = 101
        precondition(RTPTraceHeader.parse(rtx, configuration: config)?.kind == "rtx")
        rtx[0] |= 32
        precondition(RTPTraceHeader.parse(rtx, configuration: config)?.kind == "rtx-padding-flag")
        var twoByte = Data(packet.prefix(12))
        twoByte.append(contentsOf: [0x10, 0, 0, 3, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0])
        precondition(RTPTraceHeader.parse(twoByte, configuration: config)?.absoluteCaptureNtp == h.absoluteCaptureNtp)
        twoByte[17] = 17
        precondition(RTPTraceHeader.parse(twoByte, configuration: config) == nil)
        let trace = RTPTrace(capacity: 2); trace.configure(config)
        let arrival = RTPTrace(capacity: 2); arrival.configure(config)
        _ = arrival.observe(packet, direction: "inbound", at: 100, kernelArrivalNs: 90)
        _ = arrival.observe(packet, direction: "inbound", at: 120, kernelArrivalNs: 95)
        _ = arrival.observe(packet, direction: "inbound", at: 130, kernelArrivalNs: 140)
        let kernel = arrival.snapshot().frames[0]
        precondition(kernel.firstKernelArrivalNs == 90 && kernel.lastKernelArrivalNs == 95)
        precondition(kernel.kernelTimestampPackets == 2 && kernel.kernelToBridgeNsMax == 25)
        precondition(kernel.invalidKernelTimestampPackets == 1)
        let first = trace.observe(packet, direction: "outbound", at: 100)!
        trace.prepare(first, fragments: 2)
        trace.dequeued(first, queuedNs: 100, depth: 2, at: 120)
        trace.completed(first, at: 130)
        trace.completed(first, reason: "queue_deadline", at: 140)
        let row = trace.snapshot().frames[0]
        precondition(row.acceptedSequences.isEmpty && row.droppedSequences == [.max])
        precondition(row.queueWaitNsMax == 20 && row.drops["queue_deadline"] == 1)
        for i in 2...7 { packet[i] = 0 }
        let next = trace.observe(packet, direction: "outbound", at: 200)!
        trace.completed(next, at: 210)
        packet[7] = 1
        _ = trace.observe(packet, direction: "outbound", at: 300)
        trace.completed(first, at: 400)
        let result = trace.snapshot()
        precondition(result.frames.count == 2 && result.overwrittenFrames == 1 && result.lateUpdatesAfterEviction == 1)
        precondition(result.frames[0].acceptedSequences == [0])
        precondition(result.frames[0].timestamp == 0 && result.frames[0].adapterResidenceNsMax == 10)
        print("RTP_TRACE_TESTS_PASSED: negotiated payloads, RTX separation, truncated headers/extensions, wrap, fragment outcomes, bounded eviction")
    }
}
