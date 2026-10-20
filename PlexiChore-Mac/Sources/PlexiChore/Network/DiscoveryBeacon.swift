import Foundation
import Darwin

/// UDP discovery on port 47801.
/// - Broadcasts the beacon JSON once per second to 255.255.255.255 and every interface's
///   directed broadcast address.
/// - Replies (unicast) to `PLEXI?` queries with the same beacon.
///
/// Implemented with BSD sockets because Network.framework cannot set SO_BROADCAST.
final class DiscoveryBeacon: @unchecked Sendable {
    private let queue = DispatchQueue(label: "plexi.discovery", qos: .utility)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private let payloadProvider: @Sendable () -> Data

    /// `payloadProvider` is invoked on the discovery queue each time a beacon is sent.
    init(payloadProvider: @escaping @Sendable () -> Data) {
        self.payloadProvider = payloadProvider
    }

    var onError: (@Sendable (String) -> Void)?

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func startOnQueue() {
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { onError?("UDP socket() failed: \(errno)"); return }

        var yes: Int32 = 1
        let optLen = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, optLen)
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, optLen)
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, optLen)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = PlexiProtocol.udpPort.bigEndian
        addr.sin_addr = in_addr(s_addr: 0)   // INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            // Still usable for sending beacons; we just won't hear PLEXI? queries.
            onError?("UDP bind(\(PlexiProtocol.udpPort)) failed: errno \(errno) — beacon-only mode")
        }

        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        fd = s

        let rs = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainSocket() }
        rs.setCancelHandler { close(s) }
        readSource = rs
        rs.resume()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.broadcast() }
        timer = t
        t.resume()
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        readSource?.cancel()   // closes fd in cancel handler
        readSource = nil
        fd = -1
    }

    // MARK: Sending

    private func broadcast() {
        guard fd >= 0 else { return }
        let payload = payloadProvider()
        var targets: Set<UInt32> = [0xFFFF_FFFF]   // limited broadcast (network byte order irrelevant: all ones)
        for b in Self.interfaceBroadcastAddresses() { targets.insert(b) }
        for target in targets {
            send(payload, toAddress: target, port: PlexiProtocol.udpPort.bigEndian)
        }
    }

    /// `address` and `port` must already be in network byte order.
    private func send(_ payload: Data, toAddress address: UInt32, port: in_port_t) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port
        dest.sin_addr = in_addr(s_addr: address)
        let s = fd
        payload.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(s, base, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: Receiving

    private func drainSocket() {
        guard fd >= 0 else { return }
        let s = fd
        let capacity = 2048
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(s, raw.baseAddress, capacity, 0, sa, &fromLen)
                    }
                }
            }
            if n <= 0 { break }   // EAGAIN or error
            let bytes = Array(buffer[0..<n])
            guard let text = String(bytes: bytes, encoding: .utf8) else { continue }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == PlexiProtocol.discoveryQuery,
               from.sin_family == sa_family_t(AF_INET) {
                send(payloadProvider(), toAddress: from.sin_addr.s_addr, port: from.sin_port)
            }
            // Anything else (including our own / other hosts' beacons) is ignored.
        }
    }

    // MARK: Interfaces

    /// Directed broadcast addresses (network byte order) of every up, non-loopback IPv4 interface.
    static func interfaceBroadcastAddresses() -> [UInt32] {
        var result: [UInt32] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return result }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            let flags = ifa.ifa_flags
            if let addr = ifa.ifa_addr,
               addr.pointee.sa_family == sa_family_t(AF_INET),
               (flags & UInt32(IFF_UP)) != 0,
               (flags & UInt32(IFF_BROADCAST)) != 0,
               (flags & UInt32(IFF_LOOPBACK)) == 0,
               let bcast = ifa.ifa_dstaddr {   // ifa_broadaddr == ifa_dstaddr on Darwin
                let sin = bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                if sin.sin_family == sa_family_t(AF_INET), sin.sin_addr.s_addr != 0 {
                    result.append(sin.sin_addr.s_addr)
                }
            }
            cursor = ifa.ifa_next
        }
        return result
    }

    /// Human readable IPv4 addresses of this Mac (for the "manual IP" hint in the UI).
    static func localIPv4Addresses() -> [(interface: String, address: String)] {
        var result: [(interface: String, address: String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            let flags = ifa.ifa_flags
            if let addr = ifa.ifa_addr,
               addr.pointee.sa_family == sa_family_t(AF_INET),
               (flags & UInt32(IFF_UP)) != 0,
               (flags & UInt32(IFF_LOOPBACK)) == 0 {
                let hostCapacity = Int(NI_MAXHOST)
                var host = [CChar](repeating: 0, count: hostCapacity)
                let len = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(addr, len, &host, socklen_t(hostCapacity), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: ifa.ifa_name)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { result.append((interface: name, address: ip)) }
                }
            }
            cursor = ifa.ifa_next
        }
        return result
    }
}
