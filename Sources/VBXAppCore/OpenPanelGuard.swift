import AppKit
import VBXCore
import VBXEngine
import Foundation

/// Keeps the Open panel from offering folders vbx cannot open.
///
/// The rule as asked for is "only a folder containing `.beads`", but that is
/// narrower than what the engine actually accepts, and enforcing the literal
/// rule would make two legitimate choices unselectable: a `.beads` directory
/// picked directly, and — the one that matters — a multi-repository workspace
/// root, which holds `.bv/workspace.yaml` while its `.beads` directories live in
/// the repositories *below* it.
///
/// So the predicate is not written here at all. Every answer comes from
/// `BeadsEngine.probe`, which is the same discovery code `open` runs, and that
/// is what makes it impossible for the panel to offer a folder that then fails
/// to load, or to refuse one that would have worked.
///
/// Two hooks, doing different jobs:
///
///   - ``panel(_:shouldEnable:)`` greys out unopenable *files*, and leaves
///     every directory enabled. This was written the other way round, on the
///     belief that greying a directory was advisory and AppKit would still let
///     the user navigate into it. It does not: a disabled directory cannot be
///     entered, and since the folders on the way to a repository are
///     themselves unopenable, the panel could not be navigated to a workspace
///     at all unless it opened inside one.
///   - ``panel(_:validate:)`` is the actual gate. It runs on OK and throws, so a
///     folder that slips past the greying — typed into the Go-to-folder sheet,
///     say — is refused with a reason rather than opened into an error alert.
public final class OpenPanelGuard: NSObject, NSOpenSavePanelDelegate {

    /// Answering is a few `stat` calls, but the panel asks about every visible
    /// row on every redraw, so results are remembered for the guard's lifetime.
    /// A guard does not outlive the sheet, which is also why a folder that
    /// gained a `.beads` between two openings is not answered from stale state.
    private var cache: [String: ProbeResult] = [:]
    private let probe: (String) -> ProbeResult

    /// - Parameter probe: injected so tests can drive the guard without a
    ///   panel. The default is the engine, and nothing else should be passed
    ///   in the app — a second predicate is exactly what this type exists to
    ///   prevent.
    public init(probe: @escaping (String) -> ProbeResult = OpenPanelGuard.engineProbe) {
        self.probe = probe
    }

    /// The engine's answer, with a failed call treated as "no".
    ///
    /// A probe that could not answer must refuse: offering a folder on the
    /// strength of a call that failed is how the panel and the loader come to
    /// disagree.
    public static func engineProbe(_ path: String) -> ProbeResult {
        do {
            return try BeadsEngine.probe(path: path)
        } catch {
            return ProbeResult(
                path: path, canOpen: false,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Whether `path` can be opened, memoised.
    public func result(for path: String) -> ProbeResult {
        if let cached = cache[path] { return cached }
        let result = probe(path)
        cache[path] = result
        return result
    }

    public func canOpen(_ path: String) -> Bool { result(for: path).canOpen }

    /// Why `path` was refused, phrased for an alert.
    public func refusal(for path: String) -> String {
        let result = self.result(for: path)
        let detail = result.reason.isEmpty ? "it holds no bead data" : result.reason
        return "“\(URL(fileURLWithPath: path).lastPathComponent)” cannot be opened: \(detail)."
    }

    // MARK: - NSOpenSavePanelDelegate

    public func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        // Directories are always enabled, whether or not they can be opened.
        //
        // A disabled directory cannot be double-clicked into, so greying the
        // unopenable ones made the panel unusable for its main job: `~/src`
        // holds no `.beads` and none above it, so it was disabled, and there
        // was no way to reach a repository underneath it. The user had to
        // start already inside a workspace.
        //
        // Nothing is lost by enabling them. ``panel(_:validate:)`` is the
        // actual gate — it runs on OK and refuses with a reason — so choosing
        // an unopenable folder gets an explanation instead of a row that
        // cannot be reached.
        if isDirectory(url) { return true }
        return canOpen(url.path)
    }

    /// Whether `url` is a directory, treating an unanswerable check as "yes".
    ///
    /// Erring towards a directory errs towards navigable: a wrong "yes" leaves
    /// a file enabled that `validate` will refuse anyway, while a wrong "no"
    /// recreates the dead end this exists to remove.
    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
    }

    public func panel(_ sender: Any, validate url: URL) throws {
        guard !canOpen(url.path) else { return }
        throw NSError(
            domain: "com.qjam.vbx", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: refusal(for: url.path),
                NSLocalizedRecoverySuggestionErrorKey:
                    "Choose a folder containing a .beads directory, a workspace root, "
                    + "or a bead data file.",
            ])
    }
}
