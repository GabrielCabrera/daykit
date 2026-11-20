import Foundation

public enum ParsedTemporal: Sendable, Equatable {
    case dateOnly(year: Int, month: Int, day: Int)
    case dateTime(Date)

    public var isDateOnly: Bool {
        if case .dateOnly = self { return true }
        return false
    }

    public func startOfDayDate(calendar: Calendar) throws -> Date {
        switch self {
        case .dateOnly(let year, let month, let day):
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = 0
            components.minute = 0
            components.second = 0
            guard let date = calendar.date(from: components) else {
                throw DaykitError(
                    code: "INVALID_DATE",
                    exitCode: .usageError,
                    message: "Invalid calendar date: \(String(format: "%04d-%02d-%02d", year, month, day))"
                )
            }
            return date
        case .dateTime(let date):
            return date
        }
    }

    public func formatString(timeZone: TimeZone) -> String {
        switch self {
        case .dateOnly(let year, let month, let day):
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .dateTime(let date):
            return DateParsing.formatRFC3339(date, timeZone: timeZone)
        }
    }
}

public enum DateParsing {
    public static func parseTemporal(
        _ raw: String,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> ParsedTemporal {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DaykitError(
                code: "INVALID_DATE",
                exitCode: .usageError,
                message: "Date/time value cannot be empty."
            )
        }

        let lower = trimmed.lowercased()
        if lower == "now" {
            return .dateTime(now)
        }

        if let relativeDays = parseRelativeDayKeyword(lower) {
            let todayStart = calendar.startOfDay(for: now)
            guard let shifted = calendar.date(byAdding: .day, value: relativeDays, to: todayStart) else {
                throw DaykitError(code: "INVALID_DATE", exitCode: .usageError, message: "Cannot resolve date '\(trimmed)'.")
            }
            let comps = calendar.dateComponents([.year, .month, .day], from: shifted)
            guard let year = comps.year, let month = comps.month, let day = comps.day else {
                throw DaykitError(code: "INVALID_DATE", exitCode: .usageError, message: "Cannot resolve date '\(trimmed)'.")
            }
            return .dateOnly(year: year, month: month, day: day)
        }

        if let ymd = parseExactDateOnly(trimmed, calendar: calendar) {
            return .dateOnly(year: ymd.year, month: ymd.month, day: ymd.day)
        }

        if let localDate = parseLocalDateTime(trimmed, calendar: calendar, timeZone: timeZone) {
            return .dateTime(localDate)
        }

        if let isoDate = parseRFC3339(trimmed) {
            return .dateTime(isoDate)
        }

        throw DaykitError(
            code: "INVALID_DATE",
            exitCode: .usageError,
            message: "Invalid date/time format: '\(raw)'.",
            hint: "Use YYYY-MM-DD, YYYY-MM-DDTHH:MM, RFC3339 (e.g. 2026-11-20T14:30:00-03:00), or today/tomorrow/+Nd."
        )
    }

    public static func resolveRangeBound(
        _ temporal: ParsedTemporal,
        isExclusiveEnd: Bool,
        calendar: Calendar
    ) throws -> Date {
        let base = try temporal.startOfDayDate(calendar: calendar)
        if temporal.isDateOnly && isExclusiveEnd {
            guard let next = calendar.date(byAdding: .day, value: 1, to: base) else {
                throw DaykitError(code: "INVALID_DATE", exitCode: .usageError, message: "Cannot compute range end.")
            }
            return next
        }
        return base
    }

    public static func parseDuration(_ raw: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw DaykitError(code: "INVALID_DURATION", exitCode: .usageError, message: "Duration cannot be empty.")
        }

        var index = trimmed.startIndex
        var totalSeconds: TimeInterval = 0
        var parsedTokens = 0

        while index < trimmed.endIndex {
            let numStart = index
            while index < trimmed.endIndex, trimmed[index].isNumber {
                index = trimmed.index(after: index)
            }
            guard numStart < index, index < trimmed.endIndex else {
                throw DaykitError(
                    code: "INVALID_DURATION",
                    exitCode: .usageError,
                    message: "Invalid duration: '\(raw)'. Expected format like 15m, 1h, 1h30m, or 2d."
                )
            }
            guard let amount = Int(trimmed[numStart..<index]), amount >= 0 else {
                throw DaykitError(code: "INVALID_DURATION", exitCode: .usageError, message: "Invalid duration number in '\(raw)'.")
            }

            let unit = trimmed[index]
            index = trimmed.index(after: index)
            parsedTokens += 1

            switch unit {
            case "m": totalSeconds += TimeInterval(amount * 60)
            case "h": totalSeconds += TimeInterval(amount * 3600)
            case "d": totalSeconds += TimeInterval(amount * 86400)
            default:
                throw DaykitError(
                    code: "INVALID_DURATION",
                    exitCode: .usageError,
                    message: "Unsupported duration unit '\(unit)' in '\(raw)'. Use m, h, or d."
                )
            }
        }

        guard parsedTokens > 0, totalSeconds > 0 else {
            throw DaykitError(
                code: "INVALID_DURATION",
                exitCode: .usageError,
                message: "Duration must be greater than zero: '\(raw)'."
            )
        }
        return totalSeconds
    }

    public static func validateHTTPSURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let normalized = components.url?.absoluteString
        else {
            throw DaykitError(
                code: "INVALID_URL",
                exitCode: .usageError,
                message: "Invalid URL '\(raw)'. Only https:// URLs without embedded credentials are allowed."
            )
        }
        return normalized
    }

    public static func formatRFC3339(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func formatUTCISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func formatDateOnly(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    public static func formatDateComponents(_ components: DateComponents, timeZone: TimeZone) -> (string: String, hasDueTime: Bool) {
        let hasDueTime = components.hour != nil && components.minute != nil
        if !hasDueTime, let year = components.year, let month = components.month, let day = components.day {
            return (String(format: "%04d-%02d-%02d", year, month, day), false)
        }
        var resolved = components
        let tz = components.timeZone ?? timeZone
        resolved.timeZone = tz
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if let date = cal.date(from: resolved) {
            return (formatRFC3339(date, timeZone: tz), true)
        }
        if let year = components.year, let month = components.month, let day = components.day {
            return (String(format: "%04d-%02d-%02d", year, month, day), false)
        }
        return ("", false)
    }

    private static func parseRelativeDayKeyword(_ lower: String) -> Int? {
        switch lower {
        case "today": return 0
        case "tomorrow": return 1
        case "yesterday": return -1
        default:
            guard (lower.hasPrefix("+") || lower.hasPrefix("-")), lower.hasSuffix("d"), lower.count >= 3 else {
                return nil
            }
            let numSlice = lower.dropLast()
            return Int(numSlice)
        }
    }

    private static func parseExactDateOnly(_ value: String, calendar: Calendar) -> (year: Int, month: Int, day: Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }

        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.isLeapMonth = false
        guard let date = calendar.date(from: comps) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return (year, month, day)
    }

    private static func parseLocalDateTime(_ value: String, calendar: Calendar, timeZone: TimeZone) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        for format in formats {
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
