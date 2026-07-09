# stick-world AI 工作流指南

> **适用对象**：所有参与本项目的 AI Coding Agent（WorkBuddy、Cursor、Claude 等）
> **阅读顺序**：先读本文件，再读 `.trae/rules/rule.md`（核心规则文件，AI 每次加载）

---

## 一、项目 AI 协作概述

本项目（stick-world）采用 **Vibe Coding + AI 深度协同** 的开发模式。

### 核心分工

| 角色 | 职责 |
|------|------|
| **AI — 图书管理员** | 整理、归档、结构化所有项目信息 |
| **AI — 抄写员** | 将用户混乱记录转化为规范文档 |
| **AI — 执行程序员** | 按 rule.md 规范生成代码、测试、提交 |
| **AI — 决策助手** | 基于已有文档提供建议，无文档依据则告知用户自行决策 |
| **人类** | 所有游戏设计决策的最终拍板人 |

### 关键约定

- **GDD 是唯一设计真相源**：`docs/design/gdd.md`，所有游戏系统设计以此为准
- **AI 不做设计决策**：未确定处标注 `[待补充]`，告知用户决策，不自行发明
- **架构规范参考**：`.workbuddy/rules/rule.md`，这是核心规则文件

---

## 二、文件目录速查

```
F:\VSCode\game-2\
├── .workbuddy/
│   ├── rules/rule.md         # ⭐ 核心 AI 规则（架构 + Git 工作流 + 提交规范）
│   └── memory/               # WorkBuddy 工作日志
├── docs/                     # 项目文档（开源级多层结构）
│   ├── README.md             # 项目总览与导航
│   ├── CHANGELOG.md          # 变更日志
│   ├── CONTRIBUTING.md       # 贡献指南
│   ├── design/               # 游戏设计
│   │   ├── gdd.md            # ⭐ 游戏设计真相源（唯一）
│   │   ├── design-pillars.md # 设计支柱
│   │   ├── core-loop.md      # 核心玩法循环
│   │   ├── world-building.md # 世界观设定
│   │   ├── phasing-system.md # 阶段演进
│   │   ├── ui-ux.md          # UI/UX 设计
│   │   ├── mechanics/        # 子系统规格
│   │   └── balance/          # 平衡性数据
│   ├── technical/            # 技术文档
│   ├── business/             # 商业分析
│   └── project/              # 项目管理
├── tools/
│   └── vector_db/            # ChromaDB 错误知识库
│       ├── errors.json       # 错误数据源（提交到 Git）
│       ├── manage.py         # 统一管理 CLI（主入口）
│       ├── rebuild.py        # 重建向量库
│       ├── store.py          # 存储错误
│       ├── query.py          # 语义搜索
│       └── requirements.txt  # 依赖
└── stick-world/              # Godot 项目根（res://）
    ├── core/                 # 核心系统（高度稳定）
    ├── modules/              # 游戏功能模块
    ├── assets/               # 全局共享资源
    ├── addons/               # 第三方插件
    ├── prototypes/           # 原型区
    ├── tests/                # GdUnit4 测试
    └── project.godot
```

---

## 三、开发任务标准流程

每次 AI 执行开发任务的步骤：

```
1. 确认当前 dev 分支（询问用户）
2. 向量库语义搜索，检查是否有相关历史错误
3. 创建功能分支：git checkout -b agent/xxx <dev分支>
4. 编写功能代码 + GdUnit4 测试
5. 提交（原子化，用中文）：git commit -m "feat(模块): 描述"
6. 推送：git push -u origin agent/xxx
7. 合并回 dev 分支，删除 agent 分支
```

---

## 四、向量错误知识库使用

### 初始化（首次使用）

```bash
cd F:\VSCode\game-2
pip install -r tools/vector_db/requirements.txt
python tools/vector_db/manage.py rebuild
```

### 编码前查询历史错误

```bash
python tools/vector_db/manage.py query "当前任务的关键描述" --limit 3
```

### 存储新错误（排查超过 2 次未解决时）

```bash
python tools/vector_db/manage.py store \
  --symptom "发生了什么" \
  --root-cause "为什么发生" \
  --fix "怎么修复" \
  --type logic \
  --module godot-engine \
  --tags "标签1,标签2"
```

**错误类型（--type）**：

| 类型 | 说明 |
|------|------|
| `compilation` | 编译错误 |
| `runtime` | 运行时错误 |
| `logic` | 逻辑错误 |
| `ci` | CI/CD 问题 |
| `test` | 测试失败 |
| `configuration` | 配置问题 |
| `engine` | 引擎特有问题 |

**模块（--module）建议值**：
`godot-engine` / `gdscript` / `combat` / `world_map` / `city_builder` / `org` / `tech` / `logistics` / `resource` / `core` / `general`

### 查看统计

```bash
python tools/vector_db/manage.py stats
python tools/vector_db/manage.py list
python tools/vector_db/manage.py list --type logic --search "信号"
```

---

## 五、提交信息规范

格式：`类型(模块): 描述`

| 类型 | 使用场景 |
|------|---------|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `refactor` | 重构（不改变功能） |
| `test` | 添加/修改测试 |
| `docs` | 文档变更 |
| `chore` | 构建/工具/依赖变更 |

示例：
```
feat(combat): 实现基础自动战斗单位AI
fix(org): 修复组织架构树节点层级溢出
test(core): 为 event_bus 添加单元测试
docs(ai): 更新AI工作流指南
```

---

## 六、架构红线（禁止行为）

1. **禁止修改 `core/`**，除非获得明确允许
2. **禁止跨模块直接引用内部节点**（必须通过 `api.gd` 或 `event_bus`）
3. **禁止在不带测试的情况下提交功能代码**
4. **禁止自行发明游戏设计内容**（凡 GDD 未写明的，标 `[待补充]`）
5. **禁止一次提交包含多个独立功能**（保持原子化）

---

## 七、文档维护约定

- **GDD 有新决策** → 更新 `docs/design/gdd.md`
- **架构有新问题/改进项** → 追加到 `docs/project/todo.md`（按 P1/P2/P3 优先级）
- **完成一项架构改进** → 从 `docs/project/todo.md` 中删除对应条目
- **每次会话结束** → WorkBuddy 自动追加日志到 `.workbuddy/memory/YYYY-MM-DD.md`
