import Foundation

/// Presents the earned-reset count only from a recent, verified account reading.
/// Usage-window reset times are a separate quota property.
enum ResetCreditStatus {
    static func label(profile: Profile, usage: [UsageSnapshot], now: Date = Date()) -> String? {
        guard let snapshot = usage.first(where: { $0.profileID == profile.id }),
              (snapshot.observedAuthMode ?? profile.verifiedAuthMode ?? profile.authMode) != .apiKey else {
            return nil
        }
        guard snapshot.observedAuthMode == .subscription,
              let count = snapshot.resetCreditsAvailable,
              count > 0,
              let account = snapshot.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty,
              now.timeIntervalSince(snapshot.observedAt) >= 0,
              now.timeIntervalSince(snapshot.observedAt) < 360 else {
            return nil
        }
        let sharedSignIn = usage.contains { other in
            other.profileID != profile.id && other.observedAuthMode == .subscription &&
                other.accountLabel?.caseInsensitiveCompare(account) == .orderedSame
        }
        return "\(count) reset \(count == 1 ? "credit" : "credits") available" + (sharedSignIn ? " · shared sign-in" : "")
    }
}
