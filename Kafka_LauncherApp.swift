//
//  Kafka_LauncherApp.swift
//  Kafka-Launcher
//
//  Created by Furiri on 16/4/26.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        updateIcon()
        
        // Listen to system theme changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }
    
    @objc func themeChanged() {
        DispatchQueue.main.async {
            self.updateIcon()
        }
    }
    
    private func updateIcon() {
        if #available(macOS 15.0, *) {
            // On macOS 15+ (Sequoia), the OS natively handles "Icon & widget style" settings
            // (Default, Dark, Clear, Tinted) using the compiled Assets.xcassets AppIcon set.
            // Setting applicationIconImage to nil lets the system render the styled asset automatically.
            NSApplication.shared.applicationIconImage = nil
        } else {
            // Fallback for macOS 14 and older: programmatically toggle between light and dark assets.
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                NSApplication.shared.applicationIconImage = NSImage(named: "AppIconDark")
            } else {
                NSApplication.shared.applicationIconImage = NSImage(named: "AppIconLight")
            }
        }
    }
}

@main
struct Kafka_LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 660)
        .windowResizability(.contentSize)
    }
}
