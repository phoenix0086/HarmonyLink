import CoreMedia
import Foundation

// The prepared sample is handed to AppKit once and is never mutated by the decoder afterwards.
struct MirrorFrame: @unchecked Sendable {
    let sample: CMSampleBuffer
    let format: CMVideoFormatDescription
    let keyframe: Bool
}

actor MirrorFrameDecoder {
    private var sps = Data()
    private var pps = Data()
    private var format: CMVideoFormatDescription?

    func prepare(_ data: Data) -> MirrorFrame? {
        let nalUnits = Self.annexBRanges(data)
        var accessUnit = Data()
        var hasSlice = false
        var keyframe = false
        for range in nalUnits {
            let nal = data[range]
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7:
                if sps != nal { sps = Data(nal); format = nil }
            case 8:
                if pps != nal { pps = Data(nal); format = nil }
            case 1, 5:
                hasSlice = true
                keyframe = keyframe || (first & 0x1f == 5)
                Self.append(nal, to: &accessUnit)
            case 6:
                Self.append(nal, to: &accessUnit)
            default:
                break
            }
        }
        guard hasSlice else { return nil }
        if format == nil {
            guard keyframe, !sps.isEmpty, !pps.isEmpty else { return nil }
            var description: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [
                        spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count],
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description
                    )
                }
            }
            guard status == noErr, let description else { return nil }
            format = description
        }

        var block: CMBlockBuffer?
        let length = accessUnit.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &block
        ) == noErr, let block, let format else { return nil }

        let copyStatus = accessUnit.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample,
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else {
            return nil
        }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return MirrorFrame(sample: sample, format: format, keyframe: keyframe)
    }

    private static func append(_ nal: Data, to data: inout Data) {
        var size = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(nal)
    }

    private static func annexBRanges(_ data: Data) -> [Range<Data.Index>] {
        data.withUnsafeBytes { bytes in
            var units = [Range<Data.Index>]()
            var start: Int?
            var index = 0
            let base = data.startIndex
            while index + 2 < bytes.count {
                guard bytes[index] == 0, bytes[index + 1] == 0 else {
                    index += 1
                    continue
                }
                let prefix: Int
                if bytes[index + 2] == 1 {
                    prefix = 3
                } else if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    prefix = 4
                } else {
                    index += 1
                    continue
                }
                if let start, index > start { units.append((base + start)..<(base + index)) }
                start = index + prefix
                index += prefix
            }
            if let start, start < bytes.count { units.append((base + start)..<data.endIndex) }
            return units
        }
    }
}
