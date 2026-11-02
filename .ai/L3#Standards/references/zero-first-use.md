# ZERO 首次引入：新项目与既有项目

更新：2026-10-23；适用：ZERO v2.1.2，macOS/Linux。

ZERO 是项目初始化与改造模板。把文件复制过去只是准备阶段；Agent 还要核实项目事实、适配现有规范并建立可用检索。项目日常只维护 `.ai` 原始资料。

## 一次性环境

- Bash、Python 3.11+；完整检索初始化还需 Node.js 22+ 与 npm。
- 首次下载固定版本 CLI 和三个本地 GGUF 模型需要网络、磁盘和计算时间。默认模型约 2.4 GB；速度取决于网络、硬件及文档规模。
- 脚本不静默安装全局 Node/Python 或修改客户端全局信任设置。Agent 应先检查环境，说明缺失项并处理实际阻塞。

## 两阶段首次引入

### 1. 准备源资料和连接

将 ZERO 下载为模板源；可放在目标项目之外。假设模板位于当前目录的 `ZERO/`，目标是当前项目：

```bash
bash ZERO/.ai/L0#Execution/workflows/local/zero-bootstrap.sh --target "$PWD" --prepare-only
```

若以 ZERO 仓库本身建立新项目：

```bash
bash .ai/L0#Execution/workflows/local/zero-bootstrap.sh --target "$PWD" --prepare-only
```

此阶段先预检和备份，再合并模板；保留已有 `.ai`、AGENTS 和客户端设置。模板不同名文件可补齐，同名不同内容不直接覆盖。项目事实入口、首次适配规格和必要的客户端配置源保存到目标 `.ai`。

默认 `--client codex`：合并现有 Codex TOML，保留其他设置和 MCP；配置源在 `.ai/L0#Execution/configs/zero-codex.toml`，根 `.codex/config.toml` 是相对软链。`--client none` 仅准备源资料，其他客户端按正式设置引用同一适配器。

目标有旧资料时，备份位于 `.ai/L0#Execution/backups/zero-bootstrap-*/`；清单记录文件、权限与链接。旧备份目录不递归打入新备份，仍保留原处。冲突会报告，不能为消除提示删除已有事实。

### 2. Agent 完成项目适配

Agent 按新建的首次适配规格完成下列工作：

| 检查 | 要完成的改造 |
|---|---|
| 项目身份、技术栈与边界 | 从源码/配置核实，写入 L1 项目事实入口，不能把 ZERO 示例当真实项目事实 |
| 旧文档与规则 | 原文保留；当前规范归 L3，参考事实/操作指南归 L3 references/guides，任务归 L0，历史归 L4；更新引用并核验无损 |
| Path is King 与开发约定 | 审计目录、模块、API、权限、数据库和部署规则；落实适用规则，明确已有接口/数据的兼容迁移方案 |
| 现有业务约束 | 保留项目所有权、安全和部署边界；先验证再调整，不批量猜测并重命名生产路由/表 |
| 入口与自动更新 | AGENTS/客户端只保留入口，规则源在 `.ai`；写源文档后由 Agent 自动刷新索引 |

新项目在建立第一个模块时采用规范。既有项目需要按真实差异实施和测试；业务改造超出当前授权或依赖外部条件时，记录具体未完成项。运行时安装成功不能代替项目改造完成。

既有 `.ai` 若采用不同的 L3 布局，应融合适用规则并保留唯一规范主版本，更新项目 L2/L1，不长期维护两套同主题规范。首次适配完成后按规格生命周期归档；同步原文引用，稳定导航位于 `L2#Index/zero-onboarding.md`。bootstrap 能识别 completed 中的已完成任务，重复执行不会重新建立 active 待办。

### 3. 完整初始化并验收

项目资料准备好后，从目标项目执行：

```bash
bash .ai/L0#Execution/workflows/local/zero-bootstrap.sh --target "$PWD"
bash .ai/L0#Execution/workflows/local/retrieval-indexes.sh status
```

完整模式自动安装 `.ai` 内锁定的 QMD 2.8.3 / CodeGraph 1.6.2，下载模型，建立 QMD 文本/中文语义索引及源码关系图。可以从原模板入口指定同一 `--target` 重复运行；现有资料保留，工具无需重复安装，已完成索引增量更新。

验收须包含：QMD 命中本项目源文档、中文语义查询可回溯来源、备份/生成物不进入文档集合且原始 evidence 保留、CodeGraph 命中项目符号、MCP 可连接、待嵌入数量为 0。多对话使用时核验两个 CodeGraph 客户端可共享服务，一方退出不影响另一方。空项目尚无源码符号时明确记录，不虚构图谱命中。

Codex 首次连接后重连/重启，以加载新 MCP；项目需按客户端正常机制信任。本版不安装原生 Codex Stop hook：收尾由项目 AGENTS/L1 规则驱动 Agent 执行，另有 MCP 启动刷新和 CodeGraph 源码 watcher。Kiro `askAgent` 模板不是 Codex 可执行 hook；未来添加非 managed 原生 Codex hook，需对具体定义另行信任，不能以复制模板代替激活。

## 日常与数据位置

- 只维护 `.ai` 原始资料与 L0 配置源；工具、生成配置、模型和索引在 `L5#Knowledge/.generated/` 自动重建，Git 忽略生成物。
- QMD 源集合明确忽略 `L0#Execution/backups/**` 和 `**/.generated/**`，`L0#Execution/evidence/` 原始证据仍可检索。适配器检测模型、集合或忽略策略漂移后恢复生成配置；策略调整写入 L0 源配置逻辑。
- CodeGraph 根 `.codegraph` 为自动入口；共享 daemon 支持多个对话，用户目录进程登记与临时 socket 为自动运行元数据。路径预检只允许当前用户拥有的指定 `.generated/codegraph/daemon.sock` Unix socket，不能泛化为允许任意特殊文件或软链。
- QMD 普通读取不刷新全库；MCP 启动后台检查是否需要补齐。Agent 批量完成源资料修改后在收尾执行一次 `retrieval-indexes.sh refresh` 并处理失败，只读任务和源资料未变不主动刷新。CodeGraph 活动会话监听源码。
- 已知位置直接读范围，未知主题先小结果 lex，关系问题先小范围 CodeGraph；复用当前对话仍可见的未变证据。完整的预算和降级规则见检索适配规范，首次项目事实审计仍须完成。
- 模板下载目录不承担项目运行依赖；完成引入后，采用项目无需另外维护 ZERO 下载副本。

## 给 AI 的首次引入指令

> 将 ZERO 引入当前项目。先阅读 ZERO 的 `zero-first-use.md`，执行指定目标的 `--prepare-only`。保留现有事实和规则，完成生成的首次适配清单，核实技术栈、知识归位和代码/接口/数据约定的差异，实施可验证的改造。然后运行完整 bootstrap，检查 QMD、CodeGraph 与客户端连接，汇报完成项和具体阻塞；日常索引由你维护。

相关规范：[检索适配](../standards/10.ai-memory-04.retrieval-adapters.md) · [旧 L5 迁移](migration-guide-v2-1.md)。
