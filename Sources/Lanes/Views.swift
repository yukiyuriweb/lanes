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
    var color: NSColor = .systemBlue

    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let commit else { return }
        let textColor: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        var x: CGFloat = 4
        let pillHeight: CGFloat = 16

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
    let maxLength = 1_000_000
    let body = text.count > maxLength ? String(text.prefix(maxLength)) + "\n… (truncated)\n" : text
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let result = NSMutableAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    let ns = body as NSString
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
