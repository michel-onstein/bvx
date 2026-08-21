import AppKit
import Foundation

/// Installs the bundled `vbx-cli` somewhere on the user's PATH.
///
/// The destination is chosen through a save panel rather than written straight
/// to `/usr/local/bin`. That is not politeness: under the App Sandbox the
/// panel's grant is the only thing that authorises the write, and a hardcoded
/// path would simply fail. It also means the user picks a directory that is
/// actually on their PATH, which varies more than one would like.
public enum CommandLineTool {

    public enum InstallResult: Equatable, Sendable {
        case installed(path: String)
        case cancelled
        case failed(String)
    }

    /// The `vbx-cli` shipped beside the app, if there is one.
    ///
    /// Nil when running from a plain `swift build` rather than an app bundle,
    /// which is the case the menu item disables itself for.
    public static var bundledToolURL: URL? {
        // Inside a bundle the executable sits next to the app's own binary.
        let executable = Bundle.main.executableURL?.deletingLastPathComponent()
        if let executable {
            let candidate = executable.appendingPathComponent("vbx-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // A SwiftPM build puts both binaries in the same build directory.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("vbx-cli")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    public static var isAvailable: Bool { bundledToolURL != nil }

    /// Asks where to install, then links the tool there.
    @MainActor
    public static func install() -> InstallResult {
        guard let source = bundledToolURL else {
            return .failed("vbx-cli was not found beside the app.")
        }

        let panel = NSSavePanel()
        panel.title = "Install Command Line Tool"
        panel.message =
            "Choose a directory on your PATH. A link to the bundled vbx-cli is created there."
        panel.nameFieldStringValue = "vbx-cli"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return .cancelled
        }
        return link(source: source, destination: destination)
    }

    /// Creates the link, replacing an existing one.
    ///
    /// Separate from the panel so it can be tested without a UI.
    public static func link(source: URL, destination: URL) -> InstallResult {
        let manager = FileManager.default
        do {
            // A previous install is replaced rather than refused: the whole
            // point of running this again is usually to repoint it at a newer
            // build.
            if manager.fileExists(atPath: destination.path)
                || (try? destination.checkResourceIsReachable()) == true
            {
                try manager.removeItem(at: destination)
            }
            try manager.createSymbolicLink(at: destination, withDestinationURL: source)
            return .installed(path: destination.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
