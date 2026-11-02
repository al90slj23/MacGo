import AppKit
import ServiceManagement

/// Only preferences shared by all Mac Go tools belong on this page.
@MainActor final class GeneralPreferencesView: NSView {
    private let settings: Settings
    private let login = NSButton(checkboxWithTitle: L("登录时启动 Mac Go", "Start Mac Go at login"), target: nil, action: nil)
    private let showMenu = NSButton(checkboxWithTitle: L("显示菜单栏图标", "Show menu bar icon"), target: nil, action: nil)
    private let language = NSPopUpButton()

    var menuVisibilityChanged: (() -> Void)?
    var languageChanged: (() -> Void)?
    var loginChanged: ((Bool) -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init(frame: .zero)
        login.target = self; login.action = #selector(changeLogin)
        showMenu.target = self; showMenu.action = #selector(changeMenuVisibility)
        language.addItems(withTitles: ToolboxLanguage.allCases.map(\.title))
        language.target = self; language.action = #selector(changeLanguage)

        let languageLabel = NSTextField(labelWithString: L("界面语言", "Language"))
        let languageRow = NSStackView(views: [languageLabel, language])
        languageRow.orientation = .horizontal; languageRow.alignment = .centerY; languageRow.spacing = 18
        let startup = SharedSettingsLayout.card(L("启动与显示", "Startup and visibility"), views: [
            login, showMenu,
            SharedSettingsLayout.hint(L("隐藏菜单栏图标后，仍可从 Dock 或“应用程序”重新打开 Mac Go。",
                                      "When the menu bar icon is hidden, reopen Mac Go from the Dock or Applications."))
        ])
        let appearance = SharedSettingsLayout.card(L("语言", "Language"), views: [
            languageRow,
            SharedSettingsLayout.hint(L("语言设置对 Mac Go 中的所有工具生效。各工具自己的选项，在对应工具下设置。",
                                      "Language applies to every tool. Options specific to a tool live under that tool."))
        ])
        SharedSettingsLayout.install(on: self, title: L("通用设置", "General settings"),
            explanation: L("这里的设置对整个 Mac Go 生效。", "These preferences apply to all Mac Go tools."),
            views: [startup, appearance])
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshControls() {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showMenu.state = settings.showMenuBarIcon ? .on : .off
        language.selectItem(at: ToolboxLanguage.allCases.firstIndex(of: settings.language) ?? 0)
    }

    @objc private func changeLogin() { loginChanged?(login.state == .on) }
    @objc private func changeMenuVisibility() {
        settings.showMenuBarIcon = showMenu.state == .on
        menuVisibilityChanged?()
    }
    @objc private func changeLanguage() {
        settings.language = ToolboxLanguage.allCases[language.indexOfSelectedItem]
        languageChanged?()
    }
}

/// Common visual layout, with no shared tool behavior or preferences.
@MainActor enum SharedSettingsLayout {
    static func install(on view: NSView, title: String, explanation: String, views: [NSView]) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = SharedSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 25, weight: .bold)
        let description = hint(explanation)
        description.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [heading, description] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for child in views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    static func hint(_ text: String) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = .systemFont(ofSize: 11); result.textColor = .secondaryLabelColor
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return result
    }

    static func card(_ title: String, views: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 17),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -17),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for child in views {
            if child is NSTextField { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            else { child.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        }
        return container
    }
}

private final class SharedSettingsDocumentView: NSView { override var isFlipped: Bool { true } }
