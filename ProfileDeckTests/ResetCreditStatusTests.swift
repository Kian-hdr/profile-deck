import XCTest
@testable import ProfileDeck

final class ResetCreditStatusTests: XCTestCase {
    func testRecentCountAndSharedSignIn() {
        let now = Date()
        let personal = Profile(name: "Example One", homePath: "/fixture/a", dataPath: "/fixture/a-data")
        let admin = Profile(name: "Admin", homePath: "/fixture/b", dataPath: "/fixture/b-data")
        let readings = [personal, admin].map {
            UsageSnapshot(profileID: $0.id, observedAt: now, observedAuthMode: .subscription,
                accountLabel: "same@example.test", resetCreditsAvailable: 1)
        }
        XCTAssertEqual(ResetCreditStatus.label(profile: personal, usage: readings, now: now),
                       "1 reset credit available · shared sign-in")
        XCTAssertEqual(ResetCreditStatus.label(profile: admin, usage: readings, now: now),
                       "1 reset credit available · shared sign-in")
    }

    func testUnknownStaleAndAPIStateNeverInventCredits() {
        let now = Date()
        let profile = Profile(name: "Test", homePath: "/fixture", dataPath: "/fixture-data")
        XCTAssertNil(ResetCreditStatus.label(profile: profile, usage: [], now: now))
        let stale = UsageSnapshot(profileID: profile.id, observedAt: now.addingTimeInterval(-361),
            observedAuthMode: .subscription, accountLabel: "one@example.test", resetCreditsAvailable: 3)
        XCTAssertNil(ResetCreditStatus.label(profile: profile, usage: [stale], now: now))
        let zero = UsageSnapshot(profileID: profile.id, observedAt: now,
            observedAuthMode: .subscription, accountLabel: "one@example.test", resetCreditsAvailable: 0)
        XCTAssertNil(ResetCreditStatus.label(profile: profile, usage: [zero], now: now))
        let api = UsageSnapshot(profileID: profile.id, observedAt: now, observedAuthMode: .apiKey)
        XCTAssertNil(ResetCreditStatus.label(profile: profile, usage: [api], now: now))
    }
}
