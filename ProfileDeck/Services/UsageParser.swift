import Foundation

/// Parses account quota evidence only. It does not infer native task activity.
enum UsageParser {
    nonisolated static func subscription(
        profileID: UUID, account: JSONValue, rates: JSONValue, observedAt: Date = Date()
    ) throws -> UsageSnapshot {
        guard account["account"]["type"].string == "chatgpt" else {
            throw DeckError.message("Subscription usage requires a verified ChatGPT account.")
        }
        guard let rateObject = rates.object else { throw ProviderRPCError.malformed }
        var warnings: [String] = []
        var snapshot = UsageSnapshot(profileID: profileID, observedAt: observedAt,
            source: "OpenAI account rate limits", observedAuthMode: .subscription)
        snapshot.accountID = optionalString(rates["accountId"], warnings: &warnings)
        snapshot.accountLabel = optionalString(account["account"]["email"], warnings: &warnings)
        snapshot.planName = optionalString(account["account"]["planType"], warnings: &warnings)
        if case .number(let count) = rates["rateLimitResetCredits"]["availableCount"],
           count.isFinite, count >= 0, count.rounded(.towardZero) == count,
           count < Double(Int.max) {
            snapshot.resetCreditsAvailable = Int(count)
        }

        let buckets: [(String?, JSONValue)]
        if let map = rates["rateLimitsByLimitId"].object, !map.isEmpty {
            buckets = map.keys.sorted { lhs, rhs in
                if lhs == "codex" { return rhs != "codex" }
                if rhs == "codex" { return false }
                return lhs < rhs
            }.map { ($0, map[$0]!) }
        } else {
            if let mapValue = rateObject["rateLimitsByLimitId"], mapValue != .null, mapValue.object == nil {
                warnings.append("Some usage buckets could not be read.")
            }
            buckets = [(nil, rates["rateLimits"])]
        }

        for (mapID, value) in buckets {
            guard let bucket = value.object else {
                warnings.append("Some usage buckets could not be read.")
                continue
            }
            let suppliedID = optionalString(value["limitId"], warnings: &warnings)
            if let mapID, mapID.isEmpty || (suppliedID != nil && suppliedID != mapID) {
                warnings.append("A usage bucket had an inconsistent identity.")
                continue
            }
            // Older single-bucket responses do not identify their metered bucket.
            let bucketID = mapID ?? suppliedID ?? "legacy"
            let bucketName = optionalString(value["limitName"], warnings: &warnings)
            for position in ["primary", "secondary"] {
                guard let window = bucket[position], window != .null else { continue }
                guard let parsed = parseWindow(window, id: bucketID + ":" + position, bucketName: bucketName) else {
                    warnings.append("Some usage windows could not be read.")
                    continue
                }
                snapshot.windows.append(parsed)
            }
            if bucket["primary"] == nil && bucket["secondary"] == nil {
                warnings.append("Some usage windows could not be read.")
            }
        }
        if snapshot.windows.isEmpty { warnings.append("The provider returned no available usage windows.") }
        if !warnings.isEmpty {
            snapshot.error = Array(Set(warnings)).sorted().joined(separator: " ")
        }
        return snapshot
    }

    nonisolated private static func optionalString(_ value: JSONValue, warnings: inout [String]) -> String? {
        guard value != .null else { return nil }
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            warnings.append("Some account or usage details could not be read.")
            return nil
        }
        return text
    }

    nonisolated private static func parseWindow(_ value: JSONValue, id: String, bucketName: String?) -> UsageWindow? {
        guard value.object != nil, case .number(let percentage) = value["usedPercent"],
              percentage.isFinite, (0...100).contains(percentage) else { return nil }
        var duration: Int?
        if value["windowDurationMins"] != .null {
            guard case .number(let minutes) = value["windowDurationMins"], minutes.isFinite,
                  minutes > 0, minutes.rounded(.towardZero) == minutes, minutes < Double(Int.max) else { return nil }
            duration = Int(minutes)
        }
        var reset: Date?
        if value["resetsAt"] != .null {
            guard case .number(let timestamp) = value["resetsAt"], timestamp.isFinite,
                  timestamp >= 0, timestamp.rounded(.towardZero) == timestamp,
                  timestamp <= 253_402_300_799 else { return nil }
            reset = Date(timeIntervalSince1970: timestamp)
        }
        return UsageWindow(id: id, usedPercent: percentage, durationMinutes: duration,
            resetsAt: reset, bucketName: bucketName)
    }
}
