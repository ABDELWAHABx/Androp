import Foundation

/// Event-driven listener recovery, including an offline/online transition with
/// the same DHCP address. The first monitor event is a baseline, not a restart.
struct NetworkRecoveryPolicy {
    enum Action: Equatable { case none, lost, restart }
    private var wasAvailable: Bool?

    mutating func update(available: Bool, endpoint: String?, previousEndpoint: String?) -> Action {
        let previousAvailability = wasAvailable
        wasAvailable = available
        if !available { return previousAvailability == false ? .none : .lost }
        if previousAvailability == false { return .restart }
        if previousAvailability == nil { return .none }
        if endpoint != previousEndpoint { return .restart }
        return .none
    }
}
