//
//  UUControl.swift
//  UURemoteKit
//
//  The protobuf messages a viewer sends and reads on the data channels,
//  built from and read into the generated `UUProto*` types.
//

import CoreGraphics
import Foundation
import SwiftProtobuf

enum UUControl {
    /// Milliseconds since 1970, the control channel's timestamps.
    static var nowMilliseconds: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Seconds since 1970, the clipboard's and port mapping's timestamps.
    static var nowSeconds: UInt64 { UInt64(Date().timeIntervalSince1970) }

    static func encode(_ message: UUProtoMessage) -> Data {
        // Serializing a message with no required fields cannot fail.
        (try? message.serializedData()) ?? Data()
    }

    static func envelope(sequence: UInt64, timestamp: UInt64, _ body: UUProtoMessage.OneOf_Body) -> Data {
        var message = UUProtoMessage()
        message.sequence = sequence
        message.timestamp = timestamp
        message.body = body
        return encode(message)
    }

    /// A message from the host; nil for anything else (input JSON echoed on
    /// the control channel, a TERM frame).
    static func decode(_ data: Data) -> UUProtoMessage? {
        try? UUProtoMessage(serializedBytes: data)
    }

    // MARK: - Heartbeats

    /// The flag versions the viewer advertises, as the official viewer does
    /// (clipboard 3 only with clipboard sync).
    static func viewerFeatureFlags(clipboard: Bool = true) -> UUProtoFeatureFlags {
        var flags = UUProtoFeatureFlags()
        flags.captureSetting = 6
        flags.simpleAction = 2
        flags.systemMetrics = 1
        flags.privateScreen = 2
        flags.fileTransferFtp = 2
        flags.fileTransferFtp2 = 2
        flags.clipboard = clipboard ? 3 : 0
        flags.qosStat = 1
        return flags
    }

    /// The echo request sent every 100 ms once the control channel opens.
    static func echoRequest(sequence: UInt64, timestamp: UInt64 = nowMilliseconds) -> Data {
        var action = UUProtoSimpleAction()
        action.action = .echoRequest
        action.featureFlags = viewerFeatureFlags()
        return envelope(sequence: sequence, timestamp: timestamp, .simpleAction(action))
    }

    /// The answer to the host's echo request `requestSequence`.
    static func echoResponse(sequence: UInt64, timestamp: UInt64 = nowMilliseconds, requestSequence: UInt64, clipboard: Bool = true) -> Data {
        var action = UUProtoSimpleAction()
        action.action = .echoResponse
        action.argsJson = json(["seq": requestSequence])
        var flags = UUProtoFeatureFlags()
        flags.captureSetting = 6
        flags.simpleAction = 2
        flags.systemMetrics = 1
        flags.fileTransferFtp = 2
        flags.clipboard = clipboard ? 3 : 0
        action.featureFlags = flags
        return envelope(sequence: sequence, timestamp: timestamp, .simpleAction(action))
    }

    /// The `seq` of an echo request's arguments.
    static func echoSequence(_ action: UUProtoSimpleAction) -> UInt64 {
        struct Args: Decodable { var seq: UInt64 }
        return (try? JSONDecoder().decode(Args.self, from: Data(action.argsJson.utf8)))?.seq ?? 0
    }

    // MARK: - Screens

    /// `restart_capture` or `stop_capture` for one screen: the official
    /// viewer starts a screen's stream with the first and ends it with the
    /// second.
    static func captureScreen(_ screenID: Int, start: Bool, sequence: UInt64) -> Data {
        var action = UUProtoSimpleAction()
        action.action = start ? .restartCapture : .stopCapture
        action.argsJson = json(["screen_id": screenID])
        return envelope(sequence: sequence, timestamp: nowMilliseconds, .simpleAction(action))
    }

    /// The screens and the current one. A track index the host leaves off is
    /// 0 once it says any other screen's, unknown otherwise; an absent
    /// current id is 0 when a screen has that id.
    static func screens(from sources: UUProtoScreenSources) -> (screens: [UUScreen], currentID: Int?) {
        let anyTrackSaid = sources.screens.contains(where: \.hasVideoTrackIndex)
        let screens = sources.screens.map { screen -> UUScreen in
            var result = UUScreen(id: Int(screen.id))
            result.fps = Int(screen.fps)
            result.isVirtual = screen.screenType == 1
            result.isPrimary = screen.isPrimary
            result.name = screen.displayName.isEmpty ? "Display \(screen.id)" : screen.displayName
            let size = (screen.hasCurrentResolution ? pixelSize(screen.currentResolution) : nil)
                ?? screen.resolutions.lazy.compactMap(pixelSize).first
            if let size { (result.width, result.height) = size }
            if screen.hasVideoTrackIndex {
                result.videoTrackIndex = screen.videoTrackIndex >= 0 ? Int(screen.videoTrackIndex) : nil
            } else if anyTrackSaid {
                result.videoTrackIndex = 0
            }
            return result
        }
        var currentID = sources.hasCurrentScreenID ? Int(sources.currentScreenID) : nil
        if currentID == nil, screens.contains(where: { $0.id == 0 }) { currentID = 0 }
        return (screens, currentID)
    }

    /// A WinRect's size in pixels, or in points when it gives no pixels.
    private static func pixelSize(_ rect: UUProtoWinRect) -> (Int, Int)? {
        if rect.pixelWidth > 0, rect.pixelHeight > 0 { return (Int(rect.pixelWidth), Int(rect.pixelHeight)) }
        if rect.width > 0, rect.height > 0 { return (Int(rect.width), Int(rect.height)) }
        return nil
    }

    /// The host's pointer shape, its hotspot as `x`/`y`.
    static func cursor(from shape: UUProtoCursorShape) -> UUCursor {
        UUCursor(
            x: Double(shape.x),
            y: Double(shape.y),
            width: Int(shape.width),
            height: Int(shape.height),
            image: image(rgba: shape.rgba, width: Int(shape.width), height: Int(shape.height)),
            visible: shape.visible
        )
    }

    static func image(rgba: Data, width: Int, height: Int) -> CGImage? {
        // A cursor is small; the bound also keeps width * height * 4 from overflowing.
        guard (1 ... 4096).contains(width), (1 ... 4096).contains(height),
              rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - RPC

    static func rpcRequest(requestID: UInt64, _ body: UUProtoRpcRequest.OneOf_Body) -> Data {
        var request = UUProtoRpcRequest()
        request.header.requestID = requestID
        request.body = body
        return envelope(sequence: requestID, timestamp: nowMilliseconds, .rpcRequest(request))
    }

    /// The tracks the viewer has, which the host may stream screens on.
    static func sendVideoTrack(requestID: UInt64, tracks: [Int]) -> Data {
        var body = UUProtoSendVideoTrack()
        body.videoTrackIndexes = tracks.map { Int32(clamping: $0) }
        return rpcRequest(requestID: requestID, .sendVideoTrack(body))
    }

    /// The whole picture request, as the official viewer sends it on every
    /// change: no single monitor (-2), resolution unchanged (-1), the largest
    /// frame decoded, HD as the automatic floor.
    static func captureSetting(requestID: UInt64, settings: UUStreamSettings, codec: Int32, fpsCount: Int32, cursorCapture: Bool) -> Data {
        var body = UUProtoCaptureSettingRequest()
        body.fpsTier = Int32(UUFpsTier.tier(forFPS: settings.fps))
        body.quality = Int32(settings.quality)
        body.cursorCapture = cursorCapture ? 1 : 0
        body.screenID = -2
        body.width = -1
        body.height = -1
        body.chroma = settings.trueColor ? UUChroma.c444 : UUChroma.c420
        body.resolutionType = 1
        body.autoQuality = Int32(UUStreamSettings.qualityHD)
        body.codec = codec
        body.maxWidth = 3840
        body.maxHeight = 2160
        body.fpsCount = fpsCount
        return rpcRequest(requestID: requestID, .captureSetting(body))
    }

    /// A UU virtual screen of `width` × `height`.
    static func createVirtualDisplay(requestID: UInt64, width: Int, height: Int) -> Data {
        var resolution = UUProtoScreenResolution()
        resolution.width = Int32(clamping: width)
        resolution.height = Int32(clamping: height)
        var body = UUProtoCreateVirtualDisplay()
        body.localResolution = [resolution]
        body.count = 1
        return rpcRequest(requestID: requestID, .createVirtualDisplay(body))
    }

    static func removeVirtualDisplay(requestID: UInt64, screenID: Int) -> Data {
        var body = UUProtoRemoveVirtualDisplay()
        body.screenIds = [Int32(clamping: screenID)]
        return rpcRequest(requestID: requestID, .removeVirtualDisplay(body))
    }

    struct RPCFailure: Equatable, Sendable {
        var code: Int
        var message: String
        var detail: String
    }

    /// The host's answer to a picture request: the request and its errors
    /// (none: applied). An answer with no errors leaves its body off, so a
    /// response is one unless it carries another case.
    static func captureSettingAnswer(_ message: UUProtoMessage) -> (requestID: UInt64, errors: [RPCFailure])? {
        guard case let .rpcResponse(response) = message.body else { return nil }
        let errors: [UUProtoRpcError]
        switch response.body {
        case let .captureSetting(answer): errors = answer.errors
        case .none where response.header.requestID != 0: errors = []
        default: return nil
        }
        return (response.header.requestID, errors.map { RPCFailure(code: Int($0.code), message: $0.message, detail: $0.detail) })
    }

    // MARK: - JSON

    /// A JSON object as the host reads it in `args_json` and the like.
    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The frame rate *tier* the host takes in capture settings, not a rate.
enum UUFpsTier {
    static func tier(forFPS fps: Int) -> Int {
        switch fps {
        case ..<45: 1
        case ..<75: 2
        case ..<120: 3
        default: 4
        }
    }
}

enum UUChroma {
    static let c420: Int32 = 1
    static let c444: Int32 = 3
}

enum UUCodec {
    static let h264: Int32 = 1
    static let h265: Int32 = 2
}
