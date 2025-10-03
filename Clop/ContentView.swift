//
//  ContentView.swift
//  Clop
//
//  Created by Alin Panaitiu on 16.07.2022.
//

import Defaults
import LaunchAtLogin
import Lowtech
import LowtechIndie
import LowtechPro
import SwiftUI
import System

// MARK: - MenuView

struct MenuView: View {
    @ObservedObject var um = UM
    @ObservedObject var pm = PM
    @ObservedObject var om = OM
    @Environment(\.openWindow) var openWindow

    @Default(.keyComboModifiers) var keyComboModifiers
    @Default(.useAggressiveOptimisationGIF) var useAggressiveOptimisationGIF
    @Default(.useAggressiveOptimisationJPEG) var useAggressiveOptimisationJPEG
    @Default(.useAggressiveOptimisationPNG) var useAggressiveOptimisationPNG
    @Default(.useAggressiveOptimisationMP4) var useAggressiveOptimisationMP4
    @Default(.cliInstalled) var cliInstalled
    @Default(.pauseAutomaticOptimisations) var pauseAutomaticOptimisations
    @Default(.allowClopToAppearInScreenshots) var allowClopToAppearInScreenshots

    @State var cliInstallResult: String?

    @ViewBuilder var proErrors: some View {
        Section("Skipped items because of free version limits") {
            ForEach(om.skippedBecauseNotPro, id: \.self) { url in
                let str = url.isFileURL ? url.filePath!.shellString : url.absoluteString
                Button("    \(str.count > 50 ? (str.prefix(25) + "..." + str.suffix(15)) : str)") {
                    QuickLooker.quicklook(url: url)
                }
            }
            Button("Get Clop Pro") {
                settingsViewManager.tab = .about
                openWindow(id: "settings")

                PRO?.manageLicence()
                focus()
                NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some View {
        Button("Settings") {
            openWindow(id: "settings")
            focus()
        }.keyboardShortcut(",")
        LaunchAtLogin.Toggle()

        Divider()

        Section("Clipboard actions") {
            Button("Optimise") {
                Task.init { try? await optimiseLastClipboardItem() }
            }.keyboardShortcut("c", modifiers: keyComboModifiers.eventModifiers)

            if !useAggressiveOptimisationGIF ||
                !useAggressiveOptimisationJPEG ||
                !useAggressiveOptimisationPNG ||
                !useAggressiveOptimisationMP4
            {
                Button("Optimise (aggressive)") {
                    Task.init { try? await optimiseLastClipboardItem(aggressiveOptimisation: true) }
                }.keyboardShortcut("a", modifiers: keyComboModifiers.eventModifiers)
            }

            Button("Downscale") {
                scalingFactor = max(scalingFactor > 0.5 ? scalingFactor - 0.25 : scalingFactor - 0.1, 0.1)
                Task.init { try? await optimiseLastClipboardItem(downscaleTo: scalingFactor) }
            }.keyboardShortcut("-", modifiers: keyComboModifiers.eventModifiers)
            Button("Quicklook") {
                Task.init { try? await quickLookLastClipboardItem() }
            }.keyboardShortcut(" ", modifiers: keyComboModifiers.eventModifiers)

        }

        Section("Backups") {
            Button("Open backups folder") {
                NSWorkspace.shared.open(FilePath.clopBackups.url)
            }
            Button("Open working directory") {
                NSWorkspace.shared.open(FilePath.workdir.url)
            }
            Button("Force clean working directory") {
                do {
                    for dir in [FilePath.clopBackups, .videos, .images, .pdfs, .conversions, .downloads, .forResize, .forFilters, .finderQuickAction, .processLogs] {
                        try FileManager.default.removeItem(at: dir.url)
                    }
                } catch {
                    showNotice("Failed to clean working directory\n\(error.localizedDescription)")
                }

                FilePath.workdir.mkdir(withIntermediateDirectories: true, permissions: 0o755)
                guard FilePath.workdir.exists else {
                    showNotice("Failed to create working directory")
                    return
                }

                showNotice("Working directory cleaned")
            }

            Button("Revert last optimisations") {
                om.clipboardImageOptimiser?.restoreOriginal()
            }
            .keyboardShortcut("z", modifiers: keyComboModifiers.eventModifiers)
            .disabled(om.clipboardImageOptimiser?.isOriginal ?? true)
            Button("Bring back last result") {
                guard let last = om.removedOptimisers.popLast() else {
                    return
                }
                om.optimisers = om.optimisers.without(last).with(last)
            }
            .keyboardShortcut("=", modifiers: keyComboModifiers.eventModifiers)
            .disabled(om.removedOptimisers.isEmpty)
        }

        Section("Automation") {
            Toggle("Pause automatic optimisations", isOn: $pauseAutomaticOptimisations)
            if !cliInstalled {
                Button("Install command-line integration") {
                    do {
                        try installCLIBinary()
                        cliInstallResult = "CLI installed at \(CLOP_CLI_BIN_SHELL)"
                    } catch let error as InstallCLIError {
                        cliInstallResult = error.message
                    } catch {
                        cliInstallResult = "Installation failed"
                    }
                    showNotice(cliInstallResult!)
                }
            }
            if let cliInstallResult {
                Text(cliInstallResult).disabled(true)
            } else if cliInstalled {
                Text("CLI installed at \(CLOP_CLI_BIN_SHELL)").disabled(true)
            }
        }

        if !proactive, !om.skippedBecauseNotPro.isEmpty {
            proErrors
        }

        Menu("About...") {
            Button("Contact the developer") {
                NSWorkspace.shared.open(contactURL())
            }
            Button("Privacy policy") {
                NSWorkspace.shared.open("https://lowtechguys.com/clop/privacy".url!)
            }
            Text("License: \(proactive ? "Pro" : "Free")")
            #if DEBUG
                Button("Reset Trial") {
                    product?.resetTrial()
                }
                Button("Expire Trial") {
                    product?.expireTrial()
                }
            #endif
            Text("Version: v\(Bundle.main.version)")
        }

        Button("Manage license") {
            settingsViewManager.tab = .about
            openWindow(id: "settings")

            PRO?.manageLicence()
            focus()
            NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        }

        Button(um.newVersion != nil ? "v\(um.newVersion!) update available" : "Check for updates") {
            checkForUpdates()
            focus()
        }

        Toggle("Show Clop UI in screenshots", isOn: $allowClopToAppearInScreenshots)
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }.keyboardShortcut("q")
    }
}

func contactURL() -> URL {
    guard var urlBuilder = URLComponents(url: "https://lowtechguys.com/contact".url!, resolvingAgainstBaseURL: false) else {
        return "https://lowtechguys.com/contact".url!
    }
    urlBuilder.queryItems = [URLQueryItem(name: "userid", value: SERIAL_NUMBER_HASH), URLQueryItem(name: "app", value: "Clop")]

    if let licenseCode = product?.licenseCode {
        urlBuilder.queryItems?.append(URLQueryItem(name: "code", value: licenseCode))
    }

    if let email = product?.activationEmail {
        urlBuilder.queryItems?.append(URLQueryItem(name: "email", value: email))
    }

    return urlBuilder.url ?? "https://lowtechguys.com/contact".url!
}
