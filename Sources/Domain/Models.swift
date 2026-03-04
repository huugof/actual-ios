import Foundation

struct LocalDate: Codable, Equatable, Hashable, Sendable, Comparable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    init(date: Date = .now, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        self.value = String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        lhs.value < rhs.value
    }
}

struct Account: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct Payee: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let lastUsedAt: Date?
}

struct Category: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let groupName: String?
    let isIncome: Bool
}

struct CategoryBudgetSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let budgetedMinor: Int64
    let spentMinor: Int64
}

struct CategoryBudgetStatus: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let groupName: String?
    let budgetedMinor: Int64
    let spentMinor: Int64

    init(
        id: String,
        name: String,
        groupName: String? = nil,
        budgetedMinor: Int64,
        spentMinor: Int64
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.budgetedMinor = budgetedMinor
        self.spentMinor = spentMinor
    }

    var remainingMinor: Int64 {
        budgetedMinor - spentMinor
    }

    var progress: Double {
        guard budgetedMinor > 0 else { return spentMinor > 0 ? 1 : 0 }
        return min(max(Double(spentMinor) / Double(budgetedMinor), 0), 1)
    }

    var isOverBudget: Bool {
        remainingMinor < 0
    }
}

struct BudgetSummary: Codable, Equatable, Sendable {
    let budgetedMinor: Int64
    let spentMinor: Int64

    var remainingMinor: Int64 {
        budgetedMinor - spentMinor
    }

    var progress: Double {
        guard budgetedMinor > 0 else { return spentMinor > 0 ? 1 : 0 }
        return min(max(Double(spentMinor) / Double(budgetedMinor), 0), 1)
    }

    var isOverBudget: Bool {
        remainingMinor < 0
    }

    static let zero = BudgetSummary(budgetedMinor: 0, spentMinor: 0)
}

struct TransactionSplit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var categoryID: String
    var amountMinor: Int64
}

enum TransactionCategoryMode: Codable, Equatable, Sendable {
    case single(categoryID: String)
    case split([TransactionSplit])
}

enum PayeeSelection: Codable, Equatable, Sendable {
    case existing(id: String)
    case new(name: String)

    var displayText: String {
        switch self {
        case .existing(let id):
            return id
        case .new(let name):
            return name
        }
    }
}

struct TransactionDraft: Codable, Equatable, Sendable {
    var localID: UUID?
    var remoteID: String?
    var amountMinor: Int64 = 0
    var payee: PayeeSelection?
    var accountID: String = ""
    var date: LocalDate = LocalDate()
    var note: String = ""
    var categoryMode: TransactionCategoryMode = .single(categoryID: "")

    var isAmountValid: Bool {
        amountMinor != 0
    }

    var isAccountValid: Bool {
        !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isPayeeValid: Bool {
        guard let payee else { return false }
        switch payee {
        case .existing:
            return true
        case .new(let name):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var splitTotalMinor: Int64 {
        switch categoryMode {
        case .single:
            return amountMinor
        case .split(let splits):
            return splits.reduce(0) { $0 + $1.amountMinor }
        }
    }

    var splitRemainderMinor: Int64 {
        amountMinor - splitTotalMinor
    }

    var isCategoryValid: Bool {
        switch categoryMode {
        case .single(let categoryID):
            return !categoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .split(let splits):
            guard (2...4).contains(splits.count) else { return false }
            let allCategorySelected = splits.allSatisfy { !$0.categoryID.isEmpty }
            let fullyAllocated = splits.reduce(0) { $0 + $1.amountMinor } == amountMinor
            return allCategorySelected && fullyAllocated
        }
    }

    var isValidToSave: Bool {
        isAmountValid && isPayeeValid && isAccountValid && isCategoryValid
    }
}

struct RecentTransactionItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let remoteID: String?
    var amountMinor: Int64
    var payeeName: String
    var payeeID: String?
    var accountID: String
    var date: LocalDate
    var note: String
    var categorySummary: String
    var isSplit: Bool
    var categoryIDs: [String]
    var updatedAt: Date
}

struct HomeSnapshot: Equatable, Sendable {
    var trackedStatuses: [CategoryBudgetStatus]
    var overallBudget: BudgetSummary
    var otherBudgetStatuses: [CategoryBudgetStatus]
    var recents: [RecentTransactionItem]
    var queuedMutationCount: Int
}

enum PendingMutationType: String, Codable, Sendable {
    case createTransaction
    case updateTransaction
    case deleteTransaction
    case createPayee
}

enum PendingMutationState: String, Codable, Sendable {
    case queued
    case syncing
    case failed
}

struct PendingMutation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let type: PendingMutationType
    let payload: Data
    var state: PendingMutationState
    var retryCount: Int
    var createdAt: Date
    var nextAttemptAt: Date
    var lastError: String?
    var transactionLocalID: UUID?
}

enum RecentFilterMode: String, Codable, CaseIterable, Sendable {
    case trackedOnly
    case all
}

struct TrackedCategoryConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sortOrder: Int
}

struct APIConfiguration: Codable, Equatable, Sendable {
    var baseURL: URL
    var syncID: String
    var apiKey: String
    var budgetEncryptionPassword: String?
}
