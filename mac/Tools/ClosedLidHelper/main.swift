import Foundation
import Dispatch
import Darwin
import IOKit
import IOKit.ps

// Experimental macOS 15 interface, verified against Apple's xnu-11215.1.10
// IOPMLibDefs.h / RootDomainUserClient.cpp. This is NOT a public sleep assertion.
private let clamshellSleepSelector: UInt32 = 12
private let maximumLease: TimeInterval = 30

private func parentHasSameUser(_ pid: pid_t) -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = query.withUnsafeMutableBufferPointer {
        sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
    }
    return result == 0 && size == MemoryLayout<kinfo_proc>.size &&
        info.kp_eproc.e_ucred.cr_uid == getuid()
}

private func parentPID() -> pid_t? {
    let args = CommandLine.arguments
    guard args.count == 3, args[1] == "--parent-pid", let pid = Int32(args[2]),
          pid > 1, pid == getppid(), getuid() != 0, getuid() == geteuid(),
          parentHasSameUser(pid) else { return nil }
    return pid
}

private final class ClosedLidWatchdog {
    private let queue = DispatchQueue(label: "app.androp.closed-lid-watchdog")
    private let parent: pid_t
    private var connection: io_connect_t = 0
    private var attemptedEnable = false
    private var active = false
    private var deadline: TimeInterval = 0
    private var expiry: DispatchSourceTimer?
    private var powerChecks: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []

    init(parent: pid_t) { self.parent = parent }

    func run() -> Never {
        // A lost stdout reader must never SIGPIPE-kill the process before restore.
        signal(SIGPIPE, SIG_IGN)
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        if flags >= 0 { _ = fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.finish("signal", exitCode: 0) }
            source.resume()
            signals.append(source)
        }
        queue.async {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 else {
                self.fail("Experimental closed-lid mode is limited to macOS 15.")
                return
            }
            // A child that receives no explicit lease must not linger indefinitely.
            self.scheduleExpiry(after: 5, reason: "No activation request")
        }
        DispatchQueue.global(qos: .utility).async { self.readCommands() }
        dispatchMain()
    }

    private func readCommands() {
        var buffer = [UInt8](repeating: 0, count: 256)
        var line = [UInt8]()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count == 0 { queue.sync { finish("Parent disconnected", exitCode: 0) } }
            if count < 0 {
                if errno == EINTR { continue }
                queue.sync { fail("Couldn't read the parent control pipe.") }
            }
            for byte in buffer.prefix(max(0, count)) {
                if byte == 10 {
                    let command = String(bytes: line, encoding: .utf8)
                    line.removeAll(keepingCapacity: true)
                    // Synchronous delivery bounds queued commands even if a caller
                    // writes faster than the IOKit driver can process requests.
                    queue.sync { handle(command) }
                } else {
                    guard byte >= 32 && byte <= 126, line.count < 128 else {
                        queue.sync { fail("Invalid or oversized control command.") }
                        return
                    }
                    line.append(byte)
                }
            }
        }
    }

    private func handle(_ command: String?) {
        guard parent == getppid(), parentHasSameUser(parent), kill(parent, 0) == 0 else {
            finish("Parent exited", exitCode: 0)
        }
        if command == "STOP" { finish("Stopped", exitCode: 0) }
        guard let parts = command?.split(separator: " "), parts.count == 2,
              parts[0] == "RENEW", let seconds = Int(parts[1]), seconds >= 1,
              seconds <= Int(maximumLease) else {
            fail("Expected RENEW with a lease of 1 to 30 seconds, or STOP.")
            return
        }
        if let reason = powerGuardFailure() { fail(reason); return }
        if !attemptedEnable {
            // This is shared with powerd, not a client-owned assertion. Refuse
            // to clear an override that was already present before we started.
            guard readClamshellCausesSleep() == true else {
                fail("Another closed-lid configuration is active, or its state is unknown.")
                return
            }
        }
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard service != 0 else { fail("macOS power service is unavailable."); return }
            let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
            IOObjectRelease(service)
            guard result == kIOReturnSuccess, connection != 0 else {
                fail("macOS declined access to its power service.", code: result)
                return
            }
        }
        // Reapply only at explicit renewals; powerd can independently alter the
        // shared flag. A success result proves request acceptance, not lid behavior.
        attemptedEnable = true
        let result = setClamshellDisabled(true)
        guard result == kIOReturnSuccess else {
            fail("macOS rejected the experimental lid request.", code: result)
            return
        }
        active = true
        deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(seconds)
        scheduleExpiry(after: TimeInterval(seconds), reason: "Lease expired")
        startPowerChecks()
        var acknowledgement: [String: Any] = ["state": "active", "leaseSeconds": seconds,
            "experimental": true, "verification": "requestAccepted", "mutationAttempted": true]
        if let observed = readClamshellCausesSleep() { acknowledgement["observedCausesSleep"] = observed }
        emit(acknowledgement)
    }

    private func powerGuardFailure() -> String? {
        guard parent == getppid(), parentHasSameUser(parent), kill(parent, 0) == 0 else { return "Parent exited" }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious && thermal != .critical else { return "Mac temperature is too high" }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return "Couldn't verify battery level"
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { return "Couldn't verify battery level" }
            guard current.doubleValue / maximum.doubleValue > 0.2 else { return "Mac battery is at or below 20%" }
            return nil
        }
        return "No internal battery found"
    }

    private func startPowerChecks() {
        guard powerChecks == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            if ProcessInfo.processInfo.systemUptime >= self.deadline { self.finish("Lease expired", exitCode: 0) }
            if let reason = self.powerGuardFailure() { self.fail(reason) }
        }
        timer.resume()
        powerChecks = timer
    }

    private func scheduleExpiry(after seconds: TimeInterval, reason: String) {
        expiry?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.finish(reason, exitCode: 0) }
        timer.resume()
        expiry = timer
    }

    private func setClamshellDisabled(_ disabled: Bool) -> IOReturn {
        var input: UInt64 = disabled ? 1 : 0
        var outputCount: UInt32 = 0
        return IOConnectCallScalarMethod(connection, clamshellSleepSelector, &input, 1, nil, &outputCount)
    }

    private func readClamshellCausesSleep() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellCausesSleep" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func emit(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let frame = data + Data([10])
        let written = frame.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        // The event is well below PIPE_BUF. A blocked/full/broken parent pipe
        // must cause restoration rather than block the watchdog's serial queue.
        if written != frame.count { finish("Parent output unavailable", exitCode: 1, emitStatus: false) }
    }

    private func fail(_ message: String, code: IOReturn? = nil) -> Never {
        var frame: [String: Any] = ["state": "error", "message": message,
            "mutationAttempted": attemptedEnable]
        if let code { frame["code"] = Int64(code) }
        emit(frame)
        finish(message, exitCode: 1)
    }

    private func finish(_ reason: String, exitCode: Int32, emitStatus: Bool = true) -> Never {
        expiry?.cancel()
        powerChecks?.cancel()
        active = false
        let neededRestore = attemptedEnable
        var restored = true
        if attemptedEnable && connection != 0 { restored = setClamshellDisabled(false) == kIOReturnSuccess }
        attemptedEnable = false
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        if emitStatus {
            // No recursive failure path during shutdown; the parent will perform
            // its own selector-12 / value-zero fallback when restoration was not confirmed.
            var value: [String: Any] = ["state": "inactive", "reason": reason, "restored": restored,
                "mutationAttempted": neededRestore,
                "restorationVerification": neededRestore ? "requestAccepted" : "notNeeded"]
            if let observed = readClamshellCausesSleep() { value["observedCausesSleep"] = observed }
            if let data = try? JSONSerialization.data(withJSONObject: value) {
                let frame = data + Data([10])
                _ = frame.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            }
        }
        exit(restored ? exitCode : 2)
    }
}

guard let expectedParent = parentPID() else {
    let data = Data("{\"state\":\"error\",\"message\":\"Launch from androp as the same non-root user.\",\"mutationAttempted\":false}\n".utf8)
    _ = data.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    exit(1)
}
ClosedLidWatchdog(parent: expectedParent).run()
