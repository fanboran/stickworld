# 游戏数据表编辑（原 Excel 数据管线）

> **适用读者**：策划、Mod 作者、开发者

---

## 1. 现状口径：`.tres` 是唯一真源

游戏中所有数据表（单位属性、建筑参数、科技树、平衡变量等）的权威来源是 `config/` 下的 `.tres` 资源文件，**改数据 = 直接编辑 `.tres`**。曾有的 Excel→tres 导出管线已废弃冻结，冷数据归档于 `stick-world/tools/pipeline/archive/excel_pipeline/`（原 12 张 xlsx 源表与导出脚本 `export_excel.py`，内容不再与游戏数据同步，仅作历史参考）。

完整工作流：

```
直接修改 config/**/*.tres → 保存 → 重启游戏（或触发热加载）
```

不需要跑任何导出脚本。归档目录中的 xlsx 是过期快照，不要依据它改数据。

## 2. 数据表位置

| 数据域 | 真源文件 | 消费方 |
|--------|----------|--------|
| 平衡变量 | `config/balance/variables.tres` | `BalanceConfig` autoload |
| 资源定义 | `config/resources/resources.tres` | `BalanceConfig` / world_map |
| 建筑定义 | `config/buildings/buildings.tres` | `BuildingCatalog`（construction） |
| 单位/武器/防具 | `config/units/stickmen.tres` / `weapons.tres` / `armors.tres` | `BalanceConfig` |
| 制造配方 | `config/manufacturing/manufacturing.tres` | manufacturing |
| 战术档案 | `config/combat/tactics.tres` | combat |
| 文明差异/地区 | `config/expansion/civ_differences.tres` / `regions.tres` | expansion |
| 法律条目 | `config/law/law.tres` | law |
| 科技 | `config/tech/spell_techs.tres` / `admin_techs.tres` | tech |
| 组织编制预设 | `config/formations/presets.tres` | organization |
| 运输 | `config/logistics/roads.tres` / `vehicles.tres` / `carriers.tres` | logistics |

不在上表的 `config/ai/`、`config/town_life/` 等域同样以 `.tres` 为真源，本就未经 Excel 管线。

## 3. `.tres` 文件结构

数据表 `.tres` 基于 [balance_resource.gd](../../../stick-world/config/balance/balance_resource.gd) 类，每行数据是 `variables.data` 数组中的一个字典：

```
[resource]
script = ExtResource("1")
_meta = { "source_file": ..., "source_sheet": ... }   # 元数据（历史来源记录）
variables = { "data": [ { "id": "...", ... }, ... ] } # 数据行
```

编辑约定：

- 每行的 `id` 字段是唯一标识，新增行必须填且不得重复；`xxx_id` 字段指向另一张表的 `id`，引用前确认目标行存在。
- ** null 字段消毒**：GDScript 的 `String()/int()/bool()/float()` 构造不接受 null（运行时 `Nonexistent constructor` 崩）。留空的字段直接**不要写这个 key**，不要写 `"key": null`。装载侧统一走 `BalanceResource.sanitized_rows()`（会剥除值为 null 的字段），新装表路径必须用它，不要直接 `res.variables.get("data")` 取行（消毒先例见 `BalanceConfig._load_tres` 与 `BuildingCatalog.load_defs`）。
- 数组字段写 JSON 方括号 `[1, 2, 3]`，字典字段写 JSON 花括号 `{"key": "value"}`。
- 改完用文本编辑器检查一下 `.tres` 内容即可确认格式正确（Godot 加载失败会在启动时报错，可用 `tools/check_godot_errors.sh` 扫日志）。

## 4. 游戏内读取数据（BalanceConfig）

游戏通过 `BalanceConfig` 全局 Autoload 读数据，路径规则 `config/<域>/<名>.tres` → 类型路径 `"<域>.<名>"`：

```gdscript
# 读取单个值
var hp = BalanceConfig.get_value("combat.base_hp")

# 读取整张表（balance.variables.var_attack_base.value 等路径）
var attack = BalanceConfig.get_value("balance.variables.var_attack_base.value")
```

各模块 catalog（如 `BuildingCatalog`）按惯例直接 `load("res://config/.../*.tres")` 装表，新增数据域可参照先例。

> **注意**：`BalanceConfig` 的 `reload()` 热加载尚未实装，改 `.tres` 后需重启游戏生效。

## 5. 新增数据类型

1. 在 `config/` 对应域目录下新建 `.tres`（或直接在现有表的 `variables.data` 里加行）。
2. 新文件沿用 `balance_resource.gd` 基类与上面的结构约定。
3. 消费侧按需 `load()` 或经 `BalanceConfig` 读取；无需任何注册步骤。

## 6. Mod 支持（预留设计）

Mod 作者可将修改后的 `.tres` 放入 Mod 目录，游戏加载时覆盖基础数据。当前 Mod 系统未完全实现，过渡方式 = 直接替换 `config/` 下的 `.tres` 文件。
