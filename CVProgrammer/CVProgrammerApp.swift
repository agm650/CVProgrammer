//
//  CVProgrammerApp.swift
//  CVProgrammer
//
//  Created by Luc Dandoy on 22/12/2025.
//
// https://docs.tcsdcc.com/wiki/

import SwiftUI

@main
struct CVProgrammerApp: App {
    @StateObject private var metaStore = CVMetadataStore()

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rbus-ui-testing") {
            RBusMonitorView(service: RBusMonitorUITestService())
        } else {
            contentView
        }
        #else
        contentView
        #endif
    }

    private var contentView: some View {
        ContentView()
            .environmentObject(metaStore)
            .onAppear {
                metaStore.loadFromBundle()
            }
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
        .windowStyle(.titleBar)
        Settings {
            SettingsView()
        }
    }
}
