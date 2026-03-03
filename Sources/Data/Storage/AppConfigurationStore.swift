import Foundation

actor AppConfigurationStore {
    private let database: DatabaseService
    private let keychain: KeychainStore

    init(database: DatabaseService, keychain: KeychainStore) {
        self.database = database
        self.keychain = keychain
    }

    func save(
        baseURL: String,
        syncID: String,
        apiKey: String,
        encryptionPassword: String?,
        recentFilterMode: RecentFilterMode
    ) async throws {
        let sanitizedURL = baseURL.components(separatedBy: .whitespacesAndNewlines).joined()
        let sanitizedSyncID = syncID.components(separatedBy: .whitespacesAndNewlines).joined()
        let sanitizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedEncryptionPassword = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: sanitizedURL), url.scheme?.lowercased() == "https" else {
            throw NSError(domain: "AppConfigurationStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Base URL must be a valid HTTPS URL"])
        }
        guard !sanitizedSyncID.isEmpty else {
            throw NSError(domain: "AppConfigurationStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sync ID is required"])
        }
        guard !sanitizedAPIKey.isEmpty else {
            throw NSError(domain: "AppConfigurationStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "API key is required"])
        }

        try keychain.set(sanitizedAPIKey, for: .apiKey)
        if let sanitizedEncryptionPassword, !sanitizedEncryptionPassword.isEmpty {
            try keychain.set(sanitizedEncryptionPassword, for: .encryptionPassword)
        }

        try await database.saveConfig(baseURL: sanitizedURL, syncID: sanitizedSyncID, filterMode: recentFilterMode)
    }

    func loadAPIConfiguration() async throws -> APIConfiguration? {
        guard let row = try await database.loadConfig() else {
            return nil
        }
        guard let url = URL(string: row.baseURL),
              let apiKey = keychain.get(.apiKey),
              !row.syncID.isEmpty,
              !apiKey.isEmpty else {
            return nil
        }

        return APIConfiguration(
            baseURL: url,
            syncID: row.syncID,
            apiKey: apiKey,
            budgetEncryptionPassword: keychain.get(.encryptionPassword)
        )
    }

    func loadViewModelState() async throws -> SettingsFormState {
        let row = try await database.loadConfig()
        return SettingsFormState(
            baseURL: row?.baseURL ?? "",
            syncID: row?.syncID ?? "",
            apiKey: keychain.get(.apiKey) ?? "",
            budgetEncryptionPassword: keychain.get(.encryptionPassword) ?? "",
            recentFilterMode: row?.filterMode ?? .trackedOnly
        )
    }
}

struct SettingsFormState: Equatable, Sendable {
    var baseURL: String
    var syncID: String
    var apiKey: String
    var budgetEncryptionPassword: String
    var recentFilterMode: RecentFilterMode
}
