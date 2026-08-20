import BVXCore
import BVXEngine
import Foundation

// bvx-cli exposes the engine from the command line, mirroring bv's robot
// protocol. It links the same archive the app does, so any output here is
// produced by exactly the code path the GUI uses.

let usage = """
bvx-cli — command line access to the bvx engine

USAGE:
  bvx-cli <command> [options]

COMMANDS:
  info                  Resolved source, issue count, data hash, warnings
  issues                All issues as JSON
  metrics               Graph metrics (Phase 1 immediately, Phase 2 when ready)
  actionable            Issues with no unresolved blocking dependency
  plan                  Parallel execution tracks
  graph                 Dependency edges
  triage                Triage recommendations
  impact                Composite impact scores
  unblocks --id <ID>    What closing <ID> would unblock
  blocker-chain --id <ID>
  label-health
  eta --id <ID> [--agents N]
  summary               Human-readable overview (default)
  doctor                End-to-end self check; exits non-zero on failure

OPTIONS:
  --path <PATH>   Workspace, .beads directory, or data file (default: cwd)
  --wait          Wait for Phase-2 metrics before reporting
  --raw           Print raw JSON with no pretty-printing

EXAMPLES:
  bvx-cli summary --path ./Fixtures/demo
  bvx-cli metrics --wait --path ~/src/myproject
  bvx-cli unblocks --id bvx-3
"""

struct Options {
    var command = "summary"
    var path = FileManager.default.currentDirectoryPath
    var id: String?
    var agents: Int = 1
    var wait = false
    var raw = false
}

func parseArguments() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    if let first = args.first, !first.hasPrefix("-") {
        opts.command = first
        args.removeFirst()
    }

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--path":
            i += 1
            if i < args.count { opts.path = args[i] }
        case "--id":
            i += 1
            if i < args.count { opts.id = args[i] }
        case "--agents":
            i += 1
            if i < args.count { opts.agents = Int(args[i]) ?? 1 }
        case "--wait":
            opts.wait = true
        case "--raw":
            opts.raw = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown option: \(args[i])\n".utf8))
            exit(2)
        }
        i += 1
    }
    return opts
}

func emit(_ data: Data, raw: Bool) {
    guard !raw else {
        FileHandle.standardOutput.write(data)
        print()
        return
    }
    if let object = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
        FileHandle.standardOutput.write(pretty)
        print()
    } else {
        FileHandle.standardOutput.write(data)
        print()
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Renders the overview a human actually wants when they just type `bvx-cli`.
func printSummary(
    info: WorkspaceInfo, issues: [Issue], metrics: GraphMetrics,
    actionable: Set<String>, plan: ExecutionPlan
) {
    print("Workspace  \(info.displayName)")
    print("Source     \(info.source) (\(info.kind.displayName))")
    print("Hash       \(info.shortHash)")
    print("")

    var byStatus: [String: Int] = [:]
    for issue in issues { byStatus[issue.status.displayName, default: 0] += 1 }
    let statusLine =
        byStatus
        .sorted { $0.key < $1.key }
        .map { "\($0.key) \($0.value)" }
        .joined(separator: "  ")
    print("Issues     \(issues.count)   \(statusLine)")
    print("Graph      \(metrics.nodeCount) nodes, \(metrics.edgeCount) edges, density \(String(format: "%.4f", metrics.density))")
    print("Ready      \(actionable.count) actionable, \(plan.tracks.count) parallel tracks")

    if metrics.phase2Ready, let pr = metrics.pageRank, !pr.isEmpty {
        print("")
        print("Top blockers by PageRank:")
        let titles = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0.title) })
        for (id, score) in pr.sorted(by: { $0.value > $1.value }).prefix(5) {
            let blocks = metrics.blocks(id)
            print(
                "  \(id.padding(toLength: 10, withPad: " ", startingAt: 0))"
                    + " \(String(format: "%.4f", score))  blocks \(blocks)  \(titles[id] ?? "")")
        }
    } else {
        print("")
        print("Phase-2 metrics not ready (pass --wait to compute them).")
    }

    if !info.warnings.isEmpty {
        print("")
        print("Warnings:")
        for w in info.warnings { print("  • \(w)") }
    }
}

// MARK: - Main

let options = parseArguments()
let engine = BeadsEngine()

// The engine actor is async; this CLI is synchronous, so drive it through a
// semaphore rather than pretending the whole tool is async.
let done = DispatchSemaphore(value: 0)

Task {
    do {
        let info = try await engine.open(path: options.path)

        if options.wait {
            _ = try await engine.waitForPhase2()
        }

        switch options.command {
        case "summary":
            let issues = try await engine.issues()
            let metrics =
                options.wait ? try await engine.metrics() : try await engine.metrics()
            let actionable = try await engine.actionableIDs()
            let plan = try await engine.executionPlan()
            printSummary(
                info: info, issues: issues, metrics: metrics,
                actionable: actionable, plan: plan)

        case "doctor":
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
                if !ok { failures += 1 }
            }

            print("bvx doctor — \(info.source)")
            check("workspace opened", info.issueCount > 0, "\(info.issueCount) beads")
            check("data hash computed", !info.dataHash.isEmpty, info.shortHash)

            let issues = try await engine.issues()
            check("issues decoded", issues.count == info.issueCount)
            check("titles present", issues.allSatisfy { !$0.title.isEmpty })

            let phase1 = try await engine.metrics()
            check("phase 1 metrics", phase1.nodeCount == issues.count,
                  "\(phase1.nodeCount) nodes, \(phase1.edgeCount) edges")

            let full = try await engine.waitForPhase2()
            check("phase 2 metrics", full.hasPhase2Values,
                  full.status?.pageRank?.state.displayName ?? "unknown")

            let actionable = try await engine.actionableIDs()
            check("actionable set", !actionable.isEmpty, "\(actionable.count) ready")

            let plan = try await engine.executionPlan()
            let planned = Set(plan.tracks.flatMap { $0.items.map(\.id) })
            check("execution plan", !plan.tracks.isEmpty, "\(plan.tracks.count) tracks")
            check("plan covers actionable set", planned == actionable)

            let edges = try await engine.graphEdges()
            check("graph edges", !edges.isEmpty, "\(edges.count) edges")

            print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
            await engine.close()
            exit(failures == 0 ? 0 : 1)

        case "info", "issues", "metrics", "actionable", "plan", "graph", "triage",
            "impact", "recommendations", "label-health", "label-flow":
            let method = options.command.replacingOccurrences(of: "-", with: "_")
            emit(try await engine.rawJSON(method), raw: options.raw)

        case "unblocks", "blocker-chain", "eta":
            guard let id = options.id else { fail("\(options.command) requires --id") }
            let method = options.command.replacingOccurrences(of: "-", with: "_")
            var request: [String: Any] = ["id": id]
            if options.command == "eta" { request["agents"] = options.agents }
            emit(try await engine.rawJSON(method, request: request), raw: options.raw)

        default:
            fail("unknown command '\(options.command)'. Run --help for usage.")
        }

        await engine.close()
        done.signal()
    } catch {
        FileHandle.standardError.write(
            Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

done.wait()
