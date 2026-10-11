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

let dnsStableID = "01234567-89ab-4cde-8fab-0123456789ab"
let ciHostname = "iad20-gt1026-07360297-c846-4134-b947-46902abc1817-3AF5ADFF4FC1"
let boundedCIName = DiscoveryMetadataPolicy.serviceName(ciHostname, stableID: dnsStableID)
precondition(boundedCIName.utf8.count <= 63)
precondition(boundedCIName.hasSuffix("-01234567"))
precondition(DiscoveryMetadataPolicy.serviceName("My Mac", stableID: dnsStableID) == "androp-My Mac")
precondition(DiscoveryMetadataPolicy.serviceName(String(repeating: "a", count: 56), stableID: dnsStableID).utf8.count == 63)
precondition(DiscoveryMetadataPolicy.serviceName(ciHostname, stableID: "abcdef01-89ab-4cde-8fab-0123456789ab") != boundedCIName)
let unicodeDNSName = DiscoveryMetadataPolicy.serviceName(String(repeating: "📱مَ", count: 100), stableID: dnsStableID)
precondition(unicodeDNSName.utf8.count <= 63)
precondition(String(data: Data(unicodeDNSName.utf8), encoding: .utf8) != nil)
let unicodeTXTName = DiscoveryMetadataPolicy.txtName(String(repeating: "📱مَ", count: 100))
precondition(unicodeTXTName.utf8.count <= 250)
precondition(String(data: Data(unicodeTXTName.utf8), encoding: .utf8) != nil)
precondition(DiscoveryMetadataPolicy.txtName(String(repeating: "a", count: 251)).utf8.count == 250)
precondition(DiscoveryMetadataPolicy.txtName("A\u{0}B\nC") == "ABC")
precondition(DiscoveryMetadataPolicy.txtName(" \n\u{0} ") == "Mac")
precondition(DiscoveryMetadataPolicy.txtName(nil) == "Mac")
print("Discovery metadata bounds: 13 regression checks passed")
