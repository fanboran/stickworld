# core：核心层（L0）——全局单例、实体状态与抽象服务

> core/ 是依赖分层最底层：被全部模块依赖，不依赖任何模块（跨域枚举/状态在信号参数里以 int/String 广播，避免反向依赖模块类）。
> - `autoload/`：全局单例（事件总线 / 世界状态 / 用户设置 / 时间流速 / 平衡数据 / 存档）
> - `constants/`：世界空间 z 序常量
> - `entities/`：实体状态快照（RefCounted）+ WorldState 存档的字段级序列化
> - `services/`：音频抽象服务（AudioManager / MusicDirector）
>
> Autoload 依赖关系与加载顺序分析见 [docs/技术/架构/自动加载依赖.md](../../docs/技术/架构/自动加载依赖.md)；
> EventBus 信号分组全表见 [docs/技术/架构/系统交互与EventBus.md](../../docs/技术/架构/系统交互与EventBus.md)；
> 存储分层全景见 [docs/技术/架构/数据流全景.md](../../docs/技术/架构/数据流全景.md)。

---

## Autoload 单例

注册清单与顺序以 `project.godot` 的 `[autoload]` 段为准（下表即注册序）：

| # | 单例 | 脚本 | 职责与关键契约 |
|---|------|------|----------------|
| 1 | `EventBus` | `core/autoload/event_bus.gd` | 全局事件总线，模块间解耦通信的广播通道。信号按域分组声明（生命周期/战斗/编队/指挥链/旅行/领地/UI/室内/调试）。约定：只声明已实际接线的信号，实现新系统时按当时契约重新声明、不预先占位；资源/科技/组织/建筑等领域信号由对应模块 `api.gd` 自建，EventBus 不重复声明。 |
| 2 | `WorldState` | `core/autoload/world_state.gd` | 运行时世界状态中心。生产字段：`game_time`（EnvironmentSystem 推进）、`run_seed`、`visited_settlements`（聚落到访表，快速旅行判定的数据源）、`territories`（领地状态）、步行旅行队列（`walk_legs` 等，瞬态不进存档）。六大实体容器（stickmen/organizations/regions/battles/projects/supply_chains）当前为冻结预留（零调用未接线）。存档契约：订阅 `EventBus.game_saving/game_loaded`，快照直写 SQLite `world_state` 表（旧档回退 `legacy_modules`）。 |
| 3 | `ConfigManager` | `core/autoload/config_manager.gd` | 用户设置持久化（`user://settings.cfg`，ConfigFile）。`get_value/set_value` 任意键读写即落盘并发 `config_changed`；音量通道 master/bgm/sfx 走 `volume_changed`（本类只管存储与信号，总线应用归 AudioManager，单一写者）；画面类设置启动时应用，headless 跳过。 |
| 4 | `TimeManager` | `core/autoload/time_manager.gd` | 时间流速总闸。硬暂停 = 翻转引擎 `SceneTree.paused`（PAUSABLE 世界子树整体冻结，零逐系统检查）；倍速 X1/X2/X4 经 `sim_delta(delta)` 取步长；战斗开始自动暂停（`game/auto_pause_battle`，默认开）；运行时强制物理 tick 30Hz（单一真相源在本类 `_ready`）。`game_paused/game_resumed` 仅作 UI 反应通道，不承担冻结。 |
| 5 | `BalanceConfig` | `core/autoload/balance_config.gd` | 平衡数据统一读取入口。扫描 `res://config/` 下全部 `.tres`（Excel 导出管线产物，BalanceResource 承载）装进点号路径表；`get_value("units.stickmen.<行id>.<字段>")` 逐级解析，`get_all_of_type` 取整表；`reload()` 全量热重载 / `reload_single()` 单文件重载，变更发 `EventBus.balance_changed`（信号本身尚无生产订户）。autoload 阶段即装载（早于 GameRoot 装配）。 |
| 6 | `AudioManager` | `core/services/audio_manager.gd` | BGM/SFX 播放与总线音量。通道音量（master/bgm/sfx）→ AudioServer 总线（缺总线自动创建并路由 Master，SFX 末端挂硬限幅器）；SFX 唯一入口 `play_event(事件名, 世界坐标)`，事件→资产表 `SFX_EVENTS` 与播放策略表 `SFX_POLICY` 同文件（加音效不动调用点）；音乐压限为具名请求集 `request_music_duck`（多请求取最深，互不覆盖）；失焦静音、天气循环播放器。 |
| 7 | `MusicDirector` | `core/services/music_director.gd` | 自适应音乐运行时状态机：调用方 `set_context` 报告情境，`_resolve_cue` 集中解析曲目（清单 `res://assets/audio/bgm/music_manifest.json`）；一 cue 多层同帧开播（纵向混音），tier 控强度，stinger 独立短句；暂停期 `PROCESS_MODE_ALWAYS` 只压限不中断。与 AudioManager 分工：本类管"放哪首、放几层、怎么切"，音量唯一消费方仍是 AudioManager。 |
| 8 | `SaveManager` | `core/autoload/save_manager.gd` | SQLite 存档：5 槽位存 `user://saves/save_<slot>.db`。模块接口 = 订阅 `EventBus.game_saving/game_loaded`，回调内经 `get_db()` 直写各自表（建表 SQL/schema 版本 `CURRENT_SCHEMA_VERSION` 在本文件；SQL 白名单纪律：表名列名常量、运行时值 `?` 绑定）；自动存档间隔读 `game/auto_save_interval_sec`；`boot_load_slot` 供主菜单「继续游戏」跨场景交接；读档有 30s LoadGuard 兜底关库。存储设计详见 [docs/技术/架构/存储架构设计.md](../../docs/技术/架构/存储架构设计.md) 与 `modules/README.md` §8。 |
| 9 | `DebugApi` | `modules/debug_gui/api.gd` | F3 调试覆盖层对外 API（实体在 modules/debug_gui，注册跟在 core 各单例之后）。 |

## 目录结构

```
core/
├── autoload/                      # 全局单例（上表 1–5、8）
│   ├── event_bus.gd               # EventBus：全局信号总线（分组表见 docs，勿在 README 重复展开）
│   ├── world_state.gd             # WorldState：运行时状态中心 + 存档快照读写
│   ├── config_manager.gd          # ConfigManager：用户设置（音量/显示/语言/自动存档间隔）
│   ├── time_manager.gd            # TimeManager：暂停/倍速 + 30Hz 物理 tick
│   ├── balance_config.gd          # BalanceConfig：config/ 平衡数据 + 热重载
│   └── save_manager.gd            # SaveManager：SQLite 多槽位存档
├── constants/
│   └── world_z.gd                 # WorldZ：世界空间 z 序常量（地面0/装饰1/建筑2/单位3/前景10 +
│                                  #   浮动指示物 交互提示20/进度条25/血条50）；
│                                  #   apply(map) 由 MapBase._ready 统一应用，场景文件不保存 z_index
├── entities/                      # 实体状态快照（RefCounted，WorldState 容器的元素类型）
│   ├── stickman_state.gd          # StickmanState（冻结预留，随 WorldState 容器未接线）
│   ├── organization_state.gd      # OrganizationState（同上）
│   ├── region_state.gd            # RegionState（id 为 int，容器按 str(id) 存键）（同上）
│   ├── battle_state.gd            # BattleState（同上）
│   ├── project_state.gd           # ProjectState（同上）
│   ├── supply_chain_state.gd      # SupplyChainState（同上）
│   └── world_state_serializer.gd  # WorldStateSerializer：WorldState 存档的字段级编解码（在役，
│                                  #   被 world_state.gd get_save_data/load_save_data 调用）
└── services/
    ├── audio_manager.gd           # AudioManager（上表 6）
    └── music_director.gd          # MusicDirector（上表 7）
```

## 依赖

- 无：core 是 L0，不依赖任何模块或基础设施层（模块级 `api.gd` 约定不适用于本层，对外即 autoload 单例名）。

## 开发注意事项

- **core 不反向依赖模块**：跨域信号参数一律用 int/String（如 `travel_mode`、领地状态码），枚举语义注释写清值序；WorldState `territories` 的字段规范与模块侧同形内联，两处必须同步改。
- **信号纪律**：信号名 snake_case；`@warning_ignore("unused_signal")` 对每条信号逐个标注（该注解只作用于下一条语句）；新信号实装订户后再声明。
- **SQL 纪律**：表名/列名定义为常量（无法参数化），运行时值一律 `query_with_bindings` 走 `?` 绑定，禁止字符串拼接。
- **暂停与 autoload**：自动加载单例不在 game_root/ui_root 两棵子树内，暂停期仍需工作的单例（SaveManager / TimeManager / MusicDirector）在各自 `_ready` 声明 `PROCESS_MODE_ALWAYS`。
- **新增全局单例**：改 `project.godot` `[autoload]` 段，并同步 [docs/技术/架构/自动加载依赖.md](../../docs/技术/架构/自动加载依赖.md) 的依赖分析。
