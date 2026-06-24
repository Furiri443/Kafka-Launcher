import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var gameManager: GameManager
    @Environment(\.dismiss) private var dismiss

    @State private var isInstallingWine = false
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header
            HStack {
                Text("Kafka Launcher Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.2))

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // General
                    settingsGroup("General") {
                        HStack {
                            Text("Download Directory")
                            Spacer()
                            Text(gameManager.settings.defaultDownloadDirectory)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .trailing)
                            Button("Change…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    gameManager.settings.defaultDownloadDirectory = url.path
                                    gameManager.settings.save()
                                }
                            }
                            .controlSize(.small)
                        }
                        
                        Divider().opacity(0.5)
                        
                        Toggle(isOn: Binding(
                            get: { gameManager.settings.runOldVersion },
                            set: { newValue in
                                gameManager.settings.runOldVersion = newValue
                                gameManager.settings.save()
                                Task {
                                    await gameManager.checkAllGameStates()
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Allow Running Old Game Versions")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Bypass automatic update checks and launch the game directly.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Wine / GPTK
                    WineSettingsSection(gameManager: gameManager,
                                       isInstallingWine: $isInstallingWine,
                                       installError: $installError)

                    // Games
                    settingsGroup("Games") {
                        ForEach(GameType.allCases) { type in
                            HStack {
                                Label(type.displayName, systemImage: type.iconSystemName)
                                    .foregroundStyle(type.accentColor)
                                Spacer()
                                let config = gameManager.settings.config(for: type)
                                if let dir = config.installDirectory {
                                    Text(dir)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 160, alignment: .trailing)
                                } else {
                                    Text("Not installed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if type != GameType.allCases.last {
                                Divider()
                            }
                        }
                    }

                    // About
                    settingsGroup("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(AppUpdater.shared.currentVersion)
                                .foregroundStyle(.secondary)
                        }
                        
                        Divider().opacity(0.4)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button {
                                    Task {
                                        _ = await AppUpdater.shared.checkForUpdates()
                                    }
                                } label: {
                                    if AppUpdater.shared.isChecking {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("Checking…")
                                        }
                                    } else {
                                        Text("Check for Updates")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(AppUpdater.shared.isChecking || AppUpdater.shared.isDownloading)
                                
                                Spacer()
                                
                                Text(AppUpdater.shared.updateStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            if AppUpdater.shared.updateAvailable, let latest = AppUpdater.shared.latestVersion {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let notes = AppUpdater.shared.releaseNotes, !notes.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("What's New in v\(latest):")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            ScrollView {
                                                Text(notes)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .padding(8)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .frame(maxHeight: 120)
                                            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                    
                                    if AppUpdater.shared.isDownloading {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ProgressView(value: AppUpdater.shared.updateProgress)
                                                .progressViewStyle(.linear)
                                                .tint(.accentColor)
                                        }
                                    } else {
                                        Button {
                                            Task {
                                                await AppUpdater.shared.installUpdate()
                                            }
                                        } label: {
                                            Label("Install Update", systemImage: "arrow.down.and.line.horizontal.and.arrow.up")
                                                .font(.callout.weight(.medium))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.top, 6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.easeInOut, value: AppUpdater.shared.updateAvailable)
                        .animation(.easeInOut, value: AppUpdater.shared.isDownloading)
                        
                        Divider().opacity(0.4)
                        
                        Text("A unified game launcher for macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 520)
        .liquidGlassCard(cornerRadius: 16)
        .presentationBackground(.clear)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Wine Settings Section

private struct WineSettingsSection: View {
    @Bindable var gameManager: GameManager
    @Binding var isInstallingWine: Bool
    @Binding var installError: String?

    @State private var customPathValid: Bool? = nil  // nil = unchecked

    private var wineStatus: WineStatus { gameManager.wineManager.status }
    private var installProgress: WineInstallProgress? { gameManager.wineManager.installProgress }

    @State private var isRecreatingPrefix = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wine / Game Porting Toolkit")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {

                // ── Status badge row ──
                WineStatusBadge(status: wineStatus)

                Divider().opacity(0.4)

                // ── Mode picker ──
                HStack(spacing: 0) {
                    ForEach(WineSourceMode.allCases, id: \.self) { mode in
                        let selected = gameManager.settings.wineSourceMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                gameManager.settings.wineSourceMode = mode
                                gameManager.settings.save()
                                customPathValid = nil
                                installError = nil
                                // Apply immediately so status updates
                                gameManager.applyWineSettings()
                                _ = gameManager.wineManager.checkWineAvailability()
                            }
                        } label: {
                            Label(mode.displayName, systemImage: mode.icon)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    selected
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))

                // ── Mode-specific content ──
                Group {
                    switch gameManager.settings.wineSourceMode {
                    case .github:
                        githubModeContent
                    case .custom:
                        customModeContent
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.22), value: gameManager.settings.wineSourceMode)

                // ── Install progress ──
                if isInstallingWine, let progress = installProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(progress.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if case .downloading(let p) = progress {
                                Text("\(Int(p * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: progressValue(progress))
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                }

                // ── Error banner ──
                if let err = installError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                if wineStatus.isReady {
                    Divider().opacity(0.4)

                    HStack {
                        Text("Wine Tools")
                            .font(.callout)
                        Spacer()
                        Button {
                            openWineTool("winecfg")
                        } label: {
                            Label("Wine Config", systemImage: "wineglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            openWineTool("regedit")
                        } label: {
                            Label("Registry Editor", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            openConsole()
                        } label: {
                            Label("Console (CMD)", systemImage: "terminal")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("Opens the built-in Wine tools against the default prefix (~/.kafka-launcher/wineprefix).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().opacity(0.4)

                    HStack {
                        Text("Troubleshooting")
                            .font(.callout)
                        Spacer()
                        Button {
                            recreatePrefix()
                        } label: {
                            if isRecreatingPrefix {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Recreate Wine Prefix")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRecreatingPrefix)
                    }
                    Text("Can resolve Wine data corruption issues (such as VC++ Redist or empty C:\\ drive). The old prefix directory will be deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: GitHub mode UI

    private var githubModeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Distribution picker
            HStack {
                Text("Wine Build")
                    .font(.callout)
                Spacer()
                Picker("", selection: $gameManager.settings.selectedWineDistribution) {
                    ForEach(WineManager.distributions) { distro in
                        Text(distro.displayName).tag(distro.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 230)
                .onChange(of: gameManager.settings.selectedWineDistribution) {
                    gameManager.settings.save()
                    _ = gameManager.wineManager.checkWineAvailability()
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                // Install / Reinstall button
                Button {
                    startWineInstall()
                } label: {
                    Label(
                        wineStatus.isReady ? "Reinstall Wine" : "Download & Install Wine",
                        systemImage: wineStatus.isReady ? "arrow.clockwise" : "arrow.down.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstallingWine)

                Spacer()

                // Open wine folder button (only when managed wine exists)
                if case .ready = wineStatus {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: WineManager.winePath))
                    } label: {
                        Label("View Folder", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Wine will be downloaded from GitHub (Gcenx/macOS_Wine_builds or 3Shain/wine) and installed into ~/.kafka-launcher/wine/")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Custom mode UI

    private var customModeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Path row
            HStack(spacing: 8) {
                // Validation indicator
                Group {
                    if let valid = customPathValid {
                        Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(valid ? .green : .red)
                    } else {
                        Circle()
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 18)

                Text(
                    gameManager.settings.customWinePath.isEmpty
                        ? "No Wine directory selected"
                        : gameManager.settings.customWinePath
                )
                .font(.callout)
                .foregroundStyle(
                    gameManager.settings.customWinePath.isEmpty ? .secondary : .primary
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Select…") {
                    pickCustomWineFolder()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            // Validate button + hint
            HStack(spacing: 8) {
                if !gameManager.settings.customWinePath.isEmpty {
                    Button("Check") {
                        validateCustomPath()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            Text("Specify pre-installed Wine directory on the machine. The folder must contain bin/wine or bin/wine64.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Known path hints
            DisclosureGroup("Common Paths") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(commonWinePaths, id: \.self) { path in
                        HStack(spacing: 6) {
                            let exists = FileManager.default.fileExists(atPath: path + "/bin/wine64")
                                || FileManager.default.fileExists(atPath: path + "/bin/wine")
                            Image(systemName: exists ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(exists ? .green : .secondary)
                                .font(.caption)
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(exists ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if exists {
                                Button("Use") {
                                    gameManager.settings.customWinePath = path
                                    gameManager.settings.save()
                                    validateCustomPath()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    // MARK: Helpers

    private let commonWinePaths: [String] = [
        "/usr/local/opt/game-porting-toolkit/bin/../..",   // GPTK Homebrew
        "/opt/homebrew/opt/game-porting-toolkit",
        "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver",
        "/opt/homebrew",                                    // Homebrew wine64
        NSHomeDirectory() + "/.kafka-launcher/wine",        // managed path
    ]

    private func pickCustomWineFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Wine Directory"
        panel.message = "Select root directory containing Wine (must have bin/wine or bin/wine64 inside)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            gameManager.settings.customWinePath = url.path
            gameManager.settings.save()
            validateCustomPath()
        }
    }

    private func validateCustomPath() {
        let path = gameManager.settings.customWinePath
        let fm = FileManager.default
        let valid = fm.isExecutableFile(atPath: path + "/bin/wine64")
                 || fm.isExecutableFile(atPath: path + "/bin/wine")
        customPathValid = valid
        if valid {
            gameManager.applyWineSettings()
            _ = gameManager.wineManager.checkWineAvailability()
            installError = nil
        } else {
            installError = "Could not find bin/wine or bin/wine64 in the selected directory."
        }
    }

    private func startWineInstall() {
        let selectedId = gameManager.settings.selectedWineDistribution
        let distro = WineManager.distributions.first { $0.id == selectedId }
        isInstallingWine = true
        installError = nil
        Task {
            await gameManager.installWine(distribution: distro)
            await MainActor.run {
                isInstallingWine = false
            }
        }
    }

    private func progressValue(_ p: WineInstallProgress) -> Double {
        switch p {
        case .preparing:              return 0.02
        case .downloading(let v):    return 0.05 + v * 0.55
        case .extracting(let v):     return 0.60 + v * 0.25
        case .removingQuarantine:    return 0.86
        case .initializingPrefix:    return 0.93
        case .installingMediaFoundation: return 0.97
        case .complete:              return 1.0
        }
    }

    private func recreatePrefix() {
        isRecreatingPrefix = true
        Task {
            gameManager.applyWineSettings()
            try? await gameManager.wineManager.recreateWinePrefix()
            await MainActor.run {
                isRecreatingPrefix = false
            }
        }
    }

    private func openWineTool(_ tool: String) {
        Task {
            gameManager.applyWineSettings()
            do {
                try await gameManager.wineManager.openWineTool(tool)
            } catch {
                await MainActor.run {
                    installError = "Failed to open \(tool): \(error.localizedDescription)"
                }
            }
        }
    }

    private func openConsole() {
        Task {
            gameManager.applyWineSettings()
            let gameDir = WineManager.basePath
            do {
                try await gameManager.wineManager.openCmdWindow(gameDir: gameDir)
            } catch {
                await MainActor.run {
                    installError = "Failed to open console: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Wine Status Badge

private struct WineStatusBadge: View {
    let status: WineStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .shadow(color: dotColor.opacity(0.6), radius: 4)

            Text(status.displayName)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer()

            Text(badge.0)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.1.opacity(0.18), in: Capsule())
                .foregroundStyle(badge.1)
        }
    }

    private var dotColor: Color {
        switch status {
        case .ready, .systemWine, .customWine: return .green
        case .customWineInvalid:               return .red
        case .needsUpdate:                     return .orange
        default:                               return .gray
        }
    }

    private var badge: (String, Color) {
        switch status {
        case .ready, .systemWine, .customWine: return ("Ready", .green)
        case .customWineInvalid:               return ("Error", .red)
        case .needsUpdate:                     return ("Update Required", .orange)
        case .notInstalled:                    return ("Not Installed", .gray)
        default:                               return ("Not Checked", .gray)
        }
    }
}
