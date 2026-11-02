import AppKit

struct RecordedShortcut: Codable, Equatable {
    let keyCode: Int64
    let modifierRawValue: UInt64
    let keyLabel: String
    var flags: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }
    var isValid: Bool {
        let allowed: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        return (0...127).contains(keyCode) && !keyLabel.isEmpty && keyLabel.count <= 16 &&
            !flags.intersection(allowed).isEmpty && flags.subtracting(allowed).isEmpty &&
            ![36, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 76, 123, 124, 125, 126].contains(keyCode) &&
            !(keyCode == 12 && flags == .maskCommand)
    }
    var display: String {
        (flags.contains(.maskControl) ? "⌃" : "") +
        (flags.contains(.maskAlternate) ? "⌥" : "") +
        (flags.contains(.maskCommand) ? "⌘" : "") + " " + keyLabel
    }
    static var current: RecordedShortcut? {
        guard let data = UserDefaults.standard.data(forKey: "windowSwitcher.customShortcut"),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}

/// Records only while this button owns focus; it never installs a second global
/// key monitor. The host suspends the switcher until recording has ended.
@MainActor final class ShortcutRecorderButton: NSButton {
    var recordedShortcut: RecordedShortcut? { didSet { if !recording { updateTitle() } } }
    var onShortcutRecorded: ((RecordedShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var recording = false
    private var resignKeyObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        if recording { endRecording(); return }
        recording = true
        onRecordingChanged?(true)
        title = L("请按组合键…（Esc 取消）", "Press shortcut… (Esc cancels)", "請按組合鍵…（Esc 取消）")
        if window?.makeFirstResponder(self) != true { endRecording() }
    }
    private func updateTitle() {
        title = recordedShortcut.map { $0.display + " · " + L("重新录制", "Record again", "重新錄製") }
            ?? L("录制快捷键…", "Record shortcut…", "錄製快捷鍵…")
        toolTip = L("使用 Command、Option 或 Control 加一个键；Shift 用于反向选择。", "Use Command, Option or Control plus a key. Shift is reserved for reverse selection.", "使用 Command、Option 或 Control 加一個鍵；Shift 用於反向選擇。")
    }
    private func endRecording() {
        guard recording else { return }
        recording = false; updateTitle(); onRecordingChanged?(false)
    }
    override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard window?.isKeyWindow != true else { return }
                    self?.endRecording()
                }
            }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        record(event); return true
    }
    override func keyDown(with event: NSEvent) {
        if recording { record(event) } else { super.keyDown(with: event) }
    }
    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { endRecording(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.contains(.shift) else {
            title = L("Shift 留给反向选择，请重试", "Shift is reserved for reverse selection", "Shift 留給反向選擇，請重試"); return
        }
        var raw: CGEventFlags = []
        if flags.contains(.command) { raw.insert(.maskCommand) }
        if flags.contains(.option) { raw.insert(.maskAlternate) }
        if flags.contains(.control) { raw.insert(.maskControl) }
        let labels: [UInt16: String] = [48: "Tab", 49: "Space", 50: "`", 10: "§", 51: "⌫", 117: "⌦",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let value = RecordedShortcut(keyCode: Int64(event.keyCode), modifierRawValue: raw.rawValue, keyLabel: label)
        guard value.isValid else {
            title = L("请用 ⌘ / ⌥ / ⌃ 加一个普通键", "Use ⌘ / ⌥ / ⌃ plus a regular key", "請用 ⌘ / ⌥ / ⌃ 加一個普通鍵"); return
        }
        recordedShortcut = value
        recording = false; updateTitle()
        onShortcutRecorded?(value)
        onRecordingChanged?(false)
    }
    deinit { if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) } }
}
