import Foundation

private enum AppStartupResult: Sendable {
    case success(AppContainer.Dependencies)
    case failure(String)
}

@MainActor
final class AppContainer: ObservableObject {
    struct Dependencies: Sendable {
        let database: DatabaseService
        let keychain: KeychainStore
        let configurationStore: AppConfigurationStore
        let apiClient: ActualHTTPAPIClient
        let syncEngine: SyncEngine
        let transactionService: TransactionService
        let homeService: HomeService
    }

    enum StartupState {
        case launching
        case ready(Dependencies)
        case failed(message: String)
    }

    @Published private(set) var startupState: StartupState = .launching

    init() {
        start()
    }

    func retryStartup() {
        startupState = .launching
        start()
    }

    private func start() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return AppStartupResult.success(try Self.buildDependencies())
                } catch {
                    return AppStartupResult.failure("Failed to initialize app dependencies: \(error.localizedDescription)")
                }
            }.value

            switch result {
            case .success(let dependencies):
                startupState = .ready(dependencies)
            case .failure(let message):
                startupState = .failed(message: message)
            }
        }
    }

    nonisolated private static func buildDependencies() throws -> Dependencies {
        let path = try AppPaths.databasePath()
        let database = try DatabaseService(path: path)
        let keychain = KeychainStore()
        let configurationStore = AppConfigurationStore(database: database, keychain: keychain)
        let apiClient = ActualHTTPAPIClient(configProvider: {
            try await configurationStore.loadAPIConfiguration()
        })
        let transactionService = TransactionService(database: database)
        let syncEngine = SyncEngine(database: database, api: apiClient)
        let homeService = HomeService(database: database, syncEngine: syncEngine, transactionService: transactionService)

        return Dependencies(
            database: database,
            keychain: keychain,
            configurationStore: configurationStore,
            apiClient: apiClient,
            syncEngine: syncEngine,
            transactionService: transactionService,
            homeService: homeService
        )
    }
}
