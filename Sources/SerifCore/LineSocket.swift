import Foundation
import Darwin

// Newline-delimited messages over Unix stream sockets. All callbacks and `send`/`close`
// are meant to run on the `queue` given at creation (it must be serial).

public enum LineSocketError: Error { case pathTooLong, syscall(String, Int32) }

/// Longest accepted line (without its newline); a peer exceeding it is disconnected.
private let maxLineBytes = 64 * 1024 * 1024

private func makeSocket() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd >= 0 { configure(fd) }
    return fd
}

/// No SIGPIPE on writes, and close-on-exec: the engine's PTY children must not inherit its sockets.
private func configure(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

/// Fills a sockaddr_un; nil if the path does not fit in `sun_path` (104 bytes incl. NUL).
private func withSockaddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func connectedFD(path: String) -> Int32? {
    let fd = makeSocket()
    guard fd >= 0 else { return nil }
    let ok = withSockaddr(path) { connect(fd, $0, $1) == 0 } ?? false
    if !ok { close(fd); return nil }
    return fd
}

public final class LineConnection {
    public var onLine: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeActive = false          // write source is resumed (buffer non-empty)
    private var closed = false
    private var pendingCancels = 2
    private var inbuf = [UInt8]()
    private var scanned = 0                   // bytes of `inbuf` already searched for "\n"
    private var outbuf = [UInt8]()
    private var outOffset = 0
    /// Server bookkeeping: called once when the connection is fully closed.
    var onClosedInternal: ((LineConnection) -> Void)?

    // Source handlers retain self until the sources are cancelled (close() or EOF), so a live
    // connection is never deallocated early; an unclosed one stays alive on purpose.
    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        setNonBlocking(fd)
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { self.readReady() }
        w.setEventHandler { self.writeReady() }
        r.setCancelHandler { self.sourceCancelled() }
        w.setCancelHandler { self.sourceCancelled() }
        readSource = r
        writeSource = w
        r.resume()
    }

    /// Bytes accepted by `send` that the peer has not read yet.
    public var pendingBytes: Int { outbuf.count - outOffset }

    /// Appends the line plus "\n" to the outgoing buffer and writes what the socket accepts.
    /// Must be called on the connection's queue.
    public func send(_ line: Data) {
        guard !closed else { return }
        outbuf.append(contentsOf: line)
        outbuf.append(0x0A)
        flush()
    }

    /// Idempotent. Cancels the sources; `onClose` fires once, after the fd is released.
    public func close() {
        guard !closed else { return }
        closed = true
        // A source must be resumed before it can be cancelled and released.
        if !writeActive { writeSource?.resume(); writeActive = true }
        readSource?.cancel()
        writeSource?.cancel()
    }

    private func sourceCancelled() {
        pendingCancels -= 1
        guard pendingCancels == 0 else { return }
        Darwin.close(fd)
        readSource = nil
        writeSource = nil
        let cb = onClose
        onLine = nil
        onClose = nil
        outbuf = []
        inbuf = []
        cb?()
        onClosedInternal?(self)
        onClosedInternal = nil
    }

    private func flush() {
        while outOffset < outbuf.count {
            let n = outbuf.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + outOffset, outbuf.count - outOffset) }
            if n > 0 { outOffset += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if !writeActive { writeActive = true; writeSource?.resume() }
                return
            }
            close()
            return
        }
        outbuf.removeAll(keepingCapacity: false)
        outOffset = 0
        if writeActive && !closed { writeActive = false; writeSource?.suspend() }
    }

    private func writeReady() { if !closed { flush() } }

    private func readReady() {
        guard !closed else { return }
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        if n == 0 { close(); return }
        if n < 0 {
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { close() }
            return
        }
        inbuf.append(contentsOf: chunk[0..<n])
        var head = 0
        while !closed {
            let nl: Int? = inbuf.withUnsafeBytes { raw in
                let start = max(scanned, head)
                guard start < raw.count, let p = memchr(raw.baseAddress! + start, 0x0A, raw.count - start) else { return nil }
                return raw.baseAddress!.distance(to: UnsafeRawPointer(p))
            }
            guard let nl else { break }
            let line = Data(inbuf[head..<nl])
            head = nl + 1
            scanned = head
            onLine?(line)
        }
        guard !closed else { return }
        if head > 0 { inbuf.removeSubrange(0..<head) }
        scanned = inbuf.count   // the remainder has no newline
        if inbuf.count > maxLineBytes { close() }
    }
}

public final class LineServer {
    private let path: String
    private let queue: DispatchQueue
    private let onConnection: (LineConnection) -> Void
    private var listenFD: Int32
    private var source: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LineConnection] = [:]
    private var closed = false

    /// Unlinks a stale socket file, binds, chmods to 0600 and listens.
    public init(path: String, queue: DispatchQueue, onConnection: @escaping (LineConnection) -> Void) throws {
        self.path = path
        self.queue = queue
        self.onConnection = onConnection
        unlink(path)
        let fd = makeSocket()
        guard fd >= 0 else { throw LineSocketError.syscall("socket", errno) }
        guard let bound = withSockaddr(path, { bind(fd, $0, $1) }) else {
            Darwin.close(fd); throw LineSocketError.pathTooLong
        }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw LineSocketError.syscall("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { let e = errno; Darwin.close(fd); unlink(path); throw LineSocketError.syscall("listen", e) }
        setNonBlocking(fd)
        listenFD = fd
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { self.acceptReady() }
        s.setCancelHandler { Darwin.close(fd) }
        source = s
        s.resume()
    }

    private func acceptReady() {
        while !closed {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }   // EAGAIN (drained) or a transient error; the source fires again
            configure(fd)
            let conn = LineConnection(fd: fd, queue: queue)
            let id = ObjectIdentifier(conn)
            connections[id] = conn   // keep alive until it closes
            conn.onClosedInternal = { [weak self] _ in self?.connections[id] = nil }
            onConnection(conn)
        }
    }

    /// Stops accepting and unlinks the socket file; accepted connections stay open.
    public func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        unlink(path)
    }

    deinit { if !closed { source?.cancel(); unlink(path) } }
}

public enum LineClient {
    /// Connects; I/O afterwards is non-blocking with callbacks on `queue`. nil if nothing listens.
    public static func connect(path: String, queue: DispatchQueue) -> LineConnection? {
        guard let fd = connectedFD(path: path) else { return nil }
        return LineConnection(fd: fd, queue: queue)
    }

    /// Blocking one-shot: send one line, wait for one reply line (`timeout` nil = forever).
    public static func request(path: String, line: Data, timeout: TimeInterval?) -> Data? {
        guard let fd = connectedFD(path: path) else { return nil }
        defer { Darwin.close(fd) }
        setNonBlocking(fd)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        func wait(_ events: Int32) -> Bool {
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            while true {
                var ms: Int32 = -1
                if let deadline {
                    let left = deadline.timeIntervalSinceNow
                    if left <= 0 { return false }
                    ms = Int32(min(left * 1000 + 1, Double(Int32.max)))
                }
                let r = poll(&p, 1, ms)
                if r > 0 { return true }
                if r == 0 { return false }
                if errno != EINTR { return false }
            }
        }
        var out = [UInt8](line); out.append(0x0A)
        var off = 0
        while off < out.count {
            let n = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, out.count - off) }
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            guard n < 0, errno == EAGAIN, wait(Int32(POLLOUT)) else { return nil }
        }
        var acc = [UInt8](), chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard wait(Int32(POLLIN)) else { return nil }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n == 0 { return nil }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if let i = chunk[0..<n].firstIndex(of: 0x0A) {
                acc.append(contentsOf: chunk[0..<i])
                return Data(acc)
            }
            acc.append(contentsOf: chunk[0..<n])
            if acc.count > maxLineBytes { return nil }
        }
    }
}
