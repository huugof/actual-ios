import SwiftUI

private enum BudgetListLayout {
    static let amountColumnWidth: CGFloat = 124
    static let accessoryColumnWidth: CGFloat = 14
    static let categoryInsetLeading: CGFloat = 10
}

struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    private let transactionService: TransactionService
    private let onOpenSettings: () -> Void

    @State private var isShowingAdd = false
    @State private var categoryDetailTarget: CategoryDetailTarget?
    @State private var categoryDetailTransactions: [RecentTransactionItem] = []
    @State private var isCategoryDetailLoading = false
    @State private var categoryEditingTarget: EditingTarget?
    @State private var pendingDeleteItem: RecentTransactionItem?
    @State private var isShowingDeleteConfirm = false
    @State private var isOtherBudgetsExpanded = false

    init(
        viewModel: HomeViewModel,
        transactionService: TransactionService,
        onOpenSettings: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.transactionService = transactionService
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 12) {
                        budgetSummaryCard
                        trackedBudgetsCard
                        if !viewModel.otherBudgetStatuses.isEmpty {
                            otherBudgetsCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .top) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Plan*d")
                            .font(.title3.weight(.bold))
                        Spacer()
                        if viewModel.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            onOpenSettings()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title3.weight(.regular))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear
                        .frame(height: 112)
                }
                .refreshable {
                    await viewModel.refreshInBackground()
                }

                Button {
                    isShowingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .bold))
                        .frame(width: 66, height: 66)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.gradient, in: Circle())
                        .shadow(radius: 8)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 6)
                .accessibilityLabel("Add Transaction")
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                viewModel.onAppear()
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let toast = viewModel.toast {
                        HStack(spacing: 12) {
                            Text(toast.message)
                                .font(.subheadline.weight(.semibold))
                            if let action = toast.action {
                                Button(toast.actionTitle, action: action)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                viewModel.clearToast()
                            }
                        }
                    }

                    if let warning = viewModel.syncWarningMessage {
                        Text(warning)
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.orange.opacity(0.92), in: Capsule())
                            .foregroundStyle(.white)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    viewModel.clearSyncWarning()
                                }
                            }
                    }
                }
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
            }
            .onChange(of: viewModel.errorMessage, initial: false) { _, newValue in
                if newValue != nil {
                    viewModel.clearSyncWarning()
                }
            }
            .sheet(isPresented: $isShowingAdd) {
                AddEditTransactionView(
                    viewModel: AddEditTransactionViewModel(mode: .add, service: transactionService),
                    onSaved: { localID, isNew in
                        viewModel.didSaveTransaction(localID: localID, isNew: isNew)
                    }
                )
            }
            .sheet(item: $categoryDetailTarget) { target in
                NavigationStack {
                    Group {
                        if isCategoryDetailLoading {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("Loading...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if categoryDetailTransactions.isEmpty {
                            VStack(spacing: 10) {
                                Text("No transactions this month")
                                    .font(.headline)
                                Text("No entries yet for \(target.name).")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(categoryDetailTransactions) { item in
                                RecentTransactionRow(item: item)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        categoryEditingTarget = EditingTarget(id: item.id)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDeleteItem = item
                                            isShowingDeleteConfirm = true
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            }
                            .listStyle(.plain)
                        }
                    }
                    .navigationTitle(target.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                categoryDetailTarget = nil
                            }
                        }
                    }
                    .sheet(item: $categoryEditingTarget) { target in
                        AddEditTransactionView(
                            viewModel: AddEditTransactionViewModel(mode: .edit(existingID: target.id), service: transactionService),
                            onSaved: { savedID, isNew in
                                viewModel.didSaveTransaction(localID: savedID, isNew: isNew)
                                guard let categoryID = categoryDetailTarget?.id else { return }
                                Task {
                                    do {
                                        categoryDetailTransactions = try await viewModel.loadCurrentMonthTransactions(categoryID: categoryID)
                                    } catch {
                                        viewModel.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .confirmationDialog("Delete transaction?", isPresented: $isShowingDeleteConfirm, titleVisibility: .visible) {
                Button("Cancel", role: .cancel) {
                    pendingDeleteItem = nil
                }
                Button("Delete", role: .destructive) {
                    guard let item = pendingDeleteItem else { return }
                    categoryDetailTransactions.removeAll { $0.id == item.id }
                    viewModel.delete(item)
                    pendingDeleteItem = nil
                }
            } message: {
                if let item = pendingDeleteItem {
                    Text("\(item.payeeName) • \(MoneyFormatter.display(minor: item.amountMinor))")
                } else {
                    Text("This cannot be undone.")
                }
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
        }
    }

    private var budgetSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(monthBudgetTitle)
                .font(.title3.weight(.semibold))

            Text(viewModel.overallBudget.isOverBudget
                 ? "\(MoneyFormatter.display(minor: abs(viewModel.overallBudget.remainingMinor))) over"
                 : "\(MoneyFormatter.display(minor: viewModel.overallBudget.remainingMinor)) left")
            .font(.system(size: 40, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.top, 22)

            Text("\(MoneyFormatter.display(minor: viewModel.overallBudget.spentMinor)) of \(MoneyFormatter.display(minor: viewModel.overallBudget.budgetedMinor)) spent")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            ProgressView(value: viewModel.overallBudget.progress)
                .tint(viewModel.overallBudget.isOverBudget ? .red : .green)
                .scaleEffect(x: 1, y: 1.45, anchor: .center)
                .padding(.top, 20)
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var trackedBudgetsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Tracked Budgets")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(MoneyFormatter.display(minor: trackedBudgetsTotalRemaining))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(trackedBudgetsTotalRemaining < 0 ? .red : .primary)
                    .frame(width: BudgetListLayout.amountColumnWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.clear)
                    .frame(width: BudgetListLayout.accessoryColumnWidth, alignment: .trailing)
            }
            .padding(.bottom, 8)

            if viewModel.trackedStatuses.isEmpty {
                Text("No tracked categories configured yet.")
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .padding(.top, 8)
            } else {
                ForEach(viewModel.trackedStatuses.indices, id: \.self) { index in
                    let status = viewModel.trackedStatuses[index]
                    if index > 0 {
                        Divider()
                    }
                    ExpenseCategoryRow(status: status) {
                        openCategoryDetail(status)
                    }
                    .padding(.leading, BudgetListLayout.categoryInsetLeading)
                    .padding(.vertical, 16)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var otherBudgetsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isOtherBudgetsExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Other Budgets")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text(MoneyFormatter.display(minor: otherBudgetsTotalRemaining))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(otherBudgetsTotalRemaining < 0 ? .red : .primary)
                        .frame(width: BudgetListLayout.amountColumnWidth, alignment: .trailing)
                    Image(systemName: isOtherBudgetsExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: BudgetListLayout.accessoryColumnWidth, alignment: .trailing)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isOtherBudgetsExpanded {
                Divider()
                    .padding(.bottom, 2)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedOtherBudgets) { group in
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                        ForEach(group.items) { status in
                            ExpenseCategoryRow(status: status) {
                                openCategoryDetail(status)
                            }
                            .padding(.leading, BudgetListLayout.categoryInsetLeading)
                            .padding(.vertical, 13)
                            if status.id != group.items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, isOtherBudgetsExpanded ? 14 : 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var monthBudgetTitle: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return "\(formatter.string(from: .now)) Budget"
    }

    private var otherBudgetsTotalRemaining: Int64 {
        viewModel.otherBudgetStatuses.reduce(0) { $0 + $1.remainingMinor }
    }

    private var groupedOtherBudgets: [OtherBudgetGroup] {
        let grouped = Dictionary(grouping: viewModel.otherBudgetStatuses) { status in
            Self.displayGroupName(status.groupName)
        }
        return grouped
            .map { key, value in
                OtherBudgetGroup(
                    name: key,
                    items: value.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var trackedBudgetsTotalRemaining: Int64 {
        viewModel.trackedStatuses.reduce(0) { $0 + $1.remainingMinor }
    }

    private static func displayGroupName(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return "Ungrouped" }
        if looksLikeIdentifier(value) {
            return "Ungrouped"
        }
        return value
    }

    private static func looksLikeIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil {
            return true
        }
        let lower = value.lowercased()
        let hasSpace = lower.contains(" ")
        if !hasSpace,
           lower.range(of: "^[a-f0-9]{16,}$", options: .regularExpression) != nil {
            return true
        }
        if !hasSpace,
           lower.range(of: "^[a-z0-9_-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        if !hasSpace {
            let letters = lower.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let digits = lower.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            if lower.count >= 10 && letters > 0 && digits > 0 {
                return true
            }
        }
        return false
    }

    private func openCategoryDetail(_ status: CategoryBudgetStatus) {
        categoryDetailTarget = CategoryDetailTarget(id: status.id, name: status.name)
        categoryDetailTransactions = []
        isCategoryDetailLoading = true
        categoryEditingTarget = nil

        Task {
            do {
                let transactions = try await viewModel.loadCurrentMonthTransactions(categoryID: status.id)
                guard categoryDetailTarget?.id == status.id else { return }
                categoryDetailTransactions = transactions
            } catch {
                guard categoryDetailTarget?.id == status.id else { return }
                viewModel.errorMessage = error.localizedDescription
            }
            if categoryDetailTarget?.id == status.id {
                isCategoryDetailLoading = false
            }
        }
    }
}

private struct EditingTarget: Identifiable {
    let id: UUID
}

private struct ExpenseCategoryRow: View {
    let status: CategoryBudgetStatus
    let onOpenDetail: () -> Void

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(alignment: .center, spacing: 10) {
                Text(status.name)
                    .font(.subheadline.weight(.regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
                Text(MoneyFormatter.display(minor: status.remainingMinor))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status.isOverBudget ? .red : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: BudgetListLayout.amountColumnWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: BudgetListLayout.accessoryColumnWidth, alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct CategoryDetailTarget: Identifiable {
    let id: String
    let name: String
}

private struct OtherBudgetGroup: Identifiable {
    let name: String
    let items: [CategoryBudgetStatus]

    var id: String { name }
}

private struct RecentTransactionRow: View {
    let item: RecentTransactionItem
    private static let rawDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(displayDateText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(item.payeeName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.categorySummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(MoneyFormatter.display(minor: item.amountMinor))
                .font(.body.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayDateText: String {
        guard let date = Self.rawDateFormatter.date(from: item.date.value) else {
            return item.date.value
        }
        return Self.displayDateFormatter.string(from: date)
    }
}
