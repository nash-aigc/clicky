import Foundation

/// 豆包流式语音识别（火山 v3）的二进制帧编解码。
///
/// 这个文件**只有纯函数**：没有网络、没有状态、没有并发。所以它可以脱离整个
/// App 单独编译运行 —— 一个探针就能把每一帧验到底，不需要启动界面、不需要
/// 麦克风、不需要用户配合。协议里最容易写错的就是这个头，所以每个常量都写清了
/// 它对应协议的哪一位，而不是只留一个魔数。
///
/// 帧结构（ASR 与 TTS 在火山 v3 上共用同一套 4 字节头）：
///
///     byte 0 = (协议版本 << 4) | 头部长度（以 4 字节为单位）
///     byte 1 = (消息类型 << 4) | 消息标志
///     byte 2 = (序列化方式 << 4) | 压缩方式
///     byte 3 = 保留，恒为 0
///     其后   = [4 字节大端 payload 长度][payload]
///
/// 依据：官方文档的协议章节 + `THU-SAGE/syll` 里可跑的实现，逐字节对齐。
///
/// **压缩一律用 `none`，这不是偷懒，是实测结论**（2026-09-25，真服务）：
/// 官方 demo 用 gzip，但服务端同样接受 `compression = 0b0000` 的帧 —— 探针
/// 发出不压缩的配置帧和音频帧，服务端回了正常的 `msgType=0b1001` 响应而不是
/// 错误帧。省掉 gzip 就省掉了「手写 gzip 外壳」这一整块：Foundation 的
/// `.zlib` 产出的是**裸 deflate**（实测前 4 字节 `73 74 1c 05`，不是 zlib 的
/// `78 xx`），要凑成一个合法 gzip 还得自己补 10 字节头 + CRC32 + ISIZE，
/// 而那块代码没有任何办法自证正确。不压缩的代价只是多几个字节的带宽。
nonisolated enum VolcengineASRFrame {

    // MARK: - 协议常量

    /// 协议版本与头部长度，合成头字节 0。恒为 `0x11`。
    static let headerByteZero: UInt8 = (0b0001 << 4) | 0b0001

    enum MessageType: UInt8 {
        /// 全量客户端请求，payload 是 JSON（配置、控制）。
        case fullClientRequest = 0b0001
        /// 纯音频请求，payload 是裸 PCM。
        case audioOnlyRequest = 0b0010
        /// 全量服务端响应，payload 是 JSON。
        case fullServerResponse = 0b1001
        /// 纯音频服务端响应（TTS 用）。
        case audioOnlyResponse = 0b1011
        /// 服务端错误帧。布局与上面几种**不同**，见 `parseErrorFrame`。
        case serverError = 0b1111

        init(raw: UInt8) { self = MessageType(rawValue: raw) ?? .serverError }
    }

    enum MessageFlag: UInt8 {
        /// 无标志。
        case none = 0b0000
        /// 响应里带 sequence 字段（解析时要先跳过 4 字节）。
        case sequencePresent = 0b0001
        /// 客户端发：这是最后一片音频，且不带 sequence。
        case lastPacketNoSequence = 0b0010
    }

    enum Serialization: UInt8 {
        case raw = 0b0000
        case json = 0b0001
    }

    enum Compression: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }

    // MARK: - 编码

    static func packHeader(_ messageType: MessageType,
                           _ flags: UInt8,
                           _ serialization: Serialization,
                           _ compression: Compression) -> Data {
        Data([headerByteZero,
              (messageType.rawValue << 4) | flags,
              (serialization.rawValue << 4) | compression.rawValue,
              0])
    }

    /// 大端 32 位长度。协议里所有长度字段都是大端，写成小端服务端只会当成一个
    /// 荒唐的长度值然后断流 —— 而且不会说为什么。
    static func bigEndianLength(_ count: Int) -> Data {
        Data([UInt8((count >> 24) & 0xff),
              UInt8((count >> 16) & 0xff),
              UInt8((count >> 8) & 0xff),
              UInt8(count & 0xff)])
    }

    /// 配置帧：整段会话的音频格式、模型名、以及各种开关。
    static func fullClientRequest(json: Data) -> Data {
        packHeader(.fullClientRequest, MessageFlag.none.rawValue, .json, .none)
            + bigEndianLength(json.count)
            + json
    }

    /// 音频帧：100ms 一片的裸 PCM16。
    ///
    /// `isLast` 会让服务端把这一片当作流的结束 —— 它随后就会关闭连接。所以
    /// 长录音必须把它留到用户按停止的那一刻，中途永远发 `false`。
    static func audioRequest(pcm: Data, isLastPacket: Bool) -> Data {
        let flags = isLastPacket ? MessageFlag.lastPacketNoSequence.rawValue : MessageFlag.none.rawValue
        return packHeader(.audioOnlyRequest, flags, .raw, .none)
            + bigEndianLength(pcm.count)
            + pcm
    }

    // MARK: - 解码

    enum ParseError: Error, CustomStringConvertible {
        case tooShort(actualBytes: Int)
        case truncatedHeader(actualBytes: Int, neededBytes: Int)
        case truncatedPayload(declaredBytes: Int, availableBytes: Int)
        case undecodableErrorFrame

        var description: String {
            switch self {
            case .tooShort(let actual):
                return "帧只有 \(actual) 字节，连 4 字节头都不够"
            case .truncatedHeader(let actual, let needed):
                return "帧长 \(actual) 字节，但头部声明需要 \(needed) 字节"
            case .truncatedPayload(let declared, let available):
                return "payload 声明 \(declared) 字节，实际只有 \(available) 字节"
            case .undecodableErrorFrame:
                return "服务端错误帧的内容无法解析"
            }
        }
    }

    struct ParsedFrame {
        let messageType: MessageType
        let flags: UInt8
        let payload: Data
        /// 服务端错误帧携带的码。非错误帧为 nil。
        let serverErrorCode: UInt32?
    }

    /// 拆一帧。服务端错误帧的布局和普通响应不同，这里一并处理 —— 否则一个
    /// 鉴权失败会被当成「收到一段解析不了的 JSON」，把真正的原因藏起来。
    static func parse(_ frame: Data) throws -> ParsedFrame {
        let bytes = [UInt8](frame)
        guard bytes.count >= 4 else { throw ParseError.tooShort(actualBytes: bytes.count) }

        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard bytes.count >= headerLength else {
            throw ParseError.truncatedHeader(actualBytes: bytes.count, neededBytes: headerLength)
        }
        let messageType = MessageType(raw: (bytes[1] >> 4) & 0x0F)
        let flags = bytes[1] & 0x0F
        let compression = (bytes[2] & 0x0F)

        var offset = headerLength
        if flags & MessageFlag.sequencePresent.rawValue != 0 { offset += 4 }

        if messageType == .serverError {
            guard bytes.count >= offset + 8 else { throw ParseError.undecodableErrorFrame }
            let errorCode = readBigEndianUInt32(bytes, at: offset)
            offset += 4
            let errorPayload = try readPayload(bytes, at: &offset, compression: compression)
            return ParsedFrame(messageType: messageType, flags: flags,
                               payload: errorPayload, serverErrorCode: errorCode)
        }

        let payload = try readPayload(bytes, at: &offset, compression: compression)
        return ParsedFrame(messageType: messageType, flags: flags,
                           payload: payload, serverErrorCode: nil)
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func readPayload(_ bytes: [UInt8],
                                    at offset: inout Int,
                                    compression: UInt8) throws -> Data {
        guard bytes.count >= offset + 4 else {
            throw ParseError.truncatedHeader(actualBytes: bytes.count, neededBytes: offset + 4)
        }
        let declared = Int(readBigEndianUInt32(bytes, at: offset))
        offset += 4
        let available = bytes.count - offset
        guard declared <= available else {
            throw ParseError.truncatedPayload(declaredBytes: declared, availableBytes: available)
        }
        var payload = Data(bytes[offset..<(offset + declared)])
        if compression == Compression.gzip.rawValue, !payload.isEmpty {
            // 服务端这一侧确实可能压。解开失败就原样返回，让上层看到原始字节，
            // 而不是把一段乱码当成 JSON 去解。
            if let inflated = try? (payload as NSData).decompressed(using: .zlib) as Data {
                payload = inflated
            }
        }
        return payload
    }
}
