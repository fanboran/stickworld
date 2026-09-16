# town_life：小镇生活——村民职业与劳作循环

> 「每个火柴人都在真实生活」的职业层：职业档案、spawn 配比分配、工位寻位、劳作节律、职业着装。
> 本模块是纯配置与契约层——静态无状态、不进场景树，全部实现为静态函数。
> 愿景锚点：[docs/设计/系统/12-小镇生活与美术.md](docs/设计/系统/12-小镇生活与美术.md)。

---

## 目录结构

```
modules/town_life/
├── api.gd                       # 对外契约（TownLifeAPI）：全部 static 转发，外部禁止 preload 内部脚本
└── scripts/
    └── profession_registry.gd   # 职业注册表：档案读取、强制/配比分配、工位寻位、节律判定、着装
```

- 职业档案配置：`config/town_life/professions.tres`（字段 id / name_zh / work_site_def / product / produce_amount / consume_res / consume_amount / cycle / tool / quota，数值口径见类头）。

---

## 对外契约

- `assign_village_jobs(entities)`：村庄批量配比分配（各职业 ≤ min(quota, 工位容量)，配额满待业）——world 侧 spawn 是唯一正片调用点；`assign_village_job`（强制轮转）仅测试/调试用。
- `get_work_site(entity, work_site_def)`：工位寻位——building 组真槽位优先（def_id 匹配 + 运营中 + 最近槽位），无匹配建筑降级占位工位表；返回 pos 的 y 恒为 NAN（调用方按实体地面线补齐）。
- `is_work_time()`：劳作节律，7~19 时在岗（提案/待定），hour 参数可注入。
- `apply_profession_appearance(entity, id)`：读档回填重挂装具——存档只存职业 id，工具不入档。
- 职业状态协议（弱类型，实体侧零依赖本模块）：实体 `set_profession(id)` / `get_profession()`（空串 = 待业）+ `is_villager` 标志；征用离岗走 `set_profession("")`。

---

## 职责边界

- 本模块管：职业语义——档案、分配、工位寻位、节律、着装。
- `modules/world/` 管：村民生成落图与分配调用（modules/world/scripts/setup/initial_content.gd）、存档随档与回填（modules/world/scripts/setup/save_handler.gd）。
- `modules/units/` 管：行为执行——BehaviorHarvest 经本契约寻位与判节律（modules/units/scripts/ai/behavior_harvest.gd），待业村民 wander。
- 建筑侧走鸭子协议（get("def_id") / is_operational / get_work_slot_positions），不依赖 building_gen 类型，测试桩可注入。

---

## 扩展指引

- 加新职业：在 `config/town_life/professions.tres` 加档案行；绑定建筑的工位职业需目标建筑带 WorkSlots 槽位，A 线场景未到位时自动落占位工位表。
- 改产出/消耗/节拍数值：全部集中在 professions.tres 档案行，代码不写死。
