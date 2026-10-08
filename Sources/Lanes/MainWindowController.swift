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
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let commitTable = NSTableView()
    private let fileTable = NSTableView()
    private let textView: NSTextView
    private let textScroll: NSScrollView
    private let mainSplit = NSSplitView()
    private let detailSplit = NSSplitView()

    private(set) var repo: URL?
    private var commits: [Commit] = []
    private var rows: [GraphRow] = []
    private var files: [ChangedFile] = []
    private var summaryText = NSAttributedString()
    private var detailToken = 0

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
        super.init(window: window)
        setUpViews()
        window.center()
        window.setFrameAutosaveName("MainWindow")
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
        addColumn(.graph, "グラフ", width: 80)
        addColumn(.description, "説明", width: 600, flexible: true)
        addColumn(.date, "日付", width: 120)
        addColumn(.author, "作者", width: 130)
        addColumn(.hash, "コミット", width: 75)

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

    // MARK: - Loading

    func open(_ url: URL) {
        Task.detached {
            let top = Git.topLevel(of: url)
            await MainActor.run { self.didResolve(url, topLevel: top) }
        }
    }

    private func didResolve(_ url: URL, topLevel top: URL?) {
        guard let top else {
            let alert = NSAlert()
            alert.messageText = "Git リポジトリではありません"
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        repo = top
        UserDefaults.standard.set(top.path, forKey: "lastRepo")
        NSDocumentController.shared.noteNewRecentDocumentURL(top)
        window?.title = top.lastPathComponent
        window?.subtitle = top.path
        commits = []
        rows = []
        commitTable.reloadData()
        reload()
    }

    @objc func reload(_ sender: Any? = nil) {
        guard let repo else { return }
        let selectedHash = commitTable.selectedRow >= 0 && commitTable.selectedRow < commits.count
            ? commits[commitTable.selectedRow].hash : nil
        Task.detached {
            let commits = Git.log(in: repo, limit: 20000)
            let layout = GraphLayout.compute(commits)
            await MainActor.run {
                guard self.repo == repo else { return }
                self.apply(commits: commits, layout: layout, selecting: selectedHash)
            }
        }
    }

    private func apply(commits: [Commit], layout: (rows: [GraphRow], width: Int), selecting hash: String?) {
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
        window?.makeFirstResponder(commitTable)
    }

    private func showDetails(_ commit: Commit?) {
        detailToken += 1
        let token = detailToken
        files = []
        fileTable.reloadData()
        textView.string = ""
        guard let commit, let repo else { return }
        Task.detached {
            let files = Git.changedFiles(of: commit, in: repo)
            let summary = Git.summary(of: commit, in: repo)
            await MainActor.run {
                guard token == self.detailToken else { return }
                self.files = files
                self.summaryText = NSAttributedString(string: summary, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
                self.fileTable.reloadData()
                self.fileTable.selectRowIndexes([0], byExtendingSelection: false)
            }
        }
    }

    private func showFileDiff(_ file: ChangedFile) {
        guard let repo, commitTable.selectedRow >= 0 else { return }
        let commit = commits[commitTable.selectedRow]
        detailToken += 1
        let token = detailToken
        Task.detached {
            let diff = Git.diff(of: commit, file: file, in: repo)
            await MainActor.run {
                guard token == self.detailToken else { return }
                self.setText(colorizeDiff(diff))
            }
        }
    }

    private func showSummary() {
        detailToken += 1
        setText(summaryText)
    }

    private func setText(_ text: NSAttributedString) {
        textView.textStorage?.setAttributedString(text)
        textView.scroll(.zero)
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === commitTable ? commits.count : (commits.isEmpty ? 0 : files.count + 1)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }

        if tableView === fileTable {
            let cell = tableView.makeView(withIdentifier: .file, owner: nil) as? NSTableCellView
                ?? makeTextCell(.file, font: .systemFont(ofSize: 12))
            if row == 0 {
                cell.textField?.attributedStringValue = NSAttributedString(
                    string: "コミット詳細", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            } else {
                let f = files[row - 1]
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
        } else if table.selectedRow == 0 {
            showSummary()
        } else if table.selectedRow > 0 {
            showFileDiff(files[table.selectedRow - 1])
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
