import Foundation
import Network
import Combine

class ScrcpyStreamClient: ObservableObject {
    static let shared = ScrcpyStreamClient()

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "app.androp.mac.scrcpy.stream", qos: .userInteractive)
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var packetHandler: ((Data, Bool, Bool, UInt64) -> Void)?
    private var retryWork: DispatchWorkItem?
    private let maxRetries = 5

    @Published var isConnected = false
    @Published var videoWidth: UInt32 = 0
    @Published var videoHeight: UInt32 = 0
    @Published var deviceName: String = "Device"

    var onPacketReceived: ((Data, Bool, Bool, UInt64) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return packetHandler }
        set { stateLock.lock(); packetHandler = newValue; stateLock.unlock() }
    }

    private func nextGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == value
    }

    private func publish(_ value: UInt64, _ update: @escaping (ScrcpyStreamClient) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(value) else { return }
            update(self)
        }
    }

    func connect(host: String = "127.0.0.1", port: UInt16 = 1234) {
        let value = nextGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(value) else { return }
            self.cancelConnection()
            self.launch(host: host, port: port, generation: value, attempt: 0)
        }
    }

    func disconnect() {
        // Invalidate callbacks immediately, before queued transport cleanup runs.
        let value = nextGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(value) else { return }
            self.cancelConnection()
        }
        publish(value) {
            $0.isConnected = false
            $0.videoWidth = 0
            $0.videoHeight = 0
        }
    }

    private func cancelConnection() {
        retryWork?.cancel()
        retryWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func launch(host: String, port: UInt16, generation value: UInt64, attempt: Int) {
        guard isCurrent(value), let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let socket = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.isCurrent(value), self.connection === socket else { return }
            switch state {
            case .ready:
                self.publish(value) { $0.isConnected = true }
                self.readMetadata(socket, generation: value, host: host, port: port, attempt: attempt)
            case .failed(let error):
                print("[ScrcpyStreamClient] Connection failed: \(error)")
                self.fail(socket, generation: value, host: host, port: port, attempt: attempt)
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func fail(_ socket: NWConnection, generation value: UInt64,
                      host: String, port: UInt16, attempt: Int) {
        guard isCurrent(value), connection === socket else { return }
        cancelConnection()
        publish(value) { $0.isConnected = false }
        guard attempt < maxRetries else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(value) else { return }
            self.launch(host: host, port: port, generation: value, attempt: attempt + 1)
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + Double(attempt + 1) * 0.5, execute: work)
    }

    private func receive(_ length: Int, from socket: NWConnection, generation value: UInt64,
                         host: String, port: UInt16, attempt: Int,
                         completion: @escaping (Data) -> Void) {
        socket.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak socket] data, _, _, error in
            guard let self, let socket, self.isCurrent(value), self.connection === socket else { return }
            guard error == nil, let data, data.count == length else {
                self.fail(socket, generation: value, host: host, port: port, attempt: attempt)
                return
            }
            completion(data)
        }
    }

    private func readMetadata(_ socket: NWConnection, generation value: UInt64,
                              host: String, port: UInt16, attempt: Int) {
        receive(1, from: socket, generation: value, host: host, port: port, attempt: attempt) { [weak self] _ in
            self?.receive(64, from: socket, generation: value, host: host, port: port, attempt: attempt) { [weak self] data in
                guard let self else { return }
                let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "Unknown"
                self.publish(value) { $0.deviceName = name }
                self.receive(4, from: socket, generation: value, host: host, port: port, attempt: attempt) { [weak self] _ in
                    self?.readFrameHeader(socket, generation: value, host: host, port: port, attempt: attempt)
                }
            }
        }
    }

    private func readFrameHeader(_ socket: NWConnection, generation value: UInt64,
                                 host: String, port: UInt16, attempt: Int) {
        receive(12, from: socket, generation: value, host: host, port: port, attempt: attempt) { [weak self] data in
            guard let self else { return }
            guard let header = ScrcpyPacketParser.header(data) else {
                print("[ScrcpyStreamClient] Rejecting invalid video packet header")
                self.fail(socket, generation: value, host: host, port: port, attempt: attempt)
                return
            }
            switch header {
            case .session(let width, let height):
                self.publish(value) { $0.videoWidth = width; $0.videoHeight = height }
                self.readFrameHeader(socket, generation: value, host: host, port: port, attempt: attempt)
            case .media(let size, let isConfig, let isKeyframe, let pts):
                self.receive(size, from: socket, generation: value, host: host, port: port, attempt: attempt) { [weak self] packet in
                    guard let self else { return }
                    self.onPacketReceived?(packet, isConfig, isKeyframe, pts)
                    self.readFrameHeader(socket, generation: value, host: host, port: port, attempt: attempt)
                }
            }
        }
    }
}
