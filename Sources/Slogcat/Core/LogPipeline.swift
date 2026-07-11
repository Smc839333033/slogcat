import AppKit
import Foundation

/// Background actor: owns the raw ring buffer (for filter recompute) and builds the
/// attributed string for filtered entries OFF the main thread, accumulating into a pending
/// chunk. LogStore drains the chunk every 100ms and hands it to the NSTextView.
actor LogPipeline {
    private var rawBuffer: RingBuffer<LogEntry>
    private var filter: FilterEngine.Compiled
    private var highlightRegexes: [NSRegularExpression] = []
    /// Current font, baked into every built line off-main so the UI never has to stamp
    /// `.font` over the whole document (which blocked the main thread on filter changes).
    private var font: NSFont = LogTextBuilder.font(ofSize: 12)

    /// Accumulated attributed-string chunk built off-main, plus per-line end offsets
    /// (relative to the chunk) so the UI doesn't have to scan for newlines.
    private var pendingChunk = NSMutableAttributedString()
    private var pendingOffsets: [Int] = []
    private(set) var rawCount: Int = 0
    private var seq: UInt64 = 0

    /// Cap pending while the UI is frozen (paused / scrolling) so memory stays bounded.
    private var pendingLineCap = LogConfig.defaultPendingCap

    init(capacity: Int, filter: FilterEngine.Compiled) {
        self.rawBuffer = RingBuffer(capacity: capacity)
        self.filter = filter
    }

    func setFilter(_ compiled: FilterEngine.Compiled) { self.filter = compiled }

    func setFontSize(_ size: Double) {
        self.font = LogTextBuilder.font(ofSize: size)
    }

    func setHighlightKeywords(_ kws: [String]) {
        highlightRegexes = kws.compactMap {
            try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: $0), options: [.caseInsensitive])
        }
    }

    func setPendingCap(_ cap: Int) {
        pendingLineCap = max(100, cap)
        trimPendingIfNeeded()
    }

    func ingest(lines: [String]) {
        for line in lines {
            seq &+= 1
            rawCount &+= 1
            let entry = LineParser.parse(line, seq: seq)
            rawBuffer.append(entry)
            if FilterEngine.test(entry, against: filter) {
                let attr = LogTextBuilder.attributedString(for: entry, highlightRegexes: highlightRegexes, font: font)
                pendingChunk.append(attr)
                pendingOffsets.append(pendingChunk.length)
            }
        }
        trimPendingIfNeeded()
    }

    struct DrainResult: Sendable {
        let chunk: SendableAttr
        let offsets: [Int]   // relative line-end offsets within chunk
        let rawCount: Int
    }

    /// Drain up to `maxLines` pending lines. Capping per tick keeps each UI append small
    /// (smooth burst-resume after a long pause); the rest stays in `pending` for next tick.
    func drainPending(maxLines: Int = LogConfig.drainMaxLinesPerTick) -> DrainResult {
        if pendingOffsets.isEmpty {
            let result = DrainResult(chunk: SendableAttr(value: pendingChunk), offsets: pendingOffsets, rawCount: rawCount)
            pendingChunk = NSMutableAttributedString()
            pendingOffsets.removeAll(keepingCapacity: true)
            return result
        }
        if pendingOffsets.count <= maxLines {
            let result = DrainResult(chunk: SendableAttr(value: pendingChunk), offsets: pendingOffsets, rawCount: rawCount)
            pendingChunk = NSMutableAttributedString()
            pendingOffsets.removeAll(keepingCapacity: true)
            return result
        }
        // Slice the first `maxLines` lines off the pending chunk.
        let cut = pendingOffsets[maxLines - 1]
        let head = pendingChunk.attributedSubstring(from: NSRange(location: 0, length: cut))
        let headOffsets = Array(pendingOffsets.prefix(maxLines))
        pendingChunk.replaceCharacters(in: NSRange(location: 0, length: cut), with: "")
        pendingOffsets.removeFirst(maxLines)
        for i in pendingOffsets.indices { pendingOffsets[i] -= cut }
        return DrainResult(chunk: SendableAttr(value: head), offsets: headOffsets, rawCount: rawCount)
    }

    /// Re-filter the entire raw buffer (on filter change). Builds the full attributed string
    /// AND its per-line offsets off the main thread, so `replaceAll` on the UI side does no
    /// scanning. Output is capped to the last `maxLines` (display cap) so the document never
    /// exceeds its bound. Clears pending since the full replace supersedes it.
    func recomputeFiltered(maxLines: Int) -> (chunk: SendableAttr, offsets: [Int], rawCount: Int) {
        pendingChunk = NSMutableAttributedString()
        pendingOffsets.removeAll(keepingCapacity: true)
        let regexes = highlightRegexes
        let buildFont = font
        let attr = NSMutableAttributedString()
        var offsets: [Int] = []
        offsets.reserveCapacity(1024)
        for e in rawBuffer.allElements() where FilterEngine.test(e, against: filter) {
            attr.append(LogTextBuilder.attributedString(for: e, highlightRegexes: regexes, font: buildFont))
            offsets.append(attr.length)
        }
        // Cap to the last `maxLines` lines.
        if offsets.count > maxLines {
            let drop = offsets.count - maxLines
            let cut = offsets[drop - 1]
            let sliced = attr.attributedSubstring(from: NSRange(location: cut, length: attr.length - cut))
            var slicedOffsets = Array(offsets.suffix(maxLines))
            for i in slicedOffsets.indices { slicedOffsets[i] -= cut }
            return (SendableAttr(value: sliced), slicedOffsets, rawCount)
        }
        return (SendableAttr(value: attr), offsets, rawCount)
    }

    func clear() {
        rawBuffer.clear()
        pendingChunk = NSMutableAttributedString()
        pendingOffsets.removeAll(keepingCapacity: true)
        rawCount = 0
    }

    private func trimPendingIfNeeded() {
        guard pendingOffsets.count > pendingLineCap else { return }
        let trimLines = pendingOffsets.count - pendingLineCap
        let trimOffset = pendingOffsets[trimLines - 1]
        pendingChunk.replaceCharacters(in: NSRange(location: 0, length: trimOffset), with: "")
        pendingOffsets.removeFirst(trimLines)
        for i in pendingOffsets.indices { pendingOffsets[i] -= trimOffset }
    }
}
