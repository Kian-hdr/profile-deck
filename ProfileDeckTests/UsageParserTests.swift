import XCTest
@testable import ProfileDeck

final class UsageParserTests: XCTestCase {
    private let profileID = UUID()
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var account: JSONValue {
        .object(["account": .object(["type": .string("chatgpt"), "email": .string("person@example.test"), "planType": .string("pro")])])
    }
    private func window(_ percent: Double = 37, minutes: Double = 300) -> JSONValue {
        .object(["usedPercent": .number(percent), "windowDurationMins": .number(minutes), "resetsAt": .number(1_800_003_600)])
    }
    private func bucket(_ id: String = "codex", primary: JSONValue, secondary: JSONValue = .null) -> JSONValue {
        .object(["limitId": .string(id), "limitName": .null, "primary": primary, "secondary": secondary])
    }
    private func parse(_ rates: JSONValue) throws -> UsageSnapshot {
        try UsageParser.subscription(profileID: profileID, account: account, rates: rates, observedAt: checkedAt)
    }

    func testWeeklyPrimaryAndNullSecondaryPreserveProviderMeaning() throws {
        let value = try parse(.object(["accountId": .string("account-fixture"),
            "rateLimits": bucket(primary: window(37, minutes: 10080))]))
        XCTAssertEqual(value.profileID, profileID)
        XCTAssertEqual(value.accountID, "account-fixture")
        XCTAssertEqual(value.accountLabel, "person@example.test")
        XCTAssertEqual(value.planName, "pro")
        XCTAssertEqual(value.observedAuthMode, .subscription)
        XCTAssertEqual(value.source, "OpenAI account rate limits")
        XCTAssertEqual(value.observedAt, checkedAt)
        XCTAssertEqual(value.windows.map(\.id), ["codex:primary"])
        XCTAssertEqual(value.windows.first?.label, "Weekly")
        XCTAssertEqual(value.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertNil(value.error)
    }

    func testMultipleBucketsPreferMapWithoutDuplicatingLegacyAndSortCodexFirst() throws {
        let codex = bucket(primary: window(21, minutes: 10080))
        let spark = bucket("spark", primary: window(62), secondary: window(44, minutes: 10080))
        let value = try parse(.object(["rateLimits": bucket(primary: window(99)),
            "rateLimitsByLimitId": .object(["spark": spark, "codex": codex])]))
        XCTAssertEqual(value.windows.map(\.id), ["codex:primary", "spark:primary", "spark:secondary"])
        XCTAssertEqual(value.windows.map(\.usedPercent), [21, 62, 44])
        XCTAssertNil(value.error)
    }

    func testEarnedResetCreditsAreSeparateFromScheduledWindowReset() throws {
        let value = try parse(.object([
            "rateLimits": bucket(primary: window(90)),
            "rateLimitResetCredits": .object(["availableCount": .number(2)])
        ]))
        XCTAssertEqual(value.resetCreditsAvailable, 2)
        XCTAssertEqual(value.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(value.windows.first?.usedPercent, 90)
    }

    func testMissingOrMalformedResetCountStaysUnavailable() throws {
        for candidate: JSONValue in [.null, .object([:]), .object(["availableCount": .string("0")]),
                                     .object(["availableCount": .number(-1)]), .object(["availableCount": .number(1.5)])] {
            let value = try parse(.object(["rateLimits": bucket(primary: window()), "rateLimitResetCredits": candidate]))
            XCTAssertNil(value.resetCreditsAvailable)
            XCTAssertEqual(value.windows.count, 1)
        }
    }

    func testEmptyMapFallsBackToLegacyWithoutInventingBucketOrDuration() throws {
        let value = try parse(.object(["rateLimitsByLimitId": .object([:]),
            "rateLimits": .object(["primary": .object(["usedPercent": .number(12.5)]), "secondary": .null])]))
        XCTAssertEqual(value.windows.first?.id, "legacy:primary")
        XCTAssertEqual(value.windows.first?.label, "Usage window")
        XCTAssertEqual(value.windows.first?.usedPercent, 12.5)
        XCTAssertNil(value.windows.first?.resetsAt)
        XCTAssertNil(value.accountID)
        XCTAssertNil(value.error)
    }

    func testMissingAndInvalidPercentNeverBecomeUnusedCapacity() throws {
        let invalid: [JSONValue] = [.object([:]), .object(["usedPercent": .string("0")]),
            window(-1), window(101), window(.nan), window(.infinity)]
        for candidate in invalid {
            let value = try parse(.object(["rateLimits": bucket(primary: candidate)]))
            XCTAssertTrue(value.windows.isEmpty)
            XCTAssertNotNil(value.error)
            XCTAssertFalse(value.isFresh(at: checkedAt))
        }
    }

    func testMalformedSecondaryPreservesPrimaryButMarksPartialReading() throws {
        let value = try parse(.object(["rateLimits": bucket(primary: window(81), secondary: .string("invalid"))]))
        XCTAssertEqual(value.windows.map(\.usedPercent), [81])
        XCTAssertNotNil(value.error)
        XCTAssertFalse(value.isFresh(at: checkedAt))
    }

    func testMalformedMapFallbackStillReportsPartialFailure() throws {
        let value = try parse(.object(["rateLimitsByLimitId": .array([]), "rateLimits": bucket(primary: window())]))
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertNotNil(value.error)
    }

    func testInvalidDurationAndResetAreNotSilentlyDiscarded() throws {
        for minutes in [0.0, -1.0, 0.5, .infinity] {
            let value = try parse(.object(["rateLimits": bucket(primary: window(minutes: minutes))]))
            XCTAssertTrue(value.windows.isEmpty)
            XCTAssertNotNil(value.error)
        }
        let timestamps: [JSONValue] = [.string("tomorrow"), .number(.nan), .number(-1), .number(1.5)]
        for timestamp in timestamps {
            let candidate: JSONValue = .object(["usedPercent": .number(23), "resetsAt": timestamp])
            let value = try parse(.object(["rateLimits": bucket(primary: candidate)]))
            XCTAssertTrue(value.windows.isEmpty)
            XCTAssertNotNil(value.error)
        }
    }

    func testMismatchedBucketIdentityIsNotMisattributed() throws {
        let value = try parse(.object(["rateLimitsByLimitId": .object([
            "codex": bucket("different", primary: window()),
            "other": bucket("other", primary: window(45))])]))
        XCTAssertEqual(value.windows.map(\.id), ["other:primary"])
        XCTAssertNotNil(value.error)
    }

    func testAPIAndMissingAuthenticationCannotProduceSubscriptionUsage() {
        for identity: JSONValue in [.null, .object(["account": .object(["type": .string("apiKey")])])] {
            XCTAssertThrowsError(try UsageParser.subscription(profileID: profileID, account: identity,
                rates: .object(["rateLimits": bucket(primary: window())])))
        }
        XCTAssertThrowsError(try parse(.array([])))
    }

    func testUnknownWindowsAndMalformedAccountIDRemainUnavailable() throws {
        let value = try parse(.object(["accountId": .number(7), "rateLimits": .object(["primary": .null, "secondary": .null])]))
        XCTAssertNil(value.accountID)
        XCTAssertTrue(value.windows.isEmpty)
        XCTAssertNotNil(value.error)
    }
}
