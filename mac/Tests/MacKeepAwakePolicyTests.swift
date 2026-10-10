import XCTest

// Standalone policy harness: compile with MacKeepAwakePolicy.swift on a Swift host.
final class MacKeepAwakePolicyTests: XCTestCase {
    private func reason(enabled: Bool = true, connected: Bool = true, paused: Bool = false,
                        now: Double = 100, transfer: Double = 0, remote: Double = 0,
                        media: Double = 0) -> String? {
        MacKeepAwakePolicy.reason(enabled: enabled, connected: connected, paused: paused,
            now: now, transferUntil: transfer, remoteUntil: remote, mediaUntil: media)
    }

    func testOptInAloneDoesNotHoldAssertion() {
        XCTAssertNil(reason())
    }
    func testPauseDisconnectAndOptOutReleaseActiveWork() {
        XCTAssertNil(reason(paused: true, transfer: 220))
        XCTAssertNil(reason(connected: false, remote: 160))
        XCTAssertNil(reason(enabled: false, media: 220))
    }
    func testExpiredWorkDoesNotExtendIdleSleep() {
        XCTAssertNil(reason(transfer: 100, remote: 99, media: 98))
        XCTAssertEqual(reason(now: 99, remote: 100), "Remote control")
        XCTAssertNil(reason(now: 100, remote: 100))
    }
    func testIndependentWorkRetainsAssertionWhenTransferEnds() {
        XCTAssertEqual(reason(transfer: 200, remote: 160, media: 220), "File transfer")
        XCTAssertEqual(reason(transfer: 0, remote: 160, media: 220), "Remote control")
        XCTAssertEqual(reason(transfer: 0, remote: 0, media: 220), "Media playback")
    }
    func testInvalidClockAndLeaseCannotHoldAssertion() {
        XCTAssertNil(reason(now: .nan, transfer: 220))
        XCTAssertNil(reason(now: -1, transfer: 220))
        XCTAssertNil(reason(transfer: .infinity, remote: .nan))
    }
    func testExperimentalRequiresMacOS15LocalOptInAndActualActivity() {
        XCTAssertTrue(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: false, activityReason: "File transfer"))
        XCTAssertFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 16, enabled: true,
            connected: true, paused: false, activityReason: "File transfer"))
        XCTAssertFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: false,
            connected: true, paused: false, activityReason: "File transfer"))
        XCTAssertFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: true, activityReason: "File transfer"))
        XCTAssertFalse(MacKeepAwakePolicy.shouldUseExperimental(majorVersion: 15, enabled: true,
            connected: true, paused: false, activityReason: nil))
    }
}

XCTMain([testCase([
    ("testOptInAloneDoesNotHoldAssertion", MacKeepAwakePolicyTests.testOptInAloneDoesNotHoldAssertion),
    ("testPauseDisconnectAndOptOutReleaseActiveWork", MacKeepAwakePolicyTests.testPauseDisconnectAndOptOutReleaseActiveWork),
    ("testExpiredWorkDoesNotExtendIdleSleep", MacKeepAwakePolicyTests.testExpiredWorkDoesNotExtendIdleSleep),
    ("testIndependentWorkRetainsAssertionWhenTransferEnds", MacKeepAwakePolicyTests.testIndependentWorkRetainsAssertionWhenTransferEnds),
    ("testInvalidClockAndLeaseCannotHoldAssertion", MacKeepAwakePolicyTests.testInvalidClockAndLeaseCannotHoldAssertion),
    ("testExperimentalRequiresMacOS15LocalOptInAndActualActivity", MacKeepAwakePolicyTests.testExperimentalRequiresMacOS15LocalOptInAndActualActivity)
])])
