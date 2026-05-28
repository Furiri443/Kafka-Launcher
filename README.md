# Kafka-Launcher

A native macOS launcher for HoYoVerse games, built with Swift & SwiftUI. Runs games via [Wine](https://www.winehq.org/) compatibility layer and [DXMT](https://github.com/3Shain/dxmt) (Direct3D 11 → Metal translation).

---

## Requirements

| Component | Requirement |
| :--- | :--- |
| **macOS** | macOS 13 Ventura or later |
| **Architecture** | Apple Silicon or Intel |
| **Xcode** | Xcode 15 or later (for building from source) |
| **Wine** | Managed automatically by the app |
| **xdelta3** | Homebrew or bundled binary |

---

## Supported Games

| Game | Status |
| :--- | :---: |
| Genshin Impact | ✅ |
| Honkai: Star Rail | ✅ |
| Zenless Zone Zero | ✅ |
| Honkai Impact 3rd | 🔜 Planned |

---

## Features

### Native macOS Experience
Built entirely in Swift & SwiftUI with zero Electron or Node.js runtime overhead. Uses the modern `@Observable` macro for reactive state management and smooth SwiftUI updates.

### Wine Management
Automatically downloads and manages Wine installations, including optimized community builds (e.g., **3Shain v9.9-dxmt** tuned for the Metal API). Handles Media Foundation DLL installation to fix in-game cutscene playback.

### DXMT (DirectX 11 → Metal)
Version-aware DLL placement for optimal D3D11 to Metal translation:
- DXMT ≥ 0.74.0 → installed directly into Wine's library directory.
- DXMT < 0.74.0 → installed into `system32/` with native override.

### Binary Version Detection
Reads Unity binary data files (e.g., `globalgamemanagers`) directly to detect the installed game version — more accurate and resilient than text log or config file parsing.

### 4-Phase Launch Sequence

```
Phase 1 — Pre-Launch Setup
  Set Wine properties → Apply Resolution & HDR Registry
  → Configure Proxy & Import macOS Certificates
  → Wait for WineServer to idle

Phase 2 — Patching
  Place DXMT DLLs → Inject nvngx.dll / Steam DLLs
  → Download Jadeite (HSR) → Backup Crash Reporters

Phase 3 — Game Execution
  Generate config.bat → Set Environment Variables
  → Apply temporary network block → Launch via Wine/Jadeite
  → Monitor process until exit

Phase 4 — Post-Launch Cleanup
  Revert Registry → Restore backup files
  → Revert DXMT DLLs → Clean up config.bat
```

**Pre-Launch Setup** — Configures Wine properties (Retina Mode, Left Command → Control key mapping). Generates `.reg` files for custom resolution, HDR mode, and proxy settings. Automatically extracts macOS Keychain root certificates and imports them into the Wine certificate store for reliable HTTPS connections.

**Patching** — Places DXMT translation libraries, injects `nvngx.dll` for NVIDIA GPU emulation (Star Rail), and backs up game crash reporter executables to prevent Wine conflicts.

**Game Execution** — Sets key environment variables including `WINEMSYNC`/`WINEESYNC` for high-performance threading and `DXMT_CONFIG` to spoof an NVIDIA GPU vendor/device ID for Star Rail (`10de`/`2684`). Temporarily modifies `/etc/hosts` via `osascript` to block game dispatch servers during the first few seconds of startup, then automatically reverts.

**Post-Launch Cleanup** — Restores all patched files from `.bak` backups, reverts registry changes, and removes temporary scripts.

### xdelta3 Binary Patching
Applies binary patches for Wine compatibility using `xdelta3`. All patches are automatically reverted after each session to preserve the original game data.

### Per-Game Configuration

| Feature | Genshin Impact | Honkai: Star Rail | Zenless Zone Zero |
| :--- | :---: | :---: | :---: |
| Jadeite Wrapper | ❌ | ✅ v4.1.0 | ❌ |
| Anti-Cheat Driver | `HoYoKProtect.sys` | ❌ | `HoYoKProtect.sys` |
| Steam Libraries | ✅ | ❌ | ✅ |
| HDR Mode | ✅ | ❌ | ❌ |
| Custom Resolution | ✅ | ❌ | ✅ |
| Webview Fix | ❌ | ✅ | ✅ |
| NVIDIA GPU Spoof | ❌ | ✅ | ❌ |

---

## Project Structure

```
Kafka-Launcher/
├── Models/
│   ├── GameConfig.swift          # Per-game config (resolution, HDR, DXMT, Wine, proxy)
│   ├── GameInfo.swift            # Game metadata from HoYo API
│   ├── GameState.swift           # State machine (notInstalled, ready, running, updating…)
│   └── GameType.swift            # Game enum: genshinImpact, honkaiStarRail, zenlessZoneZero
├── Services/
│   ├── GameManager.swift         # Central orchestrator: install, update & launch lifecycle
│   ├── WineManager.swift         # Wine installation, wineprefix, MediaFoundation DLLs
│   ├── DXMTManager.swift         # DXMT download & version-aware DLL placement
│   ├── RegistryManager.swift     # Wine registry file generation (UTF-16LE + BOM)
│   ├── PatchManager.swift        # xdelta3 binary patch apply & restore
│   ├── JadeiteManager.swift      # Jadeite wrapper management for Star Rail
│   ├── GameServerAPI.swift       # HoYo API: update manifests & background images
│   └── GameVersionDetector.swift # Unity binary-based version detection
├── Utilities/
│   ├── ProcessRunner.swift       # Async shell process execution
│   └── Extensions.swift          # Swift utility extensions
└── Views/                        # SwiftUI views (MainView, Sidebar, Settings…)
```

---

## Roadmap

- [ ] **Honkai Impact 3rd support**
- [ ] **China (CN) region server support**
- [ ] **Delta update downloads** — download only changed files instead of the full package
- [ ] **Pre-download support** — pre-download next version update packages
- [ ] **In-app Log Viewer** — integrated Wine log viewer and Metal Shader Cache manager

---

## Credits

- **[Wine](https://www.winehq.org/)** — Windows compatibility layer
- **[DXMT](https://github.com/3Shain/dxmt)** — DirectX 11 to Metal translation by 3Shain
- **[Jadeite](https://github.com/an-anime-team/jadeite)** — Anti-cheat wrapper for Honkai: Star Rail
- **[xdelta3](http://xdelta.org/)** — Binary delta patching
- **[YAGL](https://github.com/yaagl/yet-another-anime-game-launcher)** — Original launcher this project is based on

---

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by miHoYo / HoYoVerse. All game names and trademarks are the property of their respective owners. Use at your own risk.

---

## License

Licensed under the [Apache License 2.0](LICENSE).
