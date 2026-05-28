import SwiftUI

// MARK: - Main View

struct MainView: View {
    @State private var gameManager = GameManager()
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var gameManager = gameManager
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Kafka")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .overlay(alignment: .topTrailing) {
                                    if AppUpdater.shared.updateAvailable {
                                        Circle()
                                            .fill(.orange)
                                            .frame(width: 7, height: 7)
                                            .offset(x: 3, y: -3)
                                            .shadow(color: .orange.opacity(0.6), radius: 2)
                                    }
                                }
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            GameDetailView(gameManager: gameManager)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(gameManager: gameManager)
        }
        .alert("Error", isPresented: $gameManager.showErrorAlert) {
            Button("OK", role: .cancel) {
                gameManager.errorMessage = nil
            }
        } message: {
            Text(gameManager.errorMessage ?? "An unknown error occurred.")
        }
        .alert("New Version Available", isPresented: Bindable(AppUpdater.shared).showUpdatePrompt) {
            Button("Update Now") {
                Task {
                    await AppUpdater.shared.installUpdate()
                }
            }
            Button("Later", role: .cancel) {
                AppUpdater.shared.showUpdatePrompt = false
            }
        } message: {
            Text("Version \(AppUpdater.shared.latestVersion ?? "") is available. Would you like to update now?")
        }
        .overlay {
            if AppUpdater.shared.isDownloading {
                VStack(spacing: 16) {
                    Text("Updating Kafka Launcher...")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    ProgressView(value: AppUpdater.shared.updateProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(width: 250)
                    
                    Text(AppUpdater.shared.updateStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.3))
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $gameManager.selectedGame) {
            Section("Games") {
                ForEach(GameType.allCases) { type in
                    GameSidebarRow(
                        type: type,
                        state: gameManager.gameStates[type] ?? .notInstalled
                    )
                    .tag(type)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text("Wine/GPTK Ready")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sidebar Row

struct GameSidebarRow: View {
    let type: GameType
    let state: GameState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName)
                    .lineLimit(1)

                stateLabel
            }
        } icon: {
            Image(systemName: type.iconSystemName)
                .foregroundStyle(type.accentColor)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .ready:
            Text("Ready")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .notInstalled:
            Text("Not Installed")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .needsUpdate:
            Text("Update Available")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .installing(let p, _), .updating(let p, _):
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .tint(type.accentColor)
                .frame(maxWidth: 70)
        case .running:
            Text("Running")
                .font(.system(size: 10))
                .foregroundStyle(type.accentColor)
        case .error:
            Text("Error")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        default:
            Text("...")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MainView()
}
