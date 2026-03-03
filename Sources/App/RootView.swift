import SwiftUI

struct RootView: View {
    @ObservedObject var container: AppContainer
    @State private var selectedTab: AppTab = .home

    var body: some View {
        Group {
            switch container.startupState {
            case .launching:
                loadingView
            case .failed(let message):
                startupErrorView(message: message)
            case .ready(let dependencies):
                contentView(dependencies: dependencies)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private func contentView(dependencies: AppContainer.Dependencies) -> some View {
        switch selectedTab {
        case .home:
            HomeView(
                viewModel: HomeViewModel(homeService: dependencies.homeService, transactionService: dependencies.transactionService),
                transactionService: dependencies.transactionService,
                onOpenSettings: { selectedTab = .settings }
            )
        case .settings:
            SettingsView(
                viewModel: SettingsViewModel(configurationStore: dependencies.configurationStore, homeService: dependencies.homeService),
                onOpenHome: { selectedTab = .home }
            )
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting Actual Companion...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func startupErrorView(message: String) -> some View {
        VStack(spacing: 14) {
            Text("Startup Error")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                container.retryStartup()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

private enum AppTab {
    case home
    case settings
}
