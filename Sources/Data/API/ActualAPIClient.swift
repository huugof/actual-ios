import CryptoKit
import Foundation

protocol ActualAPIClientProtocol: Sendable {
    func fetchAccounts() async throws -> [Account]
    func fetchPayees() async throws -> [Payee]
    func fetchCategories() async throws -> [CategorySyncPayload]
    func fetchCategoryBudgetSnapshots(monthCandidates: [String]) async throws -> [CategoryBudgetSnapshot]
    func fetchRecentTransactions(
        limit: Int,
        daysBack: Int,
        accountIDs: [String]?,
        allowPartialFailures: Bool
    ) async throws -> [RecentTransactionItem]
    func createPayee(name: String) async throws -> Payee
    func createTransaction(payload: APICreateTransactionPayload) async throws -> APISavedTransaction
    func updateTransaction(id: String, payload: APIUpdateTransactionPayload) async throws -> APISavedTransaction
    func deleteTransaction(id: String) async throws
}

struct APICreateTransactionPayload: Codable, Sendable {
    let accountID: String
    let date: String
    let amountMinor: Int64
    let payeeID: String?
    let payeeName: String?
    let notes: String?
    let categoryID: String?
    let splits: [APISplitPayload]?
}

struct APIUpdateTransactionPayload: Codable, Sendable {
    let accountID: String
    let date: String
    let amountMinor: Int64
    let payeeID: String?
    let payeeName: String?
    let notes: String?
    let categoryID: String?
    let splits: [APISplitPayload]?
}

struct APISplitPayload: Codable, Sendable {
    let categoryID: String
    let amountMinor: Int64
}

private extension APISplitPayload {
    var transport: APITransportSplit {
        APITransportSplit(category: categoryID, amount: amountMinor)
    }
}

private extension APICreateTransactionPayload {
    var transport: APITransportTransaction {
        APITransportTransaction(
            account: accountID,
            date: date,
            amount: amountMinor,
            payee: payeeID,
            payeeName: payeeName,
            notes: notes,
            category: categoryID,
            subtransactions: splits?.map(\.transport)
        )
    }
}

private extension APIUpdateTransactionPayload {
    var transport: APITransportTransaction {
        APITransportTransaction(
            account: accountID,
            date: date,
            amount: amountMinor,
            payee: payeeID,
            payeeName: payeeName,
            notes: notes,
            category: categoryID,
            subtransactions: splits?.map(\.transport)
        )
    }
}

struct APISavedTransaction: Codable, Sendable {
    let id: String?
    let message: String?
}

private struct APIPayeeCreateBody: Codable {
    let payee: APIPayeeCreate
}

private struct APIPayeeCreate: Codable {
    let name: String
}

private struct APITransactionBody: Codable {
    let transaction: APITransportTransaction
    let learnCategories: Bool
    let runTransfers: Bool
}

private struct APITransactionUpdateBody: Codable {
    let transaction: APITransportTransaction
}

private struct APITransportTransaction: Codable {
    let account: String
    let date: String
    let amount: Int64
    let payee: String?
    let payeeName: String?
    let notes: String?
    let category: String?
    let subtransactions: [APITransportSplit]?

    enum CodingKeys: String, CodingKey {
        case account
        case date
        case amount
        case payee
        case payeeName = "payee_name"
        case notes
        case category
        case subtransactions
    }
}

private struct APITransportSplit: Codable {
    let category: String
    let amount: Int64
}

enum APIClientError: LocalizedError {
    case invalidResponse(details: String)
    case httpError(statusCode: Int, message: String)
    case requestCancelled(endpoint: String)
    case networkError(details: String)
    case partialFailure(details: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let details):
            return "Invalid response from server (\(details))"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .requestCancelled(let endpoint):
            return "Request canceled: \(endpoint)"
        case .networkError(let details):
            return "Network error: \(details)"
        case .partialFailure(let details):
            return details
        }
    }
}

struct ActualHTTPAPIClient: ActualAPIClientProtocol {
    private let configProvider: @Sendable () async throws -> APIConfiguration?
    private let session: URLSession

    init(
        configProvider: @escaping @Sendable () async throws -> APIConfiguration?,
        session: URLSession = .shared
    ) {
        self.configProvider = configProvider
        self.session = session
    }

    func fetchAccounts() async throws -> [Account] {
        let data = try await request(path: "accounts", method: "GET")
        let dtos = try decodeList(AccountDTO.self, from: data, context: "GET accounts")
        return dtos
            .filter { !$0.isOffBudget && !$0.isClosed }
            .map { Account(id: $0.id, name: $0.name) }
    }

    func fetchPayees() async throws -> [Payee] {
        let data = try await request(path: "payees", method: "GET")
        let dtos = try decodeList(PayeeDTO.self, from: data, context: "GET payees")
        return dtos.map {
            Payee(id: $0.id, name: $0.name, lastUsedAt: $0.lastUsedAt)
        }
    }

    func fetchCategories() async throws -> [CategorySyncPayload] {
        let data = try await request(path: "categories", method: "GET")
        let dtos = try decodeList(CategoryDTO.self, from: data, context: "GET categories")

        var monthBudgets: [String: (budgeted: Int64, spent: Int64)] = [:]
        var monthGroupNames: [String: String] = [:]
        var monthGroupIDs: [String: String] = [:]
        var categoryGroupNamesByID: [String: String] = [:]
        let preferredMonth = try? await preferredBudgetMonth()
        let monthCandidates = Self.uniquePreservingOrder(
            Self.monthCandidates(from: preferredMonth)
            + Self.monthCandidates(from: Self.currentMonthString())
            + Self.recentMonthFallbacks(count: 3)
        )

        var resolvedMonth: String?
        var lastMonthError: Error?
        for month in monthCandidates {
            do {
                let context = try await monthCategoryContext(month: month)
                guard !context.budgets.isEmpty else { continue }
                monthBudgets = context.budgets
                monthGroupNames = context.groupNames
                monthGroupIDs = context.groupIDs
                resolvedMonth = month
                break
            } catch {
                lastMonthError = error
            }
        }

        if monthBudgets.isEmpty, !dtos.isEmpty {
            let reason = lastMonthError.map(Self.describeError) ?? "No month budget rows were returned by server endpoints."
            throw APIClientError.invalidResponse(details: "Unable to load category budget amounts. \(reason)")
        }

        if let resolvedMonth {
            let needsGroupIDLookup = dtos.contains { dto in
                let monthName = monthGroupNames[dto.id]
                if Self.normalizedGroupName(monthName) != nil || Self.normalizedGroupName(dto.groupName) != nil {
                    return false
                }
                if let monthGroupID = monthGroupIDs[dto.id], !monthGroupID.isEmpty {
                    return true
                }
                if let dtoGroupID = dto.groupID, !dtoGroupID.isEmpty {
                    return true
                }
                return false
            }
            if needsGroupIDLookup {
                do {
                    categoryGroupNamesByID = try await categoryGroupNameMap(month: resolvedMonth)
                } catch {
                    // Optional enhancement only; ignore failures and fall back to category metadata.
                }
            }
        }

        return dtos.map {
            let budgetSnapshot = monthBudgets[$0.id]
            let monthGroupName = monthGroupNames[$0.id]
            let monthGroupID = monthGroupIDs[$0.id]
            let categoryGroupID = Self.normalizedGroupName(monthGroupID) == nil ? monthGroupID : nil
            let dtoGroupID = Self.normalizedGroupName($0.groupID) == nil ? $0.groupID : nil
            let mappedByMonthGroupID = categoryGroupID.flatMap { categoryGroupNamesByID[$0] }
            let mappedByDTOGroupID = dtoGroupID.flatMap { categoryGroupNamesByID[$0] }
            let resolvedGroupName =
                Self.normalizedGroupName(monthGroupName)
                ?? Self.normalizedGroupName(mappedByMonthGroupID)
                ?? Self.normalizedGroupName(mappedByDTOGroupID)
                ?? Self.normalizedGroupName($0.groupName)
            return CategorySyncPayload(
                id: $0.id,
                name: $0.name,
                groupName: resolvedGroupName,
                isIncome: $0.isIncome,
                budgetedMinor: budgetSnapshot?.budgeted ?? 0,
                spentMinor: budgetSnapshot?.spent ?? 0
            )
        }
    }

    func fetchCategoryBudgetSnapshots(monthCandidates: [String]) async throws -> [CategoryBudgetSnapshot] {
        let candidates = Self.uniquePreservingOrder(
            monthCandidates.flatMap { Self.monthCandidates(from: $0) }
        )
        let fallbackCandidates = Self.uniquePreservingOrder(
            candidates + [Self.currentMonthString()] + Self.recentMonthFallbacks(count: 2)
        )

        var lastError: Error?
        for month in fallbackCandidates {
            do {
                let snapshots = try await monthCategorySnapshotsFast(month: month)
                if !snapshots.isEmpty {
                    return snapshots
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw APIClientError.invalidResponse(details: "Unable to load month category budget snapshots")
    }

    func fetchRecentTransactions(
        limit: Int,
        daysBack: Int,
        accountIDs: [String]?,
        allowPartialFailures: Bool
    ) async throws -> [RecentTransactionItem] {
        let accounts: [Account]
        if let accountIDs {
            let uniqueIDs = Self.uniquePreservingOrder(accountIDs)
            accounts = uniqueIDs.map { Account(id: $0, name: $0) }
        } else {
            accounts = try await fetchAccounts()
        }
        guard !accounts.isEmpty else { return [] }

        let sinceDate = Self.isoDateString(daysBack: daysBack)
        var allTransactions: [TransactionDTO] = []
        var failures: [String] = []
        await withTaskGroup(of: (String, Result<[TransactionDTO], Error>).self) { group in
            for account in accounts {
                group.addTask {
                    let endpoint = "accounts/\(account.id)/transactions?since_date=\(sinceDate)"
                    do {
                        let data = try await request(path: endpoint, method: "GET")
                        let decoded = try decodeList(
                            TransactionDTO.self,
                            from: data,
                            context: "GET accounts/\(account.id)/transactions"
                        )
                        return (account.name, .success(decoded))
                    } catch {
                        return (account.name, .failure(error))
                    }
                }
            }

            for await (accountName, result) in group {
                switch result {
                case .success(let accountTransactions):
                    allTransactions.append(contentsOf: accountTransactions)
                case .failure(let error):
                    failures.append("\(accountName): \(Self.describeError(error))")
                }
            }
        }
        if !failures.isEmpty {
            if !allowPartialFailures || allTransactions.isEmpty {
                throw APIClientError.partialFailure(
                    details: "Recent transaction fetch incomplete. \(failures.joined(separator: " | "))"
                )
            }
        }

        let deduped = Dictionary(grouping: allTransactions, by: \.id).compactMap { $0.value.first }
        let sorted = deduped.sorted {
            if $0.date == $1.date {
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            return $0.date > $1.date
        }

        return sorted.prefix(limit).map { dto in
            let categoryIDs: [String]
            let isSplit: Bool
            let summary: String

            if let subs = dto.subtransactions, !subs.isEmpty {
                categoryIDs = subs.map { $0.categoryID }
                isSplit = true
                summary = "Split (\(subs.count))"
            } else {
                categoryIDs = dto.categoryID.map { [$0] } ?? []
                isSplit = false
                summary = dto.categoryName
                    ?? "Uncategorized"
            }

            return RecentTransactionItem(
                id: stableUUID(from: dto.id),
                remoteID: dto.id,
                amountMinor: dto.amountMinor,
                payeeName: dto.payeeName
                    ?? dto.importedPayee
                    ?? "Unknown",
                payeeID: dto.payeeID,
                accountID: dto.accountID,
                date: LocalDate(dto.date),
                note: dto.notes ?? "",
                categorySummary: summary,
                isSplit: isSplit,
                categoryIDs: categoryIDs,
                updatedAt: dto.updatedAt ?? .now
            )
        }
    }

    func createPayee(name: String) async throws -> Payee {
        let createBody = APIPayeeCreateBody(payee: APIPayeeCreate(name: name))
        let data = try await request(path: "payees", method: "POST", body: createBody)
        let payeeID = try decode(String.self, from: data, context: "POST payees")
        do {
            let payeeData = try await request(path: "payees/\(payeeID)", method: "GET")
            let dto = try decode(PayeeDTO.self, from: payeeData, context: "GET payees/\(payeeID)")
            return Payee(id: dto.id, name: dto.name, lastUsedAt: dto.lastUsedAt)
        } catch {
            return Payee(id: payeeID, name: name, lastUsedAt: .now)
        }
    }

    func createTransaction(payload: APICreateTransactionPayload) async throws -> APISavedTransaction {
        let body = APITransactionBody(
            transaction: payload.transport,
            learnCategories: false,
            runTransfers: false
        )
        let data = try await request(path: "accounts/\(payload.accountID)/transactions", method: "POST", body: body)
        return try decode(
            APISavedTransaction.self,
            from: data,
            context: "POST accounts/\(payload.accountID)/transactions"
        )
    }

    func updateTransaction(id: String, payload: APIUpdateTransactionPayload) async throws -> APISavedTransaction {
        let body = APITransactionUpdateBody(transaction: payload.transport)
        let data = try await request(path: "transactions/\(id)", method: "PATCH", body: body)
        return try decode(APISavedTransaction.self, from: data, context: "PATCH transactions/\(id)")
    }

    func deleteTransaction(id: String) async throws {
        _ = try await request(path: "transactions/\(id)", method: "DELETE")
    }

    private func request(path: String, method: String) async throws -> Data {
        try await request(path: path, method: method, timeoutInterval: 20, body: Optional<String>.none)
    }

    private func request<T: Encodable>(path: String, method: String, body: T?) async throws -> Data {
        try await request(path: path, method: method, timeoutInterval: 20, body: body)
    }

    private func request<T: Encodable>(path: String, method: String, timeoutInterval: TimeInterval, body: T?) async throws -> Data {
        guard let cfg = try await configProvider() else {
            throw APIClientError.httpError(statusCode: 499, message: "Missing API configuration")
        }

        let base = cfg.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("budgets")
            .appendingPathComponent(cfg.syncID)
        let endpointURL = try buildURL(base: base, pathWithOptionalQuery: path)

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue(cfg.apiKey, forHTTPHeaderField: "x-api-key")
        if let encryptionPassword = cfg.budgetEncryptionPassword, !encryptionPassword.isEmpty {
            urlRequest.addValue(encryptionPassword, forHTTPHeaderField: "budget-encryption-password")
        }

        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            urlRequest.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw APIClientError.requestCancelled(endpoint: "\(method) \(endpointURL.absoluteString)")
        } catch is CancellationError {
            throw APIClientError.requestCancelled(endpoint: "\(method) \(endpointURL.absoluteString)")
        } catch {
            throw APIClientError.networkError(
                details: "\(method) \(endpointURL.absoluteString): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse(
                details: "non-HTTP response for \(method) \(endpointURL.absoluteString)"
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIClientError.httpError(
                statusCode: http.statusCode,
                message: "\(method) \(endpointURL.path): \(message)"
            )
        }

        return data
    }

    private func buildURL(base: URL, pathWithOptionalQuery: String) throws -> URL {
        let trimmed = pathWithOptionalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts.first ?? "")
        let query = parts.count == 2 ? String(parts[1]) : nil

        let pathSegments = rawPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        var url = base
        for segment in pathSegments {
            url = url.appendingPathComponent(segment)
        }

        guard let query, !query.isEmpty else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidResponse(details: "cannot build URL components for \(url.absoluteString)")
        }
        components.percentEncodedQuery = query
        guard let withQuery = components.url else {
            throw APIClientError.invalidResponse(details: "cannot create URL with query '\(query)' from \(url.absoluteString)")
        }
        return withQuery
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        let decoder = Self.makeDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if data.isEmpty, let emptyObject = "{}".data(using: .utf8), let decoded = try? decoder.decode(T.self, from: emptyObject) {
            return decoded
        }
        if let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }
        if let wrapped = try? decoder.decode(APIEnvelope<T>.self, from: data) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(APINullableEnvelope<T>.self, from: data), let value = wrapped.data {
            return value
        }
        throw APIClientError.invalidResponse(details: "\(context): \(responsePreview(from: data))")
    }

    private func decodeList<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> [T] {
        let decoder = Self.makeDecoder()
        if let decoded = try? decoder.decode([T].self, from: data) {
            return decoded
        }
        if let wrapped = try? decoder.decode(APIEnvelope<[T]>.self, from: data) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(APINullableEnvelope<[T]>.self, from: data) {
            return wrapped.data ?? []
        }
        throw APIClientError.invalidResponse(details: "\(context): \(responsePreview(from: data))")
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func responsePreview(from data: Data) -> String {
        guard !data.isEmpty else {
            return "empty body"
        }
        let snippet = String(data: data.prefix(280), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let snippet, !snippet.isEmpty {
            return "body: \(snippet)"
        }
        return "body: <\(data.count) bytes non-UTF8>"
    }

    private func stableUUID(from raw: String) -> UUID {
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let digest = SHA256.hash(data: Data(raw.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isoDateString(daysBack: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysBack, to: .now) ?? .now
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let y = components.year ?? 1970
        let m = components.month ?? 1
        let d = components.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func currentMonthString() -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: .now)
        let y = components.year ?? 1970
        let m = components.month ?? 1
        return String(format: "%04d-%02d", y, m)
    }

    private static func monthCandidates(from raw: String?) -> [String] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // actual-http-api month endpoints expect YYYY-MM only.
        if trimmed.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            return [trimmed]
        }
        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return [String(trimmed.prefix(7))]
        }
        if trimmed.count >= 7 {
            let monthPrefix = String(trimmed.prefix(7))
            if monthPrefix.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
                return [monthPrefix]
            }
        }
        return []
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    private static func recentMonthFallbacks(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let calendar = Calendar.current
        var result: [String] = []
        for offset in 0..<count {
            let date = calendar.date(byAdding: .month, value: -offset, to: .now) ?? .now
            let components = calendar.dateComponents([.year, .month], from: date)
            let y = components.year ?? 1970
            let m = components.month ?? 1
            result.append(String(format: "%04d-%02d", y, m))
        }
        return result
    }

    private func preferredBudgetMonth() async throws -> String? {
        let data = try await request(path: "months", method: "GET")
        let rawMonths = try decodeList(BudgetMonthRef.self, from: data, context: "GET months").map(\.value)
        let months = Self.uniquePreservingOrder(rawMonths.flatMap { Self.monthCandidates(from: $0) })
        guard !months.isEmpty else { return nil }

        let current = Self.currentMonthString()
        if months.contains(current) {
            return current
        }

        let sorted = months.sorted()
        if let latestUpToCurrent = sorted.filter({ $0 <= current }).last {
            return latestUpToCurrent
        }

        return sorted.last
    }

    private func monthCategoryContext(month: String) async throws -> (
        budgets: [String: (budgeted: Int64, spent: Int64)],
        groupNames: [String: String],
        groupIDs: [String: String]
    ) {
        do {
            let data = try await request(path: "months/\(month)", method: "GET")
            let details = try decode(MonthDetailsDTO.self, from: data, context: "GET months/\(month)")
            let categories = details.categoryGroups.flatMap(\.categories)
            if categories.isEmpty {
                return try await monthCategoryContextFromCategoriesEndpoint(month: month)
            }
            let budgets = Dictionary(uniqueKeysWithValues: categories.map { row in
                let normalizedSpent = row.spent < 0 ? abs(row.spent) : row.spent
                return (row.id, (row.budgeted, normalizedSpent))
            })

            var groupNames: [String: String] = [:]
            var groupIDs: [String: String] = [:]
            for group in details.categoryGroups {
                let groupName = Self.normalizedGroupName(group.name)
                for category in group.categories {
                    if let groupName {
                        groupNames[category.id] = groupName
                    } else if let categoryGroupName = Self.normalizedGroupName(category.groupName) {
                        groupNames[category.id] = categoryGroupName
                    }
                    if let categoryGroupID = category.groupID {
                        groupIDs[category.id] = categoryGroupID
                    } else if let groupID = group.id {
                        groupIDs[category.id] = groupID
                    }
                }
            }

            return (budgets: budgets, groupNames: groupNames, groupIDs: groupIDs)
        } catch {
            return try await monthCategoryContextFromCategoriesEndpoint(month: month)
        }
    }

    private func monthCategoryContextFromCategoriesEndpoint(month: String) async throws -> (
        budgets: [String: (budgeted: Int64, spent: Int64)],
        groupNames: [String: String],
        groupIDs: [String: String]
    ) {
        let data = try await request(path: "months/\(month)/categories", method: "GET")
        let monthCategories = try decodeList(
            MonthCategoryDTO.self,
            from: data,
            context: "GET months/\(month)/categories"
        )
        let budgets = Dictionary(uniqueKeysWithValues: monthCategories.map { row in
            let normalizedSpent = row.spent < 0 ? abs(row.spent) : row.spent
            return (row.id, (row.budgeted, normalizedSpent))
        })
        var groupNames: [String: String] = [:]
        for row in monthCategories {
            if let groupName = Self.normalizedGroupName(row.groupName) {
                groupNames[row.id] = groupName
            }
        }
        var groupIDs: [String: String] = [:]
        for row in monthCategories {
            if let groupID = row.groupID {
                groupIDs[row.id] = groupID
            }
        }
        return (budgets: budgets, groupNames: groupNames, groupIDs: groupIDs)
    }

    private func monthCategorySnapshotsFast(month: String) async throws -> [CategoryBudgetSnapshot] {
        let data = try await request(
            path: "months/\(month)/categories",
            method: "GET",
            timeoutInterval: 5,
            body: Optional<String>.none
        )
        let monthCategories = try decodeList(
            MonthCategoryDTO.self,
            from: data,
            context: "GET months/\(month)/categories"
        )
        return monthCategories.map { row in
            CategoryBudgetSnapshot(
                id: row.id,
                budgetedMinor: row.budgeted,
                spentMinor: row.spent < 0 ? abs(row.spent) : row.spent
            )
        }
    }

    private func categoryGroupNameMap(month: String) async throws -> [String: String] {
        do {
            let data = try await request(path: "months/\(month)/categorygroups", method: "GET", timeoutInterval: 5, body: Optional<String>.none)
            let groups = try decodeList(CategoryGroupDTO.self, from: data, context: "GET months/\(month)/categorygroups")
            var map: [String: String] = [:]
            for group in groups {
                if let name = Self.normalizedGroupName(group.name) {
                    map[group.id] = name
                }
            }
            return map
        } catch {
            let data = try await request(path: "categorygroups", method: "GET", timeoutInterval: 5, body: Optional<String>.none)
            let groups = try decodeList(CategoryGroupDTO.self, from: data, context: "GET categorygroups")
            var map: [String: String] = [:]
            for group in groups {
                if let name = Self.normalizedGroupName(group.name) {
                    map[group.id] = name
                }
            }
            return map
        }
    }

    private static func normalizedGroupName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeOpaqueIdentifier(trimmed) {
            return nil
        }
        return trimmed
    }

    private static func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil {
            return true
        }
        let lower = value.lowercased()
        if lower.contains(" ") {
            return false
        }
        if lower.range(of: "^[a-f0-9]{16,}$", options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: "^[a-z0-9_-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        let letters = lower.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = lower.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if lower.count >= 10 && letters > 0 && digits > 0 {
            return true
        }
        return false
    }

    private static func describeError(_ error: Error) -> String {
        if let apiError = error as? APIClientError, let description = apiError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private struct APIEnvelope<T: Decodable>: Decodable {
    let data: T
}

private struct APINullableEnvelope<T: Decodable>: Decodable {
    let data: T?
}

private struct BudgetMonthRef: Decodable {
    let value: String

    private enum CodingKeys: String, CodingKey {
        case month
        case name
        case value
        case date
    }

    init(from decoder: Decoder) throws {
        if let direct = try? decoder.singleValueContainer().decode(String.self) {
            value = direct
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let month = try? c.decode(String.self, forKey: .month) {
            value = month
            return
        }
        if let name = try? c.decode(String.self, forKey: .name) {
            value = name
            return
        }
        if let valueField = try? c.decode(String.self, forKey: .value) {
            value = valueField
            return
        }
        if let date = try? c.decode(String.self, forKey: .date) {
            value = date
            return
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: c.codingPath, debugDescription: "Unable to decode budget month value")
        )
    }
}

private struct AccountDTO: Codable {
    let id: String
    let name: String
    let isOffBudget: Bool
    let isClosed: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isOffBudget = "offbudget"
        case isClosed = "closed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        name = try c.decodeLossyString(forKey: .name)
        isOffBudget = c.decodeLossyBoolIfPresent(forKey: .isOffBudget) ?? false
        isClosed = c.decodeLossyBoolIfPresent(forKey: .isClosed) ?? false
    }
}

private struct PayeeDTO: Codable {
    let id: String
    let name: String
    let lastUsedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastUsedAt = "last_used_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        name = (try? c.decodeLossyString(forKey: .name)) ?? "Unknown"
        lastUsedAt = c.decodeLossyDateIfPresent(forKey: .lastUsedAt)
    }
}

private struct CategoryDTO: Decodable {
    let id: String
    let name: String
    let groupName: String?
    let groupID: String?
    let isIncome: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case groupName = "group_name"
        case groupID = "group_id"
        case isIncome = "is_income"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        name = try c.decodeLossyString(forKey: .name)
        groupName = c.decodeLossyStringIfPresent(forKey: .groupName)
        groupID = c.decodeLossyStringIfPresent(forKey: .groupID)
        isIncome = c.decodeLossyBoolIfPresent(forKey: .isIncome) ?? false
    }
}

private struct TransactionDTO: Codable {
    let id: String
    let accountID: String
    let date: String
    let amountMinor: Int64
    let payeeID: String?
    let payeeName: String?
    let importedPayee: String?
    let notes: String?
    let categoryID: String?
    let categoryName: String?
    let subtransactions: [SubtransactionDTO]?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account"
        case date
        case amountMinor = "amount"
        case payeeID = "payee"
        case payeeName = "payee_name"
        case importedPayee = "imported_payee"
        case notes
        case categoryID = "category"
        case categoryName = "category_name"
        case subtransactions
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        accountID = try c.decodeLossyString(forKey: .accountID)
        date = try c.decodeLossyString(forKey: .date)
        amountMinor = try c.decodeLossyInt64(forKey: .amountMinor)
        payeeID = c.decodeLossyStringIfPresent(forKey: .payeeID)
        payeeName = c.decodeLossyStringIfPresent(forKey: .payeeName)
        importedPayee = c.decodeLossyStringIfPresent(forKey: .importedPayee)
        notes = c.decodeLossyStringIfPresent(forKey: .notes)
        categoryID = c.decodeLossyStringIfPresent(forKey: .categoryID)
        categoryName = c.decodeLossyStringIfPresent(forKey: .categoryName)
        subtransactions = try? c.decodeIfPresent([SubtransactionDTO].self, forKey: .subtransactions)
        updatedAt = c.decodeLossyDateIfPresent(forKey: .updatedAt)
    }
}

private struct SubtransactionDTO: Codable {
    let categoryID: String
    let amountMinor: Int64

    enum CodingKeys: String, CodingKey {
        case categoryID = "category"
        case amountMinor = "amount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = try c.decodeLossyString(forKey: .categoryID)
        amountMinor = try c.decodeLossyInt64(forKey: .amountMinor)
    }
}

private struct MonthCategoryDTO: Codable {
    let id: String
    let budgeted: Int64
    let spent: Int64
    let groupName: String?
    let groupID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case budgeted
        case spent
        case groupName = "group_name"
        case groupID = "group_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        budgeted = try c.decodeLossyInt64(forKey: .budgeted)
        spent = try c.decodeLossyInt64(forKey: .spent)
        groupName = c.decodeLossyStringIfPresent(forKey: .groupName)
        groupID = c.decodeLossyStringIfPresent(forKey: .groupID)
    }
}

private struct MonthDetailsDTO: Decodable {
    let categoryGroups: [MonthCategoryGroupDTO]

    enum CodingKeys: String, CodingKey {
        case categoryGroups
        case category_groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.categoryGroups) {
            categoryGroups = try c.decode([MonthCategoryGroupDTO].self, forKey: .categoryGroups)
            return
        }
        if c.contains(.category_groups) {
            categoryGroups = try c.decode([MonthCategoryGroupDTO].self, forKey: .category_groups)
            return
        }
        throw DecodingError.keyNotFound(
            CodingKeys.categoryGroups,
            DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "Expected categoryGroups/category_groups in month payload"
            )
        )
    }
}

private struct MonthCategoryGroupDTO: Decodable {
    let id: String?
    let name: String?
    let categories: [MonthCategoryDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case categories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeLossyStringIfPresent(forKey: .id)
        name = c.decodeLossyStringIfPresent(forKey: .name)
            ?? c.decodeLossyStringIfPresent(forKey: .title)
        categories = (try? c.decode([MonthCategoryDTO].self, forKey: .categories)) ?? []
    }
}

private struct CategoryGroupDTO: Decodable {
    let id: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeLossyString(forKey: .id)
        name = c.decodeLossyStringIfPresent(forKey: .name)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: K) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            if value.rounded() == value {
                return String(Int64(value))
            }
            return String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Unable to decode string value")
        )
    }

    func decodeLossyStringIfPresent(forKey key: K) -> String? {
        if (try? decodeNil(forKey: key)) == true {
            return nil
        }
        return try? decodeLossyString(forKey: key)
    }

    func decodeLossyBoolIfPresent(forKey key: K) -> Bool? {
        if (try? decodeNil(forKey: key)) == true {
            return nil
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decode(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "n"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    func decodeLossyDateIfPresent(forKey key: K) -> Date? {
        if (try? decodeNil(forKey: key)) == true {
            return nil
        }
        if let value = try? decode(Date.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = try? decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed) {
                let normalized = seconds > 10_000_000_000 ? seconds / 1_000 : seconds
                return Date(timeIntervalSince1970: normalized)
            }
            return parseISODate(trimmed)
        }
        return nil
    }

    func decodeLossyInt64(forKey key: K) throws -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decode(String.self, forKey: key), let intValue = Int64(value) {
            return intValue
        }
        return 0
    }
}

private func parseISODate(_ input: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]

    for formatter in [withFractional, standard] {
        if let date = formatter.date(from: input) {
            return date
        }
    }
    return nil
}
