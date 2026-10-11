//
//  MacRemoteManager.swift
//  airsync-mac
//
//  Created by AirSync on 2026-01-10.
//

import Foundation
import Cocoa
import Carbon
import AudioToolbox
import CoreGraphics
import Combine

class MacRemoteManager: ObservableObject {
    static let shared = MacRemoteManager()
    
    @Published var lastVolumeLevel: Int = 0
    private var volumeCheckTimer: Timer?
    private var cachedScreenHeight: CGFloat = 1080
    private var isMonitoring = false
    
    // Key codes
    enum Key: Int {
        case leftArrow = 123
        case rightArrow = 124
        case downArrow = 125
        case upArrow = 126
        case space = 49
        case enter = 36
        case escape = 53
    }
    
    // Media keys (System defined)
    enum MediaKey: Int32 {
        case playPause = 16 // NX_KEYTYPE_PLAY
        case next = 19     // NX_KEYTYPE_NEXT
        case previous = 20 // NX_KEYTYPE_PREVIOUS
        case fast = 17     // NX_KEYTYPE_FAST
        case rewind = 18   // NX_KEYTYPE_REWIND
        case soundUp = 0   // NX_KEYTYPE_SOUND_UP
        case soundDown = 1 // NX_KEYTYPE_SOUND_DOWN
        case mute = 7      // NX_KEYTYPE_MUTE
        case brightnessUp = 2   // NX_KEYTYPE_BRIGHTNESS_UP
        case brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    }
    
    private init() {
        // Initialize last known volume
        self.lastVolumeLevel = getVolume()
        self.cachedScreenHeight = NSScreen.main?.frame.height ?? 1080
    }
    
    deinit {
        stopVolumeMonitoring()
    }
    
    // MARK: - Permissions
    
    func isAccessibilityTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private var lastTrustCheck: TimeInterval = 0
    private var reportedTrust: Bool?
    private var promptedForTrust = false
    private var accessibilityObserver: NSObjectProtocol?
    private var deviceObserver: AnyCancellable?
    private var untrustedPoll: Timer?

    /// Tell the phone the moment Accessibility is granted or revoked. Before, the Mac only
    /// re-checked when remote input arrived, so the phone kept saying "allow androp in
    /// Accessibility" after you had. Also re-sent whenever a phone connects.
    func startTrustMonitoring() {
        guard accessibilityObserver == nil else { return }
        // macOS posts this whenever the Accessibility list changes; trust updates just after.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.publishTrust(force: false) }
        }
        deviceObserver = AppState.shared.$device
            .map { $0?.deviceId }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in if id != nil { self?.publishTrust(force: true) } }
    }

    /// Sends the current state when it changed (or always with [force]). While untrusted, polls
    /// every two seconds as well, since the notification isn't posted on every macOS version.
    func publishTrust(force: Bool) {
        let trusted = isAccessibilityTrusted()
        lastTrustCheck = ProcessInfo.processInfo.systemUptime
        if force || trusted != reportedTrust {
            reportedTrust = trusted
            WebSocketServer.shared.sendRemoteControlStatus(inputAllowed: trusted)
        }
        if trusted {
            untrustedPoll?.invalidate()
            untrustedPoll = nil
        } else if untrustedPoll == nil {
            untrustedPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishTrust(force: false) }
            }
        }
    }

    /// Private builds are ad-hoc signed, so every update is a new app to macOS: Accessibility can
    /// show androp switched on while not trusting this build, and switching it on again changes
    /// nothing. Removing the stale entry and asking again fixes it; the app can't edit the list.
    func resetAccessibilityPermission(completion: @escaping (Bool) -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.androp.mac"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            var reset = false
            if (try? process.run()) != nil {
                process.waitUntilExit()
                reset = process.terminationStatus == 0
            }
            DispatchQueue.main.async {
                self.requestAccessibilityPermission()
                self.publishTrust(force: true)
                completion(reset)
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Called before synthetic input. Without Accessibility macOS drops every
    /// event silently, so ask once and tell the phone, instead of failing quietly.
    /// The check is cheap but still rate-limited for 60 Hz pointer streams.
    func ensureInputAllowed() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTrustCheck < (reportedTrust == true ? 10 : 1) { return }
        lastTrustCheck = now
        let trusted = isAccessibilityTrusted()
        // Repeat "not allowed" (at most once a second) so a reconnected phone
        // still learns why input is ignored; "allowed" is sent once per change.
        if trusted != reportedTrust || !trusted {
            reportedTrust = trusted
            WebSocketServer.shared.sendRemoteControlStatus(inputAllowed: trusted)
        }
        // Watch for the grant so the phone hears about it without another touch.
        if !trusted { DispatchQueue.main.async { self.publishTrust(force: false) } }
        if !trusted && !promptedForTrust {
            promptedForTrust = true
            DispatchQueue.main.async { self.requestAccessibilityPermission() }
        }
    }

    /// Current pointer location in global CoreGraphics coordinates (top-left of
    /// the primary display), correct on every display arrangement.
    private func currentPointer() -> CGPoint {
        if let location = CGEvent(source: nil)?.location { return location }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cachedScreenHeight
        return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    }

    /// Keep the cursor on a connected display so a large swipe cannot park it off-screen.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return point }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return point }
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        guard let nearest = bounds.min(by: { distance(point, $0) < distance(point, $1) }) else { return point }
        return CGPoint(x: min(max(point.x, nearest.minX), nearest.maxX - 1),
                       y: min(max(point.y, nearest.minY), nearest.maxY - 1))
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private var heldButton: CGMouseButton?
    private var lastPointerInput: TimeInterval = 0

    /// A lost button-up (disconnect mid-drag) must not leave the Mac dragging forever.
    private func releaseStaleButton(now: TimeInterval) {
        guard let button = heldButton, now - lastPointerInput > 3 else { return }
        heldButton = nil
        let type: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentPointer(), mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    func lockScreen() {
        let libPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(libPath, RTLD_NOW) {
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                let lockFunc = unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
                lockFunc()
            }
            dlclose(handle)
        } else {
            // Fallback to keyboard shortcut if dlopen fails (unlikely)
            executeAppleScript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
        }
    }

    func startScreensaver() {
        // Start the screensaver engine
        executeAppleScript("do shell script \"open -a ScreenSaverEngine\"")
    }
    
    // MARK: - Input Simulation
    
    func simulateMouseRelativeMove(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite, abs(dx) <= 1_000_000, abs(dy) <= 1_000_000 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        releaseStaleButton(now: now)
        lastPointerInput = now
        let current = currentPointer()
        let newPos = clampToDisplays(CGPoint(x: current.x + dx, y: current.y + dy))
        // While a button is held the move is a drag, so windows and selections follow.
        let type: CGEventType
        switch heldButton {
        case .left?: type = .leftMouseDragged
        case .right?: type = .rightMouseDragged
        case .center?: type = .otherMouseDragged
        default: type = .mouseMoved
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: newPos,
                               mouseButton: heldButton ?? .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private var lastClick: (button: CGMouseButton, time: TimeInterval, count: Int64)?

    func simulateMouseClick(button: CGMouseButton, isDown: Bool) {
        let currentPos = currentPointer()
        let mouseType: CGEventType
        switch button {
        case .left: mouseType = isDown ? .leftMouseDown : .leftMouseUp
        case .right: mouseType = isDown ? .rightMouseDown : .rightMouseUp
        case .center: mouseType = isDown ? .otherMouseDown : .otherMouseUp
        @unknown default: return
        }
        // Report double-clicks so Finder opens files and text selects words.
        let now = ProcessInfo.processInfo.systemUptime
        lastPointerInput = now
        var clickCount: Int64 = 1
        if isDown {
            if let last = lastClick, last.button == button, now - last.time < NSEvent.doubleClickInterval {
                clickCount = min(last.count + 1, 3)
            }
            lastClick = (button, now, clickCount)
            heldButton = button
        } else {
            clickCount = lastClick?.count ?? 1
            if heldButton == button { heldButton = nil }
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: currentPos, mouseButton: button) {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event.post(tap: .cghidEventTap)
        }
    }

    func simulateMouseScroll(dx: CGFloat, dy: Double) {
        // wheel1 is vertical, wheel2 is horizontal
        guard let vertical = MacRemoteInputPolicy.scrollDelta(dy),
              let horizontal = MacRemoteInputPolicy.scrollDelta(Double(dx)) else { return }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: vertical, wheel2: horizontal, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    func simulateKeyCode(_ code: Int, modifiers: [String] = []) {
        guard let code = MacRemoteInputPolicy.keyCode(code) else { return }
        let flags = parseModifiers(modifiers)
        let src: CGEventSource? = nil // Better compatibility for system shortcuts
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false)
        
        keyDown?.flags = flags
        keyUp?.flags = flags
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    func simulateText(_ text: String, modifiers: [String] = []) {
        let flags = parseModifiers(modifiers)
        let src: CGEventSource? = nil
        
        for char in text {
            // Create a blank event
            if let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                var charCode = Array(String(char).utf16)
                event.keyboardSetUnicodeString(stringLength: charCode.count, unicodeString: &charCode)
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
            
             if let eventUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                 eventUp.flags = flags
                 eventUp.post(tap: .cghidEventTap)
             }
        }
    }
    
    private func parseModifiers(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod.lowercased() {
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "command", "cmd": flags.insert(.maskCommand)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        if !modifiers.isEmpty {
            print("[MacRemoteManager] Active modifiers: \(modifiers) -> flags: \(flags.rawValue)")
        }
        return flags
    }
    
    // Traditional toggle removed in favor of real-time setModifierState

    func simulateKey(_ key: Key) {
        simulateKeyCode(key.rawValue)
    }
    
    func simulateMediaKey(_ key: MediaKey) {
        func doKey(down: Bool) {
            let performVal = Int((key.rawValue << 16) | (down ? 0xa00 : 0xb00))
            
            if let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: .init(rawValue: 0xa00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: performVal,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        
        doKey(down: true)
        doKey(down: false)
    }
    
    // MARK: - Volume Control
    
    func setVolume(_ percent: Int) {
        let constrained = max(0, min(100, percent))
        setSystemVolume(Float(constrained) / 100.0)
        
        // Update local state immediately for responsiveness
        self.lastVolumeLevel = constrained
        notifyVolumeChange()
    }
    
    func getVolume() -> Int {
        let vol = getSystemVolume()
        return MacRemoteInputPolicy.volumePercent(vol)
    }
    
    func increaseVolume() {
        // Using media keys gives visual feedback (OSD)
        simulateMediaKey(.soundUp)
        // Update tracking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.lastVolumeLevel = self.getVolume()
            self.notifyVolumeChange()
        }
    }
    
    func decreaseVolume() {
        simulateMediaKey(.soundDown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.lastVolumeLevel = self.getVolume()
            self.notifyVolumeChange()
        }
    }
    
    func toggleMute() {
        simulateMediaKey(.mute)
    }

    func increaseBrightness() {
        let current = getSystemBrightness()
        let newLevel = min(1.0, current + 0.0625)
        setSystemBrightness(newLevel)
        print("[MacRemoteManager] Increasing brightness to \(newLevel)")
    }

    func decreaseBrightness() {
        let current = getSystemBrightness()
        let newLevel = max(0.0, current - 0.0625)
        setSystemBrightness(newLevel)
        print("[MacRemoteManager] Decreasing brightness to \(newLevel)")
    }
    
    // MARK: - CoreAudio Implementation
    
    private func getSystemBrightness() -> Float {
        let libPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(libPath, RTLD_NOW) else { return 0.5 }
        defer { dlclose(handle) }
        
        typealias GetBrightnessPtr = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
            let getBrightness = unsafeBitCast(sym, to: GetBrightnessPtr.self)
            var brightness: Float = 0
            let result = getBrightness(CGMainDisplayID(), &brightness)
            if result == 0 {
                return brightness
            }
        }
        return 0.5
    }

    private func setSystemBrightness(_ level: Float) {
        let libPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(libPath, RTLD_NOW) else { return }
        defer { dlclose(handle) }
        
        typealias SetBrightnessPtr = @convention(c) (CGDirectDisplayID, Float) -> Int32
        if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
            let setBrightness = unsafeBitCast(sym, to: SetBrightnessPtr.self)
            let newLevel = max(0.0, min(1.0, level))
            _ = setBrightness(CGMainDisplayID(), newLevel)
        }
    }
    
    private func getSystemVolume() -> Float {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var defaultOutputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
        
        var getDefaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &getDefaultOutputDevicePropertyAddress,
            0,
            nil,
            &defaultOutputDeviceIDSize,
            &defaultOutputDeviceID
        )
        
        guard status1 == noErr else { return 0.0 }
        
        var volume = Float32(0.0)
        var volumeSize = UInt32(MemoryLayout.size(ofValue: volume))
        
        var volumePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status2 = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &volumePropertyAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )
        
        if status2 == noErr {
            return volume
        } else {
            return 0.0
        }
    }
    
    private func setSystemVolume(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var defaultOutputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
        
        var getDefaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &getDefaultOutputDevicePropertyAddress,
            0,
            nil,
            &defaultOutputDeviceIDSize,
            &defaultOutputDeviceID
        )
        
        guard status1 == noErr else { return }
        
        var volumeToSet = Float32(volume)
        let volumeSize = UInt32(MemoryLayout.size(ofValue: volumeToSet))
        
        var volumePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &volumePropertyAddress,
            0,
            nil,
            volumeSize,
            &volumeToSet
        )
    }
    
    // MARK: - Monitoring & Sync
    
    func startVolumeMonitoring() {
        guard !isMonitoring, !AppState.shared.isSyncPaused else { return }
        isMonitoring = true
        print("[MacRemoteManager] Starting volume monitoring")
        
        checkVolumeChange()
        
        // Start timer
        volumeCheckTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: true) { [weak self] _ in
            self?.checkVolumeChange()
        }
        volumeCheckTimer?.tolerance = 1.5
    }
    
    func stopVolumeMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        print("[MacRemoteManager] Stopping volume monitoring")
        
        volumeCheckTimer?.invalidate()
        volumeCheckTimer = nil
    }
    
    private func checkVolumeChange() {
        let current = getVolume()
        if current != lastVolumeLevel {
            lastVolumeLevel = current
            notifyVolumeChange()
        }
    }
    
    private func notifyVolumeChange() {
        DispatchQueue.main.async {
            // Send update via WebSocket
            let levelInt = self.lastVolumeLevel
            print("[MacRemoteManager] Notifying volume change: \(levelInt)%")
            WebSocketServer.shared.sendMacVolumeUpdate(level: levelInt)
        }
    }
    
    // MARK: - Helpers
    
    @discardableResult
    private func executeAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let output = script.executeAndReturnError(&error)
            if let err = error {
                print("AppleScript error: \(err)")
                return nil
            }
            return output.stringValue
        }
        return nil
    }
}
