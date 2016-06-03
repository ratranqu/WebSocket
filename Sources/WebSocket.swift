// Socket.swift
//
// The MIT License (MIT)
//
// Copyright (c) 2015 Zewo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

@_exported import Event
@_exported import Base64

public enum WebSocketError: ErrorProtocol {
    case noFrame
    case invalidOpCode
    case maskedFrameFromServer
    case unaskedFrameFromClient
    case controlFrameNotFinal
    case controlFrameInvalidLength
    case continuationOutOfOrder
    case dataFrameWithInvalidBits
    case maskKeyInvalidLength
    case noMaskKey
    case invalidUTF8Payload
    case invalidCloseCode
}

public final class WebSocket {
    private static let GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public enum Mode {
        case server
        case client
    }

    private enum State {
        case header
        case headerExtra
        case payload
    }

    private enum CloseState {
        case open
        case serverClose
        case clientClose
    }

    public let mode: Mode
    // public let request: Request
    // public let response: Response
    private let stream: Stream
    private var state: State = .header
    private var closeState: CloseState = .open

    private var incompleteFrame: Frame?
    private var continuationFrames: [Frame] = []

    private let binaryEventEmitter = EventEmitter<Data>()
    private let textEventEmitter = EventEmitter<String>()
    private let pingEventEmitter = EventEmitter<Data>()
    private let pongEventEmitter = EventEmitter<Data>()
    private let closeEventEmitter = EventEmitter<(code: CloseCode?, reason: String?)>()

    public init(stream: Stream, mode: Mode) { //, request: Request, response: Response) {
        self.stream = stream
        self.mode = mode
        // self.request = request
        // self.response = response
    }

    public func onBinary(_ listen: EventListener<Data>.Listen) -> EventListener<Data> {
        return binaryEventEmitter.addListener(listen: listen)
    }

    public func onText(_ listen: EventListener<String>.Listen) -> EventListener<String> {
        return textEventEmitter.addListener(listen: listen)
    }

    public func onPing(_ listen: EventListener<Data>.Listen) -> EventListener<Data> {
        return pingEventEmitter.addListener(listen: listen)
    }

    public func onPong(_ listen: EventListener<Data>.Listen) -> EventListener<Data> {
        return pongEventEmitter.addListener(listen: listen)
    }

    public func onClose(_ listen: EventListener<(code: CloseCode?, reason: String?)>.Listen) -> EventListener<(code: CloseCode?, reason: String?)> {
        return closeEventEmitter.addListener(listen: listen)
    }

    public func send(_ string: String) throws {
        try send(.text, data: string.data)
    }

    public func send(_ data: Data) throws {
        try send(.binary, data: data)
    }

    public func send(_ convertible: DataConvertible) throws {
        try send(.binary, data: convertible.data)
    }

    public func close(_ code: CloseCode = .normal, reason: String? = nil) throws {
        if closeState == .serverClose {
            return
        }

        if closeState == .open {
            closeState = .serverClose
        }

        var data = Data(number: code.code)

        if let reason = reason {
            data += reason
        }

        if closeState == .serverClose && code == .protocolError {
            try stream.close()
        }

        try send(.close, data: data)

        if closeState == .clientClose {
            try stream.close()
        }
    }

    public func ping(_ data: Data = []) throws {
        try send(.ping, data: data)
    }

    public func ping(_ convertible: DataConvertible) throws {
        try send(.ping, data: convertible.data)
    }

    public func pong(_ data: Data = []) throws {
        try send(.pong, data: data)
    }

    public func pong(_ convertible: DataConvertible) throws {
        try send(.pong, data: convertible.data)
    }

    public func start() throws {
        while !stream.closed {
            do {
                let data = try stream.receive(upTo: 4096)
                try processData(data)
            } catch StreamError.closedStream {
                break
            }
        }
        if closeState == .open {
            try closeEventEmitter.emit((code: .abnormal, reason: nil))
        }
    }

    private func processData(_ data: Data) throws {
        guard data.count > 0 else {
            return
        }

        var totalBytesRead = 0

        while totalBytesRead < data.count {
            let bytesRead = try readBytes(Data(data[totalBytesRead ..< data.count]))

            if bytesRead == 0 {
                break
            }

            totalBytesRead += bytesRead
        }
    }

    private func readBytes(_ data: Data) throws -> Int {
        if data.count == 0 {
            return 0
        }

        var remainingData = data

        repeat {
            if incompleteFrame == nil {
                incompleteFrame = Frame()
            }

            // Use ! because if let will add data to a copy of the frame
            remainingData = incompleteFrame!.add(data: remainingData)

            if incompleteFrame!.isComplete {
                try validateFrame(incompleteFrame!)
                try processFrame(incompleteFrame!)
                incompleteFrame = nil
            }
        } while remainingData.count > 0

        return data.count
    }

    private func validateFrame(_ frame: Frame) throws {
        func fail(_ error: ErrorProtocol) throws -> ErrorProtocol {
            try close(.protocolError)
            return error
        }

        guard !frame.rsv1 && !frame.rsv2 && !frame.rsv3 else {
            throw try fail(WebSocketError.dataFrameWithInvalidBits)
        }

        guard frame.opCode != .invalid else {
            throw try fail(WebSocketError.invalidOpCode)
        }

        guard !frame.masked || self.mode == .server else {
            throw try fail(WebSocketError.maskedFrameFromServer)
        }

        guard frame.masked || self.mode == .client else {
            throw try fail(WebSocketError.unaskedFrameFromClient)
        }

        if frame.opCode.isControl {
            guard frame.fin else {
                throw try fail(WebSocketError.controlFrameNotFinal)
            }

            guard frame.payloadLength < 126 else {
                throw try fail(WebSocketError.controlFrameInvalidLength)
            }

            if frame.opCode == .close && frame.payloadLength == 1 {
                throw try fail(WebSocketError.controlFrameInvalidLength)
            }
        } else {
            if frame.opCode == .continuation && continuationFrames.isEmpty {
                throw try fail(WebSocketError.continuationOutOfOrder)
            }

            if frame.opCode != .continuation && !continuationFrames.isEmpty {
                throw try fail(WebSocketError.continuationOutOfOrder)
            }


        }
    }

    private func processFrame(_ frame: Frame) throws {
        func fail(_ error: ErrorProtocol) throws -> ErrorProtocol {
            try close(.protocolError)
            return error
        }

        if !frame.opCode.isControl {
            continuationFrames.append(frame)
        }

        if !frame.fin {
            return
        }

        var opCode = frame.opCode


        if frame.opCode == .continuation {
            let firstFrame = continuationFrames.first!
            opCode = firstFrame.opCode
        }

        switch opCode {
        case .binary:
            try binaryEventEmitter.emit(continuationFrames.payload)
        case .text:
            if (try? String(data: continuationFrames.payload)) == nil {
                throw try fail(WebSocketError.invalidUTF8Payload)
            }
            try textEventEmitter.emit(try String(data: continuationFrames.payload))
        case .ping:
            try pingEventEmitter.emit(frame.payload)
        case .pong:
            try pongEventEmitter.emit(frame.payload)
        case .close:
            if self.closeState == .open {
                var rawCloseCode: UInt16?
                var closeReason: String?
                var data = frame.payload

                if data.count >= 2 {
                    rawCloseCode = UInt16(Data(data.prefix(2)).toInt(size: 2))
                    data.removeFirst(2)

                    if data.count > 0 {
                        closeReason = try? String(data: data)
                    }

                    if data.count > 0 && closeReason == nil {
                        throw try fail(WebSocketError.invalidUTF8Payload)
                    }
                }

                closeState = .clientClose

                if let rawCloseCode = rawCloseCode {
                    let closeCode = CloseCode(code: rawCloseCode)
                    if closeCode.isValid {
                        try close(closeCode ?? .normal, reason: closeReason)
                        try closeEventEmitter.emit((closeCode, closeReason))
                    } else {
                        throw try fail(WebSocketError.invalidCloseCode)
                    }
                } else {
                    try close(reason: nil)
                    try closeEventEmitter.emit((nil, nil))
                }
            } else if self.closeState == .serverClose {
                try stream.close()
            }
        default:
            break
        }

        if !frame.opCode.isControl {
            continuationFrames.removeAll()
        }
    }

    private func send(_ opCode: Frame.OpCode, data: Data) throws {
        let maskKey: Data
        if mode == .client {
            maskKey = try Data(randomBytes: 4)
        } else {
            maskKey = []
        }
        let frame = Frame(opCode: opCode, data: data, maskKey: maskKey)
        let data = frame.data
        try stream.send(data)
        try stream.flush()
    }

    public static func accept(_ key: String) -> String? {
        return Base64.encode(sha1((key + GUID).data))
    }
}
