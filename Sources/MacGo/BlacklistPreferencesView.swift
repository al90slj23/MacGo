import AppKit
import UniformTypeIdentifiers

@MainActor final class BlacklistPreferencesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let id: String
        let name: String
        let url: URL?
    }
    private let settings: Settings
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: L("尚未排除任何应用", "No apps excluded"))
    private let removeButton = NSButton(title: L("移除", "Remove"), target: nil, action: nil)
    private var entries: [Entry] = []
    private var knownURLs: [String: URL] = [:]
    var changed: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init(frame: .zero)
        build()
        registerForDraggedTypes([.fileURL])
        reloadEntries()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let title = NSTextField(labelWithString: L("窗口切换 · 黑名单", "Window switching · Excluded apps"))
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let explanation = NSTextField(wrappingLabelWithString: L("仅在窗口切换中隐藏这些应用的窗口，不影响风扇控制或 Mac Go 的其他功能。添加正在运行的应用、选择应用文件，或把 .app 拖到这里。移除只会取消排除，不会卸载应用。",
            "Hide these apps only in the window switcher. Fan control and other toolbox tools are unaffected. Add a running app, choose an application, or drag an .app here. Removing an entry includes it again without uninstalling it."))
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11); countLabel.textColor = .secondaryLabelColor
        let running = NSButton(title: L("添加正在运行的应用…", "Add running app…"), target: self, action: #selector(addRunning))
        let choose = NSButton(title: L("选择应用…", "Choose application…"), target: self, action: #selector(chooseApplications))
        removeButton.target = self; removeButton.action = #selector(removeSelected)
        let controls = NSStackView(views: [running, choose, removeButton])
        controls.orientation = .horizontal; controls.spacing = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.title = L("应用", "Application")
        column.minWidth = 400
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 60
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .inset
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel(L("排除的应用列表", "Excluded applications"))
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        let surface = NSView()
        surface.addSubview(scroll); surface.addSubview(emptyLabel)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, explanation, countLabel, surface, controls])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            surface.widthAnchor.constraint(equalTo: stack.widthAnchor),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: surface.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
    }

    func reloadEntries() {
        entries = settings.windowSwitcherExcludedBundleIDs.map { id in
            let url = knownURLs[id] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let bundle = url.flatMap(Bundle.init(url:))
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url?.deletingPathExtension().lastPathComponent ?? id
            return Entry(id: id, name: name, url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        table.reloadData()
        countLabel.stringValue = String(format: L("已排除 %d 个应用", "%d apps excluded"), entries.count)
        emptyLabel.isHidden = !entries.isEmpty
        removeButton.isEnabled = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { removeButton.isEnabled = !table.selectedRowIndexes.isEmpty }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let view = NSTableCellView()
        let icon = NSImageView(image: entry.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)!)
        icon.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let identifier = NSTextField(labelWithString: entry.id)
        identifier.font = .systemFont(ofSize: 10); identifier.textColor = .secondaryLabelColor
        identifier.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, identifier])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        icon.translatesAutoresizingMaskIntoConstraints = false; labels.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon); view.addSubview(labels)
        view.setAccessibilityLabel(entry.name + " · " + entry.id)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 36), icon.heightAnchor.constraint(equalToConstant: 36),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            identifier.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)
        ])
        return view
    }

    @objc private func addRunning(_ sender: NSButton) {
        let menu = NSMenu()
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications.sorted(by: { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }) {
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier,
                  id != ownID, !settings.windowSwitcherExcludedBundleIDs.contains(id), seen.insert(id).inserted else { continue }
            if let url = app.bundleURL { knownURLs[id] = url }
            let item = NSMenuItem(title: app.localizedName ?? id, action: #selector(selectRunningApp), keyEquivalent: "")
            item.target = self; item.representedObject = id
            if let image = app.icon?.copy() as? NSImage { image.size = NSSize(width: 18, height: 18); item.image = image }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L("没有可添加的正在运行应用", "No running apps to add"), action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func selectRunningApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.windowSwitcherExcludedBundleIDs.insert(id)
        reloadEntries(); changed?()
    }

    @objc private func chooseApplications() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择要排除的应用", "Choose apps to exclude")
        panel.message = L("添加后，该应用的全部窗口都会从切换面板隐藏。", "All windows of each selected app will be hidden from the switcher.")
        panel.prompt = L("添加", "Add")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard response == .OK else { return }
                self?.add(urls: panel.urls)
            }
        }
    }

    @discardableResult private func add(urls: [URL]) -> Bool {
        var added = false
        for url in urls {
            guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !id.isEmpty, id != Bundle.main.bundleIdentifier else { continue }
            knownURLs[id] = url
            if settings.windowSwitcherExcludedBundleIDs.insert(id).inserted { added = true }
        }
        if added { reloadEntries(); changed?() }
        return added
    }

    @objc private func removeSelected() {
        let ids = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }
        guard !ids.isEmpty else { return }
        settings.windowSwitcherExcludedBundleIDs.subtract(ids)
        reloadEntries(); changed?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains(where: { $0.pathExtension.lowercased() == "app" }) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return add(urls: urls)
    }
}
