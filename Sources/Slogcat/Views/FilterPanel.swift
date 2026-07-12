import AppKit
import SwiftUI

/// Filter UI: a fixed composer at the front (text + mode dropdown, Enter to commit) followed
/// by read-only committed rule chips that can be enabled/disabled or deleted.
struct FilterPanel: View {
    @Environment(LogStore.self) private var store
    @State private var composerText: String = ""
    @State private var composerKind: FilterKind = .msgInclude
    @State private var menuOpen: Bool = false
    @State private var menuFrame: CGRect = .zero
    @State private var levelMenuOpen: Bool = false
    @State private var levelMenuFrame: CGRect = .zero

    var body: some View {
        @Bindable var store = store
        let _ = store.theme.appearance   // refresh LogTheme colors on appearance toggle
        FlowLayout(spacing: 6) {
            levelSummaryChip
            composer
            ForEach(store.rules) { rule in
                @Bindable var rule = rule
                committedChip(rule)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DotGridBackground())
        .background(LogTheme.background)
        .coordinateSpace(name: "filterPanel")
        .overlay(alignment: .topLeading) {
            if menuOpen {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 10_000, height: 10_000)
                        .offset(x: -5_000, y: -5_000)
                        .contentShape(Rectangle())
                        .onTapGesture { menuOpen = false }
                    dropdownList
                        .offset(x: menuFrame.minX, y: menuFrame.maxY + 4)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if levelMenuOpen {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 10_000, height: 10_000)
                        .offset(x: -5_000, y: -5_000)
                        .contentShape(Rectangle())
                        .onTapGesture { levelMenuOpen = false }
                    levelPopover
                        .offset(x: levelMenuFrame.minX, y: levelMenuFrame.maxY + 4)
                }
            }
        }
        .zIndex((menuOpen || levelMenuOpen) ? 1000 : 0)
        .onChange(of: store.rules) { _, _ in store.recompileFilter() }
    }

    // MARK: Composer (fixed editor)

    private var composer: some View {
        HStack(spacing: 0) {
            Button {
                menuOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: composerKind.icon)
                        .font(.system(size: 10, weight: .medium))
                    Text(composerKind.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(menuOpen ? 180 : 0))
                        .animation(.easeInOut(duration: 0.15), value: menuOpen)
                }
                .foregroundStyle(composerKind.isExclude ? LogTheme.accent : LogTheme.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { menuFrame = geo.frame(in: .named("filterPanel")) }
                            .onChange(of: geo.frame(in: .named("filterPanel"))) { _, newFrame in
                                menuFrame = newFrame
                            }
                    }
                )
            }
            .buttonStyle(.plain)

            Rectangle().fill(LogTheme.border).frame(width: 1, height: 16)

            TextField("输入过滤项 ⏎", text: $composerText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LogTheme.textPrimary)
                .frame(width: 180)
                .padding(.leading, 6)
                .onSubmit {
                    let t = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    store.addRule(text: t, kind: composerKind)
                    composerText = ""
                }
        }
        .frame(height: 30)
        .background(LogTheme.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(composerKind.isExclude ? LogTheme.accent.opacity(0.5) : LogTheme.borderStrong)
        )
    }

    // MARK: Dropdown list — grouped by field, each row shows icon + mode + hint

    private var dropdownList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(FilterKind.Field.allCases.enumerated()), id: \.element.id) { idx, field in
                if idx > 0 {
                    Rectangle().fill(LogTheme.border).frame(height: 1)
                }
                // Group header
                Text(field.rawValue)
                    .font(LogTheme.labelFont(9))
                    .tracking(1.2)
                    .foregroundStyle(LogTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 3)
                ForEach(FilterKind.allCases.filter { $0.field == field }) { kind in
                    DropdownOption(
                        kind: kind,
                        isSelected: composerKind == kind,
                        action: {
                            composerKind = kind
                            menuOpen = false
                        }
                    )
                }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 240)
        .background(LogTheme.background)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LogTheme.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    // MARK: Committed chip (read-only, toggleable, deletable)
    // Layout hierarchy: the user's keyword (rule.text) is the hero — largest & highest
    // contrast. The mode (icon + tiny label) is secondary, tucked to the left behind a
    // divider. Clicking the mode area toggles enable/disable.

    private func committedChip(_ rule: FilterRule) -> some View {
        @Bindable var rule = rule
        let isExclude = rule.kind.isExclude
        let modeColor = rule.enabled ? (isExclude ? LogTheme.accent : LogTheme.textSecondary)
                                     : LogTheme.textSecondary.opacity(0.6)
        let borderColor = rule.enabled
            ? (isExclude ? LogTheme.accent.opacity(0.55) : LogTheme.borderStrong)
            : LogTheme.border

        return HStack(spacing: 0) {
            // Mode area (icon + tiny label) — click toggles enable/disable.
            Button {
                rule.enabled.toggle()
                store.recompileFilter()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: rule.kind.icon)
                        .font(.system(size: 10, weight: .medium))
                    Text(rule.kind.rawValue)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(modeColor)
                .opacity(rule.enabled ? 1 : 0.7)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .background(PointerCursor())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(rule.enabled ? "点击停用此过滤" : "点击启用此过滤")

            Rectangle().fill(LogTheme.border).frame(width: 1, height: 16)

            // Keyword (hero) — largest, highest contrast.
            Text(rule.text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(rule.enabled ? LogTheme.textPrimary : LogTheme.textSecondary)
                .strikethrough(!rule.enabled, color: LogTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 30, maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 8)
                .padding(.trailing, 6)

            Button {
                store.deleteRule(id: rule.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LogTheme.textSecondary)
                    .padding(.trailing, 8)
                    .padding(.leading, 2)
                    .frame(maxHeight: .infinity)
                    .background(PointerCursor())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)   // chip always sizes to content, never wraps
        .background(rule.enabled
            ? (isExclude ? LogTheme.accent.opacity(0.08) : LogTheme.surface)
            : LogTheme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(borderColor))
    }

    // MARK: Level filter — single summary chip that opens a popover

    /// Compact entry point: shows which levels are currently visible. Clicking opens the
    /// popover where individual levels are toggled — keeps the filter bar tidy.
    private var levelSummaryChip: some View {
        let enabled = LogLevel.allCases.filter { store.enabledLevels.contains($0) }
        let all = store.allLevelsEnabled
        let none = enabled.isEmpty
        return Button {
            levelMenuOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LogTheme.textSecondary)
                Text("等级")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LogTheme.textPrimary)
                Rectangle().fill(LogTheme.border).frame(width: 1, height: 12)
                // Summary: colored level letters, or 全部 / 无.
                if all {
                    Text("全部").font(.system(size: 10, weight: .medium)).foregroundStyle(LogTheme.textSecondary)
                } else if none {
                    Text("无").font(.system(size: 10, weight: .medium)).foregroundStyle(LogTheme.accent)
                } else {
                    HStack(spacing: 3) {
                        ForEach(enabled) { lvl in
                            Text(lvl.rawValue)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(LogTheme.color(for: lvl))
                        }
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LogTheme.textSecondary)
                    .rotationEffect(.degrees(levelMenuOpen ? 180 : 0))
                    .animation(.easeInOut(duration: 0.15), value: levelMenuOpen)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .fixedSize(horizontal: true, vertical: false)
            .background(LogTheme.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(none ? LogTheme.accent.opacity(0.5) : LogTheme.borderStrong))
            // Report frame in the filter-panel space so the popover opens right below.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { levelMenuFrame = geo.frame(in: .named("filterPanel")) }
                        .onChange(of: geo.frame(in: .named("filterPanel"))) { _, f in levelMenuFrame = f }
                }
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help("日志等级过滤")
    }

    /// Popover body: an "all" toggle header + one row per level.
    private var levelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.toggleAllLevels()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.allLevelsEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.allLevelsEnabled ? LogTheme.activeGreen : LogTheme.textSecondary)
                    Text(store.allLevelsEnabled ? "全部隐藏" : "全部显示")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LogTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PointerCursor())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(LogTheme.border).frame(height: 1)

            ForEach(LogLevel.allCases) { lvl in
                levelRow(lvl)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 190)
        .background(LogTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LogTheme.borderStrong))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    private func levelRow(_ lvl: LogLevel) -> some View {
        let on = store.enabledLevels.contains(lvl)
        let c = LogTheme.color(for: lvl)
        return LevelRow(level: lvl, tint: c, on: on) { store.toggleLevel(lvl) }
    }
}

// MARK: - Level row inside the popover

private struct LevelRow: View {
    let level: LogLevel
    let tint: Color
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Color swatch with the level letter.
                Text(level.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(on ? tint : LogTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(on ? tint.opacity(0.16) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(on ? 0.7 : 0.2)))
                Text(level.displayName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(on ? LogTheme.textPrimary : LogTheme.textSecondary)
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LogTheme.activeGreen)
                    .frame(width: 12)
                    .opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? LogTheme.surfaceRaised : Color.clear)
            .background(PointerCursor())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Dropdown option (icon + mode + hint, hover + selected states)

private struct DropdownOption: View {
    let kind: FilterKind
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let tint = kind.isExclude ? LogTheme.accent : LogTheme.textPrimary
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: kind.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.modeLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(tint)
                    Text(kind.hint)
                        .font(.system(size: 10))
                        .foregroundStyle(LogTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LogTheme.activeGreen)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? LogTheme.surfaceRaised : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(LogTheme.activeGreen).frame(width: 2) }
            }
            .background(PointerCursor())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Flow layout (wraps subviews into rows)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                height += rowHeight + spacing
                rowHeight = 0
                x = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: min(maxWidth, proposal.width ?? maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
