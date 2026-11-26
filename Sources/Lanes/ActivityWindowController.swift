import AppKit

private extension GitHubActivity.Group {
    var name: String {
        switch self {
        case .issues: return String(localized: "Issues")
        case .pullRequests: return String(localized: "PRs")
        case .reviews: return String(localized: "Reviews")
        case .comments: return String(localized: "Comments")
        case .pushes: return String(localized: "Pushes")
        }
    }

    var color: NSColor {
        switch self {
        case .issues: return .systemGreen
        case .pullRequests: return .systemPurple
        case .reviews: return .systemBlue
        case .comments: return .systemOrange
        case .pushes: return .systemTeal
        }
    }
}

private extension GitHubActivity.Kind {
    var name: String {
        switch self {
        case .issueOpened: return String(localized: "Opened issue")
        case .issueClosed: return String(localized: "Closed issue")
        case .issueReopened: return String(localized: "Reopened issue")
        case .pullOpened: return String(localized: "Opened pull request")
        case .pullClosed: return String(localized: "Closed pull request")
        case .pullMerged: return String(localized: "Merged pull request")
        case .pullReopened: return String(localized: "Reopened pull request")
        case .review: return String(localized: "Submitted review")
        case .comment: return String(localized: "Posted comment")
        case .push: return String(localized: "Pushed changes")
        }
    }

    var symbol: String {
        switch self {
        case .issueOpened, .issueReopened: return "exclamationmark.circle"
        case .issueClosed: return "checkmark.circle"
        case .pullOpened, .pullReopened: return "arrow.triangle.branch"
        case .pullClosed: return "xmark"
        case .pullMerged: return "arrow.triangle.merge"
        case .review: return "checkmark.bubble"
        case .comment: return "bubble"
        case .push: return "arrow.up"
        }
    }

    var color: NSColor {
        switch self {
        case .issueClosed, .pullClosed: return .secondaryLabelColor
        default: return group.color
        }
    }
}

private extension ActivityComparison.Period.Level {
    var color: NSColor? {
        switch self {
        case .higher: return .systemRed
        case .lower: return .systemBlue
        case .usual, .unconfirmed: return nil
        }
    }
}

private extension ActivityComparison.Period {
    var backgroundTint: NSColor? { level.color?.withAlphaComponent(complete ? 0.15 : 0.09) }

    var formattedAverage: String { average.formatted(.number.precision(.fractionLength(0...1))) }
}

@MainActor
private final class ActivityWindow: NSWindow {
    var moveDay: ((Int) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        if event.type == .keyDown, event.modifierFlags.intersection(modifiers).isEmpty, let moveDay {
            switch event.keyCode {
            case 123: moveDay(-1); return
            case 124: moveDay(1); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ActivityWindowController: NSWindowController {
    private let account = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let today = NSButton()
    private let refresh = NSButton()
    private let scroll = NSScrollView()
    private let content = NSStackView()
    private let notice = NSTextField(labelWithString: "")
    private let calendar = Calendar.autoupdatingCurrent
    private var day = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    private var feed: GitHubActivityFeed?
    private var error: GitHubActivityError?
    private var request = 0
    private var loading = false

    init() {
        let window = ActivityWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "GitHub Activity")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 610, height: 440)
        super.init(window: window)
        window.moveDay = { [weak self] offset in
            guard let self, (offset < 0 ? self.previous.isEnabled : self.next.isEnabled) else { return }
            self.stepDay(by: offset)
        }
        setUp(window)
        window.center()
        window.setFrameAutosaveName("GitHubActivityWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        if !wasVisible && !loading {
            day = calendar.startOfDay(for: Date())
            reload(nil)
        }
    }

    @objc func reload(_ sender: Any?) {
        guard !loading else { return }
        loading = true
        request += 1
        let token = request
        // Resolve the active account on each reload, including after a gh auth switch.
        feed = nil
        error = nil
        render(resetScroll: true)
        Task.detached { [weak self] in
            let result = GitHub.activityFeed()
            await MainActor.run { [weak self] in
                guard let self, self.request == token else { return }
                self.loading = false
                switch result {
                case .success(let feed): self.feed = feed
                case .failure(let error): self.error = error
                }
                self.render(resetScroll: true)
            }
        }
    }

    private func setUp(_ window: NSWindow) {
        let viewport = ActivityViewport(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = viewport
        let root = viewport.content

        account.font = .systemFont(ofSize: 12, weight: .medium)
        account.textColor = .secondaryLabelColor
        dateLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        let heading = stack(.vertical, spacing: 4, [account, dateLabel])
        heading.alignment = .leading

        configure(previous, symbol: "chevron.left", label: String(localized: "Previous day"), action: #selector(previousDay))
        configure(next, symbol: "chevron.right", label: String(localized: "Next day"), action: #selector(nextDay))
        previous.toolTip = "\(String(localized: "Previous day")) (←)"
        next.toolTip = "\(String(localized: "Next day")) (→)"
        configure(refresh, symbol: "arrow.clockwise", label: String(localized: "Reload"), action: #selector(reload(_:)))
        today.title = String(localized: "Today")
        today.bezelStyle = .rounded
        today.target = self
        today.action = #selector(goToToday)
        let buttons = stack(.horizontal, spacing: 7, [previous, today, next, refresh])
        let header = stack(.horizontal, spacing: 12, [heading, NSView(), buttons])
        header.alignment = .centerY

        let separator = NSBox()
        separator.boxType = .separator
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = ActivityDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        notice.font = .systemFont(ofSize: 10)
        notice.textColor = .secondaryLabelColor
        notice.lineBreakMode = .byTruncatingTail
        let inset: CGFloat = 28
        for view in [header, separator, scroll, notice] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 17),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -7),
            notice.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            notice.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])
        render(resetScroll: false)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func previousDay() { stepDay(by: -1) }

    @objc private func nextDay() { stepDay(by: 1) }

    private func stepDay(by offset: Int) {
        if let date = calendar.date(byAdding: .day, value: offset, to: day) { changeDay(to: date) }
    }

    @objc private func goToToday() { changeDay(to: Date()) }

    private func changeDay(to date: Date) {
        day = calendar.startOfDay(for: date)
        render(resetScroll: false)
    }

    private func render(resetScroll: Bool) {
        let now = Date()
        let current = calendar.startOfDay(for: now)
        let earliest = min(current, feed?.history.earliestDate.map { calendar.startOfDay(for: $0) } ?? current)
        // During a reload, keep the selected date until the new feed tells us the available range.
        day = min(calendar.startOfDay(for: day), current)
        if feed != nil { day = max(day, earliest) }

        dateLabel.stringValue = day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        account.stringValue = feed.map { "@\($0.login) · github.com" } ?? "github.com"
        previous.isEnabled = feed != nil && day > earliest
        next.isEnabled = feed != nil && day < current
        today.isEnabled = day < current
        refresh.isEnabled = !loading
        notice.stringValue = String(localized: "GitHub Events · Up to 300 events from the last 30 days · May appear up to 6 hours late")

        let previousOrigin = scroll.contentView.bounds.origin
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if loading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let progress = stack(.horizontal, spacing: 9, [spinner, label(String(localized: "Loading…"), size: 13)])
            add(progress)
        } else if let error {
            render(error)
        } else if let feed {
            let events = feed.history.events.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let comparison = ActivityComparison(day: day, events: events, history: feed.history, calendar: calendar, now: now)
            let summary = DailyActivitySummary(events: events, comparison: comparison)
            add(summary)
            content.setCustomSpacing(15, after: summary)
            let fullDay = calendar.dateInterval(of: .day, for: day).map(feed.history.covers) ?? false
            switch feed.status {
            case .cached:
                notice.stringValue = String(localized: "GitHub unavailable · Showing saved activity")
            case .unsaved:
                notice.stringValue = String(localized: "Couldn’t save activity to this Mac.")
            case .current where !fullDay && day < current:
                notice.stringValue = String(localized: "Saved activity for this day may be incomplete.")
            case .current: break
            }
            add(ActivityTimeline(events: events, calendar: calendar, comparison: comparison,
                                 complete: fullDay))
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        let origin = resetScroll ? NSPoint.zero : previousOrigin
        var visibleRect = scroll.contentView.bounds
        visibleRect.origin = origin
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(visibleRect).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func render(_ error: GitHubActivityError) {
        let title: String
        let message: String
        switch error {
        case .missingCLI:
            title = String(localized: "GitHub CLI is required")
            message = String(localized: "Install GitHub CLI, then run gh auth login --hostname github.com in Terminal and reload.")
        case .accountUnavailable:
            title = String(localized: "Couldn’t load your GitHub account")
            message = String(localized: "Check your connection and run gh auth status --hostname github.com in Terminal. To sign in, run gh auth login --hostname github.com, then reload.")
        case .eventsUnavailable:
            title = String(localized: "Couldn’t load GitHub activity")
            message = String(localized: "Check your connection and reload to try again.")
        }
        let heading = label(title, size: 16, weight: .semibold)
        add(heading)
        content.setCustomSpacing(6, after: heading)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = true
        add(detail)
    }

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
}

/// The window sets the available size. Changing the document's preferred size must not resize the window.
private final class ActivityViewport: NSView {
    let content = NSView()
    private lazy var width = content.widthAnchor.constraint(equalToConstant: bounds.width)
    private lazy var height = content.heightAnchor.constraint(equalToConstant: bounds.height)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.frame = bounds
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([width, height])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        width.constant = bounds.width
        height.constant = bounds.height
        content.frame = bounds
    }
}

private final class ActivityDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, _ views: [NSView]) -> NSStackView {
    let result = NSStackView(views: views)
    result.orientation = orientation
    result.spacing = spacing
    result.detachesHiddenViews = true
    return result
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let result = NSTextField(labelWithString: text)
    result.font = .systemFont(ofSize: size, weight: weight)
    result.textColor = color
    result.lineBreakMode = .byTruncatingTail
    return result
}

@MainActor
private final class DailyActivitySummary: NSView {
    init(events: [GitHubActivity], comparison: ActivityComparison) {
        super.init(frame: .zero)
        let total = label(events.count.formatted(), size: 32, weight: .semibold,
                          color: comparison.daily?.level.color ?? .labelColor)
        total.setAccessibilityLabel(String(localized: "\(events.count) activities"))
        let caption = label(String(localized: "Activities"), size: 12, color: .secondaryLabelColor)
        let count = stack(.vertical, spacing: 1, [total, caption])
        count.alignment = .leading
        count.widthAnchor.constraint(equalToConstant: 71).isActive = true
        let totals = Dictionary(grouping: events, by: { $0.kind.group }).mapValues(\.count)
        let breakdown = stack(.horizontal, spacing: 9, GitHubActivity.Group.allCases.map { group in
            let count = totals[group, default: 0]
            let number = label(count.formatted(), size: 15, weight: .semibold)
            number.textColor = count == 0 ? .secondaryLabelColor : .labelColor
            let name = label(group.name, size: 11, color: .secondaryLabelColor)
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            dot.contentTintColor = group.color
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            let category = stack(.horizontal, spacing: 5, [dot, name])
            category.alignment = .centerY
            let tile = stack(.vertical, spacing: 4, [number, category])
            tile.alignment = .leading
            tile.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 8
            tile.layer?.backgroundColor = group.color.withAlphaComponent(0.09).cgColor
            return tile
        })
        breakdown.distribution = .fillEqually
        let overview = stack(.horizontal, spacing: 12, [count, breakdown])
        overview.alignment = .centerY
        overview.distribution = .fill

        let comparisonText: String
        if let daily = comparison.daily {
            let days = comparison.sampleDays
            let average = daily.formattedAverage
            comparisonText = daily.complete
                ? String(localized: "Daily average \(average) · \(days) days")
                : String(localized: "Daily average \(average) · \(days) days · Provisional")
        } else if comparison.sampleDays < ActivityComparison.minimumDays {
            let days = comparison.sampleDays
            let minimum = ActivityComparison.minimumDays
            comparisonText = String(localized: "Comparison days \(days) of \(minimum) needed")
        } else {
            comparisonText = String(localized: "No baseline on clock-change days")
        }
        let baseline = label(comparisonText, size: 11, color: .secondaryLabelColor)
        if comparison.daily != nil && comparison.followingDays > 0 {
            let days = comparison.followingDays
            let detail = days == 1 ? String(localized: "Includes 1 completed day after the selected date.")
                : String(localized: "Includes \(days) completed days after the selected date.")
            baseline.toolTip = comparisonText + "\n" + detail
        } else {
            baseline.toolTip = comparisonText
        }
        let legend = stack(.horizontal, spacing: 10, [
            Self.key(String(localized: "Above average"), color: .systemRed),
            Self.key(String(localized: "Below average"), color: .systemBlue)
        ])
        legend.setContentHuggingPriority(.required, for: .horizontal)
        let footer = stack(.horizontal, spacing: 8, [baseline, NSView(), legend])
        footer.alignment = .centerY

        let body = stack(.vertical, spacing: 9, [overview, footer])
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            overview.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor),
            breakdown.trailingAnchor.constraint(equalTo: overview.trailingAnchor),
            legend.trailingAnchor.constraint(equalTo: footer.trailingAnchor)
        ])
    }

    private static func key(_ title: String, color: NSColor) -> NSView {
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.withAlphaComponent(0.32).cgColor
        swatch.layer?.cornerRadius = 3
        swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let key = stack(.horizontal, spacing: 4, [swatch, label(title, size: 11, color: .secondaryLabelColor)])
        key.alignment = .centerY
        return key
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.stroke()
    }
}

@MainActor
private final class ActivityTimeline: NSView {
    init(events: [GitHubActivity], calendar: Calendar, comparison: ActivityComparison, complete: Bool) {
        super.init(frame: .zero)
        let stream = ActivityStreamView(events: events, calendar: calendar, complete: complete)
        let day = DayTimelineView(events: events, calendar: calendar, comparison: comparison) { [weak stream] hour in
            stream?.jump(to: hour)
        }
        let timelineHeading = label(String(localized: "Timeline"), size: 16, weight: .semibold)
        let eventsHeading = label(String(localized: "Events"), size: 16, weight: .semibold)
        let hint = label(String(localized: "Click an hour to jump to its events."), size: 11, color: .secondaryLabelColor)
        hint.isHidden = events.isEmpty
        for child in [timelineHeading, eventsHeading, hint, day, stream] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            timelineHeading.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineHeading.topAnchor.constraint(equalTo: topAnchor),
            eventsHeading.leadingAnchor.constraint(equalTo: stream.leadingAnchor),
            eventsHeading.firstBaselineAnchor.constraint(equalTo: timelineHeading.firstBaselineAnchor),
            hint.firstBaselineAnchor.constraint(equalTo: eventsHeading.firstBaselineAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: eventsHeading.trailingAnchor, constant: 8),
            day.leadingAnchor.constraint(equalTo: leadingAnchor),
            day.topAnchor.constraint(equalTo: timelineHeading.bottomAnchor, constant: 7),
            day.bottomAnchor.constraint(equalTo: bottomAnchor),
            day.widthAnchor.constraint(equalTo: stream.widthAnchor),
            stream.leadingAnchor.constraint(equalTo: day.trailingAnchor, constant: 12),
            stream.trailingAnchor.constraint(equalTo: trailingAnchor),
            stream.topAnchor.constraint(equalTo: day.topAnchor),
            stream.bottomAnchor.constraint(equalTo: day.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class DayTimelineView: NSView, NSViewToolTipOwner {
    private struct Marker {
        let event: GitHubActivity
        let minute: Double
    }

    private static let railX: CGFloat = 57
    private static let inset: CGFloat = 12
    private static let hourHeight: CGFloat = 22
    private static let dayHeight = hourHeight * 24 + inset * 2
    private static let countWidth: CGFloat = 50
    private let hours: [[Marker]]
    private let comparison: ActivityComparison
    private var tips: [NSView.ToolTipTag: Int] = [:]
    private let onSelectHour: (Int) -> Void
    private var selectedHour: Int?

    override var isFlipped: Bool { true }

    init(events: [GitHubActivity], calendar: Calendar, comparison: ActivityComparison,
         onSelectHour: @escaping (Int) -> Void) {
        self.comparison = comparison
        self.onSelectHour = onSelectHour
        var hours = Array(repeating: [Marker](), count: 24)
        for event in events {
            let time = calendar.dateComponents([.hour, .minute, .second], from: event.date)
            guard let hour = time.hour, let minute = time.minute, let second = time.second else { continue }
            hours[hour].append(Marker(event: event, minute: Double(minute) + Double(second) / 60))
        }
        self.hours = hours
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: Self.dayHeight).isActive = true
        setAccessibilityElement(false)

        for (hour, markers) in hours.enumerated() where !markers.isEmpty {
            let count = markers.count
            let button = NSButton(title: "\(count.formatted())  ›", target: self, action: #selector(selectHour(_:)))
            button.tag = hour
            button.isBordered = false
            button.alignment = .right
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .controlAccentColor
            button.toolTip = hourDescription(hour)
            button.setAccessibilityLabel(button.toolTip)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.railX),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                button.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset + CGFloat(hour) * Self.hourHeight),
                button.heightAnchor.constraint(equalToConstant: Self.hourHeight)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func tick(_ hour: Int) -> String {
        "\(hour.formatted(.number.precision(.integerLength(2)))):00"
    }

    private func hourDescription(_ hour: Int) -> String {
        let time = "\(Self.tick(hour))–\(Self.tick(hour + 1))"
        let count = hours[hour].count
        let countLabel = count == 1 ? String(localized: "1 activity") : String(localized: "\(count) activities")
        var parts = [time, countLabel]
        if let period = comparison.hours[hour] {
            let average = period.formattedAverage
            parts.append(String(localized: "Average \(average)"))
            if !period.complete { parts.append(String(localized: "Provisional")) }
        }
        return parts.joined(separator: " · ")
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        tips.removeAll()
        for hour in hours.indices where hours[hour].isEmpty && comparison.hours[hour] != nil {
            let tag = addToolTip(NSRect(x: Self.railX, y: Self.inset + CGFloat(hour) * Self.hourHeight,
                                       width: bounds.width - Self.railX, height: Self.hourHeight),
                                 owner: self, userData: nil)
            tips[tag] = hour
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData: UnsafeMutableRawPointer?) -> String {
        tips[tag].map(hourDescription) ?? ""
    }

    @objc private func selectHour(_ sender: NSButton) {
        selectedHour = sender.tag
        needsDisplay = true
        onSelectHour(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.stroke()

        let rail = Self.railX
        for (hour, period) in comparison.hours.enumerated() {
            guard let tint = period?.backgroundTint else { continue }
            let y = Self.inset + CGFloat(hour) * Self.hourHeight
            tint.setFill()
            NSBezierPath(rect: NSRect(x: rail, y: y, width: bounds.width - rail - 5,
                                      height: Self.hourHeight)).fill()
        }
        if let selectedHour {
            let y = Self.inset + CGFloat(selectedHour) * Self.hourHeight
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: NSRect(x: rail - 4, y: y + 1, width: bounds.width - rail - 4,
                                            height: Self.hourHeight - 2), xRadius: 5, yRadius: 5).fill()
        }
        let left = rail + 12
        let right = bounds.maxX - Self.countWidth
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: rail, y: Self.inset))
        grid.line(to: NSPoint(x: rail, y: Self.inset + Self.hourHeight * 24))
        let tickStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for hour in 0...24 {
            let y = Self.inset + CGFloat(hour) * Self.hourHeight
            grid.move(to: NSPoint(x: rail - 4, y: y))
            grid.line(to: NSPoint(x: right, y: y))
            if hour.isMultiple(of: 3) {
                let tick = NSAttributedString(string: Self.tick(hour), attributes: tickStyle)
                let size = tick.size()
                tick.draw(at: NSPoint(x: rail - 10 - size.width, y: y - size.height / 2))
            }
        }
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()

        for (hour, markers) in hours.enumerated() where !markers.isEmpty {
            // Use the same spacing across days. Compress exceptionally busy hours to keep every mark in view.
            let step = min(9, max(0, right - left - 4) / CGFloat(max(1, markers.count - 1)))
            for (index, marker) in markers.enumerated() {
                let x = left + CGFloat(index) * step
                let y = Self.inset + (CGFloat(hour) + marker.minute / 60) * Self.hourHeight
                marker.event.kind.group.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
            }
        }
    }
}

@MainActor
private final class ActivityStreamView: NSView {
    private let scroll = NSScrollView()
    private let document = ActivityDocumentView()
    private var firstRowByHour: [Int: ActivityRow] = [:]
    private weak var highlighted: ActivityRow?

    init(events: [GitHubActivity], calendar: Calendar, complete: Bool) {
        super.init(frame: .zero)
        if events.isEmpty {
            let message = complete ? String(localized: "No tracked activity for this day.")
                : String(localized: "No events received for this day.")
            let empty = NSTextField(wrappingLabelWithString: message)
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerYAnchor.constraint(equalTo: centerYAnchor),
                empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
            ])
            return
        }

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let rows = stack(.vertical, spacing: 0, events.map { event in
            let row = ActivityRow(event: event)
            let hour = calendar.component(.hour, from: event.date)
            if firstRowByHour[hour] == nil { firstRowByHour[hour] = row }
            return row
        })
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        for row in rows.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func jump(to hour: Int) {
        guard let row = firstRowByHour[hour] else { return }
        highlighted?.isHighlighted = false
        row.isHighlighted = true
        highlighted = row
        layoutSubtreeIfNeeded()

        let clip = scroll.contentView
        var target = clip.bounds
        target.origin.y = row.convert(row.bounds, to: document).minY
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.stroke()
    }
}

@MainActor
private final class ActivityRow: NSView {
    private let event: GitHubActivity
    var isHighlighted = false { didSet { needsDisplay = true } }

    init(event: GitHubActivity) {
        self.event = event
        super.init(frame: .zero)
        let time = label(event.date.formatted(.dateTime.hour().minute()), size: 11, color: .secondaryLabelColor)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.alignment = .right
        let symbol = NSImage(systemSymbolName: event.kind.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!
        let icon = NSImageView(image: symbol)
        icon.contentTintColor = event.kind.color
        let action = event.title.isEmpty ? nil : event.kind.name
        let metadata = [action, event.repository, event.reference].compactMap { $0 }.joined(separator: "  ·  ")
        let title = label(event.title.isEmpty ? event.kind.name : event.title, size: 13, weight: .semibold)
        title.toolTip = title.stringValue
        let subtitle = label(metadata, size: 11, color: .secondaryLabelColor)
        subtitle.toolTip = metadata
        let text = stack(.vertical, spacing: 3, [title, subtitle])
        text.alignment = .leading
        let link = NSButton()
        link.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: String(localized: "Open on GitHub"))
        link.bezelStyle = .accessoryBarAction
        link.isBordered = false
        link.contentTintColor = .secondaryLabelColor
        link.toolTip = String(localized: "Open on GitHub")
        link.setAccessibilityLabel(String(localized: "Open on GitHub"))
        link.target = self
        link.action = #selector(openEvent)
        link.isEnabled = event.url != nil
        for view in [time, icon, text, link] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            time.widthAnchor.constraint(equalToConstant: 51),
            time.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 69),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),
            text.trailingAnchor.constraint(equalTo: link.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalTo: text.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: text.widthAnchor),
            link.centerYAnchor.constraint(equalTo: centerYAnchor),
            link.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            link.widthAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openEvent() {
        if let url = event.url { NSWorkspace.shared.open(url) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(rect: NSRect(x: 4, y: 0, width: bounds.width - 8, height: 0.5)).fill()
    }
}
