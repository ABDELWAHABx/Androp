import Foundation
import CryptoKit
import Darwin

/// Raw, encrypted file stream between Mac and phone; the fast path for large files.
/// Wire: repeated [u32 big-endian length][AES-256-GCM ciphertext+tag]. The nonce is
/// [u32 direction][u64 counter] and is never sent, so reordered, replayed or injected
/// records fail. Plaintext is [u8 type][payload]. Must match BulkTransferProtocol.kt.
nonisolated enum BulkTransferProtocol {
    static let macToPhone: UInt32 = 1
    static let phoneToMac: UInt32 = 2
    static let typeData: UInt8 = 1
    static let typeEnd: UInt8 = 2
    static let typeHello: UInt8 = 3
    static let maxPayload = 1024 * 1024
    static let tagBytes = 16

    static func nonce(direction: UInt32, counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data()
        withUnsafeBytes(of: direction.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// One direction of a stream with its own record counter.
    nonisolated final class Sealer {
        private let key: SymmetricKey
        private let direction: UInt32
        private var counter: UInt64 = 0

        init(key: SymmetricKey, direction: UInt32) {
            self.key = key
            self.direction = direction
        }

        func seal(type: UInt8, payload: Data) throws -> Data {
            var plain = Data([type])
            plain.append(payload)
            let box = try AES.GCM.seal(plain, using: key, nonce: BulkTransferProtocol.nonce(direction: direction, counter: counter))
            counter += 1
            return box.ciphertext + box.tag
        }

        func open(_ sealed: Data) throws -> (type: UInt8, payload: Data) {
            guard sealed.count > BulkTransferProtocol.tagBytes,
                  sealed.count <= BulkTransferProtocol.maxPayload + 1 + BulkTransferProtocol.tagBytes else {
                throw BulkTransferError.invalidRecord
            }
            let box = try AES.GCM.SealedBox(nonce: BulkTransferProtocol.nonce(direction: direction, counter: counter),
                                            ciphertext: sealed.dropLast(BulkTransferProtocol.tagBytes),
                                            tag: sealed.suffix(BulkTransferProtocol.tagBytes))
            counter += 1
            let plain = try AES.GCM.open(box, using: key)
            guard let type = plain.first else { throw BulkTransferError.invalidRecord }
            return (type, plain.dropFirst())
        }
    }
}

nonisolated enum BulkTransferError: Error { case invalidRecord, closed, timedOut, socket }

/// A blocking TCP endpoint for one transfer. The Mac always listens (the phone already
/// reaches it for the control connection, on home Wi-Fi or the phone's temporary hotspot).
nonisolated final class BulkTransferSocket {
    let port: UInt16
    let key: SymmetricKey
    let keyBase64: String
    private var listenFD: Int32
    private var peerFD: Int32 = -1
    private let lock = NSLock()

    /// Opens a listener on an ephemeral port with a fresh per-transfer key.
    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Darwin.close(fd); return nil }
        listenFD = fd
        port = UInt16(bigEndian: address.sin_port)
        let keyData = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        key = SymmetricKey(data: keyData)
        keyBase64 = keyData.base64EncodedString()
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        if peerFD >= 0 { Darwin.shutdown(peerFD, SHUT_RDWR); Darwin.close(peerFD); peerFD = -1 }
    }

    /// Waits for the phone to connect and prove the key with a hello naming [transferID].
    /// Connections that fail the proof are dropped; the listener closes once one succeeds.
    func acceptPeer(transferID: String, timeout: TimeInterval, isActive: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, isActive() {
            lock.lock(); let fd = listenFD; lock.unlock()
            guard fd >= 0 else { return false }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, min(500, deadline.timeIntervalSinceNow * 1000))))
            guard ready > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            configure(client)
            lock.lock(); peerFD = client; lock.unlock()
            let opener = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
            if let hello = try? readRecord(opener), hello.type == BulkTransferProtocol.typeHello,
               String(data: hello.payload, encoding: .utf8) == transferID {
                helloOpener = opener
                lock.lock(); Darwin.close(listenFD); listenFD = -1; lock.unlock()
                return true
            }
            lock.lock(); Darwin.close(client); peerFD = -1; lock.unlock()
        }
        return false
    }

    /// The receive direction after a successful hello, positioned after it.
    private(set) var helloOpener: BulkTransferProtocol.Sealer?

    private func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func writeRecord(_ sealer: BulkTransferProtocol.Sealer, type: UInt8, payload: Data) throws {
        let sealed = try sealer.seal(type: type, payload: payload)
        var header = UInt32(sealed.count).bigEndian
        try writeAll(Data(bytes: &header, count: 4))
        try writeAll(sealed)
    }

    func readRecord(_ opener: BulkTransferProtocol.Sealer) throws -> (type: UInt8, payload: Data) {
        let header = try readExactly(4)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > BulkTransferProtocol.tagBytes,
              length <= BulkTransferProtocol.maxPayload + 1 + BulkTransferProtocol.tagBytes else { throw BulkTransferError.invalidRecord }
        return try opener.open(try readExactly(length))
    }

    /// Waits for the phone to close its side (it does so after it stored the file).
    func waitForPeerClose(timeout: TimeInterval) {
        lock.lock(); let fd = peerFD; lock.unlock()
        guard fd >= 0 else { return }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&poller, 1, Int32(timeout * 1000))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                lock.lock(); let fd = peerFD; lock.unlock()
                guard fd >= 0 else { throw BulkTransferError.closed }
                let written = Darwin.send(fd, pointer, remaining, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? BulkTransferError.timedOut : BulkTransferError.socket
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while filled < count {
                lock.lock(); let fd = peerFD; lock.unlock()
                guard fd >= 0 else { throw BulkTransferError.closed }
                let read = Darwin.recv(fd, base.advanced(by: filled), count - filled, 0)
                if read == 0 { throw BulkTransferError.closed }
                if read < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? BulkTransferError.timedOut : BulkTransferError.socket
                }
                filled += read
            }
        }
        return data
    }
}
