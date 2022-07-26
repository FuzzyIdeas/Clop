//
//  ContentView.swift
//  Clop
//
//  Created by Alin Panaitiu on 16.07.2022.
//

import ServiceManagement
import SwiftUI

// MARK: - LaunchAtLoginToggle

struct LaunchAtLoginToggle: View {
    @State var loginItemEnabled = launchAtLogin

    var body: some View {
        Toggle("Launch at login", isOn: $loginItemEnabled)
            .onChange(of: loginItemEnabled) { enabled in
                launchAtLogin = enabled
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
    }
}

// MARK: - MenuView

struct MenuView: View {
    @AppStorage(SHOW_MENUBAR_ICON) var showMenubarIcon = true
    @AppStorage(SHOW_SIZE_NOTIFICATION) var showSizeNotification = true

    var body: some View {
        Toggle("Show menubar icon", isOn: $showMenubarIcon)
        Toggle("Show bytes saved notification", isOn: $showSizeNotification)
        LaunchAtLoginToggle()
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @AppStorage(SHOW_MENUBAR_ICON) var showMenubarIcon = true
    @AppStorage(SHOW_SIZE_NOTIFICATION) var showSizeNotification = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 40) {
                VStack {
                    Image("clop")
                        .imageScale(.large)
                        .foregroundColor(.accentColor)
                    VStack {
                        Text("Clop")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                        Text("Clipboard")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("optimizer")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .offset(x: 0, y: -2)
                    }
                    .offset(x: 0, y: -25)
                }
                VStack(alignment: .leading) {
                    Toggle("Show menubar icon", isOn: $showMenubarIcon)
                    Toggle("Show bytes saved notification", isOn: $showSizeNotification)
                        .fixedSize()
                    LaunchAtLoginToggle()
                }.frame(height: 100, alignment: .top)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 20)

            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .offset(x: -20, y: -20)
        }
    }
}

// MARK: - ContentView_Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
