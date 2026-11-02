import AppKit
import ToolboxCore

@MainActor final class SwitcherPanel: NSPanel {
    private let document = SwitcherDocumentView()
    private let scroll = NSScrollView()
    private let appDocument = SwitcherDocumentView()
    private let appScroll = NSScrollView()
    private let appSeparator = NSView()
    private let appHeading = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let permissionHint = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private var orderedIDs: [WindowID] = []
    private var appIDs: [WindowID] = []
    private var cards: [WindowID: WindowCard] = [:]
    private var appCards: [WindowID: WindowlessAppCard] = [:]
    private var thumbnails: [WindowID: NSImage] = [:]
    private var selectedID: WindowID?
    private var cardMode: Bool?
    private var previousFrames: [NSRect] = []
    private var lastPointerPosition = NSPoint.zero

    var panelSizePercent = 70
    var thumbnailContentMode: ThumbnailContentMode = .fit
    private(set) var maximumThumbnailPixelSize = NSSize(width: 720, height: 448)
    var thumbnailBackingScaleFactor: CGFloat { screen?.backingScaleFactor ?? 2 }

    var choose: ((WindowID) -> Void)?
    var hover: ((WindowID) -> Void)?
    var terminateApplication: ((WindowID) -> Void)?
    var dismiss: (() -> Void)?
    var requestThumbnailPermission: (() -> Void)?
    var thumbnailsEnabled = true {
        didSet { if !thumbnailsEnabled { clearThumbnails() } }
    }
    var thumbnailPermissionGranted = false {
        didSet { if !thumbnailPermissionGranted { clearThumbnails() } }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 816, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; hidesOnDeactivate = false; isFloatingPanel = true
        level = .popUpMenu; isOpaque = false; backgroundColor = .clear; hasShadow = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let surface = NSVisualEffectView()
        surface.material = .hudWindow; surface.blendingMode = .behindWindow; surface.state = .active
        surface.wantsLayer = true; surface.layer?.cornerRadius = 18; surface.layer?.masksToBounds = true
        contentView = surface
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor; caption.alignment = .right
        permissionHint.font = .systemFont(ofSize: 11); permissionHint.textColor = .secondaryLabelColor
        permissionButton.bezelStyle = .inline
        permissionButton.font = .systemFont(ofSize: 11, weight: .medium)
        permissionButton.target = self; permissionButton.action = #selector(openThumbnailPermission)
        closeButton.bezelStyle = .inline
        closeButton.target = self; closeButton.action = #selector(closePicker)
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        emptyHint.font = .systemFont(ofSize: 14); emptyHint.textColor = .secondaryLabelColor
        emptyHint.alignment = .center
        appHeading.font = .systemFont(ofSize: 12, weight: .medium)
        appHeading.textColor = .secondaryLabelColor
        appSeparator.wantsLayer = true
        appSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        scroll.documentView = document; scroll.hasVerticalScroller = true
        appScroll.documentView = appDocument; appScroll.hasHorizontalScroller = true
        appScroll.hasVerticalScroller = false
        for view in [scroll, appScroll] {
            view.autohidesScrollers = true; view.scrollerStyle = .overlay
            view.drawsBackground = false; view.borderType = .noBorder
        }
        for view in [heading, caption, permissionHint, permissionButton, closeButton, scroll,
                     emptyHint, appSeparator, appHeading, appScroll, footer] { surface.addSubview(view) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    @objc private func closePicker() { dismiss?() }
    @objc private func openThumbnailPermission() { requestThumbnailPermission?() }

    func clearThumbnails() {
        thumbnails.removeAll(keepingCapacity: true)
        for card in cards.values { card.setThumbnail(nil) }
    }

    func removeThumbnail(for id: WindowID) {
        guard thumbnails.removeValue(forKey: id) != nil else { return }
        cards[id]?.setThumbnail(nil)
    }

    func setThumbnail(_ image: NSImage, for id: WindowID) {
        guard thumbnailsEnabled, thumbnailPermissionGranted, cards[id] != nil else { return }
        if thumbnails[id] == nil, thumbnails.count >= 24 {
            guard let discarded = orderedIDs.reversed().first(where: { $0 != selectedID && thumbnails[$0] != nil }) else { return }
            thumbnails.removeValue(forKey: discarded); cards[discarded]?.setThumbnail(nil)
        }
        thumbnails[id] = image; cards[id]?.setThumbnail(image)
    }

    func show(items: [SwitchableWindow], windowlessItems: [SwitchableWindow] = [],
              selected: WindowID?, shortcut: SwitchShortcut, on targetScreen: NSScreen? = nil,
              globalIndices: [WindowID: Int] = [:], displayName: String? = nil) {
        title = L("窗口切换 · Mac Go", "Window switcher · Mac Go", "視窗切換 · Mac Go")
        let opening = !isVisible
        lastPointerPosition = NSEvent.mouseLocation
        let screen = targetScreen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fraction = CGFloat(min(100, max(30, panelSizePercent))) / 100
        let maxWidth = min(max(220, available.width * fraction), max(220, available.width - 32))
        let width = thumbnailsEnabled ? maxWidth : min(640, maxWidth)
        let needsPermission = thumbnailsEnabled && !thumbnailPermissionGranted
        let topInset: CGFloat = needsPermission ? 82 : 52
        let appBarHeight: CGFloat = windowlessItems.isEmpty ? 0 : 126
        let bottomInset: CGFloat = 42 + appBarHeight
        let previewHeight = min(220, max(128, available.height * fraction * 0.24))
        let grid = SwitcherGridLayout.make(windowSizes: items.map { $0.frame?.size }, width: width - 24,
                                          preferredPreviewHeight: previewHeight)
        let visibleHeight = thumbnailsEnabled ? min(grid.contentHeight, (previewHeight + 52) * 3) : CGFloat(min(8, items.count)) * 58
        let minimumContentHeight: CGFloat = items.isEmpty ? 60 : (thumbnailsEnabled ? previewHeight + 44 : 54)
        let height = SwitcherGridLayout.panelHeight(contentHeight: max(minimumContentHeight, visibleHeight),
            minimumContentHeight: minimumContentHeight, chromeHeight: topInset + bottomInset,
            availableHeight: available.height, percent: panelSizePercent)
        let newFrame = NSRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        if frame != newFrame { setFrame(newFrame, display: false) }
        layoutChrome(width: width, height: height, topInset: topInset, appBarHeight: appBarHeight,
                     needsPermission: needsPermission, count: items.count, appCount: windowlessItems.count,
                     shortcut: shortcut, displayName: displayName)

        let ids = items.map(\.id)
        let documentWidth = max(1, scroll.contentSize.width)
        let frames: [NSRect]
        let contentHeight: CGFloat
        if thumbnailsEnabled {
            let layout = SwitcherGridLayout.make(windowSizes: items.map { $0.frame?.size }, width: documentWidth,
                                                preferredPreviewHeight: previewHeight)
            frames = layout.frames; contentHeight = layout.contentHeight
        } else {
            frames = items.indices.map { NSRect(x: 0, y: CGFloat($0) * 58, width: documentWidth, height: 54) }
            contentHeight = CGFloat(items.count) * 58
        }
        let rebuild = ids != orderedIDs || cardMode != thumbnailsEnabled
        let relayout = rebuild || previousFrames != frames
        if ids != orderedIDs {
            let visibleIDs = Set(ids); thumbnails = thumbnails.filter { visibleIDs.contains($0.key) }
        }
        if !thumbnailsEnabled || !thumbnailPermissionGranted { clearThumbnails() }
        if rebuild {
            for card in cards.values { card.removeFromSuperview() }
            cards.removeAll(keepingCapacity: true)
            for (index, item) in items.enumerated() {
                let card = WindowCard(item: item, number: globalIndices[item.id] ?? index + 1,
                    thumbnailMode: thumbnailsEnabled, contentMode: thumbnailContentMode,
                    action: { [weak self] in self?.choose?(item.id) },
                    hover: { [weak self] in self?.pointerMoved(over: item.id) },
                    close: { [weak self] in self?.terminateApplication?(item.id) })
                card.setThumbnail(thumbnails[item.id]); cards[item.id] = card; document.addSubview(card)
            }
        } else {
            for (index, item) in items.enumerated() {
                cards[item.id]?.update(item: item, number: globalIndices[item.id] ?? index + 1)
                cards[item.id]?.setContentMode(thumbnailContentMode)
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: documentWidth, height: max(contentHeight, scroll.contentSize.height))
        if relayout {
            for (index, id) in ids.enumerated() { cards[id]?.frame = frames[index]; cards[id]?.needsLayout = true }
        }
        let scale = screen?.backingScaleFactor ?? 2
        maximumThumbnailPixelSize = NSSize(width: max(1, (frames.map { $0.width - 12 }.max() ?? 360) * scale),
                                           height: max(1, previewHeight * scale))
        let revealSelection = opening || relayout || selectedID != selected
        if rebuild || selectedID != selected {
            if let selectedID { cards[selectedID]?.setSelected(false) }
            if let selected { cards[selected]?.setSelected(true) }
        }
        orderedIDs = ids; cardMode = thumbnailsEnabled; previousFrames = frames; selectedID = selected
        layoutWindowlessApps(windowlessItems, opening: opening)
        contentView?.layoutSubtreeIfNeeded()
        if revealSelection, let selected, let card = cards[selected] { document.scrollToVisible(card.frame.insetBy(dx: 0, dy: -4)) }
        else if rebuild { scroll.contentView.scroll(to: .zero) }
        scroll.reflectScrolledClipView(scroll.contentView)
        orderFrontRegardless()
    }

    private func pointerMoved(over id: WindowID) {
        let point = NSEvent.mouseLocation
        // Opening the panel or rebuilding its tracking areas beneath a stationary
        // cursor must not replace the initial selection or a later Tab choice.
        guard isVisible, hypot(point.x - lastPointerPosition.x, point.y - lastPointerPosition.y) >= 0.5 else { return }
        lastPointerPosition = point
        hover?(id)
    }

    private func layoutWindowlessApps(_ items: [SwitchableWindow], opening: Bool) {
        let ids = items.map(\.id)
        let rebuild = ids != appIDs
        if rebuild {
            for card in appCards.values { card.removeFromSuperview() }
            appCards.removeAll(keepingCapacity: true)
            for item in items {
                let card = WindowlessAppCard(item: item, action: { [weak self] in self?.choose?(item.id) },
                                            close: { [weak self] in self?.terminateApplication?(item.id) })
                appCards[item.id] = card; appDocument.addSubview(card)
            }
        } else { for item in items { appCards[item.id]?.update(item: item) } }
        let cardWidth: CGFloat = 112
        let gap: CGFloat = 8
        let contentWidth = max(appScroll.contentSize.width, CGFloat(items.count) * (cardWidth + gap) - (items.isEmpty ? 0 : gap))
        appDocument.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(1, appScroll.contentSize.height))
        // A system setting may reserve space for the horizontal scroller even
        // when overlay style was requested. Tile before sizing the row so its
        // caption remains fully inside the actual clip view.
        appScroll.tile()
        let rowHeight = min(74, max(1, appScroll.contentSize.height))
        appDocument.frame.size.height = max(1, appScroll.contentSize.height)
        for (index, id) in ids.enumerated() {
            appCards[id]?.frame = NSRect(x: CGFloat(index) * (cardWidth + gap), y: 0, width: cardWidth, height: rowHeight)
        }
        if opening || rebuild { appScroll.contentView.scroll(to: .zero) }
        appScroll.reflectScrolledClipView(appScroll.contentView)
        appIDs = ids
    }

    private func layoutChrome(width: CGFloat, height: CGFloat, topInset: CGFloat, appBarHeight: CGFloat,
                              needsPermission: Bool, count: Int, appCount: Int,
                              shortcut: SwitchShortcut, displayName: String?) {
        heading.stringValue = L("窗口切换", "Window switcher", "視窗切換")
        permissionHint.stringValue = L("缩略图需授权", "Thumbnails need permission", "縮圖需要授權")
        permissionButton.title = L("开启缩略图…", "Enable previews…", "開啟縮圖…")
        closeButton.title = L("关闭", "Close", "關閉")
        heading.frame = NSRect(x: 18, y: height - 39, width: min(150, width - 90), height: 24)
        closeButton.frame = NSRect(x: width - 62, y: height - 38, width: 44, height: 24)
        caption.stringValue = L("\(count) 个窗口", "\(count) windows", "\(count) 個視窗")
        if let displayName, width > 500 { caption.stringValue = "\(displayName) · \(caption.stringValue)" }
        caption.frame = NSRect(x: 174, y: height - 36, width: max(0, width - 250), height: 18)
        permissionHint.isHidden = !needsPermission; permissionButton.isHidden = !needsPermission
        permissionHint.frame = NSRect(x: 18, y: height - 67, width: max(0, width - 190), height: 18)
        permissionButton.frame = NSRect(x: width - 146, y: height - 70, width: 128, height: 24)
        scroll.frame = NSRect(x: 12, y: 42 + appBarHeight, width: width - 24, height: max(1, height - topInset - 42 - appBarHeight))
        emptyHint.isHidden = count > 0
        emptyHint.stringValue = L("当前没有可切换的窗口", "No windows to switch to", "目前沒有可切換的視窗")
        emptyHint.frame = NSRect(x: 18, y: scroll.frame.midY - 10, width: width - 36, height: 20)
        let hasApps = appCount > 0
        appSeparator.isHidden = !hasApps; appHeading.isHidden = !hasApps; appScroll.isHidden = !hasApps
        // A fixed, full-width footer lane has its own horizontal scroll view.
        // The blank gap above it separates these mouse-only app choices.
        appSeparator.frame = NSRect(x: 12, y: 42 + appBarHeight - 12, width: width - 24, height: 1)
        appHeading.stringValue = L("无窗口应用 · \(appCount) · 仅鼠标点击", "Apps without windows · \(appCount) · Click to open", "無視窗應用程式 · \(appCount) · 僅滑鼠點選")
        appHeading.frame = NSRect(x: 18, y: 42 + appBarHeight - 36, width: width - 36, height: 18)
        appScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: max(1, appBarHeight - 42))
        footer.stringValue = width >= 690
            ? L("\(shortcut.display) 选择 · Shift 反向 · 松开切换 · 鼠标悬停选择，点击打开 · Esc 取消",
                "\(shortcut.display) Next · Shift Reverse · Release to switch · Hover to select, click to open · Esc Cancel",
                "\(shortcut.display) 選擇 · Shift 反向 · 放開切換 · 滑鼠停留選取，點選開啟 · Esc 取消")
            : L("\(shortcut.display) 选择 · 松开或点击切换 · Esc 取消", "\(shortcut.display) Select · Release or click to switch · Esc Cancel", "\(shortcut.display) 選擇 · 放開或點選切換 · Esc 取消")
        footer.frame = NSRect(x: 18, y: 14, width: width - 36, height: 17)
    }
}

private final class SwitcherDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor private class PointerCard: NSView {
    private var pointerTracking: NSTrackingArea?
    var pointerEntered: (() -> Void)?
    var pointerExited: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        pointerTracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { pointerEntered?() }
    override func mouseMoved(with event: NSEvent) { pointerEntered?() }
    override func mouseExited(with event: NSEvent) { pointerExited?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor private final class WindowCard: PointerCard {
    private let action: () -> Void
    private let closeAction: () -> Void
    private let thumbnailMode: Bool
    private let previewBackground = NSView()
    private let preview = WindowPreviewView()
    private let fallbackIcon = NSImageView()
    private let appIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let minimizedBadge = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")
    private let quitButton = NSButton()
    private var appName = ""
    private var windowTitle = ""
    private var minimized = false

    init(item: SwitchableWindow, number: Int, thumbnailMode: Bool, contentMode: ThumbnailContentMode,
         action: @escaping () -> Void, hover: @escaping () -> Void, close: @escaping () -> Void) {
        self.action = action; self.closeAction = close; self.thumbnailMode = thumbnailMode
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 9
        setAccessibilityElement(true); setAccessibilityRole(.button)
        previewBackground.wantsLayer = true; previewBackground.layer?.cornerRadius = 5
        previewBackground.layer?.masksToBounds = true
        previewBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.13).cgColor
        preview.contentMode = contentMode
        fallbackIcon.imageScaling = .scaleProportionallyDown
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.wantsLayer = true; appIcon.layer?.shadowColor = NSColor.black.cgColor
        appIcon.layer?.shadowOpacity = 0.5; appIcon.layer?.shadowRadius = 3; appIcon.layer?.shadowOffset = .zero
        titleLabel.lineBreakMode = .byTruncatingMiddle; titleLabel.maximumNumberOfLines = 1
        minimizedBadge.font = .systemFont(ofSize: 10, weight: .medium)
        minimizedBadge.textColor = .white
        minimizedBadge.wantsLayer = true; minimizedBadge.layer?.cornerRadius = 4
        minimizedBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        numberLabel.textColor = .secondaryLabelColor; numberLabel.alignment = .right
        configureQuitButton(quitButton, target: self, action: #selector(quitApplication))
        for view in [previewBackground, preview, fallbackIcon, appIcon, titleLabel, minimizedBadge, numberLabel, quitButton] { addSubview(view) }
        previewBackground.isHidden = !thumbnailMode; preview.isHidden = true; fallbackIcon.isHidden = !thumbnailMode
        pointerEntered = hover
        update(item: item, number: number); setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func quitApplication() { closeAction() }

    func update(item: SwitchableWindow, number: Int) {
        appName = item.appName; windowTitle = item.title; minimized = item.minimized
        titleLabel.stringValue = item.title
        minimizedBadge.isHidden = !item.minimized || !thumbnailMode
        minimizedBadge.stringValue = L(" 已最小化 ", " Minimized ", " 已最小化 ")
        let icon = item.app.icon ?? NSImage(named: NSImage.applicationIconName)
        appIcon.image = icon; fallbackIcon.image = icon
        numberLabel.stringValue = String(number)
        quitButton.toolTip = L("退出 \(appName)（所有窗口）", "Quit \(appName) (all windows)", "結束 \(appName)（所有視窗）")
        quitButton.setAccessibilityLabel(quitButton.toolTip)
        setAccessibilityLabel("\(item.appName)：\(item.title)\(item.minimized ? L("，已最小化", ", minimized", "，已最小化") : "")")
        toolTip = "\(item.appName)：\(item.title)"
    }

    func setContentMode(_ mode: ThumbnailContentMode) { preview.contentMode = mode }
    func setThumbnail(_ image: NSImage?) {
        preview.image = image; preview.isHidden = !thumbnailMode || image == nil
        fallbackIcon.isHidden = !thumbnailMode || image != nil
    }
    func setSelected(_ value: Bool) {
        titleLabel.font = .systemFont(ofSize: 15, weight: value ? .semibold : .medium)
        layer?.backgroundColor = (value ? NSColor.controlAccentColor.withAlphaComponent(0.23)
            : NSColor.controlBackgroundColor.withAlphaComponent(thumbnailMode ? 0.18 : 0)).cgColor
        layer?.borderColor = (value ? NSColor.controlAccentColor : .clear).cgColor
        layer?.borderWidth = value ? 2 : 0
        setAccessibilityValue(value ? L("已选中", "Selected", "已選取") : "")
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        if thumbnailMode {
            let previewFrame = NSRect(x: 6, y: 38, width: max(1, width - 12), height: max(1, bounds.height - 44))
            previewBackground.frame = previewFrame; preview.frame = previewFrame
            fallbackIcon.frame = NSRect(x: width / 2 - 32, y: previewFrame.midY - 32, width: 64, height: 64)
            appIcon.frame = NSRect(x: previewFrame.minX + 6, y: previewFrame.maxY - 42, width: 36, height: 36)
            quitButton.frame = NSRect(x: previewFrame.maxX - 30, y: previewFrame.maxY - 30, width: 26, height: 26)
            titleLabel.frame = NSRect(x: 8, y: 10, width: max(1, width - 38), height: 21)
            numberLabel.frame = NSRect(x: width - 27, y: 13, width: 19, height: 14)
            minimizedBadge.frame = NSRect(x: previewFrame.minX + 6, y: previewFrame.minY + 6, width: 78, height: 16)
        } else {
            appIcon.frame = NSRect(x: 8, y: 9, width: 36, height: 36)
            titleLabel.frame = NSRect(x: 54, y: 16, width: max(1, width - 118), height: 22)
            numberLabel.frame = NSRect(x: width - 61, y: 19, width: 19, height: 14)
            quitButton.frame = NSRect(x: width - 34, y: 14, width: 26, height: 26)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === quitButton || hit.isDescendant(of: quitButton) ? hit : self
    }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

@MainActor private final class WindowlessAppCard: PointerCard {
    private let action: () -> Void
    private let closeAction: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let quitButton = NSButton()
    init(item: SwitchableWindow, action: @escaping () -> Void, close: @escaping () -> Void) {
        self.action = action; self.closeAction = close
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8
        setAccessibilityElement(true); setAccessibilityRole(.button)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center; label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        configureQuitButton(quitButton, target: self, action: #selector(quitApplication))
        for view in [icon, label, quitButton] { addSubview(view) }
        pointerEntered = { [weak self] in self?.setHovered(true) }
        pointerExited = { [weak self] in self?.setHovered(false) }
        update(item: item); setHovered(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func quitApplication() { closeAction() }
    func update(item: SwitchableWindow) {
        icon.image = item.app.icon ?? NSImage(named: NSImage.applicationIconName)
        label.stringValue = item.appName
        setAccessibilityLabel(L("\(item.appName)，无窗口，点击打开", "\(item.appName), no windows, click to open", "\(item.appName)，無視窗，點選開啟"))
        quitButton.toolTip = L("退出 \(item.appName)", "Quit \(item.appName)", "結束 \(item.appName)")
        quitButton.setAccessibilityLabel(quitButton.toolTip)
    }
    private func setHovered(_ hovered: Bool) {
        // This is a mouse affordance, separate from the keyboard selection.
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(hovered ? 0.5 : 0.18).cgColor
        layer?.borderWidth = hovered ? 1 : 0
        layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
        quitButton.isHidden = false
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: bounds.midX - 20, y: 26, width: 40, height: 40)
        label.frame = NSRect(x: 5, y: 5, width: bounds.width - 10, height: 17)
        quitButton.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24, width: 22, height: 22)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === quitButton || hit.isDescendant(of: quitButton) ? hit : self
    }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

@MainActor private func configureQuitButton(_ button: NSButton, target: AnyObject, action: Selector) {
    button.isBordered = false; button.bezelStyle = .circular; button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("退出应用", "Quit application", "結束應用程式"))
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    button.contentTintColor = .white
    button.wantsLayer = true; button.layer?.shadowColor = NSColor.black.cgColor
    button.layer?.shadowOpacity = 0.6; button.layer?.shadowRadius = 2; button.layer?.shadowOffset = .zero
    button.target = target; button.action = action
}

/// Uses display-sized, memory-only captures. Source point dimensions preserve
/// fit/fill and actual-size semantics independently from Retina pixel density.
@MainActor private final class WindowPreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var contentMode: ThumbnailContentMode = .fit { didSet { if oldValue != contentMode { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let scale: CGFloat
        switch contentMode {
        case .fit: scale = fit
        case .fill: scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        case .actualSize: scale = min(1, fit)
        }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                 width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState(); bounds.clip()
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}
