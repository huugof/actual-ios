import Foundation
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var trackedStatuses: [CategoryBudgetStatus] = []
    @Published private(set) var overallBudget: BudgetSummary = .zero
    @Published private(set) var otherBudgetStatuses: [CategoryBudgetStatus] = []
    @Published private(set) var recents: [RecentTransactionItem] = []
    @Published private(set) var queuedCount: Int = 0
    @Published var isLoading = false
    @Published var isSyncing = false
    @Published private(set) var syncStatusText: String = "Up to date"
    @Published private(set) var syncStatusIcon: String = "checkmark.circle"
    @Published private(set) var syncStatusIsActive: Bool = false
    @Published var errorMessage: String?
    @Published var syncWarningMessage: String?
    @Published var toast: UndoToast?

    private let homeService: HomeService
    private let transactionService: TransactionService
    private var isMutationSyncInFlight = false
    private var pendingMutationSyncRequest = false
    private var pullSyncTask: Task<Void, Never>?
    private var retryMutationTask: Task<Void, Never>?

    init(homeService: HomeService, transactionService: TransactionService) {
        self.homeService = homeService
        self.transactionService = transactionService
    }

    func onAppear() {
        Task {
            await loadSnapshot()
            await refreshInBackground()
        }
    }

    func loadSnapshot() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await homeService.loadSnapshot()
            trackedStatuses = snapshot.trackedStatuses
            overallBudget = snapshot.overallBudget
            otherBudgetStatuses = snapshot.otherBudgetStatuses
            recents = snapshot.recents
            queuedCount = snapshot.queuedMutationCount
            if !isSyncing {
                updateIdleStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshInBackground() async {
        pullSyncTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPullSync()
        }
        pullSyncTask = task
        await task.value
        pullSyncTask = nil
    }

    func loadCurrentMonthTransactions(categoryID: String) async throws -> [RecentTransactionItem] {
        try await homeService.loadCurrentMonthTransactions(categoryID: categoryID)
    }

    func didSaveTransaction(localID: UUID, isNew: Bool) {
        Task {
            await loadSnapshot()
            if isNew {
                toast = UndoToast(message: "Transaction saved", actionTitle: "Undo", action: { [weak self] in
                    Task { await self?.undoCreated(localID: localID) }
                })
            } else {
                toast = UndoToast(message: "Transaction updated", actionTitle: "Undo", action: { [weak self] in
                    Task { await self?.loadSnapshot() }
                })
            }
            scheduleMutationSync()
        }
    }

    func delete(_ item: RecentTransactionItem) {
        Task {
            do {
                try await homeService.deleteTransaction(item)
                await loadSnapshot()
                toast = UndoToast(message: "Transaction deleted", actionTitle: "Undo", action: { [weak self] in
                    Task { await self?.restoreDeleted(item) }
                })
                scheduleMutationSync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearToast() {
        toast = nil
    }

    func clearSyncWarning() {
        syncWarningMessage = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let apiError = error as? APIClientError {
            if case .requestCancelled = apiError {
                return true
            }
        }
        return false
    }

    private func undoCreated(localID: UUID) async {
        do {
            if let draft = try await transactionService.loadDraft(localID: localID) {
                let payeeID: String?
                if case .existing(let id) = draft.payee {
                    payeeID = id
                } else {
                    payeeID = nil
                }

                let payeeName: String
                if let payeeID {
                    payeeName = (try await transactionService.payeeName(id: payeeID)) ?? payeeID
                } else if case .new(let name) = draft.payee {
                    payeeName = name
                } else {
                    payeeName = "Unknown"
                }

                let item = RecentTransactionItem(
                    id: draft.localID ?? UUID(),
                    remoteID: draft.remoteID,
                    amountMinor: draft.amountMinor,
                    payeeName: payeeName,
                    payeeID: payeeID,
                    accountID: draft.accountID,
                    date: draft.date,
                    note: draft.note,
                    categorySummary: "",
                    isSplit: {
                        if case .split = draft.categoryMode { return true }
                        return false
                    }(),
                    categoryIDs: {
                        switch draft.categoryMode {
                        case .single(let categoryID): return [categoryID]
                        case .split(let splits): return splits.map(\.categoryID)
                        }
                    }(),
                    updatedAt: .now
                )
                try await homeService.deleteTransaction(item)
                scheduleMutationSync()
            }
            await loadSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreDeleted(_ item: RecentTransactionItem) async {
        var draft = TransactionDraft()
        draft.localID = UUID()
        draft.amountMinor = item.amountMinor
        draft.payee = item.payeeID.map { .existing(id: $0) } ?? .new(name: item.payeeName)
        draft.accountID = item.accountID
        draft.date = item.date
        draft.note = item.note
        if item.isSplit {
            let firstCategory = item.categoryIDs.first ?? ""
            let splits = item.categoryIDs.prefix(2).map { TransactionSplit(id: UUID(), categoryID: $0, amountMinor: item.amountMinor / 2) }
            draft.categoryMode = splits.count >= 2 ? .split(Array(splits)) : .single(categoryID: firstCategory)
        } else {
            draft.categoryMode = .single(categoryID: item.categoryIDs.first ?? "")
        }

        do {
            _ = try await transactionService.createOrUpdateTransaction(draft)
            await loadSnapshot()
            scheduleMutationSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleMutationSync() {
        pullSyncTask?.cancel()
        pullSyncTask = nil
        retryMutationTask?.cancel()
        retryMutationTask = nil

        if isMutationSyncInFlight {
            pendingMutationSyncRequest = true
            return
        }

        isMutationSyncInFlight = true
        Task {
            repeat {
                pendingMutationSyncRequest = false
                await runMutationSync()
            } while pendingMutationSyncRequest
            isMutationSyncInFlight = false
        }
    }

    private func runMutationSync() async {
        isSyncing = true
        setSyncStatus(
            text: "Pushing • \(max(queuedCount, 1))",
            icon: "arrow.up.circle.fill",
            active: true
        )
        defer { isSyncing = false }

        do {
            let outcome = try await homeService.refreshAfterMutation()
            syncWarningMessage = outcome.warningMessage
        } catch {
            if Self.isCancellation(error) {
                return
            }
            syncWarningMessage = "Saved locally. Sync pending."
        }
        await loadSnapshot()
        await scheduleRetryIfNeeded()
    }

    private func runPullSync() async {
        isSyncing = true
        setSyncStatus(
            text: "Pulling • \(queuedCount)",
            icon: "arrow.down.circle.fill",
            active: true
        )
        defer { isSyncing = false }

        do {
            let outcome = try await homeService.refreshFull()
            syncWarningMessage = outcome.warningMessage
        } catch {
            if Self.isCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
            syncWarningMessage = nil
        }
        await loadSnapshot()
        await scheduleRetryIfNeeded()
    }

    private func scheduleRetryIfNeeded() async {
        retryMutationTask?.cancel()
        retryMutationTask = nil

        do {
            let state = try await homeService.pendingSyncState()
            queuedCount = state.pendingCount

            guard state.pendingCount > 0 else {
                updateIdleStatus()
                return
            }

            guard let nextAttemptAt = state.nextAttemptAt else {
                setSyncStatus(
                    text: "Queued • \(state.pendingCount)",
                    icon: "tray.and.arrow.up.fill",
                    active: true
                )
                return
            }

            var remaining = max(0, Int(ceil(nextAttemptAt.timeIntervalSinceNow)))
            if remaining == 0 {
                pendingMutationSyncRequest = true
                scheduleMutationSync()
                return
            }

            setSyncStatus(
                text: "Retry in \(remaining)s • \(state.pendingCount)",
                icon: "clock.arrow.circlepath",
                active: true
            )

            retryMutationTask = Task { [weak self] in
                guard let self else { return }
                while remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled {
                        return
                    }
                    remaining -= 1
                    await MainActor.run {
                        self.setSyncStatus(
                            text: "Retry in \(remaining)s • \(state.pendingCount)",
                            icon: "clock.arrow.circlepath",
                            active: true
                        )
                    }
                }
                await MainActor.run {
                    self.pendingMutationSyncRequest = true
                    self.scheduleMutationSync()
                }
            }
        } catch {
            setSyncStatus(
                text: "Sync status unavailable",
                icon: "exclamationmark.triangle.fill",
                active: true
            )
        }
    }

    private func updateIdleStatus() {
        if queuedCount > 0 {
            setSyncStatus(
                text: "Queued • \(queuedCount)",
                icon: "tray.and.arrow.up.fill",
                active: true
            )
        } else {
            setSyncStatus(
                text: "Up to date",
                icon: "checkmark.circle",
                active: false
            )
        }
    }

    private func setSyncStatus(text: String, icon: String, active: Bool) {
        syncStatusText = text
        syncStatusIcon = icon
        syncStatusIsActive = active
    }
}

struct UndoToast {
    let message: String
    let actionTitle: String
    let action: (() -> Void)?
}
