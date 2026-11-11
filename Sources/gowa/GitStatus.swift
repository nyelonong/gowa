import Foundation

/// Read-only git state of the folder holding the collection file.
struct GitStatus: Equatable, Sendable {
    struct Change: Equatable, Sendable, Identifiable {
        var code: String
        var path: String
        var id: String { path }

        var label: String {
            switch code.trimmingCharacters(in: .whitespaces) {
            case "??": "untracked"
            case "A", "AM": "added"
            case "D": "deleted"
            case "R", "RM": "renamed"
            default: "modified"
            }
        }
    }

    var branch: String
    var ahead = 0
    var behind = 0
    var changes: [Change] = []
    /// The collection file's own change, if any.
    var collectionChange: Change?

    /// Parses `git status --porcelain=v1 --branch` output.
    static func parse(_ output: String, collectionPath: String?) -> GitStatus {
        var status = GitStatus(branch: "HEAD")
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                let name = header.components(separatedBy: "...").first ?? String(header)
                status.branch = name.hasPrefix("No commits yet on ") ? String(name.dropFirst("No commits yet on ".count)) : name
                if let open = header.firstIndex(of: "["), let close = header.firstIndex(of: "]") {
                    for part in header[header.index(after: open)..<close].components(separatedBy: ", ") {
                        let pieces = part.split(separator: " ")
                        guard pieces.count == 2, let count = Int(pieces[1]) else { continue }
                        if pieces[0] == "ahead" { status.ahead = count }
                        if pieces[0] == "behind" { status.behind = count }
                    }
                }
            } else if line.count > 3 {
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
                let change = Change(code: String(line.prefix(2)), path: path)
                status.changes.append(change)
                if path == collectionPath { status.collectionChange = change }
            }
        }
        return status
    }

    /// nil when the folder isn't inside a git work tree or git is unavailable.
    static func load(for file: URL) async -> GitStatus? {
        let directory = file.deletingLastPathComponent()
        guard let root = await run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty,
              // Status can run a repository's filter commands; skip repos that define any.
              await run(["config", "--get-regexp", "^filter\\."], in: directory)?.isEmpty ?? true,
              let output = await run(["status", "--porcelain=v1", "--branch", "--untracked-files=all"], in: directory)
        else { return nil }
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let relative = filePath.hasPrefix(rootURL.path + "/") ? String(filePath.dropFirst(rootURL.path.count + 1)) : nil
        return parse(output, collectionPath: relative)
    }

    private static func run(_ arguments: [String], in directory: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            // A downloaded repository's .git/config could name a command to run;
            // disable the settings that execute programs during status.
            process.arguments = ["-C", directory.path, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                                 "-c", "core.untrackedCache=false"] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Drain before waiting so large output can't fill the pipe and stall git.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
        }
    }
}
