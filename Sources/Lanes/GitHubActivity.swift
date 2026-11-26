import Foundation

struct GitHubActivity: Codable {
    enum Kind: String, Codable {
        case issueOpened, issueClosed, issueReopened
        case pullOpened, pullClosed, pullMerged, pullReopened
        case review, comment, push

        var group: Group {
            switch self {
            case .issueOpened, .issueClosed, .issueReopened: return .issues
            case .pullOpened, .pullClosed, .pullMerged, .pullReopened: return .pullRequests
            case .review: return .reviews
            case .comment: return .comments
            case .push: return .pushes
            }
        }
    }

    enum Group: CaseIterable {
        case issues, pullRequests, reviews, comments, pushes
    }

    let id: String
    let kind: Kind
    let date: Date
    let repository: String
    var title: String
    let number: Int?
    let isPullRequest: Bool
    let url: URL?

    var reference: String? { number.map { "#\($0)" } }
}

struct GitHubActivityFeed {
    enum Status { case current, cached, unsaved }

    let login: String
    let history: GitHubActivityHistory
    let status: Status
}

enum GitHubActivityError: Error {
    case missingCLI, accountUnavailable, eventsUnavailable
}

extension GitHub {
    static func activityFeed() -> Result<GitHubActivityFeed, GitHubActivityError> {
        guard cliPath != nil else { return .failure(.missingCLI) }
        // An explicit host and a neutral directory keep repository settings out of this request.
        let options = ["api", "--hostname", "github.com"]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        struct Account: Decodable { let id: Int64; let login: String }
        guard let user = gh(options + ["user"], in: directory),
              let account = try? decoder.decode(Account.self, from: user)
        else { return .failure(.accountUnavailable) }

        let store = GitHubActivityStore()
        let started = Date()
        let endpoint = "users/\(account.login)/events?per_page=100"
        guard let data = gh(options + ["--paginate", "--slurp", endpoint], in: directory),
              let pages = try? decoder.decode([[ActivityEvent]].self, from: data)
        else {
            guard let history = try? store.load(accountID: account.id) else { return .failure(.eventsUnavailable) }
            return .success(GitHubActivityFeed(login: account.login, history: history, status: .cached))
        }
        let received = Date()

        let events = pages.flatMap { $0 }
        var seen: Set<String> = []
        var activities = events.sorted { $0.createdAt < $1.createdAt }.compactMap { event -> GitHubActivity? in
            guard seen.insert(event.id).inserted,
                  event.actor.login.caseInsensitiveCompare(account.login) == .orderedSame else { return nil }
            return event.activity
        }
        let titles = pullRequestTitles(for: activities, options: options, directory: directory)
        for index in activities.indices where activities[index].isPullRequest && activities[index].title.isEmpty {
            let event = activities[index]
            if let number = event.number, let title = titles[event.repository]?[number] {
                activities[index].title = title
            }
        }

        // Visibility filtering can leave fewer than 300 entries even with a full final page.
        let reachedLimit = events.count >= 300 || (pages.count >= 3 && pages.last?.count == 100)
        // At the cap, sibling events at the oldest timestamp may be missing.
        let cutoff = reachedLimit ? events.map(\.createdAt).min()?.addingTimeInterval(1) : nil
        let start = max(cutoff ?? .distantPast, received.addingTimeInterval(-GitHubActivityHistory.retention))
        let end = started.addingTimeInterval(-GitHubActivityHistory.publicationDelay)
        let saved = try? store.record(accountID: account.id, events: activities, since: start, through: end)
        var history = saved?.history ?? GitHubActivityHistory()
        if saved == nil { history.record(activities, since: start, through: end) }
        return .success(GitHubActivityFeed(login: account.login, history: history, status: saved?.saved == true ? .current : .unsaved))
    }

    /// The events feed can omit PR titles. Ask for each missing title once, across repositories.
    private static func pullRequestTitles(for activities: [GitHubActivity], options: [String],
                                          directory: URL) -> [String: [Int: String]] {
        var missing: [String: Set<Int>] = [:]
        var titles: [String: [Int: String]] = [:]
        for event in activities where event.isPullRequest {
            guard let number = event.number else { continue }
            if event.title.isEmpty {
                missing[event.repository, default: []].insert(number)
            } else {
                titles[event.repository, default: [:]][number] = event.title
            }
        }

        var fields: [String] = []
        var repositories: [String: String] = [:]
        var arguments = options + ["graphql"]
        var variables: [String] = []
        for (repository, numbers) in missing.sorted(by: { $0.key < $1.key }) {
            let path = repository.split(separator: "/")
            guard path.count == 2 else { continue }
            let unresolved = numbers.filter { titles[repository]?[$0] == nil }
            guard !unresolved.isEmpty else { continue }
            let index = fields.count
            let alias = "repo\(index)"
            repositories[alias] = repository
            variables += ["$owner\(index): String!", "$name\(index): String!"]
            arguments += ["-f", "owner\(index)=\(path[0])", "-f", "name\(index)=\(path[1])"]
            let pulls = unresolved.sorted().map { "pr\($0): pullRequest(number: \($0)) { number title }" }
            fields.append("\(alias): repository(owner: $owner\(index), name: $name\(index)) { \(pulls.joined(separator: " ")) }")
        }
        guard !fields.isEmpty else { return titles }

        struct Title: Decodable { let number: Int; let title: String }
        struct Response: Decodable { let data: [String: [String: Title?]?] }
        let query = "query(\(variables.joined(separator: ", "))) { \(fields.joined(separator: " ")) }"
        // GitHub may return usable titles alongside errors for inaccessible or deleted repositories.
        guard let data = gh(arguments + ["-f", "query=\(query)"], in: directory, allowPartialOutput: true),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return titles }
        for (alias, pulls) in response.data {
            guard let repository = repositories[alias], let pulls else { continue }
            for case let title? in pulls.values {
                titles[repository, default: [:]][title.number] = title.title
            }
        }
        return titles
    }
}

private struct ActivityEvent: Decodable {
    struct Repository: Decodable { let name: String }
    struct Item: Decodable {
        let number: Int?
        let title: String?
        let htmlUrl: String?
        let merged: Bool?
    }

    struct Payload: Decodable {
        let action: String?
        let issue: Item?
        let pullRequest: Item?
        let review: Item?
        let comment: Item?
        let number: Int?
        let ref: String?
    }

    let id: String
    let type: String
    let actor: PullRequest.Author
    let repo: Repository
    let createdAt: Date
    let payload: Payload?

    var activity: GitHubActivity? {
        guard let payload else { return nil }
        let kind: GitHubActivity.Kind
        let item: Item?
        var destination: String?
        switch (type, payload.action) {
        case ("IssuesEvent", "opened"): kind = .issueOpened; item = payload.issue
        case ("IssuesEvent", "closed"): kind = .issueClosed; item = payload.issue
        case ("IssuesEvent", "reopened"): kind = .issueReopened; item = payload.issue
        case ("PullRequestEvent", "opened"): kind = .pullOpened; item = payload.pullRequest
        case ("PullRequestEvent", "closed"):
            kind = payload.pullRequest?.merged == true ? .pullMerged : .pullClosed
            item = payload.pullRequest
        case ("PullRequestEvent", "merged"): kind = .pullMerged; item = payload.pullRequest
        case ("PullRequestEvent", "reopened"): kind = .pullReopened; item = payload.pullRequest
        case ("PullRequestReviewEvent", "created"), ("PullRequestReviewEvent", "submitted"):
            kind = .review; item = payload.pullRequest; destination = payload.review?.htmlUrl
        case ("IssueCommentEvent", "created"), ("PullRequestReviewCommentEvent", "created"):
            kind = .comment; item = payload.issue ?? payload.pullRequest; destination = payload.comment?.htmlUrl
        case ("PushEvent", _): kind = .push; item = nil
        default: return nil
        }

        let number = kind == .push ? nil : (item?.number ?? payload.number)
        let isPullRequest = type.hasPrefix("PullRequest")
        let ref = payload.ref
        let title = item?.title ?? ref.map { $0.replacingOccurrences(of: #"^refs/(heads|tags)/"#, with: "", options: .regularExpression) } ?? ""
        let repositoryURL = URL(string: "https://github.com")?.appendingPathComponent(repo.name)
        let itemURL = number.flatMap { number in
            repositoryURL?.appendingPathComponent(isPullRequest ? "pull/\(number)" : "issues/\(number)")
        }
        let url = [destination, item?.htmlUrl].compactMap { $0.flatMap(URL.init(string:)) }
            .first { $0.scheme == "https" && $0.host == "github.com" }
        return GitHubActivity(id: id, kind: kind, date: createdAt, repository: repo.name, title: title,
                              number: number, isPullRequest: isPullRequest, url: url ?? itemURL ?? repositoryURL)
    }
}
