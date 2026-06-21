# AI 引导的项目快速启动流程

> 本文档是从 `rule.md` 附录中独立出来的，面向 AI Coding Agent 的 **项目快速启动引导流程**。
> 当你把本架构仓库的 `rule.md` + `rule_local.md` 复制到一个新的 Godot 项目后，
> AI 将按照本文档的清单和流程引导你完成项目初始化。

---

## 一、10 项项目引用清单

AI 在新项目中必须引导用户逐项补全以下信息：

| # | 项目 | 存储位置 | 示例值 |
|---|------|----------|--------|
| 1 | **项目名称** | `rule_local.md` → `PROJECT_NAME` | `Project Astra` |
| 2 | **项目类型** | `rule_local.md` → `PROJECT_TYPE` | `桌宠 / RPG / 3D射击` |
| 3 | **Godot 根目录名** | `rule_local.md` → `GODOT_PROJECT_DIR` | `transparent-pet` |
| 4 | **本地 Godot 路径** | `rule_local.md` → `GODOT_ENGINE_PATH` | `F:\SteamLibrary\steamapps\common\Godot Engine` |
| 5 | **目标平台** | `rule_local.md` → `TARGET_PLATFORMS` | `Windows / Web` |
| 6 | **主开发分支** | `rule_local.md` → `DEV_BRANCH` | `dev/fan` |
| 7 | **已存在模块** | `rule_local.md` → `EXISTING_MODULES` | `core/、modules/pet/` |
| 8 | **建议新增模块** | `rule_local.md` → `PLANNED_MODULES` | `modules/player/、modules/combat/、...` |
| 9 | **向量知识库** | `rule_local.md` → `VECTOR_DB_ENABLED` | `已启用 / 未启用` |
| 10 | **CI/CD 变量** | `.github/workflows/ci.yml` → `env:` 块 | `GODOT_VERSION`, `PROJECT_PATH`, `GAME_NAME` |

---

## 二、首次启动 Prompt 模板

当一个全新的 Godot 项目已经创建好、`rule.md` + `rule_local.md`（模板）已复制到 `.trae/rules/` 目录后，
向 AI 发送以下 Prompt：

```
我现在有一个全新的 Godot 项目，已经复制了 rule.md 和 rule_local.md 模板。
请按照 docs/ai_project_bootstrap.md 的流程，引导我填写项目特定信息，
并自动生成 rule_local.md 和更新 CI/CD 配置。

我的 Godot 引擎安装在 [你的 Godot 路径]，
项目根目录名是 [你的项目文件夹名]。
```

AI 收到此 Prompt 后应：
1. 要求你补充缺失的 #1-#10 项信息
2. 自动填充 `rule_local.md` 中的 `{{PLACEHOLDER}}`
3. 自动更新 `.github/workflows/ci.yml` 中的 `{{GODOT_PROJECT_DIR}}` 和 `{{GAME_NAME}}`
4. 确认 `project.godot` 中的 Autoload 配置（event_bus, scene_manager, config_manager, save_manager）

---

## 三、`rule_local.md` 自动生成模板

AI 应参考以下模板，根据用户提供的 10 项信息生成最终的 `rule_local.md`：

```markdown
---
alwaysApply: true
---

## 项目特定规则（本文件只记录"这一个项目"独有的信息）

> 通用规则、模块化架构、Git 工作流、命令行环境规范等跨项目可复用的内容，均记录在同目录下的 `rule.md` 中。两份文件均设置 `alwaysApply: true`，共同生效。

**项目身份：**
- 项目名称：**[由 #1 填充]**
- 项目类型：**[由 #2 填充]**
- Godot 根目录名：**[由 #3 填充]**
- 本地 Godot 调试路径：**[由 #4 填充]**

**开发环境：**
- 测试框架：**GdUnit4**
- 目标平台：**[由 #5 填充]**
- CI/CD 平台：**GitHub Actions**
- Git 主开发分支：**[由 #6 填充]**

**模块现状：**
- 已存在模块：[由 #7 填充]
- 建议新增模块：[由 #8 填充]

**可选增强：**
- 向量知识库 / 错误记忆：[由 #9 填充]

**本文件维护原则：**
- 只写"这个项目独有的信息"，不重复 rule.md 中已有的内容。
- 当项目新增模块、变更目标平台、切换 CI 工具时，**在本文件追加或修改对应条目**。
- 当 rule.md 有新版时（例如升级了模块化架构规范），**把新版文件复制过来覆盖即可**，本文件不受影响。
```

---

## 四、首次启动完整工作流

```
用户                     AI Agent
  │                        │
  ├─ 输入 Prompt 模板 ────→│
  │                        ├─ 解析已有 rule_local.md
  │                        ├─ 检查哪些 {{PLACEHOLDER}} 仍存在
  │                        │
  │←── 逐项询问缺失信息 ──┤
  │                        │
  ├─ 回答各项信息 ────────→│
  │                        ├─ 填充 rule_local.md
  │                        ├─ 填充 .github/workflows/ci.yml
  │                        │
  │←── 展示最终结果，请求确认 ─┤
  │                        │
  ├─ 确认 ────────────────→│
  │                        ├─ 提交更改
  │                        └─ 流程结束
```

---

## 五、常见缺引用诊断

AI 在新项目中遇到以下情况时，自动触发诊断：

| 症状 | 可能原因 | AI 应执行的操作 |
|------|----------|-----------------|
| 找不到 `EventBus` 单例 | `project.godot` 未配置 Autoload | 检查 `project.godot` → 引导用户添加 autoload 条目 |
| `GdUnit4` 找不到 | 未安装测试框架 | 引导用户安装 GdUnit4 到 `addons/gdUnit4/` |
| `godot --headless` 路径错误 | `rule_local.md` 中 Godot 路径不正确 | 检查路径是否存在 → 引导用户修正 |
| CI 配置变量未替换 | 仍存在 `{{GODOT_PROJECT_DIR}}` | 引导用户填写 CI 模板变量 |
| `tools/vector_db/` 未初始化 | 首次使用 ChromaDB | 引导用户执行 `pip install -r tools/vector_db/requirements.txt` |

---

## 六、架构升级工作流

当主架构仓库（`godot-game-architecture`）有更新时：

1. **拉取最新架构**：`git pull origin main`（在架构仓库中）
2. **复制到目标项目**：
   - 将 `.trae/rules/rule.md` 复制到目标项目的 `.trae/rules/rule.md`（覆盖）
   - 将 `.trae/rules/CI-DI.md` 复制覆盖
   - 将 `.trae/rules/issues.md` 复制覆盖
   - **不要覆盖** `rule_local.md`（它包含项目特定信息）
   - 如果 `core/autoload/` 有更新：选择性合并到目标项目
   - 如果 `tools/` 有更新：选择性复制
3. **检查兼容性**：运行 `godot --headless` 验证编译通过
4. **提交**：`feat(arch): 升级至架构 vX.Y.Z`

> **核心原则**：`rule.md` 是通用层，随时可以覆盖升级；`rule_local.md` 是项目层，永远不覆盖。
