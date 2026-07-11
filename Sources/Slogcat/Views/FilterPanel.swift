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

    var body: some View {
        @Bindable var store = store
        let _ = store.theme.appearance   // refresh LogTheme colors on appearance toggle
        FlowLayout(spacing: 6) {
            ForEach(LogLevel.allCases) { lvl in
                levelChip(lvl)
            }
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
        .zIndex(menuOpen ? 1000 : 0)
        .onChange(of: store.rules) { _, _ in store.recompileFilter() }
    }

    // MARK: Composer (fixed editor)

    private var composer: some View {
        HStack(spacing: 0) {
            Button {
                menuOpen.toggle()
            } label: {
                HStack(spacing: 3) {
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

    // MARK: Dropdown list (sharp corners, opens below the trigger)

    private var dropdownList: some View {
        VStack(spacing: 0) {
            ForEach(FilterKind.allCases) { kind in
                DropdownOption(
                    label: kind.rawValue,
                    isExclude: kind.isExclude,
                    isSelected: composerKind == kind,
                    action: {
                        composerKind = kind
                        menuOpen = false
                    }
                )
            }
        }
        .frame(width: 108)
        .background(LogTheme.background)
        .overlay(Rectangle().stroke(LogTheme.borderStrong))
    }

    // MARK: Committed chip (read-only, toggleable, deletable)

    private func committedChip(_ rule: FilterRule) -> some View {
        @Bindable var rule = rule
        let isExclude = rule.kind.isExclude
        let accent = isExclude ? LogTheme.accent : LogTheme.textPrimary
        let borderColor = rule.enabled
            ? (isExclude ? LogTheme.accent.opacity(0.55) : LogTheme.borderStrong)
            : LogTheme.border

        return HStack(spacing: 6) {
            Button {
                rule.enabled.toggle()
                store.recompileFilter()
            } label: {
                Image(systemName: rule.enabled ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(rule.enabled ? accent : LogTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(rule.enabled ? "停用" : "启用")

            Text(rule.kind.rawValue)
                .font(LogTheme.labelFont(9))
                .foregroundStyle(rule.enabled ? accent : LogTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()

            Text(rule.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(rule.enabled ? LogTheme.textPrimary : LogTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 40, maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                store.deleteRule(id: rule.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LogTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)   // chip always sizes to content, never wraps
        .background(rule.enabled
            ? (isExclude ? LogTheme.accent.opacity(0.08) : LogTheme.surface)
            : LogTheme.surface.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(borderColor))
    }

    private func levelChip(_ lvl: LogLevel) -> some View {
        let on = store.enabledLevels.contains(lvl)
        let c = LogTheme.color(for: lvl)
        return Button {
            store.toggleLevel(lvl)
        } label: {
            Text(lvl.rawValue)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? c : LogTheme.textSecondary)
                .frame(height: 30)
                .frame(minWidth: 28)
                .fixedSize(horizontal: true, vertical: false)
                .background(on ? c.opacity(0.14) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(c.opacity(on ? 0.7 : 0.18)))
        }
        .buttonStyle(.plain)
        .help(lvl.displayName)
    }
}

// MARK: - Dropdown option (hover + selected states)

private struct DropdownOption: View {
    let label: String
    let isExclude: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isExclude ? LogTheme.accent : LogTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isHovered ? LogTheme.surfaceRaised : Color.clear)
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle().fill(LogTheme.accent).frame(width: 2)
                    }
                }
                .background(PointerCursor())   // hand cursor via AppKit cursor rect
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
