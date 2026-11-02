import AppKit
import ApplicationServices

/// Reusable authorization guide. The dragged file is always the running app's
/// own bundle; granting access remains an explicit action in System Settings.
@MainActor public final class PermissionGuide: NSObject, NSPopoverDelegate {
    public enum Kind: Equatable {
        case accessibility
        case screenRecording

        fileprivate var isAuthorized: Bool {
            switch self {
            case .accessibility: return AXIsProcessTrusted()
            case .screenRecording: return CGPreflightScreenCaptureAccess()
            }
        }

        fileprivate var title: String {
            switch self {
            case .accessibility: return L("开启辅助功能", "Enable Accessibility", "開啟輔助使用")
            case .screenRecording: return L("开启窗口缩略图", "Enable Window Previews", "開啟視窗縮圖")
            }
        }

        fileprivate var settingsTitle: String {
            switch self {
            case .accessibility: return L("打开辅助功能设置", "Open Accessibility Settings", "打開輔助使用設定")
            case .screenRecording: return L("打开屏幕录制设置", "Open Screen Recording Settings", "打開螢幕錄製設定")
            }
        }

        fileprivate var settingsURL: URL? {
            let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        }

        fileprivate var explanation: String {
            switch self {
            case .accessibility:
                return L("打开辅助功能设置，将下面的应用图标拖到其中的应用列表，再按系统提示开启权限。", "Open Accessibility settings, drag the app icon below into the app list, then enable access when macOS asks.")
            case .screenRecording:
                return L("读取窗口画面以显示缩略图，不保存录屏文件。不授权仍可按标题切换。", "Read window images for previews without saving recordings. Switching by title still works without this access.")
            }
        }

        fileprivate var confirmation: String {
            switch self {
            case .accessibility:
                return L("名称和图标应与这里一致。若此应用仍显示旧名称，请只移除对应旧项，再拖入当前图标。授权真正生效后，此引导会自动关闭。", "The name and icon should match. If this app still appears under its old name, remove that entry and add the current icon. This guide closes when access takes effect.")
            case .screenRecording:
                return L("在屏幕录制权限页开启此应用。若系统不接受拖入，请按系统提示添加；下方可直接在访达中定位应用。macOS 可能要求重新启动。", "Enable this app in Screen Recording settings. If dragging is unavailable, use the system add button; Reveal in Finder locates the app. macOS may require a restart.")
            }
        }
    }

    public var authorized: (() -> Void)?
    public var restartRequested: (() -> Void)?

    private let popover = NSPopover()
    private let content: PermissionGuideContent
    private var timer: Timer?
    private var reportedAuthorization = false
    private let kind: Kind

    public init(kind: Kind = .accessibility) {
        self.kind = kind
        let bundle = Bundle.main
        let url = URL(fileURLWithPath: bundle.bundlePath, isDirectory: true)
        let appURL = url.pathExtension.lowercased() == "app" ? url : nil
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        content = PermissionGuideContent(appURL: appURL, appName: appName, kind: kind)
        super.init()
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 410, height: 460)
        // Keep the drag source visible when the user activates System Settings.
        // The explicit close button and successful authorization dismiss it.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        content.dismiss = { [weak self] in self?.close() }
        content.restart = { [weak self] in self?.restartRequested?() }
    }

    public func show(relativeTo anchor: NSView) {
        guard anchor.window != nil else { return }
        reportedAuthorization = false
        if kind.isAuthorized { reportAuthorization(); return }
        if !popover.isShown { content.loadView() }
        _ = content.view
        content.resetStatus()
        if !popover.isShown {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAuthorization() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func close() {
        timer?.invalidate()
        timer = nil
        if popover.isShown { popover.close() }
    }

    public func popoverDidClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func checkAuthorization() {
        guard popover.isShown else { close(); return }
        if kind.isAuthorized { reportAuthorization() }
    }

    private func reportAuthorization() {
        guard !reportedAuthorization else { return }
        reportedAuthorization = true
        close()
        authorized?()
    }

    deinit { timer?.invalidate() }
}

@MainActor private final class PermissionGuideContent: NSViewController {
    private let appURL: URL?
    private let appName: String
    private let kind: PermissionGuide.Kind
    private var requestedScreenAccess = false
    private let status = NSTextField(wrappingLabelWithString: "")
    var dismiss: (() -> Void)?
    var restart: (() -> Void)?

    init(appURL: URL?, appName: String, kind: PermissionGuide.Kind) {
        self.appURL = appURL
        self.appName = appName
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 460))
        view = surface

        let title = NSTextField(labelWithString: kind.title)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭授权引导", "Close permission guide"))!,
                             target: self, action: #selector(closeGuide))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L("关闭授权引导", "Close permission guide")

        let explanation = NSTextField(wrappingLabelWithString: kind.explanation)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor

        let dragSource = AppBundleDragView(appURL: appURL, appName: appName)
        dragSource.dragEnded = { [weak self] copied in
            guard let self else { return }
            if copied { self.status.stringValue = L("图标已投放，正在检查当前版本的权限…", "Icon dropped. Checking access for this version…") }
            else if self.kind == .screenRecording { self.status.stringValue = L("系统未接受拖入，请打开屏幕录制设置，按系统提示添加。", "Dragging was not accepted. Open Screen Recording settings and use the system add button.") }
            else { self.status.stringValue = L("尚未投放到权限列表，请重新拖动。", "Not dropped into the permission list. Please try again.") }
        }
        let filename = appURL?.lastPathComponent ?? appName
        let instruction = NSTextField(labelWithString: L("在权限列表中找：", "Find this in the permission list: ") + filename)
        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        let confirmation = NSTextField(wrappingLabelWithString: kind.confirmation)
        confirmation.font = .systemFont(ofSize: 11)
        confirmation.textColor = .secondaryLabelColor

        let open = NSButton(title: kind.settingsTitle, target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        open.controlSize = .regular
        let reveal = NSButton(title: L("在访达中显示应用", "Reveal App in Finder"), target: self, action: #selector(revealApplication))
        reveal.isBordered = false
        reveal.font = .systemFont(ofSize: 11)
        reveal.contentTintColor = .linkColor
        reveal.isEnabled = appURL != nil
        let restart = NSButton(title: L("列表已开启但仍无效？重新启动 Mac Go", "Access is on but not working? Restart Mac Go"), target: self, action: #selector(restartApplication))
        restart.isBordered = false
        restart.font = .systemFont(ofSize: 11)
        restart.contentTintColor = .linkColor
        restart.isEnabled = appURL != nil

        let indicator = NSImageView(image: NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)!)
        indicator.contentTintColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let progress = NSStackView(views: [indicator, status])
        progress.orientation = .horizontal
        progress.alignment = .centerY
        progress.spacing = 6

        for item in [title, close, explanation, dragSource, instruction, confirmation, open, reveal, restart, progress] {
            item.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -22),
            explanation.heightAnchor.constraint(equalToConstant: 38),
            dragSource.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            dragSource.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dragSource.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            dragSource.heightAnchor.constraint(equalToConstant: 82),
            instruction.topAnchor.constraint(equalTo: dragSource.bottomAnchor, constant: 11),
            instruction.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            confirmation.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 5),
            confirmation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            confirmation.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            confirmation.heightAnchor.constraint(equalToConstant: 57),
            open.topAnchor.constraint(equalTo: confirmation.bottomAnchor, constant: 10),
            open.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            open.widthAnchor.constraint(equalToConstant: 214), open.heightAnchor.constraint(equalToConstant: 30),
            reveal.topAnchor.constraint(equalTo: open.bottomAnchor, constant: 5),
            reveal.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            reveal.heightAnchor.constraint(equalToConstant: 20),
            restart.topAnchor.constraint(equalTo: reveal.bottomAnchor, constant: 7),
            restart.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            restart.heightAnchor.constraint(equalToConstant: 22),
            progress.topAnchor.constraint(equalTo: restart.bottomAnchor, constant: 12),
            progress.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            progress.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -44),
            progress.bottomAnchor.constraint(lessThanOrEqualTo: surface.bottomAnchor, constant: -15),
            indicator.widthAnchor.constraint(equalToConstant: 13), indicator.heightAnchor.constraint(equalToConstant: 13)
        ])
        if appURL == nil {
            status.stringValue = L("请从应用包启动 Mac Go 后完成授权", "Launch Mac Go from its app bundle to grant access")
        }
    }

    func resetStatus() {
        status.stringValue = appURL == nil ? L("请从应用包启动 Mac Go 后完成授权", "Launch Mac Go from its app bundle to grant access") : L("等待在系统设置中完成授权", "Waiting for access in System Settings")
    }

    @objc private func closeGuide() { dismiss?() }
    @objc private func restartApplication() { restart?() }

    @objc private func openSettings() {
        // Request only after this explicit click, never while checking status or
        // opening the switcher. The OS still owns the grant/deny confirmation.
        if kind == .screenRecording, !requestedScreenAccess, !kind.isAuthorized {
            requestedScreenAccess = true
            _ = CGRequestScreenCaptureAccess()
        }
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealApplication() {
        guard let appURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}

/// A drag source rather than a copied file or alias. System Settings receives
/// the file URL of the actual running .app and decides whether to accept it.
@MainActor final class AppBundleDragView: NSView, NSDraggingSource {
    private let appURL: URL?
    private let icon: NSImage
    private var mouseOrigin: NSPoint?
    private var dragging = false
    private let iconView: NSImageView
    var dragEnded: ((Bool) -> Void)?

    static func applicationIcon(for appURL: URL?) -> NSImage {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
            ?? appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)!
    }

    init(appURL: URL?, appName: String) {
        self.appURL = appURL
        icon = Self.applicationIcon(for: appURL)
        iconView = NSImageView(image: icon)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        toolTip = L("可将应用图标拖到系统支持的权限列表；开启权限仍需系统确认", "Drag the app icon into a supported permission list; macOS still confirms access")
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(appName + L("，可拖动的应用图标", ", draggable app icon"))
        setAccessibilityHelp(L("将图标拖入对应的系统权限列表；如系统不支持拖入，请使用设置与访达入口完成添加。", "Drag this icon into the permission list, or use Settings and Finder to add it."))
        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(labelWithString: L("按住图标，拖到权限列表", "Drag this icon into the permission list"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, hint])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)!)
        arrow.contentTintColor = .tertiaryLabelColor
        for item in [iconView, labels, arrow] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 54), iconView.heightAnchor.constraint(equalToConstant: 54),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 13),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: arrow.leadingAnchor, constant: -10),
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 16), arrow.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Decorative icon/labels must not intercept the initial drag gesture.
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) { mouseOrigin = nil }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let appURL, let mouseOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseOrigin.x, point.y - mouseOrigin.y) >= 4 else { return }
        let item = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: appURL.path, isDirectory: true))
        item.setDraggingFrame(iconView.frame, contents: icon)
        dragging = true
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseOrigin = nil
        dragEnded?(operation.contains(.copy))
    }
}
