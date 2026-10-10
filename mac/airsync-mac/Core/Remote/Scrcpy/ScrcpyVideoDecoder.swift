//
//  ScrcpyVideoDecoder.swift
//  AirSync
//
//  Created by Sameera Wijerathna on 2026-04-01.
//

import Foundation
import VideoToolbox
import CoreMedia

class ScrcpyVideoDecoder: NSObject {
    static let shared = ScrcpyVideoDecoder()
    
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private let sessionLock = NSRecursiveLock()
    private let callbackLock = NSLock()
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    
    // Callback for decoded frames
    var onDecodedFrame: ((CVPixelBuffer) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return frameHandler }
        set { callbackLock.lock(); frameHandler = newValue; callbackLock.unlock() }
    }

    func reset() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        invalidateSession()
        formatDescription = nil
    }

    private func invalidateSession() {
        if let session = decompressionSession {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
    }
    
    func decodePacket(data: Data, isConfig: Bool, pts: UInt64) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !data.isEmpty, data.count <= ScrcpyPacketParser.maximumPacketSize else { return }
        // Detect VPS (32), SPS (33), or PPS (34) in H.265 Annex-B
        // Start codes are 00 00 00 01
        if data.count > 4 {
            let naluType = (data[data.startIndex + 4] & 0x7E) >> 1
            if naluType == 32 || naluType == 33 || naluType == 34 {
                setupDecoder(with: data)
                return
            }
        }
        
        if isConfig {
            setupDecoder(with: data)
            return
        }
        
        guard let session = decompressionSession else { return }
        
        // Android is Annex-B (00 00 00 01), VideoToolbox is AVCC (length-prefixed)
        guard let avccData = ScrcpyPacketParser.avcc(data), !avccData.isEmpty else { return }
        
        var blockBuffer: CMBlockBuffer?
        // VideoToolbox decodes asynchronously. A block buffer that points into a
        // temporary Swift Data becomes dangling as soon as this function returns.
        // Allocate CoreMedia-owned storage and copy bytes while Data is pinned.
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let buffer = blockBuffer else { return }
        let copyStatus = avccData.withUnsafeBytes { bytes -> OSStatus in
            guard let address = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: address, blockBuffer: buffer,
                                                 offsetIntoDestination: 0, dataLength: avccData.count)
        }
        guard copyStatus == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        let sampleSize = [avccData.count]
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }
        
        var flagsOut: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }
    
    private func setupDecoder(with configData: Data) {
        // Only VPS/SPS/PPS belong in a HEVC format description. Limit the count
        // before the nested pointer-pinning helper to avoid malformed-data recursion.
        let units = ScrcpyPacketParser.nalUnits(configData)
        let validNalus = units.filter { unit in
            guard let first = unit.first, unit.count >= 2 else { return false }
            return [UInt8(32), 33, 34].contains((first & 0x7E) >> 1)
        }
        guard validNalus.count == 3,
              Set(validNalus.compactMap { $0.first.map { ($0 & 0x7E) >> 1 } }).count == 3 else { return }
        var newDescription: CMVideoFormatDescription?
        let status = validNalus.withUnsafeParameterSets { pointers, sizes, count in
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &newDescription
            )
        }
        
        guard status == noErr, let desc = newDescription else {
            print("[ScrcpyVideoDecoder] Failed to create format description: \(status)")
            return
        }
        
        formatDescription = desc
        createSession(with: desc)
    }
    
    private func createSession(with desc: CMVideoFormatDescription) {
        invalidateSession()
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                guard status == noErr, let buffer = imageBuffer, let refcon = decompressionOutputRefCon else { return }
                let decoder = Unmanaged<ScrcpyVideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.onDecodedFrame?(buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &decompressionSession
        )
        
        if status != noErr {
            print("[ScrcpyVideoDecoder] Failed to create decompression session: \(status)")
        } else {
            print("[ScrcpyVideoDecoder] Decompression session created")
        }
    }
    

}

extension Array where Element == Data {
    func withUnsafeParameterSets<T>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> T) -> T {
        let parameterSets = self.map { [UInt8]($0) }
        var pointers = [UnsafePointer<UInt8>]()
        var sizes = [Int]()
        
        return recursivelyGetPointers(index: 0, currentPointers: &pointers, currentSizes: &sizes, parameterSets: parameterSets, body: body)
    }
    
    private func recursivelyGetPointers<T>(index: Int, currentPointers: inout [UnsafePointer<UInt8>], currentSizes: inout [Int], parameterSets: [[UInt8]], body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> T) -> T {
        if index == parameterSets.count {
            return body(currentPointers, currentSizes, parameterSets.count)
        }
        
        return parameterSets[index].withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                currentPointers.append(baseAddress)
                currentSizes.append(buffer.count)
            }
            let result = recursivelyGetPointers(index: index + 1, currentPointers: &currentPointers, currentSizes: &currentSizes, parameterSets: parameterSets, body: body)
            if !currentPointers.isEmpty { currentPointers.removeLast() }
            if !currentSizes.isEmpty { currentSizes.removeLast() }
            return result
        }
    }
}
