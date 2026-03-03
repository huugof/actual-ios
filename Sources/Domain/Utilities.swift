import Foundation

enum MoneyFormatter {
    static func display(minor: Int64, currencyCode: String = Locale.current.currency?.identifier ?? "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        let value = NSDecimalNumber(value: Double(minor) / 100.0)
        return formatter.string(from: value) ?? "\(Double(minor) / 100.0)"
    }

    static func parseToMinor(_ raw: String) -> Int64? {
        let sanitized = raw.replacingOccurrences(of: "[^0-9.-]", with: "", options: .regularExpression)
        guard let decimal = Decimal(string: sanitized) else { return nil }
        return NSDecimalNumber(decimal: decimal * 100).int64Value
    }
}

enum LookupRanker {
    static func rank(query: String, values: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return values }
        return values.sorted { lhs, rhs in
            let ll = lhs.lowercased()
            let rr = rhs.lowercased()

            let lhsStarts = ll.hasPrefix(q)
            let rhsStarts = rr.hasPrefix(q)
            if lhsStarts != rhsStarts { return lhsStarts }

            let lhsContains = ll.contains(q)
            let rhsContains = rr.contains(q)
            if lhsContains != rhsContains { return lhsContains }

            return ll < rr
        }
    }
}
