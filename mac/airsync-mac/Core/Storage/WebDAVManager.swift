import Foundation
import Cocoa
import Combine
import Darwin

final class WebDAVManager {
    static let shared = WebDAVManager()
    private let mountPoint = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/app.androp.mac/AndroidVolume")
    private let queue = DispatchQueue(label: "app.androp.webdav", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var mountRequested = false
    private var mounted = false
    private var activeProcess: Process?
    private var accessToken: String?
    private var accessPort = 9081
    private var requestedEndpoint: (ipAddress: String, volumeName: String)?

    var isMounted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mounted
    }

    private init() {}

    /// Credentials arrive only over the authenticated device connection and stay in memory.
    /// Revocation keeps a pending user mount request so a late server-start response can retry.
    func setAccess(token: String?, port: Int = 9081) {
        let validToken = token.flatMap { value in
            value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? value : nil
        }
        guard port > 0 && port <= 65535 else { return }
        lock.lock()
        if accessToken == validToken && accessPort == port { lock.unlock(); return }
        accessToken = validToken
        accessPort = port
        generation &+= 1
        mountRequested = false
        mounted = false
        let endpoint = requestedEndpoint
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        queue.async { self.unmountSilently(); self.notifyChange() }
        if validToken != nil, let endpoint {
            mount(ipAddress: endpoint.ipAddress, port: port, volumeName: endpoint.volumeName)
        }
    }

    func mount(ipAddress: String, port: Int = 9081, volumeName: String = "Android") {
        guard port > 0 && port <= 65535 else { return }
        lock.lock()
        requestedEndpoint = (ipAddress, volumeName)
        guard let capability = accessToken, !mountRequested else { lock.unlock(); return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ipAddress
        components.port = accessPort
        components.path = "/.androp/\(capability)/"
        guard let url = components.url else { lock.unlock(); return }
        mountRequested = true
        generation &+= 1
        let token = generation
        lock.unlock()
        queue.async {
            guard self.isCurrent(token) else { return }
            self.unmountSilently()
            guard self.isCurrent(token) else { return }
            do {
                // Never remove the mount directory recursively: a stale mounted volume could
                // make that erase remote files. An empty directory is sufficient for mounting.
                try FileManager.default.createDirectory(at: self.mountPoint, withIntermediateDirectories: true)
                let succeeded = self.run("/sbin/mount_webdav", arguments: [url.absoluteString, self.mountPoint.path], timeout: 15)
                guard self.isCurrent(token) else { self.unmountSilently(); return }
                self.lock.lock()
                self.mounted = succeeded
                self.mountRequested = succeeded
                self.lock.unlock()
                self.notifyChange()
            } catch {
                self.lock.lock()
                if self.generation == token { self.mountRequested = false }
                self.lock.unlock()
                print("[webdav] Mount failed: \(error)")
            }
        }
    }

    func unmount() {
        lock.lock()
        generation &+= 1
        mountRequested = false
        mounted = false
        accessToken = nil
        requestedEndpoint = nil
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        queue.async {
            self.unmountSilently()
            self.notifyChange()
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token && mountRequested
    }

    private func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        lock.lock()
        activeProcess = process
        lock.unlock()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        lock.lock()
        if activeProcess === process { activeProcess = nil }
        lock.unlock()
        return process.terminationStatus == 0
    }

    private func unmountSilently() {
        if !run("/usr/sbin/diskutil", arguments: ["unmount", "force", mountPoint.path], timeout: 5) {
            _ = run("/sbin/umount", arguments: ["-f", mountPoint.path], timeout: 5)
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async { AppState.shared.objectWillChange.send() }
    }

    func openInFinder() {
        guard isMounted else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(self.mountPoint) }
    }
}
