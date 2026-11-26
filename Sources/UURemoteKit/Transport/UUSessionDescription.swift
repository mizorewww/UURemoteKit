//
//  UUSessionDescription.swift
//  UURemoteKit
//
//  What the viewer reads from and adds to session descriptions.
//

import Foundation

enum UUSessionDescription {
    /// The offer as sent (the one set locally stays as it was): a bare
    /// session-level `a=x-uuremote-quic` like the official viewer's, and a
    /// 256 KB `a=max-message-size` on the SCTP m-line, without which the
    /// host assumes 64 KB and drops larger replies.
    static func offerForHost(_ sdp: String) -> String {
        var sdp = sdp
        if !sdp.contains("a=x-uuremote-quic"), let group = sdp.range(of: "a=group:BUNDLE") {
            sdp.insert(contentsOf: "a=x-uuremote-quic\r\n", at: group.lowerBound)
        }
        return sdp.contains("a=max-message-size:") ? sdp : withMaxMessageSize(sdp)
    }

    /// `a=max-message-size:262144` after each `a=sctp-port:` line.
    static func withMaxMessageSize(_ sdp: String) -> String {
        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines: [String] = []
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            lines.append(line)
            if line.hasPrefix("a=sctp-port:") { lines.append("a=max-message-size:262144") }
        }
        return lines.joined(separator: eol)
    }

    /// The SDP of a `soac` body: plain `sdp`, or `gzip_sdp` as base64 (a
    /// binary attachment arrives hydrated to base64).
    static func sdp(in body: [String: Any]) -> String? {
        if let sdp = body["sdp"] as? String, sdp.utf8.count <= 1024 * 1024 { return sdp }
        guard let compressed = (body["gzip_sdp"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let data = try? UUGzip.decompress(compressed)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Video tracks in an answer, by the host's track index: from an
    /// `a=msid:… video_N` line where there is one, otherwise the lowest
    /// index no line names, in the video m-lines' order. `named` are the
    /// mids whose line named their index.
    static func videoTrackMids(in sdp: String) -> (mids: [Int: String], named: Set<String>) {
        var lines: [(mid: String, index: Int?)] = []
        var inVideo = false
        var mid: String?
        var named: Int?
        func close() {
            guard inVideo, let mid else { return }
            lines.append((mid, named))
        }
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                close()
                let port = line.split(separator: " ").dropFirst().first
                inVideo = line.hasPrefix("m=video ") && port != "0"
                mid = nil
                named = nil
            } else if inVideo, line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst("a=mid:".count))
            } else if inVideo, line.hasPrefix("a=msid:") {
                let words = line.split(separator: " ")
                if words.count > 1, words[1].hasPrefix("video_") { named = Int(words[1].dropFirst("video_".count)) }
            }
        }
        close()
        var result: [Int: String] = [:]
        for line in lines { if let index = line.index, result[index] == nil { result[index] = line.mid } }
        var next = 0
        for line in lines where line.index.map({ result[$0] != line.mid }) ?? true {
            while result[next] != nil { next += 1 }
            result[next] = line.mid
        }
        let certain = Set(result.compactMap { index, mid in lines.contains { $0.mid == mid && $0.index == index } ? mid : nil })
        return (result, certain)
    }
}
