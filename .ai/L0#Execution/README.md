# L0 执行资产

本层保存 Mac Go 的规格、检索连接源、锁定工具依赖及本地工作流。实际应用构建与安装脚本保留在 `scripts/`，统一操作入口为根 `gogogo.sh`；不能用 ZERO 示例覆盖原生发布流程。

- [当前规格](specs/README.md)：`active/`、`backlog/`、`completed/`。
- [本地工作流](workflows/README.md)：ZERO bootstrap 和检索适配。
- `configs/`：项目配置源与锁定 toolchain；本机绝对路径、授权及运行状态按忽略策略保存。
- `backups/`：bootstrap 保留的本机快照，不公开提交，也不进入检索集合。
- `evidence/`：仅保存可公开的脱敏验收摘要；窗口画面、标题、进程/签名清单及本机详细回执留在忽略的本机记录中。

客户端连接与 hook 只引用本层源，不手工维护第二份规则。当前没有 `gogogo.sh 8*` IDE 映射功能，也没有原生 Codex Stop hook；模板文件存在不代表对应集成已激活。
