import Foundation

@main
struct MacRemoteInputRegression {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        check(MacRemoteInputPolicy.scrollDelta(.nan) == nil, "NaN cannot convert to Int32")
        check(MacRemoteInputPolicy.scrollDelta(.infinity) == nil, "Infinite scroll")
        check(MacRemoteInputPolicy.scrollDelta(-.infinity) == nil, "Negative infinite scroll")
        check(MacRemoteInputPolicy.scrollDelta(Double.greatestFiniteMagnitude) == 1_000_000, "Extreme finite scroll")
        check(MacRemoteInputPolicy.scrollDelta(-Double.greatestFiniteMagnitude) == -1_000_000, "Extreme negative scroll")
        check(MacRemoteInputPolicy.scrollDelta(25.9) == 25, "Normal scroll")
        check(MacRemoteInputPolicy.scrollDelta(-25.9) == -25, "Negative scroll")
        check(MacRemoteInputPolicy.keyCode(-1) == nil, "Negative keyboard code")
        check(MacRemoteInputPolicy.keyCode(65_536) == nil, "Oversized keyboard code")
        check(MacRemoteInputPolicy.keyCode(Int.max) == nil, "Maximum integer keyboard code")
        check(MacRemoteInputPolicy.keyCode(49) == 49, "Normal key")
        check(MacRemoteInputPolicy.volumePercent(.nan) == 0, "Invalid hardware volume")
        check(MacRemoteInputPolicy.volumePercent(.infinity) == 0, "Infinite hardware volume")
        check(MacRemoteInputPolicy.volumePercent(-1) == 0, "Negative volume")
        check(MacRemoteInputPolicy.volumePercent(2) == 100, "Out-of-range volume")
        check(MacRemoteInputPolicy.volumePercent(0.5) == 50, "Normal volume")
        print("Remote input regression: \(checks) checks passed")
    }
}
