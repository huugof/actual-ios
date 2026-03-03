import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    private let onOpenHome: () -> Void

    init(viewModel: SettingsViewModel, onOpenHome: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onOpenHome = onOpenHome
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://budget.example.ts.net:8443", text: $viewModel.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Sync ID", text: $viewModel.syncID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $viewModel.apiKey)
                    SecureField("Budget Encryption Password (optional)", text: $viewModel.budgetEncryptionPassword)
                }

                Section("Home Recent Filter") {
                    Picker("Filter", selection: $viewModel.recentFilterMode) {
                        Text("Tracked only").tag(RecentFilterMode.trackedOnly)
                        Text("All").tag(RecentFilterMode.all)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tracked Categories (5-8)") {
                    if viewModel.allCategories.isEmpty {
                        Text("Save server settings first to load categories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Selected: \(viewModel.selectedCategoryIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.allCategories) { category in
                        Button {
                            viewModel.toggleCategory(category.id)
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

                Section {
                    Button("Save Settings") {
                        viewModel.save()
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onOpenHome()
                    } label: {
                        Image(systemName: "house")
                    }
                    .controlSize(.small)
                }
            }
            .onAppear {
                viewModel.onAppear()
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let confirmationMessage = viewModel.confirmationMessage {
                    Text(confirmationMessage)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.green.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 12)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                viewModel.confirmationMessage = nil
                            }
                        }
                }
            }
        }
    }
}
