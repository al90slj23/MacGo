# ZERO 项目入口

> 版本：v2.1.2；更新：2026-10-23。
> 以下保留 ZERO 工作方式；Mac Go 实际边界以 [项目事实](zero-project-facts.md) 与 [原生规范](../L3%23Standards/standards/01.arch-03.native-macos.md) 为准。

## 首次引入

先读 [首次引入指南](../L3%23Standards/references/zero-first-use.md)。从模板入口指定目标项目：

```bash
bash ZERO/.ai/L0#Execution/workflows/local/zero-bootstrap.sh --target "$PWD" --prepare-only
```

Agent 按生成的首次适配规格核实项目事实、归位资料并处理代码/接口/数据约定的差异，再运行目标项目中的完整入口：

```bash
bash .ai/L0#Execution/workflows/local/zero-bootstrap.sh --target "$PWD"
```

初始化自动安装固定版本本地 CLI、下载模型、建立 QMD/CodeGraph 索引并合并 Codex 连接。首次环境需要 macOS/Linux、Bash、Python 3.11+、Node.js 22+ 和 npm。其他客户端可用 `--client none`，按正式格式采用相同 MCP 入口。

脚本保留并备份既有资料；运行准备与项目适配分别验收。采用项目先读自己的事实入口、现有指南和待办规格，不能把 ZERO 的示例当成项目事实。

## 核心规则摘要

1. **Path is King**：模块路径说明所有权，遵循 Mac Go 已有 SwiftPM 与 Swift 命名。当前项目没有业务表或 Web API，不据模板引入它们。
2. **证据优先**：从实际源码、配置和系统证据核实行为，文档记录已验证事实及未知项。
3. **唯一知识源**：知识及接入配置源在 `.ai`。禁止建立并行的根文档树或手写第二套 L5 事实图。
4. **唯一规范版本**：当前规则归 L3，L2 只导航，L1 只摘要。既有项目按真实布局收敛规则，处理冲突后更新所有入口。
5. **命名清楚**：完整语义、行业通用术语和同领域平铺优先，不为简短损失含义。详见 L3 命名标准。
6. **执行资产在 L0**：hooks、skills、specs、templates、workflows 的源文件在 L0，客户端只保留入口或映射。首次接入使用 bootstrap，保留项目部署脚本与原有规则。
7. **变更同步**：规范变化先检查冲突，再同步 L3 → L2 → L1；有日期的 L4 记录决策与验证，不反向覆盖当前规范。
8. **栈与所有权属于项目**：模板不指定项目已经使用某技术栈。业务事实、数据所有权、安全和部署边界必须在项目事实及规格中核实。

## 六层职责

| 层 | 内容 |
|---|---|
| L0#工作执行 (Execution) | 当前规格、执行配置、工作流、备份与验收 |
| L1#项目概览 (Overview) | 项目事实、关键边界与最小阅读入口 |
| L2#规范索引 (Index) | 当前规范和任务的导航 |
| L3#完整规范 (Standards) | 当前唯一规范；references/guides 保存有来源的事实和操作参考 |
| L4#操作日志 (Changelog) | 有日期的历史决策、结果及其证据 |
| L5#知识检索与关联 (Knowledge) | 工具派生的文档检索和源码关系；不保存唯一事实正文 |

阅读顺序：当前任务 L0 / 项目 L1 → L2 定位 → L3 当前规则；L4 按需追溯，L5 帮助定位原始来源。遵循采用项目更具体的入口要求。

## 检索与自动维护

- 已知路径/符号直接定向读相关范围；未知文档主题先 QMD 小范围 `lex`（通常 3 条、关闭 rerank），不够再按需要用 vec/自动扩展。源码调用、依赖与影响面先小范围 CodeGraph（通常 `maxFiles: 3`）。
- 工具已返回的当前源码视为已读；复用当前对话仍可见的未变片段，只补缺失或过期范围。QMD `get` 通常取命中前后 40–80 行；限制结果及打印片段，不把整个工具对象和正文重复输出。首次必读 L1、完整逻辑审查和审计仍按任务要求读完整内容。
- 检索不可用最多一次有针对性的重试，然后在所属目录用 `rg` 和范围读取；检索结果仍须核实来源、版本与项目事实，不能用工具排名代替证据。
- 工具、生成配置、模型、索引位于 `.ai/L5#Knowledge/.generated/`，由 L0 适配器重建。根 `.codegraph` 是自动入口软链。
- QMD 集合排除 `L0#Execution/backups/**` 和 `**/.generated/**`，保留 `L0#Execution/evidence/` 原始证据；生成配置的模型、集合与忽略策略漂移由适配器恢复，不手改派生配置。
- CodeGraph 默认共享 daemon，支持多个 AI 对话；用户目录进程登记和临时 socket 是自动元数据。预检仅放行当前用户拥有的 `.generated/codegraph/daemon.sock` Unix socket，其他异常路径仍拒绝。
- QMD 普通读取不刷新全库；MCP 启动后台补齐。CodeGraph 活动 MCP 监听源码，离线变化在下次启动补齐。
- Agent 批量完成 `.ai` 源 Markdown 修改后，任务收尾只运行一次 `bash .ai/L0#Execution/workflows/local/retrieval-indexes.sh refresh`；只读任务、源资料未变不主动刷新。失败由 Agent 处理或说明可用状态，诊断为索引异常时才用显式修复入口。
- 当前自动触发就是 MCP 启动、Agent 收尾和 CodeGraph 源码 watcher；本版未安装原生 Codex Stop hook。Kiro `askAgent` 模板不能当作 Codex hook，新增原生 hook 另按客户端信任机制处理。
- Codex 首次连接后需重连/重启加载工具，并按客户端机制信任项目；文件存在不代表 MCP 已连接。

## 当前规范导航

- [L2 总目录](../L2%23Index/toc.md)
- [元规范](../L3%23Standards/standards/00.meta-01.core.md)
- [核心架构](../L3%23Standards/standards/01.arch-01.core.md)
- [通用命名](../L3%23Standards/standards/04.quality-01.naming.md) 
- [检索适配与成本边界](../L3%23Standards/standards/10.ai-memory-04.retrieval-adapters.md)
- [L0 执行资产](../L0%23Execution/README.md) 与 [规格生命周期](../L0%23Execution/specs/README.md)

L1 保持 300 行以内；详细规则和实现示例查 L3，避免多处维护正文。
