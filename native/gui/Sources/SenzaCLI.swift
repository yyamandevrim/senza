import AppKit
import Foundation
import GameController
import SwiftUI

// MARK: - CLI Discovery

struct SenzaCLI {
    static func resolve() -> (executable: URL, workingDir: URL)? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        if let repoRoot = Bundle.main.infoDictionary?["SenzaRepoRoot"] as? String, !repoRoot.isEmpty {
            candidates.append((repoRoot as NSString).appendingPathComponent("bin/senza"))
        }
        // Release builds carry the CLI, dylibs and profiles in Contents/Resources.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/senza").path {
            candidates.append(bundled)
        }
        candidates.append("\(home)/.local/bin/senza")
        candidates.append("/opt/homebrew/bin/senza")
        candidates.append("/usr/local/bin/senza")

        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let repoDir = resolved.deletingLastPathComponent().deletingLastPathComponent()
                let cwd = fm.fileExists(atPath: repoDir.path) ? repoDir : fm.homeDirectoryForCurrentUser
                return (URL(fileURLWithPath: path), cwd)
            }
        }
        return nil
    }

    static func appIconImage() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "Senza", withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }
        return NSApp.applicationIconImage
    }
}

// MARK: - CLI Runner

/// Result of one Senza CLI invocation.
struct CLIResult {
    let status: Int32
    let stdout: Data
    let output: String

    var ok: Bool { status == 0 }

    /// Non-empty output lines with any `[tag]` prefixes (e.g. `[tunnel]`, `[service]`) stripped.
    var lines: [String] {
        output.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
                    s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty }
    }

    /// Last meaningful line, used as a one-line status summary.
    func summary(or fallback: String) -> String { lines.last ?? fallback }
}

extension SenzaCLI {
    static let notFoundMessage = "Senza CLI not found. Run `make install` in the repository first."

    /// PATH that finds Homebrew, ~/.local/bin and system tools even when launched from Finder/Dock.
    static func baseEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let curPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(curPath)"
        return env
    }

    /// Configured `Process` for a CLI invocation (callers that stream output use this directly).
    static func makeProcess(_ args: [String], extraEnv: [String: String] = [:]) -> Process? {
        guard let cli = resolve() else { return nil }
        let proc = Process()
        proc.executableURL = cli.executable
        proc.currentDirectoryURL = cli.workingDir
        proc.arguments = args
        proc.environment = baseEnv().merging(extraEnv) { _, new in new }
        return proc
    }

    /// Blocking run; call off the main thread. stdout is kept separately for JSON decoding.
    static func runSync(_ args: [String]) -> CLIResult {
        guard let proc = makeProcess(args) else {
            return CLIResult(status: -1, stdout: Data(), output: notFoundMessage)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return CLIResult(status: -1, stdout: Data(), output: error.localizedDescription)
        }
        // Drain stderr concurrently so a chatty stderr can't deadlock a full pipe buffer.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        proc.waitUntilExit()
        let text = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return CLIResult(status: proc.terminationStatus, stdout: outData, output: text)
    }

    /// Async wrapper: runs on a background queue, resumes on the caller's actor.
    static func run(_ args: [String]) async -> CLIResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(args))
            }
        }
    }
}
