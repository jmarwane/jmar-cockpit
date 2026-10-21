import Foundation

/// Reads a trailing time phrase: `in 20m`, `in 2 hours`, `at 18:30`, `at 6pm`, `tomorrow`, `tomorrow at 9`.
public enum ReminderParser {
    public struct Parsed: Sendable, Equatable {
        /// The text without the time phrase.
        public var text: String
        public var due: Date?
    }

    /// The hour `tomorrow` means when no time is given (matches the `Tomorrow 9:00` chip).
    public static let tomorrowHour = 9

    private static let time = #"(\d{1,2})(?:[:.h](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#
    private static let relative = try! NSRegularExpression(
        pattern: #"(?:^|\s)in\s+(\d+)\s*(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|d|days?)\s*$"#,
        options: .caseInsensitive
    )
    private static let tomorrow = try! NSRegularExpression(
        pattern: #"(?:^|\s)tomorrow(?:\s+(?:at\s+)?"# + time + #")?\s*$"#,
        options: .caseInsensitive
    )
    private static let absolute = try! NSRegularExpression(
        pattern: #"(?:^|\s)at\s+"# + time + #"\s*$"#,
        options: .caseInsensitive
    )

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Parsed {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)

        if let match = relative.firstMatch(in: text, range: range),
           let amount = Int(group(1, match, text) ?? ""),
           let unit = group(2, match, text)?.lowercased() {
            let seconds: Int
            switch unit.first {
            case "s": seconds = amount
            case "m": seconds = amount * 60
            case "h": seconds = amount * 3600
            default: seconds = amount * 86_400
            }
            return Parsed(text: remainder(text, before: match), due: now.addingTimeInterval(TimeInterval(seconds)))
        }

        if let match = tomorrow.firstMatch(in: text, range: range) {
            let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            var hour = tomorrowHour, minute = 0
            if group(1, match, text) != nil {
                guard let parsed = clock(match, text, from: 1, now: nil, calendar: calendar) else {
                    return Parsed(text: text, due: nil)
                }
                (hour, minute) = parsed
            }
            let due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            return Parsed(text: remainder(text, before: match), due: due)
        }

        if let match = absolute.firstMatch(in: text, range: range),
           let (hour, minute) = clock(match, text, from: 1, now: now, calendar: calendar) {
            var due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
            // A time already past today means tomorrow.
            if due <= now { due = calendar.date(byAdding: .day, value: 1, to: due)! }
            return Parsed(text: remainder(text, before: match), due: due)
        }

        return Parsed(text: text, due: nil)
    }

    /// True when the text ends in a time phrase Cue understands.
    public static func hasTimePhrase(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        parse(input, now: now, calendar: calendar).due != nil
    }

    /// Hour and minute from a match. `12am` is 0:00 and `12pm` is 12:00. A time with minutes and no am/pm is
    /// a 24-hour time. A bare hour from 1 to 11 that has passed today but whose evening hasn't is read as the
    /// evening (`at 7` at 15:00 → 19:00).
    private static func clock(_ match: NSTextCheckingResult, _ text: String, from first: Int, now: Date?, calendar: Calendar) -> (Int, Int)? {
        guard var hour = Int(group(first, match, text) ?? "") else { return nil }
        let minute = Int(group(first + 1, match, text) ?? "0") ?? 0
        let meridiem = group(first + 2, match, text)?.lowercased().replacingOccurrences(of: ".", with: "")
        guard minute < 60 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" { hour = hour == 12 ? 0 : hour }
            if meridiem == "pm" { hour = hour == 12 ? 12 : hour + 12 }
        } else {
            guard hour < 24 else { return nil }
            if let now, group(first + 1, match, text) == nil, (1...11).contains(hour) {
                let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
                let evening = calendar.date(bySettingHour: hour + 12, minute: minute, second: 0, of: now)!
                if today <= now, evening > now { hour += 12 }
            }
        }
        return (hour, minute)
    }

    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func remainder(_ text: String, before match: NSTextCheckingResult) -> String {
        guard let range = Range(match.range, in: text) else { return text }
        return text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
