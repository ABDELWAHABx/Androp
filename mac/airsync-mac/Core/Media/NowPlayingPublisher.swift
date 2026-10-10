//
//  NowPlayingPublisher.swift
//  AirSync
//
//  Publishes Android now-playing info into macOS MPNowPlayingInfoCenter
// so boring.notch (via MediaRemote.framework) picks it up naturally.
// Uses silent audio to make the app audio-eligible for MediaRemote reporting.
//

import Foundation
import AppKit
import AVFoundation
import MediaPlayer

final class NowPlayingPublisher {
    static let shared = NowPlayingPublisher()

    // MARK: - Silent Audio Engine (makes app audio-eligible for MediaRemote)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isSilentAudioRunning: Bool = false

    // MARK: - State
    private var currentInfo: NowPlayingInfo?
    private var commandCenterRegistered = false

    /// Timestamp of the last remote command we sent to Android.
    private var lastCommandSentAt: Date = .distantPast
    /// Timestamp of the last time we updated MPNowPlayingInfoCenter.
    private var lastStateUpdateAt: Date = .distantPast
    
    // Short debounces to provide an instant UI while preventing macOS feedback loops:
    // 0.35s limits how fast the user can mash buttons, and blocks automated
    // counter-commands that macOS fires right after we update the info center.
    private let commandDebounceInterval: TimeInterval = 0.35
    private let stateUpdateDebounceInterval: TimeInterval = 0.35

    private init() {}

    // MARK: - Public API

    /// Call once at app startup. Registers remote commands only.
    /// Silent audio is started/stopped separately based on the showInControlCenter setting.
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        registerRemoteCommands()
    }

    /// Starts silent audio if not already running (called when showInControlCenter is enabled).
    func enableSilentAudio() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.enableSilentAudio() }
            return
        }
        if currentInfo?.isPlaying == true { startSilentAudio() }
    }

    /// Stops silent audio and clears Now Playing info (called when showInControlCenter is disabled).
    func disableSilentAudio() {
        clear()
    }

    /// Update now-playing with Android media info.
    /// During the 1-second window after the user clicks a button, we ignore incoming
    /// status updates. This protects our instant optimistic UI from being overwritten
    /// by stale network packets that Android dispatched before the command took effect.
    func update(info: NowPlayingInfo) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.update(info: info) }
            return
        }
        guard UserDefaults.standard.showInControlCenter,
              !AppState.shared.isSyncPaused, AppState.shared.device != nil,
              info.hasMediaSession else {
            clear()
            return
        }
        let timeSinceCommand = Date().timeIntervalSince(lastCommandSentAt)
        if timeSinceCommand < 1.0 {
            return
        }
        
        currentInfo = info

        // Paused/idle sessions must not keep an audio engine waking the CPU.
        if info.isPlaying == true { startSilentAudio() }
        else { stopSilentAudio() }
        lastStateUpdateAt = Date()
        publishToNowPlayingInfoCenter(info: info)
    }

    /// Clear now-playing info (e.g., Android disconnected)
    func clear() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clear() }
            return
        }
        currentInfo = nil
        stopSilentAudio()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        setTransportCommandsEnabled(false)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = false
    }

    // MARK: - Silent Audio

    func startSilentAudio() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startSilentAudio() }
            return
        }
        guard UserDefaults.standard.showInControlCenter, !AppState.shared.isSyncPaused,
              currentInfo?.isPlaying == true, !isSilentAudioRunning else { return }
        isSilentAudioRunning = true

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        // Generate one second of silence
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            isSilentAudioRunning = false
            return
        }
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            isSilentAudioRunning = false
            return
        }
        buffer.frameLength = frameCount
        // Buffer is already zeroed by default — silence

        // BUG FIX: engine.start() MUST come before player.play() / scheduleBuffer.
        // Calling player.play() on an un-started engine produces:
        //   "Engine is not running because it was not explicitly started"
        do {
            try engine.start()
        } catch {
            print("[NowPlayingPublisher] Failed to start silent audio engine: \(error)")
            isSilentAudioRunning = false
            return
        }

        audioEngine = engine
        playerNode = player

        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        print("[NowPlayingPublisher] Silent audio engine started — app is now audio-eligible")
    }

    func stopSilentAudio() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopSilentAudio() }
            return
        }
        guard isSilentAudioRunning else { return }
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        playerNode = nil
        isSilentAudioRunning = false
        print("[NowPlayingPublisher] Silent audio engine stopped")
    }

    // MARK: - Publish to MPNowPlayingInfoCenter

    private func publishToNowPlayingInfoCenter(info: NowPlayingInfo) {
        let center = MPNowPlayingInfoCenter.default()
        setTransportCommandsEnabled(true)

        var mpInfo: [String: Any] = [
            MPMediaItemPropertyTitle: info.title ?? "",
            MPMediaItemPropertyArtist: info.artist ?? "",
            MPMediaItemPropertyAlbumTitle: info.album ?? "",
        ]

        if let duration = info.duration, duration > 0 {
            mpInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsed = info.elapsedTime {
            mpInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        let rate = info.playbackRate ?? 1.0
        mpInfo[MPNowPlayingInfoPropertyPlaybackRate] = info.isPlaying == true ? (rate.isFinite && rate > 0 ? rate : 1.0) : 0.0
        mpInfo[MPNowPlayingInfoPropertyIsLiveStream] = (info.duration ?? 0) <= 0
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled =
            (info.duration ?? 0) > 0 && (AppState.shared.device?.isRegularConnection ?? false)

        if let artworkData = info.artworkData,
           let nsImage = NSImage(data: artworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: nsImage.size.width, height: nsImage.size.height)) { _ in
                return nsImage
            }
            mpInfo[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = mpInfo
        // Restore playbackState so UI elements like boringNotch know it's explicitly playing/paused.
        // Automated counter-commands triggered by this change will be dropped by stateUpdateDebounceInterval.
        center.playbackState = info.isPlaying == true ? .playing : .paused
    }

    // MARK: - Remote Commands
    
    private func processCommand(name: String, action: String, optimisticUpdate: ((NowPlayingPublisher) -> Void)? = nil) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync {
                processCommand(name: name, action: action, optimisticUpdate: optimisticUpdate)
            }
        }
        guard !AppState.shared.isSyncPaused, AppState.shared.device != nil,
              currentInfo?.hasMediaSession == true else { return .noSuchContent }
        let now = Date()
        let timeSinceCommand = now.timeIntervalSince(lastCommandSentAt)
        let timeSinceState = now.timeIntervalSince(lastStateUpdateAt)
        
        if timeSinceCommand < commandDebounceInterval {
            return .success
        }
        if timeSinceState < stateUpdateDebounceInterval {
            return .success
        }
        
        lastCommandSentAt = now
        WebSocketServer.shared.sendAndroidMediaControl(action: action)
        optimisticUpdate?(self)
        
        return .success
    }

    private func registerRemoteCommands() {
        guard !commandCenterRegistered else { return }
        commandCenterRegistered = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // NOTE: Commands are forwarded to Android via WebSocket (not NowPlayingCLI which
        // controls LOCAL Mac media via the `media-control` binary). This music is from
        // the phone, so control actions must go back over the WebSocket connection.
        // IMPORTANT: macOS often fires automated counter-commands when we update MPNowPlayingInfoCenter.
        // We drop any commands received within `stateUpdateDebounceInterval` of our last update.
        // We also do optimistic updates so the UI responds instantly to clicks.
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            return self?.processCommand(name: "Play", action: "play") { $0.publishPlaybackStateUpdate(playing: true) } ?? .commandFailed
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            return self?.processCommand(name: "Pause", action: "pause") { $0.publishPlaybackStateUpdate(playing: false) } ?? .commandFailed
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            return self?.processToggle() ?? .commandFailed
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            return self?.processCommand(name: "NextTrack", action: "nextTrack") ?? .commandFailed
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            return self?.processCommand(name: "PreviousTrack", action: "previousTrack") ?? .commandFailed
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self.processSeek(to: seekEvent.positionTime)
        }
        commandCenter.changePlaybackPositionCommand.isEnabled = false

        setTransportCommandsEnabled(false)
        print("[NowPlayingPublisher] Remote commands registered")
    }

    private func setTransportCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
    }

    private func processToggle() -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.processToggle() }
        }
        let isPlaying = currentInfo?.isPlaying == true
        return processCommand(name: "TogglePlayPause", action: isPlaying ? "pause" : "play") {
            $0.publishPlaybackStateUpdate(playing: !isPlaying)
        }
    }

    private func processSeek(to positionSeconds: Double) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { self.processSeek(to: positionSeconds) }
        }
        guard var info = currentInfo, info.hasMediaSession,
              (AppState.shared.device?.isRegularConnection ?? false),
              !AppState.shared.isSyncPaused, let duration = info.duration, duration > 0,
              positionSeconds.isFinite else { return .commandFailed }
        guard Date().timeIntervalSince(lastCommandSentAt) >= commandDebounceInterval else { return .success }
        let position = min(max(0, positionSeconds), duration)
        lastCommandSentAt = Date()
        WebSocketServer.shared.seekTo(positionSeconds: position)
        info.elapsedTime = position
        currentInfo = info
        lastStateUpdateAt = Date()
        publishToNowPlayingInfoCenter(info: info)
        return .success
    }

    private func publishPlaybackStateUpdate(playing: Bool) {
        guard var info = currentInfo else { return }
        info.isPlaying = playing
        currentInfo = info
        if playing { startSilentAudio() } else { stopSilentAudio() }
        lastStateUpdateAt = Date()
        publishToNowPlayingInfoCenter(info: info)
    }
}
