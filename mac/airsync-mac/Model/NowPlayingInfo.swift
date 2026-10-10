//
//  NowPlayingInfo.swift
//  AirSync
//
//  Created by Sameera Sandakelum on 2025-09-17.
//
import Foundation

struct NowPlayingInfo {
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var elapsedTime: Double? = 0
    var duration: Double? = 0
    var isPlaying: Bool? = false
    var artworkData: Data? = nil
    var artworkMimeType: String? = nil
    var bundleIdentifier: String? = nil
    var timestamp: String? = nil
    var playbackRate: Double? = 0.0

    /// A paused track is a real session; a metadata-free idle update is not.
    var hasMediaSession: Bool {
        isPlaying == true || [title, artist].contains { value in
            guard let value else { return false }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "?" && text.lowercased() != "nothing playing"
        }
    }

    mutating func updateFromPayload(_ payload: [String: Any]) {
        if let title = payload["title"] as? String { self.title = title }
        if let artist = payload["artist"] as? String { self.artist = artist }
        if let album = payload["album"] as? String { self.album = album }
        if let elapsed = payload["elapsedTime"] as? NSNumber { self.elapsedTime = max(0, elapsed.doubleValue) }
        if let duration = payload["duration"] as? NSNumber { self.duration = max(0, duration.doubleValue) }
        if let playing = (payload["playing"] ?? payload["isPlaying"]) as? Bool { self.isPlaying = playing }
        if let rate = payload["playbackRate"] as? NSNumber { self.playbackRate = rate.doubleValue }
        else { self.playbackRate = self.isPlaying == true ? 1.0 : 0.0 }
        if let ts = payload["timestamp"] as? String { self.timestamp = ts }
        if let artworkBase64 = payload["artworkData"] as? String,
           let data = Data(base64Encoded: artworkBase64) {
            self.artworkData = data
        }
        if let mime = payload["artworkMimeType"] as? String { self.artworkMimeType = mime }
        if let bundleId = payload["bundleIdentifier"] as? String { self.bundleIdentifier = bundleId }
    }
}
