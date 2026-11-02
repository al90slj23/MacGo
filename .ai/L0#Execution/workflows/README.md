# 本地工作流

- `local/zero-bootstrap.sh`：保留式准备 `.ai`、备份冲突资料和配置检索；先 `--prepare-only` 完成事实适配，再完整初始化。
- `local/retrieval-indexes.sh`：QMD / CodeGraph 的 `init`、`status`、`refresh` 和 MCP 入口。依赖 Bash、Python 3.11+、Node.js 22+、npm；工具版本由 `configs/retrieval-toolchain` 锁定。
- 根 `gogogo.sh` 和 `scripts/`：本项目原生校验、GitHub 推送及本机安装/启动，不执行线上部署。

知识原文归 `.ai`，生成工具、模型、索引位于 `L5#Knowledge/.generated/`，根 `.codegraph` 仅为派生入口。MCP 连接、客户端重连/信任与检索命中须单独验收。

修改源 Markdown 后由 Agent 批量收尾执行一次 `refresh`，普通读取不重复刷新全库。原文没变时不主动刷新。初始化失败不能隐藏为成功或为了消除状态删除原始资料。
