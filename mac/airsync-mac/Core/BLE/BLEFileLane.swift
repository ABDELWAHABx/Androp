import Foundation
import CoreBluetooth
import CryptoKit
import UniformTypeIdentifiers

/// Blocking reads and writes over a CBL2CAPChannel for one worker thread. The channel's
/// streams live on their own run-loop thread; the worker waits on a condition.
nonisolated final class BLEFileLaneStream: NSObject, StreamDelegate, @unchecked Sendable {
    enum LaneError: Error { case closed, timedOut, invalidRecord }

    private let channel: CBL2CAPChannel // keeps the channel open
    private let input: InputStream
    private let output: OutputStream
    private let condition = NSCondition()
    private var inbox = Data()
    private var outbox = Data()
    private var finished = false
    private var runLoop: CFRunLoop?
    private static let maximumOutbox = 256 * 1024

    init?(channel: CBL2CAPChannel) {
        guard let input = channel.inputStream, let output = channel.outputStream else { return nil }
        self.channel = channel
        self.input = input
        self.output = output
        super.init()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            input.delegate = self
            output.delegate = self
            input.schedule(in: .current, forMode: .default)
            output.schedule(in: .current, forMode: .default)
            input.open()
            output.open()
            condition.lock(); runLoop = CFRunLoopGetCurrent(); condition.unlock()
            ready.signal()
            while !isFinished { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1)) }
            input.close()
            output.close()
            input.remove(from: .current, forMode: .default)
            output.remove(from: .current, forMode: .default)
        }
        thread.name = "androp-file-lane"
        thread.start()
        ready.wait()
    }

    private var isFinished: Bool {
        condition.lock(); defer { condition.unlock() }
        return finished
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable: readAvailable()
        case .hasSpaceAvailable: pump()
        case .errorOccurred, .endEncountered: close()
        default: break
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 { close(); return }
            if count == 0 { return }
            condition.lock()
            inbox.append(buffer, count: count)
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Runs on the stream thread only.
    private func pump() {
        condition.lock(); defer { condition.unlock() }
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: raw.count)
            }
            if written <= 0 { break }
            outbox.removeFirst(written)
        }
        condition.broadcast()
    }

    private func schedulePump() {
        condition.lock(); let loop = runLoop; condition.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in self?.pump() }
        CFRunLoopWakeUp(loop)
    }

    func write(_ data: Data, timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while outbox.count > Self.maximumOutbox, !finished {
            if !condition.wait(until: deadline) { condition.unlock(); throw LaneError.timedOut }
        }
        guard !finished else { condition.unlock(); throw LaneError.closed }
        outbox.append(data)
        condition.unlock()
        schedulePump()
    }

    /// Waits until everything written has been handed to the channel.
    func flush(timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !outbox.isEmpty {
            if finished { throw LaneError.closed }
            if !condition.wait(until: deadline) { throw LaneError.timedOut }
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval = 30) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while inbox.count < count {
            if finished { throw LaneError.closed }
            if !condition.wait(until: deadline) { throw LaneError.timedOut }
        }
        let bytes = Data(inbox.prefix(count))
        inbox.removeFirst(count)
        return bytes
    }

    func writeRecord(_ sealer: BulkTransferProtocol.Sealer, type: UInt8, payload: Data) throws {
        let sealed = try sealer.seal(type: type, payload: payload)
        var length = UInt32(sealed.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(sealed)
        try write(frame)
    }

    func readRecord(_ opener: BulkTransferProtocol.Sealer, timeout: TimeInterval = 30) throws -> (type: UInt8, payload: Data) {
        let header = try readExactly(4, timeout: timeout)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > BulkTransferProtocol.tagBytes,
              length <= BulkTransferProtocol.maxPayload + 1 + BulkTransferProtocol.tagBytes else { throw LaneError.invalidRecord }
        return try opener.open(try readExactly(length, timeout: timeout))
    }

    /// Unblocks every wait; the stream thread closes the streams and exits.
    func close() {
        condition.lock()
        finished = true
        let loop = runLoop
        condition.broadcast()
        condition.unlock()
        if let loop { CFRunLoopWakeUp(loop) }
    }
}

/// Small files to and from the phone over Bluetooth, on an L2CAP channel beside the GATT link,
/// so a photo or PDF doesn't need the temporary Wi-Fi network (which takes the Mac off its own
/// Wi-Fi). Protocol in BLEFileLaneProtocol. Bigger selections keep the Wi-Fi route.
@MainActor
final class BLEFileLane {
    static let shared = BLEFileLane()
    private static let queue = DispatchQueue(label: "app.androp.file-lane", qos: .userInitiated, attributes: .concurrent)
    private var active: [String: BLEFileLaneStream] = [:]

    private var pairingKey: String? { UserDefaults.standard.string(forKey: "encryptionKey") }

    func canCarry(totalBytes: Int64) -> Bool {
        BLECentralManager.shared.fileLaneAvailable && BLEFileLaneProtocol.fits(totalBytes: totalBytes) && pairingKey != nil
    }

    func cancel(id: String) { active.removeValue(forKey: id)?.close() }

    /// Mac → phone. `opened` is false only when no channel could be opened (nothing was sent),
    /// so the caller can still fall back to the Wi-Fi route.
    @discardableResult
    func send(url: URL, size: Int64, progress: @escaping (Double) -> Void,
              completion: @escaping (_ ok: Bool, _ error: String?, _ opened: Bool) -> Void) -> String {
        let id = UUID().uuidString
        guard let pairingKey, let key = BLEFileLaneProtocol.deriveKey(pairingKeyBase64: pairingKey, id: id) else {
            completion(false, "Bluetooth file transfer isn't available.", false)
            return id
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        BLECentralManager.shared.openFileLane { [weak self] channel in
            guard let self, let channel, let stream = BLEFileLaneStream(channel: channel) else {
                completion(false, "Couldn't open a Bluetooth channel to your phone.", false)
                return
            }
            self.active[id] = stream
            MacPowerManager.shared.setTransferActive(id: "lane-outgoing:\(id)", active: true, timeout: 120)
            Self.queue.async {
                let result = Self.stream(file: url, size: size, mime: mime, id: id, key: key, over: stream, progress: progress)
                stream.close()
                DispatchQueue.main.async {
                    self.active.removeValue(forKey: id)
                    MacPowerManager.shared.setTransferActive(id: "lane-outgoing:\(id)", active: false)
                    completion(result.ok, result.error, true)
                }
            }
        }
        return id
    }

    private nonisolated static func stream(file url: URL, size: Int64, mime: String, id: String, key: SymmetricKey,
                                           over stream: BLEFileLaneStream,
                                           progress: @escaping (Double) -> Void) -> (ok: Bool, error: String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (false, "Couldn't read \(url.lastPathComponent).") }
        defer { try? handle.close() }
        do {
            let sealer = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.macToPhone)
            try stream.write(BLEFileLaneProtocol.preamble(id: id))
            let meta = try JSONSerialization.data(withJSONObject: ["name": url.lastPathComponent, "size": size, "mime": mime])
            try stream.writeRecord(sealer, type: BulkTransferProtocol.typeHello, payload: meta)
            var hasher = SHA256()
            var sent: Int64 = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while let chunk = try handle.read(upToCount: BLEFileLaneProtocol.recordBytes), !chunk.isEmpty {
                hasher.update(data: chunk)
                try stream.writeRecord(sealer, type: BulkTransferProtocol.typeData, payload: chunk)
                sent += Int64(chunk.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.2 {
                    lastProgress = now
                    let fraction = size > 0 ? Double(sent) / Double(size) : 0
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
            guard sent == size else { return (false, "\(url.lastPathComponent) changed while sending.") }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let end = try JSONSerialization.data(withJSONObject: ["sha256": digest, "size": sent])
            try stream.writeRecord(sealer, type: BulkTransferProtocol.typeEnd, payload: end)
            try stream.flush()
            // The phone answers once the file is verified and saved in Downloads.
            let opener = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
            let reply = try stream.readRecord(opener, timeout: 60)
            let result = (try? JSONSerialization.jsonObject(with: reply.payload)) as? [String: Any]
            if result?["ok"] as? Bool == true { return (true, nil) }
            return (false, (result?["error"] as? String) ?? "Your phone couldn't save the file.")
        } catch {
            return (false, "The Bluetooth transfer was interrupted. Try again.")
        }
    }

    /// Phone → Mac: the phone offered a file over BLE. Checks it like the Wi-Fi fast path does,
    /// then opens a channel for the phone to stream into.
    func handleOffer(_ data: [String: Any]) {
        guard let id = data["id"] as? String, BLEFileLaneProtocol.validID(id) else { return }
        func reject(_ reason: String) {
            guard let payload = BLEControlPolicy.envelope(type: "bleFileReject", data: ["id": id, "error": reason]) else { return }
            BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
        }
        guard let name = data["name"] as? String, BLEFileLaneProtocol.validName(name),
              let size = (data["size"] as? NSNumber)?.int64Value, BLEFileLaneProtocol.fits(totalBytes: size) else {
            reject("Your Mac can't take this file over Bluetooth."); return
        }
        guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated else { return }
        guard AppState.shared.quickShareEnabled else { reject("Turn on file receiving in androp on your Mac."); return }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            reject("Your Mac's Downloads folder isn't available."); return
        }
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard free - 64 * 1024 * 1024 > size else { reject("Your Mac doesn't have enough free space."); return }
        guard let pairingKey, let key = BLEFileLaneProtocol.deriveKey(pairingKeyBase64: pairingKey, id: id) else {
            reject("Pair your phone with this Mac again."); return
        }
        BLECentralManager.shared.openFileLane { [weak self] channel in
            guard let self, let channel, let stream = BLEFileLaneStream(channel: channel) else {
                reject("Your Mac couldn't open a Bluetooth channel. Try again."); return
            }
            self.active[id] = stream
            QuickShareManager.shared.bulkReceiveProgress(id: id, progress: 0)
            MacPowerManager.shared.setTransferActive(id: "lane-incoming:\(id)", active: true, timeout: 120)
            Self.queue.async {
                let result = Self.receive(id: id, name: name, size: size, key: key, downloads: downloads, over: stream)
                stream.close()
                DispatchQueue.main.async {
                    self.active.removeValue(forKey: id)
                    MacPowerManager.shared.setTransferActive(id: "lane-incoming:\(id)", active: false)
                    QuickShareManager.shared.bulkReceiveFinished(id: id, success: result.saved != nil, error: result.error)
                    if let saved = result.saved { QuickShareManager.notifyReceived([saved]) }
                }
            }
        }
    }

    private nonisolated static func receive(id: String, name: String, size: Int64, key: SymmetricKey, downloads: URL,
                                            over stream: BLEFileLaneStream) -> (saved: URL?, error: String?) {
        let part = downloads.appendingPathComponent(".androp-\(UUID().uuidString).part")
        var saved: URL?
        var failure = "The Bluetooth transfer was interrupted. Try again."
        let reply = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.macToPhone)
        defer {
            if saved == nil { try? FileManager.default.removeItem(at: part) }
            let answer: [String: Any] = ["ok": saved != nil, "error": saved == nil ? failure : NSNull()]
            if let payload = try? JSONSerialization.data(withJSONObject: answer) {
                try? stream.writeRecord(reply, type: BulkTransferProtocol.typeEnd, payload: payload)
                try? stream.flush(timeout: 10)
            }
        }
        do {
            try stream.write(BLEFileLaneProtocol.preamble(id: id))
            guard FileManager.default.createFile(atPath: part.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: part) else {
                failure = "Couldn't write to Downloads."; return (nil, failure)
            }
            defer { try? handle.close() }
            let opener = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
            var hasher = SHA256()
            var received: Int64 = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            receiving: while true {
                let record = try stream.readRecord(opener)
                switch record.type {
                case BulkTransferProtocol.typeData:
                    received += Int64(record.payload.count)
                    guard received <= size else { failure = "Received more data than expected."; return (nil, failure) }
                    hasher.update(data: record.payload)
                    try handle.write(contentsOf: record.payload)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.2 {
                        lastProgress = now
                        let fraction = size > 0 ? Double(received) / Double(size) : 0
                        DispatchQueue.main.async { QuickShareManager.shared.bulkReceiveProgress(id: id, progress: fraction) }
                    }
                case BulkTransferProtocol.typeEnd:
                    let summary = (try? JSONSerialization.jsonObject(with: record.payload)) as? [String: Any]
                    let expected = (summary?["sha256"] as? String)?.lowercased()
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard received == size, expected == digest else { failure = "File verification failed. Try again."; return (nil, failure) }
                    break receiving
                default:
                    failure = "Unexpected data from your phone."; return (nil, failure)
                }
            }
        } catch {
            return (nil, failure)
        }
        var destination = downloads.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: part, to: destination)
            saved = destination
            return (destination, nil)
        } catch {
            failure = "Couldn't save the file in Downloads."
            return (nil, failure)
        }
    }
}
