//
//  NowPlayingAccessibility.swift
//  AirSync
//
//  Created by Sameera Sandakelum on 2025-09-17.
//

import Foundation

class NowPlayingCLI {
    static let shared = NowPlayingCLI()

    // Potential fallback paths for Apple Silicon and Intel Homebrew
    static let possibleMediaControlPaths = [
        "/opt/homebrew/bin/media-control", // Apple Silicon Homebrew
        "/usr/local/bin/media-control"     // Intel Homebrew
    ]

    // Cache resolved path to avoid repeated lookups
    private var cachedPath: String?

    private init() {}

    private func resolveBinaryPath() -> String? {
        if let cachedPath { return cachedPath }
        if let path = findExecutable(named: "media-control", fallbackPaths: NowPlayingCLI.possibleMediaControlPaths) {
            cachedPath = path
            return path
        }
        return nil
    }

    // MARK: - Local binary finder
    private func findExecutable(named name: String, fallbackPaths: [String]) -> String? {
        for path in fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        let dirs = envPath.components(separatedBy: ":")
        for dir in dirs {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    private var streamProcess: Process?
    private var streamPipe: Pipe?
    private var onUpdateHandler: ((NowPlayingInfo?) -> Void)?
    private var isStreamingActive = false
    private var retryCount = 0
    private let maxRetries = 10
    private var lineBuffer = Data()
    private var retryWorkItem: DispatchWorkItem?
    private var streamGeneration = 0

    func startStreaming(onUpdate: @escaping (NowPlayingInfo?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startStreaming(onUpdate: onUpdate) }
            return
        }
        self.onUpdateHandler = onUpdate
        guard !isStreamingActive else { return }
        streamGeneration += 1
        self.isStreamingActive = true
        self.retryCount = 0
        launchStreamProcess()
    }

    func stopStreaming() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stopStreaming() }
            return
        }
        streamGeneration += 1
        retryWorkItem?.cancel()
        retryWorkItem = nil
        self.isStreamingActive = false
        self.retryCount = 0
        self.onUpdateHandler = nil
        terminateStreamProcess()
    }

    func resetRetryCount() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resetRetryCount() }
            return
        }
        self.retryCount = 0
    }

    private func terminateStreamProcess() {
        if let process = streamProcess {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess = nil
        streamPipe = nil
        lineBuffer.removeAll()
    }

    private func launchStreamProcess() {
        guard isStreamingActive else { return }

        guard let binPath = resolveBinaryPath() else {
            print("[now-playing] media-control binary not found. Cannot stream updates.")
            // The caller may pause/restart before this asynchronous callback runs.
            let generation = streamGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStreamingActive, self.streamGeneration == generation else { return }
                self.onUpdateHandler?(nil)
            }
            return
        }

        terminateStreamProcess()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = ["stream", "--no-diff"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let readHandle = pipe.fileHandleForReading
        let generation = streamGeneration

        readHandle.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Serialize buffer parsing with start/stop and reject bytes from a dead process.
            DispatchQueue.main.async {
                guard let self, self.isStreamingActive,
                      self.streamGeneration == generation, self.streamProcess === process else { return }
                self.handleStreamData(data)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            readHandle.readabilityHandler = nil

            DispatchQueue.main.async {
                guard self.isStreamingActive, self.streamGeneration == generation,
                      self.streamProcess === proc else { return }
                self.onUpdateHandler?(nil)
                self.scheduleRetry(generation: generation)
            }
        }

        self.streamProcess = process
        self.streamPipe = pipe

        do {
            try process.run()
            print("[now-playing] Successfully launched media-control stream --no-diff")
        } catch {
            print("[now-playing] Failed to launch media-control stream:", error)
            process.terminationHandler = nil
            onUpdateHandler?(nil)
            scheduleRetry(generation: generation)
        }
    }

    private func scheduleRetry(generation: Int) {
        guard isStreamingActive, streamGeneration == generation, retryCount < maxRetries else { return }
        retryWorkItem?.cancel()
        retryCount += 1
        // Back off failed helpers instead of relaunching several times per second.
        let delay = min(pow(2.0, Double(retryCount - 1)), 30.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStreamingActive, self.streamGeneration == generation else { return }
            self.launchStreamProcess()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleStreamData(_ data: Data) {
        lineBuffer.append(data)
        // Corrupt/non-delimited helper output must not grow memory forever.
        guard lineBuffer.count <= 8 * 1024 * 1024 else {
            lineBuffer.removeAll()
            onUpdateHandler?(nil)
            return
        }

        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = lineBuffer.subdata(in: 0..<newlineIndex)
            lineBuffer.removeSubrange(0...newlineIndex)

            guard !lineData.isEmpty else { continue }
            parseStreamLine(lineData)
        }
    }

    private func parseStreamLine(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) else {
            return
        }

        let dict: [String: Any]? = {
            if let root = obj as? [String: Any] {
                if let payload = root["payload"] as? [String: Any] {
                    return payload.isEmpty ? nil : payload
                }
                if root.keys.contains("type") && root.keys.contains("payload") {
                    return nil
                }
                return root.isEmpty ? nil : root
            }
            return nil
        }()

        let info: NowPlayingInfo? = {
            guard let payload = dict, !payload.isEmpty else { return nil }
            var item = NowPlayingInfo()
            item.updateFromPayload(payload)
            return item.hasMediaSession ? item : nil
        }()

        guard isStreamingActive else { return }
        onUpdateHandler?(info)
    }




    func play() { runCommand("play") }
    func pause() { runCommand("pause") }
    func toggle() { runCommand("toggle-play-pause") }
    func next() { runCommand("next-track") }
    func previous() { runCommand("previous-track") }
    func stop() { runCommand("stop") }

    var isAvailable: Bool { resolveBinaryPath() != nil }

    @discardableResult
    func seek(to positionSeconds: Double) -> Bool {
        guard positionSeconds.isFinite, positionSeconds >= 0 else { return false }
        return runCommand("seek", arguments: [String(positionSeconds)])
    }

    @discardableResult
    private func runCommand(_ cmd: String, arguments: [String] = []) -> Bool {
        guard let binPath = resolveBinaryPath() else {
            print("[now-playing] media-control binary not found. Install with: brew install media-control")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = [cmd] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true // Command launched; playback confirmation comes from the stream.
        } catch {
            print("[now-playing] Failed to launch media command: \(error)")
            return false
        }
    }
}
