import XCTest
@testable import MacFanCore

final class DataTypesTests: XCTestCase {
    func testSP78DecodesNegativeValuesWithoutTrapping() {
        XCTAssertEqual(DataTypes.decodeSP78([0xFF, 0x00]), -1)
        XCTAssertEqual(DataTypes.decodeSP78([0x80, 0x00]), -128)
        XCTAssertEqual(DataTypes.decodeSP78([0x2A, 0x80]), 42.5)
    }

    func testEncodersClampOutOfRangeValues() {
        XCTAssertEqual(DataTypes.encodeFPE2(-10), [0, 0])
        XCTAssertEqual(DataTypes.encodeFPE2(.nan), [0, 0])
        XCTAssertEqual(DataTypes.encodeFPE2(100_000), [0xFF, 0xFF])
        XCTAssertEqual(DataTypes.decodeFPE2(DataTypes.encodeFPE2(3_000.25)), 3_000.25)
        XCTAssertEqual(DataTypes.encodeSP78(1_000), [0x7F, 0xFF])
        XCTAssertEqual(DataTypes.decodeSP78(DataTypes.encodeSP78(-20.5)), -20.5)
    }
}

final class MonitorHistoryTests: XCTestCase {
    func testHistoryKeepsMostRecentSamplesPerSeries() {
        var history = MonitorHistory()
        let fan = FanInfo(id: 0, actualRPM: 0, minRPM: 2_000, maxRPM: 6_000, targetRPM: 0)

        for i in 0..<(MonitorHistory.capacity + 5) {
            var sample = fan
            sample.actualRPM = Double(i)
            history.record(
                fans: [sample],
                temperatures: [
                    TempInfo(key: "TC0P", name: "CPU Proximity", value: Double(i)),
                    TempInfo(key: "TC1C", name: "CPU Core 1", value: Double(i) + 10),
                ],
                maxTemp: Double(i) + 10
            )
        }

        XCTAssertEqual(history.fanRPM.count, MonitorHistory.capacity)
        XCTAssertEqual(history.fanRPM.first, 5)
        XCTAssertEqual(history.temperatures[.cpu]?.last, Double(MonitorHistory.capacity + 4) + 10)
        XCTAssertNil(history.temperatures[.gpu])
    }
}
