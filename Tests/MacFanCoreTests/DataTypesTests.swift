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
