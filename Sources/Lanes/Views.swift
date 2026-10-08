import AppKit

enum Palette {
    static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed,
        .systemTeal, .systemPink, .systemYellow, .systemBrown, .systemIndigo,
    ]
    static func color(_ i: Int) -> NSColor { colors[i % colors.count] }
}

let laneWidth: CGFloat = 14
let laneInset: CGFloat = 10

final class GraphCellView: NSTableCellView {
    var row: GraphRow? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let h = bounds.height, mid = h / 2
        func x(_ lane: Int) -> CGFloat { laneInset + CGFloat(lane) * laneWidth }

        for s in row.segments {
            let (x0, y0, x1, y1) = s.top ? (x(s.from), 0, x(s.to), mid) : (x(s.from), mid, x(s.to), h)
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: x0, y: y0))
            if x0 == x1 {
                path.line(to: NSPoint(x: x1, y: y1))
            } else {
                let ym = (y0 + y1) / 2
                path.curve(to: NSPoint(x: x1, y: y1),
                           controlPoint1: NSPoint(x: x0, y: ym),
                           controlPoint2: NSPoint(x: x1, y: ym))
            }
            Palette.color(s.color).setStroke()
            path.stroke()
        }

        let r: CGFloat = 4
        let dot = NSBezierPath(ovalIn: NSRect(x: x(row.column) - r, y: mid - r, width: r * 2, height: r * 2))
        let color = Palette.color(row.color)
        if row.isMerge {
            NSColor.textBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = 2
            color.setStroke()
            dot.stroke()
        } else {
            color.setFill()
            dot.fill()
        }
    }
}

final class DescriptionCellView: NSTableCellView {
    var commit: Commit? { didSet { needsDisplay = true } }
    var pullRequests: [PullRequest] = [] { didSet { needsDisplay = true } }
    /// URLs of the PRs with activity the user hasn't opened; their badges get a dot.
    var unread: Set<String> = [] { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue

    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let textColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        var x: CGFloat = 4
        let pillHeight: CGFloat = 16

        for pr in pullRequests {
            var text = "#\(pr.number)"
            switch pr.verdict {
            case "APPROVED": text += " ✓"
            case "CHANGES_REQUESTED": text += " ±"
            default: break
            }
            // Merged PRs often keep threads nobody marked resolved, so only count them while open.
            if pr.state == "OPEN", pr.unresolvedThreads > 0 || pr.reviewThreads.hidden > 0 {
                // Threads beyond the first page aren't fetched, so the count is then a lower bound.
                text += " 💬\(pr.unresolvedThreads)" + (pr.reviewThreads.hidden > 0 ? "+" : "")
            }
            let label = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: textColor])
            let size = label.size()
            let dot: CGFloat = unread.contains(pr.url) ? 10 : 0
            let rect = NSRect(x: x, y: (bounds.height - pillHeight) / 2, width: ceil(size.width) + 10 + dot, height: pillHeight)
            let tint = prColor(pr)
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            tint.withAlphaComponent(0.25).setFill()
            pill.fill()
            tint.setStroke()
            pill.stroke()
            label.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + (pillHeight - size.height) / 2))
            if dot > 0 {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 12, y: rect.midY - 3.5, width: 7, height: 7)).fill()
            }
            x = rect.maxX + 4
        }

        for ref in commit.refs {
            let font = ref.isHead ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11)
            let label = NSAttributedString(string: ref.name, attributes: [.font: font, .foregroundColor: textColor])
            let size = label.size()
            let rect = NSRect(x: x, y: (bounds.height - pillHeight) / 2, width: ceil(size.width) + 10, height: pillHeight)
            let tint = ref.kind == .tag ? NSColor.systemGray : color
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if ref.kind != .remote {
                tint.withAlphaComponent(0.25).setFill()
                pill.fill()
            }
            tint.setStroke()
            pill.stroke()
            label.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + (pillHeight - size.height) / 2))
            x = rect.maxX + 4
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let subject = NSAttributedString(string: commit.subject, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: textColor, .paragraphStyle: para,
        ])
        let h = subject.size().height
        subject.draw(with: NSRect(x: x + 2, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - 4), height: h),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

func makeTextCell(_ id: NSUserInterfaceItemIdentifier, font: NSFont) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = id
    let tf = NSTextField(labelWithString: "")
    tf.font = font
    tf.lineBreakMode = .byTruncatingTail
    tf.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(tf)
    cell.textField = tf
    NSLayoutConstraint.activate([
        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
}

func colorizeDiff(_ text: String) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    let ns = text as NSString
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
        let line = ns.substring(with: NSRange(location: range.location, length: min(range.length, 4)))
        let color: NSColor?
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff") || line.hasPrefix("inde") {
            color = .secondaryLabelColor
        } else if line.hasPrefix("+") {
            color = .systemGreen
        } else if line.hasPrefix("-") {
            color = .systemRed
        } else if line.hasPrefix("@@") {
            color = .systemTeal
        } else {
            color = nil
        }
        if let color { result.addAttribute(.foregroundColor, value: color, range: range) }
    }
    return result
}

func prColor(_ pr: PullRequest) -> NSColor {
    if pr.isDraft { return .systemGray }
    switch pr.state {
    case "MERGED": return .systemPurple
    case "CLOSED": return .systemRed
    default: return .systemGreen
    }
}

func prStateName(_ pr: PullRequest) -> String {
    if pr.isDraft { return String(localized: "Draft") }
    switch pr.state {
    case "MERGED": return String(localized: "Merged")
    case "CLOSED": return String(localized: "Closed")
    default: return String(localized: "Open")
    }
}

/// The PR and its conversation as text: reviews and comments in time order, then the review threads.
/// The PR and its conversation as text: the description, reviews and comments in time order, then the review
/// threads. Each is a bordered card with a tinted header naming who wrote it, like on GitHub.
func renderPullRequest(_ pr: PullRequest, dateFormatter: DateFormatter) -> NSAttributedString {
    let body = NSFont.systemFont(ofSize: 12)
    let bold = NSFont.boldSystemFont(ofSize: 12)
    let result = NSMutableAttributedString()

    func line(_ parts: [(String, NSFont, NSColor, String?)], in boxes: [NSTextBlock] = [], spacing: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.textBlocks = boxes
        para.paragraphSpacing = spacing
        for (text, font, color, link) in parts {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            if let link { attrs[.link] = URL(string: link) }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        // The newline ends the paragraph, so it carries the same layout (and boxes) as its text.
        result.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para]))
    }
    func section(_ title: String) {
        gap()
        line([(title, .boldSystemFont(ofSize: 13), .labelColor, nil)], spacing: 8)
    }
    /// Space below a card; the table's own bottom margin isn't applied between adjacent tables.
    func gap() {
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
    }
    // A card is a one-column table: its header and each post or comment are rows. (Markdown tables inside
    // it can only nest in a table cell; inside a plain NSTextBlock AppKit throws while drawing them.)
    func card() -> NSTextTable {
        let t = NSTextTable()
        t.numberOfColumns = 1
        t.collapsesBorders = true
        t.setValue(100, type: .percentageValueType, for: .width)
        return t
    }
    func row(_ card: NSTextTable, _ index: Int, header: Bool = false) -> NSTextTableBlock {
        let b = NSTextTableBlock(table: card, startingRow: index, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        b.setWidth(1, type: .absoluteValueType, for: .border)
        b.setBorderColor(.separatorColor)
        b.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        b.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        b.setWidth(header ? 6 : 10, type: .absoluteValueType, for: .padding, edge: .minY)
        b.setWidth(header ? 6 : 10, type: .absoluteValueType, for: .padding, edge: .maxY)
        if header { b.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05) }
        return b
    }
    /// Who and when, in a card's header (or above a comment inside a thread card).
    func byline(_ who: PullRequest.Author?, _ what: (String, NSColor)?, _ date: Date?, in boxes: [NSTextBlock]) {
        var parts: [(String, NSFont, NSColor, String?)] = [(who?.login ?? "ghost", bold, .labelColor, nil)]
        if let what { parts.append(("  " + what.0, bold, what.1, nil)) }
        if let date { parts.append(("  " + dateFormatter.string(from: date), body, .secondaryLabelColor, nil)) }
        line(parts, in: boxes)
    }
    func markdown(_ s: String, in boxes: [NSTextBlock]) {
        let cleaned = plainText(s)
        guard !cleaned.isEmpty else { return }
        if let formatted = renderMarkdown(cleaned, font: body, container: boxes) {
            result.append(formatted)   // ends with its own newline, which carries the last block's layout
        } else {
            line([(cleaned, body, .labelColor, nil)], in: boxes)
        }
    }
    /// A card: a header line, then the body (if any).
    func post(_ who: PullRequest.Author?, _ what: (String, NSColor)?, _ date: Date?, _ text: String) {
        let c = card()
        byline(who, what, date, in: [row(c, 0, header: true)])
        if !plainText(text).isEmpty { markdown(text, in: [row(c, 1)]) }
        gap()
    }
    func more(_ n: Int) {
        if n > 0 { line([(String(localized: "\(n) more on GitHub"), body, .secondaryLabelColor, nil)], spacing: 12) }
    }

    line([("#\(pr.number) \(pr.title)", .boldSystemFont(ofSize: 16), .labelColor, nil)], spacing: 2)
    line([(prStateName(pr), bold, prColor(pr), nil),
          ("  \(pr.author?.login ?? "ghost") · \(pr.headRefName) → \(pr.baseRefName) · \(dateFormatter.string(from: pr.createdAt))  ", body, .secondaryLabelColor, nil),
          (String(localized: "Open on GitHub"), body, .linkColor, pr.url)], spacing: 12)
    post(pr.author, nil, pr.createdAt, pr.body)

    enum Item { case review(PullRequest.Review), comment(PullRequest.Comment) }
    let items: [(Date, Item)] =
        // Replying in a thread creates an empty COMMENTED review; its comment already shows under the thread.
        pr.reviews.nodes.filter { $0.state != "COMMENTED" || !plainText($0.body).isEmpty }
            .compactMap { r in r.submittedAt.map { ($0, .review(r)) } } +
        pr.comments.nodes.map { ($0.createdAt, .comment($0)) }
    if !items.isEmpty || pr.reviews.hidden + pr.comments.hidden > 0 { section(String(localized: "Conversation")) }
    more(pr.reviews.hidden + pr.comments.hidden)   // the oldest ones, since the query takes the latest
    for (date, item) in items.sorted(by: { $0.0 < $1.0 }) {
        switch item {
        case .review(let r):
            // A review with only inline comments has an empty body; its comments appear under the threads.
            post(r.author, reviewState(r.state), date, r.body)
        case .comment(let c):
            post(c.author, nil, date, c.body)
        }
    }

    let threads = pr.reviewThreads.nodes
    if !threads.isEmpty {
        let open = threads.filter { !$0.isResolved }.count
        section(String(localized: "Review Threads") + " (\(open)/\(pr.reviewThreads.totalCount ?? threads.count))")
    }
    for t in threads {
        let location = t.path + ((t.line ?? t.originalLine).map { ":\($0)" } ?? "")
        let c = card()
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        if t.isResolved {
            line([("✓ ", body, .secondaryLabelColor, nil), (location, mono, .secondaryLabelColor, nil),
                  ("  " + String(localized: "Resolved"), body, .secondaryLabelColor, nil)], in: [row(c, 0, header: true)])
            gap()
            continue
        }
        line([(location, mono, .labelColor, nil)], in: [row(c, 0, header: true)])
        for (i, comment) in t.comments.nodes.enumerated() {
            let cell = row(c, i + 1)
            byline(comment.author, nil, comment.createdAt, in: [cell])
            markdown(comment.body, in: [cell])
        }
        if t.comments.hidden > 0 {
            line([(String(localized: "\(t.comments.hidden) more on GitHub"), body, .secondaryLabelColor, nil)],
                 in: [row(c, t.comments.nodes.count + 1)])
        }
        gap()
    }
    more(pr.reviewThreads.hidden)
    return result
}

/// A review's verdict for its card header, colored like GitHub's.
private func reviewState(_ state: String) -> (String, NSColor) {
    switch state {
    case "APPROVED": return (String(localized: "Approved"), .systemGreen)
    case "CHANGES_REQUESTED": return (String(localized: "Changes requested"), .systemRed)
    case "DISMISSED": return (String(localized: "Dismissed"), .secondaryLabelColor)
    default: return (String(localized: "Reviewed"), .secondaryLabelColor)
    }
}

/// Comment bodies are Markdown with embedded HTML (bots use plenty); removes the HTML, leaving Markdown.
/// Code blocks and code spans are kept as written, so text like `Array<Foo>` survives.
private func plainText(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "\r\n", with: "\n")
    let code = try! NSRegularExpression(pattern: "```[\\s\\S]*?(?:```|$)|`[^`\\n]+`")
    var result = ""
    var prose = t.startIndex
    for match in code.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
        let range = Range(match.range, in: t)!
        result += stripMarkup(String(t[prose..<range.lowerBound])) + t[range]
        prose = range.upperBound
    }
    result += stripMarkup(String(t[prose...]))
    result = result.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
    result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Removes HTML comments, the HTML tags GitHub renders (but not other angle brackets, as in `x < y` or
/// `List<String>`), and image markup, and decodes common entities.
private func stripMarkup(_ s: String) -> String {
    let tags = "a|b|br|code|details|div|em|h[1-6]|hr|i|img|kbd|li|ol|p|picture|pre|relative-time|source|span|strong|sub|summary|sup|table|tbody|td|th|thead|tr|ul"
    var t = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    // Line breaks and block tags become paragraph breaks, so `a<br>b` or `text\n<p>a</p><p>b</p>` don't run
    // together (a single newline is just a space in Markdown).
    t = t.replacingOccurrences(of: "<br\\b[^<>]*>|<hr\\b[^<>]*>|</?(?:p|div|li|tr|h[1-6]|summary|details|table|ul|ol|pre)\\b[^<>]*>",
                               with: "\n\n", options: .regularExpression)
    t = t.replacingOccurrences(of: "</?(?:\(tags))\\b[^<>]*>", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)   // ![alt](image) → alt
    for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
        t = t.replacingOccurrences(of: entity, with: char)
    }
    return t
}

/// Markdown (GitHub-flavored) as styled text. Foundation parses it, but AppKit doesn't lay out its blocks,
/// so headings, lists, quotes, code blocks and tables are styled here from each run's presentation intent.
/// Tables, code blocks and quotes use text blocks (AppKit's box model: borders, padding, backgrounds),
/// which makes the text view fall back to TextKit 1 while they're shown.
/// Returns nil if the text can't be parsed.
private func renderMarkdown(_ source: String, font: NSFont, container: [NSTextBlock]) -> NSAttributedString? {
    guard let parsed = try? AttributedString(markdown: source, options: .init(
        interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else { return nil }
    let out = NSMutableAttributedString()
    let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
    let tint = NSColor.labelColor.withAlphaComponent(0.06)
    var lastBlock: Int?? = .none   // identity of the previous run's innermost block; nil for raw HTML
    var lastAttrs: [NSAttributedString.Key: Any] = [:]
    var markedItems = Set<Int>()
    // Every run of one table, cell, code block or quote must share the same block object.
    var tables: [Int: NSTextTable] = [:]
    var textBlocks: [Int: NSTextBlock] = [:]

    func box(_ id: Int, _ make: () -> NSTextBlock) -> NSTextBlock {
        if let b = textBlocks[id] { return b }
        let b = make()
        textBlocks[id] = b
        return b
    }

    for run in parsed.runs {
        var text = String(parsed[run.range].characters)
        let blocks = run.presentationIntent?.components ?? []   // innermost first
        let block = blocks.first?.identity
        let listDepth = blocks.filter { if case .listItem = $0.kind { return true }; return false }.count

        // Blocks aren't separated in the parsed text: end the previous paragraph with its own layout.
        var marker = ""
        if lastBlock == nil || lastBlock! != block {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: lastAttrs)) }
            if let i = blocks.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
               !markedItems.contains(blocks[i].identity) {
                markedItems.insert(blocks[i].identity)
                if case .listItem(let ordinal) = blocks[i].kind, i + 1 < blocks.count, case .orderedList = blocks[i + 1].kind {
                    marker = "\(ordinal). "
                } else {
                    marker = "• "
                }
            }
        }
        lastBlock = .some(block)

        // Boxes, outermost first: quotes get a bar on the left, code blocks a tinted box, table cells borders.
        var boxes: [NSTextBlock] = []
        var isHeaderRow = false
        for component in blocks.reversed() {
            switch component.kind {
            case .blockQuote:
                boxes.append(box(component.identity) {
                    let b = NSTextBlock()
                    b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    b.setBorderColor(.separatorColor, for: .minX)
                    b.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                    b.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                    b.setValue(100, type: .percentageValueType, for: .width)   // otherwise it shrinks to nothing
                    return b
                })
            case .codeBlock:
                boxes.append(box(component.identity) {
                    let b = NSTextBlock()
                    b.backgroundColor = tint
                    b.setWidth(8, type: .absoluteValueType, for: .padding)
                    b.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                    b.setValue(100, type: .percentageValueType, for: .width)
                    return b
                })
            case .table(let columns):
                // A table can only sit directly in a table cell (here: the card's), not in a quote or code box.
                boxes.removeAll { !($0 is NSTextTableBlock) }
                if tables[component.identity] == nil {
                    let t = NSTextTable()
                    t.numberOfColumns = max(columns.count, 1)
                    t.layoutAlgorithm = .automaticLayoutAlgorithm
                    t.collapsesBorders = true
                    t.hidesEmptyCells = false
                    t.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                    tables[component.identity] = t
                }
            case .tableHeaderRow:
                isHeaderRow = true
            case .tableCell(let column):
                let table = blocks.compactMap { c -> NSTextTable? in
                    if case .table = c.kind { return tables[c.identity] }; return nil
                }.first
                let row = blocks.compactMap { c -> Int? in
                    if case .tableRow(let r) = c.kind { return r }
                    if case .tableHeaderRow = c.kind { return 0 }
                    return nil
                }.first ?? 0
                if let table {
                    let header = isHeaderRow
                    boxes.append(box(component.identity) {
                        let b = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        b.setWidth(1, type: .absoluteValueType, for: .border)
                        b.setBorderColor(.separatorColor)
                        b.setWidth(6, type: .absoluteValueType, for: .padding)
                        if header { b.backgroundColor = tint }
                        return b
                    })
                }
            default:
                break
            }
        }
        var runFont = font
        var color = NSColor.labelColor
        var attrs: [NSAttributedString.Key: Any] = [:]
        let para = NSMutableParagraphStyle()
        let left = CGFloat(listDepth) * 16
        para.firstLineHeadIndent = left
        para.headIndent = left + (listDepth > 0 ? 14 : 0)   // wrapped list lines align after the marker
        para.paragraphSpacing = boxes.isEmpty ? 4 : 0
        para.textBlocks = container + boxes   // inside the card it belongs to
        switch blocks.first?.kind {
        case .header(let level)?:
            runFont = .boldSystemFont(ofSize: font.pointSize + [6, 4, 2, 1, 0, 0][min(max(level, 1), 6) - 1])
            para.paragraphSpacingBefore = 6
        case .codeBlock?:
            runFont = mono
            while text.hasSuffix("\n") { text.removeLast() }
        case .thematicBreak?:
            color = .tertiaryLabelColor
        case .tableCell?:
            if isHeaderRow { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
        default:
            break
        }
        if blocks.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) { color = .secondaryLabelColor }

        if let inline = run.inlinePresentationIntent {
            if inline.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if inline.contains(.code) {
                runFont = mono
                attrs[.backgroundColor] = tint
            }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        if let link = run.link { attrs[.link] = link }

        attrs[.font] = runFont
        attrs[.foregroundColor] = color
        attrs[.paragraphStyle] = para
        var plain = attrs   // for markers and paragraph ends: no link, no code background
        plain[.backgroundColor] = nil
        plain[.link] = nil
        plain[.strikethroughStyle] = nil
        if !marker.isEmpty { out.append(NSAttributedString(string: marker, attributes: plain)) }
        out.append(NSAttributedString(string: text, attributes: attrs))
        lastAttrs = plain
    }
    if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: lastAttrs)) }
    return out
}
