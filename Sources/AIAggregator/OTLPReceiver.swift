import Foundation
import Network

/// Splits a byte stream into HTTP/1.1 requests. Handles keep-alive (several
/// requests per connection) and bodies that arrive across multiple reads.
struct HTTPRequestBuffer {
    static let maxBodyBytes = 16 * 1024 * 1024

    private var data = Data()
    private(set) var isMalformed = false

    mutating func append(_ chunk: Data) { data.append(chunk) }

    /// Returns the next complete request body, or nil until more bytes arrive.
    mutating func nextBody() -> Data? {
        guard !isMalformed, let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)

        var length = 0
        for line in header.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            guard let n = Int(parts[1].trimmingCharacters(in: .whitespaces)), n >= 0, n <= Self.maxBodyBytes else {
                isMalformed = true
                return nil
            }
            length = n
        }

        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        let body = Data(data[bodyStart..<bodyEnd])
        data = Data(data[bodyEnd...])
        return body
    }
}

/// Minimal OTLP/HTTP endpoint for the coding agents' telemetry export. Bound to loopback,
/// or to this Mac's Tailscale address to take exports from the user's other machines; the
/// payloads carry account identifiers, so it never listens on any other interface, and
/// the Tailscale one only takes connections from tailnet addresses.
final class OTLPReceiver {
    private let address: IPv4Address
    private let port: UInt16
    /// The body, and the sender's address when it isn't this Mac.
    private let onBody: (Data, String?) -> Void
    private let onError: (String?) -> Void
    private let queue: DispatchQueue
    private var listener: NWListener?

    init(address: IPv4Address = .loopback, port: UInt16, queue: DispatchQueue,
         onBody: @escaping (Data, String?) -> Void, onError: @escaping (String?) -> Void) {
        self.address = address
        self.port = port
        self.queue = queue
        self.onBody = onBody
        self.onError = onError
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onError(nil)
                case .failed(let error): self?.onError("Port \(self?.port ?? 0): \(error.localizedDescription)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                var sender: String?
                if case .hostPort(.ipv4(let peer), _) = connection.endpoint, peer != .loopback {
                    guard Tailnet.contains(peer) else { connection.cancel(); return }
                    sender = "\(peer)"
                }
                connection.start(queue: self.queue)
                self.receive(on: connection, buffer: HTTPRequestBuffer(), sender: sender)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onError("Port \(port): \(error.localizedDescription)")
        }
    }

    private func receive(on connection: NWConnection, buffer: HTTPRequestBuffer, sender: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            while let body = buffer.nextBody() {
                self.onBody(body, sender)
                connection.send(content: Self.okResponse, completion: .contentProcessed { _ in })
            }
            if buffer.isMalformed || isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, sender: sender)
            }
        }
    }

    private static let okResponse = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
}

/// Tailscale's address space (100.64.0.0/10) and this Mac's address in it.
enum Tailnet {
    static func contains(_ address: IPv4Address) -> Bool {
        let b = [UInt8](address.rawValue)
        return b.count == 4 && b[0] == 100 && (b[1] & 0xC0) == 64
    }

    /// This Mac's tailnet address, when Tailscale is connected.
    static func localAddress() -> IPv4Address? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var node = list
        while let ifa = node?.pointee {
            defer { node = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let address = withUnsafeBytes(of: sin.sin_addr) { IPv4Address(Data($0)) }
            if let address, contains(address) { return address }
        }
        return nil
    }

    /// The machine name for a tailnet address, from Tailscale's MagicDNS ("mini4" for
    /// mini4.tailnet.ts.net), or the address itself when it has none. Blocks on DNS.
    static func hostName(for address: String) -> String {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return address }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return address }
        return shortName(String(cString: name))
    }

    /// First label of a host name: "mini4.tail2217fd.ts.net." → "mini4".
    static func shortName(_ name: String) -> String {
        name.split(separator: ".").first.map(String.init) ?? name
    }
}
