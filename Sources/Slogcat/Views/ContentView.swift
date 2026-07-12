import SwiftUI

struct ContentView: View {
    @Environment(LogStore.self) private var store
    @State private var showAdbConfig = false
    @State private var showFilters = true
    @State private var searchVisible = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    // Device dropdown state lives here (not inside ToolbarView) so the menu can be drawn at
    // the top level and overlay the filter/log area below the toolbar instead of being
    // clipped by it. `deviceMenuFrame` is the picker button's frame in the "root" space.
    @State private var deviceMenuOpen = false
    @State private var deviceMenuFrame: CGRect = .zero

    var body: some View {
        let _ = store.theme.appearance   // explicit dependency so LogTheme colors refresh on toggle
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ToolbarView(showAdbConfig: $showAdbConfig, showFilters: $showFilters,
                            searchVisible: $searchVisible,
                            deviceMenuOpen: $deviceMenuOpen, deviceMenuFrame: $deviceMenuFrame)
                if showFilters {
                    FilterPanel()
                    Rectangle().fill(LogTheme.border).frame(height: 1)
                }
                LogTextView()
                    .overlay(alignment: .topTrailing) {
                        // Offset the extra scroller width (~16pt) on the trailing edge so the
                        // search bar never covers the log view's scrollbar.
                        if searchVisible {
                            searchBar
                                .padding(.top, 8)
                                .padding(.trailing, 8 + 16)
                                .padding(.leading, 8)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let err = store.errorMessage {
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LogTheme.accent)
                                .padding(6)
                                .background(LogTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(LogTheme.accent.opacity(0.5)))
                                .padding(8)
                        }
                    }
            }
            // Device dropdown, drawn at the top level so it sits above the toolbar AND the
            // filter/log area below it.
            deviceMenuOverlay
        }
        .coordinateSpace(name: "root")
        .background(LogTheme.background)
        .background(WindowAccessor { w in
            w.isMovableByWindowBackground = true
            w.backgroundColor = LogTextBuilder.backgroundColor
        })
        .sheet(isPresented: $showAdbConfig) { AdbConfigSheet() }
        // ⌘F opens search
        .background(Button("search") { openSearch() }.keyboardShortcut("f", modifiers: .command).hidden())
        .onChange(of: searchVisible) { _, visible in if visible { searchFocused = true } }
    }

    /// Device dropdown menu, positioned right under the picker button. Only the device rows
    /// are shown (DEFAULT + connected devices); an empty list never opens the menu, so this
    /// only renders when there is something to pick.
    @ViewBuilder
    private var deviceMenuOverlay: some View {
        if deviceMenuOpen {
            // Click-catcher covering the whole window closes the menu on outside taps.
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { deviceMenuOpen = false }

            VStack(spacing: 0) {
                deviceMenuOption("DEFAULT", isSelected: store.selectedDeviceId == nil) {
                    store.selectedDeviceId = nil
                    deviceMenuOpen = false
                }
                ForEach(store.devices) { d in
                    deviceMenuOption(d.id, isSelected: store.selectedDeviceId == d.id) {
                        store.selectedDeviceId = d.id
                        deviceMenuOpen = false
                    }
                }
            }
            .frame(width: max(160, deviceMenuFrame.width))
            .background(LogTheme.background)
            .overlay(Rectangle().stroke(LogTheme.borderStrong))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .offset(x: deviceMenuFrame.minX, y: deviceMenuFrame.maxY + 4)
        }
    }

    private func deviceMenuOption(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSelected ? LogTheme.accent : LogTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? LogTheme.surfaceRaised : Color.clear)
                .overlay(alignment: .leading) {
                    if isSelected { Rectangle().fill(LogTheme.accent).frame(width: 2) }
                }
                .background(PointerCursor())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func openSearch() {
        searchVisible = true
        searchFocused = true
    }

    private var searchBar: some View {
        let hasQuery = !searchQuery.isEmpty
        let hasMatches = !store.searchMatches.isEmpty
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hasMatches ? LogTheme.activeGreen : LogTheme.textSecondary)
            TextField("搜索日志…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LogTheme.textPrimary)
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit { store.runSearch(searchQuery) }
                .onKeyPress(.escape) { searchVisible = false; store.closeSearch(); return .handled }

            // Match counter — accent when there are hits, dim otherwise.
            Text(hasMatches ? "\(store.searchCurrentIndex + 1)/\(store.searchMatches.count)"
                            : (hasQuery ? "0/0" : "—"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(hasMatches ? LogTheme.activeGreen : LogTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 42, alignment: .trailing)

            searchSep()

            searchIconButton("chevron.up", help: "上一个", disabled: !hasMatches) { store.prevMatch() }
            searchIconButton("chevron.down", help: "下一个", disabled: !hasMatches) { store.nextMatch() }

            searchSep()

            searchIconButton("xmark", help: "关闭 (Esc)") { searchVisible = false; store.closeSearch() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(LogTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? LogTheme.activeGreen.opacity(0.6) : LogTheme.borderStrong))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    private func searchSep() -> some View {
        Rectangle().fill(LogTheme.border).frame(width: 1, height: 16)
    }

    private func searchIconButton(_ systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? LogTheme.textSecondary.opacity(0.4) : LogTheme.textPrimary)
        }
        .buttonStyle(ToolbarIconButtonStyle(disabled: disabled))
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @Environment(LogStore.self) private var store
    @Binding var showAdbConfig: Bool
    @Binding var showFilters: Bool
    @Binding var searchVisible: Bool
    @Binding var deviceMenuOpen: Bool
    @Binding var deviceMenuFrame: CGRect

    var body: some View {
        @Bindable var store = store
        // Read appearance so SwiftUI re-evaluates this body when the theme changes (LogTheme
        // static colors are not @Observable, so we need an explicit dependency here).
        let _ = store.theme.appearance
        HStack(spacing: 12) {
            // Brand with status dot (red while streaming)
            HStack(spacing: 7) {
                Circle()
                    .fill(store.isStreaming ? LogTheme.accent : LogTheme.textSecondary)
                    .frame(width: 7, height: 7)
                    .overlay(store.isStreaming ? Circle().fill(LogTheme.accent.opacity(0.4)).frame(width: 13, height: 13) : nil)
                Text("SLOGCAT")
                    .font(LogTheme.labelFont(11))
                    .tracking(1.8)
                    .foregroundStyle(LogTheme.textPrimary)
            }

            sep()

            devicePicker

            iconButton("arrow.clockwise", help: "刷新设备列表") { Task { await store.refreshDevices() } }

            sep()

            // Start / Stop — red prominent while streaming
            Button {
                store.toggleStreaming()
            } label: {
                Label(store.isStreaming ? "STOP" : "START",
                      systemImage: store.isStreaming ? "stop.fill" : "play.fill")
                    .font(LogTheme.labelFont(10))
                    .tracking(1)
            }
            .tint(store.isStreaming ? LogTheme.accent : LogTheme.textPrimary)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            iconButton(store.paused ? "play.fill" : "pause.fill", help: "暂停/继续", disabled: !store.isStreaming) {
                store.paused.toggle()
            }
            iconButton("trash", help: "清屏") { store.clearLogs() }
            iconButton("arrow.down.to.line", help: "跳到最新") { store.jumpToBottom() }
            iconButton(showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       help: "过滤项") { showFilters.toggle() }
            iconButton("magnifyingglass", help: "搜索 (⌘F)") { searchVisible = true }

            Spacer()

            iconButton(store.theme.isDark ? "sun.max" : "moon",
                       help: store.theme.isDark ? "切换日间" : "切换夜间") {
                store.setAppearance(store.theme.isDark ? .light : .dark)
            }

            // Font size
            HStack(spacing: 2) {
                iconButton("minus", help: "缩小文字") { store.setFontSize(store.fontSize - 1) }
                Text("\(Int(store.fontSize))")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 22)
                    .foregroundStyle(LogTheme.textSecondary)
                iconButton("plus", help: "放大文字") { store.setFontSize(store.fontSize + 1) }
            }

            sep()

            iconButton("gearshape", help: "设置") { showAdbConfig = true }
        }
        .padding(.leading, 12)     // align with FilterPanel content below
        .padding(.trailing, 12)
        .padding(.top, 28)         // clear the traffic-light area (hidden title bar)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "toolbar")
        .background(DotGridBackground())
        .background(LogTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(LogTheme.border).frame(height: 1) }
    }

    private var devicePicker: some View {
        let hasDevices = !store.devices.isEmpty
        let label = hasDevices ? (store.selectedDeviceId ?? "DEFAULT") : "WAITING FOR DEVICE"
        return Button {
            guard hasDevices else { return }   // nothing to pick → don't open an empty menu
            deviceMenuOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(hasDevices ? LogTheme.textPrimary : LogTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LogTheme.textSecondary)
                    .opacity(hasDevices ? 1 : 0.35)
                    .rotationEffect(.degrees(deviceMenuOpen ? 180 : 0))
                    .animation(.easeInOut(duration: 0.15), value: deviceMenuOpen)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(LogTheme.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(LogTheme.borderStrong))
            .contentShape(Rectangle())
            // Report the button's frame in the window-level "root" space so ContentView can
            // position the dropdown right below it.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { deviceMenuFrame = geo.frame(in: .named("root")) }
                        .onChange(of: geo.frame(in: .named("root"))) { _, f in deviceMenuFrame = f }
                }
            )
        }
        .buttonStyle(PressableButtonStyle())
        // Close the menu if all devices disconnect while it's open.
        .onChange(of: store.devices.isEmpty) { _, empty in if empty { deviceMenuOpen = false } }
    }

    private func sep() -> some View {
        Rectangle().fill(LogTheme.border).frame(width: 1, height: 14)
    }

    private func iconButton(_ systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(disabled ? LogTheme.textSecondary.opacity(0.4) : LogTheme.textPrimary)
        }
        .buttonStyle(ToolbarIconButtonStyle(disabled: disabled))
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - settings sheet

struct AdbConfigSheet: View {
    @Environment(LogStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var capInput: String = ""

    var body: some View {
        @Bindable var store = store
        let _ = store.theme.appearance
        VStack(alignment: .leading, spacing: 18) {
            // Section: ADB Path
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(LogTheme.accent).frame(width: 7, height: 7)
                    Text("ADB PATH").font(LogTheme.labelFont(11)).tracking(1.5)
                }
                Text("留空则自动检测（~/Library/Android/sdk/platform-tools/adb 等）。\n填入完整路径可手动指定。")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LogTheme.textSecondary)
                    .lineSpacing(3)
                TextField("/Users/you/Library/Android/sdk/platform-tools/adb", text: $store.adbPath)
                    .techField()
            }

            Rectangle().fill(LogTheme.border).frame(height: 1)

            // Section: Font size
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(LogTheme.accent).frame(width: 7, height: 7)
                    Text("FONT SIZE").font(LogTheme.labelFont(11)).tracking(1.5)
                }
                Text("日志文字的字号，可用工具栏的 −/＋ 或此处调整（8–28）。")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LogTheme.textSecondary)
                HStack(spacing: 10) {
                    Button { store.setFontSize(store.fontSize - 1) } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                    Text("\(Int(store.fontSize)) pt")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LogTheme.textPrimary)
                        .frame(minWidth: 50)
                    Button { store.setFontSize(store.fontSize + 1) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                    Spacer()
                    Text("\(Int(store.fontSize)) / 8–28")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LogTheme.textSecondary)
                }
            }

            Rectangle().fill(LogTheme.border).frame(height: 1)

            // Section: Appearance
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(LogTheme.accent).frame(width: 7, height: 7)
                    Text("APPEARANCE").font(LogTheme.labelFont(11)).tracking(1.5)
                }
                Text("界面主题：夜间为深色护眼，日间为浅色高亮。")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LogTheme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(Appearance.allCases) { a in
                        Button {
                            store.setAppearance(a)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: a == .dark ? "moon" : "sun.max")
                                    .font(.system(size: 11))
                                Text(a.label)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(store.theme.appearance == a ? LogTheme.accent : LogTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(store.theme.appearance == a ? LogTheme.accent.opacity(0.10) : LogTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(store.theme.appearance == a ? LogTheme.accent.opacity(0.5) : LogTheme.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }

            Rectangle().fill(LogTheme.border).frame(height: 1)

            // Section: Display cap
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(LogTheme.accent).frame(width: 7, height: 7)
                    Text("MAX LINES").font(LogTheme.labelFont(11)).tracking(1.5)
                }
                Text("显示窗口中保留的最大日志行数，超出后从最旧开始丢弃。")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LogTheme.textSecondary)
                HStack(spacing: 10) {
                    TextField("\(LogConfig.defaultDisplayCap)", text: $capInput)
                        .techField()
                        .onSubmit { commitCap() }
                    Button("应用") { commitCap() }
                        .font(LogTheme.labelFont(10))
                        .tracking(1)
                        .tint(LogTheme.textPrimary)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Text("当前: \(store.displayCap) 行  范围: 1000–100000")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LogTheme.textSecondary)
            }

            HStack {
                Spacer()
                Button("DONE") { dismiss() }
                    .font(LogTheme.labelFont(10))
                    .tracking(1)
                    .tint(LogTheme.textPrimary)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { capInput = "\(store.displayCap)" }
        .padding(22)
        .frame(width: 480)
        .background(DotGridBackground())
        .background(LogTheme.background)
    }

    private func commitCap() {
        guard let v = Int(capInput.filter { $0.isNumber }) else { return }
        store.setDisplayCap(v)
        capInput = "\(store.displayCap)"
    }
}
