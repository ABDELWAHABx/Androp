import Foundation
import CryptoKit

/// Receives a file the paired phone streams over the fast path, straight into
/// Downloads, verifying its SHA-256 while it arrives. Files from your own phone
/// arrive without a consent prompt, like AirDrop between your own devices.
nonisolated enum BulkFileReceiver {
    private static let queue = DispatchQueue(label: "app.androp.bulk-receive", qos: .userInitiated, attributes: .concurrent)

    @MainActor
    static func handleOffer(_ data: [String: Any]) {
        guard let id = data["id"] as? String, (1...128).contains(id.utf8.count),
              let name = data["name"] as? String, validName(name),
              let size = data["size"] as? Int, (0...(1 << 50)).contains(size) else { return }
        func reject(_ reason: String) {
            WebSocketServer.shared.sendBulkFileMessage(type: "fileBulkReject", data: ["id": id, "error": reason])
        }
        guard !AppState.shared.isSyncPaused, AppState.shared.device?.isRegularConnection == true else {
            reject("Your Mac isn't ready. Try again."); return
        }
        guard AppState.shared.quickShareEnabled else { reject("Turn on file receiving in androp on your Mac."); return }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            reject("Your Mac's Downloads folder isn't available."); return
        }
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard free - 64 * 1024 * 1024 > Int64(size) else { reject("Your Mac doesn't have enough free space."); return }
        guard let socket = BulkTransferSocket() else { reject("Your Mac couldn't open a transfer port."); return }
        guard WebSocketServer.shared.sendBulkFileMessage(type: "fileBulkAccept",
            data: ["id": id, "port": Int(socket.port), "key": socket.keyBase64]) else { socket.close(); return }
        QuickShareManager.shared.bulkReceiveProgress(id: id, progress: 0)
        MacPowerManager.shared.setTransferActive(id: "bulk-incoming:\(id)", active: true, timeout: 120)
        queue.async { receive(socket: socket, id: id, name: name, size: size, downloads: downloads) }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
    }

    private static func receive(socket: BulkTransferSocket, id: String, name: String, size: Int, downloads: URL) {
        let part = downloads.appendingPathComponent(".androp-\(UUID().uuidString).part")
        var saved: URL?
        var failure = "The transfer was interrupted. Try again."
        defer {
            socket.close()
            if saved == nil { try? FileManager.default.removeItem(at: part) }
            let result = saved
            let message = failure
            DispatchQueue.main.async {
                MacPowerManager.shared.setTransferActive(id: "bulk-incoming:\(id)", active: false)
                QuickShareManager.shared.bulkReceiveFinished(id: id, success: result != nil, error: message)
                if let result { QuickShareManager.notifyReceived([result]) }
                WebSocketServer.shared.sendBulkFileMessage(type: "fileBulkResult",
                    data: ["id": id, "ok": result != nil, "error": result == nil ? message as Any : NSNull()])
            }
        }
        guard socket.acceptPeer(transferID: id, timeout: 15, isActive: { true }), let opener = socket.helloOpener else {
            failure = "Your phone couldn't reach this Mac. Check that both are on the same Wi-Fi."; return
        }
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else { failure = "Couldn't write to Downloads."; return }
        var hasher = SHA256()
        var received = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var lastPower = lastProgress
        do {
            defer { try? handle.close() }
            receiving: while true {
                let record = try socket.readRecord(opener)
                switch record.type {
                case BulkTransferProtocol.typeData:
                    received += record.payload.count
                    guard received <= size else { failure = "Received more data than expected."; return }
                    hasher.update(data: record.payload)
                    try handle.write(contentsOf: record.payload)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.2 {
                        lastProgress = now
                        let fraction = size == 0 ? 0 : Double(received) / Double(size)
                        DispatchQueue.main.async { QuickShareManager.shared.bulkReceiveProgress(id: id, progress: fraction) }
                    }
                    if now - lastPower >= 30 {
                        lastPower = now
                        DispatchQueue.main.async {
                            MacPowerManager.shared.setTransferActive(id: "bulk-incoming:\(id)", active: true, timeout: 120)
                        }
                    }
                case BulkTransferProtocol.typeEnd:
                    let summary = (try? JSONSerialization.jsonObject(with: record.payload)) as? [String: Any]
                    let expected = (summary?["sha256"] as? String)?.lowercased()
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard received == size, expected == digest else { failure = "File verification failed. Try again."; return }
                    break receiving
                default:
                    failure = "Unexpected data from your phone."; return
                }
            }
        } catch {
            return
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
        } catch {
            failure = "Couldn't save the file in Downloads."
        }
    }
}
