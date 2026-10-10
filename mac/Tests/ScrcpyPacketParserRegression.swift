import Foundation

@main
struct ScrcpyPacketParserRegression {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        func media(_ size: UInt32, flags: UInt64 = 0) -> Data {
            var result = Data()
            var timestamp = flags.bigEndian
            var size = size.bigEndian
            withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            return result
        }
        func session(_ width: UInt32, _ height: UInt32) -> Data {
            var result = Data([0x80, 0, 0, 0])
            var width = width.bigEndian
            var height = height.bigEndian
            withUnsafeBytes(of: &width) { result.append(contentsOf: $0) }
            withUnsafeBytes(of: &height) { result.append(contentsOf: $0) }
            return result
        }
        check(ScrcpyPacketParser.header(Data()) == nil, "Empty header")
        for length in [1, 4, 8, 11, 13] {
            check(ScrcpyPacketParser.header(Data(repeating: 0, count: length)) == nil, "Truncated header \(length)")
        }
        check(ScrcpyPacketParser.header(media(0)) == nil, "Reject zero-sized receive")
        check(ScrcpyPacketParser.header(media(UInt32.max)) == nil, "Reject oversized allocation")
        check(ScrcpyPacketParser.header(media(UInt32(ScrcpyPacketParser.maximumPacketSize) + 1)) == nil, "Packet size bound")
        check(ScrcpyPacketParser.header(media(32, flags: (1 << 62) | (1 << 61) | 123)) ==
              .media(size: 32, isConfig: true, isKeyframe: true, pts: 123), "Unaligned small Data flag parsing")
        let padded = Data([0xFF]) + media(1, flags: 777)
        check(ScrcpyPacketParser.header(padded.dropFirst()) == .media(size: 1, isConfig: false, isKeyframe: false, pts: 777),
              "A Data slice need not start at index zero or an aligned pointer")
        check(ScrcpyPacketParser.header(session(1920, 1080)) == .session(width: 1920, height: 1080), "Session dimensions")
        check(ScrcpyPacketParser.header(session(0, 1080)) == nil, "Reject zero width")
        check(ScrcpyPacketParser.header(session(1920, 0)) == nil, "Reject zero height")
        check(ScrcpyPacketParser.header(session(65_536, 1080)) == nil, "Reject dimension that would trap UInt16 conversion")
        check(ScrcpyPacketParser.header(session(1920, UInt32.max)) == nil, "Reject enormous height")
        check(ScrcpyPacketParser.nalUnits(Data()) == [], "Empty configuration")
        let mixed = Data([0, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x42, 1, 0, 0, 0, 1, 0x44, 1])
        check(ScrcpyPacketParser.nalUnits(mixed) == [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])], "Mixed Annex-B prefixes")
        check(ScrcpyPacketParser.avcc(mixed) == Data([0, 0, 0, 2, 0x40, 1, 0, 0, 0, 2, 0x42, 1, 0, 0, 0, 2, 0x44, 1]), "AVCC lengths contain no next prefix")
        check(ScrcpyPacketParser.avcc(Data([0, 0, 1])) == nil, "Empty NAL must not be decoded")
        check(ScrcpyPacketParser.avcc(Data([0, 0, 0, 1, 0, 0, 1, 0x26, 1])) == Data([0, 0, 0, 2, 0x26, 1]), "Skip consecutive empty NALs")
        check(ScrcpyPacketParser.avcc(Data([0x26, 1])) == Data([0, 0, 0, 2, 0x26, 1]), "Raw NAL compatibility")
        var fragmented = Data()
        for _ in 0..<1_026 { fragmented.append(contentsOf: [0, 0, 1, 0x26, 1]) }
        check(ScrcpyPacketParser.nalUnits(fragmented).isEmpty, "Bound malformed tiny NAL count")
        print("Scrcpy packet regression: \(checks) checks passed")
    }
}
