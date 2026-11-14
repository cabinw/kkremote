import Foundation
import WebRTC

@main struct HEVCNALTests {
    static func main() {
        let a = Data([0x40, 1, 2]), b = Data([0x26, 1, 7])
        precondition(HEVCNAL.split(HEVCNAL.start + a + Data([0, 0, 1]) + b) == [a, b])
        for data in [Data(), Data([0, 0, 1, 0]), Data([9, 0, 0, 1, 0x40, 1]), HEVCNAL.start + a + HEVCNAL.start] {
            precondition(HEVCNAL.split(data) == nil)
        }
        precondition(HEVCNAL.split(Data(repeating: 0, count: 16 * 1024 * 1024 + 1)) == nil)
        precondition(HEVCNAL.format([:]) == nil)
        let offer = "m=video 9 UDP/TLS/RTP/SAVPF 98 99 100\r\na=rtpmap:98 H265/90000\r\na=fmtp:98 level-id=150;profile-id=2;tier-flag=0\r\na=rtpmap:99 rtx/90000\r\na=rtpmap:100 H264/90000\r\n"
        precondition(HDRFormat.prefersMain10(offer))
        precondition(!HDRFormat.prefersMain10(offer.replacingOccurrences(of: "profile-id=2", with: "profile-id=20")))
        precondition(!HDRFormat.prefersMain10(offer.replacingOccurrences(of: "98 99 100", with: "100 98 99")))
        precondition(!HDRFormat.prefersMain10(offer.replacingOccurrences(of: "video 9", with: "video 0")))
        precondition(!HDRFormat.prefersMain10("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n"))
        print("PASS: HEVC NAL boundaries, malformed input and exact Main10 SDP negotiation")
    }
}
