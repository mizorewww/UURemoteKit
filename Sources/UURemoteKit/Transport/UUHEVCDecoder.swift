//
//  UUHEVCDecoder.swift
//  UURemoteKit
//
//  H.265 for WebRTC's receiver, on VideoToolbox. The WebRTC build
//  negotiates H.265 and depacketizes it but ships no decoder for it on
//  Apple platforms, and UU hosts send H.265.
//

import CoreMedia
import Foundation
import os
import VideoToolbox
@preconcurrency import WebRTC

/// Annex-B byte streams, as WebRTC hands over an encoded frame.
enum UUAnnexB {
    /// The NAL units, without their start codes (00 00 01 or 00 00 00 01).
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    // A 4-byte start code's leading zero is the start code's.
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start ..< end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    /// An H.265 NAL unit's type.
    static func hevcType(_ nal: Data) -> UInt8 {
        nal.isEmpty ? 0xFF : (nal[nal.startIndex] >> 1) & 0x3F
    }
}

/// Decodes one H.265 track into BGRA pixel buffers. WebRTC calls it from
/// one decoding thread at a time.
final class UUHEVCDecoder: NSObject, RTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private static let log = Logger(subsystem: "UURemoteKit", category: "hevc")

    /// WebRTC's `WEBRTC_VIDEO_CODEC_OK` and `WEBRTC_VIDEO_CODEC_ERROR`; an
    /// error asks the sender for a key frame.
    static let ok = 0
    static let error = -1

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        Self.ok
    }

    func release() -> Int {
        reset()
        return Self.ok
    }

    func implementationName() -> String {
        "VideoToolbox HEVC (UURemoteKit)"
    }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let units = UUAnnexB.nalUnits(encodedImage.buffer)
        // VPS, SPS and PPS (32, 33, 34) come before a key frame; new ones
        // mean a new format, and a new session for it.
        let sets = [32, 33, 34].compactMap { type in units.last { UUAnnexB.hevcType($0) == type } }
        if sets.count == 3, sets != parameterSets {
            reset()
            parameterSets = sets
            format = Self.formatDescription(sets)
        }
        let pictures = units.filter { !(32 ... 34).contains(UUAnnexB.hevcType($0)) }
        guard !pictures.isEmpty else { return Self.ok }
        guard let currentFormat = format else { return Self.error }
        if session == nil { session = Self.makeSession(currentFormat) }
        guard let session, let sample = Self.sample(pictures, format: currentFormat, timestamp: encodedImage.timeStamp) else { return Self.error }

        // Without asynchronous decompression the handler runs before
        // DecodeFrame returns, on this thread.
        let output = Output(callback: callback, timestamp: encodedImage.timeStamp)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            output.deliver(imageBuffer)
        }
        guard status == noErr, output.delivered else {
            Self.log.error("could not decode a frame: \(status)")
            // The session may be broken past this frame: a new one starts
            // at the key frame the error asks for.
            reset()
            format = parameterSets.isEmpty ? nil : Self.formatDescription(parameterSets)
            return Self.error
        }
        return Self.ok
    }

    // Unchecked: VideoToolbox types its handler @Sendable, yet without asynchronous decompression it runs on this thread before DecodeFrame returns.
    private final class Output: @unchecked Sendable {
        let callback: RTCVideoDecoderCallback?
        let timestamp: UInt32
        var delivered = false

        init(callback: RTCVideoDecoderCallback?, timestamp: UInt32) {
            self.callback = callback
            self.timestamp = timestamp
        }

        func deliver(_ pixelBuffer: CVPixelBuffer) {
            delivered = true
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: Int64(timestamp) * 1_000_000 / 90)
            frame.timeStamp = Int32(bitPattern: timestamp)
            callback?(frame)
        }
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { reset() }

    static func formatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        // The pointers must stay valid for the call: one buffer, pinned.
        let joined = [UInt8](sets.reduce(Data(), +))
        let sizes = sets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            var offset = 0
            let pointers: [UnsafePointer<UInt8>] = sizes.map { size in
                defer { offset += size }
                return buffer.baseAddress! + offset
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    private static func makeSession(_ format: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        // No output callback: each frame is decoded with a handler, which
        // VideoToolbox refuses on a session that has one.
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        return status == noErr ? session : nil
    }

    /// The NAL units as one sample, each behind its 4-byte length.
    private static func sample(_ units: [Data], format: CMVideoFormatDescription, timestamp: UInt32) -> CMSampleBuffer? {
        var bytes = Data(capacity: units.reduce(0) { $0 + 4 + $1.count })
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let size = bytes.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: [size], sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

/// Every decoder on one transport, for asking all of them for a key frame:
/// the next decode of each returns WebRTC's
/// `WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME`, and the receiver sends the
/// host a picture loss indication.
final class UUKeyFrameRequests: Sendable {
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    var current: Int { generation.withLock { $0 } }
    func request() { generation.withLock { $0 += 1 } }
}

/// A decoder that answers a pending key-frame request after decoding.
final class UUKeyFrameRequestingDecoder: NSObject, RTCVideoDecoder {
    private let inner: RTCVideoDecoder
    private let requests: UUKeyFrameRequests
    private var seen: Int

    static let okRequestKeyFrame = 4

    init(_ inner: RTCVideoDecoder, requests: UUKeyFrameRequests) {
        self.inner = inner
        self.requests = requests
        seen = requests.current
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) { inner.setCallback(callback) }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { inner.startDecode(withNumberOfCores: numberOfCores) }
    func release() -> Int { inner.release() }
    func implementationName() -> String { inner.implementationName() }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let result = inner.decode(encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
        let current = requests.current
        guard result == UUHEVCDecoder.ok, current != seen, encodedImage.frameType != .videoFrameKey else {
            seen = current
            return result
        }
        seen = current
        return Self.okRequestKeyFrame
    }
}

/// H.265 (ours) and H.264 (WebRTC's own VideoToolbox decoder): what UU
/// hosts send, both decoded into pixel buffers.
final class UUDecoderFactory: NSObject, RTCVideoDecoderFactory, Sendable {
    private let fallback = RTCDefaultVideoDecoderFactory()
    let requests = UUKeyFrameRequests()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        [RTCVideoCodecInfo(name: "H265")] + fallback.supportedCodecs().filter { $0.name == "H264" }
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        let decoder: RTCVideoDecoder? = info.name == "H265" ? UUHEVCDecoder() : fallback.createDecoder(info)
        return decoder.map { UUKeyFrameRequestingDecoder($0, requests: requests) }
    }
}
