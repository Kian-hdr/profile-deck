import XCTest
@testable import ProfileDeck

final class UsagePreviewTests: XCTestCase {
    func testUsageFillsFromEmptyToFullAndClampsInvalidValues() {
        let readings: [Double] = [0, 10, 50, 80, 100]
        XCTAssertEqual(readings.map { UsageWindow(id: "test", usedPercent: $0).usedFraction }, [0, 0.1, 0.5, 0.8, 1])
        XCTAssertEqual(UsageWindow(id: "test", usedPercent: -1).usedFraction, 0)
        XCTAssertEqual(UsageWindow(id: "test", usedPercent: 150).usedFraction, 1)
        XCTAssertEqual(UsageWindow(id: "test", usedPercent: .nan).usedFraction, 0)
    }

    func testCachedUsageKeepsItsUsageBasedTint() {
        XCTAssertEqual(UsageMeterTint.forUsedPercent(10), .green)
        XCTAssertEqual(UsageMeterTint.forUsedPercent(50), .yellow)
        XCTAssertEqual(UsageMeterTint.forUsedPercent(80), .orange)
        XCTAssertEqual(UsageMeterTint.forUsedPercent(95), .red)
        // Freshness changes the explanation, not the last verified fill colour.
        let stale = UsageWindow(id: "weekly", usedPercent: 92)
        XCTAssertEqual(UsageMeterTint.forUsedPercent(stale.usedPercent), .orange)
    }
    private func fixture() -> (Profile, UsageSnapshot) {
        let profile = Profile(name: "Example", homePath: "/fixture/home", dataPath: "/fixture/data")
        let snapshot = UsageSnapshot(profileID: profile.id, windows: [
            UsageWindow(id: "codex:primary", usedPercent: 40, durationMinutes: 10080),
            UsageWindow(id: "spark:primary", usedPercent: 20, durationMinutes: 300, bucketName: "Spark"),
            UsageWindow(id: "spark:secondary", usedPercent: 10, durationMinutes: 10080, bucketName: "Spark")
        ], observedAuthMode: .subscription)
        return (profile, snapshot)
    }
    func testOlderProfilesDefaultToAllPreviews() throws {
        let (profile, snapshot) = fixture()
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertNil(decoded.showMenuUsage)
        XCTAssertNil(decoded.hiddenMenuUsageWindowIDs)
        XCTAssertTrue(decoded.showsMenuUsage)
        XCTAssertEqual(decoded.menuWindows(from: snapshot).count, 3)
    }
    func testPerWindowChoicesPersistAcrossResetsAndDoNotChangeUsageData() throws {
        var (profile, snapshot) = fixture()
        profile.hiddenMenuUsageWindowIDs = ["spark:primary", "spark:secondary"]
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        snapshot.windows[1].resetsAt = Date().addingTimeInterval(3600)
        snapshot.windows[1].bucketName = "Renamed model"
        XCTAssertEqual(decoded.menuWindows(from: snapshot).map(\.id), ["codex:primary"])
        XCTAssertEqual(snapshot.displayWindows.count, 3)
        XCTAssertTrue(snapshot.isFresh())
        profile.hiddenMenuUsageWindowIDs?.insert("codex:primary")
        XCTAssertFalse(profile.hasMenuUsagePreview(for: snapshot))
    }
    func testMasterSwitchRetainsChoicesAndIsIndependentPerProfile() throws {
        var (profile, snapshot) = fixture()
        var other = profile; other.id = UUID()
        profile.hiddenMenuUsageWindowIDs = ["spark:primary"]
        profile.showMenuUsage = false
        var restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertTrue(restored.menuWindows(from: snapshot).isEmpty)
        XCTAssertFalse(restored.hasMenuUsagePreview(for: nil))
        XCTAssertEqual(other.menuWindows(from: snapshot).count, 3)
        restored.showMenuUsage = true
        XCTAssertEqual(restored.menuWindows(from: snapshot).count, 2)
        XCTAssertTrue(restored.hasMenuUsagePreview(for: snapshot))
    }
}
