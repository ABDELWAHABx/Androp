//
//  WebSocketServer+Outgoing.swift
//  airsync-mac
//

import Foundation
import Swifter
import CryptoKit
import AppKit

extension WebSocketServer {
    // A receiver advertises a bounded chunk inbox. Multiple independent 8-chunk
    // windows can overflow it, so file sends share one FIFO while control traffic
    // continues on the existing transport queues.
    private static let fileSendQueue = DispatchQueue(label: "app.androp.file-send", qos: .utility)

    
    // MARK: - Sending Helpers

    @discardableResult
    func sendPowerProtocol(type: String, data: [String: Any]) -> Bool {
        guard !AppState.shared.isSyncPaused,
              let bytes = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
              let payload = String(data: bytes, encoding: .utf8) else { return false }
        if sendDataToFirstAvailable(bytes) { return true }
        guard BLECentralManager.shared.isAuthenticated else { return false }
        return BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
    }

    /// Tells the phone whether macOS will accept remote pointer/keyboard input.
    func sendRemoteControlStatus(inputAllowed: Bool) {
        _ = sendPowerProtocol(type: "remoteControlStatus", data: ["inputAllowed": inputAllowed])
    }

    func broadcast(message: String) {
        lock.lock()
        let sessions = primarySessionID == nil ? [] : activeSessions
        lock.unlock()
        for session in sessions { _ = enqueueWrite(Data(message.utf8), to: session, encrypt: false) }
    }

    @discardableResult
    func sendToFirstAvailable(message: String) -> Bool {
        return sendDataToFirstAvailable(Data(message.utf8))
    }

    @discardableResult
    func sendDataToFirstAvailable(_ data: Data) -> Bool {
        lock.lock()
        let session = activeSessions.first { ObjectIdentifier($0) == primarySessionID }
        lock.unlock()
        guard let session = session else { return false }
        return enqueueWrite(data, to: session)
    }

    /// A slow peer must not hold the application state lock or block the main
    /// thread. The transfer window and this queue bound pending network work.
    @discardableResult
    func enqueueWrite(_ data: Data, to session: WebSocketSession, encrypt: Bool = true) -> Bool {
        lock.lock()
        guard shouldRun, pendingWrites < 64, activeSessions.contains(where: { $0 === session }) else { lock.unlock(); return false }
        let generation = lifecycleGeneration
        let key = symmetricKey
        pendingWrites += 1
        lock.unlock()
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.pendingWrites -= 1
                self.lock.unlock()
            }
            self.lock.lock()
            let valid = self.shouldRun && self.lifecycleGeneration == generation && self.activeSessions.contains(where: { $0 === session })
            self.lock.unlock()
            guard valid else { return }
            if encrypt, let key = key, let encrypted = encryptData(data, using: key) {
                session.writeText(encrypted)
            } else if let message = String(data: data, encoding: .utf8) {
                session.writeText(message)
            }
        }
        return true
    }

    private func sendMessage(type: String, data: [String: Any]) {
        // Fire-and-forget status/UI commands may originate from system callbacks.
        // Move the entire route to main before touching BLE, without blocking
        // those callers or claiming that a future enqueue has already succeeded.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.sendMessage(type: type, data: data) }
            return
        }
        guard !AppState.shared.isSyncPaused else { return }
        let messageDict: [String: Any] = [
            "type": type,
            "data": data
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: messageDict, options: [])
            let sent = sendDataToFirstAvailable(jsonData)
            if !sent && BLECentralManager.shared.isAuthenticated {
                sendOverBLE(type: type, data: data)
            }
        } catch {
            print("[websocket] Error creating \(type) message: \(error)")
        }
    }

    private func sendOverBLE(type: String, data: [String: Any]) {
        print("[ble] Sending message over BLE: \(type)")
        switch type {
        case "notificationAction", "mediaControl", "volumeControl", "callControl",
             "toggleNowPlaying", "macVolume", "modifierStatus", "macMediaControlResponse",
             "phoneHotspotControl":
            // One bounded envelope preserves seek positions, reply text and action
            // parameters; the phone uses the same validated handlers as Wi-Fi.
            guard let payload = BLEControlPolicy.envelope(type: type, data: data) else { return }
            BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
        case "clipboardUpdate":
            if let content = data["content"] as? String {
                BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charClipboardDataWrite, payload: content)
            }
        case "dismissNotification":
            if let id = data["id"] as? String {
                BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charNotificationDismiss, payload: id)
            }
        case "status":
            guard let payload = BLEControlPolicy.envelope(type: type, data: BLEControlPolicy.compactStatus(data)) else { return }
            BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
        case "toggleAppNotif":
            if let package = data["package"] as? String, let state = data["state"] as? String {
                let payload = "toggleNotif|\(package)|\(state)"
                BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
            }
        case "toggleAppNotifs":
            if let packages = data["packages"] as? [String], let state = data["state"] as? String,
               let json = try? JSONSerialization.data(withJSONObject: ["packages": packages, "state": state]),
               let payload = String(data: json, encoding: .utf8) {
                BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: "toggleNotifs|" + payload)
            }
        case "disconnectRequest":
            BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: "manual_disconnect")
        default:
            print("[ble] No BLE mapping for type: \(type)")
        }
    }

    /// True means the connected transport accepted the request, not that the
    /// phone played sound. The phone respects its silent and Do Not Disturb settings.
    @discardableResult
    func sendFindPhone(stop: Bool = false) -> Bool {
        guard !AppState.shared.isSyncPaused, AppState.shared.device != nil else { return false }
        let message: [String: Any] = ["type": "findPhone", "data": ["action": stop ? "stop" : "start"]]
        if let data = try? JSONSerialization.data(withJSONObject: message), sendDataToFirstAvailable(data) {
            return true
        }
        return BLECentralManager.shared.writeChunked(
            characteristicUUID: BLEConstants.charMediaControl, payload: stop ? "stopFindPhone" : "findPhone")
    }

    // MARK: - Outgoing Requests

    func sendDisconnectRequest() {
        sendMessage(type: "disconnectRequest", data: [:])
    }

    func sendQuickShareTrigger() {
        // print("[websocket] Quick Share trigger requested")
        sendMessage(type: "startQuickShare", data: [:])
    }

    func sendRefreshAdbPortsRequest() {
        sendMessage(type: "refreshAdbPorts", data: [:])
    }

    func sendTransferCancel(id: String) {
        sendMessage(type: "fileTransferCancel", data: ["id": id])
    }

    func toggleNotification(for package: String, to state: Bool) {
        guard !AppState.shared.isSyncPaused, var app = AppState.shared.androidApps[package], app.listening != state else { return }
        app.listening = state
        AppState.shared.androidApps[package] = app
        AppState.shared.saveAppsToDisk()

        sendMessage(type: "toggleAppNotif", data: ["package": package, "state": "\(state)"])
    }

    func toggleNotifications(for packages: [String], to state: Bool) {
        guard !AppState.shared.isSyncPaused, AppState.shared.device != nil else { return }
        var apps = AppState.shared.androidApps
        var changed: [String] = []
        for package in Set(packages) {
            guard var app = apps[package], app.listening != state else { continue }
            app.listening = state
            apps[package] = app
            changed.append(package)
        }
        guard !changed.isEmpty else { return }
        AppState.shared.androidApps = apps
        AppState.shared.saveAppsToDisk()
        // Keep each command bounded; each batch is one transaction on Android.
        for start in stride(from: 0, to: changed.count, by: 512) {
            let batch = Array(changed[start..<min(start + 512, changed.count)])
            sendMessage(type: "toggleAppNotifs", data: ["packages": batch, "state": "\(state)"])
        }
    }

    func sendBrowseRequest(path: String, showHidden: Bool = false) {
        sendMessage(type: "browseLs", data: ["path": path, "showHidden": showHidden])
    }

    func sendPullRequest(path: String) {
        let message = FileTransferProtocol.buildFilePull(path: path)
        sendToFirstAvailable(message: message)
    }

    func dismissNotification(id: String) {
        sendMessage(type: "dismissNotification", data: ["id": id])
    }

    func sendNotificationAction(id: String, name: String, text: String? = nil) {
        var data: [String: Any] = ["id": id, "name": name]
        if let t = text, !t.isEmpty { data["text"] = t }
        sendMessage(type: "notificationAction", data: data)
    }

    // MARK: - Media Controls

    func togglePlayPause() { sendMediaAction("playPause") }
    func skipNext() { sendMediaAction("next") }
    func skipPrevious() { sendMediaAction("previous") }
    func stopMedia() { sendMediaAction("stop") }
    func toggleLike() { sendMediaAction("toggleLike") }
    func like() { sendMediaAction("like") }
    func unlike() { sendMediaAction("unlike") }

    /// Seek Android playback to a specific position (in seconds).
    func seekTo(positionSeconds: Double) {
        guard let positionMs = NowPlayingInfo.seekMilliseconds(positionSeconds) else { return }
        sendMessage(type: "mediaControl", data: ["action": "seekTo", "positionMs": positionMs])
    }

    private func sendMediaAction(_ action: String) {
        sendMessage(type: "mediaControl", data: ["action": action])

    }

    /// Forward a system media command (from MPRemoteCommandCenter) back to Android.
    /// - action: "play", "pause", "playPause", "nextTrack", "previousTrack"
    func sendAndroidMediaControl(action: String) {
        // Map MPRemoteCommandCenter-style names to the Android protocol's action names
        let androidAction: String
        switch action {
        case "play":          androidAction = "play"
        case "pause":         androidAction = "pause"
        case "playPause":     androidAction = "playPause"
        case "nextTrack":     androidAction = "next"
        case "previousTrack": androidAction = "previous"
        default:              androidAction = action
        }
        sendMediaAction(androidAction)
    }

    // MARK: - Volume Controls

    func volumeUp() { sendVolumeAction("increaseVolume") }
    func volumeDown() { sendVolumeAction("decreaseVolume") }
    func toggleMute() { sendVolumeAction("toggleMute") }

    func setVolume(_ volume: Int) {
        sendMessage(type: "volumeControl", data: ["action": "setVolume", "volume": volume])
    }

    private func sendVolumeAction(_ action: String) {
        sendMessage(type: "volumeControl", data: ["action": action])

    }

    func sendMacVolumeUpdate(level: Int) {
        sendMessage(type: "macVolume", data: ["volume": level])
    }

    func sendModifierStatus(status: [String: [String: Any]]) {
        sendMessage(type: "modifierStatus", data: status)
    }

    @discardableResult
    func sendClipboardProtocol(type: String = "clipboardUpdate", data: [String: Any]) -> Bool {
        guard !AppState.shared.isSyncPaused else { return false }
        if let payload = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
           sendDataToFirstAvailable(payload) { return true }
        var envelope = data
        envelope["andropClipboard"] = 1
        envelope["kind"] = type == "clipboardAck" ? "ack" : "update"
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: payload, encoding: .utf8) else { return false }
        return BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charClipboardDataWrite, payload: text)
    }

    func sendClipboardUpdate(_ message: String) {
        let sent = sendToFirstAvailable(message: message)
        if !sent && BLECentralManager.shared.isAuthenticated {
             // Extract text if possible or just send raw
             if let data = message.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let innerData = dict["data"] as? [String: Any],
                let text = innerData["text"] as? String {
                 BLETransportBridge.shared.sendClipboard(text)
             }
        }
    }

    // MARK: - Device Status (Mac -> Android)

    func sendDeviceStatus(batteryLevel: Int, isCharging: Bool, isPaired: Bool, musicInfo: NowPlayingInfo?, albumArtBase64: String? = nil) {
        var statusDict: [String: Any] = [
            "battery": ["level": batteryLevel, "isCharging": isCharging],
            "isPaired": isPaired
        ]

        if let musicInfo {
            var musicDict: [String: Any] = [
                "isPlaying": musicInfo.isPlaying ?? false,
                "title": musicInfo.title ?? "",
                "artist": musicInfo.artist ?? "",
                "volume": MacRemoteManager.shared.lastVolumeLevel,
                "isMuted": MacRemoteManager.shared.lastVolumeLevel == 0,
                "likeStatus": "none",
                "elapsedTime": musicInfo.elapsedTime ?? 0,
                "duration": musicInfo.duration ?? 0,
                "timestamp": musicInfo.timestamp ?? "",
                "playbackRate": musicInfo.playbackRate ?? 1.0
            ]
            
            if let art = albumArtBase64 {
                musicDict["albumArt"] = art
                if art.isEmpty { musicDict["albumArtLite"] = "" }
            }

            statusDict["music"] = musicDict
        }

        sendMessage(type: "status", data: statusDict)
    }

    // MARK: - Call Control

    /// Executes a call control action on the Android device via ADB.
    /// Maps generic actions (accept, end) to specific ADB key events.
    func sendMacStatusOverBLE() {
        let batteryLevel: Int
        let isCharging: Bool
        
        if let status = BatteryInfo.fetchStatus() {
            batteryLevel = status.percentage
            isCharging = status.isCharging
        } else {
            batteryLevel = -1 // Desktop Mac
            isCharging = false
        }
        
        let payload = "\(batteryLevel)|\(isCharging ? "1" : "0")"
        if let data = payload.data(using: .utf8) {
            BLECentralManager.shared.write(characteristicUUID: BLEConstants.charMacBattery, data: data)
        }
    }

    func sendCallAction(eventId: String, action: String) {
        let commandAction: String
        switch action.lowercased() {
        case "accept":
            commandAction = "accept"
        case "decline":
            commandAction = "decline"
        case "end":
            commandAction = "end"
        default:
            commandAction = action.lowercased()
        }
        
        // Natively send programmatic control command over WebSocket / BLE sync channel
        sendMessage(type: "callControl", data: ["action": commandAction])
    }

    // MARK: - File Transfer (Mac -> Android)

    /// Initiates a robust file transfer to the connected device.
    /// Implements a sliding window protocol with checksum verification and retry logic for reliable delivery.
    @discardableResult
    func sendFile(url: URL, chunkSize: Int = 256 * 1024, isClipboard: Bool = false,
                  transferID: String = UUID().uuidString, expectedDeviceID: String? = nil,
                  expectedFileSize: Int64? = nil,
                  progress: ((Double) -> Void)? = nil,
                  completion: ((Bool, String?) -> Void)? = nil) -> String {
        let chunkSize = min(max(chunkSize, 16 * 1024), 1024 * 1024)
        let deviceMatches = expectedDeviceID == nil || AppState.shared.device?.deviceId == expectedDeviceID
        lock.lock()
        let session = activeSessions.first { ObjectIdentifier($0) == primarySessionID }
        let generation = lifecycleGeneration
        let queueFull = outgoingAcks.count >= 64
        let available = shouldRun && deviceMatches && session != nil && !queueFull && outgoingAcks[transferID] == nil
        if available { outgoingAcks[transferID] = [] }
        lock.unlock()
        guard available, let session else {
            DispatchQueue.main.async {
                completion?(false, queueFull ? "The transfer queue is full. Wait for current files to finish and try again."
                    : "Connect your phone over Wi-Fi before sending files.")
            }
            return transferID
        }
        Self.fileSendQueue.async { [weak self] in
            guard let self else { return }
            let powerID = "ws-outgoing:\(transferID)"
            var succeeded = false
            var failure: String? = "The transfer was interrupted. Reconnect your phone and try again."
            defer {
                MacPowerManager.shared.setTransferActive(id: powerID, active: false)
                if !succeeded { _ = send(FileTransferProtocol.buildCancel(id: transferID)) }
                self.lock.lock()
                self.outgoingAcks.removeValue(forKey: transferID)
                self.outgoingVerification.removeValue(forKey: transferID)
                self.lock.unlock()
                DispatchQueue.main.async { completion?(succeeded, succeeded ? nil : failure) }
            }
            func isActive() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.shouldRun && self.lifecycleGeneration == generation &&
                    self.primarySessionID == ObjectIdentifier(session) && self.outgoingAcks[transferID] != nil
            }
            func send(_ message: String) -> Bool {
                isActive() && self.enqueueWrite(Data(message.utf8), to: session)
            }
            guard isActive(), url.isFileURL else { return }
            var lastPowerNote: TimeInterval = -10
            func noteFileIO() {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastPowerNote >= 10 else { return }
                self.lock.lock()
                if self.shouldRun && self.lifecycleGeneration == generation &&
                    self.primarySessionID == ObjectIdentifier(session) && self.outgoingAcks[transferID] != nil {
                    lastPowerNote = now
                    MacPowerManager.shared.setTransferActive(id: powerID, active: true)
                }
                self.lock.unlock()
            }
            noteFileIO()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                failure = "Couldn't open the selected file. Choose it again in Finder."
                return
            }
            defer { try? handle.close() }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard expectedFileSize == nil || expectedFileSize == Int64(size) else {
                    failure = "The file changed since you selected it. Choose it again before sending."; return
                }
                // Hash each first-send chunk once, instead of rereading the whole file
                // before the transfer can begin. The receiver verifies the final digest.
                var hasher = SHA256()
                let checksum: String? = nil
                let mime = self.mimeType(for: url) ?? "application/octet-stream"
                let bulk = BulkTransferSocket()
                defer { bulk?.close() }
                guard send(FileTransferProtocol.buildInit(id: transferID, name: url.lastPathComponent,
                    size: Int64(size), mime: mime, chunkSize: chunkSize, checksum: checksum, isClipboard: isClipboard,
                    bulkPort: bulk?.port, bulkKey: bulk?.keyBase64)) else { return }
                var streamed = false
                if let bulk, bulk.acceptPeer(transferID: transferID, timeout: 6, isActive: isActive) {
                    // Fast path: one encrypted TCP stream, 1 MB records, no per-chunk acks.
                    let sealer = BulkTransferProtocol.Sealer(key: bulk.key, direction: BulkTransferProtocol.macToPhone)
                    try handle.seek(toOffset: 0)
                    var offset = 0
                    var lastProgress = ProcessInfo.processInfo.systemUptime - 1
                    while offset < size {
                        guard isActive() else { return }
                        let data = try handle.read(upToCount: BulkTransferProtocol.maxPayload) ?? Data()
                        guard !data.isEmpty, data.count <= size - offset else {
                            failure = "The file changed while sending. Try again."; return
                        }
                        hasher.update(data: data)
                        do { try bulk.writeRecord(sealer, type: BulkTransferProtocol.typeData, payload: data) }
                        catch { failure = "The connection to your phone dropped. Try again."; return }
                        offset += data.count
                        noteFileIO()
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastProgress >= 0.2 {
                            lastProgress = now
                            let fraction = size == 0 ? 0.99 : min(0.99, Double(offset) / Double(size))
                            DispatchQueue.main.async { progress?(fraction) }
                        }
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    let end = (try? JSONSerialization.data(withJSONObject: ["sha256": digest, "size": size])) ?? Data()
                    do { try bulk.writeRecord(sealer, type: BulkTransferProtocol.typeEnd, payload: end) }
                    catch { failure = "The connection to your phone dropped. Try again."; return }
                    streamed = true
                }
                if !streamed {
                let totalChunks = max(1, (size + chunkSize - 1) / chunkSize)
                var pending: [Int: (payload: String, attempts: Int, sent: Date)] = [:]
                var next = 0
                var base = 0
                var lastProgress = ProcessInfo.processInfo.systemUptime - 1
                while base < totalChunks {
                    guard isActive() else { return }
                    self.lock.lock()
                    let acked = self.outgoingAcks[transferID] ?? []
                    let rejection = self.outgoingVerification[transferID]
                    self.lock.unlock()
                    if let rejection, !rejection.verified { failure = rejection.error ?? "Your phone couldn't save the file."; return }
                    while acked.contains(base) { pending.removeValue(forKey: base); base += 1 }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastProgress >= 0.2 || base == totalChunks {
                        lastProgress = now
                        let fraction = size == 0 ? 0.99 : min(0.99, Double(min(base * chunkSize, size)) / Double(size))
                        DispatchQueue.main.async { progress?(fraction) }
                    }
                    if base == totalChunks { break }
                    while next < totalChunks && next - base < 8 {
                        try handle.seek(toOffset: UInt64(next * chunkSize))
                        let data = try handle.read(upToCount: chunkSize) ?? Data()
                        guard data.count == min(chunkSize, size - next * chunkSize) else {
                            failure = "The file changed while sending. Try again."; return
                        }
                        hasher.update(data: data)
                        noteFileIO()
                        let encoded = data.base64EncodedString()
                        guard send(FileTransferProtocol.buildChunk(id: transferID, index: next, base64Chunk: encoded)) else { return }
                        pending[next] = (encoded, 1, Date())
                        next += 1
                    }
                    for (index, entry) in pending where !acked.contains(index) {
                        if Date().timeIntervalSince(entry.sent) * 1000 >= Double(self.ackWaitMs) {
                            guard entry.attempts < self.maxChunkRetries else {
                                failure = "Your phone stopped responding. Check Wi-Fi and try again."
                                _ = send(FileTransferProtocol.buildCancel(id: transferID))
                                return
                            }
                            guard send(FileTransferProtocol.buildChunk(id: transferID, index: index, base64Chunk: entry.payload)) else { return }
                            pending[index] = (entry.payload, entry.attempts + 1, Date())
                        }
                    }
                    self.transferWakeup.lock()
                    self.lock.lock()
                    let unchanged = self.outgoingAcks[transferID] == acked && self.outgoingVerification[transferID]?.verified != false
                    self.lock.unlock()
                    if unchanged {
                        let deadline = pending.filter { !acked.contains($0.key) }.values.map {
                            $0.sent.addingTimeInterval(Double(self.ackWaitMs) / 1000)
                        }.min() ?? Date().addingTimeInterval(2)
                        _ = self.transferWakeup.wait(until: deadline)
                    }
                    self.transferWakeup.unlock()
                }
                let finalChecksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard send(FileTransferProtocol.buildComplete(id: transferID, name: url.lastPathComponent, size: Int64(size), checksum: finalChecksum)) else { return }
                }
                // Final verification streams the temporary file and publishes a
                // second copy to Downloads. Give large files a bounded storage
                // budget without polling or keeping cancelled transfers alive.
                let saveBudget = max(120, min(15 * 60, Double(size) / (16 * 1024 * 1024) + 60))
                self.lock.lock()
                if self.shouldRun && self.lifecycleGeneration == generation &&
                    self.primarySessionID == ObjectIdentifier(session) && self.outgoingAcks[transferID] != nil {
                    MacPowerManager.shared.setTransferActive(id: powerID, active: true, timeout: saveBudget)
                }
                self.lock.unlock()
                let deadline = Date().addingTimeInterval(saveBudget)
                while isActive() && Date() < deadline {
                    self.transferWakeup.lock()
                    self.lock.lock()
                    let active = self.shouldRun && self.lifecycleGeneration == generation &&
                        self.primarySessionID == ObjectIdentifier(session) && self.outgoingAcks[transferID] != nil
                    let verified = self.outgoingVerification[transferID]
                    self.lock.unlock()
                    guard active else { self.transferWakeup.unlock(); return }
                    if let verified {
                        self.transferWakeup.unlock()
                        succeeded = verified.verified
                        failure = verified.error ?? "Your phone couldn't save the file."
                        if succeeded { DispatchQueue.main.async { progress?(1) } }
                        return
                    }
                    _ = self.transferWakeup.wait(until: deadline)
                    self.transferWakeup.unlock()
                }
                failure = "Your phone didn't confirm saving the file. Check Downloads before retrying."
            } catch {
                failure = error.localizedDescription
                _ = send(FileTransferProtocol.buildCancel(id: transferID))
            }
        }
        return transferID
    }
}
