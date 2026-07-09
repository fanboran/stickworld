# Autoload 依赖图

> 底层架构第五阶段：6 个核心 Autoload 服务的依赖方向、初始化顺序、职责边界。

---

## 一、当前 Autoload 清单（来自 project.godot）

| 名称 | 脚本 | 类型 | 状态 |
|------|------|------|------|
| `EventBus` | `core/autoload/event_bus.gd` | 基础设施 | ✅ 完整 |
| `ConfigManager` | `core/autoload/config_manager.gd` | 基础设施 | ✅ 完整 |
| `SaveManager` | `core/autoload/save_manager.gd` | 基础设施 | ✅ 完整 |
| `SceneManager` | `core/autoload/scene_manager.gd` | 基础设施 | ✅ 完整 |
| `AudioManager` | `core/services/audio_manager.gd` | 服务 | ✅ 完整 |
| `_mcp_game_helper` | `addons/godot_ai/runtime/game_helper.gd` | 工具 | 第三方 |

---

## 二、新增 Autoload 建议

基于架构设计，建议新增以下 Autoload：

| 名称 | 职责 | 优先级 |
|------|------|--------|
| `WorldState` | 运行时世界状态集中管理（所有实体状态） | **高** |
| `TimeManager` | 游戏时间流速控制、自动暂停/减速逻辑 | **高** |
| `BalanceConfig` | 热加载平衡变量（从 config/balance/ 读取） | 中 |
| `InputManager` | 统一输入映射（待 project.godot 补 InputMap） | 中 |

### 2.1 WorldState

```gdscript
# core/autoload/world_state.gd
# 集中管理所有运行时实体状态

var stickmen: Dictionary = {}       # {id: StickmanState}
var organizations: Dictionary = {}   # {id: OrganizationState}
var regions: Dictionary = {}         # {id: RegionState}
var battles: Dictionary = {}         # {id: BattleState}
var projects: Dictionary = {}        # {id: ProjectState}
var supply_chains: Dictionary = {}   # {id: SupplyChainState}
var game_time: float = 0.0

func get_entity(entity_type: String, entity_id: String):
    # 统一查询入口
    pass

func register_module_save_data(module_name: String, get_save_fn: Callable, load_save_fn: Callable):
    # 与 SaveManager 协作
    pass
```

### 2.2 TimeManager

```gdscript
# core/autoload/time_manager.gd

enum Speed { PAUSED, X1, X2, X4 }

var current_speed: Speed = Speed.X1
var auto_pause_conditions: Array[String] = []   # ["battle_started", "commander_died", ...]
var auto_slow_on_possess: bool = true

func set_speed(speed: Speed):
    # 发射 game_paused / game_resumed 信号
    pass

func should_update(system_name: String) -> bool:
    # 各系统调用此方法判断当前帧是否需要更新
    pass
```

### 2.3 BalanceConfig

```gdscript
# core/autoload/balance_config.gd

# 从 config/balance/variables.tres 加载所有平衡变量
# 提供热加载：编辑 .tres 后无需重启游戏

var data: Dictionary = {}

func get_value(path: String):   # 如 "combat.base_hp"
    pass

func reload():
    pass
```

---

## 三、依赖图

```
                    ┌─────────────┐
                    │  EventBus   │  ← 零依赖，所有其他 Autoload 依赖它
                    └──────┬──────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ ConfigManager│  │ WorldState   │  │ TimeManager  │
│ (独立)        │  │ (依赖EventBus)│  │ (依赖EventBus)│
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                  │
       │          ┌──────┘                  │
       │          │                         │
       ▼          ▼                         │
┌──────────────┐                            │
│ AudioManager │ ← 依赖 ConfigManager       │
│              │   (读音量设置)              │
└──────────────┘                            │
                                            │
       ┌────────────────────────────────────┘
       │
       ▼
┌──────────────┐
│ SaveManager  │ ← 依赖 WorldState + EventBus
│              │   (存档时读 WorldState, 发射 game_saving/saved)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ SceneManager │ ← 依赖 SaveManager + EventBus
│              │   (场景切换, 发射 ui_switch_view)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│BalanceConfig │ ← 依赖 EventBus
│ (热加载)      │   (变量变更时发射 balance_changed)
└──────────────┘
```

### 循环依赖检查

**结论：无循环依赖。**

- EventBus → 零依赖 ✓
- ConfigManager → 零依赖 ✓
- WorldState → 仅依赖 EventBus ✓（EventBus 不依赖 WorldState）
- TimeManager → 仅依赖 EventBus ✓
- AudioManager → 依赖 ConfigManager ✓（ConfigManager 不依赖 AudioManager）
- SaveManager → 依赖 WorldState ✓（WorldState 不依赖 SaveManager）
- SceneManager → 依赖 SaveManager ✓
- BalanceConfig → 仅依赖 EventBus ✓

---

## 四、初始化顺序

Godot Autoload 按 `project.godot` 中声明的**自上而下顺序**初始化：

```ini
[autoload]

EventBus="*res://core/autoload/event_bus.gd"        # 1. 最先（零依赖）
WorldState="*res://core/autoload/world_state.gd"     # 2. （仅依赖 EventBus, 新增）
ConfigManager="*res://core/autoload/config_manager.gd" # 3.
TimeManager="*res://core/autoload/time_manager.gd"   # 4. （新增）
BalanceConfig="*res://core/autoload/balance_config.gd" # 5. （新增）
AudioManager="*res://core/services/audio_manager.gd"  # 6.
SaveManager="*res://core/autoload/save_manager.gd"    # 7.
SceneManager="*res://core/autoload/scene_manager.gd"  # 8.
```

**原则**：
1. 零依赖的先初始化（EventBus）
2. 数据层先于服务层（WorldState 先于 SaveManager）
3. 服务层最后（AudioManager、SceneManager）

---

## 五、职责边界

| Autoload | 负责 | 不负责 |
|----------|------|--------|
| EventBus | 信号注册、safe_emit | 不存储任何游戏状态 |
| WorldState | 所有实体状态的读写 | 不处理游戏逻辑（逻辑在各模块中） |
| ConfigManager | 用户设置的读写 | 不存游戏配置（游戏配置在 BalanceConfig） |
| TimeManager | 时间流速、暂停/恢复 | 不处理各系统的具体更新逻辑 |
| BalanceConfig | 平衡变量加载和热更新 | 不做平衡计算（计算在各模块中） |
| SaveManager | 存档读写、模块注册 | 不定义存档内容格式（各模块自行定义） |
| SceneManager | 场景/视图切换 | 不定义场景内容 |
| AudioManager | 音频播放 | 不定义何时播放（由各模块通过 EventBus 触发） |

---

*下一阶段：平衡性调优框架。*
