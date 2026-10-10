import Foundation

/// Accessed only on HotspotWiFiWorker.queue. Ownership follows the request,
/// rather than an SSID that a later request (or the user) might reuse.
nonisolated struct TemporaryWiFiOwnership {
    struct Release: Equatable {
        let disconnect: Bool
        let restoreSSID: String?
    }
    private struct Claim {
        let owner: UUID
        let ssid: String
        let previousSSID: String?
        var associationSubmitted: Bool
    }
    private var claim: Claim?

    mutating func begin(owner: UUID, ssid: String, currentSSID: String?) {
        // If a newer request adopts a still-owned temporary network, keep the
        // original network as its restoration target, not the old hotspot.
        let previousClaim = claim
        let adopting = previousClaim?.associationSubmitted == true && previousClaim?.ssid == currentSSID
        let previousSSID = adopting ? previousClaim?.previousSSID : currentSSID
        claim = Claim(owner: owner, ssid: ssid, previousSSID: previousSSID,
                      associationSubmitted: adopting && currentSSID == ssid)
    }

    mutating func willAssociate(owner: UUID) -> Bool {
        guard claim?.owner == owner else { return false }
        claim?.associationSubmitted = true
        return true
    }

    mutating func release(owner: UUID, currentSSID: String?, cancelled: Bool) -> Release? {
        guard let current = claim, current.owner == owner else { return nil }
        claim = nil // A late completion cannot release this request twice.
        guard current.associationSubmitted,
              currentSSID == nil || currentSSID == current.ssid else {
            return Release(disconnect: false, restoreSSID: nil)
        }
        let restore = !cancelled && current.previousSSID != current.ssid ? current.previousSSID : nil
        return Release(disconnect: currentSSID == current.ssid, restoreSSID: restore)
    }
}
