// Run on macOS (only Foundation is required):
// swiftc airsync-mac/Model/NowPlayingInfo.swift Tests/NowPlayingInfoRegression.swift -o /tmp/androp-media-tests
// /tmp/androp-media-tests
import Foundation

@main
struct NowPlayingInfoRegression {
    static func main() {
        func parse(_ payload: [String: Any]) -> NowPlayingInfo {
            var info = NowPlayingInfo()
            info.updateFromPayload(payload)
            return info
        }
        assert(!NowPlayingInfo().hasMediaSession, "An idle initial state must not create a player")
        assert(!parse([:]).hasMediaSession)
        assert(!parse(["playing": false, "elapsedTime": 0]).hasMediaSession)
        assert(!parse(["title": " ? ", "artist": " "]).hasMediaSession)
        assert(!parse(["title": "Nothing Playing"]).hasMediaSession)
        assert(parse(["title": "A real paused track", "playing": false]).hasMediaSession)
        assert(parse(["artist": "Radio", "playing": false]).hasMediaSession)
        assert(parse(["playing": true]).hasMediaSession, "Untitled live streams are valid media")
        assert(parse(["isPlaying": true]).isPlaying == true)
        let integerTimes = parse(["title": "Track", "elapsedTime": 17, "duration": 120])
        assert(integerTimes.elapsedTime == 17 && integerTimes.duration == 120)
        assert(parse(["elapsedTime": -5, "duration": -1]).elapsedTime == 0)
        assert(parse(["playing": false]).playbackRate == 0)
        assert(parse(["playing": true]).playbackRate == 1)
        assert(parse(["playing": true, "playbackRate": 1.5]).playbackRate == 1.5)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            let info = parse(["elapsedTime": invalid, "duration": invalid, "playbackRate": invalid, "playing": true])
            assert(info.elapsedTime == 0 && info.duration == 0 && info.playbackRate == 1)
        }
        var artwork = parse(["artworkData": Data([1, 2, 3]).base64EncodedString()])
        assert(artwork.artworkData == Data([1, 2, 3]))
        artwork.updateFromPayload(["artworkData": "invalid!"])
        assert(artwork.artworkData == nil)
        assert(parse(["artworkData": String(repeating: "A", count: 7 * 1024 * 1024 + 1)]).artworkData == nil)
        assert(parse(["elapsedTime": Double.greatestFiniteMagnitude, "duration": Double.greatestFiniteMagnitude]).duration == NowPlayingInfo.maximumTimelineSeconds)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, Double.greatestFiniteMagnitude] {
            assert(NowPlayingInfo.seekMilliseconds(invalid) == nil)
        }
        assert(NowPlayingInfo.seekMilliseconds(1.25) == 1250)
        assert(NowPlayingInfo.seekMilliseconds(0) == 0)
        print("NowPlayingInfo regression checks passed")
    }
}
