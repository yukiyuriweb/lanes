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

struct ChangedFile {
    let status: String   // A, M, D, R, C, T ...
    let path: String
    let oldPath: String?
}

enum Git {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    static func run(_ args: [String], in dir: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=false", "-c", "log.showSignature=false"] + args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func topLevel(of dir: URL) -> URL? {
        guard let s = run(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        return URL(fileURLWithPath: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func log(in repo: URL, limit: Int) -> [Commit] {
        let fmt = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"
        guard let out = run(["log", "--branches", "--remotes", "--tags", "HEAD", "--date-order",
                             "--decorate=full", "--max-count=\(limit)", "--format=\(fmt)"], in: repo)
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
        let base = c.parents.first ?? emptyTree
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

    static func summary(of c: Commit, in repo: URL) -> String {
        let fmt = "commit    %H%nparents   %P%nauthor    %an <%ae>  %ad%ncommitter %cn <%ce>  %cd%n%n%B"
        let header = run(["show", "-s", "--date=format-local:%Y/%m/%d %H:%M:%S", "--format=\(fmt)", c.hash], in: repo) ?? ""
        let stat = run(["diff", "--stat=200", "-M", c.parents.first ?? emptyTree, c.hash], in: repo) ?? ""
        return header.trimmingCharacters(in: .newlines) + "\n\n" + stat
    }

    static func diff(of c: Commit, file: ChangedFile, in repo: URL) -> String {
        var paths = [file.path]
        if let old = file.oldPath { paths.insert(old, at: 0) }
        return run(["diff", "--no-color", "--no-ext-diff", "-M", c.parents.first ?? emptyTree, c.hash, "--"] + paths, in: repo) ?? ""
    }
}
