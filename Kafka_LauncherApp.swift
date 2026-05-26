//
//  Kafka_LauncherApp.swift
//  Kafka-Launcher
//
//  Created by Furiri on 16/4/26.
//

import SwiftUI

@main
struct Kafka_LauncherApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 660)
        .windowResizability(.contentSize)
    }
}
