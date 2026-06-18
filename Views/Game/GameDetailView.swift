import SwiftUI

// MARK: - Game Detail View

struct GameDetailView: View {
    @Bindable var gameManager: GameManager
    @State private var showGameSettings = false

    private var game: GameInfo { gameManager.currentGame }
    private var state: GameState { gameManager.currentState }
    private var type: GameType { gameManager.selectedGame }
    private var shouldShowGameHeader: Bool {
        guard let launcherContent = game.launcherContent else { return true }
        return launcherContent.backgroundURL == nil
            && launcherContent.backgroundVideoURL == nil
            && launcherContent.themeURL == nil
    }

    var body: some View {
        ZStack {
            backgroundLayer

            if shouldShowGameHeader {
                VStack(alignment: .leading) {
                    gameHeader
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .padding(.top, 16)
            }

            // Bottom bar
            VStack {
                Spacer()
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showGameSettings) {
            GameSettingsSheet(gameManager: gameManager, gameType: type)
        }
    }

    private var backgroundLayer: some View {
        GeometryReader { proxy in
            let globalFrame = proxy.frame(in: .global)
            ZStack {
                LinearGradient(
                    colors: type.gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let bgURL = game.launcherContent?.backgroundURL {
                    CachedAsyncImage(url: bgURL)
                        .transition(.opacity)
                }

                if let bgVideoURL = game.launcherContent?.backgroundVideoURL {
                    LoopingVideoBackground(url: bgVideoURL)
                        .transition(.opacity)
                }

                if let themeURL = game.launcherContent?.themeURL {
                    CachedAsyncImage(url: themeURL)
                        .transition(.opacity)
                }

                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 180)
                }
            }
            .frame(
                width: max(globalFrame.maxX, proxy.size.width),
                height: max(globalFrame.maxY, proxy.size.height)
            )
            .offset(x: -max(globalFrame.minX, 0), y: -max(globalFrame.minY, 0))
            .animation(.easeInOut(duration: 0.4), value: gameManager.selectedGame)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var gameHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(game.type.displayName)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(game.type.isDarkBackground ? .white : .black)
                .shadow(color: game.type.isDarkBackground ? .black.opacity(0.5) : .white.opacity(0.3), radius: 6, y: 2)

            if case .needsUpdate(let current, let latest) = state {
                HStack(spacing: 4) {
                    Text("v\(current)")
                        .strikethrough()
                        .foregroundStyle(game.type.isDarkBackground ? .white.opacity(0.4) : .black.opacity(0.4))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                    Text("v\(latest)")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            } else if let config = gameManager.settings.gameConfigs[type],
                      let version = config.installedVersion {
                Text("Version \(version)")
                    .font(.system(size: 13))
                    .foregroundStyle(game.type.isDarkBackground ? .white.opacity(0.7) : .black.opacity(0.6))
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if let progress = state.progress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.statusText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(type.accentColor)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()

            // Settings button
            if state == .ready || state == .notInstalled {
                Button {
                    showGameSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
            }

            // Locate existing game button
            if state == .notInstalled {
                Button {
                    Task { await gameManager.locateGame(type) }
                } label: {
                    Label("Locate Game", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlassButton(color: .white)
            }

            // Launch button
            launchButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .liquidGlassCard(cornerRadius: 18)
    }

    // MARK: - Launch Button

    private var launchButton: some View {
        Button {
            Task { await gameManager.performAction(for: type) }
        } label: {
            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(state.actionLabel, systemImage: launchButtonIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .liquidGlassButton(color: type.accentColor)
        .disabled(!state.isActionable)
        .opacity(state.isActionable ? 1.0 : 0.5)
    }

    private var launchButtonIcon: String {
        switch state {
        case .notInstalled: return "arrow.down.to.line"
        case .ready: return "play.fill"
        case .needsUpdate: return "arrow.up.circle.fill"
        case .running: return "stop.fill"
        case .error: return "arrow.clockwise"
        default: return "ellipsis"
        }
    }
}

// MARK: - Game Settings Sheet

struct GameSettingsSheet: View {
    @Bindable var gameManager: GameManager
    let gameType: GameType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header - always visible
            HStack {
                Text("\(gameType.displayName) Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.2))

            Divider()

            // Scrollable custom form content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsGroup("Installation") {
                        HStack {
                            Text("Install Directory")
                            Spacer()
                            Text(gameManager.settings.config(for: gameType).installDirectory ?? "Not set")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .trailing)
                        }
                        Button("Change Installer Directory...") {
                            Task {
                                if let url = await gameManager.selectInstallDirectory(for: gameType) {
                                    gameManager.settings.updateConfig(for: gameType) { config in
                                        config.installDirectory = url.path
                                    }
                                    gameManager.settings.save()
                                    await gameManager.checkAllGameStates()
                                }
                            }
                        }
                        
                        if gameManager.currentState == .ready {
                            Divider().opacity(0.5)
                            Button("Check Integrity") {
                                Task { await gameManager.checkIntegrity(for: gameType) }
                            }
                        }
                    }

                    settingsGroup("Wine") {
                        Toggle("Use Global Wine Settings", isOn: configBinding(\.useGlobalWineSettings))

                        if !gameManager.settings.config(for: gameType).useGlobalWineSettings {
                            Picker("Wine Source", selection: configBinding(\.wineSourceMode)) {
                                ForEach(WineSourceMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            
                            if gameManager.settings.config(for: gameType).wineSourceMode == .github {
                                Picker("Wine Version", selection: configBinding(\.wineDistribution)) {
                                    ForEach(WineManager.distributions) { distro in
                                        Text(distro.displayName).tag(distro.id)
                                    }
                                }
                            } else {
                                HStack {
                                    Text(gameManager.settings.config(for: gameType).customWinePath.isEmpty ? "No folder selected" : gameManager.settings.config(for: gameType).customWinePath)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Select...") {
                                        Task { @MainActor in
                                            let panel = NSOpenPanel()
                                            panel.title = "Select Wine Directory"
                                            panel.canChooseDirectories = true
                                            panel.canChooseFiles = false
                                            panel.canCreateDirectories = false
                                            if panel.runModal() == .OK, let url = panel.url {
                                                gameManager.settings.updateConfig(for: gameType) { config in
                                                    config.customWinePath = url.path
                                                }
                                                gameManager.settings.save()
                                            }
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }

                        Divider().opacity(0.5)

                        HStack {
                            Text("Current Status")
                            Spacer()
                            Text(gameManager.wineManager.status.displayName)
                                .foregroundStyle(gameManager.wineManager.status.isReady ? .green : .secondary)
                                .font(.caption.weight(.medium))
                        }
                        
                        HStack {
                            if !gameManager.wineManager.status.isReady {
                                Button("Download & Install Wine for this game") {
                                    Task {
                                        // Apply properly before install
                                        gameManager.applyWineSettings(for: gameType)
                                        let isGlobal = gameManager.settings.config(for: gameType).useGlobalWineSettings
                                        let mode = isGlobal ? gameManager.settings.wineSourceMode : gameManager.settings.config(for: gameType).wineSourceMode
                                        
                                        if mode == .github {
                                            let selected = isGlobal ? gameManager.settings.selectedWineDistribution : gameManager.settings.config(for: gameType).wineDistribution
                                            let distro = WineManager.distributions.first { $0.id == selected }
                                            await gameManager.installWine(distribution: distro)
                                        }
                                    }
                                }
                            } else {
                                @Bindable var gameManager = gameManager
                                RecreatePrefixButton(gameManager: gameManager, gameType: gameType)
                            }
                            
                            Spacer()
                            
                             Button("Re-check") {
                                gameManager.applyWineSettings(for: gameType)
                                _ = gameManager.wineManager.checkWineAvailability()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider().opacity(0.5)

                        Toggle("Retina Mode", isOn: configBinding(\.retinaMode))
                        Toggle("Left ⌘ as Ctrl", isOn: configBinding(\.leftCommandIsCtrl))
                    }

                    settingsGroup("Graphics") {
                        Toggle("Enable DXMT", isOn: configBinding(\.enableDXMT))
                        Toggle("Metal HUD", isOn: configBinding(\.metalHUD))
                        Toggle("Enable HDR", isOn: configBinding(\.enableHDR))
                        Toggle("Custom Resolution", isOn: configBinding(\.customResolution))
                        if gameManager.settings.config(for: gameType).customResolution {
                            HStack {
                                TextField("Width", value: configBinding(\.resolutionWidth), format: .number)
                                    .frame(width: 80)
                                Text("×")
                                TextField("Height", value: configBinding(\.resolutionHeight), format: .number)
                                    .frame(width: 80)
                            }
                        }
                    }

                    settingsGroup("Audio") {
                        Picker("Voice Language", selection: configBinding(\.voiceLanguage)) {
                            ForEach(GameConfig.VoiceLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                    }

                    settingsGroup("Network") {
                        Toggle("Enable Proxy", isOn: configBinding(\.proxyEnabled))
                        if gameManager.settings.config(for: gameType).proxyEnabled {
                            TextField("Proxy Host", text: configBinding(\.proxyHost))
                        }
                        
                        Divider().opacity(0.3)
                        
                        Toggle("Run FireflyPS (Local Proxy Helper)", isOn: Binding(
                            get: { gameManager.settings.config(for: gameType).useFireflyPS },
                            set: { newValue in
                                gameManager.settings.updateConfig(for: gameType) { config in
                                    config.useFireflyPS = newValue
                                    if newValue {
                                        config.usePrivateServer = false
                                    }
                                }
                                gameManager.settings.save()
                            }
                        ))
                        
                        Toggle("Play on Private Server (Direct Connection)", isOn: configBinding(\.usePrivateServer))
                            .disabled(gameManager.settings.config(for: gameType).useFireflyPS)
                            .opacity(gameManager.settings.config(for: gameType).useFireflyPS ? 0.5 : 1.0)
                        
                        if gameManager.settings.config(for: gameType).useFireflyPS {
                            TextField("Private Server Address", text: .constant("127.0.0.1:21000"))
                                .disabled(true)
                                .foregroundStyle(.secondary)
                        } else if gameManager.settings.config(for: gameType).usePrivateServer {
                            TextField("Private Server Address", text: configBinding(\.privateServerAddress))
                        }
                        
                        if gameManager.settings.config(for: gameType).useFireflyPS {
                            TextField("Accept Run Code", text: configBinding(\.privateServerAcceptRun))
                            
                            HStack {
                                Button {
                                    let path = gameManager.proxyDirectoryPath
                                    // Ensure directory exists so Finder can open it
                                    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                
                                Button {
                                    Task {
                                        do {
                                            try await gameManager.downloadProxyArchive()
                                        } catch {
                                            print("Failed to download proxy: \(error)")
                                        }
                                    }
                                } label: {
                                    Label("Download/Update Proxy", systemImage: "arrow.down.circle")
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }
                            
                            Text("Note: The proxy server is downloaded and run automatically on game launch. Click 'Show in Finder' to reveal the folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Divider().opacity(0.3)
                        
                        Toggle("Block Network (Anti-Cheat)", isOn: configBinding(\.blockNetwork))
                    }

                    settingsGroup("Advanced") {
                        Toggle("WINEMSYNC", isOn: configBinding(\.winemsync))
                        Toggle("Timeout Fix", isOn: configBinding(\.timeoutFix))
                        Toggle("Steam Emulation", isOn: configBinding(\.useSteamPatch))
                        Toggle("ReShade", isOn: configBinding(\.enableReShade))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 600)
        .liquidGlassCard(cornerRadius: 16)
        .presentationBackground(.clear)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // removed wineDistributionBinding

    private func configBinding<T>(_ keyPath: WritableKeyPath<GameConfig, T>) -> Binding<T> {
        Binding(
            get: { gameManager.settings.config(for: gameType)[keyPath: keyPath] },
            set: { newValue in
                gameManager.settings.updateConfig(for: gameType) { config in
                    config[keyPath: keyPath] = newValue
                }
                gameManager.settings.save()
            }
        )
    }
}

// MARK: - Recreate Prefix Button

struct RecreatePrefixButton: View {
    let gameManager: GameManager
    let gameType: GameType
    
    @State private var isRecreating = false
    
    var body: some View {
        Button {
            isRecreating = true
            Task {
                gameManager.applyWineSettings(for: gameType)
                try? await gameManager.wineManager.recreateWinePrefix()
                await MainActor.run {
                    isRecreating = false
                }
            }
        } label: {
            if isRecreating {
                ProgressView().controlSize(.small)
            } else {
                Text("Recreate Wine Prefix")
            }
        }
        .disabled(isRecreating)
    }
}
