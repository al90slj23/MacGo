# ZERO 采用与资料归位

日期：2026-11-02。模板来源：[al90slj23/ZERO](https://github.com/al90slj23/ZERO)，v2.1.2，固定提交 `d6a5da15b8ddbefb4a99b3b71a3dac4df85bceb2`。

## 采用范围

采用六层知识生命周期、规格结构、保留式 bootstrap、QMD 文档检索和 CodeGraph 源码关系适配器。`ZERO/` 是独立、忽略提交的本地模板克隆；项目日常运行依赖自身 `.ai`，不依赖模板目录。

Mac Go 是现有 Swift 原生应用。模板中的 Web 页面、REST 路由、数据库命名、后台表格、远程主机、线上部署、Kiro/其他 IDE 映射示例不属于本项目当前规范，也不构成已经实现的功能。适用的架构、命名、质量及发布约定已按实际源码改写。

为避免把模板示例当作当前约束，准备阶段复制的非适用 Markdown 未进入项目知识发布集；原始资料可从上述固定模板提交恢复。保留检索/六层规范及首次引入参考。未修改 ZERO 上游克隆，不把模板变动和 Mac Go 发布混合提交。

## 现有资料

| 原位置 | 当前唯一源 | 处理 |
| --- | --- | --- |
| 根 `AGENTS.md` 的 Mac Go 规则 | [原生 macOS 规范](../standards/01.arch-03.native-macos.md) | 原规则完整保留；根文件仅做入口 |
| `docs/VALIDATION.md` | [验证状态](validation.md) | 内容保留；原路径成为链接入口 |
| `docs/reverse-engineering/ifan-control.md` | [iFan 分析](ifan-control.md) | 内容保留；原路径成为链接入口 |
| 根 `README.md` | 根 `README.md` | 保留公开产品说明，规范和验收链接到 `.ai` |
| `THIRD_PARTY_NOTICES.md`、Stats MIT 许可 | 原法律文件 | 法律归属文件保留，不复制为规范 |

## 兼容性决策

不批量重命名 SwiftPM 模块或既有持久化字段。`local.mactoolbox.*`、`windowSwitcher.*`、`fan.*`、`toolbox.*` 和兼容 helper 名称按现有迁移保留。窗口切换排除列表不是全局黑名单。当前没有业务 REST API、数据库表或服务器部署，因此不存在相应迁移任务；以后新增时另建规格。

检索初始化、客户端 MCP 实际连通、发布脚本测试、GitHub 推送、本机安装运行以及系统权限/硬件验收分别记录，不能用任一项代替其余项。
