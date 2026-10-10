//
//  NowPlayingViewModel.swift
//  AirSync
//
//  Created by Sameera Sandakelum on 2025-09-17.
//
import Foundation
import Combine
import CryptoKit

class MacInfoSyncManager: ObservableObject {
    static let shared = MacInfoSyncManager()
    @Published var title: String = "Unknown Title"
    @Published var artist: String = "Unknown Artist"
    @Published var album: String = "Unknown Album"
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false
    @Published var artworkBase64: String = ""

    private var timer: Timer?
    private var lastSentInfo: NowPlayingInfo?
    // Snapshot of the last payload we actually sent over the wire
    private var lastSentSnapshot: Snapshot?
    
    private var lastSentArtworkHash: String?
    private var cachedArtworkData: Data?
    private var cachedArtworkHash: String?

    // Mirrors the payload fields we send so equality check is accurate and cheap
    private struct Snapshot: Equatable {
        struct Music: Equatable {
            let isPlaying: Bool
            let title: String
            let artist: String
            let volume: Int
            let isMuted: Bool
            let albumArt: String
            let likeStatus: String
            let elapsedTime: Int
            let duration: Int
            let playbackRate: Double
        }
        let batteryLevel: Int
        let isCharging: Bool
        let isPaired: Bool
        let music: Music?
    }
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Monitor device connection status and sendNowPlayingStatus toggle
        Publishers.CombineLatest3(AppState.shared.$device, AppState.shared.$sendNowPlayingStatus, AppState.shared.$isSyncPaused)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] device, sendNowPlayingStatus, isPaused in
                if device != nil && !isPaused {
                    self?.startSync(sendNowPlayingStatus: sendNowPlayingStatus)
                } else {
                    self?.stopSync()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        stopSync()
        cancellables.removeAll()
    }

    private func startSync(sendNowPlayingStatus: Bool) {
        print("[mac-info-sync] Starting device status monitoring - device connected")

        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.refreshBatteryStatus()
            }
            timer?.tolerance = 10
        }

        if sendNowPlayingStatus {
            NowPlayingCLI.shared.startStreaming { [weak self] info in
                self?.handleNowPlayingUpdate(info)
            }
            refreshBatteryStatus()
        } else {
            NowPlayingCLI.shared.stopStreaming()
            sendDeviceStatusWithoutMusic()
        }
    }

    private func stopSync() {
        print("[mac-info-sync] Stopping media playback monitoring - device disconnected")
        timer?.invalidate()
        timer = nil

        NowPlayingCLI.shared.stopStreaming()

        title = ""
        artist = ""
        album = ""
        elapsed = 0
        duration = 0
        isPlaying = false
        artworkBase64 = ""
        lastSentInfo = nil
        lastSentSnapshot = nil
        lastSentArtworkHash = nil
        cachedArtworkData = nil
        cachedArtworkHash = nil
    }

    func forceRefresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.forceRefresh() }
            return
        }
        // A transport handover must send a complete snapshot to the new receiver.
        lastSentSnapshot = nil
        lastSentArtworkHash = nil
        refreshStatus()
    }

    private func refreshStatus() {
        guard AppState.shared.device != nil, !AppState.shared.isSyncPaused else { return }
        if let lastInfo = lastSentInfo, AppState.shared.sendNowPlayingStatus {
            sendDeviceStatusIfNeeded(with: lastInfo)
        } else {
            sendDeviceStatusWithoutMusic()
        }
    }

    private func refreshBatteryStatus() {
        refreshStatus()
        // Reuse the existing minute status tick; media-control streams may emit
        // only state changes during long, uninterrupted playback.
        MacPowerManager.shared.refreshMediaActivity()
    }

    private func handleNowPlayingUpdate(_ info: NowPlayingInfo?) {
        guard AppState.shared.device != nil, !AppState.shared.isSyncPaused else { return }

        guard let info = info, info.hasMediaSession else {
            sendDeviceStatusWithoutMusic()
            return
        }

        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        if let bundleId = info.bundleIdentifier, !ownBundleId.isEmpty, bundleId == ownBundleId {
            sendDeviceStatusWithoutMusic()
            return
        }

        title = info.title ?? ""
        artist = info.artist ?? ""
        album = info.album ?? ""
        elapsed = info.elapsedTime ?? 0
        duration = info.duration ?? 0
        isPlaying = info.isPlaying ?? false
        sendDeviceStatusIfNeeded(with: info)
    }
    
    private func sendDeviceStatusWithoutMusic() {
        // Only send if there's a connected device
        guard AppState.shared.device != nil, !AppState.shared.isSyncPaused else { return }

        // Forget stale media before deduplicating, or a battery tick resurrects it.
        lastSentInfo = nil
        lastSentArtworkHash = nil
        cachedArtworkData = nil
        cachedArtworkHash = nil
        title = ""
        artist = ""
        album = ""
        elapsed = 0
        duration = 0
        isPlaying = false
        artworkBase64 = ""
        let batteryInfo = getBatteryInfo()

        // Build snapshot and compare to last sent; skip network if identical
        let snapshot = Snapshot(
            batteryLevel: batteryInfo.level,
            isCharging: batteryInfo.isCharging,
            isPaired: true,
            music: nil
        )

        guard snapshot != lastSentSnapshot else {
            // Nothing changed — skip sending
            return
        }

        // Send device status without music info (full payload for current mode)
        WebSocketServer.shared.sendDeviceStatus(
            batteryLevel: snapshot.batteryLevel,
            isCharging: snapshot.isCharging,
            isPaired: snapshot.isPaired,
            musicInfo: nil,
            albumArtBase64: nil
        )

        // Update last sent snapshot
        lastSentSnapshot = snapshot

        // Handle N/A battery status for desktop Macs
        if batteryInfo.level == -1 {
            print("[mac-info-sync] Sent device status update (desktop Mac - no battery, no music)")
        } else {
            print("[mac-info-sync] Sent device status update (battery: \(batteryInfo.level)%, charging: \(batteryInfo.isCharging), no music)")
        }
    }

    private func sendDeviceStatusIfNeeded(with info: NowPlayingInfo) {
        // Only send if there's a connected device
        guard AppState.shared.device != nil, !AppState.shared.isSyncPaused else { return }

        // Check if now playing is enabled - if not, send status without music info
        let shouldIncludeMusicInfo = AppState.shared.sendNowPlayingStatus
        
        // Get battery info
        let batteryInfo = getBatteryInfo()

        if info.artworkData != cachedArtworkData {
            cachedArtworkData = info.artworkData
            cachedArtworkHash = info.artworkData.map { data in
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        let currentHash = cachedArtworkHash

        let isArtworkChanged = (currentHash != lastSentArtworkHash)
        let artworkToSend: String?
        if shouldIncludeMusicInfo {
            if isArtworkChanged {
                if let rawData = info.artworkData {
                    artworkToSend = rawData.base64EncodedString()
                } else {
                    artworkToSend = ""
                }
                self.artworkBase64 = artworkToSend ?? ""
            } else {
                // Missing artwork means retain the receiver's cached bitmap.
                artworkToSend = nil
            }
        } else {
            artworkToSend = nil
        }

        // Build snapshot mirroring the payload we would send
        let musicSnapshot: Snapshot.Music? = {
            guard shouldIncludeMusicInfo else { return nil }
            return Snapshot.Music(
                isPlaying: info.isPlaying ?? false,
                title: info.title ?? "",
                artist: info.artist ?? "",
                volume: MacRemoteManager.shared.lastVolumeLevel,
                isMuted: MacRemoteManager.shared.lastVolumeLevel == 0,
                albumArt: currentHash ?? "", // Use hash for snapshot comparison
                likeStatus: "none", // must match payload default
                // Receivers interpolate position locally; transport wakes only every 5 seconds.
                elapsedTime: Int((info.elapsedTime ?? 0) / 5),
                duration: Int(info.duration ?? 0),
                playbackRate: info.playbackRate ?? (info.isPlaying == true ? 1.0 : 0.0)
            )
        }()

        let snapshot = Snapshot(
            batteryLevel: batteryInfo.level,
            isCharging: batteryInfo.isCharging,
            isPaired: true,
            music: musicSnapshot
        )

        // Keep the latest timeline even if its network update is coalesced.
        if shouldIncludeMusicInfo { lastSentInfo = info }
        // Early exit if nothing changed compared to the last sent payload
        guard snapshot != lastSentSnapshot else {
//            print("[mac-info-sync] No change, Skipping")
            return
        }

        // Send full device status
        WebSocketServer.shared.sendDeviceStatus(
            batteryLevel: snapshot.batteryLevel,
            isCharging: snapshot.isCharging,
            isPaired: snapshot.isPaired,
            musicInfo: shouldIncludeMusicInfo ? info : nil,
            albumArtBase64: artworkToSend
        )


        // Update last sent trackers
        lastSentSnapshot = snapshot
        if shouldIncludeMusicInfo { 
            if let sent = artworkToSend {
                lastSentArtworkHash = sent.isEmpty ? nil : currentHash
            }
        }

        // Logging
//        if shouldIncludeMusicInfo {
//            print("Sent device status to Android: \(info.title ?? "Unknown") by \(info.artist ?? "Unknown")")
//        } else {
//            if batteryInfo.level == -1 {
//                print("Sent device status update (desktop Mac - no battery)")
//            } else {
//                print("Sent device status update (battery: \(batteryInfo.level)%, charging: \(batteryInfo.isCharging))")
//            }
//        }
    }

    private func getBatteryInfo() -> (level: Int, isCharging: Bool) {
        // IOKit reports internal batteries directly without subprocesses or model lookups.
        if let status = BatteryInfo.fetchStatus() {
            return (level: status.percentage, isCharging: status.isCharging)
        }
        return (level: -1, isCharging: false)
    }

    // MARK: - Media Control Functions
    func togglePlayPause() {
        NowPlayingCLI.shared.toggle()
    }

    func play() {
        NowPlayingCLI.shared.play()
    }

    func pause() {
        NowPlayingCLI.shared.pause()
    }

    func next() {
        NowPlayingCLI.shared.next()
    }

    func previous() {
        NowPlayingCLI.shared.previous()
    }

    @discardableResult
    func seek(to positionSeconds: Double) -> Bool {
        guard !AppState.shared.isSyncPaused, positionSeconds.isFinite, positionSeconds >= 0 else { return false }
        let bounded = duration > 0 ? min(positionSeconds, duration) : positionSeconds
        return NowPlayingCLI.shared.seek(to: bounded)
    }

    func stop() {
        NowPlayingCLI.shared.stop()
    }
}
