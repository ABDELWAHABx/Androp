import Foundation

@main
struct NetworkRecoveryRegression {
    static func main() {
        var policy = NetworkRecoveryPolicy()
        let ip = "192.168.1.12"
        precondition(policy.update(available: true, endpoint: ip, previousEndpoint: ip) == .none)
        precondition(policy.update(available: true, endpoint: ip, previousEndpoint: ip) == .none)
        precondition(policy.update(available: false, endpoint: nil, previousEndpoint: ip) == .lost)
        precondition(policy.update(available: false, endpoint: nil, previousEndpoint: nil) == .none)
        precondition(policy.update(available: true, endpoint: ip, previousEndpoint: nil) == .restart)
        precondition(policy.update(available: true, endpoint: ip, previousEndpoint: ip) == .none)
        precondition(policy.update(available: true, endpoint: "10.0.0.2", previousEndpoint: ip) == .restart)
        var sameAddress = NetworkRecoveryPolicy()
        precondition(sameAddress.update(available: false, endpoint: ip, previousEndpoint: ip) == .lost)
        precondition(sameAddress.update(available: true, endpoint: ip, previousEndpoint: ip) == .restart)
        var initiallyOffline = NetworkRecoveryPolicy()
        precondition(initiallyOffline.update(available: false, endpoint: nil, previousEndpoint: nil) == .lost)
        precondition(initiallyOffline.update(available: true, endpoint: ip, previousEndpoint: nil) == .restart)
        print("Network recovery: 11 checks passed")
    }
}
