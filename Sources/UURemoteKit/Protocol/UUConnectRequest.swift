//
//  UUConnectRequest.swift
//  UURemoteKit
//
//  What a viewer sends with its request for control: the ConnectOptions
//  attachment and the `streamer_data` JSON.
//

import Foundation

enum UUConnectRequest {
    /// The version the host compares against its moving baseline; under it,
    /// the host refuses the viewer ("控制端版本过低"). The official macOS
    /// viewer reports 4.48.4.
    static let clientVersion = "4.48.4"
    static let clientTypeMac: Int32 = 4
    static let captureDesktop: Int32 = 1
    static let captureTerminal: Int32 = 8

    /// ConnectOptions for a desktop (screen, input, clipboard) or a terminal
    /// connection (terminals and port mappings, no video).
    static func options(purpose: UUConnectionPurpose, deviceID: String, settings: UUStreamSettings) -> Data {
        var options = UUProtoConnectOptions()
        let desktop = purpose == .desktop
        options.captureType = desktop ? captureDesktop : captureTerminal
        // The official viewer sends UINT64_MAX for both capture types.
        options.typeValue = .max
        options.deviceID = deviceID
        options.clientType = clientTypeMac
        options.clientVersion = clientVersion
        options.controlConnectType = 1
        // Every codec and chroma decoded; the host picks.
        for codec in [UUCodec.h265, UUCodec.h264] {
            for chroma in [UUChroma.c420, UUChroma.c444] {
                var cap = UUProtoDecoderCap()
                cap.fps = Int32(settings.fps)
                cap.codec = codec
                cap.width = 3840
                cap.height = 2160
                cap.chroma = desktop ? chroma : 0
                options.decoderCaps.append(cap)
            }
        }
        if desktop {
            var params = UUProtoCaptureParams()
            params.fpsTier = Int32(UUFpsTier.tier(forFPS: settings.fps))
            params.videoQuality = Int32(settings.quality)
            params.chooseResolutionType = 2 // follow the viewer's
            params.localResolution = resolution(1920, 1080)
            params.chooseResolution = UUProtoScreenResolution() // sent empty, as the official viewer does
            params.chromaFormat = UUChroma.c420 // 4:4:4 is asked for in the capture settings
            params.enableHdr = true
            params.fpsCount = Int32(settings.fps)
            options.captureParams = params
            var mode = UUProtoVirtualDisplayMode()
            mode.width = 1920
            mode.height = 1080
            mode.fps = Int32(settings.fps)
            options.virtualDisplayModes = [mode]
            options.virtualDisplayInitResolution = resolution(1920, 1080)
            options.featureFlags = UUControl.viewerFeatureFlags()
        }
        return (try? options.serializedData()) ?? Data()
    }

    private static func resolution(_ width: Int32, _ height: Int32) -> UUProtoScreenResolution {
        var resolution = UUProtoScreenResolution()
        resolution.width = width
        resolution.height = height
        return resolution
    }

    /// `streamer_data`: `{control_id, device_capability: {display_info,
    /// ice_id, video_codec_capability}}`, sent as a JSON string.
    static func streamerData(controlID: String, fps: Int) -> [String: Any] {
        var capability: [[String: Any]] = []
        for codec in [UUCodec.h264, UUCodec.h265] {
            for chroma in [UUChroma.c420, UUChroma.c444] {
                capability.append([
                    "video_codec": codec,
                    "chroma_sampling": chroma,
                    "codec_impl": 34, // the official Mac viewer's
                    "bit_depth": 8,
                    "width": 3840,
                    "height": 2160,
                ])
            }
        }
        return [
            "control_id": controlID,
            "device_capability": [
                "display_info": [["id": 1, "fps": fps, "type": 0, "hdr": 0]],
                "ice_id": "",
                "video_codec_capability": capability,
            ],
        ]
    }
}
