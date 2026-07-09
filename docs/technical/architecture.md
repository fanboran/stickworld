# 技术架构

> **基于 GDD 的工程分析，非设计决定。** 所有具体方案供创始人参考，最终选型由创始人决定。
> GDD 参见 [`../design/gdd.md`](../design/gdd.md)。

---

## 一、技术栈

| 项 | 方案 | 依据 |
|----|------|------|
| 引擎 | Godot 4.x | 创始人指定 |
| 脚本语言 | GDScript | Godot 原生 |
| 2D 渲染 | Node2D + Sprite2D + AnimatedSprite2D | 平面 2D 画风 |
| 动画 | AnimationPlayer + 骨骼动画（Skeleton2D） | 火柴人战斗动画 |
| 测试 | GdUnit4 | Godot 生态标准 |
| CI/CD | GitHub Actions | `godot --headless` |
| AI 开发 | Vibe Coding 模式 | 创始人偏好 |

---

## 二、项目结构

```
stick-world/                    # Godot 项目根（res://）
├── project.godot
├── core/                       # 核心系统（高度稳定，修改需批准）
│   ├── autoload/               # Godot Autoload 单例
│   │   ├── event_bus.gd        # 全局事件总线
│   │   ├── scene_manager.gd    # 场景切换管理
│   │   ├── config_manager.gd   # 配置管理
│   │   └── save_manager.gd     # 存档管理
│   └── utils/                  # 通用工具
├── modules/                    # 游戏功能模块
│   ├── combat/                 # 战斗系统
│   ├── economy/                # 经济系统
│   ├── organization/           # 组织架构
│   ├── technology/             # 科技系统
│   ├── expansion/              # 扩张/世界地图
│   ├── logistics/              # 物流运输
│   ├── construction/           # 建设系统
│   └── achievement/            # 成就系统
├── world/                      # 世界/地图/场景
│   ├── terrain/                # 地形系统
│   ├── units/                  # 单位（火柴人）
│   ├── buildings/              # 建筑
│   └── map/                    # 世界地图
├── ui/                         # UI 组件
│   ├── panels/                 # 各面板
│   ├── widgets/                # 可复用控件
│   └── themes/                 # 主题（按阶段切换）
├── assets/                     # 全局共享资源
├── prototypes/                 # 原型实验区
├── tests/                      # GdUnit4 测试
└── addons/                     # 第三方插件
```

---

## 三、场景与视图

基于 GDD 八层结构 + 五阶段演进：

| 视图/场景 | 主要使用阶段 | 说明 |
|-----------|-------------|------|
| 世界大地图 | 阶段 3-5 | 地块、国境、资源分布 |
| 城市建设/家园 | 阶段 2-3 | 定居点内部视图 |
| 2D 侧视角战场 | 阶段 1-4 | 战斗实演 |
| 组织架构面板 | 阶段 3-5 | 树状指挥链设计 |
| 科技/学院界面 | 阶段 2-5 | 教育体系管理 |
| 报表界面 | 阶段 4-5 | 魔方投影式数据总览 |
| 物流视图 | 阶段 3-5 | 运输网络地图 |

### 无缝切换方案

**推荐方案**：单场景多视图——所有视图放在一个 Scene，通过 show/hide + 相机位置/缩放切换。

- 真正的无缝：无加载画面
- LOD 系统管理不同距离的细节
- 相机缩放连续而非跳跃

---

## 四、数据存储

**推荐方案**（待创始人确认）：

| 数据类型 | 格式 | 用途 |
|----------|------|------|
| 静态配置 | Godot Resource (.tres) | 单位属性、建筑数据、科技树 |
| 存档 | JSON + FileAccess | 游戏进度 |
| 设置 | ConfigFile (.cfg) | 用户偏好 |
| UGC 分享 | JSON | 指挥链配置导出/导入 |

---

## 五、关键架构模式

### 5.1 事件总线（EventBus）

模块间通信通过全局事件总线，避免直接引用：

```gdscript
# 发送
EventBus.emit("battle_won", {"location": "north_pass", "casualties": 42})

# 接收
EventBus.on("battle_won", _on_battle_won)
```

### 5.2 模块 API

每个模块对外暴露 `api.gd`，内部节点不直接暴露：

```
modules/combat/
├── api.gd          # 对外接口
├── combat_system.gd
├── unit_ai.gd
└── internal/        # 内部实现
```

### 5.3 数据驱动

游戏配置脱离代码——用 Resource 文件驱动：

```gdscript
# res://data/units/warrior.tres
[resource]
unit_name = "战士"
hp = 100
attack = 15
```

---

## 六、无缝缩放架构

### LOD 系统

| LOD 级别 | 距离 | 模拟精度 | 渲染精度 |
|----------|------|----------|----------|
| LOD 0（最近） | 可见个体 | 完整 AI + 物理 | 全细节动画 |
| LOD 1 | 可见小队 | 简化 AI | 简化动画 |
| LOD 2 | 可见军团 | 抽象模拟 | 图标/色块 |
| LOD 3（最远） | 地图视图 | 纯数值 | 地图覆盖 |

### 过渡处理

- LOD 切换不是瞬时的——通过 blend 过渡
- 远离相机的单位状态由模拟引擎维护（不直接渲染）
- 相机靠近时，单位状态从模拟引擎"具体化"为可见实体

---

## 七、性能考量

| 挑战 | 方案 |
|------|------|
| 数千火柴人同时渲染 | LOD + 视锥剔除 |
| 实时战斗模拟 | 远离玩家的战斗用简化 AI |
| 多个战场并行 | 每个战场独立线程/帧分配 |
| 存档文件过大 | 增量存档 + 压缩 |

---

## 八、多人工作流（预留）

| 角色 | 职责 |
|------|------|
| 主程/架构 | 核心系统、战斗逻辑 |
| 配合程序 | UI、工具、数据配置 |
| 美术 | 火柴人素材、场景、UI 皮肤 |

Git + GitHub，Godot 标准 `.gitignore`。

---

*本文档随架构演进更新。*
