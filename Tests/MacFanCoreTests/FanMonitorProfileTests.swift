import XCTest
@testable import MacFanCore

@MainActor
final class FanMonitorProfileTests: XCTestCase {
    func testFailedProfileApplyRetries() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeActiveProfileManager(percent: 50)
        monitor.maxTemp = 80

        monitor.evaluateProfile()
        XCTAssertEqual(client.setAllFansRequests, [50])
        client.completeSetAllFans(success: false)

        monitor.evaluateProfile()
        XCTAssertEqual(client.setAllFansRequests, [50, 50])
    }

    func testSuccessfulProfileApplyIsNotRepeated() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeActiveProfileManager(percent: 50)
        monitor.maxTemp = 80

        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)
        monitor.evaluateProfile()

        XCTAssertEqual(client.setAllFansRequests, [50])
    }

    func testStaleProfileCompletionCannotCommitOldTarget() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager
        monitor.maxTemp = 80

        monitor.evaluateProfile()
        let firstCompletion = try XCTUnwrap(client.setAllFansCompletions.first)

        var updated = try XCTUnwrap(manager.activeProfile)
        updated.rules = [FanRule(tempThreshold: 0, fanSpeedPercent: 80)]
        manager.updateProfile(updated)
        monitor.clearProfileState()
        monitor.evaluateProfile()
        XCTAssertEqual(client.setAllFansRequests, [50, 80])

        firstCompletion(FanControlResult(success: true, message: "old"))
        client.completeSetAllFans(at: 1, success: false)
        monitor.evaluateProfile()

        XCTAssertEqual(client.setAllFansRequests, [50, 80, 80])
    }

    func testManualSpeedThenUnmatchedProfileRestoresAuto() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        let unmatched = FanProfile(name: "Unmatched", rules: [])
        manager.addProfile(unmatched)
        manager.setActive(nil)
        monitor.profileManager = manager

        monitor.setAllFans(percent: 40)
        client.completeSetAllFans(success: true)
        manager.setActive(unmatched.id)
        monitor.profileDidChange()

        XCTAssertEqual(client.resetAllFansRequestCount, 1)
    }

    func testSwitchingToUnmatchedProfileRestoresAuto() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager
        monitor.maxTemp = 80

        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)
        let unmatched = FanProfile(name: "Unmatched", rules: [])
        manager.addProfile(unmatched)
        manager.setActive(unmatched.id)
        monitor.profileDidChange()

        XCTAssertEqual(client.resetAllFansRequestCount, 1)
    }

    func testResetFailureRetriesAndOnlySuccessUpdatesCounter() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager
        monitor.maxTemp = 80

        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)
        manager.setActive(nil)

        monitor.evaluateProfile()
        XCTAssertEqual(client.resetAllFansRequestCount, 1)
        client.completeResetAllFans(success: false)
        XCTAssertEqual(monitor.fanResetCounter, 0)

        monitor.evaluateProfile()
        XCTAssertEqual(client.resetAllFansRequestCount, 2)
        client.completeResetAllFans(at: 1, success: true)
        XCTAssertEqual(monitor.fanResetCounter, 1)
    }

    private func makeActiveProfileManager(percent: Double) throws -> ProfileManager {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFanMonitorTests-\(UUID().uuidString)/profiles.json")
        let manager = ProfileManager(fileURL: fileURL)
        let profile = FanProfile(
            name: "Test",
            rules: [FanRule(tempThreshold: 0, fanSpeedPercent: percent)]
        )
        manager.addProfile(profile)
        manager.setActive(profile.id)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        return manager
    }
}

@MainActor
private final class MockFanControlClient: FanControlClient {
    var setAllFansRequests: [Double] = []
    var setAllFansCompletions: [FanControlCompletion] = []
    var resetAllFansRequestCount = 0
    var resetAllFansCompletions: [FanControlCompletion] = []

    func setFanSpeed(fanID: Int, rpm: Double, completion: @escaping FanControlCompletion) {
        completion(FanControlResult(success: true, message: "ok"))
    }

    func setAllFans(percent: Double, completion: @escaping FanControlCompletion) {
        setAllFansRequests.append(percent)
        setAllFansCompletions.append(completion)
    }

    func setAllFansMax(completion: @escaping FanControlCompletion) {
        completion(FanControlResult(success: true, message: "ok"))
    }

    func resetFan(fanID: Int, completion: @escaping FanControlCompletion) {
        completion(FanControlResult(success: true, message: "ok"))
    }

    func resetAllFans(completion: @escaping FanControlCompletion) {
        resetAllFansRequestCount += 1
        resetAllFansCompletions.append(completion)
    }

    func invalidate() {}

    func completeSetAllFans(at index: Int = 0, success: Bool) {
        setAllFansCompletions[index](FanControlResult(success: success, message: success ? "ok" : "failed"))
    }

    func completeResetAllFans(at index: Int = 0, success: Bool) {
        resetAllFansCompletions[index](FanControlResult(success: success, message: success ? "ok" : "failed"))
    }
}
