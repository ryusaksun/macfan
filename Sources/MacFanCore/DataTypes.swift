import Foundation

/// SMC 数据类型编解码
public enum DataTypes {

    // MARK: - flt (IEEE 754 Float, 4 bytes)

    public static func decodeFloat(_ bytes: [UInt8], size: UInt32) -> Float {
        guard size >= 4 else { return 0 }
        var value: Float = 0
        let data = Data([bytes[0], bytes[1], bytes[2], bytes[3]])
        _ = withUnsafeMutableBytes(of: &value) { ptr in
            data.copyBytes(to: ptr)
        }
        return value
    }

    public static func encodeFloat(_ value: Float) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    // MARK: - sp78 (Signed 8.8 Fixed Point, 2 bytes)

    public static func decodeSP78(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 2 else { return 0 }
        // 用 bitPattern 解释符号位；Int16(UInt16) 在高位为 1 时会崩溃
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    public static func encodeSP78(_ value: Double) -> [UInt8] {
        // 越界或 NaN 直接转换会触发运行时陷阱（Helper 以 root 运行，必须避免崩溃）
        let scaled = value.isFinite ? (value * 256.0).rounded() : 0
        let raw = Int16(max(Double(Int16.min), min(Double(Int16.max), scaled)))
        return [UInt8(truncatingIfNeeded: raw >> 8),
                UInt8(truncatingIfNeeded: raw & 0xFF)]
    }

    // MARK: - fpe2 (Unsigned 14.2 Fixed Point, 2 bytes)

    public static func decodeFPE2(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 2 else { return 0 }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    public static func encodeFPE2(_ value: Double) -> [UInt8] {
        let scaled = value.isFinite ? (value * 4.0).rounded() : 0
        let raw = UInt16(max(0, min(Double(UInt16.max), scaled)))
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    // MARK: - Integer types

    public static func decodeUInt8(_ bytes: [UInt8]) -> UInt8 {
        guard !bytes.isEmpty else { return 0 }
        return bytes[0]
    }

    public static func encodeUInt8(_ value: UInt8) -> [UInt8] {
        return [value]
    }

    public static func decodeUInt16(_ bytes: [UInt8]) -> UInt16 {
        guard bytes.count >= 2 else { return 0 }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    public static func encodeUInt16(_ value: UInt16) -> [UInt8] {
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    public static func decodeUInt32(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 4 else { return 0 }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    // MARK: - 通用格式化

    public static func formatValue(bytes: [UInt8], dataType: FourCharCode, dataSize: UInt32) -> String {
        let typeStr = dataType.toString

        switch typeStr {
        case "flt ":
            return String(format: "%.2f", decodeFloat(bytes, size: dataSize))
        case "sp78":
            return String(format: "%.2f", decodeSP78(bytes))
        case "fpe2":
            return String(format: "%.2f", decodeFPE2(bytes))
        case "ui8 ":
            return "\(decodeUInt8(bytes))"
        case "ui16":
            return "\(decodeUInt16(bytes))"
        case "ui32":
            return "\(decodeUInt32(bytes))"
        case "si8 ":
            guard !bytes.isEmpty else { return "0" }
            return "\(Int8(bitPattern: bytes[0]))"
        case "flag":
            return decodeUInt8(bytes) == 1 ? "true" : "false"
        default:
            let hex = bytes.prefix(Int(dataSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "[\(hex)]"
        }
    }
}
