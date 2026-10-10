//
//  ScrcpyServerManager.swift
//  AirSync
//
//  Created by Sameera Wijerathna on 2026-04-01.
//

import Foundation
import Darwin

class ScrcpyServerManager: NSObject {
    static let shared = ScrcpyServerManager()
    
    private let serverLocalPath = Bundle.main.path(forResource: "scrcpy-server", ofType: nil)
    private let serverRemotePath = "/data/local/tmp/scrcpy-server"
    private let serverPort: Int = 1234
    
    private var adbProcess: Process?
    private var activeSerial: String?
    private let sessionLock = NSRecursiveLock()
    private var sessionGeneration: UInt64 = 0

    private func isCurrentSession(_ generation: UInt64) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return generation == sessionGeneration && !AppState.shared.isSyncPaused
    }
    
    func startServer(serial: String, desktopMode: Bool = false, completion: @escaping (Bool) -> Void) {
        sessionLock.lock()
        let generation = sessionGeneration
        sessionLock.unlock()
        guard isCurrentSession(generation) else { return }
        sessionLock.lock()
        activeSerial = serial
        sessionLock.unlock()
        let adbPath = ADBConnector.findExecutable(named: "adb", fallbackPaths: ADBConnector.possibleADBPaths) ?? "/opt/homebrew/bin/adb"
        
        // Step 0: Cleanup previous instances and port forwards
        print("[ScrcpyServerManager] Cleaning up previous sessions...")
        
        // Remove port forward on Mac
        let cleanupPort = Process()
        cleanupPort.executableURL = URL(fileURLWithPath: adbPath)
        cleanupPort.arguments = ["-s", serial, "forward", "--remove", "tcp:\(serverPort)"]
        do {
            try cleanupPort.run()
            cleanupPort.waitUntilExit()
        } catch {
            print("[ScrcpyServerManager] Cleanup could not launch ADB: \(error)")
            completion(false)
            return
        }
        
        // Kill existing server process on device
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: adbPath)
        killProcess.arguments = ["-s", serial, "shell", "pkill -f com.genymobile.scrcpy.Server || true"]
        do {
            try killProcess.run()
            killProcess.waitUntilExit()
        } catch {
            print("[ScrcpyServerManager] Device cleanup failed: \(error)")
            completion(false)
            return
        }
        
        // Step 1: Push the server
        pushServer(serial: serial) { success in
            guard self.isCurrentSession(generation) else { return }
            guard success else {
                completion(false)
                return
            }
            
            // Step 2: Forward port
            self.forwardPort(serial: serial) { success in
                guard self.isCurrentSession(generation) else { return }
                guard success else {
                    completion(false)
                    return
                }
                
                // Step 3: Launch server
                self.launchServer(serial: serial, desktopMode: desktopMode, generation: generation, completion: completion)
            }
        }
    }
    
    private func pushServer(serial: String, completion: @escaping (Bool) -> Void) {
        let adbPath = ADBConnector.findExecutable(named: "adb", fallbackPaths: ADBConnector.possibleADBPaths) ?? "/opt/homebrew/bin/adb"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        guard let serverLocalPath, FileManager.default.isReadableFile(atPath: serverLocalPath) else {
            print("[ScrcpyServerManager] Bundled scrcpy server is missing")
            completion(false)
            return
        }
        process.arguments = ["-s", serial, "push", serverLocalPath, serverRemotePath]
        
        do {
            try process.run()
            process.waitUntilExit()
            completion(process.terminationStatus == 0)
        } catch {
            print("[ScrcpyServerManager] Push failed: \(error)")
            completion(false)
        }
    }
    
    private func forwardPort(serial: String, completion: @escaping (Bool) -> Void) {
        let adbPath = ADBConnector.findExecutable(named: "adb", fallbackPaths: ADBConnector.possibleADBPaths) ?? "/opt/homebrew/bin/adb"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "forward", "tcp:\(serverPort)", "localabstract:scrcpy"]
        
        do {
            try process.run()
            process.waitUntilExit()
            completion(process.terminationStatus == 0)
        } catch {
            print("[ScrcpyServerManager] Port forward failed: \(error)")
            completion(false)
        }
    }
    
    private var launchCompletion: ((Bool) -> Void)?
    private var launchTimer: Timer?
    
    func launchServer(serial: String, desktopMode: Bool = false, generation: UInt64? = nil, completion: @escaping (Bool) -> Void) {
        sessionLock.lock()
        let generation = generation ?? sessionGeneration
        sessionLock.unlock()
        guard isCurrentSession(generation) else { return }
        let adbPath = ADBConnector.findExecutable(named: "adb", fallbackPaths: ADBConnector.possibleADBPaths) ?? "/opt/homebrew/bin/adb"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        
        var serverArgs = [
            "tunnel_forward=true", "audio=false", "video=true", "control=true",
            "video_codec=h265", "video_bit_rate=8000000"
        ]
        
        if desktopMode {
            // Virtual display — new_display requires "WxH" or "WxH/DPI" format
            let dpi = UserDefaults.standard.scrcpyDesktopDpi
            if !dpi.isEmpty {
                serverArgs.append("new_display=1920x1080/\(dpi)")
            } else {
                serverArgs.append("new_display=1920x1080")
            }
            serverArgs.append("flex_display=true")
        } else {
            serverArgs.append("max_size=1440")
        }
        
        process.arguments = [
            "-s", serial,
            "shell",
            "CLASSPATH=\(serverRemotePath)",
            "app_process", "/", "com.genymobile.scrcpy.Server", "4.1"
        ] + serverArgs
        
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    print("[scrcpy-server] \(trimmed)")
                    
                    // Detect readiness: "[server] INFO: Video size: ..." or "[server] INFO: New display: ..."
                    if trimmed.contains("INFO: Video size:") || trimmed.contains("INFO: New display:") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            guard self?.isCurrentSession(generation) == true else { return }
                            self?.finishLaunch(success: true, generation: generation)
                        }
                    }
                    
                    // Detect failure
                    if trimmed.contains("ERROR:") || trimmed.contains("Exception") {
                        print("[ScrcpyServerManager] Server reported error: \(trimmed)")
                        // Trigger failure if it's a critical error
                        if trimmed.contains("Permission denied") || trimmed.contains("could not start") {
                            DispatchQueue.main.async {
                                guard self?.isCurrentSession(generation) == true else { return }
                                self?.finishLaunch(success: false, generation: generation)
                            }
                        }
                    }
                }
            }
        }
        
        sessionLock.lock()
        guard isCurrentSession(generation) else {
            sessionLock.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        do {
            try process.run()
            self.adbProcess = process
            self.launchCompletion = completion
            sessionLock.unlock()
            
            // Watchdog timer: if we don't see the log in 5s, proceed anyway
            DispatchQueue.main.async {
                guard self.isCurrentSession(generation) else { return }
                self.launchTimer?.invalidate()
                self.launchTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    guard self?.isCurrentSession(generation) == true else { return }
                    if self?.launchCompletion != nil {
                        print("[ScrcpyServerManager] Readiness log timeout - proceeding anyway")
                        self?.finishLaunch(success: true, generation: generation)
                    }
                }
            }
        } catch {
            sessionLock.unlock()
            print("[ScrcpyServerManager] Launch failed: \(error)")
            completion(false)
        }
    }
    
    private func finishLaunch(success: Bool, generation: UInt64) {
        sessionLock.lock()
        guard isCurrentSession(generation) else { sessionLock.unlock(); return }
        let completion = launchCompletion
        launchCompletion = nil
        launchTimer?.invalidate()
        launchTimer = nil
        sessionLock.unlock()
        // Clear before calling external code: completion may stop/start another session.
        completion?(success)
    }

    func stopServer() {
        sessionLock.lock()
        sessionGeneration &+= 1
        let currentProcess = adbProcess
        let serial = activeSerial
        activeSerial = nil
        adbProcess = nil
        launchTimer?.invalidate()
        launchTimer = nil
        launchCompletion = nil
        sessionLock.unlock()
        if let process = currentProcess {
            if let pipe = process.standardOutput as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            if let pipe = process.standardError as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            if process.isRunning { process.terminate() }
        }
        // Pausing an idle app must not launch ADB just to clean up a nonexistent session.
        guard let serial else { return }
        // Remove only this device's port forward
        let adbPath = ADBConnector.findExecutable(named: "adb", fallbackPaths: ADBConnector.possibleADBPaths) ?? "/opt/homebrew/bin/adb"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "forward", "--remove", "tcp:\(serverPort)"]
        
        do {
            try process.run()
            // Cleanup must never block Pause or window dismissal on the UI thread.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        } catch {
            print("[ScrcpyServerManager] Failed to remove port forward: \(error)")
        }
    }
    
    func startMirroringSession(appState: AppState, streamClient: ScrcpyStreamClient, desktopMode: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        // Stop any current session first to prevent port/process clashes
        self.stopMirroringSession(streamClient: streamClient)
        sessionLock.lock()
        let generation = sessionGeneration
        sessionLock.unlock()
        guard isCurrentSession(generation) else { return }
        let wiredAdbEnabled = appState.wiredAdbEnabled
        let wirelessAddress = "\(appState.adbConnectedIP):\(appState.adbPort)"
        let adbConnected = appState.adbConnected
        
        ADBConnector.getWiredDevices { devices in
            guard self.isCurrentSession(generation) else { return }
            let mappedSerial = appState.selectedWiredSerial ?? (appState.device?.deviceId).flatMap { appState.deviceAdbSerials[$0] }
            let serialToUse: String?
            if let mapped = mappedSerial, devices.contains(where: { $0.serial == mapped }) {
                serialToUse = mapped
            } else {
                serialToUse = devices.first?.serial
            }
            
            let finalSerial: String?
            if wiredAdbEnabled, let serial = serialToUse {
                finalSerial = serial
            } else if adbConnected && !appState.adbConnectedIP.isEmpty {
                finalSerial = wirelessAddress
            } else {
                finalSerial = nil
            }
            
            guard let serial = finalSerial else {
                DispatchQueue.main.async {
                    completion(false, "No ADB device detected. Please connect your device via USB or Wi-Fi.")
                }
                return
            }
            
            self.startServer(serial: serial, desktopMode: desktopMode) { success in
                guard success else {
                    DispatchQueue.main.async {
                        completion(false, "Failed to start scrcpy server on device.")
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard self.isCurrentSession(generation) else { return }
                    streamClient.onPacketReceived = { data, isConfig, isKeyframe, pts in
                        ScrcpyVideoDecoder.shared.decodePacket(data: data, isConfig: isConfig, pts: pts)
                    }
                    streamClient.connect()
                    ScrcpyControlClient.shared.connect()
                    completion(true, nil)
                }
            }
        }
    }
    
    func stopMirroringSession(streamClient: ScrcpyStreamClient) {
        streamClient.onPacketReceived = nil
        streamClient.disconnect()
        ScrcpyControlClient.shared.disconnect()
        ScrcpyVideoDecoder.shared.reset()
        self.stopServer()
    }
}
