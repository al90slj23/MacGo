# Mac Go Agent 入口

先完整阅读 `.ai/L1#Overview/zero-project-facts.md`、`.ai/L1#Overview/guide.md` 和 `.ai/L2#Index/toc.md`。修改前必须阅读 `.ai/L3#Standards/standards/01.arch-03.native-macos.md`，其中完整保留原 Mac Go 的设置层级、权限、风扇安全、品牌与实机验收规则。

- 当前规则唯一源为 `.ai/L3#Standards/standards/`；根 README 面向使用者，`docs/` 仅保留历史链接入口。
- 新任务在 L0 建立或更新规格；知识、当前规范、历史与派生检索分别归所属层，不能以旧构建或模拟结果替代当前应用验收。
- 发布前读 `.ai/L3#Standards/standards/09.tool-01.gogogo-sh.md`：本项目仅发布到 GitHub 并更新本机应用，没有线上服务部署。
- 保留无关改动，按审阅过的文件清单暂存；不得整仓 `git add -A`、强推或自动变基。公开内容须排除私密本机证据和第三方二进制。

<!-- BEGIN ZERO BOOTSTRAP -->
## ZERO project workflow

- Read `.ai/L1#Overview/zero-project-facts.md` and the project's existing guide first, then `.ai/L1#Overview/zero-template-guide.md` and `.ai/L2#Index/toc.md`.
- Project facts and existing project boundaries govern adoption. Read `.ai/L2#Index/zero-onboarding.md` and reconcile template standards through `.ai/L0#Execution/specs/active/zero-onboarding/00.spec-03.tasks.md`; the first introduction remains pending until the Agent completes that audit.
- Maintain source knowledge only in `.ai`. QMD retrieves its Markdown; CodeGraph derives relations from the project's source code. Verify retrieved claims against their owning sources.
- With an exact path/symbol, read the relevant range directly. Unknown document topics start with a scoped QMD lex query (normally 3 results, rerank disabled); code relationships start with a narrow CodeGraph query (normally maxFiles 3). Use vector/expanded search only when needed.
- Reuse current unchanged excerpts still visible in this conversation and treat returned current source as already read. Fetch only missing or stale ranges; normally read 40-80 lines around a document hit and print selected paths/lines/excerpts rather than whole tool objects. Required initial context, audits and complete-file logic reviews still apply.
- If retrieval is unavailable, make at most one targeted retry, then use scoped rg and range reads. Keep the project's owning-source, host and data-boundary verification requirements.
- Batch all `.ai` source Markdown edits and automatically run `bash .ai/L0#Execution/workflows/local/retrieval-indexes.sh refresh` once from the project root at task completion. Read-only tasks and unchanged sources do not proactively refresh; handle failures and reserve explicit repair for a diagnosed stale/broken index.
- Inspect legacy documentation and conventions during onboarding. Business code, API names and database schemas require separately reviewed semantic migrations; bootstrap creates no such migration.
<!-- END ZERO BOOTSTRAP -->
