import Foundation
import GRDB

struct CategorySyncPayload: Codable, Sendable {
    let id: String
    let name: String
    let groupName: String?
    let isIncome: Bool
    let budgetedMinor: Int64
    let spentMinor: Int64
}

actor DatabaseService {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        let migrator = Self.makeMigrator()
        try migrator.migrate(dbQueue)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_schema") { db in
            try db.create(table: AccountRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: PayeeRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("lastUsedAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: CategoryRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("groupName", .text)
                t.column("isIncome", .boolean).notNull().defaults(to: false)
                t.column("budgetedMinor", .integer).notNull().defaults(to: 0)
                t.column("spentMinor", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: TrackedCategoryRow.databaseTableName) { t in
                t.column("categoryID", .text).primaryKey()
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: TransactionRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("remoteID", .text)
                t.column("amountMinor", .integer).notNull()
                t.column("payeeID", .text)
                t.column("payeeName", .text).notNull()
                t.column("accountID", .text).notNull()
                t.column("date", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("isSplit", .boolean).notNull().defaults(to: false)
                t.column("categorySummary", .text).notNull().defaults(to: "")
                t.column("categoryIDsJSON", .text).notNull().defaults(to: "[]")
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: SplitLineRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("transactionID", .text).notNull().indexed()
                t.column("categoryID", .text).notNull()
                t.column("amountMinor", .integer).notNull()
            }

            try db.create(table: PendingMutationRow.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull().indexed()
                t.column("payload", .blob).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("nextAttemptAt", .datetime).notNull()
                t.column("lastError", .text)
                t.column("transactionLocalID", .text)
            }

            try db.create(table: AppConfigRow.databaseTableName) { t in
                t.column("id", .integer).primaryKey().notNull()
                t.column("baseURL", .text).notNull()
                t.column("syncID", .text).notNull()
                t.column("recentFilterMode", .text).notNull().defaults(to: RecentFilterMode.trackedOnly.rawValue)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }

    func loadConfig() async throws -> (baseURL: String, syncID: String, filterMode: RecentFilterMode)? {
        try await dbQueue.read { db in
            guard let row = try AppConfigRow.fetchOne(db, key: 1) else {
                return nil
            }
            return (row.baseURL, row.syncID, RecentFilterMode(rawValue: row.recentFilterMode) ?? .trackedOnly)
        }
    }

    func saveConfig(baseURL: String, syncID: String, filterMode: RecentFilterMode) async throws {
        try await dbQueue.write { db in
            let row = AppConfigRow(id: 1, baseURL: baseURL, syncID: syncID, recentFilterMode: filterMode.rawValue, updatedAt: .now)
            try row.save(db)
        }
    }

    func setTrackedCategoryIDs(_ ids: [String]) async throws {
        try await dbQueue.write { db in
            try TrackedCategoryRow.deleteAll(db)
            for (index, id) in ids.enumerated() {
                try TrackedCategoryRow(categoryID: id, sortOrder: index).insert(db)
            }
        }
    }

    func fetchTrackedCategoryIDs() async throws -> [String] {
        try await dbQueue.read { db in
            try TrackedCategoryRow
                .order(Column("sortOrder"))
                .fetchAll(db)
                .map(\.categoryID)
        }
    }

    func upsertAccounts(_ accounts: [Account]) async throws {
        try await dbQueue.write { db in
            let incomingIDs = Set(accounts.map(\.id))
            for account in accounts {
                let row = AccountRow(id: account.id, name: account.name, updatedAt: .now)
                try row.save(db)
            }

            if incomingIDs.isEmpty {
                try AccountRow.deleteAll(db)
            } else {
                let ids = Array(incomingIDs)
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM accounts WHERE id NOT IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
            }
        }
    }

    func upsertPayees(_ payees: [Payee]) async throws {
        try await dbQueue.write { db in
            for payee in payees {
                let row = PayeeRow(id: payee.id, name: payee.name, lastUsedAt: payee.lastUsedAt, updatedAt: .now)
                try row.save(db)
            }
        }
    }

    func upsertCategories(_ categories: [CategorySyncPayload]) async throws {
        try await dbQueue.write { db in
            for category in categories {
                let row = CategoryRow(
                    id: category.id,
                    name: category.name,
                    groupName: category.groupName,
                    isIncome: category.isIncome,
                    budgetedMinor: category.budgetedMinor,
                    spentMinor: category.spentMinor,
                    updatedAt: .now
                )
                try row.save(db)
            }
        }
    }

    func applyCategoryBudgetSnapshots(_ snapshots: [CategoryBudgetSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        try await dbQueue.write { db in
            for snapshot in snapshots {
                try db.execute(
                    sql: "UPDATE categories SET budgetedMinor = ?, spentMinor = ?, updatedAt = ? WHERE id = ?",
                    arguments: [snapshot.budgetedMinor, snapshot.spentMinor, Date.now, snapshot.id]
                )
            }
        }
    }

    func fetchAccounts() async throws -> [Account] {
        try await dbQueue.read { db in
            try AccountRow.order(Column("name")).fetchAll(db).map(\.domain)
        }
    }

    func fetchAllCategories() async throws -> [Category] {
        try await dbQueue.read { db in
            try CategoryRow
                .filter(Column("isIncome") == false)
                .order(Column("name"))
                .fetchAll(db)
                .map(\.domain)
        }
    }

    func fetchTrackedCategories() async throws -> [Category] {
        try await dbQueue.read { db in
            let trackedRows = try TrackedCategoryRow.order(Column("sortOrder")).fetchAll(db)
            let trackedIDs = trackedRows.map(\.categoryID)
            guard !trackedIDs.isEmpty else { return [] }

            return try CategoryRow
                .filter(Column("isIncome") == false)
                .filter(trackedIDs.contains(Column("id")))
                .fetchAll(db)
                .map(\.domain)
                .sorted { lhs, rhs in
                    let li = trackedIDs.firstIndex(of: lhs.id) ?? 0
                    let ri = trackedIDs.firstIndex(of: rhs.id) ?? 0
                    return li < ri
                }
        }
    }

    func upsertPayee(_ payee: Payee) async throws {
        try await dbQueue.write { db in
            let row = PayeeRow(id: payee.id, name: payee.name, lastUsedAt: payee.lastUsedAt, updatedAt: .now)
            try row.save(db)
        }
    }

    func categoryName(id: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM categories WHERE id = ?", arguments: [id])
        }
    }

    func payeeName(id: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM payees WHERE id = ?", arguments: [id])
        }
    }

    func categoryNames(ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM categories WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            var names: [String: String] = [:]
            for row in rows {
                let id: String = row["id"]
                let name: String = row["name"]
                names[id] = name
            }
            return names
        }
    }

    func fetchHomeSnapshot(filterMode: RecentFilterMode, recentLimit: Int) async throws -> HomeSnapshot {
        try await dbQueue.read { db in
            let trackedRows = try TrackedCategoryRow.order(Column("sortOrder")).fetchAll(db)
            let trackedIDs = trackedRows.map(\.categoryID)

            let allExpenseRows = try CategoryRow
                .filter(Column("isIncome") == false)
                .fetchAll(db)
            let overallBudget = BudgetSummary(
                budgetedMinor: allExpenseRows.reduce(0) { $0 + $1.budgetedMinor },
                spentMinor: allExpenseRows.reduce(0) { $0 + $1.spentMinor }
            )
            let categoryByID = Dictionary(uniqueKeysWithValues: allExpenseRows.map { ($0.id, $0) })

            let statuses: [CategoryBudgetStatus]
            if trackedIDs.isEmpty {
                statuses = []
            } else {
                statuses = trackedIDs.compactMap { categoryByID[$0]?.status }
            }
            let trackedSet = Set(trackedIDs)
            let otherBudgetStatuses = allExpenseRows
                .filter { !trackedSet.contains($0.id) }
                .map(\.status)
                .sorted { lhs, rhs in
                    let lg = lhs.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rg = rhs.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lGroup = (lg?.isEmpty == false ? lg! : "Ungrouped")
                    let rGroup = (rg?.isEmpty == false ? rg! : "Ungrouped")
                    let groupOrder = lGroup.localizedCaseInsensitiveCompare(rGroup)
                    if groupOrder != .orderedSame {
                        return groupOrder == .orderedAscending
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

            let txRequest = TransactionRow.order(Column("date").desc, Column("updatedAt").desc).limit(recentLimit)
            if filterMode == .trackedOnly, !trackedIDs.isEmpty {
                let all = try TransactionRow.order(Column("date").desc, Column("updatedAt").desc).fetchAll(db)
                let filtered = all.filter { !trackedSet.isDisjoint(with: Set($0.categoryIDs)) }
                let recents = Array(filtered.prefix(recentLimit)).map(\.domain)
                let queuedCount = try PendingMutationRow.filter(Column("state") != PendingMutationState.failed.rawValue).fetchCount(db)
                return HomeSnapshot(
                    trackedStatuses: statuses,
                    overallBudget: overallBudget,
                    otherBudgetStatuses: otherBudgetStatuses,
                    recents: recents,
                    queuedMutationCount: queuedCount
                )
            }

            let recents = try txRequest.fetchAll(db).map(\.domain)
            let queuedCount = try PendingMutationRow.filter(Column("state") != PendingMutationState.failed.rawValue).fetchCount(db)
            return HomeSnapshot(
                trackedStatuses: statuses,
                overallBudget: overallBudget,
                otherBudgetStatuses: otherBudgetStatuses,
                recents: recents,
                queuedMutationCount: queuedCount
            )
        }
    }

    func fetchTransactionsForCategory(
        _ categoryID: String,
        monthPrefix: String,
        limit: Int
    ) async throws -> [RecentTransactionItem] {
        try await dbQueue.read { db in
            let rows = try TransactionRow
                .filter(Column("date").like("\(monthPrefix)%"))
                .order(Column("date").desc, Column("updatedAt").desc)
                .fetchAll(db)

            let filtered = rows.filter { $0.categoryIDs.contains(categoryID) }
            return Array(filtered.prefix(limit)).map(\.domain)
        }
    }

    func searchPayees(query: String, limit: Int = 15) async throws -> [Payee] {
        try await dbQueue.read { db in
            let allRows = try PayeeRow.fetchAll(db)
            let sorted = allRows.sorted { lhs, rhs in
                let lName = lhs.name.lowercased()
                let rName = rhs.name.lowercased()
                let q = query.lowercased()

                let ls = lName.hasPrefix(q)
                let rs = rName.hasPrefix(q)
                if ls != rs { return ls }

                let ll = lhs.lastUsedAt ?? .distantPast
                let rl = rhs.lastUsedAt ?? .distantPast
                if ll != rl { return ll > rl }

                return lName < rName
            }

            return Array(sorted.prefix(limit)).map(\.domain)
        }
    }

    func searchCategories(query: String, trackedOnly: Bool, limit: Int = 20) async throws -> [Category] {
        try await dbQueue.read { db in
            let trackedIDs = trackedOnly ? Set(try TrackedCategoryRow.fetchAll(db).map(\.categoryID)) : nil
            let all = try CategoryRow.fetchAll(db)
            let q = query.lowercased()

            let filtered = all.filter { row in
                guard !row.isIncome else { return false }
                if let trackedIDs, !trackedIDs.contains(row.id) { return false }
                if q.isEmpty { return true }
                return row.name.lowercased().contains(q)
            }

            let sorted = filtered.sorted { lhs, rhs in
                let ls = lhs.name.lowercased().hasPrefix(q)
                let rs = rhs.name.lowercased().hasPrefix(q)
                if ls != rs { return ls }
                return lhs.name.lowercased() < rhs.name.lowercased()
            }

            return Array(sorted.prefix(limit)).map(\.domain)
        }
    }

    func touchPayeeLastUsed(payeeID: String?) async throws {
        guard let payeeID else { return }
        try await dbQueue.write { db in
            if var row = try PayeeRow.fetchOne(db, key: payeeID) {
                row.lastUsedAt = .now
                row.updatedAt = .now
                try row.update(db)
            }
        }
    }

    func saveTransaction(
        draft: TransactionDraft,
        payeeName: String,
        categorySummary: String,
        categoryIDs: [String],
        splits: [TransactionSplit]
    ) async throws -> UUID {
        let id = draft.localID ?? UUID()
        let now = Date.now
        let categoryIDsJSONData = try JSONEncoder().encode(categoryIDs)
        let categoryIDsJSON = String(decoding: categoryIDsJSONData, as: UTF8.self)

        let transactionRow = TransactionRow(
            id: id,
            remoteID: draft.remoteID,
            amountMinor: draft.amountMinor,
            payeeID: {
                if case .existing(let id) = draft.payee { return id }
                return nil
            }(),
            payeeName: payeeName,
            accountID: draft.accountID,
            date: draft.date.value,
            note: draft.note,
            isSplit: {
                if case .split = draft.categoryMode { return true }
                return false
            }(),
            categorySummary: categorySummary,
            categoryIDsJSON: categoryIDsJSON,
            updatedAt: now
        )

        try await dbQueue.write { db in
            try transactionRow.save(db)
            try SplitLineRow.filter(Column("transactionID") == id).deleteAll(db)
            for split in splits {
                try SplitLineRow(id: split.id, transactionID: id, categoryID: split.categoryID, amountMinor: split.amountMinor).insert(db)
            }
        }

        return id
    }

    func fetchRecentTransaction(id: UUID) async throws -> RecentTransactionItem? {
        try await dbQueue.read { db in
            try TransactionRow.fetchOne(db, key: id).map(\.domain)
        }
    }

    func loadDraft(localID: UUID) async throws -> TransactionDraft? {
        try await dbQueue.read { db in
            guard let row = try TransactionRow.fetchOne(db, key: localID) else {
                return nil
            }

            let splitRows = try SplitLineRow
                .filter(Column("transactionID") == localID)
                .fetchAll(db)

            let mode: TransactionCategoryMode
            if splitRows.isEmpty, let firstCategory = row.categoryIDs.first {
                mode = .single(categoryID: firstCategory)
            } else {
                mode = .split(splitRows.map { split in
                    TransactionSplit(id: split.id, categoryID: split.categoryID, amountMinor: split.amountMinor)
                })
            }

            let payee: PayeeSelection? = row.payeeID.map { .existing(id: $0) } ?? .new(name: row.payeeName)

            return TransactionDraft(
                localID: row.id,
                remoteID: row.remoteID,
                amountMinor: row.amountMinor,
                payee: payee,
                accountID: row.accountID,
                date: LocalDate(row.date),
                note: row.note,
                categoryMode: mode
            )
        }
    }

    func upsertRecentTransactions(_ transactions: [RecentTransactionItem]) async throws {
        try await dbQueue.write { db in
            for transaction in transactions {
                let row = TransactionRow(
                    id: transaction.id,
                    remoteID: transaction.remoteID,
                    amountMinor: transaction.amountMinor,
                    payeeID: transaction.payeeID,
                    payeeName: transaction.payeeName,
                    accountID: transaction.accountID,
                    date: transaction.date.value,
                    note: transaction.note,
                    isSplit: transaction.isSplit,
                    categorySummary: transaction.categorySummary,
                    categoryIDsJSON: String(decoding: try JSONEncoder().encode(transaction.categoryIDs), as: UTF8.self),
                    updatedAt: transaction.updatedAt
                )
                try row.save(db)
            }
        }
    }

    func fetchSplits(for transactionID: UUID) async throws -> [TransactionSplit] {
        try await dbQueue.read { db in
            try SplitLineRow
                .filter(Column("transactionID") == transactionID)
                .order(Column("id"))
                .fetchAll(db)
                .map { row in
                    TransactionSplit(id: row.id, categoryID: row.categoryID, amountMinor: row.amountMinor)
                }
        }
    }

    func deleteTransaction(localID: UUID) async throws {
        try await dbQueue.write { db in
            try SplitLineRow.filter(Column("transactionID") == localID).deleteAll(db)
            _ = try TransactionRow.deleteOne(db, key: localID)
        }
    }

    func setTransactionRemoteID(localID: UUID, remoteID: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transactions SET remoteID = ?, updatedAt = ? WHERE id = ?",
                arguments: [remoteID, Date.now, localID]
            )
        }
    }

    func fetchTransactionRemoteID(localID: UUID) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT remoteID FROM transactions WHERE id = ?", arguments: [localID])
        }
    }

    func enqueueMutation(_ mutation: PendingMutation) async throws {
        let row = PendingMutationRow(
            id: mutation.id,
            type: mutation.type.rawValue,
            payload: mutation.payload,
            state: mutation.state.rawValue,
            retryCount: mutation.retryCount,
            createdAt: mutation.createdAt,
            nextAttemptAt: mutation.nextAttemptAt,
            lastError: mutation.lastError,
            transactionLocalID: mutation.transactionLocalID
        )
        try await dbQueue.write { db in
            try row.insert(db)
        }
    }

    func fetchReadyMutations(limit: Int = 10, now: Date = .now) async throws -> [PendingMutation] {
        try await dbQueue.read { db in
            let rows = try PendingMutationRow
                .filter(Column("state") == PendingMutationState.queued.rawValue)
                .filter(Column("nextAttemptAt") <= now)
                .order(Column("createdAt"))
                .limit(limit)
                .fetchAll(db)

            return rows.compactMap { $0.toDomain() }
        }
    }

    func markMutationSyncing(_ id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE pending_mutations SET state = ? WHERE id = ?", arguments: [PendingMutationState.syncing.rawValue, id])
        }
    }

    func markMutationCompleted(_ id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try PendingMutationRow.deleteOne(db, key: id)
        }
    }

    func markMutationFailed(_ id: UUID, retryCount: Int, delay: TimeInterval, lastError: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pending_mutations SET state = ?, retryCount = ?, nextAttemptAt = ?, lastError = ? WHERE id = ?",
                arguments: [
                    PendingMutationState.queued.rawValue,
                    retryCount,
                    Date.now.addingTimeInterval(delay),
                    lastError,
                    id
                ]
            )
        }
    }

    func markMutationPermanentFailure(_ id: UUID, lastError: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pending_mutations SET state = ?, lastError = ? WHERE id = ?",
                arguments: [PendingMutationState.failed.rawValue, lastError, id]
            )
        }
    }

    func pendingMutationCount() async throws -> Int {
        try await dbQueue.read { db in
            try PendingMutationRow.filter(Column("state") != PendingMutationState.failed.rawValue).fetchCount(db)
        }
    }

    func fetchPendingDeleteTransactionLocalIDs() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT transactionLocalID
                    FROM pending_mutations
                    WHERE type = ?
                      AND state IN (?, ?)
                      AND transactionLocalID IS NOT NULL
                """,
                arguments: [
                    PendingMutationType.deleteTransaction.rawValue,
                    PendingMutationState.queued.rawValue,
                    PendingMutationState.syncing.rawValue
                ]
            )

            var ids = Set<UUID>()
            for row in rows {
                let value: DatabaseValue = row["transactionLocalID"]
                if let id = DatabaseService.uuidFromDatabaseValue(value) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    nonisolated private static func uuidFromDatabaseValue(_ value: DatabaseValue) -> UUID? {
        if value.isNull {
            return nil
        }
        if let id = UUID.fromDatabaseValue(value) {
            return id
        }
        if let raw = String.fromDatabaseValue(value), let id = UUID(uuidString: raw) {
            return id
        }
        if let data = Data.fromDatabaseValue(value), data.count == 16 {
            let bytes = Array(data)
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        return nil
    }
}
