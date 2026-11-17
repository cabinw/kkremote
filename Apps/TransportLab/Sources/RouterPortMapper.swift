#if os(macOS)
import Foundation
import Darwin

/// Ephemeral NAT-PMP (RFC 6886) + UPnP IGD (WANIPConnection/WANPPPConnection) UDP port mapper.
/// Upgrades Port-Restricted home routers (NAT3) to Full-Cone reachability for 5G Symmetric CGNAT peers,
/// and automatically removes the mapping when the session stops.
final class RouterPortMapper {
    enum Mapping {
        case natPMP(gateway: String, internalPort: UInt16)
        case upnp(controlURL: URL, serviceType: String, externalPort: UInt16)
    }

    private var active: Mapping?

    func mapUDP(ifIndex: UInt32, lanIP: String, gatewayIP: String, internalPort: UInt16, leaseSeconds: UInt32 = 3600) -> UInt16? {
        if let ext = tryNATPMP(ifIndex: ifIndex, gatewayIP: gatewayIP, internalPort: internalPort, leaseSeconds: leaseSeconds) {
            active = .natPMP(gateway: gatewayIP, internalPort: internalPort)
            return ext
        }
        if let (ext, ctrlURL, svcType) = tryUPnP(ifIndex: ifIndex, lanIP: lanIP, internalPort: internalPort, leaseSeconds: leaseSeconds) {
            active = .upnp(controlURL: ctrlURL, serviceType: svcType, externalPort: ext)
            return ext
        }
        return nil
    }

    func unmap(ifIndex: UInt32) {
        guard let mapping = active else { return }
        active = nil
        switch mapping {
        case .natPMP(let gateway, let internalPort):
            _ = tryNATPMP(ifIndex: ifIndex, gatewayIP: gateway, internalPort: internalPort, leaseSeconds: 0)
        case .upnp(let controlURL, let serviceType, let externalPort):
            let body = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><u:DeletePortMapping xmlns:u="\(serviceType)">
            <NewRemoteHost></NewRemoteHost>
            <NewExternalPort>\(externalPort)</NewExternalPort>
            <NewProtocol>UDP</NewProtocol>
            </u:DeletePortMapping></s:Body></s:Envelope>
            """
            _ = Self.soapRequest(url: controlURL, action: "\"\(serviceType)#DeletePortMapping\"", body: body, timeout: 1.0)
        }
    }

    private func tryNATPMP(ifIndex: UInt32, gatewayIP: String, internalPort: UInt16, leaseSeconds: UInt32) -> UInt16? {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }
        var idx = ifIndex
        _ = setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 450_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = UInt16(5351).bigEndian
        guard gatewayIP.withCString({ inet_pton(AF_INET, $0, &dst.sin_addr) }) == 1 else { return nil }

        var req = Data([0x00, 0x01, 0x00, 0x00])
        req.append(UInt8(internalPort >> 8)); req.append(UInt8(internalPort & 0xff))
        let requestedExt = leaseSeconds == 0 ? UInt16(0) : internalPort
        req.append(UInt8(requestedExt >> 8)); req.append(UInt8(requestedExt & 0xff))
        var leaseBE = leaseSeconds.bigEndian
        withUnsafeBytes(of: &leaseBE) { req.append(contentsOf: $0) }

        let sent = req.withUnsafeBytes { rawPtr in
            withUnsafePointer(to: &dst) { dPtr in
                dPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(sock, rawPtr.baseAddress, rawPtr.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == 12 else { return nil }

        var resp = [UInt8](repeating: 0, count: 32)
        let n = resp.withUnsafeMutableBytes { recv(sock, $0.baseAddress, $0.count, 0) }
        guard n >= 16, resp[0] == 0, resp[1] == 129, resp[2] == 0, resp[3] == 0 else { return nil }
        return (UInt16(resp[10]) << 8) | UInt16(resp[11])
    }

    private func tryUPnP(ifIndex: UInt32, lanIP: String, internalPort: UInt16, leaseSeconds: UInt32) -> (UInt16, URL, String)? {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }
        var idx = ifIndex
        _ = setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 600_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var mcast = sockaddr_in()
        mcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mcast.sin_family = sa_family_t(AF_INET)
        mcast.sin_port = UInt16(1900).bigEndian
        _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &mcast.sin_addr) }

        for target in ["urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n"
            _ = query.withCString { cPtr in
                withUnsafePointer(to: &mcast) { dPtr in
                    dPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(sock, cPtr, strlen(cPtr), 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var respBuf = [UInt8](repeating: 0, count: 2048)
        let n = respBuf.withUnsafeMutableBytes { recv(sock, $0.baseAddress, $0.count, 0) }
        guard n > 0, let text = String(bytes: respBuf.prefix(n), encoding: .utf8) else { return nil }
        guard let locLine = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
              let descURL = URL(string: locLine.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)),
              let host = descURL.host, host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") else {
            return nil
        }

        guard let xmlData = Self.httpGet(url: descURL, timeout: 1.2),
              let xml = String(data: xmlData, encoding: .utf8) else { return nil }

        for svcType in ["urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            guard let range = xml.range(of: svcType),
                  let ctrlStart = xml.range(of: "<controlURL>", range: range.upperBound..<xml.endIndex),
                  let ctrlEnd = xml.range(of: "</controlURL>", range: ctrlStart.upperBound..<xml.endIndex) else { continue }
            let rawPath = String(xml[ctrlStart.upperBound..<ctrlEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let controlURL = URL(string: rawPath, relativeTo: descURL)?.absoluteURL else { continue }
            let soap = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><u:AddPortMapping xmlns:u="\(svcType)">
            <NewRemoteHost></NewRemoteHost>
            <NewExternalPort>\(internalPort)</NewExternalPort>
            <NewProtocol>UDP</NewProtocol>
            <NewInternalPort>\(internalPort)</NewInternalPort>
            <NewInternalClient>\(lanIP)</NewInternalClient>
            <NewEnabled>1</NewEnabled>
            <NewPortMappingDescription>KKRemote Ephemeral UDP</NewPortMappingDescription>
            <NewLeaseDuration>\(leaseSeconds)</NewLeaseDuration>
            </u:AddPortMapping></s:Body></s:Envelope>
            """
            if Self.soapRequest(url: controlURL, action: "\"\(svcType)#AddPortMapping\"", body: soap, timeout: 1.5) {
                return (internalPort, controlURL, svcType)
            }
        }
        return nil
    }

    private static func httpGet(url: URL, timeout: TimeInterval) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        session.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { out = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.3)
        session.invalidateAndCancel()
        return out
    }

    private static func soapRequest(url: URL, action: String, body: String, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue(action, forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(body.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.3)
        session.invalidateAndCancel()
        return ok
    }
}
#endif
