//
//  WebSocketServer+Handlers.swift
//  airsync-mac
//

import Foundation
import Swifter
import CryptoKit
import UserNotifications
import CoreGraphics

extension WebSocketServer {
    
    /// Central router for incoming WebSocket messages.
    /// Decodes message type and dispatches to specific specialized handlers.
    func handleMessage(_ message: Message, session: WebSocketSession) {
        let sessionId = ObjectIdentifier(session)
        lock.lock()
        let primaryID = primarySessionID
        lock.unlock()
        
        if message.type != .device && sessionId != primaryID {
            print("[websocket] Ignoring message of type \(message.type) from non-primary session")
            return
        }

        switch message.type {
        case .device:
            handleDeviceHandshake(message, session: session)
        case .notification:
            handleNotification(message)
        case .callEvent:
            handleCallEvent(message)
        case .callProgress:
            handleCallProgress(message)
        case .notificationActionResponse:
            handleNotificationActionResponse(message)
        case .notificationAction:
            print("[websocket] Warning: received 'notificationAction' from remote (ignored).")
        case .notificationUpdate:
            handleNotificationUpdate(message)
        case .status:
            handleStatusUpdate(message)
        case .dismissalResponse:
            handleDismissalResponse(message)
        case .mediaControlResponse:
            handleMediaControlResponse(message)
        case .appIcons:
            handleAppIcons(message)
        case .clipboardUpdate:
            handleClipboardUpdate(message)
        case .clipboardAck:
            if let data = message.data.value as? [String: Any] {
                AppState.shared.acknowledgeClipboard(id: data["id"] as? String ?? "", ok: data["ok"] as? Bool ?? false)
            }
        case .fileTransferInit:
            handleFileTransferInit(message)
        case .fileChunk:
            handleFileChunk(message, session: session)
        case .fileChunkAck:
            handleFileChunkAck(message)
        case .fileTransferComplete:
            handleFileTransferComplete(message)
        case .transferVerified:
            handleTransferVerified(message)
        case .fileTransferCancel:
            handleFileTransferCancel(message)
        case .macMediaControl:
            handleMacMediaControlRequest(message)
        case .macPowerControl:
            if let data = message.data.value as? [String: Any] { handleMacPowerControl(data) }
        case .callControlResponse:
            handleCallControlResponse(message)
        case .remoteControl:
            handleRemoteControl(message)
        case .browseData:
            handleBrowseData(message)
        case .transferNetwork:
            if let data = message.data.value as? [String: Any],
               let bytes = try? JSONSerialization.data(withJSONObject: ["type": "transferNetwork", "data": data]),
               let envelope = String(data: bytes, encoding: .utf8) {
                TransferNetworkCoordinator.shared.handleEnvelope(envelope, fromNetwork: true)
            }
        case .phoneHotspotState:
            if let data = message.data.value as? [String: Any] { PhoneHotspotManager.shared.handleState(data) }
        case .webDavAccess:
            guard !AppState.shared.isSyncPaused,
                  let device = AppState.shared.device, device.isRegularConnection,
                  AppState.shared.isPlus, AppState.shared.isFileAccessEnabled,
                  let data = message.data.value as? [String: Any] else { return }
            if data["enabled"] as? Bool == true,
               let token = data["token"] as? String,
               let port = data["port"] as? Int, (1...65535).contains(port) {
                WebDAVManager.shared.mount(ipAddress: device.ipAddress, port: port, volumeName: device.name)
                WebDAVManager.shared.setAccess(token: token, port: port)
            } else {
                WebDAVManager.shared.setAccess(token: nil)
            }
        case .userDisconnected:
            handleUserDisconnected()
        case .volumeControl, .macVolume, .toggleAppNotif, .browseLs, .wakeUpRequest, .macMediaControlResponse, .macPowerControlResponse, .macInfo, .callControl:
            // Outgoing or unexpected messages
            break
        }
    }

    /// Authenticated BLE uses only small control/state messages. File/session
    /// negotiation never enters the WebSocket router without its socket identity.
    func handleBLEMessage(_ message: Message) {
        guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated else { return }
        switch message.type {
        case .phoneHotspotState:
            if let data = message.data.value as? [String: Any] { PhoneHotspotManager.shared.handleState(data) }
        case .status:
            if let data = message.data.value as? [String: Any],
               let battery = data["battery"] as? [String: Any],
               let level = battery["level"] as? Int, (0...100).contains(level),
               let charging = battery["isCharging"] as? Bool {
                if data["music"] == nil {
                    if AppState.shared.status == nil {
                        AppState.shared.status = DeviceStatus(battery: .init(level: level, isCharging: charging), isPaired: true, music: nil)
                    } else { AppState.shared.status?.battery = .init(level: level, isCharging: charging) }
                } else { handleStatusUpdate(message) }
            }
        case .remoteControl:
            // The phone coalesces pointer motion over Bluetooth, so the trackpad
            // works on every authenticated transport, not only Wi-Fi.
            handleRemoteControl(message)
        case .macMediaControl: handleMacMediaControlRequest(message)
        case .notificationActionResponse: handleNotificationActionResponse(message)
        case .dismissalResponse: handleDismissalResponse(message)
        case .mediaControlResponse: handleMediaControlResponse(message)
        case .callControlResponse: handleCallControlResponse(message)
        case .callEvent: handleCallEvent(message)
        case .callProgress: handleCallProgress(message)
        default: break
        }
    }

    // MARK: - Private Handlers

    /// Called only by the primary WebSocket session or authenticated BLE peer.
    func handleMacPowerControl(_ data: [String: Any]) {
        guard !AppState.shared.isSyncPaused, let action = data["action"] as? String, action.count <= 64,
              let requestID = data["requestId"] as? String, !requestID.isEmpty, requestID.count <= 128 else { return }
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused else { return }
            var accepted = false
            var error: String?
            switch action {
            case "setKeepAwake":
                if let enabled = data["enabled"] as? Bool {
                    MacPowerManager.shared.setKeepAwake(enabled: enabled)
                    accepted = true
                } else { error = "Choose whether to enable Keep Awake." }
            case "sleep":
                accepted = MacPowerManager.shared.requestSleep()
                if !accepted { error = "Sleep is available only when the Mac lid is confirmed closed and macOS allows the request." }
            default:
                error = "Unsupported Mac power command."
            }
            var response: [String: Any] = ["requestId": requestID, "action": action, "accepted": accepted]
            if let error = error { response["error"] = error }
            self.sendPowerProtocol(type: "macPowerControlResponse", data: response)
        }
    }

    /// Processes initial device handshake.
    /// Handles device registration, wallpaper syncing, and IP conflict resolution for local network priority.
    private func handleDeviceHandshake(_ message: Message, session: WebSocketSession) {
        let sessionId = ObjectIdentifier(session)
        var previousSession: WebSocketSession?
        self.lock.lock()
        
        let incomingTargetIp = (message.data.value as? [String: Any])?["targetIpAddress"] as? String ?? ""
        let isIncomingLocal = ipIsPrivatePreferred(incomingTargetIp)
        
        if let oldPrimary = primarySessionID, oldPrimary != sessionId {
            if isIncomingLocal {
                print("[websocket] New local session taking over as primary. Closing old session.")
                previousSession = activeSessions.first(where: { ObjectIdentifier($0) == oldPrimary })
                self.primarySessionID = sessionId
            } else {
                print("[websocket] Ignoring non-local session takeover attempt (\(incomingTargetIp)) to maintain stability.")
                self.lock.unlock()
                return
            }
        } else {
            self.primarySessionID = sessionId
        }
        self.lock.unlock()
        previousSession?.socket.close()
        
        if let dict = message.data.value as? [String: Any],
           let name = dict["name"] as? String,
           let ip = dict["ipAddress"] as? String,
           let port = dict["port"] as? Int {

            if let targetIp = dict["targetIpAddress"] as? String {
                AppState.shared.activeMacIp = targetIp.trimmingCharacters(in: .whitespaces)
            }

            let version = dict["version"] as? String ?? "2.0.0"
            let adbPorts = dict["adbPorts"] as? [String] ?? []
            let deviceId = dict["id"] as? String ?? ""

            lock.lock()
            if primarySessionID == sessionId { authenticatedPrimarySessionID = sessionId }
            lock.unlock()

            // File-browsing credentials belong only to this authenticated session,
            // including when the same phone reconnects on a replacement socket.
            WebDAVManager.shared.unmount()
            AppState.shared.device = Device(
                name: name,
                ipAddress: ip,
                port: port,
                version: version,
                adbPorts: adbPorts,
                deviceId: deviceId
            )

            if let base64 = dict["wallpaper"] as? String {
                AppState.shared.currentDeviceWallpaperBase64 = base64
                UserDefaults.standard.set(base64, forKey: "lastCachedWallpaperBase64")
                
                // Save wallpaper to disk for DeviceCard
                if let id = dict["id"] as? String,
                   let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    DispatchQueue.global(qos: .background).async {
                        do {
                            let fileManager = FileManager.default
                            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                                let wallpaperDir = appSupport.appendingPathComponent("Wallpapers")
                                if !fileManager.fileExists(atPath: wallpaperDir.path) {
                                    try fileManager.createDirectory(at: wallpaperDir, withIntermediateDirectories: true)
                                }
                                let fileURL = wallpaperDir.appendingPathComponent("\(id).jpg")
                                let fallbackURL = wallpaperDir.appendingPathComponent("last_wallpaper.jpg")
                                try data.write(to: fileURL)
                                try? data.write(to: fallbackURL)
                                print("[websocket] Saved wallpaper for device \(id)")
                            }
                        } catch {
                            print("[websocket] Failed to save wallpaper: \(error)")
                        }
                    }
                }
            }

            if (!AppState.shared.adbConnected && (AppState.shared.adbEnabled || AppState.shared.manualAdbConnectionPending || AppState.shared.wiredAdbEnabled) &&
                (AppState.shared.isPlus || AppState.shared.manualAdbConnectionPending)) {
                let killServer = AppState.shared.userInitiatedAdbConnect || AppState.shared.alwaysKillAdbBeforeConnect
                
                if AppState.shared.wiredAdbEnabled {
                    ADBConnector.getWiredDevices { wiredDevices in
                        let mappedSerial = AppState.shared.selectedWiredSerial ?? AppState.shared.deviceAdbSerials[deviceId]
                        
                        if !wiredDevices.isEmpty {
                            if let mappedSerial = mappedSerial {
                                if let matchedDevice = wiredDevices.first(where: { $0.serial == mappedSerial }) {
                                    DispatchQueue.main.async {
                                        AppState.shared.selectedWiredSerial = matchedDevice.serial
                                        AppState.shared.adbConnected = true
                                        AppState.shared.adbConnectionMode = .wired
                                        AppState.shared.adbConnectionResult = "Connected via Wired ADB (Serial: \(matchedDevice.serial))"
                                        AppState.shared.manualAdbConnectionPending = false
                                        AppState.shared.userInitiatedAdbConnect = false
                                    }
                                } else {
                                    if AppState.shared.adbEnabled || AppState.shared.manualAdbConnectionPending {
                                        ADBConnector.connectToADB(ip: ip, killServer: killServer)
                                    }
                                    DispatchQueue.main.async {
                                        AppState.shared.manualAdbConnectionPending = false
                                        AppState.shared.userInitiatedAdbConnect = false
                                    }
                                }
                            } else {
                                if wiredDevices.count == 1, let singleDevice = wiredDevices.first {
                                    DispatchQueue.main.async {
                                        AppState.shared.deviceAdbSerials[deviceId] = singleDevice.serial
                                        AppState.shared.selectedWiredSerial = singleDevice.serial
                                        AppState.shared.adbConnected = true
                                        AppState.shared.adbConnectionMode = .wired
                                        AppState.shared.adbConnectionResult = "Connected via Wired ADB (Serial: \(singleDevice.serial))"
                                        AppState.shared.manualAdbConnectionPending = false
                                        AppState.shared.userInitiatedAdbConnect = false
                                    }
                                } else {
                                    if AppState.shared.adbEnabled || AppState.shared.manualAdbConnectionPending {
                                        ADBConnector.connectToADB(ip: ip, killServer: killServer)
                                    }
                                    DispatchQueue.main.async {
                                        AppState.shared.manualAdbConnectionPending = false
                                        AppState.shared.userInitiatedAdbConnect = false
                                    }
                                }
                            }
                        } else {
                            if AppState.shared.adbEnabled || AppState.shared.manualAdbConnectionPending {
                                ADBConnector.connectToADB(ip: ip, killServer: killServer)
                            }
                            DispatchQueue.main.async {
                                AppState.shared.manualAdbConnectionPending = false
                                AppState.shared.userInitiatedAdbConnect = false
                            }
                        }
                    }
                } else if AppState.shared.adbEnabled || AppState.shared.manualAdbConnectionPending {
                    // Try wireless connection directly
                    ADBConnector.connectToADB(ip: ip, killServer: killServer)
                    AppState.shared.manualAdbConnectionPending = false
                    AppState.shared.userInitiatedAdbConnect = false
                }
            }

            if let bleToken = dict["bleAuthToken"] as? String, !bleToken.isEmpty {
                let oldToken = UserDefaults.standard.string(forKey: "bleAuthToken")
                UserDefaults.standard.set(bleToken, forKey: "bleAuthToken")
                if !deviceId.isEmpty {
                    UserDefaults.standard.set(deviceId, forKey: "lastBLEPairedDeviceID")
                } else {
                    UserDefaults.standard.removeObject(forKey: "lastBLEPairedDeviceID")
                }
                // An authenticated network pairing changing the credential
                // invalidates the old Bluetooth session before any new commands.
                if oldToken != bleToken && AppState.shared.isBLEEnabled {
                    BLECentralManager.shared.disconnect(restartScanning: true)
                } else {
                    BLECentralManager.shared.ensureAutomaticConnection()
                }
            }

            if UserDefaults.standard.hasPairedDeviceOnce == false {
                UserDefaults.standard.hasPairedDeviceOnce = true
            }
            
            sendMacInfoResponse()
        }
    }

    private func handleNotification(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let nid = dict["id"] as? String,
           let title = dict["title"] as? String,
           let body = dict["body"] as? String,
           let app = dict["app"] as? String,
           let package = dict["package"] as? String {
            let priority = dict["priority"] as? String
            var actions: [NotificationAction] = []
            if let arr = dict["actions"] as? [[String: Any]] {
                for a in arr {
                    if let name = a["name"] as? String, let typeStr = a["type"] as? String,
                       let t = NotificationAction.ActionType(rawValue: typeStr) {
                        actions.append(NotificationAction(name: name, type: t))
                    }
                }
            }
            let progress = dict["progress"] as? Int
            let progressMax = dict["progressMax"] as? Int
            let progressIndeterminate = dict["progressIndeterminate"] as? Bool
            let ongoing = dict["ongoing"] as? Bool
            
            let notif = Notification(
                title: title,
                body: body,
                app: app,
                nid: nid,
                package: package,
                priority: priority,
                actions: actions,
                progress: progress,
                progressMax: progressMax,
                progressIndeterminate: progressIndeterminate,
                ongoing: ongoing
            )
            DispatchQueue.main.async {
                AppState.shared.addNotification(notif)
            }
        }
    }

    private func handleCallEvent(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let eventId = dict["eventId"] as? String,
           let number = dict["number"] as? String,
           let normalizedNumber = dict["normalizedNumber"] as? String,
           let directionStr = dict["direction"] as? String,
           let direction = CallDirection(rawValue: directionStr),
           let stateStr = dict["state"] as? String,
           let state = CallState(rawValue: stateStr) {
            
            let contactName = (dict["contactName"] as? String) ?? normalizedNumber
            
            var timestamp: Int64 = 0
            if let ts = dict["timestamp"] as? Int64 {
                timestamp = ts
            } else if let ts = dict["timestamp"] as? Int {
                timestamp = Int64(ts)
            } else if let ts = dict["timestamp"] as? NSNumber {
                timestamp = ts.int64Value
            }
            
            let deviceId = dict["deviceId"] as? String ?? ""
            let contactPhoto = dict["contactPhoto"] as? String
            
            let callEvent = CallEvent(
                eventId: eventId,
                contactName: contactName,
                number: number,
                normalizedNumber: normalizedNumber,
                direction: direction,
                state: state,
                timestamp: timestamp,
                deviceId: deviceId,
                contactPhoto: contactPhoto
            )
            DispatchQueue.main.async {
                AppState.shared.updateCallEvent(callEvent)
            }
        }
    }

    private func handleCallProgress(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let eventId = dict["eventId"] as? String {
            DispatchQueue.main.async {
                AppState.shared.receivedCallProgress(eventId: eventId)
            }
        }
    }

    private func handleStatusUpdate(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let battery = dict["battery"] as? [String: Any],
           let level = battery["level"] as? Int,
           let isCharging = battery["isCharging"] as? Bool,
           let paired = dict["isPaired"] as? Bool,
           let music = dict["music"] as? [String: Any],
           let playing = music["isPlaying"] as? Bool,
           let title = music["title"] as? String,
           let artist = music["artist"] as? String,
           let volume = music["volume"] as? Int,
           let isMuted = music["isMuted"] as? Bool
        {
            let albumArt = (music["albumArt"] as? String) ?? ""
            let likeStatus = (music["likeStatus"] as? String) ?? "none"
            let isBuffering = (music["isBuffering"] as? Bool) ?? false

            // Android sends duration/position in ms; convert to seconds.
            // Using NSNumber because Swift's `as? Double` fails if the JSON parser inferred an Int.
            let durationSec = (music["duration"] as? NSNumber).map { $0.doubleValue / 1000.0 } ?? -1.0
            var positionSec = (music["position"] as? NSNumber).map { $0.doubleValue / 1000.0 } ?? -1.0

            // Timestamp-based position correction:
            // Android includes the wall-clock ms when the position snapshot was taken.
            // We add the elapsed time since then (which includes WiFi transit) to get a
            // much more accurate "current" position — effectively NTP-style compensation.
            // Clamp: only correct for realistic WiFi delays (< 5s). Larger deltas likely
            // indicate clock skew between devices, which would worsen accuracy if applied.
            if positionSec >= 0, playing, !isBuffering,
               let tsMs = music["positionTimestamp"] as? NSNumber {
                let capturedAt = tsMs.doubleValue / 1000.0
                let nowSec = Date().timeIntervalSince1970
                let networkDelta = nowSec - capturedAt
                if networkDelta > -2.0 && networkDelta < 5.0 {
                    positionSec += max(0.0, networkDelta)
                }
            }
            // Clamp to duration to prevent the seekbar going past the end
            if durationSec > 0 && positionSec > durationSec {
                positionSec = durationSec
            }

            let oldTitle = AppState.shared.status?.music?.title

            AppState.shared.status = DeviceStatus(
                battery: .init(level: level, isCharging: isCharging),
                isPaired: paired,
                music: .init(
                    isPlaying: playing,
                    title: title,
                    artist: artist,
                    volume: volume,
                    isMuted: isMuted,
                    albumArt: albumArt,
                    likeStatus: likeStatus,
                    duration: durationSec,
                    position: positionSec,
                    isBuffering: isBuffering
                )
            )

            DispatchQueue.main.async {
                if oldTitle != title {
                    AppState.shared.handleTrackChange()
                } else {
                    AppState.shared.syncMediaPosition(incoming: positionSec)
                }
            }

            // Only publish to macOS Control Center / boringNotch when the user opts in,
            // because it requires a silent background audio track which can cause multipoint
            // Bluetooth headphones to route audio focus to the Mac.
            if UserDefaults.standard.showInControlCenter {
                var npInfo = NowPlayingInfo()
                npInfo.title = title
                npInfo.artist = artist
                npInfo.isPlaying = playing
                if let data = Data(base64Encoded: albumArt) {
                    npInfo.artworkData = data
                }
                // Seekbar: Android sends duration/position in ms; MPNowPlayingInfoCenter needs seconds.
                // positionMs uses optDouble so missing/null safely falls back to -1.
                // NOTE: Use NSNumber because Swift's JSON parser returns an Int type for flat numbers.
                if let nsNum = music["duration"] as? NSNumber, nsNum.doubleValue > 0 {
                    npInfo.duration = nsNum.doubleValue / 1000.0
                }
                if let pMs = music["position"] as? NSNumber, pMs.doubleValue >= 0 {
                    npInfo.elapsedTime = pMs.doubleValue / 1000.0
                }
                NowPlayingPublisher.shared.update(info: npInfo)
            } else {
                // If the setting is off, ensure any previously running session is cleared
                NowPlayingPublisher.shared.clear()
            }
        }
    }

    private func handleAppIcons(_ message: Message) {
        if let dict = message.data.value as? [String: [String: Any]] {
            DispatchQueue.global(qos: .background).async {
                let incomingPackages = Set(dict.keys)
                let existingPackages = Set(AppState.shared.androidApps.keys)

                for (package, details) in dict {
                    guard let name = details["name"] as? String,
                          let iconBase64 = details["icon"] as? String,
                          let systemApp = details["systemApp"] as? Bool,
                          let listening = details["listening"] as? Bool else { continue }

                    var cleaned = iconBase64
                    if let range = cleaned.range(of: "base64,") { cleaned = String(cleaned[range.upperBound...]) }

                    var iconPath: String? = nil
                    if let data = Data(base64Encoded: cleaned), !cleaned.isEmpty {
                        let fileURL = appIconsDirectory().appendingPathComponent("\(package).png")
                        do {
                            try data.write(to: fileURL, options: .atomic)
                            iconPath = fileURL.path
                        } catch {
                            print("[websocket] Failed to write icon for \(package): \(error)")
                        }
                    }

                    DispatchQueue.main.async {
                        if var existingApp = AppState.shared.androidApps[package] {
                            existingApp.listening = listening
                            if let newIconPath = iconPath {
                                existingApp.iconUrl = newIconPath
                            }
                            AppState.shared.androidApps[package] = existingApp
                        } else {
                            let app = AndroidApp(
                                packageName: package,
                                name: name,
                                iconUrl: iconPath,
                                listening: listening,
                                systemApp: systemApp
                            )
                            AppState.shared.androidApps[package] = app
                        }
                    }
                }

                let toRemove = existingPackages.subtracting(incomingPackages)
                if !toRemove.isEmpty {
                    DispatchQueue.main.async {
                        var pathsToRemove: [String] = []
                        for pkg in toRemove {
                            if let iconPath = AppState.shared.androidApps[pkg]?.iconUrl {
                                pathsToRemove.append(iconPath)
                            }
                            AppState.shared.androidApps.removeValue(forKey: pkg)
                        }
                        DispatchQueue.global(qos: .background).async {
                            for path in pathsToRemove {
                                try? FileManager.default.removeItem(atPath: path)
                            }
                        }
                    }
                }

                DispatchQueue.main.async {
                    AppState.shared.saveAppsToDisk()
                }
            }
        }
    }

    private func handleFileTransferInit(_ message: Message) {
        guard let dict = message.data.value as? [String: Any],
              let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let size = dict["size"] as? Int,
              let mime = dict["mime"] as? String else { return }
        let chunkSize = dict["chunkSize"] as? Int ?? 64 * 1024
        guard size >= 0, chunkSize > 0, chunkSize <= 1024 * 1024,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return }
        let checksum = dict["checksum"] as? String
        lock.lock()
        let generation = lifecycleGeneration
        lock.unlock()
        fileQueue.async {
            guard self.isCurrentLifecycle(generation) else { return }
            self.lock.lock()
            let existing = self.incomingFiles[id]
            self.lock.unlock()
            guard existing == nil else { return }
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: tempFile.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: tempFile) else { return }
            let io = IncomingFileIO(id: id, name: name, size: size, mime: mime,
                                    tempUrl: tempFile, fileHandle: handle, chunkSize: chunkSize,
                                    lastPowerActivity: ProcessInfo.processInfo.systemUptime)
            self.lock.lock()
            guard self.shouldRun && self.lifecycleGeneration == generation else {
                self.lock.unlock()
                try? handle.close()
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            self.incomingFiles[id] = io
            self.incomingFilesChecksum[id] = checksum
            MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(id)", active: true)
            self.lock.unlock()
        }
    }

    private func handleFileChunk(_ message: Message, session: WebSocketSession) {
        guard let dict = message.data.value as? [String: Any],
              let id = dict["id"] as? String,
              let index = dict["index"] as? Int,
              let chunkBase64 = dict["chunk"] as? String else { return }
        fileQueue.async {
            self.lock.lock()
            let state = self.incomingFiles[id]
            self.lock.unlock()
            guard var io = state, index >= 0, index <= max(0, (io.size - 1) / io.chunkSize),
                  let data = Data(base64Encoded: chunkBase64),
                  data.count == min(io.chunkSize, io.size - index * io.chunkSize),
                  let handle = io.fileHandle else { return }
            if !io.receivedChunks.contains(index) {
                do {
                    try handle.seek(toOffset: UInt64(index * io.chunkSize))
                    try handle.write(contentsOf: data)
                    io.receivedChunks.insert(index)
                    io.bytesReceived += data.count
                    let now = ProcessInfo.processInfo.systemUptime
                    let renewPower = now - io.lastPowerActivity >= 10
                    if renewPower { io.lastPowerActivity = now }
                    self.lock.lock()
                    guard self.incomingFiles[id] != nil else { self.lock.unlock(); return }
                    self.incomingFiles[id] = io
                    if renewPower { MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(id)", active: true) }
                    self.lock.unlock()
                } catch {
                    self.cancelFileTransfer(id: id)
                    return
                }
            }
            // Acknowledge only after the write succeeds; duplicates don't inflate byte counts.
            self.sendToFirstAvailable(message: FileTransferProtocol.buildChunkAck(id: id, index: index))
        }
    }

    private func handleFileTransferComplete(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String {
            
            fileQueue.async {
                self.lock.lock()
                let state = self.incomingFiles[id]
                if state != nil { MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(id)", active: true) }
                self.lock.unlock()
                if let state = state {
                    let powerID = "ws-incoming:\(id)"
                    defer { MacPowerManager.shared.setTransferActive(id: powerID, active: false) }
                    do {
                        try state.fileHandle?.close()
                    } catch {
                        self.cancelFileTransfer(id: id)
                        return
                    }
                    
                    var totalBytes: UInt64 = 0
                    do {
                        let attr = try FileManager.default.attributesOfItem(atPath: state.tempUrl.path)
                        totalBytes = attr[.size] as? UInt64 ?? 0
                    } catch {
                        print("[websocket] (file-transfer) Failed to get size for validation: \(error)")
                    }
                    
                    let expectedSize = state.size
                    let resolvedName = state.name
                    
                    if Int(totalBytes) != expectedSize || state.bytesReceived != expectedSize {
                        print("[websocket] (file-transfer) Size mismatch for \(resolvedName): \(totalBytes)/\(expectedSize)")
                        try? FileManager.default.removeItem(at: state.tempUrl)
                        self.lock.lock()
                        self.incomingFiles.removeValue(forKey: id)
                        self.incomingFilesChecksum.removeValue(forKey: id)
                        self.lock.unlock()
                        return 
                    }
                    
                    self.lock.lock()
                    let expectedChecksum = self.incomingFilesChecksum[id]
                    self.lock.unlock()

                    if let expected = expectedChecksum {
                        var verified = false
                        if let handle = try? FileHandle(forReadingFrom: state.tempUrl) {
                            defer { try? handle.close() }
                            var hasher = SHA256()
                            var lastPowerNote = ProcessInfo.processInfo.systemUptime
                            while true {
                                self.lock.lock()
                                let active = self.incomingFiles[id] != nil
                                self.lock.unlock()
                                guard active else { return }
                                let data: Data
                                do {
                                    data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                                } catch {
                                    self.cancelFileTransfer(id: id)
                                    return
                                }
                                if data.isEmpty { break }
                                hasher.update(data: data)
                                let now = ProcessInfo.processInfo.systemUptime
                                if now - lastPowerNote >= 10 {
                                    lastPowerNote = now
                                    self.lock.lock()
                                    if self.incomingFiles[id] != nil { MacPowerManager.shared.setTransferActive(id: powerID, active: true) }
                                    self.lock.unlock()
                                }
                            }
                            let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                            verified = computed == expected
                        }
                        guard verified else {
                            self.cancelFileTransfer(id: id)
                            return
                        }
                    }

                    self.lock.lock()
                    let active = self.incomingFiles[id] != nil
                    self.lock.unlock()
                    guard active else { return }
                    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                        do {
                            var finalName = resolvedName
                            var finalDest = downloads.appendingPathComponent(finalName)
                            var counter = 1
                            
                            let nsString = resolvedName as NSString
                            let baseName = nsString.deletingPathExtension
                            let extensionStr = nsString.pathExtension
                            let hasExtension = !extensionStr.isEmpty
                            
                            while FileManager.default.fileExists(atPath: finalDest.path) {
                                if hasExtension {
                                    finalName = "\(baseName)(\(counter)).\(extensionStr)"
                                } else {
                                    finalName = "\(baseName)(\(counter))"
                                }
                                finalDest = downloads.appendingPathComponent(finalName)
                                counter += 1
                            }
                            
                            try FileManager.default.moveItem(at: state.tempUrl, to: finalDest)

                            DispatchQueue.main.async { QuickShareManager.notifyReceived([finalDest]) }
                        } catch {
                            print("[websocket] (file-transfer) Failed to move incoming file: \(error)")
                        }
                    }
                    
                    self.lock.lock()
                    self.incomingFiles.removeValue(forKey: id)
                    self.incomingFilesChecksum.removeValue(forKey: id)
                    self.lock.unlock()
                }
            }
        }
    }

    private func handleBrowseData(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let path = dict["path"] as? String,
           let itemsArray = dict["items"] as? [[String: Any]] {
            
            var items: [FileBrowserItem] = []
            for itemDict in itemsArray {
                let name = itemDict["name"] as? String ?? ""
                let isDir = itemDict["isDir"] as? Bool ?? false
                let size = (itemDict["size"] as? Int64) ?? Int64(itemDict["size"] as? Int ?? 0)
                let timeValue = (itemDict["time"] as? Int64) ?? Int64(itemDict["time"] as? Int ?? 0)
                
                if !name.isEmpty {
                    items.append(FileBrowserItem(name: name, isDir: isDir, size: size, time: timeValue))
                }
            }
            
            DispatchQueue.main.async {
                AppState.shared.browsePath = path
                AppState.shared.browseItems = items
                AppState.shared.browseError = nil
                AppState.shared.isBrowsingLoading = false
            }
        } else if let error = (message.data.value as? [String: Any])?["error"] as? String {
            DispatchQueue.main.async {
                AppState.shared.browseError = error
                AppState.shared.isBrowsingLoading = false
            }
        }
    }

    private func handleRemoteControl(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let action = dict["action"] as? String {
            guard !AppState.shared.isSyncPaused else { return }
            switch action {
            case "keypress":
                guard let code = dict["keycode"] as? Int, (0...65535).contains(code) else { return }
            case "type":
                guard let text = dict["text"] as? String, text.utf8.count <= 64 * 1024 else { return }
            case "vol_set":
                guard let level = MacRemoteInputPolicy.number(dict["value"]), (0...100).contains(level) else { return }
            case "mouse_move", "mouse_scroll":
                // Android's JSON writes integral doubles as integers (3.0 -> 3), so
                // accept any JSON number; rejecting Int dropped most pointer frames.
                guard let dx = MacRemoteInputPolicy.number(dict["dx"]),
                      let dy = MacRemoteInputPolicy.number(dict["dy"]),
                      dx.isFinite, dy.isFinite else { return }
            case "mouse_click":
                guard dict["button"] is String, dict["isDown"] is Bool else { return }
            case "arrow_up", "arrow_down", "arrow_left", "arrow_right", "enter", "space", "escape",
                 "vol_up", "vol_down", "vol_mute", "media_play_pause", "media_next", "media_prev",
                 "lock_screen", "screensaver", "brightness_up", "brightness_down": break
            default: return
            }
            DispatchQueue.main.async { MacPowerManager.shared.noteRemoteActivity() }
            if MacRemoteInputPolicy.needsAccessibility(action) {
                MacRemoteManager.shared.ensureInputAllowed()
            }
            #if DEBUG
            print("[WebSocketServer] Received remote action: \(action)")
            #endif
            
            switch action {
            case "keypress":
                if let code = dict["keycode"] as? Int {
                    let modifiers = dict["modifiers"] as? [String] ?? []
                    MacRemoteManager.shared.simulateKeyCode(code, modifiers: modifiers)
                }
            case "type":
                if let text = dict["text"] as? String {
                    let modifiers = dict["modifiers"] as? [String] ?? []
                    MacRemoteManager.shared.simulateText(text, modifiers: modifiers)
                }
            case "arrow_up": MacRemoteManager.shared.simulateKey(.upArrow)
            case "arrow_down": MacRemoteManager.shared.simulateKey(.downArrow)
            case "arrow_left": MacRemoteManager.shared.simulateKey(.leftArrow)
            case "arrow_right": MacRemoteManager.shared.simulateKey(.rightArrow)
            case "enter": MacRemoteManager.shared.simulateKey(.enter)
            case "space": MacRemoteManager.shared.simulateKey(.space)
            case "escape": MacRemoteManager.shared.simulateKey(.escape)
            case "vol_up": MacRemoteManager.shared.increaseVolume()
            case "vol_down": MacRemoteManager.shared.decreaseVolume()
            case "vol_mute": MacRemoteManager.shared.toggleMute()
            case "vol_set":
                if let value = MacRemoteInputPolicy.number(dict["value"]) {
                    MacRemoteManager.shared.setVolume(Int(value.rounded()))
                }
            case "media_play_pause": MacRemoteManager.shared.simulateMediaKey(.playPause)
            case "media_next": MacRemoteManager.shared.simulateMediaKey(.next)
            case "media_prev": MacRemoteManager.shared.simulateMediaKey(.previous)
            case "mouse_move":
                if let dx = MacRemoteInputPolicy.number(dict["dx"]), let dy = MacRemoteInputPolicy.number(dict["dy"]) {
                    MacRemoteManager.shared.simulateMouseRelativeMove(dx: CGFloat(dx), dy: CGFloat(dy))
                }
            case "mouse_click":
                if let buttonStr = dict["button"] as? String, let isDown = dict["isDown"] as? Bool {
                    let button: CGMouseButton
                    switch buttonStr {
                    case "right": button = .right
                    case "center": button = .center
                    default: button = .left
                    }
                    MacRemoteManager.shared.simulateMouseClick(button: button, isDown: isDown)
                }
            case "mouse_scroll":
                if let dx = MacRemoteInputPolicy.number(dict["dx"]), let dy = MacRemoteInputPolicy.number(dict["dy"]) {
                    MacRemoteManager.shared.simulateMouseScroll(dx: CGFloat(dx), dy: dy)
                }
            case "lock_screen":
                MacRemoteManager.shared.lockScreen()
            case "screensaver":
                MacRemoteManager.shared.startScreensaver()
            case "brightness_up":
                MacRemoteManager.shared.increaseBrightness()
            case "brightness_down":
                MacRemoteManager.shared.decreaseBrightness()
            default: break
            }
        }
    }

    func handleMacMediaControlRequest(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let action = dict["action"] as? String {
            if action == "seekTo" {
                guard let position = dict["positionMs"] as? NSNumber,
                      position.doubleValue.isFinite, position.doubleValue >= 0 else {
                    sendMacMediaControlResponse(action: action, success: false)
                    return
                }
                DispatchQueue.main.async {
                    let accepted = MacInfoSyncManager.shared.seek(to: position.doubleValue / 1000.0)
                    if accepted { MacPowerManager.shared.noteRemoteActivity() }
                    self.sendMacMediaControlResponse(action: action, success: accepted)
                }
            } else {
                handleMediaControl(action: action)
            }
        }
    }

    func handleMediaControl(action: String) {
        guard NowPlayingCLI.shared.isAvailable else {
            sendMacMediaControlResponse(action: action, success: false)
            return
        }
        switch action {
        case "play": NowPlayingCLI.shared.play()
        case "pause": NowPlayingCLI.shared.pause()
        case "previous": NowPlayingCLI.shared.previous()
        case "next": NowPlayingCLI.shared.next()
        case "stop": NowPlayingCLI.shared.stop()
        case "playPause": NowPlayingCLI.shared.toggle()
        default:
            sendMacMediaControlResponse(action: action, success: false)
            return
        }
        DispatchQueue.main.async { MacPowerManager.shared.noteRemoteActivity() }
        sendMacMediaControlResponse(action: action, success: true)
    }
    
    func handleVolumeControl(action: String) {
        switch action {
        case "up", "vol_up": MacRemoteManager.shared.increaseVolume()
        case "down", "vol_down": MacRemoteManager.shared.decreaseVolume()
        case "mute", "vol_mute": MacRemoteManager.shared.toggleMute()
        default: return
        }
        DispatchQueue.main.async { MacPowerManager.shared.noteRemoteActivity() }
    }

    private func handleNotificationUpdate(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let nid = dict["id"] as? String {
            if (dict["action"] as? String)?.lowercased() == "dismiss" || dict["dismissed"] as? Bool == true {
                DispatchQueue.main.async {
                    if AppState.shared.notifications.contains(where: { $0.nid == nid }) {
                        AppState.shared.removeNotificationById(nid, notifyPhone: false)
                    }
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [nid])
                }
            }
        }
    }

    private func handleNotificationActionResponse(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String,
           let action = dict["action"] as? String,
           let success = dict["success"] as? Bool {
            print("[websocket] Notification action response id=\(id) action=\(action) success=\(success)")
        }
    }

    private func handleDismissalResponse(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String,
           let success = dict["success"] as? Bool {
            print("[websocket] Dismissal \(success ? "succeeded" : "failed") for notification id: \(id)")
        }
    }

    private func handleMediaControlResponse(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let action = dict["action"] as? String,
           let success = dict["success"] as? Bool {
            print("[websocket] Media control \(action) \(success ? "succeeded" : "failed")")
        }
    }

    private func handleUserDisconnected() {
        DispatchQueue.main.async {
            AppState.shared.disconnectDevice(manual: true)
        }
    }

    private func handleClipboardUpdate(_ message: Message) {
        if let dict = message.data.value as? [String: Any] {
            AppState.shared.handleClipboardEnvelope(dict)
        }
    }

    private func handleFileChunkAck(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String,
           let index = dict["index"] as? Int {
            self.lock.lock()
            if var set = outgoingAcks[id] {
                set.insert(index)
                outgoingAcks[id] = set
            }
            self.lock.unlock()
            self.transferWakeup.lock()
            self.transferWakeup.broadcast()
            self.transferWakeup.unlock()
        }
    }

    private func handleTransferVerified(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String,
           let verified = dict["verified"] as? Bool {
            lock.lock()
            let active = outgoingAcks[id] != nil
            if active { outgoingVerification[id] = (verified, dict["error"] as? String) }
            lock.unlock()
            transferWakeup.lock()
            transferWakeup.broadcast()
            transferWakeup.unlock()
            guard active else { return }
            MacPowerManager.shared.setTransferActive(id: "ws-outgoing:\(id)", active: false)
            AppState.shared.postNativeNotification(
                id: "transfer_verified_\(id)",
                appName: "androp",
                title: verified ? "Sent to \(AppState.shared.device?.name ?? "your phone")" : "Couldn't send file",
                body: verified ? "In Downloads on your phone" : "Try sending it again"
            )
        }
    }

    private func handleFileTransferCancel(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let id = dict["id"] as? String {
            cancelFileTransfer(id: id)
        }
    }

    func cancelAllFileTransfers() {
        lock.lock()
        let transfers = Array(incomingFiles.values)
        let outgoingIDs = Array(outgoingAcks.keys)
        incomingFiles.removeAll()
        incomingFilesChecksum.removeAll()
        outgoingAcks.removeAll()
        outgoingVerification.removeAll()
        lock.unlock()
        for transfer in transfers { MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(transfer.id)", active: false) }
        for id in outgoingIDs { MacPowerManager.shared.setTransferActive(id: "ws-outgoing:\(id)", active: false) }
        transferWakeup.lock()
        transferWakeup.broadcast()
        transferWakeup.unlock()
        fileQueue.async {
            for transfer in transfers {
                try? transfer.fileHandle?.close()
                try? FileManager.default.removeItem(at: transfer.tempUrl)
            }
        }
    }

    func cancelFileTransfer(id: String, notifyRemote: Bool = false) {
        if notifyRemote { _ = sendToFirstAvailable(message: FileTransferProtocol.buildCancel(id: id)) }
        lock.lock()
        let incoming = incomingFiles.removeValue(forKey: id)
        incomingFilesChecksum.removeValue(forKey: id)
        outgoingAcks.removeValue(forKey: id)
        outgoingVerification.removeValue(forKey: id)
        MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(id)", active: false)
        MacPowerManager.shared.setTransferActive(id: "ws-outgoing:\(id)", active: false)
        lock.unlock()
        transferWakeup.lock()
        transferWakeup.broadcast()
        transferWakeup.unlock()
        fileQueue.async {
            // An init already queued on fileQueue can register after the router
            // handles cancel. Drain that pending state as well as the snapshot.
            self.lock.lock()
            let queued = self.incomingFiles.removeValue(forKey: id)
            self.incomingFilesChecksum.removeValue(forKey: id)
            MacPowerManager.shared.setTransferActive(id: "ws-incoming:\(id)", active: false)
            self.lock.unlock()
            for transfer in [incoming, queued].compactMap({ $0 }) {
                try? transfer.fileHandle?.close()
                try? FileManager.default.removeItem(at: transfer.tempUrl)
            }
        }
    }

    private func handleCallControlResponse(_ message: Message) {
        if let dict = message.data.value as? [String: Any],
           let action = dict["action"] as? String,
           let success = dict["success"] as? Bool {
            let msg = dict["message"] as? String ?? ""
            print("[websocket] Call control \(action) \(success ? "succeeded" : "failed"): \(msg)")
        }
    }

    // MARK: - Outgoing Responses

    private func sendMacMediaControlResponse(action: String, success: Bool) {
        let message = """
        {
            "type": "macMediaControlResponse",
            "data": {
                "action": "\(action)",
                "success": \(success)
            }
        }
        """
        sendToFirstAvailable(message: message)
    }

    func sendMacInfoResponse() {
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused else { return }
            let macName = AppState.shared.myDevice?.name ?? (Host.current().localizedName ?? "My Mac")
            let categoryTypeRaw = DeviceTypeUtil.deviceTypeDescription()
            let exactDeviceNameRaw = DeviceTypeUtil.deviceFullDescription()
            let categoryType = categoryTypeRaw.isEmpty ? "Mac" : categoryTypeRaw
            let exactDeviceName = exactDeviceNameRaw.isEmpty ? categoryType : exactDeviceNameRaw
            let isPlusSubscription = AppState.shared.isPlus
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
            let savedAppPackages = Array(AppState.shared.androidApps.keys)

            let modelId = DeviceTypeUtil.modelIdentifier()
            let macInfo = MacInfo(
                name: macName,
                modelIdentifier: modelId,
                categoryType: categoryType,
                exactDeviceName: exactDeviceName,
                isPlusSubscription: isPlusSubscription,
                version: appVersion,
                savedAppPackages: savedAppPackages,
                quickSharePort: NearbyConnectionManager.shared.readyQuickSharePort
            )

            do {
                let jsonData = try JSONEncoder().encode(macInfo)
                if var jsonDict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    jsonDict["model"] = modelId
                    jsonDict["type"] = categoryType
                    jsonDict["isPlus"] = isPlusSubscription
                    jsonDict["quickShareEndpointSupported"] = true
                    for (key, value) in MacPowerManager.shared.statusFields { jsonDict[key] = value }

                    let messageDict: [String: Any] = [
                        "type": "macInfo",
                        "data": jsonDict
                    ]

                    let messageJsonData = try JSONSerialization.data(withJSONObject: messageDict, options: [])
                    if let messageJsonString = String(data: messageJsonData, encoding: .utf8) {
                        if !self.sendToFirstAvailable(message: messageJsonString), BLECentralManager.shared.isAuthenticated {
                            BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: messageJsonString)
                        }
                    }
                }
            } catch {
                print("[websocket] Error creating mac info response: \(error)")
            }
        }
    }
}
