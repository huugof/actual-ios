import Foundation

enum MoneyFormatter {
    private static let displayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = .autoupdatingCurrent
        return f
    }()

    static func display(minor: Int64) -> String {
        let value = NSDecimalNumber(value: Double(minor) / 100.0)
        return displayFormatter.string(from: value) ?? "\(Double(minor) / 100.0)"
    }

    static func currencyInputText(minor: Int64) -> String {
        let sign = minor < 0 ? "-" : ""
        let absoluteMinor = abs(minor)
        let whole = absoluteMinor / 100
        let cents = absoluteMinor % 100
        return "\(sign)\(whole).\(String(format: "%02lld", cents))"
    }

    static func normalizeShiftedCurrencyInput(_ raw: String) -> String {
        currencyInputText(minor: shiftedInputToMinor(raw))
    }

    static func shiftedInputToMinor(_ raw: String) -> Int64 {
        let sign: Int64 = raw.contains("-") ? -1 : 1
        let digits = raw.filter(\.isNumber)
        let absoluteMinor = Int64(digits) ?? 0
        return sign * absoluteMinor
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

enum IdentifierHeuristics {
    /// Returns true when `value` looks like a machine-generated opaque identifier
    /// rather than a human-readable name (UUID, long hex string, etc.).
    static func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil { return true }
        let lower = value.lowercased()
        if lower.contains(" ") { return false }
        if lower.range(of: "^[a-f0-9]{16,}$", options: .regularExpression) != nil { return true }
        if lower.range(of: "^[a-z0-9_-]{20,}$", options: .regularExpression) != nil { return true }
        let letters = lower.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = lower.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return lower.count >= 10 && letters > 0 && digits > 0
    }
}
