# 数据流与存储方案

> 底层架构第三阶段：信息在各系统间的流动路径 + 数据持久化选型。

---

## 一、数据流全景

```
┌──────────────────────────────────────────────────────────────┐
│                        玩家输入                               │
│  (键盘/鼠标 → UI → SceneManager → 各系统)                     │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                    组织系统（核心枢纽）                         │
│                                                              │
│  玩家通过组织系统下达高层指令：                                 │
│  "虎贲师→攻占北方行省"  →  创建 MilitaryCampaign Project       │
│  "皇家科学院→研究火球术"  →  创建 Research Project             │
│  "帝国路桥司→修北方大道"  →  创建 Construction Project         │
└───────┬──────────────────┬──────────────────┬────────────────┘
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────┐      ┌───────────┐      ┌───────────┐
│ 战斗系统   │      │ 科技系统   │      │ 建设系统   │
│           │      │           │      │           │
│ Project→  │      │ Project→  │      │ Project→  │
│ Battle    │      │ Research  │      │ Build     │
└─────┬─────┘      └─────┬─────┘      └─────┬─────┘
      │                  │                  │
      │ 消耗/产出         │ 消耗/产出         │ 消耗/产出
      ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────────┐
│                      资源系统                                 │
│                                                              │
│  接收所有系统的资源消耗请求                                    │
│  通过价格信号自动调节生产                                      │
│  库存不足 → resource_not_enough 信号 → 相关系统处理            │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                      运输系统                                 │
│                                                              │
│  资源不瞬移——通过物流链路从产地流向消费地                       │
│  断供 → supply_line_cut 信号 → 前线战斗力下降                  │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                      扩张系统                                 │
│                                                              │
│  战斗结果 → 地块控制度变化 → territory_gained/lost 信号        │
│  新地块 → 新资源 → 新建造空间 → 新组织驻扎点                    │
└──────────────────────────────────────────────────────────────┘
```

---

## 二、核心数据流详解

### 2.1 命令下发流（玩家→组织→项目→执行）

```
玩家在组织面板选择"虎贲师" → 点击"进攻北方行省"
  → 组织系统创建 MilitaryCampaign Project
  → Project 分解为子 Project（师→团→营→连→排）
  → 每层 Project 分配给对应层级的 Organization
  → Organization 通过所属 Stickman 执行（或 L2+ 层级 AI 下达到子层）
  → 战斗系统检测敌对单位 → 创建 Battle 实例
  → 战斗进行中 → 实时发射 battle_* 信号
```

### 2.2 经济自动调节流（供需→价格→行为）

```
战争导致铁矿石需求↑
  → 资源系统检测需求-供给曲线变化
  → price_changed 信号（铁价上涨）
  → 商业组织检测价格信号 → 自动调整商队路线（"把铁运到价格高的地方"）
  → 民间采矿组织检测价格信号 → 增加铁矿石开采
  → 资源系统检测供给↑ → 价格回落
  → 循环自稳定
```

### 2.3 信息上报流（下层→上层）

```
L1 排长 AI 检测到前方有大量敌军
  → 根据 autonomy_level 决定：
    - HIGH: 自主决定撤退/求援
    - LOW: 上报 L2 连长等待指令
  → 上报通过 org_efficiency_changed 反映在组织效率指标中
  → 玩家在帝国概览看到"虎贲师·第三团·第二连·士气下降"
  → 缩放查看 → 发现问题 → 调整策略
```

---

## 三、数据存储方案

### 3.1 三层存储架构

| 层级 | 内容 | 格式 | 位置 |
|------|------|------|------|
| **静态配置** | 单位属性、建筑数据、科技树、地形、种族 | Godot Resource (.tres) | `stick-world/config/` |
| **运行时状态** | 所有实体的当前状态（见 `entities.md`） | 内存（Dictionary） | 运行时 |
| **存档** | 运行时状态的快照 | JSON | `user://saves/slot_N/` |

### 3.2 静态配置（.tres）

每个实体类型一个 Resource 文件：

```
config/
├── units/
│   ├── stickman_warrior.tres      # 战士基础属性
│   ├── stickman_mage.tres         # 法师
│   ├── stickman_giant.tres        # 巨人
│   └── ...
├── buildings/
│   ├── house.tres
│   ├── farm.tres
│   └── ...
├── tech_tree/
│   ├── tier_1.tres
│   └── ...
├── resources/
│   ├── food.tres
│   ├── black_pitch.tres
│   └── ...
├── organizations/
│   ├── preset_military.tres       # 军事编制预设模板
│   ├── preset_research.tres       # 科研机构预设模板
│   └── ...
├── regions/
│   └── world_map_regions.tres     # 地块定义
└── balance/
    └── variables.tres             # 全局平衡变量（可热加载）
```

### 3.3 运行时状态（内存）

代码中每个实体用一个 `RefCounted` 或 `Resource` 对象表示：

```gdscript
# 伪代码示例
class_name StickmanState extends RefCounted
var id: String
var name: String
var hp: float
# ... 所有属性

class_name WorldState extends RefCounted
var stickmen: Dictionary       # {id: StickmanState}
var organizations: Dictionary  # {id: OrganizationState}
var regions: Dictionary        # {id: RegionState}
var battles: Dictionary        # {id: BattleState}
var resources: Dictionary      # {id: ResourceState}
var current_time: float
```

运行时状态**不**分散在各模块中，而是集中在一个 `WorldState` 对象中（或通过 `SaveManager` 的模块注册机制分块管理）。

### 3.4 存档格式（JSON）

```json
{
  "version": "0.1.0",
  "timestamp": 1234567890,
  "play_time": 43200,
  "stickmen": {
    "unit_001": {"name": "张三", "race": "plain", "hp": 85, ...},
    ...
  },
  "organizations": {
    "org_001": {"name": "虎贲师", "tag": "military", "tier": 4, ...},
    ...
  },
  "regions": {...},
  "resources": {...},
  "technologies": [...],
  "active_projects": [...],
  "active_battles": [...],
  "supply_chains": [...]
}
```

- 每个模块实现 SaveManager 的 `get_save_data()` / `load_save_data()` 接口
- SaveManager 已完整实现此机制（见现有代码 `save_manager.gd`）
- 增量存档：大型存档考虑只存变动的部分（后期可优化，初期全量存）

### 3.5 大规模数据的性能策略

后期帝国 10000+ 火柴人的运行时处理：

| 距离玩家视口 | 模拟方式 |
|-------------|----------|
| 近（LOD 0） | 完整 AI + 完整渲染 + 每帧更新 |
| 中（LOD 1） | 简化 AI + 简化渲染 + 每 N 帧更新 |
| 远（LOD 2） | 抽象数值模拟 + 不渲染 + 每 M 帧批处理 |
| 极远（LOD 3） | 仅保留聚合统计数据，通过统计公式推算 |

**实例化策略**：当玩家缩放到某个远距离区域时，该区域的火柴人从 LOD 3 的"统计数字"**现场生成为具体实例**。特性（名字、性格、装备）在生成时随机分配——但存档中不存这些远距离单位的个体数据，只存聚合统计（人口数 + 种族比例 + 平均能力值）。

---

## 四、模块间通信规则

```
✅ 允许：模块 A → EventBus 信号 → 模块 B
✅ 允许：模块 A → api.gd → 模块 B（同步调用，少数场景）
❌ 禁止：模块 A 直接访问模块 B 的内部脚本
❌ 禁止：跨模块信号形成循环
```

### 同步调用 vs 异步事件

| 场景 | 方式 | 原因 |
|------|------|------|
| 查询地块资源 | 同步（api.gd） | 即时查询，不需要异步 |
| 战斗消耗资源 | 异步（EventBus） | 多接收方，解耦 |
| 科技解锁新单位 | 异步（EventBus） | 多系统需要响应 |
| 组织解散 | 异步（EventBus） | 级联影响多个系统 |

---

*下一阶段：模块 API 规范。*
