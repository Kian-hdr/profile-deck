import XCTest
import SQLite3
@testable import ProfileDeck

final class PromptBalanceUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_080_000) // 2026-07-03 12:00 UTC

    private func fixture(update: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileDeckBilling-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw NSError(domain: "Fixture", code: 1) }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE provider_accounts(id TEXT PRIMARY KEY, accountName TEXT, provider TEXT, syncHealth TEXT, credentialReference TEXT);
        CREATE TABLE api_account_settings(accountID TEXT PRIMARY KEY, revision TEXT);
        CREATE TABLE api_spend_summaries(accountID TEXT PRIMARY KEY, todayUSD REAL, monthUSD REAL, fetchedAt TEXT, costsThrough TEXT, currentDayAvailable INTEGER, settingsRevision TEXT);
        INSERT INTO provider_accounts VALUES('billing-1','Example API','openAIAPI','connected','never-read-this-reference');
        INSERT INTO provider_accounts VALUES('codex','Subscription','codex','connected',NULL);
        INSERT INTO api_account_settings VALUES('billing-1','revision-1');
        INSERT INTO api_spend_summaries VALUES('billing-1',2.5,15.75,'2026-07-03 11:59:00.000','2026-07-03 11:59:00.000',1,'revision-1');
        \(update)
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "Fixture", code: 2) }
        return url
    }

    func testReadsOnlySelectedAPISourceAndPreservesForeignDatabase() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let service = PromptBalanceUsage(databaseURL: url)
        let sources = try await service.sources()
        XCTAssertEqual(sources.map(\.id), ["billing-1"])
        XCTAssertEqual(sources.map(\.name), ["Example API"])
        let reading = try await service.read(sourceID: "billing-1", now: now)
        XCTAssertEqual(reading.todayUSD, 2.5)
        XCTAssertEqual(reading.monthUSD, 15.75)
        XCTAssertTrue(reading.currentDayAvailable)
        XCTAssertNil(reading.warning)
        XCTAssertEqual(reading.fetchedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMissingTodayDoesNotBecomeZero() async throws {
        let url = try fixture(update: "UPDATE api_spend_summaries SET currentDayAvailable=0, todayUSD=0;")
        defer { try? FileManager.default.removeItem(at: url) }
        let reading = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now)
        XCTAssertNil(reading.todayUSD)
        XCTAssertFalse(reading.currentDayAvailable)
        XCTAssertEqual(reading.monthUSD, 15.75)
        XCTAssertTrue(reading.warning?.contains("awaiting") == true)
    }

    func testRevisionMismatchFailsClosed() async throws {
        let url = try fixture(update: "UPDATE api_account_settings SET revision='newer';")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now)
            XCTFail("An old settings response must not be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("settings changed")) }
    }

    func testStaleConnectionPreservesOriginalCheckTime() async throws {
        let url = try fixture(update: "UPDATE provider_accounts SET syncHealth='error';")
        defer { try? FileManager.default.removeItem(at: url) }
        let reading = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now.addingTimeInterval(1800))
        XCTAssertEqual(reading.fetchedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(reading.todayUSD, 2.5)
        XCTAssertTrue(reading.warning?.contains("Cached") == true)
        XCTAssertTrue(reading.warning?.contains("connection") == true)
    }

    func testPriorUTCPeriodsAreNotRelabeledCurrent() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let service = PromptBalanceUsage(databaseURL: url)
        let nextDay = try await service.read(sourceID: "billing-1", now: now.addingTimeInterval(86400))
        XCTAssertNil(nextDay.todayUSD)
        XCTAssertEqual(nextDay.monthUSD, 15.75)
        let nextMonth = try await service.read(sourceID: "billing-1", now: now.addingTimeInterval(32 * 86400))
        XCTAssertNil(nextMonth.todayUSD)
        XCTAssertNil(nextMonth.monthUSD)
    }

    func testMalformedAmountOrFutureTimestampRejected() async throws {
        for update in ["UPDATE api_spend_summaries SET todayUSD='invalid';",
                       "UPDATE api_spend_summaries SET monthUSD=1e999;",
                       "UPDATE api_spend_summaries SET fetchedAt='2027-01-01 00:00:00.000';",
                       "UPDATE api_spend_summaries SET fetchedAt='2026-02-30 00:00:00.000';"] {
            let url = try fixture(update: update)
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now)
                XCTFail("Invalid metadata must fail closed")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid")) }
        }
    }

    func testMissingAndUnsupportedDatabaseDoNotCreateOrMigrate() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("MissingBilling-\(UUID().uuidString).sqlite")
        do {
            _ = try await PromptBalanceUsage(databaseURL: missing).sources()
            XCTFail("Missing cache must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let url = try fixture(update: "DROP TABLE api_spend_summaries;")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        do {
            _ = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now)
            XCTFail("Unsupported cache must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unsupported")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSourceIdentifierIsBoundAndCostCorrectionsRemainSigned() async throws {
        let url = try fixture(update: "UPDATE api_spend_summaries SET todayUSD=-0.5;")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = PromptBalanceUsage(databaseURL: url)
        do {
            _ = try await service.read(sourceID: "billing-1' OR 1=1 --", now: now)
            XCTFail("Source selection must be parameterized")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No saved")) }
        let reading = try await service.read(sourceID: "billing-1", now: now)
        XCTAssertEqual(reading.todayUSD, -0.5)
    }
    private func budgetFixture(kind: String = "monthly", extra: String = "") throws -> URL {
        try fixture(update: """
        ALTER TABLE api_account_settings ADD COLUMN budgetKind TEXT;
        ALTER TABLE api_account_settings ADD COLUMN amount REAL;
        ALTER TABLE api_account_settings ADD COLUMN balanceAsOf TEXT;
        ALTER TABLE api_account_settings ADD COLUMN creditExpiresAt TEXT;
        ALTER TABLE api_account_settings ADD COLUMN checkedBalanceUSD REAL;
        ALTER TABLE api_account_settings ADD COLUMN balanceCheckedAt TEXT;
        ALTER TABLE api_spend_summaries ADD COLUMN periodUSD REAL;
        ALTER TABLE api_spend_summaries ADD COLUMN periodStart TEXT;
        UPDATE api_account_settings SET budgetKind='\(kind)', amount=100, balanceAsOf='2026-07-01 00:00:00.000';
        UPDATE api_spend_summaries SET periodUSD=25, periodStart='2026-07-01 00:00:00.000';
        \(extra)
        """)
    }

    func testLinkedAPIBillingDoesNotRequireNativeLoginOrClient() async throws {
        let url = try budgetFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        var profile = Profile(name: "Offline API", authMode: .apiKey, homePath: "/missing/home", dataPath: "/missing/data", appPath: "/missing/client.app")
        profile.billingSourceID = "billing-1"
        XCTAssertTrue(profile.hasLinkedAPIBilling)
        let reading = await NativeAdapter(billingDatabaseURL: url).usage(profile: profile)
        XCTAssertNotNil(reading.apiSpend)
        XCTAssertNil(reading.error)
        XCTAssertNil(reading.observedAuthMode, "Organization costs cannot verify native identity")
        profile.verifiedAuthMode = .subscription
        XCTAssertFalse(profile.hasLinkedAPIBilling)
    }
    func testBudgetProgressAndOldSchemaCompatibility() async throws {
        let old = try fixture(), current = try budgetFixture()
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let legacy = try await PromptBalanceUsage(databaseURL: old).read(sourceID: "billing-1", now: now)
        XCTAssertNil(legacy.budgetUsedPercent)
        XCTAssertEqual(legacy.monthUSD, 15.75)
        let reading = try await PromptBalanceUsage(databaseURL: current).read(sourceID: "billing-1", now: now)
        XCTAssertEqual(reading.budgetUsedPercent, 25)
        let nextMonth = try await PromptBalanceUsage(databaseURL: current).read(sourceID: "billing-1", now: now.addingTimeInterval(32 * 86400))
        XCTAssertNil(nextMonth.budgetUsedPercent)
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(APISpendSnapshot.self, from: encoded).budgetUsedPercent)
    }

    func testCreditCheckpointIsDatedAndExpirySuppressesBar() async throws {
        let url = try budgetFixture(kind: "creditBalance", extra: "UPDATE api_account_settings SET checkedBalanceUSD=40, balanceCheckedAt='2026-07-02 00:00:00.000', creditExpiresAt='2026-07-04 00:00:00.000';")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = PromptBalanceUsage(databaseURL: url)
        let reading = try await service.read(sourceID: "billing-1", now: now)
        XCTAssertEqual(reading.budgetUsedPercent, 60)
        XCTAssertTrue(reading.budgetLabel.contains("as of"))
        XCTAssertEqual(reading.budgetAsOf, Date(timeIntervalSince1970: 1_782_950_400))
        let expired = try await service.read(sourceID: "billing-1", now: now.addingTimeInterval(86400))
        XCTAssertNil(expired.budgetUsedPercent)
        XCTAssertTrue(expired.budgetUnavailableReason.contains("expired"))
    }

    func testInvalidBudgetKeepsCostsAndOverBudgetClampsBar() async throws {
        for (amount, expected) in [("0", Optional<Double>.none), ("10", Optional(100.0)), ("NULL", nil)] {
            let url = try budgetFixture(extra: "UPDATE api_account_settings SET amount=\(amount);")
            defer { try? FileManager.default.removeItem(at: url) }
            let reading = try await PromptBalanceUsage(databaseURL: url).read(sourceID: "billing-1", now: now)
            XCTAssertEqual(reading.budgetUsedPercent, expected)
            XCTAssertEqual(reading.monthUSD, 15.75)
        }
    }

}
