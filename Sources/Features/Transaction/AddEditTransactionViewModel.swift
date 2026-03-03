import Foundation

@MainActor
final class AddEditTransactionViewModel: ObservableObject {
    enum Mode {
        case add
        case edit(existingID: UUID)

        var isNew: Bool {
            if case .add = self { return true }
            return false
        }
    }

    @Published var amountText = ""
    @Published var payeeText = ""
    @Published var selectedPayee: PayeeSelection?
    @Published var categoryText = ""
    @Published var selectedCategoryID = ""
    @Published var selectedAccountID = ""
    @Published var date = LocalDate()
    @Published var note = ""
    @Published var isSplitMode = false
    @Published var splitLines: [TransactionSplit] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var payeeSuggestions: [Payee] = []
    @Published private(set) var trackedQuickCategories: [Category] = []
    @Published private(set) var allCategories: [Category] = []
    @Published private(set) var categorySuggestions: [Category] = []
    @Published private(set) var splitCategoryTextByLineID: [UUID: String] = [:]
    @Published private(set) var splitCategorySuggestionsByLineID: [UUID: [Category]] = [:]
    @Published private(set) var canSave = false
    @Published var errorMessage: String?
    @Published var isSaving = false

    private let mode: Mode
    private let service: TransactionService
    private var existingRemoteID: String?

    var title: String {
        mode.isNew ? "Add Transaction" : "Edit Transaction"
    }

    var isNew: Bool {
        mode.isNew
    }

    var splitRemainingMinor: Int64 {
        let total = MoneyFormatter.parseToMinor(amountText) ?? 0
        let allocated = splitLines.reduce(0) { $0 + $1.amountMinor }
        return total - allocated
    }

    var nonTrackedCategories: [Category] {
        let trackedIDs = Set(trackedQuickCategories.map(\.id))
        return allCategories
            .filter { !trackedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init(mode: Mode, service: TransactionService) {
        self.mode = mode
        self.service = service
        if mode.isNew {
            splitLines = [
                TransactionSplit(id: UUID(), categoryID: "", amountMinor: 0),
                TransactionSplit(id: UUID(), categoryID: "", amountMinor: 0)
            ]
        }
    }

    func onAppear() {
        Task {
            do {
                accounts = try await service.fetchAccounts()
                trackedQuickCategories = try await service.fetchTrackedCategories()
                allCategories = try await service.searchCategories(query: "", trackedOnly: false)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if case .edit(let existingID) = mode {
                    try await preload(existingID: existingID)
                }
                if selectedAccountID.isEmpty {
                    selectedAccountID = accounts.first?.id ?? ""
                } else if !accounts.contains(where: { $0.id == selectedAccountID }) {
                    accounts.append(Account(id: selectedAccountID, name: "Unavailable account"))
                }
                seedSplitStateForCurrentLines()
                updateCanSave()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateAmount(_ value: String) {
        amountText = value
        updateCanSave()
    }

    func updatePayeeQuery(_ query: String) {
        payeeText = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            payeeSuggestions = []
            selectedPayee = nil
            updateCanSave()
            return
        }

        selectedPayee = .new(name: trimmed)
        Task {
            do {
                let suggestions = try await service.searchPayees(query: trimmed)
                guard payeeText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame else {
                    return
                }

                payeeSuggestions = suggestions
                if let topPrefixMatch = suggestions.first(where: {
                    $0.name.lowercased().hasPrefix(trimmed.lowercased())
                }) {
                    selectedPayee = .existing(id: topPrefixMatch.id)
                } else {
                    selectedPayee = .new(name: trimmed)
                }
                updateCanSave()
            } catch {
                guard payeeText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame else {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
        updateCanSave()
    }

    func selectPayee(_ payee: Payee) {
        selectedPayee = .existing(id: payee.id)
        payeeText = payee.name
        updateCanSave()
    }

    func updateCategoryQuery(_ query: String) {
        categoryText = query
        selectedCategoryID = ""
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            categorySuggestions = []
            updateCanSave()
            return
        }

        Task {
            do {
                categorySuggestions = try await service.searchCategories(query: trimmed, trackedOnly: false)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        updateCanSave()
    }

    func selectCategory(_ category: Category) {
        selectedCategoryID = category.id
        categoryText = category.name
        categorySuggestions = []
        updateCanSave()
    }

    func categoryDisplayName(for categoryID: String) -> String {
        guard !categoryID.isEmpty else { return "" }
        if let tracked = trackedQuickCategories.first(where: { $0.id == categoryID }) {
            return tracked.name
        }
        if let category = allCategories.first(where: { $0.id == categoryID }) {
            return category.name
        }
        if categoryID == selectedCategoryID, !categoryText.isEmpty {
            return categoryText
        }
        return categoryID
    }

    func toggleSplitMode(_ enabled: Bool) {
        isSplitMode = enabled
        if enabled, splitLines.isEmpty {
            splitLines = [
                TransactionSplit(id: UUID(), categoryID: "", amountMinor: 0),
                TransactionSplit(id: UUID(), categoryID: "", amountMinor: 0)
            ]
        }
        seedSplitStateForCurrentLines()
        updateCanSave()
    }

    func addSplitLine() {
        guard splitLines.count < 4 else { return }
        let line = TransactionSplit(id: UUID(), categoryID: "", amountMinor: 0)
        splitLines.append(line)
        splitCategoryTextByLineID[line.id] = ""
        splitCategorySuggestionsByLineID[line.id] = trackedQuickCategories
        updateCanSave()
    }

    func removeSplitLine(_ id: UUID) {
        guard splitLines.count > 2 else { return }
        splitLines.removeAll { $0.id == id }
        splitCategoryTextByLineID[id] = nil
        splitCategorySuggestionsByLineID[id] = nil
        updateCanSave()
    }

    private func updateSplitCategory(id: UUID, categoryID: String) {
        guard let index = splitLines.firstIndex(where: { $0.id == id }) else { return }
        splitLines[index].categoryID = categoryID
        updateCanSave()
    }

    func splitCategoryText(for lineID: UUID) -> String {
        splitCategoryTextByLineID[lineID] ?? ""
    }

    func splitSuggestions(for lineID: UUID) -> [Category] {
        let query = splitCategoryTextByLineID[lineID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            return trackedQuickCategories
        }
        return splitCategorySuggestionsByLineID[lineID] ?? []
    }

    func updateSplitCategoryQuery(lineID: UUID, query: String) {
        splitCategoryTextByLineID[lineID] = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            splitCategorySuggestionsByLineID[lineID] = trackedQuickCategories
            updateSplitCategory(id: lineID, categoryID: "")
            return
        }

        updateSplitCategory(id: lineID, categoryID: "")
        Task {
            do {
                splitCategorySuggestionsByLineID[lineID] = try await service.searchCategories(query: trimmed, trackedOnly: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectSplitCategory(lineID: UUID, category: Category) {
        splitCategoryTextByLineID[lineID] = category.name
        splitCategorySuggestionsByLineID[lineID] = []
        updateSplitCategory(id: lineID, categoryID: category.id)
    }

    func updateSplitAmount(id: UUID, amountText: String) {
        guard let index = splitLines.firstIndex(where: { $0.id == id }) else { return }
        splitLines[index].amountMinor = MoneyFormatter.parseToMinor(amountText) ?? 0
        updateCanSave()
    }

    func autoFillRemainder(targetID: UUID) {
        guard let total = MoneyFormatter.parseToMinor(amountText) else { return }
        guard let index = splitLines.firstIndex(where: { $0.id == targetID }) else { return }
        let allocatedWithoutTarget = splitLines.enumerated().reduce(Int64(0)) { acc, pair in
            let (idx, line) = pair
            return idx == index ? acc : acc + line.amountMinor
        }
        splitLines[index].amountMinor = total - allocatedWithoutTarget
        updateCanSave()
    }

    func save() async throws -> UUID {
        isSaving = true
        defer { isSaving = false }

        var draft = TransactionDraft()
        if case .edit(let id) = mode {
            draft.localID = id
            draft.remoteID = existingRemoteID
        }

        draft.amountMinor = MoneyFormatter.parseToMinor(amountText) ?? 0
        draft.payee = selectedPayee ?? .new(name: payeeText)
        draft.accountID = selectedAccountID
        draft.date = date
        draft.note = note
        if isSplitMode {
            draft.categoryMode = .split(splitLines)
        } else {
            draft.categoryMode = .single(categoryID: selectedCategoryID)
        }

        let localID = try await service.createOrUpdateTransaction(draft)
        return localID
    }

    func recomputeValidation() {
        updateCanSave()
    }

    private func preload(existingID: UUID) async throws {
        guard let draft = try await service.loadDraft(localID: existingID) else { return }
        existingRemoteID = draft.remoteID
        amountText = MoneyFormatter.display(minor: draft.amountMinor).replacingOccurrences(of: Locale.current.currencySymbol ?? "$", with: "")
        selectedPayee = draft.payee
        payeeText = switch draft.payee {
        case .existing(let id):
            (try await service.payeeName(id: id)) ?? id
        case .new(let name):
            name
        case .none:
            ""
        }
        selectedAccountID = draft.accountID
        date = draft.date
        note = draft.note

        switch draft.categoryMode {
        case .single(let categoryID):
            isSplitMode = false
            selectedCategoryID = categoryID
            categoryText = (try await service.categoryName(id: categoryID)) ?? ""
            categorySuggestions = []
        case .split(let splits):
            isSplitMode = true
            splitLines = splits
            splitCategoryTextByLineID = [:]
            splitCategorySuggestionsByLineID = [:]
            for split in splits {
                splitCategoryTextByLineID[split.id] = (try await service.categoryName(id: split.categoryID)) ?? split.categoryID
                splitCategorySuggestionsByLineID[split.id] = []
            }
        }
    }

    private func seedSplitStateForCurrentLines() {
        for line in splitLines {
            if splitCategoryTextByLineID[line.id] == nil {
                splitCategoryTextByLineID[line.id] = ""
            }
            if splitCategorySuggestionsByLineID[line.id] == nil {
                splitCategorySuggestionsByLineID[line.id] = trackedQuickCategories
            }
        }
    }

    private func updateCanSave() {
        let amount = MoneyFormatter.parseToMinor(amountText) ?? 0
        let payee = selectedPayee ?? .new(name: payeeText)
        let draft = TransactionDraft(
            localID: nil,
            remoteID: existingRemoteID,
            amountMinor: amount,
            payee: payee,
            accountID: selectedAccountID,
            date: date,
            note: note,
            categoryMode: isSplitMode ? .split(splitLines) : .single(categoryID: selectedCategoryID)
        )
        canSave = draft.isValidToSave
    }
}
