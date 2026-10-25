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
        XCTAssertEqual(monitor.manualOwner, .profile)

        monitor.evaluateProfile()
        XCTAssertEqual(client.resetAllFansRequestCount, 2)
        client.completeResetAllFans(at: 1, success: true)
        XCTAssertEqual(monitor.manualOwner, .none)
        XCTAssertEqual(monitor.controlMode, .system)
    }

    // MARK: - 手动控制

    func testManualSpeedWithoutProfileIsNotReverted() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()

        monitor.setAllFans(percent: 40)
        client.completeSetAllFans(success: true)
        monitor.evaluateProfile()
        monitor.evaluateProfile()

        XCTAssertEqual(client.resetAllFansRequestCount, 0)
        XCTAssertEqual(monitor.controlMode, .manual(percent: 40))
    }

    func testManualSpeedDeactivatesActiveProfile() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager

        monitor.setAllFans(percent: 30)

        XCTAssertNil(manager.activeProfileID)
        client.completeSetAllFans(success: true)
        XCTAssertEqual(monitor.controlMode, .manual(percent: 30))
    }

    func testProfileDoesNotResetWhileManualRequestIsInFlight() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager
        monitor.maxTemp = 80
        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)

        // 用户拖动滑块：配置被停用，请求尚未返回时定时评估触发
        monitor.setAllFans(percent: 20)
        monitor.evaluateProfile()

        XCTAssertEqual(client.resetAllFansRequestCount, 0)
        client.completeSetAllFans(at: 1, success: true)
        monitor.evaluateProfile()
        XCTAssertEqual(client.resetAllFansRequestCount, 0)
        XCTAssertEqual(monitor.controlMode, .manual(percent: 20))
    }

    func testStaleManualCompletionDoesNotOverrideNewerRequest() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()

        monitor.setAllFans(percent: 25)
        monitor.setAllFans(percent: 75)
        client.completeSetAllFans(at: 1, success: true)
        client.completeSetAllFans(at: 0, success: true)

        XCTAssertEqual(monitor.controlMode, .manual(percent: 75))
        XCTAssertFalse(monitor.isApplying)
    }

    func testRestoreSystemControlDeactivatesProfileAndResets() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeActiveProfileManager(percent: 50)
        monitor.profileManager = manager
        monitor.maxTemp = 80
        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)

        monitor.restoreSystemControl()

        XCTAssertNil(manager.activeProfileID)
        XCTAssertEqual(client.resetAllFansRequestCount, 1)
        client.completeResetAllFans(success: true)
        XCTAssertEqual(monitor.controlMode, .system)
    }

    func testControlModeReportsProfileTarget() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeManager()
        let profile = FanProfile(name: "Hot", rules: [FanRule(tempThreshold: 70, fanSpeedPercent: 60)])
        manager.addProfile(profile)
        monitor.profileManager = manager

        monitor.maxTemp = 50
        monitor.activateProfile(profile.id)
        XCTAssertEqual(monitor.controlMode, .profile(percent: nil))

        monitor.maxTemp = 75
        monitor.evaluateProfile()
        XCTAssertEqual(monitor.controlMode, .profile(percent: 60))
    }

    // MARK: - 与硬件状态同步

    func testExternalManualModeIsAdoptedAsManual() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()
        monitor.fans = [
            FanInfo(id: 0, actualRPM: 4_000, minRPM: 2_000, maxRPM: 6_000, targetRPM: 4_000, mode: 1),
            FanInfo(id: 1, actualRPM: 4_000, minRPM: 2_000, maxRPM: 6_000, targetRPM: 4_000, mode: 1),
        ]

        monitor.reconcileWithHardware()
        monitor.evaluateProfile()

        XCTAssertEqual(monitor.controlMode, .manual(percent: 50))
        XCTAssertEqual(client.resetAllFansRequestCount, 0)
    }

    func testExternalManualModeIsResetWhenActiveProfileDoesNotMatch() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        let manager = try makeManager()
        let profile = FanProfile(name: "Hot", rules: [FanRule(tempThreshold: 90, fanSpeedPercent: 100)])
        manager.addProfile(profile)
        manager.setActive(profile.id)
        monitor.profileManager = manager
        monitor.maxTemp = 50
        monitor.fans = [FanInfo(id: 0, actualRPM: 4_000, minRPM: 2_000, maxRPM: 6_000, targetRPM: 4_000, mode: 1)]

        monitor.reconcileWithHardware()
        monitor.evaluateProfile()

        XCTAssertEqual(client.resetAllFansRequestCount, 1)
    }

    func testHardwareBackToAutoClearsManualState() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()
        monitor.setAllFans(percent: 40)
        client.completeSetAllFans(success: true)

        monitor.fans = [FanInfo(id: 0, actualRPM: 0, minRPM: 2_000, maxRPM: 6_000, targetRPM: 0, mode: 0)]
        monitor.reconcileWithHardware()

        XCTAssertEqual(monitor.controlMode, .system)
    }

    func testProfileIsReappliedAfterExternalReset() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeActiveProfileManager(percent: 50)
        monitor.maxTemp = 80
        monitor.evaluateProfile()
        client.completeSetAllFans(success: true)

        monitor.fans = [FanInfo(id: 0, actualRPM: 0, minRPM: 2_000, maxRPM: 6_000, targetRPM: 0, mode: 0)]
        monitor.reconcileWithHardware()
        monitor.evaluateProfile()

        XCTAssertEqual(client.setAllFansRequests, [50, 50])
    }

    func testReconcileIgnoresTransientStateWhileRequestInFlight() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()
        monitor.setAllFans(percent: 40)

        monitor.fans = [FanInfo(id: 0, actualRPM: 0, minRPM: 2_000, maxRPM: 6_000, targetRPM: 0, mode: 0)]
        monitor.reconcileWithHardware()
        client.completeSetAllFans(success: true)

        XCTAssertEqual(monitor.controlMode, .manual(percent: 40))
    }

    func testManualSpeedIsReappliedAfterWake() throws {
        let client = MockFanControlClient()
        let monitor = FanMonitor(fanControlClient: client)
        monitor.profileManager = try makeManager()
        monitor.setAllFans(percent: 40)
        client.completeSetAllFans(success: true)

        monitor.prepareForSleep()
        monitor.fans = [FanInfo(id: 0, actualRPM: 0, minRPM: 2_000, maxRPM: 6_000, targetRPM: 0, mode: 0)]
        monitor.reconcileWithHardware()
        monitor.resumeAfterWake()

        XCTAssertEqual(client.setAllFansRequests, [40, 40])
        client.completeSetAllFans(at: 1, success: true)
        XCTAssertEqual(monitor.controlMode, .manual(percent: 40))
    }

    private func makeActiveProfileManager(percent: Double) throws -> ProfileManager {
        let manager = try makeManager()
        let profile = FanProfile(
            name: "Test",
            rules: [FanRule(tempThreshold: 0, fanSpeedPercent: percent)]
        )
        manager.addProfile(profile)
        manager.setActive(profile.id)
        return manager
    }

    private func makeManager() throws -> ProfileManager {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFanMonitorTests-\(UUID().uuidString)/profiles.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        return ProfileManager(fileURL: fileURL)
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
