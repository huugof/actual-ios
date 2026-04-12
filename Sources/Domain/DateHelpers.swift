import Foundation

enum DateHelpers {
    /// Extracts the "YYYY-MM" prefix from a date string, returning nil if the
    /// string doesn't begin with a valid year-month pattern.
    static func monthPrefix(from rawDate: String) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 7 else { return nil }
        let prefix = String(trimmed.prefix(7))
        guard prefix.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return prefix
    }

    /// Returns the current month as "YYYY-MM".
    static func currentMonthPrefix(calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month], from: .now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    /// Returns a "YYYY-MM" string for the current month offset by `offset` months.
    static func monthString(offset: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(byAdding: .month, value: offset, to: .now) ?? .now
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    /// Returns a deduplicated copy of `values` in original order, dropping empty strings.
    static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }
}
