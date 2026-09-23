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

/// Minimal OTLP/HTTP endpoint for Claude Code's telemetry export. Loopback only:
/// the payloads carry account identifiers and must never be reachable off-machine.
final class OTLPReceiver {
    private let port: UInt16
    private let onBody: (Data) -> Void
    private let onError: (String?) -> Void
    private let queue = DispatchQueue(label: "com.graywzc.AIAggregator.otlp")
    private var listener: NWListener?

    init(port: UInt16, onBody: @escaping (Data) -> Void, onError: @escaping (String?) -> Void) {
        self.port = port
        self.onBody = onBody
        self.onError = onError
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
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
                connection.start(queue: self.queue)
                self.receive(on: connection, buffer: HTTPRequestBuffer())
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onError("Port \(port): \(error.localizedDescription)")
        }
    }

    private func receive(on connection: NWConnection, buffer: HTTPRequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            while let body = buffer.nextBody() {
                self.onBody(body)
                connection.send(content: Self.okResponse, completion: .contentProcessed { _ in })
            }
            if buffer.isMalformed || isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static let okResponse = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
}
