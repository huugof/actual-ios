import SwiftUI

struct AddEditTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddEditTransactionViewModel
    @FocusState private var focusedField: Field?
    private let onSaved: (UUID, Bool) -> Void

    enum Field {
        case amount
        case payee
        case category
    }

    init(viewModel: AddEditTransactionViewModel, onSaved: @escaping (UUID, Bool) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    amountField
                    payeeField
                    categoryField
                    if viewModel.isSplitMode {
                        splitEditor
                    }
                    accountPicker
                    dateField
                    noteField
                }
                .padding(16)
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                let localID = try await viewModel.save()
                                onSaved(localID, viewModel.isNew)
                                dismiss()
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(!viewModel.canSave || viewModel.isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 10)
                }
            }
            .onAppear {
                viewModel.onAppear()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focusedField = .amount
                }
            }
            .onChange(of: viewModel.selectedAccountID, initial: false) { _, _ in viewModel.recomputeValidation() }
            .onChange(of: viewModel.note, initial: false) { _, _ in viewModel.recomputeValidation() }
            .onChange(of: viewModel.date.value, initial: false) { _, _ in viewModel.recomputeValidation() }
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amount")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("0.00", text: Binding(
                get: { viewModel.amountText },
                set: { viewModel.updateAmount($0) }
            ))
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: .amount)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var payeeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payee")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)

                HStack(spacing: 0) {
                    Text(viewModel.payeeText)
                        .foregroundStyle(.clear)
                    Text(viewModel.payeeGhostSuffix)
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .allowsHitTesting(false)

                TextField("Type payee", text: Binding(
                    get: { viewModel.payeeText },
                    set: { viewModel.updatePayeeQuery($0) }
                ))
                .focused($focusedField, equals: .payee)
                .submitLabel(.done)
                .onSubmit {
                    viewModel.acceptTopPayeeSuggestion()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 42)
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Category")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.isSplitMode ? "Single" : "Split") {
                    viewModel.toggleSplitMode(!viewModel.isSplitMode)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !viewModel.isSplitMode {
                Menu {
                    if !viewModel.trackedQuickCategories.isEmpty {
                        Section("Tracked") {
                            ForEach(viewModel.trackedQuickCategories) { category in
                                Button {
                                    viewModel.selectCategory(category)
                                } label: {
                                    if viewModel.selectedCategoryID == category.id {
                                        Label(category.name, systemImage: "checkmark")
                                    } else {
                                        Text(category.name)
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.nonTrackedCategories.isEmpty {
                        Section("All Categories") {
                            ForEach(viewModel.nonTrackedCategories) { category in
                                Button {
                                    viewModel.selectCategory(category)
                                } label: {
                                    if viewModel.selectedCategoryID == category.id {
                                        Label(category.name, systemImage: "checkmark")
                                    } else {
                                        Text(category.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(viewModel.categoryDisplayName(for: viewModel.selectedCategoryID).isEmpty ? "Select category" : viewModel.categoryDisplayName(for: viewModel.selectedCategoryID))
                            .foregroundStyle(viewModel.selectedCategoryID.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var splitEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Split Allocation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Remaining")
                Spacer()
                Text(MoneyFormatter.display(minor: viewModel.splitRemainingMinor))
                    .fontWeight(.semibold)
                    .foregroundStyle(viewModel.splitRemainingMinor == 0 ? .green : .orange)
            }
            .font(.footnote)

            ForEach(viewModel.splitLines) { line in
                SplitLineEditor(
                    line: line,
                    selectedCategoryName: viewModel.categoryDisplayName(for: line.categoryID),
                    trackedCategories: viewModel.trackedQuickCategories,
                    otherCategories: viewModel.nonTrackedCategories,
                    onCategorySelected: { viewModel.selectSplitCategory(lineID: line.id, category: $0) },
                    onAmountChanged: { viewModel.updateSplitAmount(id: line.id, amountText: $0) },
                    onAutofill: { viewModel.autoFillRemainder(targetID: line.id) },
                    onRemove: { viewModel.removeSplitLine(line.id) }
                )
            }

            Button("Add split line") {
                viewModel.addSplitLine()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.splitLines.count >= 4)
        }
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Account", selection: $viewModel.selectedAccountID) {
                ForEach(viewModel.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Date")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("YYYY-MM-DD", text: Binding(
                get: { viewModel.date.value },
                set: { viewModel.date = LocalDate($0) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Optional", text: $viewModel.note)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct SplitLineEditor: View {
    let line: TransactionSplit
    let selectedCategoryName: String
    let trackedCategories: [Category]
    let otherCategories: [Category]
    let onCategorySelected: (Category) -> Void
    let onAmountChanged: (String) -> Void
    let onAutofill: () -> Void
    let onRemove: () -> Void

    @State private var amountInput = ""

    var body: some View {
        VStack(spacing: 8) {
            Menu {
                if !trackedCategories.isEmpty {
                    Section("Tracked") {
                        ForEach(trackedCategories) { category in
                            Button {
                                onCategorySelected(category)
                            } label: {
                                if line.categoryID == category.id {
                                    Label(category.name, systemImage: "checkmark")
                                } else {
                                    Text(category.name)
                                }
                            }
                        }
                    }
                }

                if !otherCategories.isEmpty {
                    Section("All Categories") {
                        ForEach(otherCategories) { category in
                            Button {
                                onCategorySelected(category)
                            } label: {
                                if line.categoryID == category.id {
                                    Label(category.name, systemImage: "checkmark")
                                } else {
                                    Text(category.name)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selectedCategoryName.isEmpty ? "Select category" : selectedCategoryName)
                        .foregroundStyle(selectedCategoryName.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                TextField("0.00", text: Binding(
                    get: { amountInput.isEmpty ? MoneyFormatter.display(minor: line.amountMinor).replacingOccurrences(of: Locale.current.currencySymbol ?? "$", with: "") : amountInput },
                    set: {
                        amountInput = $0
                        onAmountChanged($0)
                    }
                ))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)

                Button("Remainder", action: onAutofill)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
