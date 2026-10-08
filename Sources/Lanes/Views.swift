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
func renderPullRequest(_ pr: PullRequest, dateFormatter: DateFormatter) -> NSAttributedString {
    let body = NSFont.systemFont(ofSize: 12)
    let bold = NSFont.boldSystemFont(ofSize: 12)
    let result = NSMutableAttributedString()
    var indent: CGFloat = 0
    func add(_ s: String, _ font: NSFont = body, _ color: NSColor = .labelColor, link: String? = nil) {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = indent
        para.headIndent = indent
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if let link { attrs[.link] = URL(string: link) }
        result.append(NSAttributedString(string: s, attributes: attrs))
    }
    func header(_ who: PullRequest.Author?, _ what: String?, _ date: Date?) {
        add(who?.login ?? "ghost", bold)
        let meta = [what, date.map(dateFormatter.string(from:))].compactMap { $0 }.joined(separator: " · ")
        add(meta.isEmpty ? "\n" : "  " + meta + "\n", body, .secondaryLabelColor)
    }
    func text(_ s: String) {
        let cleaned = plainText(s)
        if !cleaned.isEmpty { add(cleaned + "\n") }
    }
    func more(_ n: Int) {
        if n > 0 { add(String(localized: "\(n) more on GitHub") + "\n\n", body, .secondaryLabelColor) }
    }

    add("#\(pr.number) \(pr.title)\n", .boldSystemFont(ofSize: 15))
    add(prStateName(pr), bold, prColor(pr))
    add("  \(pr.author?.login ?? "ghost") · \(pr.headRefName) → \(pr.baseRefName) · \(dateFormatter.string(from: pr.createdAt))\n",
        body, .secondaryLabelColor)
    add(String(localized: "Open on GitHub"), body, .linkColor, link: pr.url)
    add("\n\n")
    text(pr.body)

    enum Item { case review(PullRequest.Review), comment(PullRequest.Comment) }
    let items: [(Date, Item)] =
        // Replying in a thread creates an empty COMMENTED review; its comment already shows under the thread.
        pr.reviews.nodes.filter { $0.state != "COMMENTED" || !plainText($0.body).isEmpty }
            .compactMap { r in r.submittedAt.map { ($0, .review(r)) } } +
        pr.comments.nodes.map { ($0.createdAt, .comment($0)) }
    if !items.isEmpty {
        add("\n── " + String(localized: "Conversation") + " ──\n\n", bold, .secondaryLabelColor)
    }
    more(pr.reviews.hidden + pr.comments.hidden)   // the oldest ones, since the query takes the latest
    for (date, item) in items.sorted(by: { $0.0 < $1.0 }) {
        switch item {
        case .review(let r):
            // A review with only inline comments has an empty body; its comments appear under the threads.
            header(r.author, reviewStateName(r.state), date)
            text(r.body)
        case .comment(let c):
            header(c.author, nil, date)
            text(c.body)
        }
        add("\n")
    }

    let threads = pr.reviewThreads.nodes
    if !threads.isEmpty {
        let open = threads.filter { !$0.isResolved }.count
        add("\n── " + String(localized: "Review Threads") + " (\(open)/\(pr.reviewThreads.totalCount ?? threads.count)) ──\n\n", bold, .secondaryLabelColor)
    }
    for t in threads {
        let location = t.path + ((t.line ?? t.originalLine).map { ":\($0)" } ?? "")
        if t.isResolved {
            add("✓ " + location, body, .secondaryLabelColor)
            add("  " + String(localized: "Resolved") + "\n\n", body, .secondaryLabelColor)
            continue
        }
        add(location + "\n", .monospacedSystemFont(ofSize: 12, weight: .bold))
        indent = 20
        for c in t.comments.nodes {
            header(c.author, nil, c.createdAt)
            text(c.body)
            add("\n")
        }
        more(t.comments.hidden)
        indent = 0
    }
    more(pr.reviewThreads.hidden)
    return result
}

private func reviewStateName(_ state: String) -> String {
    switch state {
    case "APPROVED": return String(localized: "Approved")
    case "CHANGES_REQUESTED": return String(localized: "Changes requested")
    case "DISMISSED": return String(localized: "Dismissed")
    default: return String(localized: "Reviewed")
    }
}

/// Comment bodies are Markdown with embedded HTML (bots use plenty); show them as readable plain text.
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
    // Line breaks and the ends of blocks become newlines, so `a<br>b` or `<p>a</p><p>b</p>` don't run together.
    t = t.replacingOccurrences(of: "<br\\b[^<>]*>|<hr\\b[^<>]*>|</(?:p|div|li|tr|h[1-6]|summary|details|table|ul|ol|pre)>",
                               with: "\n", options: .regularExpression)
    t = t.replacingOccurrences(of: "</?(?:\(tags))\\b[^<>]*>", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)   // ![alt](image) → alt
    for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
        t = t.replacingOccurrences(of: entity, with: char)
    }
    return t
}
