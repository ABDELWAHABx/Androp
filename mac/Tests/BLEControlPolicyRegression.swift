import Foundation

@main struct BLEControlPolicyRegression {
    static func main() throws {
        func decode(_ text: String?) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(text!.utf8)) as! [String: Any]
        }
        let command = try decode(BLEControlPolicy.envelope(type: "mediaControl", data: ["action": "seekTo", "positionMs": 42000]))
        assert((command["data"] as? [String: Any])?["positionMs"] as? Int == 42000)
        assert(BLEControlPolicy.envelope(type: "remoteControl", data: ["text": String(repeating: "ع", count: 65536)]) == nil)
        assert(BLEControlPolicy.envelope(type: "invalid", data: ["number": Double.nan]) == nil)
        let status = BLEControlPolicy.compactStatus(["battery": ["level": 50, "isCharging": true], "isPaired": true,
            "music": ["title": "a\u{001F}b", "duration": 300, "elapsedTime": 50, "albumArt": String(repeating: "x", count: 100000), "albumArtLite": "large"]])
        let music = status["music"] as! [String: Any]
        assert(music["title"] as? String == "a\u{001F}b")
        assert(music["duration"] as? Int == 300 && music["elapsedTime"] as? Int == 50)
        assert(music["albumArt"] as? String == "" && music["albumArtLite"] == nil)
        assert((status["battery"] as? [String: Any])?["isCharging"] as? Bool == true)
        assert(BLEControlPolicy.envelope(type: "status", data: status)!.utf8.count < 1024)
        assert(BLEControlPolicy.compactStatus(["isPaired": true])["music"] == nil)
        assert(BLEControlPolicy.clipboardRetryDelay(bytes: 65536, wifi: false) == 60)
        assert(BLEControlPolicy.clipboardRetryDelay(bytes: 1, wifi: false) < 9)
        assert(BLEControlPolicy.clipboardRetryDelay(bytes: 65536, wifi: true) == 4)
        print("BLE control policy: 12 regression assertions passed")
    }
}
