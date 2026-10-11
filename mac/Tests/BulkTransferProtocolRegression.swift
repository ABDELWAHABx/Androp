import Foundation
import CryptoKit

@main
struct BulkTransferProtocolRegression {
    static func main() throws {
        let key = SymmetricKey(data: Data(0..<32))
        // Shared vector with Android (BulkTransferProtocolTest).
        let sealed = try BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.macToPhone)
            .seal(type: BulkTransferProtocol.typeData, payload: Data("androp".utf8))
        precondition(sealed.map { String(format: "%02x", $0) }.joined() == "4557a3ce7e3584b57f8db32fa5ff0a3663c84a9c810e1f",
                     "bulk record matches Android vector")
        let sender = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
        let receiver = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
        let hello = try sender.seal(type: BulkTransferProtocol.typeHello, payload: Data("id".utf8))
        let data = try sender.seal(type: BulkTransferProtocol.typeData, payload: Data(repeating: 7, count: 300_000))
        precondition(try receiver.open(hello).type == BulkTransferProtocol.typeHello, "hello opens first")
        precondition(try receiver.open(data).payload.count == 300_000, "data opens in order")
        let wrongDirection = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.macToPhone)
        precondition((try? wrongDirection.open(hello)) == nil, "direction is bound into the nonce")
        let skipped = BulkTransferProtocol.Sealer(key: key, direction: BulkTransferProtocol.phoneToMac)
        precondition((try? skipped.open(data)) == nil, "reordered record rejected")
        print("Bulk transfer protocol: 5 checks passed")
    }
}
