import AppKit
import SwiftUI

// MARK: - NSAttributedString builder

enum LogTextBuilder {
    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.32)

    /// Fixed column widths for pid/tid so the level/tag/message columns stay left-aligned
    /// across lines regardless of pid/tid digit count. 5 covers the vast majority of Android
    /// pids/tids; longer values simply widen that line (rare, harmless).
    static let pidWidth = 5
    static let tidWidth = 5

    /// Background matching the current theme. Read at call time so appearance changes take effect.
    static var backgroundColor: NSColor {
        ThemeManagerShared.isDark
            ? NSColor(white: 0.10, alpha: 1)
            : NSColor(white: 0.96, alpha: 1)
    }

    /// Default text color matching the theme.
    static var textColor: NSColor {
        ThemeManagerShared.isDark ? NSColor.white : NSColor(white: 0.08, alpha: 1)
    }

    static func font(ofSize size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func nsColor(for level: LogLevel) -> NSColor {
        switch level {
        case .verbose: return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 0.62, green: 0.58, blue: 0.80, alpha: 1)
            : NSColor(srgbRed: 0.50, green: 0.42, blue: 0.70, alpha: 1)
        case .debug:   return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.55, blue: 0.85, alpha: 1)
        case .info:    return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 0.60, green: 0.75, blue: 0.62, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.60, blue: 0.30, alpha: 1)
        case .warn:    return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 1.0, green: 0.82, blue: 0.25, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.65, blue: 0.10, alpha: 1)
        case .error:   return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 1.0, green: 0.33, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.20, blue: 0.20, alpha: 1)
        case .fatal:   return ThemeManagerShared.isDark
            ? NSColor(srgbRed: 1.0, green: 0.15, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.75, green: 0.10, blue: 0.15, alpha: 1)
        }
    }

    /// Build one line as an attributed string. The whole line is dyed with the level color
    /// (timestamp/pid dimmer, message full). `.font` is baked in by the background pipeline.
    static func attributedString(for entry: LogEntry, highlightRegexes: [NSRegularExpression], font: NSFont) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let c = nsColor(for: entry.level)
        let dim = c.withAlphaComponent(0.50)
        let tagC = c.withAlphaComponent(0.80)

        if !entry.timestamp.isEmpty {
            s.append(NSAttributedString(string: entry.timestamp + " ", attributes: [.foregroundColor: dim, .font: font]))
        }
        if entry.pid != 0 {
            // Right-pad pid/tid to a fixed width so the level/tag/message columns line up.
            // Monospace font → equal char width, so space-padding alone aligns perfectly.
            // O(1) per line (just a few extra spaces); no impact on offset/search/trim math.
            let pid = String(entry.pid)
            let tid = String(entry.tid)
            let pidPad = String(repeating: " ", count: max(0, LogTextBuilder.pidWidth - pid.count))
            let tidPad = String(repeating: " ", count: max(0, LogTextBuilder.tidWidth - tid.count))
            s.append(NSAttributedString(string: "\(pidPad)\(pid) \(tidPad)\(tid) ", attributes: [.foregroundColor: dim, .font: font]))
        }
        s.append(NSAttributedString(string: entry.level.rawValue + " ", attributes: [.foregroundColor: c, .font: font]))
        if !entry.tag.isEmpty {
            s.append(NSAttributedString(string: entry.tag + ": ", attributes: [.foregroundColor: tagC, .font: font]))
        }

        let msg = NSMutableAttributedString(string: entry.message, attributes: [.foregroundColor: c, .font: font])
        if !highlightRegexes.isEmpty {
            let nsMsg = entry.message as NSString
            for re in highlightRegexes {
                re.enumerateMatches(in: entry.message, range: NSRange(location: 0, length: nsMsg.length)) { m, _, _ in
                    if let m = m { msg.addAttribute(.backgroundColor, value: highlightColor, range: m.range) }
                }
            }
        }
        s.append(msg)
        s.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        return s
    }
}

/// Sendable wrapper so an attributed string built off-main can be handed to the main thread.
struct SendableAttr: @unchecked Sendable {
    let value: NSAttributedString
}

// MARK: - Coordinator

final class LogCoordinator: NSObject {
    weak var textView: NSTextView?
    private(set) var lineCount: Int = 0
    /// Cumulative character offset recorded after each line's trailing newline.
    private var lineEndOffsets: [Int] = []
    var followTail: Bool = true
    /// When the user navigates search matches (prev/next), we lock follow-tail so new appends
    /// don't yank the viewport back to the bottom. Cleared when the user manually scrolls to the
    /// bottom (updateFollowTail detects it) or when search is closed.
    var searchLocked: Bool = false

    /// Bounded display buffer: when line count exceeds `cap`, the oldest `trimBatch` lines
    /// are dropped from the front. Ring-buffer semantics over the NSTextView's text storage.
    private var cap = LogConfig.defaultDisplayCap
    private let trimBatch = LogConfig.trimBatch

    /// While the user is live-scrolling, appends are stashed here and flushed on scroll end
    /// so textStorage mutations (which trigger layout) don't fight the scroll gesture.
    private var isLiveScrolling = false
    private var pendingDuringScroll: [(NSAttributedString, [Int])] = []
    /// Deferred search shift offset — set inside beginEditing/endEditing when front-trim
    /// happens, applied after endEditing so highlightSearchMatch's scrollRangeToVisible
    /// doesn't trigger glyph generation while textStorage is editing.
    private var pendingSearchShift: Int? = nil

    func attach(_ tv: NSTextView, scrollView: NSScrollView) {
        self.textView = tv
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willStartLiveScroll),
                       name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        nc.addObserver(self, selector: #selector(didEndLiveScroll),
                       name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        tv.layoutManager?.allowsNonContiguousLayout = true
        updateFollowTail()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        textView = nil
    }

    /// Update NSTextView + NSScrollView colors to match the current theme. Called on appearance toggle.
    func applyAppearance() {
        guard let tv = textView, let sv = tv.enclosingScrollView else { return }
        let bg = LogTextBuilder.backgroundColor
        tv.backgroundColor = bg
        tv.textColor = LogTextBuilder.textColor
        sv.backgroundColor = bg
    }

    /// Apply text size. Attributed strings carry no `.font`, so we (a) set the text view's
    /// default font and (b) explicitly re-apply `.font` to every run, then force the layout
    /// manager to drop cached glyphs and re-layout — otherwise already-displayed (especially
    /// off-screen) text keeps the old size.
    private var currentFontSize: Double = -1
    private var currentFont: NSFont = LogTextBuilder.font(ofSize: 12)

    func setFontSize(_ size: Double) {
        guard let tv = textView, size != currentFontSize else { return }
        currentFontSize = size
        currentFont = LogTextBuilder.font(ofSize: size)
        tv.font = currentFont
        guard let storage = tv.textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.font, value: currentFont, range: whole)
        storage.endEditing()
        if let lm = tv.layoutManager {
            lm.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
            lm.invalidateDisplay(forCharacterRange: whole)
        }
        tv.needsDisplay = true
    }

    @objc private func willStartLiveScroll() { isLiveScrolling = true }

    @objc private func didEndLiveScroll() {
        isLiveScrolling = false
        updateFollowTail()
        flushPending()
    }

    private func updateFollowTail() {
        guard let tv = textView, let sv = tv.enclosingScrollView else { return }
        let clip = sv.contentView
        let bottom = clip.bounds.origin.y + clip.bounds.height
        let atBottom = bottom >= tv.bounds.height - 40
        followTail = atBottom
        // If the user scrolled back to the bottom, release the search lock so new logs
        // resume auto-scrolling.
        if atBottom { searchLocked = false }
    }

    // MARK: Mutations (must run on main thread)

    /// Append a pre-built chunk plus its per-line end offsets (relative to the chunk).
    func appendChunk(_ chunk: NSAttributedString, offsets: [Int]) {
        guard chunk.length > 0 else { return }
        if isLiveScrolling {
            pendingDuringScroll.append((chunk, offsets))
            if pendingDuringScroll.count > 64 {
                pendingDuringScroll.removeFirst(pendingDuringScroll.count - 64)
            }
            return
        }
        appendChunkNow(chunk, offsets: offsets)
    }

    private func flushPending() {
        guard !pendingDuringScroll.isEmpty else { return }
        let pending = pendingDuringScroll
        pendingDuringScroll.removeAll(keepingCapacity: true)
        for (chunk, offsets) in pending {
            appendChunkNow(chunk, offsets: offsets)
        }
    }

    private func appendChunkNow(_ chunk: NSAttributedString, offsets: [Int]) {
        guard let tv = textView, chunk.length > 0 else { return }
        let storage = tv.textStorage!
        let base = lineEndOffsets.last ?? 0
        let appendAt = storage.length
        storage.beginEditing()
        storage.append(chunk)
        // Stamp the current font onto the newly appended runs so they match the chosen size.
        storage.addAttribute(.font, value: currentFont, range: NSRange(location: appendAt, length: chunk.length))
        lineEndOffsets.reserveCapacity(lineEndOffsets.count + offsets.count)
        for off in offsets { lineEndOffsets.append(base + off) }
        if lineEndOffsets.count > cap {
            let trimLines = lineEndOffsets.count - cap + trimBatch
            let trimOffset = lineEndOffsets[trimLines - 1]
            // Clear search highlight before trim (its range is still valid pre-trim), then
            // shift stored search matches by -trimOffset so they stay correct after the trim.
            clearSearchHighlight()
            storage.replaceCharacters(in: NSRange(location: 0, length: trimOffset), with: "")
            lineEndOffsets.removeFirst(trimLines)
            for i in lineEndOffsets.indices { lineEndOffsets[i] -= trimOffset }
            pendingSearchShift = trimOffset   // defer to after endEditing — scrollRangeToVisible
                                              // inside highlightSearchMatch would trigger glyph
                                              // generation while textStorage is editing → crash
        }
        lineCount = lineEndOffsets.count
        storage.endEditing()
        if let shift = pendingSearchShift {
            pendingSearchShift = nil
            searchShiftHandler?(shift)
        }
        if followTail && !searchLocked { scrollToEnd() }
    }

    /// Replace the whole document. `offsets` (per-line end offsets) are precomputed off the
    /// main thread by the pipeline, and `.font` is already baked into `attr` there — so this
    /// does only the bulk `setAttributedString` + offset assignment on main, no font stamp.
    func replaceAll(_ attr: NSAttributedString, offsets: [Int]) {
        guard let tv = textView else { return }
        let storage = tv.textStorage!
        storage.beginEditing()
        storage.setAttributedString(attr)
        storage.endEditing()
        lineEndOffsets = offsets
        lineCount = lineEndOffsets.count
        searchLocked = false   // document replaced → search lock no longer meaningful
        if followTail { scrollToEnd() }
    }

    func clear() {
        guard let tv = textView else { return }
        tv.textStorage!.beginEditing()
        tv.textStorage!.setAttributedString(NSAttributedString())
        tv.textStorage!.endEditing()
        lineEndOffsets.removeAll(keepingCapacity: true)
        lineCount = 0
    }

    /// Update the display cap at runtime. If the current document exceeds the new cap,
    /// immediately trims the oldest lines so the document stays within the bound.
    func updateCap(_ newCap: Int) {
        cap = newCap
        guard let tv = textView else { return }
        let storage = tv.textStorage!
        if lineEndOffsets.count > cap {
            let trimLines = lineEndOffsets.count - cap + trimBatch
            guard trimLines > 0 && trimLines <= lineEndOffsets.count else { return }
            let trimOffset = lineEndOffsets[trimLines - 1]
            clearSearchHighlight()
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: trimOffset), with: "")
            lineEndOffsets.removeFirst(trimLines)
            for i in lineEndOffsets.indices { lineEndOffsets[i] -= trimOffset }
            lineCount = lineEndOffsets.count
            storage.endEditing()
            searchShiftHandler?(trimOffset)
        }
    }

    func scrollToEnd() {
        guard let tv = textView, let sv = tv.enclosingScrollView else { return }
        let clip = sv.contentView
        let docHeight = tv.bounds.height
        let visibleHeight = clip.bounds.height
        // Animate the clip view's bounds origin toward the new bottom (Core Animation —
        // cheap, runs off the main thread). Falls back to range-based scroll if the doc
        // isn't taller than the viewport or the tail isn't laid out yet.
        if docHeight > visibleHeight {
            let targetY = max(0, docHeight - visibleHeight)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }, completionHandler: nil)
            sv.reflectScrolledClipView(clip)
        } else {
            let len = lineEndOffsets.last ?? 0
            tv.scrollRangeToVisible(NSRange(location: len, length: 0))
        }
        followTail = true
    }

    // MARK: Search

    private var highlightedSearchRange: NSRange?
    /// Called with the front-trim char offset whenever lines are dropped from the front, so
    /// the store can shift its stored search match ranges to stay correct.
    var searchShiftHandler: ((Int) -> Void)?

    /// Find all (case-insensitive) ranges of `query` in the displayed document.
    func findMatches(_ query: String) -> [NSRange] {
        guard let tv = textView, !query.isEmpty else { return [] }
        return findMatches(query, in: NSRange(location: 0, length: tv.textStorage!.length))
    }

    /// Find matches of `query` restricted to `range` (case-insensitive). Cheap incremental scan
    /// used after each append so the search count stays live without re-scanning 20k lines.
    func findMatches(_ query: String, in range: NSRange) -> [NSRange] {
        guard let tv = textView, !query.isEmpty, range.length > 0 else { return [] }
        let str = tv.string as NSString
        // Clamp the scan range to the actual string length — async deferral means the document
        // may have been trimmed between scheduling and execution.
        let clampedLoc = max(0, min(range.location, str.length))
        let clampedEnd = min(NSMaxRange(range), str.length)
        guard clampedEnd > clampedLoc else { return [] }
        let clampedRange = NSRange(location: clampedLoc, length: clampedEnd - clampedLoc)
        var matches: [NSRange] = []
        var r = clampedRange
        while r.length > 0 {
            let found = str.range(of: query, options: [.caseInsensitive], range: r)
            if found.location == NSNotFound || found.length == 0 { break }
            matches.append(found)
            r.location = NSMaxRange(found)
            r.length = clampedEnd - r.location
        }
        return matches
    }

    /// Total document length (char count). Used to know where to start an incremental scan.
    var documentLength: Int {
        textView?.textStorage?.length ?? 0
    }

    /// Underline + scroll to a match range (nil clears the current highlight). Uses underline
    /// (not background) so it doesn't clash with keyword-highlight backgrounds.
    /// NOTE: does NOT wrap in beginEditing/endEditing — callers that are already inside an
    /// editing block (e.g. appendChunkNow) can call this safely; callers that aren't should
    /// wrap their own batch. Wrapping here causes nested begin/end pairs that prematurely
    /// trigger glyph generation → "_fillGlyphHole while textStorage is editing" crash.
    func highlightSearchMatch(_ range: NSRange?) {
        guard let storage = textView?.textStorage else { return }
        let len = storage.length
        if let prev = highlightedSearchRange, prev.location + prev.length <= len {
            storage.removeAttribute(.underlineStyle, range: prev)
            storage.removeAttribute(.underlineColor, range: prev)
        }
        highlightedSearchRange = nil
        guard let range = range, range.location + range.length <= len, range.length > 0 else { return }
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
        storage.addAttribute(.underlineColor, value: NSColor.systemYellow, range: range)
        highlightedSearchRange = range
        // Lock follow-tail so the next append doesn't yank the viewport back to the bottom.
        searchLocked = true
        textView?.scrollRangeToVisible(range)
    }

    /// Clear search lock — called when the user manually scrolls back to the bottom or closes search.
    func clearSearchLock() {
        searchLocked = false
    }

    func clearSearchHighlight() { highlightSearchMatch(nil) }
}

// MARK: - NSViewRepresentable

struct LogTextView: NSViewRepresentable {
    @Environment(LogStore.self) private var store

    func makeCoordinator() -> LogCoordinator { LogCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tv = NSTextView()

        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.font = LogTextBuilder.font(ofSize: store.fontSize)
        tv.textColor = NSColor.white
        tv.backgroundColor = LogTextBuilder.backgroundColor
        tv.drawsBackground = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        // Wrap lines at the text view's (window) width: container tracks the view, so as the
        // window resizes, lines re-wrap to fit.
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 4
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.autoresizingMask = [.width]

        // Disable features a read-only log view doesn't need — reduces layout/overhead.
        tv.usesFontPanel = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesRuler = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = true
        scrollView.backgroundColor = LogTextBuilder.backgroundColor

        context.coordinator.attach(tv, scrollView: scrollView)
        store.coordinator = context.coordinator
        context.coordinator.searchShiftHandler = { [weak store] offset in
            store?.shiftSearchMatches(by: -offset)   // front-trim shifts remaining text down
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if store.coordinator !== context.coordinator { store.coordinator = context.coordinator }
        context.coordinator.setFontSize(store.fontSize)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: LogCoordinator) {
        coordinator.detach()
    }
}
