import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct PolicyTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws {
    guard value == nil else {
        throw PolicyTestFailure(description: "\(file):\(line): expected nil, received \(String(describing: value))")
    }
}

private func expectEqual<T: Equatable>(_ value: T, _ expected: T,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
    guard value == expected else {
        throw PolicyTestFailure(description: "\(file):\(line): expected \(expected), received \(value)")
    }
}

private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    try expectEqual(value, true, file: file, line: line)
}

private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    try expectEqual(value, false, file: file, line: line)
}

// Standalone policy harness: compile with MacKeepAwakePolicy.swift on a Swift host.
final class MacKeepAwakePolicyTests {
    private func reason(enabled: Bool = true, connected: Bool = true, paused: Bool = false,
                        now: Double = 100, transfer: Double = 0, remote: Double = 0,
                        media: Double = 0) -> String? {
        MacKeepAwakePolicy.reason(enabled: enabled, connected: connected, paused: paused,
            now: now, transferUntil: transfer, remoteUntil: remote, mediaUntil: media)
    }

    func testOptInAloneDoesNotHoldAssertion() throws {
        try expectNil(reason())
    }
    func testPauseDisconnectAndOptOutReleaseActiveWork() throws {
        try expectNil(reason(paused: true, transfer: 220))
        try expectNil(reason(connected: false, remote: 160))
        try expectNil(reason(enabled: false, media: 220))
    }
    func testExpiredWorkDoesNotExtendIdleSleep() throws {
        try expectNil(reason(transfer: 100, remote: 99, media: 98))
        try expectEqual(reason(now: 99, remote: 100), "Remote control")
        try expectNil(reason(now: 100, remote: 100))
    }
    func testIndependentWorkRetainsAssertionWhenTransferEnds() throws {
        try expectEqual(reason(transfer: 200, remote: 160, media: 220), "File transfer")
        try expectEqual(reason(transfer: 0, remote: 160, media: 220), "Remote control")
        try expectEqual(reason(transfer: 0, remote: 0, media: 220), "Media playback")
    }
    func testInvalidClockAndLeaseCannotHoldAssertion() throws {
        try expectNil(reason(now: .nan, transfer: 220))
        try expectNil(reason(now: -1, transfer: 220))
        try expectNil(reason(transfer: .infinity, remote: .nan))
    }
    func testExperimentalRequiresMacOS15LocalOptInAndActualActivity() throws {
        try expectTrue(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: false, activityReason: "File transfer"))
        try expectFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 16, enabled: true,
            connected: true, paused: false, activityReason: "File transfer"))
        try expectFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: false,
            connected: true, paused: false, activityReason: "File transfer"))
        try expectFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: true, activityReason: "File transfer"))
        try expectFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: false, activityReason: nil))
    }
}

// Foundation-only entry point also runs on Linux; XCTest is not part of the
// macOS command-line SDK and would need developer-framework search paths.
let suite = MacKeepAwakePolicyTests()
let tests: [(String, () throws -> Void)] = [
    ("testOptInAloneDoesNotHoldAssertion", suite.testOptInAloneDoesNotHoldAssertion),
    ("testPauseDisconnectAndOptOutReleaseActiveWork", suite.testPauseDisconnectAndOptOutReleaseActiveWork),
    ("testExpiredWorkDoesNotExtendIdleSleep", suite.testExpiredWorkDoesNotExtendIdleSleep),
    ("testIndependentWorkRetainsAssertionWhenTransferEnds", suite.testIndependentWorkRetainsAssertionWhenTransferEnds),
    ("testInvalidClockAndLeaseCannotHoldAssertion", suite.testInvalidClockAndLeaseCannotHoldAssertion),
    ("testExperimentalRequiresMacOS15LocalOptInAndActualActivity", suite.testExperimentalRequiresMacOS15LocalOptInAndActualActivity)
]
var failures = 0
for (name, run) in tests {
    do {
        try run()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}
print("Power policy: \(tests.count) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
