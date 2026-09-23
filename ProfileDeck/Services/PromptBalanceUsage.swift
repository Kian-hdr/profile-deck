import Foundation
import SQLite3

/// Reads organization spending already collected by Prompt Balance. Never owns
/// credentials, refreshes that app, or infers which native profile paid the costs.
actor PromptBalanceUsage {
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prompt Balance/usage.sqlite")
    }

    func sources() throws -> [BillingSource] {
        try query("SELECT id, accountName FROM provider_accounts WHERE provider = 'openAIAPI' ORDER BY accountName, id LIMIT 501") { statement in
            var result: [BillingSource] = []
            while try Self.step(statement) {
                guard result.count < 500 else { throw Self.failure("Too many billing sources. Open Prompt Balance to review its accounts.") }
                result.append(BillingSource(id: try Self.text(statement, 0), name: try Self.text(statement, 1)))
            }
            return result
        }
    }

    func read(sourceID: String, now: Date = Date()) throws -> APISpendSnapshot {
        guard !sourceID.isEmpty, sourceID.utf8.count <= 256, !sourceID.contains("\0") else {
            throw Self.failure("Select a valid billing source.")
        }
        let settingsColumns = try columns(in: "api_account_settings")
        let spendColumns = try columns(in: "api_spend_summaries")
        let fields = [("c", "budgetKind"), ("c", "amount"), ("c", "balanceAsOf"),
                      ("c", "creditExpiresAt"), ("c", "checkedBalanceUSD"), ("c", "balanceCheckedAt"),
                      ("s", "periodUSD"), ("s", "periodStart")]
        let budgetFields = fields.map { alias, field in
            (alias == "c" ? settingsColumns : spendColumns).contains(field) ? "\(alias).\(field)" : "NULL"
        }.joined(separator: ", ")
        return try query("""
            SELECT a.id, a.accountName, a.syncHealth, s.todayUSD, s.monthUSD,
                   s.fetchedAt, s.costsThrough, s.currentDayAvailable,
                   s.settingsRevision, c.revision, \(budgetFields)
            FROM provider_accounts a
            JOIN api_spend_summaries s ON s.accountID = a.id
            JOIN api_account_settings c ON c.accountID = a.id
            WHERE a.provider = 'openAIAPI' AND a.id = ? LIMIT 2
            """, binding: sourceID) { statement in
            guard try Self.step(statement) else {
                throw Self.failure("No saved spending reading. Connect and refresh this account in Prompt Balance.")
            }
            let id = try Self.text(statement, 0), name = try Self.text(statement, 1)
            let health = try Self.text(statement, 2)
            let today = try Self.number(statement, 3), month = try Self.number(statement, 4)
            let fetched = try Self.date(statement, 5, now: now)
            let through = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : try Self.date(statement, 6, now: now)
            guard sqlite3_column_type(statement, 7) == SQLITE_INTEGER,
                  [0, 1].contains(sqlite3_column_int(statement, 7)),
                  try Self.text(statement, 8) == Self.text(statement, 9) else {
                throw Self.failure("The billing settings changed. Refresh this account in Prompt Balance.")
            }
            let reportedToday = sqlite3_column_int(statement, 7) == 1
            var budgetAmount: Double?, budgetUsed: Double?, budgetDate: Date?
            var kind: String?
            var budgetReason: String?
            do {
                if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                    budgetReason = "Update Prompt Balance to read a spending budget."
                } else {
                    kind = try Self.text(statement, 10)
                    guard ["monthly", "creditBalance"].contains(kind!) else { throw Self.failure("Unsupported budget type.") }
                    if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                        budgetReason = "Set a budget or starting credit in Prompt Balance."
                    } else {
                        let amount = try Self.number(statement, 11)
                        guard amount > 0 else { throw Self.failure("Invalid budget amount.") }
                        let periodUsed = try Self.number(statement, 16)
                        let periodStart = try Self.date(statement, 17, now: now)
                        var utc = Calendar(identifier: .gregorian)
                        utc.timeZone = TimeZone(secondsFromGMT: 0)!
                        if kind == "monthly" {
                            guard periodStart == utc.dateInterval(of: .month, for: now)?.start else {
                                throw Self.failure("Refresh Prompt Balance for this month's budget.")
                            }
                            budgetAmount = amount; budgetUsed = max(0, periodUsed); budgetDate = fetched
                        } else {
                            let start = try Self.date(statement, 12, now: now)
                            guard periodStart == start else { throw Self.failure("Refresh Prompt Balance for the current credit period.") }
                            if sqlite3_column_type(statement, 13) != SQLITE_NULL {
                                let expiry = try Self.date(statement, 13, now: .distantFuture)
                                guard expiry > now else { throw Self.failure("Credit has expired. Update the balance in Prompt Balance.") }
                            }
                            var remaining: Double? = reportedToday && utc.isDate(fetched, inSameDayAs: now) ? max(0, amount - max(0, periodUsed)) : nil
                            budgetDate = fetched
                            if sqlite3_column_type(statement, 14) != SQLITE_NULL {
                                let checked = try Self.number(statement, 14)
                                let checkedAt = try Self.date(statement, 15, now: now)
                                guard checked >= 0, checkedAt >= start else { throw Self.failure("Invalid checked credit balance.") }
                                if remaining == nil || checked < remaining! {
                                    remaining = checked; budgetDate = checkedAt
                                }
                            }
                            guard let remaining else { throw Self.failure("Credit usage is awaiting a current cost report.") }
                            budgetAmount = amount; budgetUsed = max(0, amount - remaining)
                        }
                    }
                }
            } catch {
                budgetAmount = nil; budgetUsed = nil; budgetDate = nil
                budgetReason = error.localizedDescription
            }
            guard try !Self.step(statement) else { throw Self.failure("The billing source is ambiguous.") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let sameDay = calendar.isDate(fetched, inSameDayAs: now)
            let sameMonth = calendar.dateInterval(of: .month, for: fetched)?.start == calendar.dateInterval(of: .month, for: now)?.start
            var warnings: [String] = []
            if health != "connected" { warnings.append("Prompt Balance has not confirmed a successful current connection.") }
            if now.timeIntervalSince(fetched) > 900 { warnings.append("Cached reading. Refresh Prompt Balance for newer spending.") }
            if !sameMonth { warnings.append("This reading is from an earlier UTC month.") }
            else if !sameDay || !reportedToday { warnings.append("Today's UTC spending is awaiting a provider report.") }
            return APISpendSnapshot(sourceID: id, sourceName: name,
                todayUSD: sameDay && reportedToday ? today : nil, monthUSD: sameMonth ? month : nil,
                fetchedAt: fetched, costsThrough: through, currentDayAvailable: sameDay && reportedToday,
                warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
                budgetAmountUSD: budgetAmount, budgetUsedUSD: budgetUsed, budgetKind: kind,
                budgetAsOf: budgetDate, budgetUnavailableDetail: budgetReason)
        }
    }

    private func columns(in table: String) throws -> Set<String> {
        // Table names are internal constants; never supplied by a source record.
        try query("PRAGMA table_info(\(table))") { statement in
            var result = Set<String>()
            while try Self.step(statement) { result.insert(try Self.text(statement, 1)) }
            return result
        }
    }

    private func query<T>(_ sql: String, binding: String? = nil, body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw Self.failure("Prompt Balance's billing cache is missing. Open Prompt Balance and connect an API account.")
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw Self.failure("Cannot read Prompt Balance's billing cache. Check its availability and access.")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 1_048_576)
        // Bound even a damaged or unexpectedly complex foreign schema. Queries run
        // on this actor, away from UI state; no transaction or migration writes.
        var remainingSteps = 200
        return try withUnsafeMutablePointer(to: &remainingSteps) { budget in
            sqlite3_progress_handler(connection, 1_000, { context in
                guard let context else { return 1 }
                let count = context.assumingMemoryBound(to: Int.self)
                count.pointee -= 1
                return count.pointee <= 0 ? 1 : 0
            }, budget)
            defer { sqlite3_progress_handler(connection, 0, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Self.failure("The billing cache format is unavailable or unsupported. Update and refresh Prompt Balance.")
            }
            defer { sqlite3_finalize(statement) }
            if let binding {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(statement, 1, binding, -1, transient) == SQLITE_OK else {
                    throw Self.failure("Could not select the billing source.")
                }
            }
            return try body(statement)
        }
    }

    private static func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure("The billing cache is busy or unreadable. Try again after Prompt Balance refreshes.")
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              sqlite3_column_bytes(statement, column) <= 256,
              let pointer = sqlite3_column_text(statement, column) else { throw failure("Invalid billing metadata.") }
        let value = String(cString: pointer)
        guard !value.isEmpty, value.utf8.count == sqlite3_column_bytes(statement, column),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure("Invalid billing metadata.")
        }
        return value
    }

    private static func number(_ statement: OpaquePointer, _ column: Int32) throws -> Double {
        guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, column)) else {
            throw failure("Invalid spending amount in the billing cache.")
        }
        let value = sqlite3_column_double(statement, column)
        // Provider corrections can legitimately produce negative reported costs.
        guard value.isFinite, abs(value) <= 1e12 else { throw failure("Invalid spending amount in the billing cache.") }
        return value
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32, now: Date) throws -> Date {
        let value = try text(statement, column)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value), formatter.string(from: date) == value,
               date.timeIntervalSince1970 >= 0, date <= now.addingTimeInterval(300) { return date }
        }
        throw failure("Invalid check time in the billing cache.")
    }

    private static func failure(_ message: String) -> DeckError { .message(message) }
}
