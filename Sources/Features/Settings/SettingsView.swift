import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @FocusState private var focusedField: Field?

    init(viewModel: SettingsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private enum Field: Hashable {
        case baseURL
        case syncID
        case apiKey
        case budgetEncryptionPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://budget.example.ts.net:8443", text: $viewModel.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .baseURL)
                    TextField("Sync ID", text: $viewModel.syncID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .syncID)
                    SecureField("API Key", text: $viewModel.apiKey)
                        .focused($focusedField, equals: .apiKey)
                    SecureField("Budget Encryption Password (optional)", text: $viewModel.budgetEncryptionPassword)
                        .focused($focusedField, equals: .budgetEncryptionPassword)
                }

                Section("Home Recent Filter") {
                    Picker("Filter", selection: $viewModel.recentFilterMode) {
                        Text("Tracked only").tag(RecentFilterMode.trackedOnly)
                        Text("All").tag(RecentFilterMode.all)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.recentFilterMode, initial: false) { _, _ in
                        viewModel.triggerAutoSaveFromControlChange()
                    }
                }

                Section("Tracked Categories") {
                    if viewModel.allCategories.isEmpty {
                        Text("Enter server settings to load categories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Selected: \(viewModel.selectedCategoryIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.allCategories) { category in
                        Button {
                            viewModel.toggleCategoryAndAutoSave(category.id)
                        } label: {
                            HStack {
                                Text(category.name)
                                Spacer()
                                if viewModel.selectedCategoryIDs.contains(category.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: focusedField, initial: false) { oldValue, newValue in
                if oldValue != nil, oldValue != newValue {
                    viewModel.triggerAutoSaveFromFieldBlur()
                }
            }
            .onAppear {
                viewModel.onAppear()
            }
            .onDisappear {
                viewModel.triggerAutoSaveFromFieldBlur()
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}
