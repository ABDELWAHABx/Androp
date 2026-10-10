import Foundation
import IOKit
import Darwin

/// Explicitly experimental: an accepted driver request is not proof of physical
/// closed-lid operation. The driver flag is shared with powerd and other clients.
@MainActor
final class MacClamshellController {
    static var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 &&
        FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/androp-closed-lid-helper").path)
    }
    private(set) var isActive = false
    var onStateChange: ((Bool, String?) -> Void)?
    private var desired = false
    private var generation: UInt64 = 0
    private var lastRenewal: TimeInterval = -10
    private var acknowledgementExpiry: DispatchWorkItem?
    private let worker = MacClamshellProcessWorker()

    func renew() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !desired || now - lastRenewal >= 9 else { return }
        lastRenewal = now
        if !desired {
            desired = true
            generation &+= 1
            let current = generation
            scheduleAcknowledgementExpiry(generation: current)
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/androp-closed-lid-helper")
            worker.start(executable: executable, generation: current) { [weak self] token, event in
                DispatchQueue.main.async {
                    guard let self, self.desired, token == self.generation else { return }
                    switch event {
                    case .active:
                        self.isActive = true
                        self.scheduleAcknowledgementExpiry(generation: token)
                        self.onStateChange?(true, nil)
                    case .failure(let message):
                        self.desired = false
                        self.generation &+= 1
                        self.isActive = false
                        self.acknowledgementExpiry?.cancel()
                        self.acknowledgementExpiry = nil
                        self.stopWorker(resetFallback: true)
                        self.onStateChange?(false, message)
                    }
                }
            }
        } else { worker.renew(generation: generation) }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard desired || isActive else {
            if let completion { worker.whenStopped { DispatchQueue.main.async { completion() } } }
            return
        }
        desired = false
        generation &+= 1
        lastRenewal = -10
        isActive = false
        acknowledgementExpiry?.cancel()
        acknowledgementExpiry = nil
        stopWorker(resetFallback: false)
        if let completion { worker.whenStopped { DispatchQueue.main.async { completion() } } }
        onStateChange?(false, nil)
    }

    private func scheduleAcknowledgementExpiry(generation: UInt64) {
        acknowledgementExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desired, self.generation == generation else { return }
            self.desired = false
            self.generation &+= 1
            self.isActive = false
            self.stopWorker(resetFallback: true)
            self.onStateChange?(false, "The experimental closed-lid helper didn't renew its 30-second watchdog.")
        }
        acknowledgementExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func stopWorker(resetFallback: Bool) {
        worker.stop(resetFallback: resetFallback) { [weak self] error in
            DispatchQueue.main.async {
                self?.isActive = false
                self?.onStateChange?(false, error)
            }
        }
    }
}

/// Process/pipe state stays on one utility queue; callbacks deliver only bounded
/// values to the main actor. Generation invalidation precedes queued cleanup.
nonisolated final class MacClamshellProcessWorker: @unchecked Sendable {
    enum Event: Sendable { case active, failure(String) }
    private let queue = DispatchQueue(label: "app.androp.clamshell-helper", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var callback: (@Sendable (UInt64, Event) -> Void)?
    private var flagMayBeSet = false
    private var quarantined = false

    func start(executable: URL, generation: UInt64,
               callback: @escaping @Sendable (UInt64, Event) -> Void) {
        lock.lock()
        self.generation = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(generation) else { return }
            self.callback = callback
            guard !quarantined else {
                callback(generation, .failure("Experimental closed-lid recovery couldn't be confirmed. Open the lid and sleep your Mac before restarting androp."))
                return
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                callback(generation, .failure("The experimental closed-lid helper is missing from this build."))
                return
            }
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            self.process = process
            self.input = input
            self.output = output
            self.buffer.removeAll(keepingCapacity: true)
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self?.queue.async { self?.read(data, generation: generation) }
            }
            process.terminationHandler = { [weak self] process in
                self?.queue.async {
                    guard let self, self.isCurrent(generation), self.process === process else { return }
                    self.callback?(generation, .failure("The experimental closed-lid helper stopped (\(process.terminationStatus))."))
                    self.cleanup()
                    let uncertainRestore = process.terminationReason == .uncaughtSignal || process.terminationStatus == 2
                    if self.flagMayBeSet && uncertainRestore, let error = Self.resetDriverFlag() {
                        self.quarantined = true
                        callback(generation, .failure(error))
                    }
                    self.flagMayBeSet = false
                }
            }
            do {
                // The generation lock makes run atomic with pause/stop invalidation.
                self.lock.lock()
                guard self.generation == generation else { self.lock.unlock(); self.cleanup(); return }
                do { try process.run(); self.lock.unlock() }
                catch { self.lock.unlock(); throw error }
                self.flagMayBeSet = true
                try input.fileHandleForWriting.write(contentsOf: Data("RENEW 30\n".utf8))
            } catch {
                callback(generation, .failure("Couldn't start experimental closed-lid mode: \(error.localizedDescription)"))
                // The controller queues STOP/EOF cleanup. If run failed before
                // sending RENEW, there is no driver flag to reset.
            }
        }
    }

    func renew(generation: UInt64) {
        queue.async { [self] in
            guard isCurrent(generation), let process, process.isRunning, let input else { return }
            do { try input.fileHandleForWriting.write(contentsOf: Data("RENEW 30\n".utf8)) }
            catch { callback?(generation, .failure("The experimental closed-lid helper stopped responding.")) }
        }
    }

    func stop(resetFallback: Bool, onRestoreError: @escaping @Sendable (String) -> Void) {
        lock.lock()
        generation &+= 1
        lock.unlock()
        queue.async { [self] in
            let child = process
            if let input { try? input.fileHandleForWriting.write(contentsOf: Data("STOP\n".utf8)) }
            try? input?.fileHandleForWriting.close()
            var forced = false
            if let child {
                // Keep restart work behind bounded shutdown/recovery on this
                // serial queue, so an older cleanup cannot clear a newer lease.
                Self.waitForExit(child, seconds: 1)
                if child.isRunning {
                    forced = true
                    child.terminate()
                    Self.waitForExit(child, seconds: 1)
                }
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                    Self.waitForExit(child, seconds: 1)
                }
                if child.isRunning {
                    quarantined = true
                    onRestoreError("Couldn't stop the experimental helper. Open the lid and sleep your Mac; closed-lid recovery is uncertain.")
                }
                if flagMayBeSet && !child.isRunning &&
                    (child.terminationReason == .uncaughtSignal || child.terminationStatus == 2) { forced = true }
            }
            cleanup()
            // A normal helper exit0/1 confirms its cleanup request succeeded;
            // resetting again would unnecessarily alter another client's flag.
            if flagMayBeSet && forced {
                if let error = Self.resetDriverFlag() { quarantined = true; onRestoreError(error) }
            }
            flagMayBeSet = false
        }
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func whenStopped(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    private func read(_ data: Data, generation: UInt64) {
        guard isCurrent(generation) else { return }
        buffer.append(data)
        guard buffer.count <= 16 * 1024 else {
            callback?(generation, .failure("The experimental helper returned an oversized response."))
            buffer.removeAll()
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: 0..<end)
            buffer.removeSubrange(0...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let state = message["state"] as? String else {
                callback?(generation, .failure("The experimental helper returned an invalid response."))
                return
            }
            if let attempted = message["mutationAttempted"] as? Bool { flagMayBeSet = attempted }
            switch state {
            case "active":
                guard let lease = message["leaseSeconds"] as? Int, (1...30).contains(lease),
                      message["experimental"] as? Bool == true,
                      message["verification"] as? String == "requestAccepted",
                      message["mutationAttempted"] as? Bool == true else {
                    callback?(generation, .failure("The experimental helper didn't confirm its watchdog."))
                    return
                }
                callback?(generation, .active)
            case "inactive":
                callback?(generation, .failure("Experimental closed-lid mode stopped: \(String((message["reason"] as? String ?? "inactive").prefix(240)))"))
            case "error":
                callback?(generation, .failure(String((message["message"] as? String ?? "Experimental closed-lid mode was rejected.").prefix(320))))
            default:
                callback?(generation, .failure("The experimental helper returned an unknown state."))
            }
        }
    }

    private func cleanup() {
        process?.terminationHandler = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        callback = nil
    }

    private static func resetDriverFlag() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return "Couldn't find the power service to restore normal lid sleep. Open the lid and sleep your Mac." }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == kIOReturnSuccess else { return "Couldn't restore normal lid sleep (\(opened)). Open the lid and sleep your Mac." }
        defer { IOServiceClose(connection) }
        var value: UInt64 = 0
        let result = IOConnectCallScalarMethod(connection, 12, &value, 1, nil, nil)
        return result == kIOReturnSuccess ? nil : "Normal lid-sleep recovery wasn't confirmed (\(result)). Open the lid and sleep your Mac."
    }
}
