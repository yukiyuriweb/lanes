import Foundation

struct PullRequest: Decodable {
    struct Author: Decodable { let login: String }
    struct Oid: Decodable { let oid: String }
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
                number title url state isDraft headRefName baseRefName headRefOid mergeCommit { oid }
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
        // Apps launched from Finder don't get the shell's PATH, so look in the usual install locations.
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        // gh fills in {owner} and {repo} from the repository in the current directory.
        p.arguments = ["api", "graphql", "-f", "query=\(query)", "-F", "owner={owner}", "-F", "repo={repo}"]
        p.currentDirectoryURL = repo
        p.environment = ProcessInfo.processInfo.environment.merging(["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }

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
}
