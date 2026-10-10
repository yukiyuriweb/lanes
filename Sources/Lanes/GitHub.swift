import Foundation

struct PullRequest: Decodable {
    struct Author: Decodable { let login: String }
    struct Oid: Decodable { let oid: String }
    struct Repository: Decodable { let url: String }
    /// One page of a connection. Large PRs can have more than the query asks for; `hidden` counts the rest.
    struct Nodes<T: Decodable>: Decodable {
        let nodes: [T]
        let totalCount: Int?
        var hidden: Int { max(0, (totalCount ?? nodes.count) - nodes.count) }
    }

    struct Review: Decodable {
        let author: Author?
        let state: String   // APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING
        let body: String
        let submittedAt: Date?
    }

    struct Comment: Decodable {
        let author: Author?
        let body: String
        let createdAt: Date
    }

    struct Thread: Decodable {
        let isResolved: Bool
        let path: String
        let line: Int?
        let originalLine: Int?
        let comments: Nodes<Comment>
        /// The newest comment, which the first page of `comments` may not reach.
        let latestComment: Nodes<Comment>?
    }

    let number: Int
    let title: String
    let url: String
    let state: String   // OPEN, CLOSED, MERGED
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let headRefOid: String
    /// The repository the branch lives in (a fork for PRs from forks); nil if it was deleted.
    let headRepository: Repository?
    let mergeCommit: Oid?
    let reviewDecision: String?
    let author: Author?
    let createdAt: Date
    let body: String
    let reviews: Nodes<Review>
    let comments: Nodes<Comment>
    let reviewThreads: Nodes<Thread>

    /// The commit the PR is shown on: the merge (or squash) commit once merged, the head otherwise.
    var commitHash: String { mergeCommit?.oid ?? headRefOid }

    var unresolvedThreads: Int { reviewThreads.nodes.filter { !$0.isResolved }.count }

    /// APPROVED or CHANGES_REQUESTED from GitHub's review decision, or else from each reviewer's latest verdict.
    var verdict: String? {
        if let reviewDecision, reviewDecision != "REVIEW_REQUIRED" { return reviewDecision }
        var latest: [String: String] = [:]
        for r in reviews.nodes where r.state == "APPROVED" || r.state == "CHANGES_REQUESTED" || r.state == "DISMISSED" {
            latest[r.author?.login ?? ""] = r.state
        }
        if latest.values.contains("CHANGES_REQUESTED") { return "CHANGES_REQUESTED" }
        if latest.values.contains("APPROVED") { return "APPROVED" }
        return nil
    }

    /// When someone other than `viewer` last reviewed or commented, or nil if nobody else has. Activity in
    /// resolved threads doesn't count: there's nothing left to do there, and those threads show collapsed.
    func lastActivity(excluding viewer: String) -> Date? {
        // A thread comment arrives in a review of its own, empty unless it has a summary; count such
        // comments through their (unresolved) thread instead of through that review. When not every thread
        // was fetched, those reviews still count, so replies in the missing threads aren't lost.
        // "Empty" is judged like the conversation view does, so a review counts only if it's shown.
        let threadsComplete = reviewThreads.hidden == 0
        let reviews = reviews.nodes.filter { !threadsComplete || $0.state != "COMMENTED" || !plainText($0.body).isEmpty }
            .compactMap { r in r.author?.login == viewer ? nil : r.submittedAt }
        let threadComments = reviewThreads.nodes.filter { !$0.isResolved }
            .flatMap { $0.comments.nodes + ($0.latestComment?.nodes ?? []) }
        let comments = (comments.nodes + threadComments).compactMap { c in c.author?.login == viewer ? nil : c.createdAt }
        return (reviews + comments).max()
    }
}

/// Remembers, per pull request, the latest activity the user has looked at, to mark open PRs with newer activity.
enum SeenActivity {
    private static let key = "seenPRActivity"

    /// Whether an open PR has reviews or comments by others that the user hasn't opened yet.
    static func isUnread(_ pr: PullRequest, viewer: String) -> Bool {
        guard pr.state == "OPEN", let last = pr.lastActivity(excluding: viewer) else { return false }
        let seen = (UserDefaults.standard.dictionary(forKey: key)?[entry(pr, viewer)] as? Double).map(Date.init(timeIntervalSince1970:))
        return seen.map { last > $0 } ?? true
    }

    static func markSeen(_ pr: PullRequest, viewer: String) {
        guard let last = pr.lastActivity(excluding: viewer) else { return }
        var seen = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        seen[entry(pr, viewer)] = last.timeIntervalSince1970
        UserDefaults.standard.set(seen, forKey: key)
    }

    /// Per account as well as per PR: what's "someone else's" activity depends on who is signed in to `gh`.
    private static func entry(_ pr: PullRequest, _ viewer: String) -> String { viewer + " " + pr.url }
}

/// Reads pull requests through the `gh` CLI, which handles authentication and finds the GitHub repository from the remotes.
enum GitHub {
    private static let query = """
        query($owner: String!, $repo: String!) {
          viewer { login }
          repository(owner: $owner, name: $repo) {
            pullRequests(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url state isDraft headRefName baseRefName headRefOid headRepository { url } mergeCommit { oid }
                reviewDecision author { login } createdAt body
                reviews(last: 50) { totalCount nodes { author { login } state body submittedAt } }
                comments(last: 100) { totalCount nodes { author { login } body createdAt } }
                reviewThreads(first: 50) {
                  totalCount
                  nodes { isResolved path line originalLine comments(first: 30) { totalCount nodes { author { login } body createdAt } }
                          latestComment: comments(last: 1) { nodes { author { login } body createdAt } } }
                }
              }
            }
          }
        }
        """

    /// The most recently updated pull requests and the signed-in user's login, or nil when `gh` is missing,
    /// not signed in, or the repository isn't on GitHub.
    static func pullRequests(in repo: URL) -> (prs: [PullRequest], viewer: String)? {
        // gh fills in {owner} and {repo} from the repository in the current directory.
        guard let data = gh(["api", "graphql", "-f", "query=\(query)", "-F", "owner={owner}", "-F", "repo={repo}"], in: repo)
        else { return nil }

        struct Response: Decodable {
            struct Data: Decodable {
                struct Repository: Decodable { let pullRequests: PullRequest.Nodes<PullRequest> }
                let viewer: PullRequest.Author
                let repository: Repository?
            }
            let data: Data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: data).data, let repository = response.repository
        else { return nil }
        return (repository.pullRequests.nodes, response.viewer.login)
    }

    /// GitHub's emoji shortcodes, each with the URL of its image, or nil when `gh` can't reach GitHub.
    static func emojiImages(in repo: URL) -> [String: String]? {
        gh(["api", "emojis"], in: repo).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    /// Posts `body` as a comment on the pull request at `url`; false if it couldn't.
    static func comment(_ body: String, on url: String, in repo: URL) -> Bool {
        gh(["pr", "comment", url, "--body", body], in: repo) != nil
    }

    /// What `gh` prints, or nil if it's missing or fails.
    private static func gh(_ arguments: [String], in repo: URL) -> Data? {
        // Apps launched from Finder don't get the shell's PATH, so look in the usual install locations.
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = arguments
        p.currentDirectoryURL = repo
        p.environment = ProcessInfo.processInfo.environment.merging(["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// GitHub's emoji shortcodes (`:+1:`) and the emoji they stand for, so text shows 👍 as GitHub does.
enum Emoji {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: String] = [:]

    /// Fetches the shortcodes through `gh` unless they're already known. Call it off the main thread.
    static func load(in repo: URL) {
        guard lock.withLock({ table.isEmpty }), let images = GitHub.emojiImages(in: repo) else { return }
        let emoji = images.compactMapValues(emoji(fromImage:))
        lock.withLock { table = emoji }
    }

    /// `s` with each known `:shortcode:` replaced by its emoji. Unknown ones stay as typed, as on GitHub.
    static func replacingShortcodes(in s: String) -> String {
        guard s.contains(":") else { return s }
        let table = lock.withLock { table }
        guard !table.isEmpty else { return s }
        let pattern = try! NSRegularExpression(pattern: ":([a-z0-9_+\\-]+):")
        var result = ""
        var rest = s.startIndex
        for match in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let range = Range(match.range, in: s)!
            guard range.lowerBound >= rest, let emoji = table[String(s[Range(match.range(at: 1), in: s)!])] else { continue }
            result += s[rest..<range.lowerBound] + emoji
            rest = range.upperBound
        }
        return result + s[rest...]
    }

    /// The emoji an image stands for, from its file name: `.../unicode/1f469-1f4bb.png` is 👩‍💻. GitHub's
    /// own images, like `octocat`, have no Unicode emoji and give nil.
    static func emoji(fromImage url: String) -> String? {
        guard let name = URL(string: url)?.deletingPathExtension().lastPathComponent, url.contains("/unicode/") else { return nil }
        let scalars = name.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        guard !scalars.isEmpty else { return nil }
        // The names leave out joiners and variation selectors; put them back so the sequence draws as one emoji.
        let regional: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF, modifier: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
        let tag: ClosedRange<UInt32> = 0xE0020...0xE007F, keycap: UInt32 = 0x20E3, presentation: UInt32 = 0xFE0F
        var s = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            let v = scalar.value
            // Flags (pairs of letters, or tag sequences), skin tones and keycaps attach without a joiner.
            if i > 0, !(v == keycap || v == presentation || modifier.contains(v) || tag.contains(v)
                        || (regional.contains(v) && regional.contains(scalars[i - 1].value))) {
                s.append("\u{200D}")
            }
            s.append(scalar)
            // Symbols like ❤ (U+2764) or ♀ are text by default; GitHub shows them as emoji.
            let next = i + 1 < scalars.count ? scalars[i + 1].value : nil
            if !scalar.properties.isEmojiPresentation, !tag.contains(v), v != keycap, v != presentation,
               !(next.map { $0 == presentation || modifier.contains($0) } ?? false) {
                s.append("\u{FE0F}")
            }
        }
        return String(s)
    }
}
