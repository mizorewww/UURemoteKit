import CoreMedia
import Foundation
import os
import VideoToolbox
@preconcurrency import WebRTC
import XCTest
@testable import UURemoteKit

/// H.265 as a UU host sends it, made here with VideoToolbox: Annex-B, the
/// parameter sets in front of each key frame.
private enum HEVCSource {
    static func frames(count: Int, width: Int = 640, height: Int = 360) throws -> [(data: Data, key: Bool)] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else {
            throw XCTSkip("no HEVC encoder here")
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let output = OSAllocatedUnfairLock(initialState: [(data: Data, key: Bool)]())
        for index in 0 ..< count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(index * 20 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let properties = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30), duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample else { return }
                output.withLock { $0.append(annexB(sample)) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        return output.withLock { $0 }
    }

    private static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool) {
        let startCode = Data([0, 0, 0, 1])
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0 ..< count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { out += startCode + Data(bytes: pointer, count: size) }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return (out, key) }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return (out, key) }
        let bytes = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            out += startCode + bytes[offset ..< min(offset + size, bytes.count)]
            offset += size
        }
        return (out, key)
    }
}

final class HEVCDecoderTests: XCTestCase {
    private func image(_ data: Data, key: Bool, timestamp: UInt32) -> RTCEncodedImage {
        let image = RTCEncodedImage()
        image.buffer = data
        image.timeStamp = timestamp
        image.frameType = key ? .videoFrameKey : .videoFrameDelta
        return image
    }

    func testHostH265DecodesIntoPixelBuffers() throws {
        let frames = try HEVCSource.frames(count: 10)
        XCTAssertTrue(frames.first?.key ?? false)
        let decoder = UUHEVCDecoder()
        let sizes = OSAllocatedUnfairLock(initialState: [CGSize]())
        decoder.setCallback { frame in
            guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
            sizes.withLock { $0.append(CGSize(width: CVPixelBufferGetWidth(buffer.pixelBuffer), height: CVPixelBufferGetHeight(buffer.pixelBuffer))) }
        }
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 1), UUHEVCDecoder.ok)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(decoder.decode(image(frame.data, key: frame.key, timestamp: UInt32(index * 3000)), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUHEVCDecoder.ok)
        }
        XCTAssertEqual(sizes.withLock { $0 }, Array(repeating: CGSize(width: 640, height: 360), count: frames.count))
        _ = decoder.release()
    }

    /// Frames before the first key frame cannot be decoded: the error asks
    /// the host for one.
    func testADeltaFrameFirstAsksForAKeyFrame() throws {
        let frames = try HEVCSource.frames(count: 3)
        let decoder = UUHEVCDecoder()
        decoder.setCallback { _ in }
        XCTAssertEqual(decoder.decode(image(frames[1].data, key: false, timestamp: 0), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUHEVCDecoder.error)
        XCTAssertEqual(decoder.decode(image(frames[0].data, key: true, timestamp: 1), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUHEVCDecoder.ok)
    }

    /// A key frame asked for: the next delta frame decoded says so to WebRTC.
    func testAKeyFrameRequestIsAnsweredOnTheNextDecode() throws {
        let frames = try HEVCSource.frames(count: 3)
        let requests = UUKeyFrameRequests()
        let decoder = UUKeyFrameRequestingDecoder(UUHEVCDecoder(), requests: requests)
        decoder.setCallback { _ in }
        XCTAssertEqual(decoder.decode(image(frames[0].data, key: true, timestamp: 0), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUHEVCDecoder.ok)
        requests.request()
        XCTAssertEqual(decoder.decode(image(frames[1].data, key: false, timestamp: 1), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUKeyFrameRequestingDecoder.okRequestKeyFrame)
        XCTAssertEqual(decoder.decode(image(frames[2].data, key: false, timestamp: 2), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), UUHEVCDecoder.ok)
    }

    func testAnnexBSplitsOnBothStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x42, 2, 3, 0, 0, 0, 1, 0x26])
        XCTAssertEqual(UUAnnexB.nalUnits(stream), [Data([0x40, 1]), Data([0x42, 2, 3]), Data([0x26])])
        XCTAssertEqual(UUAnnexB.hevcType(Data([0x40, 1])), 32)
    }
}
