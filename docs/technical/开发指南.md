# 开发者指南

> 面向本项目的开发者（包括未来的室友/协作者）。

---

## 环境搭建

1. 安装 [Godot 4.x](https://godotengine.org)
2. 克隆仓库
3. 在 Godot 中打开 `stick-world/project.godot`
4. 通过 AssetLib 安装 GdUnit4
5. Python 3.10+（用于 `tools/` 脚本）

---

## 项目结构速查

```
stick-world/                     # Godot 项目
├── core/                        # 核心系统（修改需批准）
├── modules/                     # 功能模块
├── world/                       # 世界/地图/单位
├── ui/                          # UI 组件
├── tests/                       # 测试
└── prototypes/                  # 原型

docs/                            # 文档
├── design/                      # 游戏设计
├── technical/                   # 技术文档
├── business/                    # 商业分析
└── project/                     # 项目管理
```

---

## 开发工作流

1. 从 `dev` 创建功能分支：`git checkout -b agent/xxx dev`
2. 编写代码 + 测试（GdUnit4）
3. 原子化提交：`git commit -m "feat(模块): 描述"`
4. 推送合并回 `dev`

---

## 架构红线

- **禁止**修改 `core/` 目录（除非获批准）
- **禁止**跨模块直接引用内部节点（用 `api.gd` 或 `EventBus`）
- **禁止**无测试的功能代码提交
- **禁止**自行发明游戏设计（GDD 是唯一真相源）

---

## 代码风格

- `snake_case` 变量/函数，`PascalCase` 类
- 信号命名：`something_happened`
- 公开函数必须带 docstring
- 类文件头注释说明用途

---

## 提交规范

```
<type>(<scope>): <description>
```

type: `feat` / `fix` / `refactor` / `test` / `docs` / `chore`

---

## 向量错误知识库

编码前查询历史错误：
```bash
python tools/vector_db/manage.py query "关键词" --limit 3
```

存储新错误（排查 2 次以上未解决时）：
```bash
python tools/vector_db/manage.py store --symptom "现象" --root-cause "原因" --fix "方案"
```

---

## 常见问题

| 问题 | 解决 |
|------|------|
| EventBus 找不到 | 检查 `project.godot` Autoload 配置 |
| GdUnit4 报错 | 确认已安装到 `addons/gdUnit4/` |
| CI 失败 | 检查 GitHub Actions 中 Godot 路径 |
