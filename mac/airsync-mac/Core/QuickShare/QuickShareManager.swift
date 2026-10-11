//
//  QuickShareManager.swift
//  AirSync
//

import Foundation
import AppKit
import SwiftUI
import UserNotifications
@preconcurrency import Combine
import UniformTypeIdentifiers

struct QuickShareTransferInfo {
    let device: RemoteDeviceInfo
    let transfer: TransferMetadata
}

@MainActor
public class QuickShareManager: NSObject, ObservableObject, MainAppDelegate, ShareExtensionDelegate {
    public static let shared = QuickShareManager()
    @Published public var isEnabled: Bool = UserDefaults.standard.object(forKey: "quickShareEnabled") == nil
        ? true : UserDefaults.standard.bool(forKey: "quickShareEnabled") {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "quickShareEnabled")
            if isEnabled {
                startService()
            } else {
                stopService()
            }
        }
    }
    
    @Published public var isRunning: Bool = false
    @Published public var discoveredDevices: [RemoteDeviceInfo] = []
    @Published public var transferState: TransferState = .idle
    @Published public var transferProgress: Double = 0
    @Published public var lastPinCode: String?
    @Published public var transferURLs: [URL] = []
    @Published public var autoTargetDeviceName: String?
    @Published public var selectedFileSize: Int64 = 0
    @Published public var dropFeedback: String?
    @Published public var sendingFileName: String?
    @Published public var sendingDeviceName: String?
    private var preparedDeviceID: String?
    private var preparedPairingToken: String?
    private var preparedFileSizes: [Int64] = []
    private var preparedDeviceName: String?
    private var wsTransferID: String?
    private var fileSendGeneration: UInt64 = 0
    private var transferNetworkLease: UUID?
    private var preparedNextFileIndex = 0
    private var preparedCompletedBytes: Int64 = 0
    
    public enum TransferState: Equatable {
        case idle
        case preparing(String)
        case reviewing(String)
        case connectingNetwork(String) // paired device name
        case discovering
        case connecting(String) // deviceID
        case awaitingPin(String, String) // pin, deviceID
        case sending(String) // deviceID
        case receiving(String) // transferID
        case incomingAwaitingConsent(TransferMetadata, RemoteDeviceInfo)
        case finished
        case failed(String)
    }
    
    private var resetGeneration: UInt64 = 0
    private var suspended = false
    private var discovering = false
    private var activeIncomingTransfers: [String: QuickShareTransferInfo] = [:]
    
    override private init() {
        super.init()
        NearbyConnectionManager.shared.mainAppDelegate = self
        if isEnabled {
            startService()
        }
    }
    
    public var deviceName: String {
        return UserDefaults.standard.string(forKey: "deviceName") ?? Host.current().localizedName ?? "Mac"
    }
    
    // MARK: - Lifecycle
    
    public func startService() {
        guard isEnabled && !AppState.shared.isSyncPaused && !suspended && !isRunning else { return }
        registerNotificationCategories()
        NearbyConnectionManager.shared.mainAppDelegate = self
        NearbyConnectionManager.shared.becomeVisible()
        isRunning = true
        print("[quickshare] Service started — visible as '\(deviceName)'")
    }
    
    public func stopService() {
        isRunning = false
        stopDiscovery()
        NearbyConnectionManager.shared.stopVisibility()
        let notifications = activeIncomingTransfers.keys.map { "transfer_" + $0 }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notifications)
        activeIncomingTransfers.removeAll()
        print("[quickshare] Service stopped")
    }
    
    public func suspendService() {
        suspended = true
        stopService()
    }

    public func resumeService() {
        suspended = false
        if isEnabled { startService() }
    }

    private func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        let acceptAction = UNNotificationAction(
            identifier: "QUICKSHARE_ACCEPT",
            title: Localizer.shared.text("quickshare.accept"),
            options: .authenticationRequired
        )
        let declineAction = UNNotificationAction(
            identifier: "QUICKSHARE_DECLINE",
            title: Localizer.shared.text("quickshare.decline")
        )
        let incomingCategory = UNNotificationCategory(
            identifier: "INCOMING_TRANSFERS",
            actions: [acceptAction, declineAction],
            intentIdentifiers: []
        )
        NotificationCategoryRegistry.shared.register(incomingCategory)
    }
    
    // MARK: - Outbound Discovery
    
    public func startDiscovery(autoTargetName: String? = nil) {
        guard !AppState.shared.isSyncPaused && !suspended && isEnabled else { return }
        if discovering {
            self.autoTargetDeviceName = autoTargetName
            return
        }
        discovering = true
        discoveredDevices.removeAll()
        self.autoTargetDeviceName = autoTargetName
        transferState = .discovering
        NearbyConnectionManager.shared.addShareExtensionDelegate(self)
        NearbyConnectionManager.shared.startDeviceDiscovery()
        
        // Trigger Quick Share mode on any connected AirSync device
        WebSocketServer.shared.sendQuickShareTrigger()
    }
    
    public func stopDiscovery() {
        if discovering { NearbyConnectionManager.shared.stopDeviceDiscovery() }
        discovering = false
        NearbyConnectionManager.shared.removeShareExtensionDelegate(self)
        discoveredDevices.removeAll()
        self.autoTargetDeviceName = nil
        
        switch transferState {
        case .preparing, .reviewing, .connectingNetwork, .discovering, .connecting, .awaitingPin, .sending, .receiving, .incomingAwaitingConsent:
            cancelActiveTransfer()
        default:
            break
        }
    }

    public func cancelActiveTransfer() {
        fileSendGeneration &+= 1
        releaseTransferNetwork(cancelled: true)
        if let id = wsTransferID {
            wsTransferID = nil
            WebSocketServer.shared.cancelFileTransfer(id: id, notifyRemote: true)
            transferState = .idle
            AppState.shared.showingQuickShareTransfer = false
            return
        }
        switch transferState {
        case .connecting(let id), .awaitingPin(_, let id), .sending(let id):
            NearbyConnectionManager.shared.cancelOutgoingTransfer(id: id)
            transferState = .idle
            AppState.shared.showingQuickShareTransfer = false
        case .receiving(let id):
            activeIncomingTransfers.removeValue(forKey: id)
            NearbyConnectionManager.shared.cancelIncomingTransfer(id: id)
            transferState = .idle
            AppState.shared.showingQuickShareTransfer = false
        case let .incomingAwaitingConsent(meta, _):
            activeIncomingTransfers.removeValue(forKey: meta.id)
            NearbyConnectionManager.shared.cancelIncomingTransfer(id: meta.id)
            transferState = .idle
            AppState.shared.showingQuickShareTransfer = false
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_" + meta.id])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["transfer_" + meta.id])
        default:
            transferState = .idle
            AppState.shared.showingQuickShareTransfer = false
        }
    }

    public var canPrepareFiles: Bool {
        switch transferState {
        case .idle, .reviewing, .failed, .finished: return true
        default: return false
        }
    }

    public func chooseFilesForConnectedDevice() {
        let panel = NSOpenPanel()
        panel.title = "Send files to your phone"
        panel.prompt = "Choose files"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK { self.prepareFilesForConnectedDevice(panel.urls) }
        }
    }

    public func presentFileError(_ message: String) {
        dropFeedback = message
        guard canPrepareFiles else { return }
        transferState = .failed(message)
        AppState.shared.showingQuickShareTransfer = true
    }

    /// One entry point for every drop, Dock, Services and menu-bar send: with a phone
    /// connected the files go straight to it (no picker, no review step), like AirDrop to
    /// a contact. Option, or no connected phone, opens nearby-device discovery instead.
    public func send(_ urls: [URL], pickDevice: Bool = false) {
        guard !urls.isEmpty, !AppState.shared.isSyncPaused else { return }
        if !pickDevice, AppState.shared.device != nil {
            prepareFilesForConnectedDevice(urls, sendImmediately: true)
        } else {
            transferURLs = urls
            startDiscovery(autoTargetName: nil)
            AppState.shared.showingQuickShareTransfer = true
        }
    }

    public func prepareFilesForConnectedDevice(_ urls: [URL], sendImmediately: Bool = false) {
        guard canPrepareFiles else {
            dropFeedback = "Finish or cancel the current transfer before adding files."
            return
        }
        guard !AppState.shared.isSyncPaused else { presentFileError("Resume androp before sending files."); return }
        guard let device = AppState.shared.device else {
            presentFileError("Connect your Android phone to androp, then drop the files again."); return
        }
        guard !urls.isEmpty else { presentFileError("Choose one or more files to send."); return }
        fileSendGeneration &+= 1
        resetGeneration &+= 1
        let generation = fileSendGeneration
        dropFeedback = nil
        transferURLs = []
        preparedFileSizes = []
        preparedNextFileIndex = 0
        preparedCompletedBytes = 0
        selectedFileSize = 0
        preparedDeviceID = device.deviceId
        preparedPairingToken = UserDefaults.standard.string(forKey: "bleAuthToken")
        preparedDeviceName = device.name
        transferState = .preparing(device.name)
        AppState.shared.showingQuickShareTransfer = true
        DispatchQueue.global(qos: .utility).async {
            var validated: [URL] = []
            var sizes: [Int64] = []
            var seen: Set<URL> = []
            var bytes: Int64 = 0
            var failure: String?
            for url in urls {
                guard url.isFileURL else { failure = "Drop files from Finder. Web links cannot be sent as files."; break }
                guard !url.lastPathComponent.contains("\\"), url.lastPathComponent.utf16.count <= 255 else {
                    failure = "Rename \(url.lastPathComponent) to remove backslashes or shorten its name before sending."; break
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    guard values.isRegularFile == true else {
                        failure = "\(url.lastPathComponent) is a folder or unsupported item. Compress it in Finder, then send the ZIP file."
                        break
                    }
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        failure = "Couldn't read \(url.lastPathComponent). Choose it again in Finder."; break
                    }
                    let canonical = url.standardizedFileURL
                    if !seen.insert(canonical).inserted { continue }
                    let result = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                    guard !result.overflow else { failure = "The selected files are too large."; break }
                    bytes = result.partialValue
                    validated.append(url)
                    sizes.append(Int64(values.fileSize ?? 0))
                } catch { failure = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"; break }
            }
            DispatchQueue.main.async {
                guard self.fileSendGeneration == generation else { return }
                if let failure { self.transferState = .failed(failure); return }
                guard !AppState.shared.isSyncPaused else {
                    self.transferState = .failed("Resume androp before sending files."); return
                }
                // A Wi-Fi handoff can temporarily remove the phone. Keep the
                // selection; the send gate checks the original paired identity.
                self.transferURLs = validated
                self.preparedFileSizes = sizes
                self.selectedFileSize = bytes
                self.transferState = .reviewing(device.name)
                if sendImmediately && self.canSendPreparedFiles { self.sendPreparedFiles() }
            }
        }
    }

    /// Send can establish a fast link from the authenticated BLE connection.
    /// Actual file bytes still require a verified network session below.
    public var canSendPreparedFiles: Bool {
        FileTransferRoutePolicy.mayBegin(
            preparedDeviceID: preparedDeviceID,
            currentDeviceID: AppState.shared.device?.deviceId,
            preparedPairingToken: preparedPairingToken,
            currentPairingToken: UserDefaults.standard.string(forKey: "bleAuthToken"),
            networkConnected: AppState.shared.device?.isRegularConnection == true,
            bluetoothAuthenticated: BLECentralManager.shared.isAuthenticated,
            paused: AppState.shared.isSyncPaused)
    }

    private var canStreamPreparedFiles: Bool {
        guard let lease = transferNetworkLease,
              TransferNetworkCoordinator.shared.isActiveLease(id: lease) else { return false }
        return FileTransferRoutePolicy.maySend(
            preparedDeviceID: preparedDeviceID,
            currentDeviceID: AppState.shared.device?.deviceId,
            preparedPairingToken: preparedPairingToken,
            currentPairingToken: UserDefaults.standard.string(forKey: "bleAuthToken"),
            networkConnected: AppState.shared.device?.isRegularConnection == true,
            paused: AppState.shared.isSyncPaused)
    }

    public var canReviewPreparedFiles: Bool {
        preparedDeviceID != nil && !transferURLs.isEmpty && preparedFileSizes.count == transferURLs.count
    }

    public var completedPreparedFileCount: Int { preparedNextFileIndex }

    public func reviewPreparedFiles() {
        guard case .failed = transferState, canReviewPreparedFiles else { return }
        dropFeedback = nil
        transferState = .reviewing(preparedDeviceName ?? "your phone")
    }

    public func sendPreparedFiles() {
        guard case .reviewing = transferState, !transferURLs.isEmpty else { return }
        guard canSendPreparedFiles, let targetID = preparedDeviceID else {
            dropFeedback = "Reconnect the same paired phone, then try Send again. Your selected files are still here."
            return
        }
        fileSendGeneration &+= 1
        let generation = fileSendGeneration
        let files = transferURLs
        dropFeedback = nil
        transferProgress = 0
        sendingFileName = nil
        sendingDeviceName = preparedDeviceName
        transferState = .connectingNetwork(preparedDeviceName ?? "your phone")
        transferNetworkLease = TransferNetworkCoordinator.shared.ensureNetwork(
            deviceID: targetID, pairingToken: preparedPairingToken) { [weak self] result in
                // The coordinator can complete immediately on existing Wi-Fi.
                // Defer until its lease has been assigned, and consume once.
                Task { @MainActor in
                    guard let self, self.fileSendGeneration == generation else { return }
                    guard case .connectingNetwork = self.transferState else {
                        // A disconnect resets the UI without releasing this lease. Release
                        // the coordinator's reference so stale state cannot block later
                        // Quick Share consent, and so any connected Wi-Fi is torn down.
                        self.releaseTransferNetwork()
                        return
                    }
                    switch result {
                    case .success:
                        guard self.canStreamPreparedFiles else {
                            self.failPreparedTransfer("The paired phone changed before sending. Reconnect the original phone and try again.")
                            return
                        }
                        self.transferState = .sending(targetID)
                        self.sendPreparedFile(files, index: self.preparedNextFileIndex,
                            completedBytes: self.preparedCompletedBytes, targetID: targetID, generation: generation)
                    case .failure(let error):
                        self.failPreparedTransfer(error.localizedDescription)
                    }
                }
            }
    }

    /// The coordinator calls this after revoking a connected local lease.
    /// Cancel the in-flight file before any delayed callback can start another.
    func transferNetworkInvalidated(id: UUID, message: String) {
        guard transferNetworkLease == id else { return }
        transferNetworkLease = nil
        fileSendGeneration &+= 1
        let activeTransfer = wsTransferID
        wsTransferID = nil
        if let activeTransfer {
            WebSocketServer.shared.cancelFileTransfer(id: activeTransfer, notifyRemote: true)
        }
        sendingFileName = nil
        transferState = .failed(message)
        AppState.shared.showingQuickShareTransfer = true
    }

    private func releaseTransferNetwork(cancelled: Bool = false) {
        guard let id = transferNetworkLease else { return }
        transferNetworkLease = nil
        if cancelled { TransferNetworkCoordinator.shared.cancel(id: id) }
        else { TransferNetworkCoordinator.shared.finish(id: id) }
    }

    private func failPreparedTransfer(_ message: String) {
        wsTransferID = nil
        sendingFileName = nil
        transferState = .failed(message)
        releaseTransferNetwork()
    }

    private func sendPreparedFile(_ files: [URL], index: Int, completedBytes: Int64,
                                  targetID: String, generation: UInt64) {
        guard fileSendGeneration == generation else { return }
        guard index < files.count else {
            wsTransferID = nil
            sendingFileName = nil
            transferProgress = 1
            transferState = .finished
            releaseTransferNetwork()
            return
        }
        guard canStreamPreparedFiles else {
            failPreparedTransfer("The paired phone or Wi-Fi connection changed. Your remaining files are still selected.")
            return
        }
        let url = files[index]
        let size = preparedFileSizes[index]
        let id = UUID().uuidString
        wsTransferID = id
        sendingFileName = url.lastPathComponent
        WebSocketServer.shared.sendFile(url: url, transferID: id, expectedDeviceID: targetID, expectedFileSize: size,
            progress: { fraction in
                guard self.fileSendGeneration == generation, self.wsTransferID == id else { return }
                self.transferProgress = self.selectedFileSize > 0
                    ? (Double(completedBytes) + Double(size) * fraction) / Double(self.selectedFileSize)
                    : (Double(index) + fraction) / Double(files.count)
            }, completion: { success, error in
                guard self.fileSendGeneration == generation, self.wsTransferID == id else { return }
                self.wsTransferID = nil
                if success {
                    self.preparedNextFileIndex = index + 1
                    self.preparedCompletedBytes = completedBytes + size
                    self.sendPreparedFile(files, index: index + 1, completedBytes: completedBytes + size,
                                          targetID: targetID, generation: generation)
                } else {
                    self.failPreparedTransfer(error ?? "Couldn't send the file. Your remaining files are still selected; try again.")
                }
            })
    }

    public func sendFiles(urls: [URL], to device: RemoteDeviceInfo) {
        guard !AppState.shared.isSyncPaused && !suspended && isEnabled, let deviceID = device.id else { return }
        sendingDeviceName = device.name
        sendingFileName = nil
        transferState = .connecting(deviceID)
        transferProgress = 0
        
        // Trigger Quick Share mode on Android if it's the connected device
        if let connectedDevice = AppState.shared.device,
           connectedDevice.name == device.name {
            print("[quickshare] Target device matches connected device, sending WebSocket trigger")
            WebSocketServer.shared.sendQuickShareTrigger()
        }
        
        NearbyConnectionManager.shared.startOutgoingTransfer(deviceID: deviceID, delegate: self, urls: urls)
    }
    
    public func generateQrCodeKey() -> String {
        return NearbyConnectionManager.shared.generateQrCodeKey()
    }
    
    public func clearQrCodeKey() {
        NearbyConnectionManager.shared.clearQrCodeKey()
    }
    
    // MARK: - MainAppDelegate (Incoming)
    
    public func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
        guard !AppState.shared.isSyncPaused && !suspended && isEnabled,
              transferNetworkLease == nil else {
            handleUserConsent(transferID: transfer.id, accepted: false)
            return
        }
        // Nearby display names are unauthenticated. A matching paired-phone name
        // cannot prove that this Nearby sender owns the paired WebSocket key.
        // Always request consent here; authenticated WebSocket drops use their
        // separate receiver and do not pass through this Nearby consent path.

        let fileStr: String = {
            if let textTitle = transfer.textDescription {
                return textTitle
            } else if transfer.files.count == 1 {
                return transfer.files[0].name
            } else {
                return String(format: Localizer.shared.text("quickshare.n_files"), transfer.files.count)
            }
        }()
        
        self.transferState = .incomingAwaitingConsent(transfer, device)
        AppState.shared.showingQuickShareTransfer = true
        
        let content = UNMutableNotificationContent()
        content.title = Localizer.shared.text("app.name")
        content.subtitle = String(format: Localizer.shared.text("quickshare.pin_code"), transfer.pinCode ?? "")
        content.body = String(format: Localizer.shared.text("quickshare.device_sending_files"), device.name, fileStr)
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Submarine.aiff"))
        content.categoryIdentifier = "INCOMING_TRANSFERS"
        content.userInfo = [
            "type": "quickshare",
            "transferID": transfer.id
        ]
        
        
        let request = UNNotificationRequest(identifier: "transfer_" + transfer.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        
        self.activeIncomingTransfers[transfer.id] = QuickShareTransferInfo(device: device, transfer: transfer)
    }
    
    public func incomingTransfer(id: String, didFinishWith error: Error?) {
        let wasActive = activeIncomingTransfers.removeValue(forKey: id) != nil
        if wasActive && !suspended && !AppState.shared.isSyncPaused, let error = error {
            let content = UNMutableNotificationContent()
            content.title = Localizer.shared.text("transfer_failed")
            content.body = error.localizedDescription
            content.sound = .default
            let request = UNNotificationRequest(identifier: "transfer_error_" + id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            
            self.transferState = .failed(error.localizedDescription)
            
            resetTransfer(after: 1.5)
        }
        
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_" + id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["transfer_" + id])
    }
 
    public func transferDidComplete(id: String, urls: [URL]) {
        guard !suspended && !AppState.shared.isSyncPaused, activeIncomingTransfers[id] != nil else { return }
        print("[quickshare] Transfer \(id) completed on disk with urls: \(urls)")
        self.transferState = .finished
        self.transferProgress = 1.0
        Self.notifyReceived(urls)
        
        // Pop up overlay if enabled and exactly one file transferred
        if AppState.shared.popupSharedImages, urls.count == 1, let firstURL = urls.first, isImage(url: firstURL) {
            DispatchQueue.main.async {
                SharedImagePopupManager.shared.show(fileURL: firstURL)
            }
        }
        
        resetTransfer(after: 1.5)
    }
    
    /// Received files announce themselves; clicking the banner reveals them in Finder.
    static func notifyReceived(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let content = UNMutableNotificationContent()
        content.title = urls.count == 1 ? first.lastPathComponent : "\(urls.count) files"
        content.body = "From \(AppState.shared.device?.name ?? "your phone") · in Downloads"
        content.userInfo = ["type": "receivedFile", "path": first.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "received_\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func resetTransfer(after delay: TimeInterval) {
        resetGeneration &+= 1
        let generation = resetGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.resetGeneration == generation else { return }
            switch self.transferState {
            case .finished, .failed:
                AppState.shared.showingQuickShareTransfer = false
                self.transferState = .idle
            default:
                break
            }
        }
    }

    private func isImage(url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp"]
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
    
    public func handleUserConsent(transferID: String, accepted: Bool) {
        NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: accepted)
        if !accepted {
            activeIncomingTransfers.removeValue(forKey: transferID)
            if case .incomingAwaitingConsent(let meta, _) = transferState, meta.id == transferID {
                transferState = .idle
                AppState.shared.showingQuickShareTransfer = false
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_" + transferID])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["transfer_" + transferID])
            }
        } else {
            if case .incomingAwaitingConsent(let meta, _) = transferState, meta.id == transferID {
                transferState = .receiving(transferID)
                transferProgress = 0
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_" + transferID])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["transfer_" + transferID])
            }
        }
    }
    
    /// Fast-path receive from the paired phone: shown on the phone card's transfer pill
    /// without taking over a send or Quick Share exchange already on screen.
    public func bulkReceiveProgress(id: String, progress: Double) {
        switch transferState {
        case .idle, .finished, .failed: transferState = .receiving(id)
        case .receiving(let current) where current == id: break
        default: return
        }
        transferProgress = progress
    }

    public func bulkReceiveFinished(id: String, success: Bool, error: String?) {
        guard case .receiving(let current) = transferState, current == id else { return }
        transferProgress = success ? 1 : transferProgress
        transferState = success ? .finished : .failed(error ?? "Transfer failed")
        resetTransfer(after: success ? 2 : 4)
    }

    public func incomingTransferProgress(id: String, progress: Double) {
        guard !suspended && !AppState.shared.isSyncPaused, activeIncomingTransfers[id] != nil else { return }
        self.transferProgress = progress
        if case .receiving(let activeID) = transferState, activeID == id {
            // Already in receiving state
        } else {
            transferState = .receiving(id)
        }
    }
    
    // MARK: - ShareExtensionDelegate (Outgoing)
    
    public func addDevice(device: RemoteDeviceInfo) {
        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            
            // If auto-targeting is active and name matches, start transfer
            if let targetName = autoTargetDeviceName, device.name == targetName {
                print("[quickshare] Auto-targeting found device '\(device.name)', starting transfer")
                self.autoTargetDeviceName = nil // Clear so it doesn't trigger again
                sendFiles(urls: self.transferURLs, to: device)
            }
        }
    }
    
    public func removeDevice(id: String) {
        discoveredDevices.removeAll(where: { $0.id == id })
    }
    
    public func startTransferWithQrCode(device: RemoteDeviceInfo) {
        addDevice(device: device)
    }
    
    public func connectionWasEstablished(pinCode: String) {
        guard let deviceID = caseDiscoveryID() else { return }
        lastPinCode = pinCode
        transferState = .awaitingPin(pinCode, deviceID)
    }

    private func caseDiscoveryID() -> String? {
        // Nearby delegate callbacks cannot take over an authenticated batch.
        guard transferNetworkLease == nil else { return nil }
        switch transferState {
        case .connecting(let id), .awaitingPin(_, let id), .sending(let id):
            return id
        default:
            return nil
        }
    }
    
    public func connectionFailed(with error: Error) {
        guard caseDiscoveryID() != nil else { return }
        transferState = .failed(error.localizedDescription)
        resetTransfer(after: 3)
    }
    
    public func transferAccepted() {
        if let id = caseDiscoveryID() {
            transferState = .sending(id)
        }
    }
    
    public func transferProgress(progress: Double) {
        guard caseDiscoveryID() != nil else { return }
        self.transferProgress = progress
    }
    
    public func transferFinished() {
        guard caseDiscoveryID() != nil else { return }
        transferState = .finished
        resetTransfer(after: 2)
    }
}
