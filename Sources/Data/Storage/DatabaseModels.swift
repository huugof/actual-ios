import Foundation
import GRDB

struct AccountRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "accounts"

    var id: String
    var name: String
    var updatedAt: Date
}

struct PayeeRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "payees"

    var id: String
    var name: String
    var lastUsedAt: Date?
    var updatedAt: Date
}

struct CategoryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "categories"

    var id: String
    var name: String
    var groupName: String?
    var isIncome: Bool
    var budgetedMinor: Int64
    var spentMinor: Int64
    var updatedAt: Date
}

struct TrackedCategoryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "tracked_categories"

    var categoryID: String
    var sortOrder: Int
}

struct TransactionRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "transactions"

    var id: UUID
    var remoteID: String?
    var amountMinor: Int64
    var payeeID: String?
    var payeeName: String
    var accountID: String
    var date: String
    var note: String
    var isSplit: Bool
    var categorySummary: String
    var categoryIDsJSON: String
    var updatedAt: Date
}

struct SplitLineRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "split_lines"

    var id: UUID
    var transactionID: UUID
    var categoryID: String
    var amountMinor: Int64
}

struct PendingMutationRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "pending_mutations"

    var id: UUID
    var type: String
    var payload: Data
    var state: String
    var retryCount: Int
    var createdAt: Date
    var nextAttemptAt: Date
    var lastError: String?
    var transactionLocalID: UUID?
}

struct AppConfigRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "app_config"

    var id: Int
    var baseURL: String
    var syncID: String
    var recentFilterMode: String
    var updatedAt: Date
}

extension CategoryRow {
    var status: CategoryBudgetStatus {
        CategoryBudgetStatus(
            id: id,
            name: name,
            groupName: groupName,
            budgetedMinor: budgetedMinor,
            spentMinor: spentMinor
        )
    }

    var domain: Category {
        Category(id: id, name: name, groupName: groupName, isIncome: isIncome)
    }
}

extension PayeeRow {
    var domain: Payee {
        Payee(id: id, name: name, lastUsedAt: lastUsedAt)
    }
}

extension AccountRow {
    var domain: Account {
        Account(id: id, name: name)
    }
}

extension PendingMutationRow {
    func toDomain() -> PendingMutation? {
        guard let type = PendingMutationType(rawValue: type),
              let state = PendingMutationState(rawValue: state) else {
            return nil
        }
        return PendingMutation(
            id: id,
            type: type,
            payload: payload,
            state: state,
            retryCount: retryCount,
            createdAt: createdAt,
            nextAttemptAt: nextAttemptAt,
            lastError: lastError,
            transactionLocalID: transactionLocalID
        )
    }
}

extension TransactionRow {
    var categoryIDs: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(categoryIDsJSON.utf8))) ?? []
    }

    var domain: RecentTransactionItem {
        RecentTransactionItem(
            id: id,
            remoteID: remoteID,
            amountMinor: amountMinor,
            payeeName: payeeName,
            payeeID: payeeID,
            accountID: accountID,
            date: LocalDate(date),
            note: note,
            categorySummary: categorySummary,
            isSplit: isSplit,
            categoryIDs: categoryIDs,
            updatedAt: updatedAt
        )
    }
}
