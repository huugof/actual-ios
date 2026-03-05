import SwiftUI
import UIKit

struct AddEditTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: AddEditTransactionViewModel
    @FocusState private var focusedField: Field?
    @State private var isAmountFocused = false
    @State private var didScheduleInitialAmountFocus = false
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
                scheduleInitialAmountFocusIfNeeded()
            }
            .onChange(of: viewModel.selectedAccountID, initial: false) { _, _ in viewModel.recomputeValidation() }
            .onChange(of: viewModel.note, initial: false) { _, _ in viewModel.recomputeValidation() }
            .onChange(of: viewModel.date.value, initial: false) { _, _ in viewModel.recomputeValidation() }
        }
    }

    private func scheduleInitialAmountFocusIfNeeded() {
        guard !didScheduleInitialAmountFocus else { return }
        didScheduleInitialAmountFocus = true
        let delays: [TimeInterval] = [0, 0.1, 0.3, 0.6]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if focusedField == nil && !isAmountFocused {
                    isAmountFocused = true
                }
            }
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amount")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ShiftedCurrencyTextField(text: Binding(
                get: { viewModel.amountText },
                set: { viewModel.updateAmount($0) }
            ), placeholder: "0.00", isFocused: $isAmountFocused)
            .frame(maxWidth: .infinity)
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
                    amountText: viewModel.splitAmountText(for: line.id),
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
            DatePicker("", selection: Binding(
                get: { viewModel.datePickerSelection },
                set: { viewModel.datePickerSelection = $0 }
            ), displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
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
    let amountText: String
    let trackedCategories: [Category]
    let otherCategories: [Category]
    let onCategorySelected: (Category) -> Void
    let onAmountChanged: (String) -> Void
    let onAutofill: () -> Void
    let onRemove: () -> Void

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
                ShiftedCurrencyTextField(text: Binding(
                    get: { amountText },
                    set: { onAmountChanged($0) }
                ), placeholder: "0.00")
                .frame(maxWidth: .infinity)

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

private struct ShiftedCurrencyTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: Binding<Bool>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.borderStyle = .roundedRect
        textField.keyboardType = .numberPad
        textField.placeholder = placeholder
        textField.text = text
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        if let isFocused {
            if isFocused.wrappedValue, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private var isFocused: Binding<Bool>?

        init(text: Binding<String>, isFocused: Binding<Bool>?) {
            self.text = text
            self.isFocused = isFocused
        }

        @objc func editingChanged(_ textField: UITextField) {
            let raw = textField.text ?? ""
            let digitsOnly = raw.filter(\.isNumber)
            let formatted = digitsOnly.isEmpty ? "" : MoneyFormatter.normalizeShiftedCurrencyInput(digitsOnly)
            if textField.text != formatted {
                textField.text = formatted
            }
            if text.wrappedValue != formatted {
                text.wrappedValue = formatted
            }
            moveCursorToEnd(textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFocused?.wrappedValue = true
            moveCursorToEnd(textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isFocused?.wrappedValue = false
        }

        private func moveCursorToEnd(_ textField: UITextField) {
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
    }
}
