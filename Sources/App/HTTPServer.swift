import Foundation
import Network

/// Minimal, dependency-free HTTP/1.1 server on Network.framework.
/// Each connection has its own serial queue; requests are handled concurrently across connections.
/// Supports keep-alive, pipelining (sequentially), Content-Length and chunked bodies, `Expect: 100-continue`.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [(String, String)]
    var headers: [String: String]       // lower-cased names
    var body: Data
    var remote: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    static let reasons: [Int: String] = [
        100: "Continue", 200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large", 414: "URI Too Long",
        429: "Too Many Requests", 456: "Quota Exceeded", 500: "Internal Server Error", 503: "Service Unavailable",
    ]
}

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    let port: UInt16
    let localhostOnly: Bool
    let maxBody: Int
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "http.listener")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]
    var onStateChange: (@Sendable (String, Bool) -> Void)?

    init(port: UInt16, localhostOnly: Bool, maxBody: Int = 128 * 1024, handler: @escaping Handler) {
        self.port = port; self.localhostOnly = localhostOnly; self.maxBody = maxBody; self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "HTTPServer", code: 1) }
        if localhostOnly {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        // Without a required endpoint the listener binds all interfaces (0.0.0.0 and ::).
        let l = localhostOnly ? try NWListener(using: params) : try NWListener(using: params, on: nwPort)
        l.newConnectionLimit = 1024
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange?("listening", true)
            case .failed(let e): self?.onStateChange?("failed: \(e.localizedDescription)", false)
            case .cancelled: self?.onStateChange?("stopped", false)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let all = lock.withLock { let c = Array(connections.values); connections.removeAll(); return c }
        all.forEach { $0.close() }
    }

    private func accept(_ nw: NWConnection) {
        let c = Connection(nw: nw, server: self)
        lock.withLock { connections[ObjectIdentifier(c)] = c }
        c.start()
    }

    fileprivate func closed(_ c: Connection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(c)) }
    }

    fileprivate func handle(_ r: HTTPRequest) async -> HTTPResponse { await handler(r) }

    // MARK: - Connection

    fileprivate final class Connection: @unchecked Sendable {
        let nw: NWConnection
        weak var server: HTTPServer?
        let queue = DispatchQueue(label: "http.conn")
        var buffer = Data()
        var busy = false
        var closed = false
        var sentContinue = false
        var idleTimer: DispatchWorkItem?
        let remote: String

        init(nw: NWConnection, server: HTTPServer) {
            self.nw = nw; self.server = server
            if case .hostPort(let host, _) = nw.endpoint { remote = "\(host)".replacingOccurrences(of: "::ffff:", with: "") }
            else { remote = "?" }
        }

        func start() {
            nw.stateUpdateHandler = { [weak self] s in
                if case .failed = s { self?.close() }
                if case .cancelled = s { self?.close() }
            }
            nw.start(queue: queue)
            receive()
            armIdle()
        }

        func close() {
            guard !closed else { return }
            closed = true
            idleTimer?.cancel()
            nw.cancel()
            server?.closed(self)
        }

        private func armIdle() {
            idleTimer?.cancel()
            guard !busy else { return }   // never time out while a request is being processed
            let w = DispatchWorkItem { [weak self] in self?.close() }
            idleTimer = w
            queue.asyncAfter(deadline: .now() + 75, execute: w)
        }

        private func receive() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data, !data.isEmpty { self.buffer.append(data); self.armIdle(); self.process() }
                if done || err != nil { if !self.busy { self.close() } else { self.closed = true } ; return }
                self.receive()
            }
        }

        /// Parse as many complete requests as are buffered (one at a time, in order).
        private func process() {
            guard !busy, !closed else { return }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 32 * 1024 { respondAndClose(431, "Request header too large") }
                return
            }
            guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
                respondAndClose(400, "Malformed request"); return
            }
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard requestLine.count >= 2 else { respondAndClose(400, "Malformed request line"); return }
            let method = String(requestLine[0]).uppercased()
            let target = String(requestLine[1])
            let version = requestLine.count > 2 ? String(requestLine[2]) : "HTTP/1.0"
            if target.utf8.count > 16 * 1024 { respondAndClose(414, "Request URL too long"); return }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = headers[k].map { "\($0), \(v)" } ?? v
            }
            let bodyStart = headEnd.upperBound
            let maxBody = server?.maxBody ?? 128 * 1024
            var body = Data()
            var consumed = bodyStart

            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                sendContinueIfNeeded(headers)
                guard let (decoded, end) = Self.decodeChunked(buffer, from: bodyStart, limit: maxBody) else {
                    if buffer.count - bodyStart > maxBody + 64 * 1024 { respondAndClose(413, "Request payload exceeds the limit") }
                    return   // need more data
                }
                if decoded.count > maxBody { respondAndClose(413, "Request payload exceeds the limit"); return }
                body = decoded; consumed = end
            } else if let lenStr = headers["content-length"] {
                guard let len = Int(lenStr), len >= 0 else { respondAndClose(400, "Invalid Content-Length"); return }
                if len > maxBody { respondAndClose(413, "Request payload exceeds the limit (\(maxBody / 1024) KiB)"); return }
                sendContinueIfNeeded(headers)
                guard buffer.count - bodyStart >= len else { return }   // wait for the rest
                body = buffer.subdata(in: bodyStart..<bodyStart + len)
                consumed = bodyStart + len
            } else if ["POST", "PUT", "PATCH"].contains(method), headers["expect"] != nil {
                respondAndClose(411, "Length required"); return
            }
            buffer.removeSubrange(buffer.startIndex..<consumed)
            sentContinue = false

            let (path, query) = Self.splitTarget(target)
            let req = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body, remote: remote)
            let keepAlive: Bool = {
                let c = headers["connection"]?.lowercased() ?? ""
                return version == "HTTP/1.1" ? !c.contains("close") : c.contains("keep-alive")
            }()
            busy = true
            idleTimer?.cancel()
            Task {
                let resp = await self.server?.handle(req) ?? HTTPResponse.json(503, ["message": "Server stopping"])
                self.queue.async {
                    self.send(resp, keepAlive: keepAlive, headOnly: method == "HEAD")
                    self.busy = false
                    self.armIdle()
                    if !keepAlive || self.closed { self.nw.send(content: nil, isComplete: true, completion: .contentProcessed { _ in self.close() }) }
                    else { self.process() }
                }
            }
        }

        private func sendContinueIfNeeded(_ headers: [String: String]) {
            guard !sentContinue, headers["expect"]?.lowercased() == "100-continue" else { return }
            sentContinue = true
            nw.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }

        private func respondAndClose(_ status: Int, _ message: String) {
            busy = true
            send(.json(status, ["message": message]), keepAlive: false, headOnly: false)
            nw.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close() })
        }

        private func send(_ r: HTTPResponse, keepAlive: Bool, headOnly: Bool) {
            var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reasons[r.status] ?? "Status")\r\n"
            var hasType = false
            for (k, v) in r.headers { head += "\(k): \(v)\r\n"; if k.lowercased() == "content-type" { hasType = true } }
            if !hasType && !r.body.isEmpty { head += "Content-Type: application/json; charset=utf-8\r\n" }
            head += "Content-Length: \(r.body.count)\r\n"
            head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
            head += "Server: Beonyeok\r\n\r\n"
            var out = Data(head.utf8)
            if !headOnly { out.append(r.body) }
            nw.send(content: out, completion: .contentProcessed { _ in })
        }

        static func splitTarget(_ t: String) -> (String, [(String, String)]) {
            guard let q = t.firstIndex(of: "?") else { return (t.removingPercentEncoding ?? t, []) }
            let path = String(t[..<q])
            return (path.removingPercentEncoding ?? path, parseForm(String(t[t.index(after: q)...])))
        }

        /// Returns (decoded body, index after the terminating chunk) or nil if incomplete.
        static func decodeChunked(_ buf: Data, from start: Int, limit: Int) -> (Data, Int)? {
            var i = start
            var out = Data()
            let crlf = Data("\r\n".utf8)
            while true {
                guard let lineEnd = buf.range(of: crlf, in: i..<buf.endIndex) else { return nil }
                let sizeLine = String(data: buf[i..<lineEnd.lowerBound], encoding: .ascii) ?? ""
                guard let size = Int(sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16)
                else { return (out, buf.endIndex) }   // malformed: treat as end
                i = lineEnd.upperBound
                if size == 0 {
                    // Skip optional trailers up to the blank line.
                    guard let end = buf.range(of: Data("\r\n".utf8), in: i..<buf.endIndex) else { return nil }
                    return (out, end.upperBound)
                }
                guard buf.count - i >= size + 2 else { return nil }
                out.append(buf[i..<i + size])
                if out.count > limit { return (out, buf.endIndex) }
                i += size + 2
            }
        }
    }
}

/// application/x-www-form-urlencoded (also used for query strings). Repeated keys are preserved.
func parseForm(_ s: String) -> [(String, String)] {
    s.split(separator: "&", omittingEmptySubsequences: true).map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        func dec(_ x: Substring) -> String {
            String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x)
        }
        return (dec(parts[0]), parts.count > 1 ? dec(parts[1]) : "")
    }
}
