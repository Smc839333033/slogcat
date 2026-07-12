import SwiftUI

/// UI-facing store. @Observable + @MainActor. Drains filtered entries from the background
/// LogPipeline every 100ms and pushes them as text to the LogCoordinator (NSTextView).
@MainActor
@Observable
final class LogStore {
    // Filter / config state (bound to UI)
    var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    var rules: [FilterRule] = []
    var fontSize: Double = UserDefaults.standard.double(forKey: LogConfig.fontSizeKey) == 0
        ? 12 : UserDefaults.standard.double(forKey: LogConfig.fontSizeKey)
    var displayCap: Int = {
        let v = UserDefaults.standard.integer(forKey: LogConfig.displayCapKey)
        return v > 0 ? v : LogConfig.defaultDisplayCap
    }()
    var adbPath: String = AdbLocator.userPath ?? ""
    var hdcPath: String = HdcLocator.userPath ?? ""
    let theme = ThemeManager()

    // Stream state
    var isStreaming: Bool = false
    var paused: Bool = false            // manual freeze (button)
    var rawCount: Int = 0
    var displayedCount: Int = 0
    var devices: [Device] = []
    var selectedDeviceId: String? = nil
    var statusMessage: String = "Idle"
    var errorMessage: String? = nil

    weak var coordinator: LogCoordinator?

    private let pipeline: LogPipeline
    private let adb = AdbProcess()
    private let hdc = HdcProcess()
    private var streamTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var devicePollTask: Task<Void, Never>?
    var recomputing: Bool = false
    private var clearing: Bool = false

    init() {
        self.pipeline = LogPipeline(capacity: 50_000, filter: FilterEngine.compile(.default))
        ThemeManagerShared = theme
        startSnapshotTask()
        startDevicePollTask()
    }

    // MARK: - Streaming

    /// The currently selected device (resolved from `selectedDeviceId` against the device list),
    /// or nil when "DEFAULT" / nothing is selected. Drives which tool (adb/hdc) streams logs.
    var selectedDevice: Device? {
        guard let id = selectedDeviceId else { return nil }
        return devices.first { $0.id == id }
    }

    /// Platform to stream from: the selected device's platform, else Android (default tool).
    private var streamPlatform: Platform { selectedDevice?.platform ?? .android }

    /// Change the target device. If the selection actually changes, the current log buffer is
    /// cleared (logs from the previous device — especially a different platform like Android vs
    /// HarmonyOS — must not mix) and, if we were streaming, streaming restarts on the new device.
    func selectDevice(_ id: String?) {
        guard id != selectedDeviceId else { return }
        let wasStreaming = isStreaming
        if wasStreaming { stopStreaming() }
        selectedDeviceId = id
        // Clear the previous device's logs, then restart streaming — awaiting the pipeline clear
        // first so the new stream never ingests into a buffer that's about to be wiped.
        clearing = true
        statusMessage = "Cleared"
        closeSearch()
        Task {
            await pipeline.clear()
            coordinator?.clear()
            displayedCount = 0
            rawCount = 0
            clearing = false
            if wasStreaming { startStreaming() }
        }
    }

    func startStreaming() {
        guard !isStreaming else { return }
        let platform = streamPlatform

        if platform == .harmony {
            if !hdcPath.isEmpty { HdcLocator.userPath = hdcPath }
            guard HdcLocator.resolvedPath() != nil else {
                errorMessage = "未找到 hdc。请在设置中填写 hdc 完整路径（HarmonyOS SDK toolchains 目录下）。"
                return
            }
        } else {
            if !adbPath.isEmpty { AdbLocator.userPath = adbPath }
            guard AdbLocator.resolvedPath() != nil else {
                errorMessage = "未找到 adb。请在右上角设置 adb 完整路径（如 ~/Library/Android/sdk/platform-tools/adb）。"
                return
            }
        }
        errorMessage = nil
        isStreaming = true
        statusMessage = "Streaming…"

        let deviceId = selectedDeviceId
        streamTask = Task.detached(priority: .userInitiated) { [adb, hdc, pipeline, weak self] in
            let stream: AsyncThrowingStream<String, Error> = platform == .harmony
                ? hdc.hilogLines(deviceId: deviceId)
                : adb.logcatLines(deviceId: deviceId)
            var batch: [String] = []
            batch.reserveCapacity(256)
            do {
                for try await line in stream {
                    if Task.isCancelled { break }
                    batch.append(line)
                    if batch.count >= 256 {
                        await pipeline.ingest(lines: batch, platform: platform)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                await self?.applyError(error.localizedDescription, platform: platform)
                return
            }
            if !batch.isEmpty { await pipeline.ingest(lines: batch, platform: platform) }
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        adb.terminate()
        hdc.terminate()
        isStreaming = false
        statusMessage = "Stopped"
    }

    func toggleStreaming() { isStreaming ? stopStreaming() : startStreaming() }

    private func applyError(_ msg: String, platform: Platform) {
        let tool = platform == .harmony ? "hdc" : "adb"
        errorMessage = "\(tool) 错误: \(msg)"
        isStreaming = false
        statusMessage = "Stopped"
    }

    // MARK: - Filter

    /// Debounced + off-main recompute. Replaces the whole document with the new filter result.
    func recompileFilter() {
        let spec = FilterSpec(enabledLevels: enabledLevels, rules: rules)
        let compiled = FilterEngine.compile(spec)
        let kws = highlightKeywords
        let cap = displayCap

        recomputing = true
        recomputeTask?.cancel()
        recomputeTask = Task.detached(priority: .userInitiated) { [pipeline, weak self] in
            try? await Task.sleep(nanoseconds: LogConfig.recomputeDebounceMs * 1_000_000)   // coalesce rapid actions
            if Task.isCancelled { return }
            await pipeline.setFilter(compiled)
            await pipeline.setHighlightKeywords(kws)
            let (chunk, offsets, rc) = await pipeline.recomputeFiltered(maxLines: cap)  // attr + offsets off-main
            await self?.applyRecompute(chunk, offsets: offsets, rawCount: rc, cancelled: Task.isCancelled)
        }
    }

    private func applyRecompute(_ chunk: SendableAttr, offsets: [Int], rawCount: Int, cancelled: Bool) {
        if cancelled { recomputing = false; return }
        coordinator?.replaceAll(chunk.value, offsets: offsets)
        displayedCount = coordinator?.lineCount ?? 0
        self.rawCount = rawCount
        recomputing = false
        if !activeSearchQuery.isEmpty {
            // Document was replaced — re-run the full search and reset the scan cursor.
            let m = coordinator?.findMatches(activeSearchQuery) ?? []
            searchMatches = m
            searchScanCursor = coordinator?.documentLength ?? 0
            searchCurrentIndex = 0
            coordinator?.highlightSearchMatch(m.isEmpty ? nil : m[0])
        } else {
            closeSearch()
        }
    }

    func toggleLevel(_ level: LogLevel) {
        if enabledLevels.contains(level) { enabledLevels.remove(level) }
        else { enabledLevels.insert(level) }
        recompileFilter()
    }

    var allLevelsEnabled: Bool { enabledLevels.count == LogLevel.allCases.count }

    /// Toggle all levels at once: enable all if any are off, otherwise disable all.
    func toggleAllLevels() {
        enabledLevels = allLevelsEnabled ? [] : Set(LogLevel.allCases)
        recompileFilter()
    }

    /// Add a committed (read-only) filter rule from the composer.
    func addRule(text: String, kind: FilterKind) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        rules.append(FilterRule(text: t, kind: kind))
    }

    func deleteRule(id: UUID) { rules.removeAll { $0.id == id } }

    /// Literal message-include terms (from enabled rules) used for in-message highlighting.
    var highlightKeywords: [String] {
        rules.filter { $0.enabled && $0.kind == .msgInclude && !$0.text.isEmpty }.map { $0.text }
    }

    // MARK: - Buffer

    func clearLogs() {
        clearing = true
        statusMessage = "Cleared"
        closeSearch()
        Task {
            await pipeline.clear()
            self.coordinator?.clear()
            self.displayedCount = 0
            self.rawCount = 0
            self.clearing = false
        }
    }

    func jumpToBottom() { coordinator?.scrollToEnd() }

    // MARK: - Search

    var searchMatches: [NSRange] = []
    var searchCurrentIndex: Int = 0   // 0-based
    /// Active query. Non-empty while a search is live; cleared by closeSearch().
    private var activeSearchQuery: String = ""
    /// Char offset up to which we've already scanned for the active query. Avoids re-scanning
    /// the whole document each tick — only new text past this point is scanned.
    private var searchScanCursor: Int = 0

    func runSearch(_ query: String) {
        activeSearchQuery = query
        let m = coordinator?.findMatches(query) ?? []
        searchMatches = m
        searchScanCursor = coordinator?.documentLength ?? 0
        searchCurrentIndex = 0
        coordinator?.highlightSearchMatch(m.isEmpty ? nil : m[0])
    }

    func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        searchCurrentIndex = (searchCurrentIndex + 1) % searchMatches.count
        coordinator?.highlightSearchMatch(searchMatches[searchCurrentIndex])
    }

    func prevMatch() {
        guard !searchMatches.isEmpty else { return }
        searchCurrentIndex = (searchCurrentIndex - 1 + searchMatches.count) % searchMatches.count
        coordinator?.highlightSearchMatch(searchMatches[searchCurrentIndex])
    }

    func closeSearch() {
        coordinator?.clearSearchHighlight()
        coordinator?.clearSearchLock()
        searchMatches = []
        searchCurrentIndex = 0
        activeSearchQuery = ""
        searchScanCursor = 0
    }

    /// Shift stored search match ranges when the document is front-trimmed (lines dropped
    /// from the front). `delta` is negative (char offset removed); matches in the trimmed
    /// region are dropped, the rest shift to stay valid. Also fixes the scan cursor.
    func shiftSearchMatches(by delta: Int) {
        guard delta != 0 else { return }
        searchScanCursor = max(0, searchScanCursor + delta)
        guard !searchMatches.isEmpty else { return }
        var shifted: [NSRange] = []
        for r in searchMatches {
            let newLoc = r.location + delta
            if newLoc < 0 { continue }   // was in the trimmed region
            shifted.append(NSRange(location: newLoc, length: r.length))
        }
        searchMatches = shifted
        if searchCurrentIndex >= searchMatches.count {
            searchCurrentIndex = max(0, searchMatches.count - 1)
        }
        coordinator?.highlightSearchMatch(searchMatches.isEmpty ? nil : searchMatches[searchCurrentIndex])
    }

    /// Incrementally scan newly-appended text for the active search query and merge new matches
    /// into `searchMatches`. Only scans from `searchScanCursor` to the current document end —
    /// O(new text per tick), not O(whole document), so it won't block the main thread.
    func refreshSearchAfterAppend() {
        guard !activeSearchQuery.isEmpty else { return }
        guard let coordinator else { return }
        let docLen = coordinator.documentLength
        // If trim shrank the document below our scan cursor (possible because this runs async
        // on the next runloop pass), reset the cursor and do a full re-scan to stay correct.
        if searchScanCursor > docLen {
            let m = coordinator.findMatches(activeSearchQuery)
            searchMatches = m
            searchScanCursor = docLen
            if searchCurrentIndex >= searchMatches.count {
                searchCurrentIndex = max(0, searchMatches.count - 1)
            }
            coordinator.highlightSearchMatch(searchMatches.isEmpty ? nil : searchMatches[searchCurrentIndex])
            return
        }
        guard docLen > searchScanCursor else { return }   // nothing new
        // Overlap by the query's UTF-16 length - 1 in case a match straddles the cursor boundary.
        let queryLen = (activeSearchQuery as NSString).length
        let overlap = max(0, queryLen - 1)
        let scanStart = max(0, searchScanCursor - overlap)
        let scanRange = NSRange(location: scanStart, length: docLen - scanStart)
        let newMatches = coordinator.findMatches(activeSearchQuery, in: scanRange)
        searchScanCursor = docLen
        guard !newMatches.isEmpty else { return }
        // Merge: existing matches before scanStart are kept as-is; new matches (which are all
        // >= scanStart) are appended in order. Duplicates are possible in the overlap region
        // — dedupe by location.
        if scanStart == 0 {
            searchMatches = newMatches
        } else {
            var merged = searchMatches.filter { $0.location < scanStart }
            let existingLocations = Set(merged.map { $0.location })
            for m in newMatches where !existingLocations.contains(m.location) {
                merged.append(m)
            }
            merged.sort { $0.location < $1.location }
            searchMatches = merged
        }
        // If we were on "no matches" (index 0 of empty), move to first new match.
        if searchCurrentIndex >= searchMatches.count {
            searchCurrentIndex = max(0, searchMatches.count - 1)
        }
    }

    func setFontSize(_ size: Double) {
        let clamped = min(28, max(8, size))
        guard clamped != fontSize else { return }
        fontSize = clamped
        UserDefaults.standard.set(clamped, forKey: LogConfig.fontSizeKey)
        coordinator?.setFontSize(clamped)        // re-apply to existing storage
        Task { await pipeline.setFontSize(clamped) }  // bake into future builds
    }

    func setDisplayCap(_ cap: Int) {
        let clamped = min(100_000, max(1_000, cap))
        guard clamped != displayCap else { return }
        displayCap = clamped
        UserDefaults.standard.set(clamped, forKey: LogConfig.displayCapKey)
        coordinator?.updateCap(clamped)
        Task { await pipeline.setPendingCap(clamped) }
        recompileFilter()
    }

    func setAppearance(_ a: Appearance) {
        guard a != theme.appearance else { return }
        theme.set(a)
        ThemeManagerShared = theme
        coordinator?.applyAppearance()
        recompileFilter()   // rebuild attributed strings with new colors
    }

    // MARK: - Devices

    /// Fetch the current device list (both adb and hdc) and reconcile it with the selection.
    /// Called on launch, on manual refresh, and periodically by the device-poll task so
    /// devices plugged in after the app opened are picked up automatically.
    func refreshDevices() async {
        async let android = DeviceManager.listDevices()
        async let harmony = HdcDeviceManager.listDevices()
        applyDevices(await android + (await harmony))
    }

    private func applyDevices(_ devs: [Device]) {
        guard devs != devices else { return }   // no change → don't disturb UI / selection
        devices = devs
        // Auto-select the first device when nothing is selected, or when the previously
        // selected device was unplugged.
        if selectedDeviceId == nil || !devs.contains(where: { $0.id == selectedDeviceId }) {
            selectedDeviceId = devs.first?.id
        }
        statusMessage = devs.isEmpty ? "无设备连接" : "Idle"
    }

    /// Poll `adb devices` AND `hdc list targets` in the background so hot-plugged devices of
    /// either platform appear without a manual refresh. Lightweight; reconciliation is a no-op
    /// when the merged list is unchanged. hdc polling is a no-op / empty when hdc isn't installed.
    private func startDevicePollTask() {
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                async let android = DeviceManager.listDevices()
                async let harmony = HdcDeviceManager.listDevices()
                let devs = await android + (await harmony)
                guard let self else { return }
                if Task.isCancelled { return }
                self.applyDevices(devs)
                try? await Task.sleep(nanoseconds: LogConfig.devicePollIntervalMs * 1_000_000)
            }
        }
    }

    // MARK: - Drain loop (100ms)

    private func startSnapshotTask() {
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: LogConfig.drainIntervalMs * 1_000_000)
                guard let self else { return }
                if self.paused || self.recomputing || self.clearing { continue }
                // Per-tick capped drain → smooth trickle + bounded main-thread work.
                let result = await self.pipeline.drainPending()
                self.rawCount = result.rawCount
                if result.chunk.value.length > 0 {
                    self.coordinator?.appendChunk(result.chunk.value, offsets: result.offsets)
                    self.displayedCount = self.coordinator?.lineCount ?? 0
                    // Defer search refresh to the next runloop pass: appendChunkNow mutates
                    // textStorage inside beginEditing/endEditing, and reading tv.string or
                    // adding underline attributes in the same pass can race with the layout
                    // manager's drawRect, causing "Range or index out of bounds" crashes.
                    let query = self.activeSearchQuery
                    if !query.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            self?.refreshSearchAfterAppend()
                        }
                    }
                }
            }
        }
    }
}

extension FilterSpec {
    static let `default` = FilterSpec(
        enabledLevels: Set(LogLevel.allCases),
        rules: []
    )
}
