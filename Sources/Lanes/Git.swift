import Foundation

struct Ref {
    enum Kind { case head, local, remote, tag }
    let name: String
    let kind: Kind
    var isHead = false
}

struct Commit {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let refs: [Ref]
    let subject: String
}

/// What the Commit Details pane shows about a commit.
struct CommitSummary {
    struct FileStat {
        let path: String
        let oldPath: String?
        /// Lines added and deleted; nil for a binary file.
        let added: Int?
        let deleted: Int?
    }
    let hash: String
    let parents: [String]
    let author: String
    let authorEmail: String
    let authorDate: Date
    let committer: String
    let committerEmail: String
    let committerDate: Date
    let subject: String
    /// The message after the subject line, trimmed.
    let body: String
    let files: [FileStat]
}

struct ChangedFile {
    let status: String   // A, M, D, R, C, T ...
    let path: String
    let oldPath: String?
}

enum Git {
    static func run(_ args: [String], in dir: URL) -> String? {
        run(args, in: dir, limit: .max)?.output
    }

    /// Runs git and returns its stdout, or nil if git failed.
    /// Stops reading (and kills git) once `limit` bytes have been read.
    static func run(_ args: [String], in dir: URL, limit: Int) -> (output: String, truncated: Bool)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=false", "-c", "log.showSignature=false"] + args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let handle = out.fileHandleForReading
        var data = Data()
        var truncated = false
        while case let chunk = handle.availableData, !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                truncated = true
                data = data.prefix(limit)
                p.terminate()
                break
            }
        }
        p.waitUntilExit()
        guard truncated || p.terminationStatus == 0 else { return nil }
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    static func topLevel(of dir: URL) -> URL? {
        guard let s = run(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        return URL(fileURLWithPath: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func log(in repo: URL, limit: Int) -> [Commit] {
        let fmt = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"
        var revs = ["--branches", "--remotes", "--tags"]
        // HEAD adds a detached HEAD; an unborn HEAD would make the whole log fail.
        if run(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo) != nil { revs.append("HEAD") }
        guard let out = run(["log"] + revs + ["--date-order", "--decorate=full", "--max-count=\(limit)", "--format=\(fmt)"],
                            in: repo)
        else { return [] }
        var commits: [Commit] = []
        for record in out.split(separator: "\u{1e}") {
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard f.count == 7 else { continue }
            commits.append(Commit(
                hash: f[0],
                parents: f[1].split(separator: " ").map(String.init),
                author: f[2],
                email: f[3],
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                refs: parseRefs(f[5]),
                subject: f[6]))
        }
        return commits
    }

    static func parseRefs(_ s: String) -> [Ref] {
        var refs: [Ref] = []
        for part in s.components(separatedBy: ", ") where !part.isEmpty {
            if part.hasPrefix("HEAD -> ") {
                refs.append(Ref(name: shortName(String(part.dropFirst(8))), kind: .local, isHead: true))
            } else if part == "HEAD" {
                refs.append(Ref(name: "HEAD", kind: .head, isHead: true))
            } else if part.hasPrefix("tag: ") {
                refs.append(Ref(name: shortName(String(part.dropFirst(5))), kind: .tag))
            } else if part.hasPrefix("refs/remotes/") {
                if part.hasSuffix("/HEAD") { continue }
                refs.append(Ref(name: shortName(part), kind: .remote))
            } else {
                refs.append(Ref(name: shortName(part), kind: .local))
            }
        }
        return refs
    }

    private static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    static func changedFiles(of c: Commit, in repo: URL) -> [ChangedFile] {
        let base = base(of: c, in: repo)
        guard let out = run(["diff", "--name-status", "-z", "-M", base, c.hash], in: repo) else { return [] }
        let parts = out.components(separatedBy: "\0")
        var files: [ChangedFile] = []
        var i = 0
        while i < parts.count, !parts[i].isEmpty {
            let status = String(parts[i].prefix(1))
            if status == "R" || status == "C" {
                guard i + 2 < parts.count else { break }
                files.append(ChangedFile(status: status, path: parts[i + 2], oldPath: parts[i + 1]))
                i += 3
            } else {
                guard i + 1 < parts.count else { break }
                files.append(ChangedFile(status: status, path: parts[i + 1], oldPath: nil))
                i += 2
            }
        }
        return files
    }

    static func summary(of c: Commit, in repo: URL) -> CommitSummary? {
        let fmt = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"
        guard let out = run(["show", "-s", "--format=\(fmt)", c.hash], in: repo) else { return nil }
        let f = out.components(separatedBy: "\u{1f}")
        guard f.count == 9 else { return nil }
        // The subject is the first paragraph, joined into one line, as git's %s does.
        let message = f[8].trimmingCharacters(in: .whitespacesAndNewlines)
        let split = message.range(of: "\n\n")
        let subject = String(message[..<(split?.lowerBound ?? message.endIndex)])
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let body = split.map { message[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return CommitSummary(
            hash: f[0], parents: f[1].split(separator: " ").map(String.init),
            author: f[2], authorEmail: f[3], authorDate: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
            committer: f[5], committerEmail: f[6], committerDate: Date(timeIntervalSince1970: TimeInterval(f[7]) ?? 0),
            subject: subject, body: body, files: fileStats(of: c, in: repo))
    }

    /// Lines added and deleted per file, from `git diff --numstat -z`.
    private static func fileStats(of c: Commit, in repo: URL) -> [CommitSummary.FileStat] {
        guard let out = run(["diff", "--numstat", "-z", "-M", base(of: c, in: repo), c.hash], in: repo) else { return [] }
        // Each entry is "added<TAB>deleted<TAB>path<NUL>", or for a rename "added<TAB>deleted<TAB><NUL>old<NUL>new<NUL>".
        let parts = out.components(separatedBy: "\0")
        var stats: [CommitSummary.FileStat] = []
        var i = 0
        while i < parts.count, !parts[i].isEmpty {
            let f = parts[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { break }
            let added = Int(f[0]), deleted = Int(f[1])
            if f[2].isEmpty {
                guard i + 2 < parts.count else { break }
                stats.append(.init(path: parts[i + 2], oldPath: parts[i + 1], added: added, deleted: deleted))
                i += 3
            } else {
                stats.append(.init(path: String(f[2]), oldPath: nil, added: added, deleted: deleted))
                i += 1
            }
        }
        return stats
    }

    static func diff(of c: Commit, file: ChangedFile, in repo: URL) -> String {
        var paths = [file.path]
        if let old = file.oldPath { paths.insert(old, at: 0) }
        let limit = 2_000_000
        guard let result = run(["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "-M", base(of: c, in: repo), c.hash, "--"] + paths,
                               in: repo, limit: limit)
        else { return "" }
        return result.truncated ? result.output + "\n… (truncated at \(limit / 1_000_000) MB)\n" : result.output
    }

    /// What to diff a commit against: its first parent, or the empty tree for a root commit.
    /// The empty tree's ID depends on the repository's object format (SHA-1 or SHA-256).
    private static func base(of c: Commit, in repo: URL) -> String {
        if let parent = c.parents.first { return parent }
        return run(["hash-object", "-t", "tree", "/dev/null"], in: repo)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    }
}
