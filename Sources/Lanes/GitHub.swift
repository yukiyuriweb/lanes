import Foundation

struct PullRequest: Decodable {
    struct Author: Decodable { let login: String }
    struct Oid: Decodable { let oid: String }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T] }

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
}

/// Reads pull requests through the `gh` CLI, which handles authentication and finds the GitHub repository from the remotes.
enum GitHub {
    private static let query = """
        query($owner: String!, $repo: String!) {
          repository(owner: $owner, name: $repo) {
            pullRequests(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url state isDraft headRefName baseRefName headRefOid mergeCommit { oid }
                reviewDecision author { login } createdAt body
                reviews(last: 50) { nodes { author { login } state body submittedAt } }
                comments(last: 100) { nodes { author { login } body createdAt } }
                reviewThreads(first: 50) {
                  nodes { isResolved path line originalLine comments(first: 30) { nodes { author { login } body createdAt } } }
                }
              }
            }
          }
        }
        """

    /// The most recently updated pull requests, or nil when `gh` is missing, not signed in,
    /// or the repository isn't on GitHub.
    static func pullRequests(in repo: URL) -> [PullRequest]? {
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
                let repository: Repository?
            }
            let data: Data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Response.self, from: data))?.data.repository?.pullRequests.nodes
    }
}
