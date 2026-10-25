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

    func testDeleteAndRestoreKeepsPosition() throws {
        let location = try makeLocation()
        let manager = ProfileManager(fileURL: location.file)
        let middle = manager.profiles[1]
        manager.setActive(middle.id)

        let removed = try XCTUnwrap(manager.deleteProfile(middle.id))
        XCTAssertEqual(removed.index, 1)
        XCTAssertTrue(removed.wasActive)
        XCTAssertNil(manager.activeProfileID)

        manager.restoreProfile(removed.profile, at: removed.index)
        XCTAssertEqual(manager.profiles[1], middle)
        XCTAssertEqual(ProfileManager(fileURL: location.file).profiles.map(\.id), manager.profiles.map(\.id))
    }

    func testDuplicateInsertsCopyAfterOriginal() throws {
        let location = try makeLocation()
        let manager = ProfileManager(fileURL: location.file)
        let original = manager.profiles[0]

        let copy = try XCTUnwrap(manager.duplicateProfile(original.id))

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(manager.profiles[1].id, copy.id)
        XCTAssertEqual(copy.rules.map(\.fanSpeedPercent), original.rules.map(\.fanSpeedPercent))
    }

    func testUpsertAddsThenUpdates() throws {
        let location = try makeLocation()
        let manager = ProfileManager(fileURL: location.file)
        var profile = FanProfile(name: "New", rules: [FanRule(tempThreshold: 60, fanSpeedPercent: 40)])

        manager.upsertProfile(profile)
        profile.name = "Renamed"
        manager.upsertProfile(profile)

        XCTAssertEqual(manager.profiles.count, 4)
        XCTAssertEqual(manager.profiles.last?.name, "Renamed")
    }

    func testHysteresisKeepsRuleUntilTemperatureDropsBelowMargin() throws {
        let location = try makeLocation()
        let manager = ProfileManager(fileURL: location.file)
        let quiet = try XCTUnwrap(manager.profiles.first { $0.name == "安静" })
        manager.setActive(quiet.id)
        let battery = BatteryInfo()

        XCTAssertEqual(manager.evaluateActiveProfile(maxTemp: 72, battery: battery), 60)
        XCTAssertEqual(manager.evaluateActiveProfile(maxTemp: 68, battery: battery), 60)
        XCTAssertEqual(manager.evaluateActiveProfile(maxTemp: 66, battery: battery), 30)
        XCTAssertEqual(manager.evaluateActiveProfile(maxTemp: 69, battery: battery), 30)
        XCTAssertEqual(manager.evaluateActiveProfile(maxTemp: 70, battery: battery), 60)
        XCTAssertNil(manager.evaluateActiveProfile(maxTemp: 50, battery: battery))
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
