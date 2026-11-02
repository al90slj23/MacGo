# Mac Go 项目事实

核实日期：2026-11-02。以实际源码、包清单和最终运行回执为证据；本页不把模板示例写成项目事实。

## 身份与范围

- 产品 **Mac Go**，公开源码仓库 [al90slj23/MacGo](https://github.com/al90slj23/MacGo)。单一原生应用集中提供多个工具和设置入口。
- 当前模块为窗口切换/可选缩略图、风扇读取/受限控制/温控规则。通用基础设置及授权集中展示，工具状态与排除列表独立。
- SwiftPM 包、主 target、product、可执行文件均为 `MacGo`，包名与显示名为 `Mac Go.app` / `Mac Go`。
- `Resources/Info.plist` 当前版本为 0.6.1 / build 16；版本以构建时清单及最终包为准。

## 技术与所有权

| 路径 | 已核实职责 |
| --- | --- |
| `Sources/MacGo/` | AppKit 应用、设置入口、窗口采集/激活/预览、风扇 UI 和本机服务管理 |
| `Sources/ToolboxCore/` | 可测试的窗口策略、布局、风扇规则与身份策略 |
| `Sources/SMCController/` | 设备读数、协议编码与受限风扇操作 |
| `Sources/FanHelperProtocol/` | XPC 协议及客户端会话 |
| `Sources/MacToolboxFanHelper/` | 特权服务、身份校验、所有权及恢复记录 |
| `Tests/` | 策略及 SMC 模拟测试；常规测试不写真实硬件 |
| `Resources/` | 应用元数据、原创图标、服务 plist 与安装资源 |

最低 macOS 13，Swift 工具清单为 5.9；窗口缩略图路径使用 macOS 14+ ScreenCaptureKit。构建没有第三方 SwiftPM 依赖。Swift 标准模块、AppKit、ServiceManagement、Security、IOKit 等是系统依赖。

偏好由应用 UserDefaults 维护：共享 `toolbox.*`、窗口 `windowSwitcher.*`、风扇 `fan.*`。系统 TCC 是权限状态所有者；应用只能请求和检测，不修改其数据库。用户本机控制服务授权须由原生管理员确认，root 拥有服务/身份清单；具体路径和精确签名限制以源码及原生规范为准。

兼容标识 `local.mactoolbox.*`、helper 名称及持久化命名空间保留，不能因品牌更名放宽校验。窗口画面仅按需捕获独立窗口并保留在内存；公开资料不包含本机画面、窗口标题或签名授权清单。

## 构建、发布与运行

- `swift test`：纯策略与模拟测试。
- `scripts/build-app.sh`：构建并严格签名验证 `dist/Mac Go.app`；默认临时签名，可显式指定 `CODE_SIGN_IDENTITY`。
- `scripts/install-local.sh`：固定更新到 `~/Applications/Mac Go.app`，保留前一版本、迁移旧规范包名、刷新该应用 Launch Services 注册；拒绝覆盖仍在运行的旧进程。
- `gogogo.sh`：项目统一校验、GitHub 发布和本机应用更新入口，操作含义见 [发布规范](../L3%23Standards/standards/09.tool-01.gogogo-sh.md)。
- 当前没有线上服务、生产主机、业务数据库或 Web 前后端部署。GitHub 推送成功与本机最终应用正在运行是不同结果。

当前构建的功能验收范围见 [验证状态](../L3%23Standards/references/validation.md)。源码测试、构建、安装、运行、系统权限、精确窗口激活和实际风扇转速分别证明，不继承旧构建的成功结论。

## 知识入口

完整原生规则归 [L3 原生 macOS 规范](../L3%23Standards/standards/01.arch-03.native-macos.md)，任务归 L0，导航归 L2，历史归 L4，L5 仅为派生检索。ZERO 采用来源、非适用范围与资料归位见 [采用记录](../L3%23Standards/references/zero-adoption.md)。
