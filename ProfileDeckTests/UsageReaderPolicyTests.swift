import XCTest
@testable import ProfileDeck

final class UsageReaderPolicyTests: XCTestCase {
    func testAccountReaderAllowsOnlyAccountAndQuotaReads() {
        XCTAssertTrue(ProviderRPC.permits(method: "account/read", params: .object(["refreshToken": .bool(false)]), purpose: .accountUsage))
        XCTAssertTrue(ProviderRPC.permits(method: "account/rateLimits/read", params: .object([:]), purpose: .accountUsage))
        for method in ["config/read", "config/batchWrite", "config/value/write", "account/login/start", "account/logout", "thread/start", "thread/resume", "turn/start", "plugin/install", "initialize", "unknown"] {
            XCTAssertFalse(ProviderRPC.permits(method: method, params: .object([:]), purpose: .accountUsage), method)
        }
        XCTAssertTrue(ProviderRPC.permits(method: "config/batchWrite", params: .object([:]), purpose: .configuration))
        XCTAssertFalse(ProviderRPC.permits(method: "account/rateLimits/read", params: .object([:]), purpose: .configuration))
    }

    func testAccountReadRequiresExplicitFalseTokenRefresh() {
        let rejected: [JSONValue] = [.object([:]), .null, .object(["refreshToken": .bool(true)]),
            .object(["refreshToken": .number(0)]), .object(["refreshToken": .string("false")])]
        for purpose in [ProviderRPC.Purpose.accountUsage, .configuration] {
            for params in rejected {
                XCTAssertFalse(ProviderRPC.permits(method: "account/read", params: params, purpose: purpose))
            }
        }
        XCTAssertFalse(ProviderRPC.permits(method: "account/read", params: .object([
            "refreshToken": .bool(false), "unknownFutureOption": .bool(true)
        ]), purpose: .accountUsage))
        let invalidRateParams: [JSONValue] = [.null, .array([]), .object(["refreshToken": .bool(false)])]
        for params in invalidRateParams {
            XCTAssertFalse(ProviderRPC.permits(method: "account/rateLimits/read", params: params, purpose: .accountUsage))
        }
    }

    func testExistingProfileDecodesWithoutNewOptionalAccountFields() throws {
        let profile = Profile(name: "Fixture", homePath: "/fixture/home", dataPath: "/fixture/data")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        for key in ["verifiedAuthMode", "identityCheckedAt", "billingSourceID"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertNil(decoded.verifiedAuthMode)
        XCTAssertNil(decoded.identityCheckedAt)
        XCTAssertNil(decoded.billingSourceID)
    }

    func testExistingUsageAndWindowsDecodeWithoutNewMetadata() throws {
        let profileID = UUID(), now = Date()
        let old = UsageSnapshot(profileID: profileID, accountID: "fixture-account",
            windows: [UsageWindow(id: "codex:primary", usedPercent: 12, durationMinutes: 300)], observedAt: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["observedAuthMode", "accountLabel", "planName", "apiSpend"] { object.removeValue(forKey: key) }
        var windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        windows[0].removeValue(forKey: "bucketName")
        object["windows"] = windows
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.profileID, profileID)
        XCTAssertEqual(decoded.windows.first?.usedPercent, 12)
        XCTAssertNil(decoded.windows.first?.bucketName)
        XCTAssertNil(decoded.apiSpend)
        XCTAssertNil(decoded.observedAuthMode)
    }

    func testAPISpendingNeverBecomesSubscriptionCapacityOrThresholds() {
        let now = Date(), profileID = UUID()
        let spend = APISpendSnapshot(sourceID: "billing-fixture", sourceName: "Example organization",
            todayUSD: 1, monthUSD: 20, fetchedAt: now, costsThrough: now, currentDayAvailable: true)
        var api = UsageSnapshot(profileID: profileID, accountID: "fixture-account", observedAt: now,
            observedAuthMode: .apiKey, apiSpend: spend)
        XCTAssertFalse(api.isFresh(at: now))
        XCTAssertTrue(DeckLogic.notificationKeys(snapshot: api, settings: DeckSettings(), now: now).isEmpty)
        // Fail closed if imported, old, or inconsistent persisted state mixes units.
        api.windows = [UsageWindow(id: "not-api-credit", usedPercent: 95, durationMinutes: 300, resetsAt: now.addingTimeInterval(300))]
        XCTAssertFalse(api.isFresh(at: now))
        XCTAssertTrue(DeckLogic.notificationKeys(snapshot: api, settings: DeckSettings(), now: now).isEmpty)
    }

    @MainActor func testRuntimeReassignmentClearsAccountEvidenceButRenamePreservesIt() async {
        let model = AppModel(demo: true)
        await model.bootstrap()
        for changedField in ["home", "data", "app"] {
            var profile = model.deck.profiles[0]
            profile.observedAccount = "fixture@example.test"
            profile.verifiedAuthMode = .subscription
            profile.identityCheckedAt = Date()
            model.deck.profiles[0] = profile
            model.deck.usage = [UsageSnapshot(profileID: profile.id, accountID: "fixture-account",
                windows: [UsageWindow(id: "fixture", usedPercent: 10)])]
            profile.name = "Renamed fixture"
            model.update(profile)
            XCTAssertEqual(model.deck.profiles[0].observedAccount, "fixture@example.test")
            XCTAssertEqual(model.deck.usage.count, 1)
            switch changedField {
            case "home": profile.homePath = "/fixture/reassigned-\(UUID().uuidString)/home"
            case "data": profile.dataPath = "/fixture/reassigned-\(UUID().uuidString)/data"
            default: profile.appPath = "/fixture/Other Client.app"
            }
            model.update(profile)
            XCTAssertNil(model.deck.profiles[0].observedAccount, changedField)
            XCTAssertNil(model.deck.profiles[0].verifiedAuthMode, changedField)
            XCTAssertNil(model.deck.profiles[0].identityCheckedAt, changedField)
            XCTAssertTrue(model.deck.usage.isEmpty, changedField)
        }
    }
}
