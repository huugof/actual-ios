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
    @Published var errorMessage: String?

    private let configurationStore: AppConfigurationStore
    private let homeService: HomeService

    private var hasLoadedInitialState = false
    private var hasStartedLoading = false
    private var autoSaveTask: Task<Void, Never>?
    private var hasQueuedAutoSave = false
    private var lastSavedConfig: ConfigSnapshot?
    private var lastSavedTrackedCategoryIDs: [String] = []

    private struct ConnectionSnapshot: Equatable {
        let baseURL: String
        let syncID: String
        let apiKey: String
        let budgetEncryptionPassword: String
    }

    private struct ConfigSnapshot: Equatable {
        let baseURL: String
        let syncID: String
        let apiKey: String
        let budgetEncryptionPassword: String
        let recentFilterMode: RecentFilterMode

        var connection: ConnectionSnapshot {
            ConnectionSnapshot(
                baseURL: baseURL,
                syncID: syncID,
                apiKey: apiKey,
                budgetEncryptionPassword: budgetEncryptionPassword
            )
        }
    }

    init(configurationStore: AppConfigurationStore, homeService: HomeService) {
        self.configurationStore = configurationStore
        self.homeService = homeService
    }

    func onAppear() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true

        Task {
            do {
                let state = try await configurationStore.loadViewModelState()
                baseURL = state.baseURL
                syncID = state.syncID
                apiKey = state.apiKey
                budgetEncryptionPassword = state.budgetEncryptionPassword
                recentFilterMode = state.recentFilterMode

                allCategories = try await homeService.fetchAllCategories()
                let trackedCategoryIDs = try await homeService.loadTrackedCategoryIDs()
                selectedCategoryIDs = Set(trackedCategoryIDs)

                lastSavedConfig = currentConfigSnapshot()
                lastSavedTrackedCategoryIDs = trackedCategoryIDs
                hasLoadedInitialState = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleCategoryAndAutoSave(_ id: String) {
        if selectedCategoryIDs.contains(id) {
            selectedCategoryIDs.remove(id)
        } else {
            selectedCategoryIDs.insert(id)
        }
        enqueueAutoSave()
    }

    func triggerAutoSaveFromFieldBlur() {
        enqueueAutoSave()
    }

    func triggerAutoSaveFromControlChange() {
        enqueueAutoSave()
    }

    private func enqueueAutoSave() {
        guard hasLoadedInitialState else { return }
        hasQueuedAutoSave = true
        guard autoSaveTask == nil else { return }

        autoSaveTask = Task { @MainActor [weak self] in
            await self?.runAutoSaveLoop()
        }
    }

    private func runAutoSaveLoop() async {
        while hasQueuedAutoSave {
            hasQueuedAutoSave = false
            await persistPendingChangesIfNeeded()
        }
        autoSaveTask = nil
    }

    private func persistPendingChangesIfNeeded() async {
        let currentConfig = currentConfigSnapshot()
        let configChanged = currentConfig != lastSavedConfig
        let connectionChanged = currentConfig.connection != lastSavedConfig?.connection
        let currentTrackedCategoryIDs = orderedTrackedCategoryIDs()
        let trackedChanged = currentTrackedCategoryIDs != lastSavedTrackedCategoryIDs

        guard configChanged || trackedChanged else { return }
        errorMessage = nil

        do {
            if configChanged, canPersistConfig(currentConfig) {
                try await configurationStore.save(
                    baseURL: currentConfig.baseURL,
                    syncID: currentConfig.syncID,
                    apiKey: currentConfig.apiKey,
                    encryptionPassword: currentConfig.budgetEncryptionPassword,
                    recentFilterMode: currentConfig.recentFilterMode
                )
                lastSavedConfig = currentConfig

                if connectionChanged {
                    _ = try await homeService.refresh()
                    allCategories = try await homeService.fetchAllCategories()
                }
            }

            if !allCategories.isEmpty {
                let trackedCategoryIDsAfterRefresh = orderedTrackedCategoryIDs()
                if trackedCategoryIDsAfterRefresh != lastSavedTrackedCategoryIDs {
                    try await homeService.saveTrackedCategoryIDs(trackedCategoryIDsAfterRefresh)
                    lastSavedTrackedCategoryIDs = trackedCategoryIDsAfterRefresh
                }
            }
        } catch {
            if Self.isCancellation(error) {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func currentConfigSnapshot() -> ConfigSnapshot {
        ConfigSnapshot(
            baseURL: baseURL.components(separatedBy: .whitespacesAndNewlines).joined(),
            syncID: syncID.components(separatedBy: .whitespacesAndNewlines).joined(),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            budgetEncryptionPassword: budgetEncryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            recentFilterMode: recentFilterMode
        )
    }

    private func canPersistConfig(_ config: ConfigSnapshot) -> Bool {
        guard !config.syncID.isEmpty else { return false }
        guard !config.apiKey.isEmpty else { return false }
        guard let url = URL(string: config.baseURL), url.scheme?.lowercased() == "https" else {
            return false
        }
        return true
    }

    private func orderedTrackedCategoryIDs() -> [String] {
        allCategories
            .filter { selectedCategoryIDs.contains($0.id) }
            .map(\.id)
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
