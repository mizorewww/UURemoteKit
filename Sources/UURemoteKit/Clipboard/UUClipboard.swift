//
//  UUClipboard.swift
//  UURemoteKit
//
//  The clipboard on TEXT_DATA_CHANNEL. A host may use any of three forms:
//
//  - `ClipboardChange` (field 17): the older plain stream, chunked.
//  - RpcRequest `clipboard_text` (case 10): what the official Windows host
//    applies, and what mobile viewers send.
//  - The rich negotiation (RpcRequest case 9, RpcResponse case 5): the only
//    form the official Mac host exchanges. The offerer lists formats, the
//    taker asks for one, the offerer confirms and sends it in blocks.
//

import Foundation

/// The text formats the rich negotiation carries. Windows hosts offer and
/// ask for CF_UNICODETEXT (13, UTF-16LE with CRLF line endings); the Mac host
/// offers its pasteboard as format 0 named `public.utf8-plain-text`.
enum UUClipboardFormat: Equatable {
    case windows
    case mac

    static let windowsID: UInt64 = 13
    static let macName = "public.utf8-plain-text"

    init?(_ format: UUProtoClipboardFormat) {
        if format.id == Self.windowsID { self = .windows; return }
        if format.name == Self.macName || format.alternateName == Self.macName { self = .mac; return }
        // The Mac host's format is 0; taken when the name is missing too.
        if format.id == 0 { self = .mac; return }
        return nil
    }

    var id: UInt64 { self == .windows ? Self.windowsID : 0 }

    var requestName: String { self == .windows ? "CF_UNICODETEXT" : Self.macName }

    /// An offer names no predefined Windows format: Windows registers even a
    /// predefined one as custom when it has a name.
    var offer: UUProtoClipboardFormat {
        var format = UUProtoClipboardFormat()
        format.id = id
        if self == .mac { format.name = Self.macName }
        return format
    }

    func encode(_ text: String) -> Data {
        switch self {
        case .windows:
            let crlf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            var data = Data()
            for unit in crlf.utf16 {
                data.append(UInt8(unit & 0xFF))
                data.append(UInt8(unit >> 8))
            }
            data.append(contentsOf: [0, 0])
            return data
        case .mac:
            return Data(text.utf8)
        }
    }

    func decode(_ data: Data) -> String? {
        switch self {
        case .windows:
            guard data.count.isMultiple(of: 2) else { return nil }
            var units = stride(from: data.startIndex, to: data.endIndex, by: 2).map {
                UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
            }
            if units.last == 0 { units.removeLast() }
            guard !units.contains(0) else { return nil }
            return String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\r\n", with: "\n")
        case .mac:
            var bytes = data
            if bytes.last == 0 { bytes.removeLast() }
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { return nil }
            return text
        }
    }
}

enum UUClipboardLimit {
    static let maxText = 30 * 1024
    /// Chunks small enough that UTF-16 plus framing stays below the channel
    /// reader's 65535 bytes.
    static let chunkBytes = 8192
    /// Rich transfer blocks.
    static let blockBytes = 0x20000
    static let maxBytes = maxText * 2 + 2
}

/// Chunk reassembly: a text bigger than one chunk arrives as several
/// messages sharing an id, complete on the one without `more`.
struct UUClipboardAssembly {
    private var pending: (id: UInt64, text: String, started: Date)?

    mutating func accept(id: UInt64, text: String, more: Bool) -> String? {
        let now = Date()
        var combined = ""
        if let pending, pending.id == id, now.timeIntervalSince(pending.started) < 5 {
            combined = pending.text
        }
        guard combined.utf8.count + text.utf8.count <= UUClipboardLimit.maxText else {
            pending = nil
            return nil
        }
        combined += text
        if more {
            pending = (id, combined, pending?.started ?? now)
            return nil
        }
        pending = nil
        return combined
    }
}

/// The clipboard state machine of one connection: it is fed every
/// TEXT_DATA_CHANNEL message and returns what to send back.
struct UUClipboard {
    /// The text last offered to the host, so its request for it can still
    /// be answered after later local copies.
    private(set) var offeredText: String?
    /// Request and sequence ids count up from 100, like the official viewer's.
    private var sequence: UInt64 = 100
    /// The plain stream and the case-10 changes, apart: a host may interleave them.
    private var streamAssembly = UUClipboardAssembly()
    private var textAssembly = UUClipboardAssembly()
    /// An inbound rich transfer: the key asked with, the format, the block
    /// count the confirmation promised, and the blocks so far.
    private var inbound: (key: String, format: UUClipboardFormat, count: Int?, blocks: [Int: Data])?

    private mutating func next() -> UInt64 {
        sequence = sequence &+ 1
        if sequence < 100 { sequence = 100 }
        return sequence
    }

    private mutating func envelope(_ body: UUProtoMessage.OneOf_Body) -> Data {
        UUControl.envelope(sequence: next(), timestamp: UUControl.nowSeconds, body)
    }

    private mutating func request(_ body: UUProtoRpcRequest.OneOf_Body) -> Data {
        var request = UUProtoRpcRequest()
        request.header.requestID = next()
        request.body = body
        return envelope(.rpcRequest(request))
    }

    private mutating func response(to header: UUProtoRpcHeader, _ body: UUProtoRpcResponse.OneOf_Body) -> Data {
        var response = UUProtoRpcResponse()
        response.header = header
        response.body = body
        return envelope(.rpcResponse(response))
    }

    private mutating func rich(_ kind: UUProtoRichClipboardRequest.OneOf_Kind) -> Data {
        var rich = UUProtoRichClipboardRequest()
        rich.kind = kind
        return request(.richClipboard(rich))
    }

    private mutating func richResponse(to header: UUProtoRpcHeader, _ kind: UUProtoRichClipboardResponse.OneOf_Kind) -> Data {
        var rich = UUProtoRichClipboardResponse()
        rich.kind = kind
        return response(to: header, .richClipboard(rich))
    }

    /// `text` split at most `chunkBytes` apart, on character boundaries.
    static func chunks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [""] }
        var parts: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let width = String(character).utf8.count
            if bytes + width > UUClipboardLimit.chunkBytes, !current.isEmpty {
                parts.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += width
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - A local copy, offered to the host

    /// The messages carrying a local copy to the host. A Windows host writes
    /// the case-10 text (and a rich list after it would replace it with a
    /// placeholder); a Mac host only takes the rich offer. An unknown host
    /// gets the offer first, so the text lands last and wins.
    mutating func offer(_ text: String, hostIsMac: Bool?) -> [Data] {
        guard !text.isEmpty, text.utf8.count <= UUClipboardLimit.maxText, !text.contains("\0") else { return [] }
        offeredText = text
        var list = UUProtoClipboardFormatList()
        list.formats = [UUClipboardFormat.windows.offer, UUClipboardFormat.mac.offer]
        let richOffer = rich(.formatList(list))
        let parts = Self.chunks(text)
        let texts = parts.enumerated().map { index, part -> Data in
            var change = UUProtoClipboardTextChangeRequest()
            change.format = 1
            change.text = part
            change.more = index + 1 < parts.count
            // The envelope's sequence comes before the request's id, as the
            // official viewer numbers them.
            let sequence = next()
            var request = UUProtoRpcRequest()
            request.header.requestID = next()
            request.body = .clipboardText(change)
            return UUControl.envelope(sequence: sequence, timestamp: UUControl.nowSeconds, .rpcRequest(request))
        }
        switch hostIsMac {
        case true?: return [richOffer]
        case false?: return texts
        case nil: return [richOffer] + texts
        }
    }

    // MARK: - Messages from the host

    struct Received: Equatable {
        var replies: [Data] = []
        var text: String?
        /// The message was the clipboard's, even a bare acknowledgement.
        var handled = false
    }

    /// Takes one message; answers what has to be answered and gives the
    /// text once it is complete.
    mutating func receive(_ message: UUProtoMessage) -> Received {
        var result = Received()
        switch message.body {
        case let .clipboardChange(change):
            result.handled = true
            result.text = streamAssembly.accept(id: change.id, text: change.text, more: change.more)
        case let .rpcRequest(request):
            switch request.body {
            case let .clipboardText(change):
                result.handled = true
                receiveTextChange(change, header: request.header, into: &result)
            case let .richClipboard(rich):
                result.handled = true
                receiveRichRequest(rich, header: request.header, into: &result)
            default:
                break
            }
        case let .rpcResponse(response):
            switch response.body {
            case .clipboardText:
                // The acknowledgement of a change of ours.
                result.handled = true
            case let .richClipboard(rich):
                result.handled = true
                if case let .dataConfirm(confirm) = rich.kind { receiveConfirmation(confirm, into: &result) }
            default:
                break
            }
        default:
            break
        }
        if let text = result.text, text.contains("\0") { result.text = nil }
        return result
    }

    /// A case-10 text change: reassembled, the last chunk acknowledged.
    /// Only plain text (format 1) is known to land.
    private mutating func receiveTextChange(_ change: UUProtoClipboardTextChangeRequest, header: UUProtoRpcHeader, into result: inout Received) {
        guard change.format == 1,
              let text = textAssembly.accept(id: UInt64(change.format), text: change.text, more: change.more)
        else { return }
        var answer = UUProtoClipboardTextChangeResponse()
        answer.err = 1
        result.replies.append(response(to: header, .clipboardText(answer)))
        result.text = text
    }

    private mutating func receiveRichRequest(_ rich: UUProtoRichClipboardRequest, header: UUProtoRpcHeader, into result: inout Received) {
        switch rich.kind {
        case let .formatList(list): receiveFormatList(list, header: header, into: &result)
        case let .dataRequest(request): receiveDataRequest(request, header: header, into: &result)
        case let .dataBlock(block): receiveDataBlock(block, header: header, into: &result)
        case nil: break
        }
    }

    /// A format list: acknowledged (even one without text, so the host's
    /// state machine moves on), then the text asked for, in the Windows
    /// format when both are offered.
    private mutating func receiveFormatList(_ list: UUProtoClipboardFormatList, header: UUProtoRpcHeader, into result: inout Received) {
        result.replies.append(richResponse(to: header, .formatList(UUProtoClipboardFormatListAck())))
        let offered = list.formats.compactMap(UUClipboardFormat.init)
        guard let format = offered.contains(.windows) ? .windows : offered.first else {
            inbound = nil
            return
        }
        let id = next()
        let key = String(format: "%08x-0000-4000-8000-%012llx", UInt32(Date().timeIntervalSince1970), id & 0xFFFF_FFFF_FFFF)
        var ask = UUProtoClipboardDataRequest()
        ask.formatID = format.id
        ask.key = key
        ask.formatName = format.requestName
        inbound = (key, format, nil, [:])
        var rich = UUProtoRichClipboardRequest()
        rich.kind = .dataRequest(ask)
        var request = UUProtoRpcRequest()
        request.header.requestID = id
        request.body = .richClipboard(rich)
        result.replies.append(envelope(.rpcRequest(request)))
    }

    /// The host asks for a text we offered: confirmed with the block count,
    /// then sent. A format or text we do not have answers unavailable.
    private mutating func receiveDataRequest(_ request: UUProtoClipboardDataRequest, header: UUProtoRpcHeader, into result: inout Received) {
        let key = request.key
        guard !key.isEmpty, key.count <= 256 else { return }
        let format: UUClipboardFormat? = request.formatID == UUClipboardFormat.windowsID ? .windows
            : request.formatName == UUClipboardFormat.macName ? .mac
            : request.formatID == 0 ? .mac : nil
        let data = format.flatMap { format in offeredText.map(format.encode) }
        let count = data.map { max(1, ($0.count + UUClipboardLimit.blockBytes - 1) / UUClipboardLimit.blockBytes) }
        var confirm = UUProtoClipboardDataConfirm()
        confirm.status = data != nil ? 1 : 2
        confirm.key = key
        confirm.blockCount = UInt64(count ?? 0)
        result.replies.append(richResponse(to: header, .dataConfirm(confirm)))
        guard let data, let count else { return }
        for index in 0 ..< count {
            let start = data.startIndex + index * UUClipboardLimit.blockBytes
            var block = UUProtoClipboardDataBlock()
            block.key = key
            block.index = Int32(index)
            block.data = data[start ..< min(start + UUClipboardLimit.blockBytes, data.endIndex)]
            result.replies.append(rich(.dataBlock(block)))
        }
    }

    /// A block of a transfer we asked for: confirmed, and the text complete
    /// once every promised block is in.
    private mutating func receiveDataBlock(_ block: UUProtoClipboardDataBlock, header: UUProtoRpcHeader, into result: inout Received) {
        let index = Int(block.index)
        guard index >= 0, index <= UUClipboardLimit.maxBytes / UUClipboardLimit.blockBytes + 1,
              block.data.count <= UUClipboardLimit.maxBytes,
              inbound?.key == block.key
        else { return }
        inbound?.blocks[index] = block.data
        var confirm = UUProtoClipboardBlockConfirm()
        confirm.key = block.key
        confirm.index = UInt64(index)
        confirm.status = 1
        result.replies.append(richResponse(to: header, .blockConfirm(confirm)))
        if let text = completeInbound() { result.text = text }
    }

    /// The confirmation of our request: the block count to expect.
    private mutating func receiveConfirmation(_ confirm: UUProtoClipboardDataConfirm, into result: inout Received) {
        guard confirm.status == 1, confirm.key == inbound?.key, confirm.blockCount > 0,
              confirm.blockCount <= UInt64(UUClipboardLimit.maxBytes / UUClipboardLimit.blockBytes + 2)
        else { return }
        inbound?.count = Int(confirm.blockCount)
        if let text = completeInbound() { result.text = text }
    }

    /// Complete when the count is in and every block is here. Hosts may
    /// number blocks from one or from zero; a whole run either way is taken,
    /// never one missing a block in the middle.
    private mutating func completeInbound() -> String? {
        guard let state = inbound, let count = state.count, count > 0 else { return nil }
        let first: Int
        if (0 ..< count).allSatisfy({ state.blocks[$0] != nil }) {
            first = 0
        } else if (1 ... count).allSatisfy({ state.blocks[$0] != nil }) {
            first = 1
        } else {
            return nil
        }
        let data = (first ..< first + count).reduce(into: Data()) { $0.append(state.blocks[$1] ?? Data()) }
        inbound = nil
        guard data.count <= UUClipboardLimit.maxBytes else { return nil }
        return state.format.decode(data)
    }
}
