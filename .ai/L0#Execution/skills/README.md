# L0#Execution/skills - AI 技能文档

**定位**：管理 AI 技能文档（Skills），遵循 agentskills.io 标准。

---

## 核心架构原则（零容忍）

**平台无关源文件 + 符号链接映射**：

1. **源文件直接放在 `.ai/L0#Execution/skills/{name}/`**
   - 不套 `kiro/` 等平台子目录
   - 每个 skill 一个独立目录

2. **通过符号链接映射到各 IDE**：
   - Kiro：`.kiro/skills/{name}/`
   - Claude Code：`.claude/skills/{name}/`
   - OpenCode：`.opencode/skills/{name}/`

3. **禁止直接修改映射目标**：
   - 所有修改都在 `.ai/L0#Execution/skills/` 进行

---

## 目录结构

```
.ai/L0#Execution/skills/
├── README.md                  # 本文档
└── {skill-name}/              # 技能目录（小写字母 + 连字符）
    ├── SKILL.md               # 技能主文档（必须）
    ├── examples/              # 示例文件（可选）
    └── assets/                # 资源文件（可选）
```

---

## Skill 文件规范

### SKILL.md 结构

```markdown
---
name: skill-name
description: 技能简短描述
version: 1.0.0
---

# Skill Name

## 概述
技能的详细描述

## 使用场景
- 场景 1
- 场景 2

## 使用方法
具体的使用步骤和示例

## 注意事项
重要的注意事项和限制

## 示例
实际使用示例
```

### 必须字段（frontmatter）
- `name`：技能名称（小写字母 + 连字符）
- `description`：简短描述（一句话）
- `version`：版本号（语义化版本）

---

## 创建新 Skill

```bash
# 1. 创建技能目录
mkdir -p .ai/L0#Execution/skills/my-skill

# 2. 创建 SKILL.md
cat > .ai/L0#Execution/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: 我的技能描述
version: 1.0.0
---

# My Skill

## 概述
技能的详细描述

## 使用场景
- 场景 1

## 使用方法
具体步骤

## 注意事项
重要提示

## 示例
示例代码
EOF

# 3. 映射到 Kiro
./gogogo.sh 8a

# 4. 验证
ls -la .kiro/skills/my-skill/SKILL.md
```

---

## Skill 命名规范

### 目录命名
- **格式**：小写字母 + 连字符
- **示例**：`code-review`、`test-generation`、`api-design`

### Skill 名称
- **格式**：与目录名一致
- **示例**：`code-review`、`test-generation`、`api-design`

---

## Skill 类型

### 1. 开发技能
- **用途**：辅助代码开发
- **示例**：`code-review`、`refactoring`、`debugging`

### 2. 测试技能
- **用途**：辅助测试编写
- **示例**：`test-generation`、`test-coverage`、`e2e-testing`

### 3. 文档技能
- **用途**：辅助文档编写
- **示例**：`api-documentation`、`readme-generation`、`changelog`

### 4. 架构技能
- **用途**：辅助架构设计
- **示例**：`api-design`、`database-design`、`system-design`

---

## 映射关系

| L0#工作执行 (Execution) 源目录 | Kiro | Claude Code | OpenCode |
|-----------|------|-------------|----------|
| `.ai/L0#Execution/skills/{name}/` | `.kiro/skills/{name}/` | `.claude/skills/{name}/` | `.opencode/skills/{name}/` |

**注意**：
- Cursor 不支持 Skills
- OpenCode 同时兼容 `.claude/skills/` 和 `.opencode/skills/`

---

## 激活 Skill

### Kiro
```bash
# 通过 discloseContext 工具激活
discloseContext(name: "skill-name")
```

### Claude Code
```bash
# 通过 @skill 激活
@skill skill-name
```

### OpenCode
```bash
# 通过 @skill 激活
@skill skill-name
```

---

## Skill 版本管理

### 版本号规范
- **格式**：`major.minor.patch`（语义化版本）
- **示例**：`1.0.0`、`1.2.3`、`2.0.0`

### 版本更新规则
- **major**：不兼容的 API 变更
- **minor**：向后兼容的功能新增
- **patch**：向后兼容的问题修正

---

## 注意事项

1. **SKILL.md 是必须文件**：每个 skill 目录必须包含
2. **frontmatter 是必须的**：name、description、version 三个字段
3. **不要直接修改映射目标**：所有修改在 `.ai/L0#Execution/skills/` 进行
4. **新增 skill 后运行映射命令**：`./gogogo.sh 8a`
5. **保持 skill 独立**：每个 skill 一个目录，不要合并

---

## 常见 Skills

| Skill | 用途 | 适用场景 |
|-------|------|---------|
| `code-review` | 代码审查 | PR 审查、代码质量检查 |
| `test-generation` | 测试生成 | 单元测试、集成测试 |
| `api-design` | API 设计 | RESTful API、GraphQL |
| `database-design` | 数据库设计 | 表结构、索引优化 |
| `refactoring` | 代码重构 | 代码优化、架构调整 |

---

**最后更新**：2026-04-16
