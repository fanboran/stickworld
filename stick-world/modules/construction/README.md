# construction：建造放置与建造项目推进

> 本模块负责建筑从选址到运营的全流程：
> - 选址校验与占格（placement/）
> - 建造项目状态机与派工推进（construction_project + work_crew_assigner）
> - 完工建筑注册表、升级/拆除/修理、SQLite 存读档（construction_manager + catalog/）
> - 建造菜单 UI 与选址条带预览（ui/）
>
> 建筑本体（场景/外观/Building 基类）归 [`modules/building_gen/`](../building_gen/README.md)，本模块经其 api 注册默认场景。
> 系统级设计见 [docs/设计/系统/03-定居点与建筑.md](docs/设计/系统/03-定居点与建筑.md)、[docs/技术/架构/场景与战斗/建筑与定居点.md](docs/技术/架构/场景与战斗/建筑与定居点.md)。

---

## 目录结构

```
modules/construction/
├── api.gd                                # 对外契约：开工/预置/派工查询/升级/拆除/修理/存读档 + 公共信号
├── scripts/
│   ├── construction_manager.gd           # 内部管理器（Node）：项目表 tick、建筑注册表、地图/资源系统注入点
│   ├── construction_project.gd           # 建造项目状态机 PLANNED→UNDER_CONSTRUCTION→OPERATIONAL/CANCELLED
│   ├── work_crew_assigner.gd             # 派工：工人池↔项目匹配；行为端查 get_worker_project 拿目标
│   ├── building_costs.gd                 # 建造成本提取与扣减（先全量检查、失败回滚），经注入的 ResourcesApi 执行
│   ├── build_progress_tracker.gd         # 双进度条跟踪器（项目↔指示器生命周期）
│   ├── build_progress_indicator.gd       # 工地头顶双进度条（材料/建造），挂 map.BuildMaskLayer
│   ├── catalog/
│   │   ├── building_catalog.gd           # 场景注册表 + config/buildings/buildings.tres 定义装载
│   │   └── building_persistence.gd       # buildings / construction_projects 两表 SQLite 存读档
│   └── placement/
│       ├── placement_system.gd           # 高层选址语义：try_place / find_nearest_free / release_area
│       └── placement_validator.gd        # 边界/尺寸校验（鸭子协议访问 grid，不依赖 world）
└── ui/
    ├── build_menu.gd + build_menu.tscn   # 建造菜单：建筑列表→选址模式→开工（EXPLORE 模式入口）
    └── placement_ghost.gd                # 选址条带预览（单节点 _draw 自绘）
```

---

## 对外契约

- 全部交互经 `api.gd`：开工 `start_construction_at(region_id, building_type, cell_x, ...)`、预置 `spawn_operational_building`、维护 `upgrade / demolish / repair_building`、存读档 `save_to_db / load_from_db`；查询与派工：`get_building_state / get_nearest_warehouse / get_nearest_project / register_worker / try_assign_worker / get_worker_project` 等。
- 公共信号 `building_started / building_completed / building_removed / building_upgraded / building_repaired` 由本 api 自建承担，EventBus 不重复声明。

---

## 依赖

- `modules/building_gen/`：Building 基类与建筑场景（building_catalog 经其 api 注册默认场景）。
- `modules/resources/`：ResourcesApi 运行时注入（成本扣减、清场回收）。
- 地图经 set_map 注入 + 鸭子协议（placement_grid / building_host / expand_map），不引用 world 内部脚本。
- 被依赖：`modules/units/`（StickmanEntity 注入本 api，行为端派工与交互探测按 工地>仓库>资源点）、`modules/world/`（SystemSetup 装配、初始建筑预置、demo_quest 监听 building_completed）。

---

## 扩展指引

- 新增可建造建筑：在 building_gen 侧补场景与 buildings.tres 定义行（见 [`../building_gen/README.md`](../building_gen/README.md)），本模块启动时自动注册进建造菜单。
- 新增存档字段：改 scripts/catalog/building_persistence.gd 的表列与恢复映射，入口仍走 api.gd 的 save/load。
