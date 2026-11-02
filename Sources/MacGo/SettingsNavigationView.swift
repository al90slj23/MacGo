import AppKit

/// A page belongs to one tool or to Mac Go itself. Tool preferences are
/// never promoted to global behavior by their position in the navigation.
enum SettingsPage: String, CaseIterable {
    case general, permissions, switcher, switcherBlacklist, fans, fanRules, fanPreferences, guide
}

@MainActor final class SettingsNavigationView: NSView {
    var selected: ((SettingsPage) -> Void)?
    private var buttons: [SettingsPage: NSButton] = [:]

    init(page: SettingsPage) {
        super.init(frame: .zero)
        let brand = NSTextField(labelWithString: "Mac Go")
        brand.font = .systemFont(ofSize: 19, weight: .bold)
        let caption = NSTextField(labelWithString: L("一个入口，各自设置", "One toolbox, separate tools"))
        caption.font = .systemFont(ofSize: 11); caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [brand, caption])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.setCustomSpacing(27, after: caption)
        func group(_ title: String, symbol: String, pages: [(SettingsPage, String)]) {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
            let heading = NSStackView(views: [icon, label]); heading.spacing = 7
            stack.addArrangedSubview(heading)
            for (page, title) in pages {
                let button = NSButton(title: title, target: self, action: #selector(choose))
                button.identifier = NSUserInterfaceItemIdentifier(page.rawValue)
                button.setButtonType(.onOff); button.bezelStyle = .recessed
                button.alignment = .left; button.font = .systemFont(ofSize: 13)
                button.setAccessibilityLabel(title)
                button.heightAnchor.constraint(equalToConstant: 31).isActive = true
                stack.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                buttons[page] = button
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }
        }
        group(L("通用", "General"), symbol: "gearshape", pages: [
            (.general, L("基础设置", "Preferences")), (.permissions, L("授权", "Permissions"))])
        group(L("窗口切换", "Window switching"), symbol: "macwindow.on.rectangle", pages: [
            (.switcher, L("切换与外观", "Switching & appearance")), (.switcherBlacklist, L("黑名单", "Excluded apps"))])
        group(L("风扇控制", "Fan control"), symbol: "fanblades", pages: [
            (.fans, L("转速控制", "Fan speeds")),
            (.fanRules, L("温控规则", "Temperature rules")),
            (.fanPreferences, L("偏好设置", "Preferences"))])
        group(L("帮助", "Help"), symbol: "questionmark.circle", pages: [(.guide, L("使用说明", "Usage guide"))])
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18)
        ])
        select(page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ page: SettingsPage) {
        for (key, button) in buttons { button.state = key == page ? .on : .off }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let page = SettingsPage(rawValue: raw) else { return }
        select(page); selected?(page)
    }
}
