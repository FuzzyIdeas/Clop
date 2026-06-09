import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "InstallCLI")

struct InstallCLIError: Error {
    let message: String
    let info: String
}

let CLOP_CLI_BIN = "\(Bundle.main.sharedSupportPath!)/ClopCLI"
let CLI_BIN_DIR = "\(HOME)/.local/bin"
let CLI_BIN_DIR_ENV = "$HOME/.local/bin"
let CLOP_CLI_BIN_LINK = "\(CLI_BIN_DIR)/clop"
let CLOP_CLI_BIN_SHELL = "~/.local/bin/clop"
let ZSHRC = "\(HOME)/.zshrc"
let BASHRC = "\(HOME)/.bashrc"
let FISHRC = "\(HOME)/.config/fish/config.fish"
let PATH_EXPORT = """

export PATH="$PATH:\(CLI_BIN_DIR_ENV)"

"""

func installCLIBinary() throws {
    if !fm.fileExists(atPath: CLI_BIN_DIR) {
        do {
            try fm.createDirectory(atPath: CLI_BIN_DIR, withIntermediateDirectories: true)
        } catch {
            log.error("Error on creating \(CLI_BIN_DIR): \(error)")
            throw InstallCLIError(
                message: "Missing \(CLI_BIN_DIR)",
                info: "Error on creating the '\(CLI_BIN_DIR)' directory: \(error)"
            )
        }
    }

    // Recreate the symlink only if it isn't already pointing at this bundle's CLI.
    // `attributesOfItem` uses lstat, so it also catches broken/stale symlinks that
    // `fileExists` (which follows the link) would silently miss and then fail to replace.
    if !cliSymlinkValid() {
        if (try? fm.attributesOfItem(atPath: CLOP_CLI_BIN_LINK)) != nil {
            do {
                try fm.removeItem(atPath: CLOP_CLI_BIN_LINK)
            } catch {
                log.error("Error on removing \(CLOP_CLI_BIN_LINK): \(error)")
                throw InstallCLIError(
                    message: "Already existing \(CLOP_CLI_BIN_LINK)",
                    info: "Error on removing the existing '\(CLOP_CLI_BIN_LINK)' file: \(error)"
                )
            }
        }

        try fm.createSymbolicLink(atPath: CLOP_CLI_BIN_LINK, withDestinationPath: CLOP_CLI_BIN)
    }

    for config in [BASHRC, ZSHRC, FISHRC] {
        let contents = fm.contents(atPath: config)?.s ?? ""
        guard !contents.contains(CLI_BIN_DIR_ENV), !contents.contains(CLI_BIN_DIR) else {
            continue
        }

        fm.createFile(
            atPath: shellConfigWriteTarget(config),
            contents: (contents + PATH_EXPORT).data(using: .utf8),
            attributes: [.posixPermissions: 0o644]
        )
    }

    Defaults[.cliInstalled] = true
}

/// Whether the `clop` CLI symlink exists and points at this bundle's CLI binary.
/// A stale link (the app was moved or updated to a new path) or a broken link reads
/// as not installed, so the UI can offer a reinstall that repairs it.
func cliSymlinkValid() -> Bool {
    guard let attrs = try? fm.attributesOfItem(atPath: CLOP_CLI_BIN_LINK),
          (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
          let dest = try? fm.destinationOfSymbolicLink(atPath: CLOP_CLI_BIN_LINK)
    else { return false }
    return dest == CLOP_CLI_BIN && fm.fileExists(atPath: CLOP_CLI_BIN)
}

/// If a shell config file is itself a symlink (e.g. managed dotfiles), return its
/// real target so we write through it instead of replacing the symlink with a plain file.
func shellConfigWriteTarget(_ config: String) -> String {
    guard let attrs = try? fm.attributesOfItem(atPath: config),
          (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
          let dest = try? fm.destinationOfSymbolicLink(atPath: config)
    else { return config }
    return URL(fileURLWithPath: dest, relativeTo: URL(fileURLWithPath: config).deletingLastPathComponent()).path
}

func handleCLIInstall() {
    let args = CommandLine.arguments
    guard args.contains("install-cli") || args.contains("installcli") || args.contains("cli") else {
        return
    }

    do {
        try installCLIBinary()
        print("CLI installed at \(CLOP_CLI_BIN_SHELL)")

        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            do {
                try exec(arg0: shell, args: ["-l"])
            } catch {
                print("Restart your shell and type `clop --help` to use it")
            }
        }
    } catch let error as InstallCLIError {
        print(error.message)
        print(error.info)
        exit(1)
    } catch {
        print("Error installing CLI")
        print(error.localizedDescription)
        exit(2)
    }
    exit(0)
}
