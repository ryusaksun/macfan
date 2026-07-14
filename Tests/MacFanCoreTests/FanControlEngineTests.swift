import XCTest
@testable import MacFanCore

final class FanControlEngineTests: XCTestCase {
    func testSetAllFansUsesEachFanRange() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000), (3_000, 9_000)])
        let engine = makeEngine(smc)

        let result = engine.setAllFans(percent: 50)

        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(smc.fanValues[SMCKeys.fanTargetSpeed(0)], 4_000)
        XCTAssertEqual(smc.fanValues[SMCKeys.fanTargetSpeed(1)], 6_000)
    }

    func testSetAllFansRejectsNonFinitePercentWithoutWriting() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)])
        let result = makeEngine(smc).setAllFans(percent: .nan)

        XCTAssertFalse(result.success)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testTargetFailureRollsBackModeAndFtst() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)], hasFtst: true)
        smc.alwaysFailWrites.insert(SMCKeys.fanTargetSpeed(0))

        let result = makeEngine(smc).setFanSpeed(fanID: 0, rpm: 4_000)

        XCTAssertFalse(result.success)
        XCTAssertEqual(smc.uint8Values[SMCKeys.fanMode(0)], 0)
        XCTAssertEqual(smc.uint8Values[SMCKeys.forceMode], 0)
        XCTAssertTrue(smc.writes.contains("\(SMCKeys.forceMode)=1"))
        XCTAssertTrue(smc.writes.contains("\(SMCKeys.forceMode)=0"))
    }

    func testManualModeFailureClearsFtst() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)], hasFtst: true)
        smc.unreadableUInt8Keys.insert(SMCKeys.fanMode(0))

        let result = makeEngine(smc).setFanSpeed(fanID: 0, rpm: 4_000)

        XCTAssertFalse(result.success)
        XCTAssertEqual(smc.uint8Values[SMCKeys.forceMode], 0)
    }

    func testResetWithZeroFansStillClearsFtst() {
        let smc = MockSMC(fanRanges: [], hasFtst: true)
        smc.uint8Values[SMCKeys.forceMode] = 1

        let result = makeEngine(smc).resetAllFans()

        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(smc.uint8Values[SMCKeys.forceMode], 0)
    }

    func testResetSingleFanClearsFtstBeforeMode() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)], hasFtst: true)
        smc.uint8Values[SMCKeys.forceMode] = 1
        smc.uint8Values[SMCKeys.fanMode(0)] = 1

        let result = makeEngine(smc).resetFan(fanID: 0)

        XCTAssertTrue(result.success, result.message)
        let ftstIndex = smc.writes.firstIndex(of: "\(SMCKeys.forceMode)=0")
        let modeIndex = smc.writes.firstIndex(of: "\(SMCKeys.fanMode(0))=0")
        XCTAssertLessThan(try XCTUnwrap(ftstIndex), try XCTUnwrap(modeIndex))
    }

    func testResetAllFansClearsFtstBeforeFanModes() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)], hasFtst: true)
        smc.uint8Values[SMCKeys.forceMode] = 1
        smc.uint8Values[SMCKeys.fanMode(0)] = 1

        let result = makeEngine(smc).resetAllFans()

        XCTAssertTrue(result.success, result.message)
        let ftstIndex = smc.writes.firstIndex(of: "\(SMCKeys.forceMode)=0")
        let modeIndex = smc.writes.firstIndex(of: "\(SMCKeys.fanMode(0))=0")
        XCTAssertLessThan(try XCTUnwrap(ftstIndex), try XCTUnwrap(modeIndex))
    }

    func testResetAllFansReportsAnyFailure() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000), (2_000, 7_000)])
        smc.uint8Values[SMCKeys.fanMode(0)] = 1
        smc.uint8Values[SMCKeys.fanMode(1)] = 1
        smc.alwaysFailWrites.insert(SMCKeys.fanMode(1))

        let result = makeEngine(smc).resetAllFans()

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("风扇 1"))
        XCTAssertEqual(smc.uint8Values[SMCKeys.fanMode(0)], 0)
        XCTAssertEqual(smc.uint8Values[SMCKeys.fanMode(1)], 1)
    }

    func testLegacyModeKeyIsSupported() {
        let smc = MockSMC(fanRanges: [(2_000, 6_000)], useLegacyModeKeys: true)

        let result = makeEngine(smc).setFanSpeed(fanID: 0, rpm: 4_000)

        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(smc.uint8Values[SMCKeys.fanModeLegacy(0)], 1)
    }

    private func makeEngine(_ smc: MockSMC) -> FanControlEngine {
        FanControlEngine(
            smc: smc,
            retryCount: 2,
            retryDelayMicroseconds: 0,
            forceModeDelayMicroseconds: 0
        )
    }
}

private enum MockError: Error {
    case missing(String)
    case writeFailed(String)
}

private final class MockSMC: SMCBackend {
    var uint8Values: [String: UInt8] = [:]
    var fanValues: [String: Double] = [:]
    var keys: Set<String> = []
    var writes: [String] = []
    var alwaysFailWrites: Set<String> = []
    var unreadableUInt8Keys: Set<String> = []

    init(
        fanRanges: [(Double, Double)],
        hasFtst: Bool = false,
        useLegacyModeKeys: Bool = false
    ) {
        uint8Values[SMCKeys.fanCount] = UInt8(fanRanges.count)
        keys.insert(SMCKeys.fanCount)
        if hasFtst {
            keys.insert(SMCKeys.forceMode)
            uint8Values[SMCKeys.forceMode] = 0
        }
        for (fanID, range) in fanRanges.enumerated() {
            let modeKey = useLegacyModeKeys ? SMCKeys.fanModeLegacy(fanID) : SMCKeys.fanMode(fanID)
            keys.insert(modeKey)
            keys.insert(SMCKeys.fanMinSpeed(fanID))
            keys.insert(SMCKeys.fanMaxSpeed(fanID))
            keys.insert(SMCKeys.fanTargetSpeed(fanID))
            uint8Values[modeKey] = 0
            fanValues[SMCKeys.fanMinSpeed(fanID)] = range.0
            fanValues[SMCKeys.fanMaxSpeed(fanID)] = range.1
            fanValues[SMCKeys.fanTargetSpeed(fanID)] = range.0
        }
    }

    func open() throws {}
    func close() {}

    func getKeyInfo(key: FourCharCode) throws -> SMCKeyDataKeyInfo {
        let name = key.toString
        guard keys.contains(name) else { throw MockError.missing(name) }
        return SMCKeyDataKeyInfo(dataSize: 1, dataType: 0, dataAttributes: 0)
    }

    func readUInt8(_ key: String) throws -> UInt8 {
        guard !unreadableUInt8Keys.contains(key), let value = uint8Values[key] else {
            throw MockError.missing(key)
        }
        return value
    }

    func writeUInt8(_ key: String, value: UInt8) throws {
        guard !alwaysFailWrites.contains(key) else { throw MockError.writeFailed(key) }
        writes.append("\(key)=\(value)")
        uint8Values[key] = value
    }

    func readFanSpeed(_ key: String) throws -> Double {
        guard let value = fanValues[key] else { throw MockError.missing(key) }
        return value
    }

    func writeFanSpeed(_ key: String, rpm: Double) throws {
        guard !alwaysFailWrites.contains(key) else { throw MockError.writeFailed(key) }
        writes.append("\(key)=\(rpm)")
        fanValues[key] = rpm
    }
}
