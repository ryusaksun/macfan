import Foundation
import IOKit

// MARK: - SMC Data Structures (内部使用)

struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

public struct SMCKeyDataKeyInfo {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0
}

/// IOKit SMC 调用的输入/输出结构 (必须与内核驱动的 SMCParamStruct 完全匹配)
struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCKeyDataVersion = SMCKeyDataVersion()
    var pLimitData: SMCKeyDataPLimitData = SMCKeyDataPLimitData()
    var keyInfo: SMCKeyDataKeyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - 公开数据结构

/// 高层 SMC 值表示
public struct SMCVal {
    public var key: FourCharCode = 0
    public var dataSize: UInt32 = 0
    public var dataType: FourCharCode = 0
    public var bytes: [UInt8] = Array(repeating: 0, count: 32)
}

// MARK: - SMC 命令选择器

enum SMCSelector: UInt8 {
    case kSMCHandleYPCEvent  = 2
    case kSMCReadKey         = 5
    case kSMCWriteKey        = 6
    case kSMCGetKeyFromIndex = 8
    case kSMCGetKeyInfo      = 9
}

// MARK: - SMC 错误类型

public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case failedToOpen
    case keyNotFound(String)
    case readFailed(String, kern_return_t)
    case writeFailed(String, kern_return_t)
    case typeMismatch(expected: String, got: String)
    case invalidData

    public var description: String {
        switch self {
        case .driverNotFound:
            return "找不到 AppleSMC 驱动"
        case .failedToOpen:
            return "无法打开 SMC 连接"
        case .keyNotFound(let key):
            return "SMC key '\(key)' 不存在"
        case .readFailed(let key, let code):
            return "读取 '\(key)' 失败 (错误码: \(code))"
        case .writeFailed(let key, let code):
            return "写入 '\(key)' 失败 (错误码: \(code))"
        case .typeMismatch(let expected, let got):
            return "数据类型不匹配: 期望 \(expected), 得到 \(got)"
        case .invalidData:
            return "数据无效"
        }
    }
}

// MARK: - FourCharCode 辅助

public typealias FourCharCode = UInt32

extension FourCharCode {
    public init(fromString str: String) {
        precondition(str.count == 4, "FourCharCode 必须是 4 个字符")
        let bytes = Array(str.utf8)
        self = UInt32(bytes[0]) << 24
             | UInt32(bytes[1]) << 16
             | UInt32(bytes[2]) << 8
             | UInt32(bytes[3])
    }

    public var toString: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// MARK: - SMCKit 核心类

public final class SMCKit: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var isOpen = false
    private let lock = NSLock()

    public init() {}

    /// 打开与 AppleSMC 的连接
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isOpen else { return }

        let matchingDict = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)

        guard service != 0 else {
            throw SMCError.driverNotFound
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard result == kIOReturnSuccess else {
            throw SMCError.failedToOpen
        }

        isOpen = true
    }

    /// 关闭 SMC 连接
    public func close() {
        lock.lock()
        defer { lock.unlock() }

        if isOpen {
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }
    }

    deinit {
        close()
    }

    // MARK: - 底层调用

    private func callSMC(inputData: inout SMCKeyData) throws -> SMCKeyData {
        var outputData = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCSelector.kSMCHandleYPCEvent.rawValue),
            &inputData,
            MemoryLayout<SMCKeyData>.stride,
            &outputData,
            &outputSize
        )

        guard result == kIOReturnSuccess else {
            throw SMCError.readFailed("call", result)
        }

        return outputData
    }

    /// 获取 key 的信息（数据类型和大小）
    public func getKeyInfo(key: FourCharCode) throws -> SMCKeyDataKeyInfo {
        var inputData = SMCKeyData()
        inputData.key = key
        inputData.data8 = SMCSelector.kSMCGetKeyInfo.rawValue

        let outputData = try callSMC(inputData: &inputData)
        return outputData.keyInfo
    }

    // MARK: - 读取

    /// 读取 SMC key 的原始值
    public func readKey(_ keyStr: String) throws -> SMCVal {
        let key = FourCharCode(fromString: keyStr)
        let keyInfo = try getKeyInfo(key: key)

        var inputData = SMCKeyData()
        inputData.key = key
        inputData.keyInfo.dataSize = keyInfo.dataSize
        inputData.data8 = SMCSelector.kSMCReadKey.rawValue

        let outputData = try callSMC(inputData: &inputData)

        var val = SMCVal()
        val.key = key
        val.dataSize = keyInfo.dataSize
        val.dataType = keyInfo.dataType

        withUnsafePointer(to: outputData.bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { buf in
                for i in 0..<min(Int(keyInfo.dataSize), 32) {
                    val.bytes[i] = buf[i]
                }
            }
        }

        return val
    }

    /// 写入 SMC key
    public func writeKey(_ keyStr: String, dataType: FourCharCode, bytes: [UInt8]) throws {
        let key = FourCharCode(fromString: keyStr)
        let keyInfo = try getKeyInfo(key: key)

        var inputData = SMCKeyData()
        inputData.key = key
        inputData.data8 = SMCSelector.kSMCWriteKey.rawValue
        inputData.keyInfo.dataSize = keyInfo.dataSize

        withUnsafeMutablePointer(to: &inputData.bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { buf in
                for i in 0..<min(bytes.count, 32) {
                    buf[i] = bytes[i]
                }
            }
        }

        let output = try callSMC(inputData: &inputData)

        if output.result != 0 {
            throw SMCError.writeFailed(keyStr, kern_return_t(output.result))
        }
    }

    /// 写入 SMC key (带详细调试输出)
    public func writeKeyDebug(_ keyStr: String, dataType: FourCharCode, bytes: [UInt8]) -> (ioResult: kern_return_t, smcResult: UInt8) {
        let key = FourCharCode(fromString: keyStr)

        let keyInfo: SMCKeyDataKeyInfo
        do {
            keyInfo = try getKeyInfo(key: key)
        } catch {
            return (kIOReturnError, 0xFF)
        }

        var inputData = SMCKeyData()
        inputData.key = key
        inputData.data8 = SMCSelector.kSMCWriteKey.rawValue
        inputData.keyInfo.dataSize = keyInfo.dataSize

        withUnsafeMutablePointer(to: &inputData.bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { buf in
                for i in 0..<min(bytes.count, 32) {
                    buf[i] = bytes[i]
                }
            }
        }

        var outputData = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let ioResult = IOConnectCallStructMethod(
            connection,
            UInt32(SMCSelector.kSMCHandleYPCEvent.rawValue),
            &inputData,
            MemoryLayout<SMCKeyData>.stride,
            &outputData,
            &outputSize
        )

        return (ioResult, outputData.result)
    }

    /// 获取索引位置的 key 名
    public func getKeyAtIndex(_ index: UInt32) throws -> FourCharCode {
        var inputData = SMCKeyData()
        inputData.data8 = SMCSelector.kSMCGetKeyFromIndex.rawValue
        inputData.data32 = index

        let outputData = try callSMC(inputData: &inputData)
        return outputData.key
    }

    // MARK: - 高层读取辅助

    public func readFloat(_ key: String) throws -> Float {
        let val = try readKey(key)
        return DataTypes.decodeFloat(val.bytes, size: val.dataSize)
    }

    public func readSP78(_ key: String) throws -> Double {
        let val = try readKey(key)
        return DataTypes.decodeSP78(val.bytes)
    }

    public func readUInt8(_ key: String) throws -> UInt8 {
        let val = try readKey(key)
        guard val.dataSize >= 1 else { throw SMCError.invalidData }
        return val.bytes[0]
    }

    public func readUInt16(_ key: String) throws -> UInt16 {
        let val = try readKey(key)
        guard val.dataSize >= 2 else { throw SMCError.invalidData }
        return UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1])
    }

    /// 智能读取温度（自动处理 sp78/flt 类型）
    public func readTemperature(_ key: String) throws -> Double {
        let val = try readKey(key)
        let typeStr = val.dataType.toString

        switch typeStr {
        case "sp78":
            return DataTypes.decodeSP78(val.bytes)
        case "flt ":
            return Double(DataTypes.decodeFloat(val.bytes, size: val.dataSize))
        default:
            return DataTypes.decodeSP78(val.bytes)
        }
    }

    /// 智能读取风扇转速（自动处理 flt/fpe2 类型）
    public func readFanSpeed(_ key: String) throws -> Double {
        let val = try readKey(key)
        let typeStr = val.dataType.toString

        switch typeStr {
        case "flt ":
            return Double(DataTypes.decodeFloat(val.bytes, size: val.dataSize))
        case "fpe2":
            return DataTypes.decodeFPE2(val.bytes)
        default:
            return Double(DataTypes.decodeFloat(val.bytes, size: val.dataSize))
        }
    }

    // MARK: - 高层写入辅助

    public func writeUInt8(_ key: String, value: UInt8) throws {
        try writeKey(key, dataType: FourCharCode(fromString: "ui8 "), bytes: [value])
    }

    public func writeFloat(_ key: String, value: Float) throws {
        let bytes = DataTypes.encodeFloat(value)
        try writeKey(key, dataType: FourCharCode(fromString: "flt "), bytes: bytes)
    }

    public func writeFPE2(_ key: String, value: Double) throws {
        let bytes = DataTypes.encodeFPE2(value)
        try writeKey(key, dataType: FourCharCode(fromString: "fpe2"), bytes: bytes)
    }

    /// 智能写入风扇转速（根据 key 的实际数据类型）
    public func writeFanSpeed(_ key: String, rpm: Double) throws {
        let val = try readKey(key)
        let typeStr = val.dataType.toString

        switch typeStr {
        case "flt ":
            try writeFloat(key, value: Float(rpm))
        case "fpe2":
            try writeFPE2(key, value: rpm)
        default:
            try writeFloat(key, value: Float(rpm))
        }
    }
}
