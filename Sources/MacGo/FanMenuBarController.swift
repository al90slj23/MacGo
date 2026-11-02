import AppKit
import QuartzCore
import ToolboxCore

/// A second entry into the same fan session, never a second hardware controller.
@MainActor final class FanMenuBarController: NSObject {
    var openRules: (() -> Void)?
    var openPreferences: (() -> Void)?
    private let settings: Settings
    private let session: FanToolView
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let dashboard: FanDashboardView
    private let glyph = FanStatusGlyphView()
    private var animationStep: Int?

    init(settings: Settings, session: FanToolView) {
        self.settings = settings; self.session = session
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        dashboard = FanDashboardView(settings: settings, compact: true)
        super.init()
        let controller = NSViewController()
        controller.view = dashboard
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 660)
        popover.behavior = .transient
        if let button = item.button {
            // The transparent image reserves a native image slot; only the
            // overlaid glyph rotates, leaving text and click handling intact.
            button.image = NSImage(size: NSSize(width: 17, height: 17))
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePopover)
            button.addSubview(glyph)
            glyph.visibilityChanged = { [weak self] in self?.updateMotionFromReadings() }
        }
        dashboard.modeSelected = { [weak session] in session?.selectMode($0) }
        dashboard.manualPercentChanged = { [weak session] in session?.setManualPercent($0) }
        dashboard.openRules = { [weak self] in self?.popover.close(); self?.openRules?() }
        dashboard.openPreferences = { [weak self] in self?.popover.close(); self?.openPreferences?() }
        update()
    }

    func update() {
        item.isVisible = settings.showMenuBarIcon
        if !item.isVisible { popover.close() }
        let fans = session.readings
        let first = fans.first
        let rpm = first.flatMap { $0.actualRPM.isFinite && $0.actualRPM >= 0 && $0.actualRPM < Double(Int.max) ? Int($0.actualRPM.rounded()) : nil }
        var values: [String] = []
        if settings.showCPUTemperatureInMenuBar {
            if let cpu = session.cpuTemperatureCelsius {
                values.append(String(format: "%.0f%@", settings.temperatureUnit.displayValue(forCelsius: cpu), settings.temperatureUnit.symbol))
            } else { values.append("—" + settings.temperatureUnit.symbol) }
        }
        values.append(rpm.map { "\($0) rpm" } ?? "— rpm")
        item.button?.title = " " + values.joined(separator: " · ")
        if let button = item.button {
            button.layoutSubtreeIfNeeded()
            glyph.frame = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        }
        let title = L("Mac Go · 风扇控制", "Mac Go · Fans")
        item.button?.setAccessibilityLabel(title + " · " + values.joined(separator: " · "))
        item.button?.toolTip = title + "\n" + L("显示实际转速；温度为有效 CPU 传感器平均值。点击调速。", "Actual RPM; temperature is the average of valid CPU sensors. Click to control fans.")
        let ratio = first.flatMap { $0.maximumRPM > 0 && $0.actualRPM.isFinite ? $0.actualRPM / $0.maximumRPM : nil } ?? 0
        updateMotion(ratio: ratio)
        dashboard.update(fans: fans, temperatures: session.temperatures,
                         mode: session.selectedMode, manualPercent: session.manualPercent,
                         canControl: session.isControlServiceReady && !fans.isEmpty,
                         busy: session.isBusy, message: session.controlMessage,
                         uptimeSeconds: session.uptimeSeconds)
    }

    func refreshLocalization() { dashboard.refreshLocalization(); update() }

    func shutdown() {
        popover.close(); glyph.stopMotion()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func updateMotion(ratio: Double) {
        guard item.isVisible, settings.animateFanIcon, ratio.isFinite, ratio > 0,
              let window = glyph.window, window.isVisible,
              window.occlusionState.contains(.visible), !glyph.isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            glyph.stopMotion(); animationStep = nil; return
        }
        let step = Int((min(1, ratio) * 10).rounded())
        guard animationStep != step else { return }
        animationStep = step
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0; animation.toValue = Double.pi * 2
        animation.duration = 1.8 - 1.4 * Double(step) / 10
        animation.repeatCount = .infinity
        glyph.startMotion(animation)
    }

    private func updateMotionFromReadings() {
        let first = session.readings.first
        updateMotion(ratio: first.flatMap { $0.maximumRPM > 0 ? $0.actualRPM / $0.maximumRPM : nil } ?? 0)
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.close(); return }
        update()
        let available = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 730
        popover.contentSize = NSSize(width: 360, height: max(360, min(660, available - 70)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor private final class FanStatusGlyphView: NSView {
    var visibilityChanged: (() -> Void)?
    private let blades = CALayer()
    private var observers: [NSObjectProtocol] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blades.contentsGravity = .resizeAspect
        blades.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(blades)
        refreshImage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blades.bounds = CGRect(origin: .zero, size: bounds.size)
        blades.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibilityChanged?() }
                })
        }
        refreshImage(); visibilityChanged?()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshImage() }
    private func refreshImage() {
        let image = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        // Rasterize in the status bar appearance so template glyphs retain the
        // native foreground color when rendered by a standalone layer.
        let raster = NSImage(size: NSSize(width: 17, height: 17))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            raster.lockFocus()
            image?.draw(in: NSRect(x: 0, y: 0, width: 17, height: 17))
            NSColor.labelColor.setFill()
            NSRect(x: 0, y: 0, width: 17, height: 17).fill(using: .sourceIn)
            raster.unlockFocus()
        }
        blades.contentsScale = window?.backingScaleFactor ?? 2
        blades.contents = raster.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    func startMotion(_ animation: CAAnimation) { blades.add(animation, forKey: "fanRotation") }
    func stopMotion() { blades.removeAnimation(forKey: "fanRotation") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
