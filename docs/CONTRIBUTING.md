# 贡献指南

## 开发环境

1. 安装 Godot 4.x（[godotengine.org](https://godotengine.org)）
2. 克隆仓库：`git clone <repo-url>`
3. 安装 GdUnit4 测试框架（Godot 内 AssetLib 搜索安装）
4. 安装 Python 3.10+（用于工具脚本和向量知识库）

## 分支策略

- `dev` — 主开发分支
- `agent/<feature>` — 功能分支（AI Agent 自动创建）
- `fix/<issue>` — 修复分支

**工作流**：
```
1. 从 dev 创建功能分支
2. 编写代码 + 测试
3. 原子化提交（一个功能一个 commit）
4. 推送并合并回 dev
```

## 代码规范

- 语言：GDScript
- 命名：snake_case（变量/函数），PascalCase（类）
- 信号命名：`something_happened`
- 所有公开函数须有 docstring
- 新增功能必须有对应的 GdUnit4 测试

## 提交信息格式

```
<type>(<scope>): <description>
```

类型：`feat` / `fix` / `refactor` / `test` / `docs` / `chore`

示例：
```
feat(combat): 实现基础自动战斗单位AI
fix(org): 修复组织架构树节点层级溢出
```

## 架构红线

以下内容**禁止**在未获明确许可的情况下修改：

1. `core/` 目录下的核心系统文件
2. `core/autoload/` 中的全局单例
3. 跨模块直接引用内部节点（必须通过 `api.gd` 或 `event_bus`）

## 测试要求

- 新功能必须有单元测试（GdUnit4）
- 修改核心系统前必须先跑全量测试
- 测试覆盖率目标：核心系统 > 80%

## 文档同步

- 修改游戏设计 → 更新 `docs/设计/游戏设计文档.md`
- 发现架构问题 → 追加到 `docs/项目/待办事项.md`
- 每次会话结束 → WorkBuddy 自动追加 `.workbuddy/memory/YYYY-MM-DD.md`

## 提问与沟通

- 设计问题 → 参考 `docs/设计/游戏设计文档.md`（GDD 是唯一真相源）
- 技术问题 → 参考 `docs/技术/技术架构.md`
- 未找到答案 → 询问项目创始人
