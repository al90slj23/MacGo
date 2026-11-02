import AppKit

@MainActor final class UsageGuideView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 28, height: 24)
        text.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 12
        let contents = NSMutableAttributedString(string: "")
        func heading(_ zh: String, _ en: String) {
            contents.append(NSAttributedString(string: L(zh, en) + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]))
        }
        func body(_ zh: String, _ en: String, _ traditional: String? = nil) {
            contents.append(NSAttributedString(string: L(zh, en, traditional) + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph]))
        }
        heading("设置层级", "Settings organization")
        body("左侧按通用与各工具分组。语言、登录启动和菜单栏放在“通用 → 基础设置”；系统权限集中在“通用 → 授权”，逐项完成后可在同页查看状态。每个工具保留自己的功能选项。",
             "The sidebar groups General and each tool. Language, login startup and menu bar visibility live under General → Preferences. Complete permissions and check their status under General → Permissions. Each tool keeps its own options.")
        heading("窗口切换", "Window switching")
        body("按住 Command 连续按 Tab 选择独立窗口，松开 Command 进入选中窗口。Shift 反向，方向键移动，Enter 确认，Esc 取消。按键保持按住时，鼠标移到窗口卡片上会更新选中框；点击卡片立即切换，不必先松开按键。“查看窗口列表”也支持相同的鼠标操作。",
             "Hold Command and press Tab to browse individual windows, then release Command to switch. Shift reverses, arrows navigate, Enter confirms, and Esc cancels. While holding the modifier, hover a window card to change the selection or click to switch immediately. Preview windows supports the same pointer controls.",
             "按住 Command 連續按 Tab 選擇獨立視窗，放開 Command 進入選取視窗。Shift 反向，方向鍵移動，Enter 確認，Esc 取消。按鍵保持按住時，滑鼠移到視窗卡片上會更新選取框；點擊卡片立即切換，不必先放開按鍵。「查看視窗列表」也支援相同的滑鼠操作。")
        body("在设置中录制自己的快捷键；Shift 留给反向选择。录制时按 Esc 或点击其他应用会取消，原有快捷键不变。默认选中方式可调整为上一个、当前或首个条目。",
             "Record your own shortcut in settings; Shift is reserved for reverse selection. Esc or switching away cancels recording and keeps the previous shortcut. Choose whether the initial selection is the previous, current or first item.")
        heading("显示与黑名单", "Display and excluded apps")
        body("集中显示将条目放在打开面板时鼠标所在的屏幕；分屏幕显示按窗口实际位置分组。无窗口应用在唤出屏幕面板的底部单独成栏，默认显示，可在“窗口切换 → 切换与外观”关闭。此栏仅供鼠标选择、点击打开，Cmd / Option + Tab 和方向键不会选到；条目较多时可独立横向滚动。",
             "Combined mode uses the display containing the pointer when you open the picker. Per-display mode groups windows by location. Apps without windows occupy a separate bottom bar on the invoking display. The bar is on by default and can be hidden under Window switching → Switching and appearance. Select and click these apps with the pointer; Cmd / Option + Tab and arrows skip the bar. It scrolls horizontally when needed.",
             "集中顯示將項目放在開啟面板時滑鼠所在的螢幕；分螢幕顯示按視窗實際位置分組。無視窗應用程式在叫出螢幕面板的底部單獨成列，預設顯示，可在「視窗切換 → 切換與外觀」關閉。此列僅供滑鼠選取、點擊開啟，Cmd / Option + Tab 和方向鍵不會選到；項目較多時可獨立橫向捲動。")
        body("卡片右上角的 × 会正常退出整个对应应用，包括它的其他窗口；未保存内容由该应用提示处理。“窗口切换 → 黑名单”只隐藏切换列表中的应用窗口，不影响风扇或其他工具；移除黑名单条目不会卸载应用。",
             "The × at the top right of a card requests a normal quit of the entire app, including its other windows. That app handles unsaved-work prompts. Window switching → Excluded apps hides windows only from the switcher, without affecting fan control or other tools. Removing an exclusion does not uninstall the app.",
             "卡片右上角的 × 會正常結束整個對應應用程式，包括它的其他視窗；未儲存內容由該應用程式提示處理。「視窗切換 → 黑名單」只隱藏切換列表中的應用程式視窗，不影響風扇或其他工具；移除黑名單項目不會解除安裝應用程式。")
        heading("权限", "Permissions")
        body("辅助功能用于读取窗口和切换焦点。屏幕录制仅用于可选缩略图；预览只保存在内存，不录音、不保存文件。使用授权气泡中的应用图标和设置入口完成授权；系统要求时重新启动 Mac Go。",
             "Accessibility reads windows and changes focus. Optional Screen Recording access supplies previews, kept only in memory without audio or saved recordings. Use the app icon and Settings shortcut in the permission guide; restart Toolbox if macOS asks.")
        heading("风扇控制", "Fan control")
        body("读取转速不需要管理员权限。本机控制服务先展示安装内容，再由 macOS 请求管理员确认。安装后仍需手动选择目标转速；本工具只恢复自己接管过的控制。如果其他软件正在手动调速，请先在该软件中恢复系统自动。",
             "Reading fan speed needs no administrator access. Local control shows the installation details before macOS requests administrator approval. Installing does not select a manual speed. Toolbox restores only control that it owns; if another app is controlling the fan, restore automatic mode in that app first.")
        body("菜单栏风扇图标可直接打开控制面板，与设置页共用同一控制会话。系统、最大、手动和自定义为选定模式，实际转速与硬件模式另外显示。手动百分比按最高转速计算，最低受硬件限制；0% 不代表停转。",
             "The menu bar fan opens the same control session as settings. Choose System, Maximum, Manual or Custom; actual RPM and hardware mode are shown separately. Manual percentages use maximum speed while respecting hardware minimums; 0% does not stop the fan.")
        body("在“风扇控制 → 温控规则”中添加传感器、温度条件、风扇和百分比，再选择自定义模式。多条匹配规则取较高转速，条件解除、读数不可用或时段外会释放本工具的控制。偏好设置可调整动画、CPU 温度显示、温度单位、开机延迟和每日时段；仅在 Mac Go 运行及会话有效时执行。",
             "Add a sensor, temperature condition, fan and percentage under Fan control → Temperature rules, then choose Custom. Multiple matches use the higher speed; cleared conditions, unavailable readings or schedule gaps release owned control. Fan preferences include animation, CPU temperature, units, boot delay and daily hours. Control runs only while Mac Go is open in an active session.")
        text.textStorage?.setAttributedString(contents)
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
