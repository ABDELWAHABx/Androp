import Foundation
import AppKit
import CoreBluetooth
import UserNotifications

class BLETransportBridge {
    static let shared = BLETransportBridge()
    
    func handleIncoming(uuid: CBUUID, payload: String) {
        guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated else { return }
        let components = payload.components(separatedBy: BLEConstants.delimiter)
        
        switch uuid {
        case BLEConstants.charNotificationData:
            handleNotification(components)
        case BLEConstants.charMediaState:
            handleMediaState(components)
        case BLEConstants.charClipboardDataNotify:
            handleClipboard(payload)
        case BLEConstants.charDeviceName:
            handleDeviceName(payload)
        case BLEConstants.charNotificationDismissNotify:
            handleNotificationDismiss(payload)
        case BLEConstants.charMacControl:
            handleMacControl(payload)
        default:
            break
        }
    }
    
    private func handleMacControl(_ payload: String) {
        if payload.utf8.count <= 2048, let bytes = payload.data(using: .utf8),
           let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           message["type"] as? String == "macPowerControl", let data = message["data"] as? [String: Any] {
            guard BLECentralManager.shared.isAuthenticated else { return }
            WebSocketServer.shared.handleMacPowerControl(data)
            return
        }
        if payload.utf8.count <= 64 * 1024, let bytes = payload.data(using: .utf8),
           let message = try? JSONDecoder().decode(Message.self, from: bytes) {
            let generation = BLECentralManager.shared.sessionGeneration
            DispatchQueue.main.async {
                guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                      BLECentralManager.shared.sessionGeneration == generation else { return }
                WebSocketServer.shared.handleBLEMessage(message)
            }
            return
        }
        let components = payload.components(separatedBy: "|")
        guard components.count >= 2 else { return }
        let type = components[0]
        let action = components[1]
        let value = components.count >= 3 ? components[2] : nil
        
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            switch type {
            case "media":
                WebSocketServer.shared.handleMediaControl(action: action)
            case "volume":
                if action == "vol_set", let value = value, let level = Int(value) {
                    MacRemoteManager.shared.setVolume(level)
                    MacPowerManager.shared.noteRemoteActivity()
                } else {
                    WebSocketServer.shared.handleVolumeControl(action: action)
                }
            case "remote":
                if action == "manual_disconnect" {
                    print("[BLE] Received manual disconnect from Android client! Instantly disconnecting...")
                    BLECentralManager.shared.disconnect()
                } else {
                    self.handleRemoteControl(action, value: value)
                }
            default:
                break
            }
        }
    }
    
    private func handleRemoteControl(_ action: String, value: String? = nil) {
        guard !AppState.shared.isSyncPaused else { return }
        switch action {
        case "vol_set":
            guard let value = value, let level = Int(value), (0...100).contains(level) else { return }
        case "arrow_up", "arrow_down", "arrow_left", "arrow_right", "enter", "space", "escape",
             "lock_screen", "screensaver", "brightness_up", "brightness_down",
             "media_play_pause", "media_next", "media_prev", "vol_up", "vol_down", "vol_mute": break
        default: return
        }
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            MacPowerManager.shared.noteRemoteActivity()
        }
        print("[ble] Received remote control: \(action)\(value.map { ", value: \($0)" } ?? "")")
        switch action {
        case "arrow_up": MacRemoteManager.shared.simulateKey(.upArrow)
        case "arrow_down": MacRemoteManager.shared.simulateKey(.downArrow)
        case "arrow_left": MacRemoteManager.shared.simulateKey(.leftArrow)
        case "arrow_right": MacRemoteManager.shared.simulateKey(.rightArrow)
        case "enter": MacRemoteManager.shared.simulateKey(.enter)
        case "space": MacRemoteManager.shared.simulateKey(.space)
        case "escape": MacRemoteManager.shared.simulateKey(.escape)
        case "lock_screen": MacRemoteManager.shared.lockScreen()
        case "screensaver": MacRemoteManager.shared.startScreensaver()
        case "brightness_up": MacRemoteManager.shared.increaseBrightness()
        case "brightness_down": MacRemoteManager.shared.decreaseBrightness()
        // Media: use NowPlayingCLI for reliability (HID simulation is unreliable from BLE context)
        case "media_play_pause": NowPlayingCLI.shared.toggle()
        case "media_next": NowPlayingCLI.shared.next()
        case "media_prev": NowPlayingCLI.shared.previous()
        case "vol_up": MacRemoteManager.shared.increaseVolume()
        case "vol_down": MacRemoteManager.shared.decreaseVolume()
        case "vol_mute": MacRemoteManager.shared.toggleMute()
        case "vol_set":
            if let value = value, let level = Int(value) {
                MacRemoteManager.shared.setVolume(level)
            }
        default: break
        }
    }
    
    private struct NotificationMetadata: Decodable {
        let id: String
        let actions: [NotificationAction]
        let priority: String?
    }

    private func handleNotification(_ components: [String]) {
        let pkg: String
        let appName: String
        let title: String
        let text: String
        
        if components.count >= 4 {
            pkg = components[0]
            appName = components[1]
            title = components[2]
            text = components[3]
        } else if components.count >= 3 {
            pkg = components[0]
            appName = pkg // Fallback to package name
            title = components[1]
            text = components[2]
        } else {
            return
        }
        
        var notificationID = UUID().uuidString
        var actions: [NotificationAction] = []
        var priority = ""
        if components.count >= 5, components[4].utf8.count <= 16 * 1024,
           let data = components[4].data(using: .utf8),
           let metadata = try? JSONDecoder().decode(NotificationMetadata.self, from: data),
           !metadata.id.isEmpty, metadata.id.count <= 512 {
            notificationID = metadata.id
            priority = metadata.priority == "silent" ? "silent" : "alerting"
            actions = Array(metadata.actions.prefix(8)).filter { !$0.name.isEmpty && $0.name.count <= 128 }
        }
        let notif = Notification(
            title: title,
            body: text,
            app: appName,
            nid: notificationID,
            package: pkg,
            priority: priority,
            actions: actions
        )
        
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            AppState.shared.addNotification(notif)
        }
    }
    
    private func handleMediaState(_ components: [String]) {
        guard components.count >= 6 else { return }
        let isPlaying = components[0] == "1"
        let title = components[1]
        let artist = components[2]
        let volume = Int(components[3]) ?? 0
        let isMuted = components[4] == "1"
        let likeStatus = components[5]
        
        // Update AppState.status
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            let music = DeviceStatus.Music(
                isPlaying: isPlaying,
                title: title,
                artist: artist,
                volume: volume,
                isMuted: isMuted,
                albumArt: "", // No art over BLE
                likeStatus: likeStatus,
                duration: -1.0,
                position: -1.0,
                isBuffering: false
            )
            
            if AppState.shared.status == nil {
                AppState.shared.status = DeviceStatus(battery: DeviceStatus.Battery(level: 0, isCharging: false, isReported: false), isPaired: true, music: music)
            } else {
                AppState.shared.status?.music = music
            }
        }
    }
    
    private func handleClipboard(_ text: String) {
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            if let bytes = text.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               envelope["andropClipboard"] as? Int == 1,
               let kind = envelope["kind"] as? String, kind == "update" || kind == "ack" {
                if kind == "ack" {
                    AppState.shared.acknowledgeClipboard(id: envelope["id"] as? String ?? "", ok: envelope["ok"] as? Bool ?? false)
                } else { AppState.shared.handleClipboardEnvelope(envelope) }
            } else if AppState.shared.isClipboardSyncEnabled {
                AppState.shared.updateClipboardFromAndroid(text)
            }
        }
    }

    private func handleDeviceName(_ name: String) {
        print("[ble] Received device name: \(name)")
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            BLECentralManager.shared.connectedDeviceName = name
            if AppState.shared.device != nil {
                AppState.shared.device?.name = name
            }
        }
    }
    
    private func handleNotificationDismiss(_ id: String) {
        print("[ble] Received notification dismissal: \(id)")
        let generation = BLECentralManager.shared.sessionGeneration
        DispatchQueue.main.async {
            guard !AppState.shared.isSyncPaused, BLECentralManager.shared.isAuthenticated,
                  BLECentralManager.shared.sessionGeneration == generation else { return }
            AppState.shared.removeNotificationById(id, notifyPhone: false)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }
    
    // --- Outbound ---
    
    func sendMediaControl(_ action: String) {
        BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: action)
    }
    
    func sendMacMediaState(info: NowPlayingInfo) {
        let payload = [
            (info.isPlaying ?? false) ? "1" : "0",
            info.title ?? "",
            info.artist ?? "",
            String(MacRemoteManager.shared.lastVolumeLevel),
            (MacRemoteManager.shared.lastVolumeLevel == 0) ? "1" : "0",
            "none"
        ].joined(separator: BLEConstants.delimiter)
        
        BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMacMediaState, payload: payload)
    }
    
    func sendClipboard(_ text: String) {
        BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charClipboardDataWrite, payload: text)
    }
}
