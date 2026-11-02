import AppKit
import ToolboxCore

enum SwitchShortcut: String, CaseIterable {
    case commandTab, optionTab, commandSection, commandGrave, custom

    var title: String {
        switch self {
        case .commandTab: return L("⌘ Tab · 按窗口切换", "⌘ Tab · Switch windows", "⌘ Tab · 切換視窗")
        case .optionTab: return L("⌥ Tab · 保留系统应用切换", "⌥ Tab · Keep macOS app switching", "⌥ Tab · 保留系統應用切換")
        case .commandSection: return "⌘ §"
        case .commandGrave: return L("⌘ ` · Tab 上方键", "⌘ ` · Key above Tab", "⌘ ` · Tab 上方鍵")
        case .custom: return L("自定义", "Custom", "自訂") + " · " + display
        }
    }
    var keyCode: Int64 { self == .custom ? (RecordedShortcut.current?.keyCode ?? 48) : (self == .commandGrave ? 50 : (self == .commandSection ? 10 : 48)) }
    var modifier: CGEventFlags { self == .custom ? (RecordedShortcut.current?.flags ?? .maskCommand) : (self == .optionTab ? .maskAlternate : .maskCommand) }
    var modifierTitle: String {
        let count = [CGEventFlags.maskCommand, .maskAlternate, .maskControl].filter { modifier.contains($0) }.count
        if count > 1 { return L("任一修饰键", "any modifier", "任一修飾鍵") }
        if modifier.contains(.maskCommand) { return "Command" }
        if modifier.contains(.maskAlternate) { return "Option" }
        return "Control"
    }
    var display: String {
        self == .custom ? (RecordedShortcut.current?.display ?? "⌘ Tab") : (self == .commandSection ? "⌘ §" : (self == .commandGrave ? "⌘ `" : (self == .optionTab ? "⌥ Tab" : "⌘ Tab")))
    }
}

enum ToolboxLanguage: String, CaseIterable {
    case system, simplifiedChinese, traditionalChinese, english
    var title: String {
        switch self {
        case .system: return L("跟随系统", "System", "跟隨系統")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum SwitcherScreenMode: String, CaseIterable {
    case combined, perScreen
    var title: String { self == .combined ? L("集中显示", "Combined", "集中顯示") : L("分屏幕显示", "Per display", "分螢幕顯示") }
}

enum SwitcherInitialSelection: String, CaseIterable {
    case previousWindow, currentWindow, firstWindow
    var title: String {
        switch self {
        case .previousWindow: return L("上一个窗口", "Previous window", "上一個視窗")
        case .currentWindow: return L("当前窗口", "Current window", "目前視窗")
        case .firstWindow: return L("列表第一个", "First item", "列表第一個")
        }
    }
}

enum ThumbnailContentMode: String, CaseIterable {
    case fit, fill, actualSize
    var title: String {
        switch self {
        case .fit: return L("缩放并居中", "Fit and center", "縮放並置中")
        case .fill: return L("填充并裁切", "Fill and crop", "填滿並裁切")
        case .actualSize: return L("原始大小", "Actual size", "原始大小")
        }
    }
}

/// Each tool owns its lifecycle; new tools can share the same menu-bar host.
@MainActor protocol ToolboxModule: AnyObject {
    var name: String { get }
    func start()
    func stop()
}

@MainActor final class Settings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var enabled: Bool {
        get { defaults.object(forKey: "windowSwitcher.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowSwitcher.enabled") }
    }
    var shortcut: SwitchShortcut {
        get { SwitchShortcut(rawValue: defaults.string(forKey: "windowSwitcher.shortcut") ?? "") ?? .commandTab }
        set { defaults.set(newValue.rawValue, forKey: "windowSwitcher.shortcut") }
    }
    var customShortcut: RecordedShortcut? {
        get { defaults.data(forKey: "windowSwitcher.customShortcut").flatMap { try? JSONDecoder().decode(RecordedShortcut.self, from: $0) }.flatMap { $0.isValid ? $0 : nil } }
        set {
            guard let newValue, newValue.isValid, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: "windowSwitcher.customShortcut"); return
            }
            defaults.set(data, forKey: "windowSwitcher.customShortcut")
        }
    }
    var showThumbnails: Bool {
        get { defaults.object(forKey: "windowSwitcher.showThumbnails") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowSwitcher.showThumbnails") }
    }
    var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "toolbox.showMenuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "toolbox.showMenuBarIcon") }
    }
    var language: ToolboxLanguage {
        get { ToolboxLanguage(rawValue: defaults.string(forKey: "toolbox.language") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "toolbox.language") }
    }
    var showWindowlessApps: Bool {
        // A mouse-only footer belongs to this tool. Preserve an explicit opt-out.
        get { defaults.object(forKey: "windowSwitcher.showWindowlessApps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "windowSwitcher.showWindowlessApps") }
    }
    var panelSizePercent: Int {
        get { let value = defaults.integer(forKey: "windowSwitcher.panelSizePercent"); return (30...100).contains(value) ? value : 70 }
        set { defaults.set(min(100, max(30, newValue)), forKey: "windowSwitcher.panelSizePercent") }
    }
    var screenMode: SwitcherScreenMode {
        get { SwitcherScreenMode(rawValue: defaults.string(forKey: "windowSwitcher.screenMode") ?? "") ?? .combined }
        set { defaults.set(newValue.rawValue, forKey: "windowSwitcher.screenMode") }
    }
    var initialSelection: SwitcherInitialSelection {
        get { SwitcherInitialSelection(rawValue: defaults.string(forKey: "windowSwitcher.initialSelection") ?? "") ?? .previousWindow }
        set { defaults.set(newValue.rawValue, forKey: "windowSwitcher.initialSelection") }
    }
    var thumbnailContentMode: ThumbnailContentMode {
        get { ThumbnailContentMode(rawValue: defaults.string(forKey: "windowSwitcher.thumbnailContentMode") ?? "") ?? .fit }
        set { defaults.set(newValue.rawValue, forKey: "windowSwitcher.thumbnailContentMode") }
    }
    var windowSwitcherExcludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "windowSwitcher.excludedBundleIDs") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "windowSwitcher.excludedBundleIDs") }
    }

    // Fan preferences are independent of global settings and every other tool.
    var animateFanIcon: Bool {
        get { defaults.object(forKey: "fan.animateFanIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fan.animateFanIcon") }
    }
    var showCPUTemperatureInMenuBar: Bool {
        get { defaults.object(forKey: "fan.showCPUTemperatureInMenuBar") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "fan.showCPUTemperatureInMenuBar") }
    }
    var temperatureUnit: FanTemperatureUnit {
        get { FanTemperatureUnit(rawValue: defaults.string(forKey: "fan.temperatureUnit") ?? "") ?? .celsius }
        set { defaults.set(newValue.rawValue, forKey: "fan.temperatureUnit") }
    }
    var controlPeriod: FanControlPeriod {
        get { FanControlPeriod(rawValue: defaults.string(forKey: "fan.controlPeriod") ?? "") ?? .always }
        set { defaults.set(newValue.rawValue, forKey: "fan.controlPeriod") }
    }
    var bootDelayMinutes: Int {
        get {
            guard let value = defaults.object(forKey: "fan.bootDelayMinutes") as? Int,
                  (0...10080).contains(value) else { return 15 }
            return value
        }
        set { if (0...10080).contains(newValue) { defaults.set(newValue, forKey: "fan.bootDelayMinutes") } }
    }
    var scheduleStartMinute: Int {
        get {
            guard let value = defaults.object(forKey: "fan.scheduleStartMinute") as? Int,
                  (0..<1440).contains(value) else { return 540 }
            return value
        }
        set { if (0..<1440).contains(newValue) { defaults.set(newValue, forKey: "fan.scheduleStartMinute") } }
    }
    var scheduleEndMinute: Int {
        get {
            guard let value = defaults.object(forKey: "fan.scheduleEndMinute") as? Int,
                  (0..<1440).contains(value) else { return 1080 }
            return value
        }
        set { if (0..<1440).contains(newValue) { defaults.set(newValue, forKey: "fan.scheduleEndMinute") } }
    }
    var fanRules: [FanAutomationRule] {
        get {
            guard let data = defaults.data(forKey: "fan.rules"),
                  let rules = try? JSONDecoder().decode([FanAutomationRule].self, from: data) else { return [] }
            return rules
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "fan.rules")
        }
    }
    var selectedFanMode: FanOperatingMode {
        get { FanOperatingMode(rawValue: defaults.string(forKey: "fan.selectedMode") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "fan.selectedMode") }
    }
    var manualFanPercent: Double {
        get {
            guard let value = defaults.object(forKey: "fan.manualPercent") as? Double,
                  value.isFinite, (0...100).contains(value) else { return 100 }
            return value
        }
        set { if newValue.isFinite, (0...100).contains(newValue) { defaults.set(newValue, forKey: "fan.manualPercent") } }
    }
}
