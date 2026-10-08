import AppKit

private extension NSUserInterfaceItemIdentifier {
    static let graph = Self("graph")
    static let description = Self("description")
    static let date = Self("date")
    static let author = Self("author")
    static let hash = Self("hash")
    static let file = Self("file")
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let commitTable = NSTableView()
    private let fileTable = NSTableView()
    private let textView: NSTextView
    private let textScroll: NSScrollView
    private let mainSplit = NSSplitView()
    private let detailSplit = NSSplitView()

    private(set) var repo: URL?
    var onClose: (() -> Void)?
    private var commits: [Commit] = []
    private var rows: [GraphRow] = []
    private var files: [ChangedFile] = []
    /// Pull requests by the commit they're shown on (see `PullRequest.commitHash`).
    private var pullRequests: [String: [PullRequest]] = [:]
    /// The selected commit's pull requests, listed between "Commit Details" and the files.
    private var detailPRs: [PullRequest] = []
    /// What the detail list showed before a reload, so reloading the same commit returns to it.
    private enum DetailItem { case pullRequest(url: String), file(path: String) }
    private var restoreDetail: (hash: String, item: DetailItem)?
    /// Set when the user selects something in the detail list while it loads, so a restore doesn't override it.
    private var detailTouched = false
    private var summaryText = NSAttributedString()
    /// Bumped when the selected commit changes; guards loading its files and summary.
    private var detailToken = 0
    /// Bumped whenever the text pane is pointed at something else; guards diff loads.
    private var textToken = 0
    /// Bumped on each history reload, so an older reload can't overwrite a newer one.
    private var loadToken = 0
    /// Bumped on each pull request fetch, so an older fetch can't overwrite a newer one.
    private var prToken = 0

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    init() {
        textScroll = NSTextView.scrollableTextView()
        textView = textScroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lanes"
        // The controller owns the window; AppKit releasing it on close as well would over-release it.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setUpViews()
        window.center()
        // Only one window can own the autosave name; later ones are placed by the app delegate.
        window.setFrameAutosaveName("MainWindow")
        window.tabbingIdentifier = "Lanes"
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUpViews() {
        func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, flexible: Bool = false) {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = 30
            col.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            commitTable.addTableColumn(col)
        }
        addColumn(.graph, String(localized: "Graph"), width: 80)
        addColumn(.description, String(localized: "Description"), width: 600, flexible: true)
        addColumn(.date, String(localized: "Date"), width: 120)
        addColumn(.author, String(localized: "Author"), width: 130)
        addColumn(.hash, String(localized: "Commit"), width: 75)

        commitTable.style = .fullWidth
        commitTable.rowHeight = 22
        commitTable.intercellSpacing = .zero
        commitTable.usesAlternatingRowBackgroundColors = true
        commitTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        commitTable.dataSource = self
        commitTable.delegate = self

        let commitScroll = NSScrollView()
        commitScroll.documentView = commitTable
        commitScroll.hasVerticalScroller = true
        commitScroll.hasHorizontalScroller = true

        let fileCol = NSTableColumn(identifier: .file)
        fileCol.resizingMask = .autoresizingMask
        fileTable.addTableColumn(fileCol)
        fileTable.headerView = nil
        fileTable.style = .fullWidth
        fileTable.rowHeight = 20
        fileTable.dataSource = self
        fileTable.delegate = self

        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        // No wrapping: scroll horizontally like a diff viewer.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textScroll.hasHorizontalScroller = true

        detailSplit.isVertical = true
        detailSplit.dividerStyle = .thin
        detailSplit.addArrangedSubview(fileScroll)
        detailSplit.addArrangedSubview(textScroll)
        detailSplit.autosaveName = "DetailSplit"

        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(commitScroll)
        mainSplit.addArrangedSubview(detailSplit)
        mainSplit.autosaveName = "MainSplit"

        window?.contentView = mainSplit
        window?.layoutIfNeeded()
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil {
            mainSplit.setPosition(480, ofDividerAt: 0)
            detailSplit.setPosition(320, ofDividerAt: 0)
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: - Loading

    /// Shows the repository whose top-level directory is `top`.
    func show(_ top: URL) {
        repo = top
        window?.title = top.lastPathComponent
        window?.subtitle = top.path
        commits = []
        rows = []
        pullRequests = [:]
        commitTable.reloadData()
        reload()
    }

    @objc func reload(_ sender: Any? = nil) {
        guard let repo else { return }
        loadToken += 1
        let token = loadToken
        Task.detached {
            let commits = Git.log(in: repo, limit: 20000)
            let layout = GraphLayout.compute(commits)
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.apply(commits: commits, layout: layout)
            }
        }
        // Fetched separately so the graph never waits on the network.
        prToken += 1
        let prToken = prToken
        Task.detached {
            let prs = GitHub.pullRequests(in: repo)
            await MainActor.run {
                guard prToken == self.prToken, repo == self.repo else { return }
                self.apply(pullRequests: prs ?? [])
            }
        }
    }

    private func apply(pullRequests prs: [PullRequest]) {
        pullRequests = Dictionary(grouping: prs, by: \.commitHash)
        let col = commitTable.column(withIdentifier: .description)
        if col >= 0 { commitTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<commits.count), columnIndexes: [col]) }

        // Refresh the selected commit's PR rows, keeping the same file or PR selected.
        guard commitTable.selectedRow >= 0 else { return }
        let old = detailPRs
        detailPRs = pullRequests[commits[commitTable.selectedRow].hash] ?? []
        let selected = fileTable.selectedRow
        fileTable.reloadData()
        guard selected >= 0 else { return }   // details still loading; they select a row when done
        let row = selected > old.count ? selected - old.count + detailPRs.count   // a file
            : selected > detailPRs.count ? 0                                       // a PR that's gone
            : selected
        fileTable.selectRowIndexes([row], byExtendingSelection: false)
        // Selecting the same row again doesn't notify, so redraw an open PR with its new data here.
        if row == selected && row >= 1 && row <= detailPRs.count { showPullRequest(detailPRs[row - 1]) }
    }

    private func apply(commits: [Commit], layout: (rows: [GraphRow], width: Int)) {
        // Keep whatever is selected now (it may have changed since the reload started), along with its detail item.
        let hash = commitTable.selectedRow >= 0 && commitTable.selectedRow < self.commits.count
            ? self.commits[commitTable.selectedRow].hash : nil
        if let hash, let item = selectedDetailItem() { restoreDetail = (hash, item) }
        self.commits = commits
        self.rows = layout.rows
        if let col = commitTable.tableColumn(withIdentifier: .graph) {
            col.width = min(CGFloat(layout.width) * laneWidth + laneInset, 400)
        }
        commitTable.reloadData()
        let index = hash.flatMap { h in commits.firstIndex { $0.hash == h } } ?? (commits.isEmpty ? nil : 0)
        if let index {
            commitTable.selectRowIndexes([index], byExtendingSelection: false)
            commitTable.scrollRowToVisible(index)
        } else {
            showDetails(nil)
        }
        // Reselecting the commit (synchronously) started reloading its details if needed; don't apply it later.
        restoreDetail = nil
        window?.makeFirstResponder(commitTable)
    }

    private func selectedDetailItem() -> DetailItem? {
        let row = fileTable.selectedRow
        if row >= 1 && row <= detailPRs.count { return .pullRequest(url: detailPRs[row - 1].url) }
        if row > detailPRs.count && row - 1 - detailPRs.count < files.count { return .file(path: files[row - 1 - detailPRs.count].path) }
        return nil
    }

    private func showDetails(_ commit: Commit?) {
        detailToken += 1
        textToken += 1
        let token = detailToken
        files = []
        detailPRs = []
        summaryText = NSAttributedString()
        fileTable.reloadData()
        fileTable.deselectAll(nil)
        detailTouched = false
        textView.string = ""
        guard let commit, let repo else { return }
        let restore = restoreDetail?.hash == commit.hash ? restoreDetail?.item : nil
        Task.detached {
            let files = Git.changedFiles(of: commit, in: repo)
            let summary = Git.summary(of: commit, in: repo)
            await MainActor.run {
                guard token == self.detailToken else { return }
                self.files = files
                self.detailPRs = self.pullRequests[commit.hash] ?? []
                self.summaryText = NSAttributedString(string: summary, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
                self.fileTable.reloadData()
                var row = 0
                switch self.detailTouched ? nil : restore {
                case .pullRequest(let url)?: row = self.detailPRs.firstIndex { $0.url == url }.map { $0 + 1 } ?? 0
                case .file(let path)?: row = self.files.firstIndex { $0.path == path }.map { $0 + 1 + self.detailPRs.count } ?? 0
                case nil: break
                }
                // "Commit Details" may already be selected (clicked while loading), in which case no selection change fires.
                let changes = self.fileTable.selectedRow != row
                self.fileTable.selectRowIndexes([row], byExtendingSelection: false)
                if !changes { self.showDetailRow(row) }
            }
        }
    }

    private func showFileDiff(_ file: ChangedFile) {
        guard let repo, commitTable.selectedRow >= 0 else { return }
        let commit = commits[commitTable.selectedRow]
        textToken += 1
        let token = textToken
        Task.detached {
            let diff = Git.diff(of: commit, file: file, in: repo)
            await MainActor.run {
                guard token == self.textToken else { return }
                self.setText(colorizeDiff(diff))
            }
        }
    }

    private func showPullRequest(_ pr: PullRequest) {
        textToken += 1
        setText(renderPullRequest(pr, dateFormatter: dateFormatter), wraps: true)
    }

    private func showSummary() {
        textToken += 1
        setText(summaryText)
    }

    /// Diffs and summaries scroll horizontally; prose (PR conversations) wraps to the pane's width.
    private func setText(_ text: NSAttributedString, wraps: Bool = false) {
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        if wraps {
            textView.frame.size.width = textScroll.contentSize.width
        } else {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.textStorage?.setAttributedString(text)
        textView.scroll(.zero)
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === commitTable ? commits.count : (commits.isEmpty ? 0 : 1 + detailPRs.count + files.count)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }

        if tableView === fileTable {
            let cell = tableView.makeView(withIdentifier: .file, owner: nil) as? NSTableCellView
                ?? makeTextCell(.file, font: .systemFont(ofSize: 12))
            if row == 0 {
                cell.textField?.attributedStringValue = NSAttributedString(
                    string: String(localized: "Commit Details"), attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            } else if row <= detailPRs.count {
                let pr = detailPRs[row - 1]
                cell.textField?.attributedStringValue = NSAttributedString(
                    string: String(localized: "Pull Request #\(pr.number)"),
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: prColor(pr)])
                cell.toolTip = pr.title
            } else {
                let f = files[row - 1 - detailPRs.count]
                let s = NSMutableAttributedString(string: f.status + "  ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: statusColor(f.status),
                ])
                let name = f.oldPath.map { "\($0) → \(f.path)" } ?? f.path
                s.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                cell.textField?.attributedStringValue = s
                cell.toolTip = name
            }
            return cell
        }

        let commit = commits[row]
        switch id {
        case .graph:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? GraphCellView ?? {
                let c = GraphCellView()
                c.identifier = id
                return c
            }()
            cell.row = rows[row]
            return cell
        case .description:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DescriptionCellView ?? {
                let c = DescriptionCellView()
                c.identifier = id
                return c
            }()
            cell.color = Palette.color(rows[row].color)
            cell.commit = commit
            cell.pullRequests = pullRequests[commit.hash] ?? []
            cell.toolTip = commit.subject
            return cell
        default:
            let font: NSFont = id == .hash
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeTextCell(id, font: font)
            switch id {
            case .date: cell.textField?.stringValue = dateFormatter.string(from: commit.date)
            case .author:
                cell.textField?.stringValue = commit.author
                cell.toolTip = "\(commit.author) <\(commit.email)>"
            default: cell.textField?.stringValue = String(commit.hash.prefix(8))
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === commitTable {
            showDetails(table.selectedRow >= 0 ? commits[table.selectedRow] : nil)
        } else {
            if table.selectedRow >= 0 { detailTouched = true }
            showDetailRow(table.selectedRow)
        }
    }

    /// Shows a row of the detail list: the commit summary, a pull request, or a file's diff.
    private func showDetailRow(_ row: Int) {
        if row == 0 {
            showSummary()
        } else if row > 0 && row <= detailPRs.count {
            showPullRequest(detailPRs[row - 1])
        } else if row > 0 {
            showFileDiff(files[row - 1 - detailPRs.count])
        }
    }

    private func statusColor(_ status: String) -> NSColor {
        switch status {
        case "A": return .systemGreen
        case "D": return .systemRed
        case "R", "C": return .systemBlue
        default: return .systemOrange
        }
    }
}
