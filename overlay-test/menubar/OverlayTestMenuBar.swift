import AppKit
import CoreGraphics
import Foundation

// MARK: - Variant & Parameter Definitions

private enum VariantExtraKind {
    case none
    case v11State
    case v14Theme
    case v15Stage
}

private struct OverlayVariant {
    let id: String
    let shortTitle: String
    let menuTitle: String
    let supportsStyle: Bool
    let supportsAlwaysExpanded: Bool
    let supportsDockEdge: Bool
    let extraKind: VariantExtraKind

    static let all: [OverlayVariant] = [
        OverlayVariant(id: "v1", shortTitle: "V1", menuTitle: "V1 · 定稿基准版（全窗五色渐变 + 星点闪烁）", supportsStyle: false, supportsAlwaysExpanded: false, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v2", shortTitle: "V2", menuTitle: "V2 · 极简棱镜光带（全清中心 + 6 色边带）", supportsStyle: true, supportsAlwaysExpanded: false, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v3", shortTitle: "V3", menuTitle: "V3 · 活体事件驱动（待机隐退 + 指针唤醒）", supportsStyle: true, supportsAlwaysExpanded: false, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v4", shortTitle: "V4", menuTitle: "V4 · 全窗液态玻璃（真磨砂 + 斜向双反光）", supportsStyle: true, supportsAlwaysExpanded: false, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v5", shortTitle: "V5", menuTitle: "V5 · Ego Lite 复刻（9pt 针尖点阵 + 扫光浪）", supportsStyle: true, supportsAlwaysExpanded: false, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v6", shortTitle: "V6", menuTitle: "V6 · 智能折叠胶囊（4s 收折 + 光环联动）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v7", shortTitle: "V7", menuTitle: "V7 · 外溢环境光（窗外 40pt Ambilight 光晕）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v8", shortTitle: "V8", menuTitle: "V8 · 接驳脉冲丝带（底部接口 + 双路光纤｜已淘汰）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v9", shortTitle: "V9", menuTitle: "V9 · 丝绸干涉极光边（高饱和宽幅波浪）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v10", shortTitle: "V10", menuTitle: "V10 · Ego Lite × V6 融合（点阵扫光 + 胶囊联动）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .none),
        OverlayVariant(id: "v11", shortTitle: "V11", menuTitle: "V11 · 多态状态语义切换（推流/暂停/重连/隐私）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: false, extraKind: .v11State),
        OverlayVariant(id: "v12", shortTitle: "V12", menuTitle: "V12 · 四边磁吸 + 顶栏融合（窗体居上零糊字）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: true, extraKind: .none),
        OverlayVariant(id: "v13", shortTitle: "V13", menuTitle: "V13 · 窗外取景框 + 双星巡航（光学锁定角标）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: true, extraKind: .none),
        OverlayVariant(id: "v14", shortTitle: "V14", menuTitle: "V14 · 量子棱镜全息极光（色散 + 点击脉冲波）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: true, extraKind: .v14Theme),
        OverlayVariant(id: "v15", shortTitle: "V15", menuTitle: "V15 · 零边框立体氛围舞台（无框窗后光影舞台）", supportsStyle: true, supportsAlwaysExpanded: true, supportsDockEdge: true, extraKind: .v15Stage),
    ]

    static func find(_ raw: String) -> OverlayVariant? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == normalized || $0.shortTitle.lowercased() == normalized }
    }
}

private enum ProbeStyle: String, CaseIterable {
    case subtle, standard, vivid
    var title: String {
        switch self {
        case .subtle: return "柔和 (subtle)"
        case .standard: return "标准 (standard)"
        case .vivid: return "鲜明 (vivid)"
        }
    }
}

private enum ProbeAppearance: String, CaseIterable {
    case auto, light, dark
    var title: String {
        switch self {
        case .auto: return "跟随系统 (auto)"
        case .light: return "浅色窗口 (light)"
        case .dark: return "深色窗口 (dark)"
        }
    }
}

private enum ProbeDock: String, CaseIterable {
    case versionDefault, top, bottom, left, right
    var title: String {
        switch self {
        case .versionDefault: return "跟随各版本默认边"
        case .top: return "顶部 (top)"
        case .bottom: return "底部 (bottom)"
        case .left: return "左侧 (left)"
        case .right: return "右侧 (right)"
        }
    }
}

private enum V11Mode: String, CaseIterable {
    case live, paused, reconnecting, privacy, cycle
    var title: String {
        switch self {
        case .live: return "推流中 (live)"
        case .paused: return "已暂停 (paused)"
        case .reconnecting: return "重连雷达 (reconnecting)"
        case .privacy: return "隐私遮罩 (privacy)"
        case .cycle: return "自动轮播 (--cycle)"
        }
    }
}

private enum V14ThemeOption: String, CaseIterable {
    case prism, violet, solar, emerald
    var title: String {
        switch self {
        case .prism: return "全息棱镜 (prism)"
        case .violet: return "紫电超频 (violet)"
        case .solar: return "炽焰极光 (solar)"
        case .emerald: return "矩阵翡翠 (emerald)"
        }
    }
}

private enum V15StageOption: String, CaseIterable {
    case nebula, spotlight, caustics
    var title: String {
        switch self {
        case .nebula: return "星云萤火 (nebula)"
        case .spotlight: return "英雄聚光 (spotlight)"
        case .caustics: return "水波焦散 (caustics)"
        }
    }
}

// MARK: - Window Discovery

private struct WindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect

    static func visibleWindows() -> [WindowSnapshot] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let myPID = ProcessInfo.processInfo.processIdentifier
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  pid != myPID,
                  (row[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 100,
                  frame.height > 100,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 else {
                return nil
            }
            let owner = row[kCGWindowOwnerName as String] as? String ?? ""
            let title = row[kCGWindowName as String] as? String ?? ""
            return WindowSnapshot(id: id, pid: pid, owner: owner, title: title, frame: frame)
        }
    }
}

private enum TargetSelection: Equatable {
    case appFrontmost(String)
    case windowID(CGWindowID, ownerHint: String)

    var displayName: String {
        switch self {
        case .appFrontmost(let name): return name
        case .windowID(let id, let ownerHint): return "\(ownerHint) (#\(id))"
        }
    }
}

// MARK: - Root Resolution

private func resolveOverlayTestRoot(explicitRoot: String?) -> URL? {
    let fm = FileManager.default
    func isValidRoot(_ url: URL) -> Bool {
        let core = url.appendingPathComponent("shared/OverlayProbeCore.swift").path
        let v1 = url.appendingPathComponent("v1/WindowOverlayProbe.swift").path
        return fm.fileExists(atPath: core) && fm.fileExists(atPath: v1)
    }

    var candidates: [URL] = []
    if let explicitRoot, !explicitRoot.isEmpty {
        candidates.append(URL(fileURLWithPath: explicitRoot, isDirectory: true))
    }
    if let envRoot = ProcessInfo.processInfo.environment["OVERLAY_TEST_ROOT"], !envRoot.isEmpty {
        candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
    }
    if let match = candidates.first(where: isValidRoot) {
        return match
    }

    // Walk up from bundle/executable paths so launching via .app or CLI resolves overlay-test/.
    for seed in [Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]), URL(fileURLWithPath: fm.currentDirectoryPath)] {
        var cur = seed.standardizedFileURL
        for _ in 0..<6 {
            if isValidRoot(cur) { return cur }
            let child = cur.appendingPathComponent("overlay-test", isDirectory: true)
            if isValidRoot(child) { return child }
            cur.deleteLastPathComponent()
        }
    }
    return nil
}

// MARK: - Menu Bar Controller

private final class OverlaySwitcherApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlayRoot: URL
    private let defaultAppName: String
    private var initialVariantID: String?

    private var targetSelection: TargetSelection
    private var currentVariant: OverlayVariant?
    private var style: ProbeStyle = .standard
    private var appearance: ProbeAppearance = .auto
    private var dockEdge: ProbeDock = .versionDefault
    private var alwaysExpanded = false
    private var hideChildStatusItem = true

    private var v11Mode: V11Mode = .live
    private var v14Theme: V14ThemeOption = .prism
    private var v15Stage: V15StageOption = .nebula

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusHeadlineItem: NSMenuItem!
    private var targetInfoItem: NSMenuItem!
    private var prevItem: NSMenuItem!
    private var nextItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var variantItems: [String: NSMenuItem] = [:]

    private var targetMenu: NSMenu!
    private var styleItems: [ProbeStyle: NSMenuItem] = [:]
    private var appearanceItems: [ProbeAppearance: NSMenuItem] = [:]
    private var expandToggleItem: NSMenuItem!
    private var dockItems: [ProbeDock: NSMenuItem] = [:]
    private var hideChildStatusMenuItem: NSMenuItem!
    private var v11Items: [V11Mode: NSMenuItem] = [:]
    private var v14Items: [V14ThemeOption: NSMenuItem] = [:]
    private var v15Items: [V15StageOption: NSMenuItem] = [:]

    private let workerQueue = DispatchQueue(label: "com.cabinw.kkremote.overlay-menubar.worker")
    private var activeProcess: Process?
    private var activeVariantID: String?
    private var switchGeneration: UInt64 = 0
    private var isCompiling = false
    private var lastStatusNote: String?

    init(overlayRoot: URL, defaultAppName: String, initialTarget: TargetSelection, initialVariantID: String?, style: ProbeStyle, appearance: ProbeAppearance) {
        self.overlayRoot = overlayRoot
        self.defaultAppName = defaultAppName
        self.targetSelection = initialTarget
        self.initialVariantID = initialVariantID
        self.style = style
        self.appearance = appearance
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBar()
        syncMenuStates()

        if let initialVariantID, let variant = OverlayVariant.find(initialVariantID) {
            selectAndLaunch(variant)
        } else {
            updateStatusBarAppearance()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopActiveProcessSync()
    }

    // MARK: - Menu Construction

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarAppearance()

        menu.delegate = self
        menu.autoenablesItems = false

        statusHeadlineItem = NSMenuItem(title: "状态：待机", action: nil, keyEquivalent: "")
        statusHeadlineItem.isEnabled = false
        menu.addItem(statusHeadlineItem)

        targetInfoItem = NSMenuItem(title: "目标：\(targetSelection.displayName)", action: nil, keyEquivalent: "")
        targetInfoItem.isEnabled = false
        menu.addItem(targetInfoItem)

        menu.addItem(.separator())

        prevItem = makeItem(title: "← 上一个效果", action: #selector(selectPreviousVariant), key: "[")
        menu.addItem(prevItem)

        nextItem = makeItem(title: "→ 下一个效果", action: #selector(selectNextVariant), key: "]")
        menu.addItem(nextItem)

        restartItem = makeItem(title: "↻ 重新挂载当前效果", action: #selector(restartCurrentVariant), key: "r")
        menu.addItem(restartItem)

        stopItem = makeItem(title: "⏹ 停止当前遮罩", action: #selector(stopCurrentVariant), key: "0")
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let sectionLabel = NSMenuItem(title: "选择遮罩方案（V1 – V15）", action: nil, keyEquivalent: "")
        sectionLabel.isEnabled = false
        menu.addItem(sectionLabel)

        for (index, variant) in OverlayVariant.all.enumerated() {
            let item = NSMenuItem(title: variant.menuTitle, action: #selector(selectVariantItem(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            variantItems[variant.id] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Variant-specific presets submenu (clicking an item picks its submode AND activates that variant).
        let presetSubmenu = NSMenu()
        let v11Header = NSMenuItem(title: "V11 状态预设（点击即切到 V11）", action: nil, keyEquivalent: "")
        v11Header.isEnabled = false
        presetSubmenu.addItem(v11Header)
        for (idx, mode) in V11Mode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectV11Mode(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            v11Items[mode] = item
            presetSubmenu.addItem(item)
        }
        presetSubmenu.addItem(.separator())
        let v14Header = NSMenuItem(title: "V14 光谱主题（点击即切到 V14）", action: nil, keyEquivalent: "")
        v14Header.isEnabled = false
        presetSubmenu.addItem(v14Header)
        for (idx, theme) in V14ThemeOption.allCases.enumerated() {
            let item = NSMenuItem(title: theme.title, action: #selector(selectV14Theme(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            v14Items[theme] = item
            presetSubmenu.addItem(item)
        }
        presetSubmenu.addItem(.separator())
        let v15Header = NSMenuItem(title: "V15 立体舞台（点击即切到 V15）", action: nil, keyEquivalent: "")
        v15Header.isEnabled = false
        presetSubmenu.addItem(v15Header)
        for (idx, stage) in V15StageOption.allCases.enumerated() {
            let item = NSMenuItem(title: stage.title, action: #selector(selectV15Stage(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            v15Items[stage] = item
            presetSubmenu.addItem(item)
        }
        let presetRoot = NSMenuItem(title: "版本专属子模式 (V11 / V14 / V15)", action: nil, keyEquivalent: "")
        presetRoot.submenu = presetSubmenu
        menu.addItem(presetRoot)

        // Shared parameters submenu
        let paramsSubmenu = NSMenu()
        let styleHeader = NSMenuItem(title: "遮罩强度（V2–V15 生效）", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        paramsSubmenu.addItem(styleHeader)
        for (idx, candidate) in ProbeStyle.allCases.enumerated() {
            let item = NSMenuItem(title: candidate.title, action: #selector(selectStyleOption(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            styleItems[candidate] = item
            paramsSubmenu.addItem(item)
        }

        paramsSubmenu.addItem(.separator())
        let appearanceHeader = NSMenuItem(title: "明暗外观", action: nil, keyEquivalent: "")
        appearanceHeader.isEnabled = false
        paramsSubmenu.addItem(appearanceHeader)
        for (idx, mode) in ProbeAppearance.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectAppearanceOption(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            appearanceItems[mode] = item
            paramsSubmenu.addItem(item)
        }

        paramsSubmenu.addItem(.separator())
        let dockHeader = NSMenuItem(title: "胶囊停靠边缘（V12–V15 生效）", action: nil, keyEquivalent: "")
        dockHeader.isEnabled = false
        paramsSubmenu.addItem(dockHeader)
        for (idx, edge) in ProbeDock.allCases.enumerated() {
            let item = NSMenuItem(title: edge.title, action: #selector(selectDockOption(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            dockItems[edge] = item
            paramsSubmenu.addItem(item)
        }

        paramsSubmenu.addItem(.separator())
        expandToggleItem = makeItem(title: "控制胶囊常驻展开（V6–V15 生效）", action: #selector(toggleAlwaysExpanded), key: "")
        paramsSubmenu.addItem(expandToggleItem)

        hideChildStatusMenuItem = makeItem(title: "隐藏子探针独立菜单栏图标（推荐）", action: #selector(toggleHideChildStatusItem), key: "")
        paramsSubmenu.addItem(hideChildStatusMenuItem)

        let paramsRoot = NSMenuItem(title: "外观与控制条参数", action: nil, keyEquivalent: "")
        paramsRoot.submenu = paramsSubmenu
        menu.addItem(paramsRoot)

        // Target window submenu (populated dynamically on menu open)
        targetMenu = NSMenu()
        let targetRoot = NSMenuItem(title: "演示目标窗口（默认 \(defaultAppName)）", action: nil, keyEquivalent: "")
        targetRoot.submenu = targetMenu
        menu.addItem(targetRoot)

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "退出 OverlayTest 菜单栏", action: #selector(quitApp), key: "q"))

        statusItem.menu = menu
    }

    private func makeItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            rebuildTargetSubmenu()
            refreshTargetInfoLine()
            syncMenuStates()
        }
    }

    private func rebuildTargetSubmenu() {
        targetMenu.removeAllItems()

        let defaultItem = NSMenuItem(title: "自动跟随 \(defaultAppName) 前景窗口（默认）", action: #selector(selectDefaultAppTarget), keyEquivalent: "")
        defaultItem.target = self
        if case .appFrontmost(let owner) = targetSelection, owner == defaultAppName {
            defaultItem.state = .on
        }
        targetMenu.addItem(defaultItem)
        targetMenu.addItem(.separator())

        let windows = WindowSnapshot.visibleWindows()
        if windows.isEmpty {
            let empty = NSMenuItem(title: "当前未检测到可用桌面窗口", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            targetMenu.addItem(empty)
            return
        }

        // Group or sort PopAgent first so it's always effortless to re-pick.
        let sorted = windows.sorted { lhs, rhs in
            let lIsDefault = lhs.owner == defaultAppName
            let rIsDefault = rhs.owner == defaultAppName
            if lIsDefault != rIsDefault { return lIsDefault }
            if lhs.owner != rhs.owner { return lhs.owner.localizedCaseInsensitiveCompare(rhs.owner) == .orderedAscending }
            return lhs.id < rhs.id
        }

        for w in sorted {
            let cleanTitle = w.title.isEmpty ? "(无标题)" : String(w.title.prefix(30))
            let sizeStr = "\(Int(w.frame.width))×\(Int(w.frame.height))"
            let label = "\(w.owner) — \(cleanTitle) (\(sizeStr)) [#\(w.id)]"
            let item = NSMenuItem(title: label, action: #selector(selectSpecificWindowTarget(_:)), keyEquivalent: "")
            item.tag = Int(w.id)
            item.representedObject = w.owner
            item.target = self
            if case .windowID(let id, _) = targetSelection, id == w.id {
                item.state = .on
            }
            targetMenu.addItem(item)
        }
    }

    private func refreshTargetInfoLine() {
        let windows = WindowSnapshot.visibleWindows()
        let match: WindowSnapshot? = {
            switch targetSelection {
            case .appFrontmost(let owner):
                return windows.first { $0.owner == owner }
            case .windowID(let id, _):
                return windows.first { $0.id == id }
            }
        }()

        if let match {
            targetInfoItem.title = "目标：\(match.owner) · #\(match.id) (\(Int(match.frame.width))×\(Int(match.frame.height)))"
        } else {
            targetInfoItem.title = "目标：未找到 \(targetSelection.displayName) 可见窗口"
        }
    }

    private func syncMenuStates() {
        for variant in OverlayVariant.all {
            variantItems[variant.id]?.state = (currentVariant?.id == variant.id) ? .on : .off
        }
        for (candidate, item) in styleItems {
            item.state = (candidate == style) ? .on : .off
        }
        for (mode, item) in appearanceItems {
            item.state = (mode == appearance) ? .on : .off
        }
        for (edge, item) in dockItems {
            item.state = (edge == dockEdge) ? .on : .off
        }
        expandToggleItem.state = alwaysExpanded ? .on : .off
        hideChildStatusMenuItem.state = hideChildStatusItem ? .on : .off

        for (mode, item) in v11Items { item.state = (mode == v11Mode) ? .on : .off }
        for (theme, item) in v14Items { item.state = (theme == v14Theme) ? .on : .off }
        for (stage, item) in v15Items { item.state = (stage == v15Stage) ? .on : .off }

        let hasActive = currentVariant != nil
        restartItem.isEnabled = hasActive
        stopItem.isEnabled = hasActive || isCompiling

        if isCompiling, let variant = currentVariant {
            statusHeadlineItem.title = "状态：正在编译 \(variant.shortTitle)..."
        } else if let variant = currentVariant, activeProcess?.isRunning == true {
            statusHeadlineItem.title = "状态：正在演示 \(variant.shortTitle) · \(styleSummary(for: variant))"
        } else if let note = lastStatusNote {
            statusHeadlineItem.title = "状态：\(note)"
        } else if let variant = currentVariant {
            statusHeadlineItem.title = "状态：\(variant.shortTitle) 已停止"
        } else {
            statusHeadlineItem.title = "状态：未开启遮罩（点击下方 V1–V15 开始）"
        }

        updateStatusBarAppearance()
    }

    private func styleSummary(for variant: OverlayVariant) -> String {
        switch variant.extraKind {
        case .v11State: return v11Mode.rawValue
        case .v14Theme: return v14Theme.rawValue
        case .v15Stage: return v15Stage.rawValue
        case .none: return variant.supportsStyle ? style.rawValue : appearance.rawValue
        }
    }

    private func updateStatusBarAppearance() {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "OverlayTest") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        if isCompiling, let v = currentVariant {
            button.title = " \(v.shortTitle)…"
        } else if let v = currentVariant, activeProcess?.isRunning == true {
            button.title = " \(v.shortTitle)"
        } else if let v = currentVariant, lastStatusNote != nil {
            button.title = " \(v.shortTitle)!"
        } else {
            button.title = " OverlayTest"
        }
    }

    // MARK: - Actions

    @objc private func selectVariantItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < OverlayVariant.all.count else { return }
        selectAndLaunch(OverlayVariant.all[idx])
    }

    @objc private func selectNextVariant() {
        let all = OverlayVariant.all
        if let current = currentVariant, let idx = all.firstIndex(where: { $0.id == current.id }) {
            selectAndLaunch(all[(idx + 1) % all.count])
        } else if let first = all.first {
            selectAndLaunch(first)
        }
    }

    @objc private func selectPreviousVariant() {
        let all = OverlayVariant.all
        if let current = currentVariant, let idx = all.firstIndex(where: { $0.id == current.id }) {
            selectAndLaunch(all[(idx - 1 + all.count) % all.count])
        } else if let last = all.last {
            selectAndLaunch(last)
        }
    }

    @objc private func restartCurrentVariant() {
        guard let currentVariant else { return }
        selectAndLaunch(currentVariant)
    }

    @objc private func stopCurrentVariant() {
        switchGeneration &+= 1
        isCompiling = false
        currentVariant = nil
        activeVariantID = nil
        lastStatusNote = "已停止演示"
        stopActiveProcessSync()
        syncMenuStates()
    }

    @objc private func selectStyleOption(_ sender: NSMenuItem) {
        let all = ProbeStyle.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        style = all[sender.tag]
        if let current = currentVariant { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func selectAppearanceOption(_ sender: NSMenuItem) {
        let all = ProbeAppearance.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        appearance = all[sender.tag]
        if let current = currentVariant { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func selectDockOption(_ sender: NSMenuItem) {
        let all = ProbeDock.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        dockEdge = all[sender.tag]
        if let current = currentVariant, current.supportsDockEdge { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func toggleAlwaysExpanded() {
        alwaysExpanded.toggle()
        if let current = currentVariant, current.supportsAlwaysExpanded { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func toggleHideChildStatusItem() {
        hideChildStatusItem.toggle()
        if let current = currentVariant { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func selectV11Mode(_ sender: NSMenuItem) {
        let all = V11Mode.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        v11Mode = all[sender.tag]
        if let v11 = OverlayVariant.find("v11") { selectAndLaunch(v11) }
    }

    @objc private func selectV14Theme(_ sender: NSMenuItem) {
        let all = V14ThemeOption.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        v14Theme = all[sender.tag]
        if let v14 = OverlayVariant.find("v14") { selectAndLaunch(v14) }
    }

    @objc private func selectV15Stage(_ sender: NSMenuItem) {
        let all = V15StageOption.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        v15Stage = all[sender.tag]
        if let v15 = OverlayVariant.find("v15") { selectAndLaunch(v15) }
    }

    @objc private func selectDefaultAppTarget() {
        targetSelection = .appFrontmost(defaultAppName)
        if let current = currentVariant { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func selectSpecificWindowTarget(_ sender: NSMenuItem) {
        let id = CGWindowID(sender.tag)
        let owner = sender.representedObject as? String ?? defaultAppName
        targetSelection = .windowID(id, ownerHint: owner)
        if let current = currentVariant { selectAndLaunch(current) } else { syncMenuStates() }
    }

    @objc private func quitApp() {
        stopActiveProcessSync()
        NSApp.terminate(nil)
    }

    // MARK: - Build & Spawn Pipeline

    private func selectAndLaunch(_ variant: OverlayVariant) {
        switchGeneration &+= 1
        let generation = switchGeneration

        currentVariant = variant
        lastStatusNote = nil
        stopActiveProcessSync()

        let needsBuild = !isBinaryUpToDate(for: variant)
        isCompiling = needsBuild
        syncMenuStates()

        let launchArgs = buildCLIArguments(for: variant)
        let binaryURL = binaryURL(for: variant)
        let launcherURL = overlayRoot.appendingPathComponent("\(variant.id)/test-window-overlay.sh")

        workerQueue.async { [weak self] in
            guard let self else { return }

            if needsBuild {
                let buildResult = self.runBuildIfNeeded(launcherScript: launcherURL)
                if let errorMsg = buildResult {
                    DispatchQueue.main.async {
                        guard self.switchGeneration == generation else { return }
                        self.isCompiling = false
                        self.lastStatusNote = errorMsg
                        self.syncMenuStates()
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                guard self.switchGeneration == generation else { return }
                self.isCompiling = false
                self.spawnProbeProcess(variant: variant, executableURL: binaryURL, arguments: launchArgs, generation: generation)
            }
        }
    }

    private func binaryURL(for variant: OverlayVariant) -> URL {
        overlayRoot
            .appendingPathComponent(variant.id, isDirectory: true)
            .appendingPathComponent("build/WindowOverlayProbe.app/Contents/MacOS/WindowOverlayProbe")
    }

    private func isBinaryUpToDate(for variant: OverlayVariant) -> Bool {
        let fm = FileManager.default
        let binPath = binaryURL(for: variant).path
        guard fm.isExecutableFile(atPath: binPath),
              let binAttr = try? fm.attributesOfItem(atPath: binPath),
              let binMTime = binAttr[.modificationDate] as? Date else {
            return false
        }
        var sources = [overlayRoot.appendingPathComponent("\(variant.id)/WindowOverlayProbe.swift").path]
        if variant.id != "v1" {
            sources.append(overlayRoot.appendingPathComponent("shared/OverlayProbeCore.swift").path)
        }
        for src in sources {
            if let attr = try? fm.attributesOfItem(atPath: src),
               let srcMTime = attr[.modificationDate] as? Date,
               srcMTime > binMTime {
                return false
            }
        }
        return true
    }

    private func runBuildIfNeeded(launcherScript: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [launcherScript.path, "--help"]
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return "编译启动失败：\(error.localizedDescription)"
        }
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "编译失败：\(errText.isEmpty ? "exit \(proc.terminationStatus)" : errText)"
        }
        return nil
    }

    private func buildCLIArguments(for variant: OverlayVariant) -> [String] {
        var args: [String] = []
        switch targetSelection {
        case .appFrontmost(let owner):
            args += ["--app", owner, "--frontmost"]
        case .windowID(let id, _):
            args += ["--window-id", "\(id)"]
        }
        args += ["--duration", "3600", "--appearance", appearance.rawValue]
        if variant.supportsStyle {
            args += ["--style", style.rawValue]
        }
        if variant.supportsAlwaysExpanded && alwaysExpanded {
            args.append("--always-expanded")
        }
        if variant.supportsDockEdge && dockEdge != .versionDefault {
            args += ["--dock", dockEdge.rawValue]
        }
        switch variant.extraKind {
        case .v11State:
            switch v11Mode {
            case .cycle: args.append("--cycle")
            default: args += ["--state", v11Mode.rawValue]
            }
        case .v14Theme:
            args += ["--theme", v14Theme.rawValue]
        case .v15Stage:
            args += ["--stage", v15Stage.rawValue]
        case .none:
            break
        }
        if hideChildStatusItem {
            args.append("--no-status-item")
        }
        return args
    }

    private func spawnProbeProcess(variant: OverlayVariant, executableURL: URL, arguments: [String], generation: UInt64) {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let lock = NSLock()
        var stderrLines: [String] = []
        var stdoutLines: [String] = []

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            stderrLines.append(text)
            lock.unlock()
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            stdoutLines.append(text)
            lock.unlock()
        }

        proc.terminationHandler = { [weak self] finished in
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            let errText = stderrLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let outText = stdoutLines.joined()
            lock.unlock()

            DispatchQueue.main.async {
                guard let self, self.switchGeneration == generation else { return }
                if self.activeProcess === finished {
                    self.activeProcess = nil
                    self.activeVariantID = nil
                }
                if !errText.isEmpty {
                    if errText.contains("Expected one visible target") {
                        self.lastStatusNote = "未找到 \(self.targetSelection.displayName) 可见窗口"
                    } else {
                        self.lastStatusNote = String(errText.split(separator: "\n").last ?? "探针异常退出")
                    }
                } else if outText.contains("STOP reason=target-terminated") {
                    self.lastStatusNote = "目标窗口已退出，点击菜单可重新挂载"
                } else if outText.contains("STOP reason=user") {
                    self.lastStatusNote = "已从控件关闭遮罩"
                } else {
                    self.lastStatusNote = "探针已退出 (code \(finished.terminationStatus))"
                }
                self.syncMenuStates()
            }
        }

        do {
            try proc.run()
            activeProcess = proc
            activeVariantID = variant.id
            syncMenuStates()
            print("[OverlayTestMenuBar] LAUNCH variant=\(variant.id) pid=\(proc.processIdentifier) args=\(arguments.joined(separator: " "))")
            fflush(stdout)
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            lastStatusNote = "启动失败：\(error.localizedDescription)"
            syncMenuStates()
        }
    }

    private func stopActiveProcessSync() {
        guard let proc = activeProcess else { return }
        activeProcess = nil
        activeVariantID = nil
        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(0.35)
            while proc.isRunning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.015))
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }
}

// MARK: - CLI Entry Point

private let args = CommandLine.arguments
private func argValue(_ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

if args.contains("--help") {
    print("""
    OverlayTestMenuBar [--app NAME | --window-id ID] [--start v1..v15|none] [--style subtle|standard|vivid]
                       [--appearance auto|light|dark] [--root PATH]
    """)
    exit(0)
}

guard let rootURL = resolveOverlayTestRoot(explicitRoot: argValue("--root")) else {
    fputs("OverlayTestMenuBar: unable to locate overlay-test directory. Pass --root /path/to/overlay-test.\n", stderr)
    exit(1)
}

let defaultApp = argValue("--app") ?? "PopAgent"
private let target: TargetSelection = {
    if let rawID = argValue("--window-id"), let id = UInt32(rawID) {
        return .windowID(id, ownerHint: defaultApp)
    }
    return .appFrontmost(defaultApp)
}()

let rawStart = argValue("--start") ?? "v1"
let initialVariant: String? = (rawStart.lowercased() == "none") ? nil : rawStart
if let initialVariant, OverlayVariant.find(initialVariant) == nil {
    fputs("OverlayTestMenuBar: --start must be v1..v15 or none.\n", stderr)
    exit(1)
}

private let initialStyle: ProbeStyle = {
    guard let s = ProbeStyle(rawValue: argValue("--style") ?? "standard") else {
        fputs("OverlayTestMenuBar: --style must be subtle, standard, or vivid.\n", stderr)
        exit(1)
    }
    return s
}()

private let initialAppearance: ProbeAppearance = {
    guard let a = ProbeAppearance(rawValue: argValue("--appearance") ?? "auto") else {
        fputs("OverlayTestMenuBar: --appearance must be auto, light, or dark.\n", stderr)
        exit(1)
    }
    return a
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let controller = OverlaySwitcherApp(
    overlayRoot: rootURL,
    defaultAppName: defaultApp,
    initialTarget: target,
    initialVariantID: initialVariant,
    style: initialStyle,
    appearance: initialAppearance
)
app.delegate = controller

// Forward SIGTERM/SIGINT cleanly so child probes don't linger when stopped from terminal.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { NSApp.terminate(nil) }
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { NSApp.terminate(nil) }
sigtermSource.resume()

app.run()
