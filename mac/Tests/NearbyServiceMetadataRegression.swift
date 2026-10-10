import Foundation

let valid = Data([0x23] + Array("Ab09".utf8) + [0xFC, 0x9F, 0x5E, 0, 0])
precondition(NearbyServiceMetadata.endpointID(in: valid) == "Ab09")
var malformed = valid
malformed[1] = 0xFF
precondition(NearbyServiceMetadata.endpointID(in: malformed) == nil)
malformed[1] = 0
precondition(NearbyServiceMetadata.endpointID(in: malformed) == nil)
for count in 0..<valid.count {
    precondition(NearbyServiceMetadata.endpointID(in: valid.prefix(count)) == nil)
}
precondition(NearbyServiceMetadata.extensionRecords(in: Data([1, 255, 1, 2, 3]), offset: 0) == nil)
precondition(NearbyServiceMetadata.extensionRecords(in: Data([1]), offset: 0) == nil)
precondition(NearbyServiceMetadata.extensionRecords(in: Data([1, 0]), offset: 0)?[1] == Data())
precondition(NearbyServiceMetadata.extensionRecords(in: Data([1, 2, 4, 5, 2, 1, 9]), offset: 0)?[1] == Data([4, 5]))
precondition(NearbyServiceMetadata.extensionRecords(in: Data(), offset: 1) == nil)
let unicodeName = NearbyServiceMetadata.encodedName(String(repeating: "📱", count: 100))
precondition(unicodeName.count <= 255 && String(data: unicodeName, encoding: .utf8) != nil)
precondition(NearbyServiceMetadata.encodedName(nil).isEmpty)
print("Nearby service metadata regressions passed")
