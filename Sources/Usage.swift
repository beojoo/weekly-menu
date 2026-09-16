import Foundation

enum UsageError: String, Error {
    case notRunning = "Codex not running"
    case notSignedIn = "Not signed in"
    case unavailable = "Rate limit unavailable"
}

struct UsageWindow {
    let usedPercent: Double
    let resetsAt: Date
    let durationMinutes: Int
    // Whole percent, rounded down so the label never overstates remaining quota.
    var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }

    init?(_ object: Any?) {
        guard let value = object as? [String: Any],
              let used = Self.number(value["usedPercent"]), used.isFinite,
              let epoch = Self.number(value["resetsAt"]), epoch.isFinite,
              epoch > 0, epoch < 253_402_300_800,
              let minutes = Self.number(value["windowDurationMins"]),
              minutes == 300 || minutes == 10_080 else { return nil }
        usedPercent = used
        resetsAt = Date(timeIntervalSince1970: epoch)
        durationMinutes = Int(minutes)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

import CoreFoundation

struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow
    let updatedAt: Date

    init(result: [String: Any], now: Date = Date()) throws {
        let bucket: [String: Any]?
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            // An explicit map is authoritative. Never substitute a model-specific quota.
            bucket = buckets["codex"] as? [String: Any]
        } else {
            let legacy = result["rateLimits"] as? [String: Any]
            let id = legacy?["limitId"] as? String
            bucket = id == nil || id == "codex" ? legacy : nil
        }
        guard let bucket else { throw UsageError.unavailable }
        let windows = [UsageWindow(bucket["primary"]), UsageWindow(bucket["secondary"])].compactMap { $0 }
        guard let weekly = windows.first(where: { $0.durationMinutes == 10_080 }) else {
            throw UsageError.unavailable
        }
        self.weekly = weekly
        fiveHour = windows.first(where: { $0.durationMinutes == 300 })
        updatedAt = now
    }

    func title(now: Date = Date()) -> String {
        "W\(weekly.remainingPercent)% · \(ResetTime.text(until: weekly.resetsAt, now: now))"
    }
}

enum ResetTime {
    static func text(until reset: Date, now: Date = Date()) -> String {
        let interval = reset.timeIntervalSince(now)
        guard interval.isFinite else { return "--" }
        let seconds = Int(max(0, min(interval, 253_402_300_800)))
        if seconds >= 86_400 { return "\(seconds / 86_400)일\((seconds % 86_400) / 3_600)시간" }
        if seconds >= 3_600 { return "\(seconds / 3_600)시간\((seconds % 3_600) / 60)분" }
        return "\(seconds / 60)분"
    }
}

enum ReadOnlyMethod: String, CaseIterable {
    case initialize
    case initialized
    case account = "account/read"
    case limits = "account/rateLimits/read"
}
