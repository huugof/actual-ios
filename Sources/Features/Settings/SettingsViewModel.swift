import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var baseURL = ""
    @Published var syncID = ""
    @Published var apiKey = ""
    @Published var budgetEncryptionPassword = ""
    @Published var recentFilterMode: RecentFilterMode = .trackedOnly
    @Published var allCategories: [Category] = []
    @Published var selectedCategoryIDs: Set<String> = []
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var confirmationMessage: String?

    private let configurationStore: AppConfigurationStore
    private let homeService: HomeService

    init(configurationStore: AppConfigurationStore, homeService: HomeService) {
        self.configurationStore = configurationStore
        self.homeService = homeService
    }

    func onAppear() {
        Task {
            do {
                let state = try await configurationStore.loadViewModelState()
                baseURL = state.baseURL
                syncID = state.syncID
                apiKey = state.apiKey
                budgetEncryptionPassword = state.budgetEncryptionPassword
                recentFilterMode = state.recentFilterMode

                allCategories = try await homeService.fetchAllCategories()
                selectedCategoryIDs = Set(try await homeService.loadTrackedCategoryIDs())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleCategory(_ id: String) {
        if selectedCategoryIDs.contains(id) {
            selectedCategoryIDs.remove(id)
        } else {
            selectedCategoryIDs.insert(id)
        }
    }

    func save() {
        isSaving = true
        errorMessage = nil
        confirmationMessage = nil

        Task {
            defer { isSaving = false }
            do {
                try await configurationStore.save(
                    baseURL: baseURL,
                    syncID: syncID,
                    apiKey: apiKey,
                    encryptionPassword: budgetEncryptionPassword,
                    recentFilterMode: recentFilterMode
                )

                // Refresh lookups from server after credentials/config are saved.
                let outcome = try await homeService.refresh()
                allCategories = try await homeService.fetchAllCategories()

                // First save should allow connection details to persist even before tracked categories are selected.
                guard !allCategories.isEmpty else {
                    if let warning = outcome.warningMessage {
                        confirmationMessage = "Connection saved. \(warning)"
                    } else {
                        confirmationMessage = "Connection saved. Sync categories, then pick 5-8 tracked categories."
                    }
                    return
                }

                guard (5...8).contains(selectedCategoryIDs.count) else {
                    if let warning = outcome.warningMessage {
                        confirmationMessage = "Connection saved. \(warning)"
                    } else {
                        confirmationMessage = "Connection saved. Select 5-8 tracked categories, then save again."
                    }
                    return
                }

                let ordered = allCategories
                    .filter { selectedCategoryIDs.contains($0.id) }
                    .map(\.id)
                try await homeService.saveTrackedCategoryIDs(ordered)
                if let warning = outcome.warningMessage {
                    confirmationMessage = "Settings saved. \(warning)"
                } else {
                    confirmationMessage = "Settings saved"
                }
            } catch {
                if Self.isCancellation(error) {
                    return
                }
                errorMessage = error.localizedDescription
            }
        }
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
}
