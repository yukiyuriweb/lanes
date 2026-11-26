import Darwin
import Foundation

struct GitHubActivityHistory: Codable {
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let publicationDelay: TimeInterval = 6 * 60 * 60
    private(set) var events: [GitHubActivity] = []
    private(set) var coverage: [DateInterval] = []

    var earliestDate: Date? {
        [events.first?.date, coverage.first?.start].compactMap { $0 }.min()
    }

    mutating func record(_ incoming: [GitHubActivity], since start: Date, through end: Date) {
        var byID: [String: GitHubActivity] = [:]
        for event in events { byID[event.id] = event }
        for event in incoming {
            var event = event
            if event.title.isEmpty, let previous = byID[event.id] { event.title = previous.title }
            byID[event.id] = event
        }
        events = byID.values.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }

        guard start < end else { return }
        let ranges = (coverage + [DateInterval(start: start, end: end)]).sorted { $0.start < $1.start }
        coverage = []
        for range in ranges {
            if let last = coverage.last, range.start <= last.end {
                coverage.removeLast()
                coverage.append(DateInterval(start: last.start, end: max(last.end, range.end)))
            } else {
                coverage.append(range)
            }
        }
    }

    func covers(_ interval: DateInterval) -> Bool {
        coverage.contains { $0.start <= interval.start && $0.end >= interval.end }
    }
}

struct ActivityComparison {
    static let referenceWindowDays = 28
    static let minimumDays = 5

    struct Period {
        enum Level { case higher, lower, usual, unconfirmed }
        let count: Int
        let average: Double
        let complete: Bool

        var level: Level {
            if Double(count) > average { return .higher }
            if !complete { return .unconfirmed }
            return Double(count) < average ? .lower : .usual
        }
    }

    let sampleDays: Int
    let followingDays: Int
    let daily: Period?
    let hours: [Period?]

    init(day: Date, events: [GitHubActivity], history: GitHubActivityHistory, calendar: Calendar, now: Date) {
        func completeDay(offset: Int) -> Date? {
            guard let date = calendar.date(byAdding: .day, value: offset, to: day),
                  let interval = calendar.dateInterval(of: .day, for: date),
                  interval.duration == 86400, interval.end <= now, history.covers(interval) else { return nil }
            return interval.start
        }

        var eligible = Set((1...Self.referenceWindowDays).compactMap { completeDay(offset: -$0) })
        let precedingDays = eligible.count
        if precedingDays < Self.minimumDays {
            for offset in 1...Self.referenceWindowDays {
                if let date = completeDay(offset: offset) { eligible.insert(date) }
                if eligible.count == Self.minimumDays { break }
            }
        }
        sampleDays = eligible.count
        followingDays = sampleDays - precedingDays
        guard sampleDays >= Self.minimumDays,
              let interval = calendar.dateInterval(of: .day, for: day),
              interval.duration == 86400 else {
            daily = nil
            hours = Array(repeating: nil, count: 24)
            return
        }

        var baseline = Array(repeating: 0, count: 24)
        let earliest = eligible.min() ?? day
        let latestEnd = (eligible.max() ?? day).addingTimeInterval(86400)
        for event in history.events where event.date >= earliest && event.date < latestEnd {
            if eligible.contains(calendar.startOfDay(for: event.date)) {
                baseline[calendar.component(.hour, from: event.date)] += 1
            }
        }
        let counts = Dictionary(grouping: events) { calendar.component(.hour, from: $0.date) }.mapValues(\.count)
        let samples = Double(sampleDays)
        daily = Period(count: events.count, average: Double(baseline.reduce(0, +)) / samples,
                       complete: history.covers(interval))
        hours = (0..<24).map { hour in
            let start = interval.start.addingTimeInterval(Double(hour) * 3600)
            guard start <= now else { return nil }
            let slice = DateInterval(start: start, duration: 3600)
            return Period(count: counts[hour, default: 0], average: Double(baseline[hour]) / samples,
                          complete: history.covers(slice))
        }
    }
}

/// Keeps the minimum metadata needed to display saved events. Each GitHub account has a private file.
struct GitHubActivityStore {
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Lanes/GitHub Activity")) {
        self.directory = directory
    }

    func load(accountID: Int64) throws -> GitHubActivityHistory {
        let file = directory.appending(path: "\(accountID).json")
        return try JSONDecoder().decode(GitHubActivityHistory.self, from: Data(contentsOf: file))
    }

    func record(accountID: Int64, events: [GitHubActivity], since start: Date, through end: Date) throws -> (history: GitHubActivityHistory, saved: Bool) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = directory.appending(path: "\(accountID).lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }

        var history: GitHubActivityHistory
        do {
            history = try load(accountID: accountID)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            history = GitHubActivityHistory()
        }
        history.record(events, since: start, through: end)
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: directory.appending(path: "\(accountID).json"), options: .atomic)
            return (history, true)
        } catch {
            return (history, false)
        }
    }
}
