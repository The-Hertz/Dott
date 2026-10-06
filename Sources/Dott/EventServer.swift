import Foundation

/// Una connessione dall'hook: una riga di JSON, poi (solo per i permessi) la risposta.
final class Connection {
    let fd: Int32
    /// Se true la connessione resta aperta in attesa di una risposta.
    var held = false
    var onClose: (() -> Void)?

    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var delivered = false
    private var closed = false
    private var readSuspended = false
    private var watchdog: DispatchSourceTimer?
    private let onMessage: (Connection, [String: Any]) -> Void

    init(fd: Int32, onMessage: @escaping (Connection, [String: Any]) -> Void) {
        self.fd = fd
        self.onMessage = onMessage
    }

    func start() {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in self?.readable() }
        let fd = self.fd
        s.setCancelHandler { Darwin.close(fd) }
        source = s
        s.resume()
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !closed {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if !delivered {
                    buffer.append(chunk, count: n)
                    if buffer.count > 8_000_000 { close(); return }
                    if let nl = buffer.firstIndex(of: 0x0A) {
                        deliver(Data(buffer[buffer.startIndex..<nl]))
                    }
                }
            } else if n == 0 {
                // L'altro lato ha finito di scrivere (nc lo fa appena ha inviato la riga).
                if !delivered, !buffer.isEmpty { deliver(buffer) }
                if held {
                    watchGone()
                } else {
                    close()
                }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                if held { onClose?() }
                close()
                return
            }
        }
    }

    /// In attesa di una risposta: capiamo che l'hook e' sparito (Claude ha avuto la risposta
    /// altrove) quando un invio a vuoto sul socket fallisce.
    private func watchGone() {
        guard !readSuspended else { return }
        source?.suspend()
        readSuspended = true
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if send(self.fd, "", 0, 0) < 0 {
                let cb = self.onClose
                self.close()
                cb?()
            }
        }
        watchdog = t
        t.resume()
    }

    private func deliver(_ data: Data) {
        delivered = true
        buffer.removeAll()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            onMessage(self, obj)
        }
        if !held { close() }
    }

    func reply(_ json: [String: Any]) {
        guard !closed else { return }
        if var data = try? JSONSerialization.data(withJSONObject: json) {
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        held = false
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        onClose = nil
        watchdog?.cancel()
        watchdog = nil
        if readSuspended { source?.resume(); readSuspended = false }
        source?.cancel()
        source = nil
    }
}

/// Ascolta su un socket Unix privato (solo il tuo utente puo' scriverci).
final class EventServer {
    let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    var onMessage: ((Connection, [String: Any]) -> Void)?

    init(path: String) { self.path = path }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw posixError("path troppo lungo", code: ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strlcpy($0, path, maxLen) }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw posixError("bind") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw posixError("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            let conn = Connection(fd: client) { [weak self] c, payload in
                self?.onMessage?(c, payload)
            }
            connections[ObjectIdentifier(conn)] = conn
            let id = ObjectIdentifier(conn)
            conn.start()
            // Pulizia: una connessione chiusa non serve piu' tenerla in mappa.
            DispatchQueue.main.asyncAfter(deadline: .now() + 130) { [weak self] in
                self?.connections[id] = nil
            }
        }
    }

    private func posixError(_ what: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(code)))"])
    }
}
