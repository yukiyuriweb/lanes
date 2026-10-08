import Foundation

/// A line piece inside one row. Top segments run from lane `from` at the row's top edge
/// to lane `to` at its middle; bottom segments run from the middle to the bottom edge.
struct Segment {
    let from: Int
    let to: Int
    let top: Bool
    let color: Int
}

struct GraphRow {
    let column: Int
    let color: Int
    let isMerge: Bool
    let segments: [Segment]
}

enum GraphLayout {
    /// Assigns each commit a lane. Commits must be ordered children-before-parents.
    static func compute(_ commits: [Commit]) -> (rows: [GraphRow], width: Int) {
        // Each lane holds the hash of the commit it is heading towards.
        var lanes: [(hash: String, color: Int)?] = []
        var nextColor = 0
        var width = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }

        for c in commits {
            var segs: [Segment] = []
            let matches = lanes.indices.filter { lanes[$0]?.hash == c.hash }
            let col: Int, color: Int
            if let first = matches.first {
                col = first
                color = lanes[first]!.color
            } else {
                col = freeSlot()
                color = nextColor
                nextColor += 1
            }

            for (i, lane) in lanes.enumerated() {
                guard let lane else { continue }
                segs.append(Segment(from: i, to: lane.hash == c.hash ? col : i, top: true, color: lane.color))
            }

            for i in matches { lanes[i] = nil }
            lanes[col] = c.parents.first.map { ($0, color) }

            var newLanes = Set<Int>()
            for p in c.parents.dropFirst() {
                if let j = lanes.firstIndex(where: { $0?.hash == p }) {
                    segs.append(Segment(from: col, to: j, top: false, color: lanes[j]!.color))
                } else {
                    let k = freeSlot()
                    lanes[k] = (p, nextColor)
                    nextColor += 1
                    newLanes.insert(k)
                    segs.append(Segment(from: col, to: k, top: false, color: lanes[k]!.color))
                }
            }
            for (i, lane) in lanes.enumerated() {
                guard let lane, !newLanes.contains(i) else { continue }
                segs.append(Segment(from: i, to: i, top: false, color: lane.color))
            }

            width = max(width, lanes.count)
            while let last = lanes.last, last == nil { lanes.removeLast() }
            rows.append(GraphRow(column: col, color: color, isMerge: c.parents.count > 1, segments: segs))
        }
        return (rows, width)
    }
}
