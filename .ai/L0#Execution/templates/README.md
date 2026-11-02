# L0#Execution/templates - 模板文件

**定位**：项目模板文件，用于快速创建标准化的配置和文档。

## 目录结构

```
.ai/L0#Execution/templates/
├── README.md
├── hook-template.json       钩子配置模板
├── spec-template.md         Spec 文档模板
└── workflow-template.yml    工作流配置模板
```

## 模板列表

> 暂无模板。请在项目中根据需要创建。

### 推荐模板

#### hook-template.json
- **用途**：创建新的 IDE 钩子配置
- **使用**：复制到 `.ai/L0#Execution/hooks/`，修改配置

#### spec-template.md
- **用途**：创建新的功能规格文档
- **使用**：复制到 `.ai/L0#Execution/specs/{feature-name}/`，填写内容

#### workflow-template.yml
- **用途**：创建新的 CI/CD 工作流
- **使用**：复制到 `.ai/L0#Execution/workflows/`，配置流程

## 使用方法

### 创建新钩子
```bash
# 1. 复制模板
cp .ai/L0#Execution/templates/hook-template.json .ai/L0#Execution/hooks/my-new-hook.json

# 2. 编辑配置
vim .ai/L0#Execution/hooks/my-new-hook.json

# 3. 映射到 Kiro
./gogogo.sh 8a
```

### 创建新 Spec
```bash
# 1. 创建目录
mkdir -p .ai/L0#Execution/specs/backlog/my-feature

# 2. 复制模板
cp .ai/L0#Execution/templates/spec-template.md .ai/L0#Execution/specs/backlog/my-feature/00.spec-01.requirements.md

# 3. 编写需求
vim .ai/L0#Execution/specs/backlog/my-feature/00.spec-01.requirements.md
```

### 创建新工作流
```bash
# 1. 复制模板
cp .ai/L0#Execution/templates/workflow-template.yml .ai/L0#Execution/workflows/github/my-workflow.yml

# 2. 配置流程
vim .ai/L0#Execution/workflows/github/my-workflow.yml
```

## 模板维护

### 更新模板
1. 根据实际使用经验优化模板
2. 添加新的模板类型
3. 保持模板简洁实用

### 模板规范
- **命名**：`{类型}-template.{扩展名}`
- **注释**：包含详细的使用说明
- **示例**：提供典型的配置示例
- **版本**：在模板中标注版本号

## 注意事项

1. **模板是起点**：复制后根据实际需求修改
2. **保持更新**：定期根据最佳实践更新模板
3. **文档完整**：模板中包含足够的注释和说明
4. **版本管理**：重大变更时更新版本号

---

**最后更新**：2026-04-16
