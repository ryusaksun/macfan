import XCTest
@testable import MacFanCore

@MainActor
final class ProfileManagerTests: XCTestCase {
    func testFirstLaunchCreatesDefaults() throws {
        let location = try makeLocation()

        let manager = ProfileManager(fileURL: location.file)

        XCTAssertEqual(manager.profiles.count, 3)
        XCTAssertNil(manager.loadError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.file.path))
    }

    func testCorruptFileIsBackedUpBeforeDefaultsReplaceIt() throws {
        let location = try makeLocation()
        try Data("not-json".utf8).write(to: location.file)

        let manager = ProfileManager(fileURL: location.file)
        let files = try FileManager.default.contentsOfDirectory(
            at: location.directory,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(manager.profiles.count, 3)
        XCTAssertNotNil(manager.loadError)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.contains(".corrupt-") })
        XCTAssertEqual(try Data(contentsOf: backup), Data("not-json".utf8))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: location.file)))
    }

    func testBatteryConditionsDoNotMatchWhenBatteryIsMissing() throws {
        let location = try makeLocation()
        let manager = ProfileManager(fileURL: location.file)
        let onBattery = FanProfile(
            name: "On Battery",
            rules: [FanRule(tempThreshold: 0, fanSpeedPercent: 50)],
            condition: .onBattery
        )
        manager.addProfile(onBattery)
        manager.setActive(onBattery.id)

        XCTAssertNil(manager.evaluateActiveProfile(maxTemp: 80, battery: BatteryInfo()))

        var below = onBattery
        below.id = UUID()
        below.condition = .batteryBelow(50)
        manager.addProfile(below)
        manager.setActive(below.id)
        XCTAssertNil(manager.evaluateActiveProfile(maxTemp: 80, battery: BatteryInfo()))
    }

    func testDanglingActiveProfileIsCleared() throws {
        let location = try makeLocation()
        let writer = ProfileManager(fileURL: location.file)
        writer.setActive(UUID())

        let manager = ProfileManager(fileURL: location.file)

        XCTAssertNil(manager.activeProfileID)
        XCTAssertEqual(manager.profiles.count, 3)
    }

    private func makeLocation() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, directory.appendingPathComponent("profiles.json"))
    }
}
