# 数据表系统定案：Excel 管线废弃，`.tres` 唯一真源

- [x] **方案定案（创始人已拍板）**：Excel→tres 导出管线废弃。游戏数据唯一真源 = `config/**/*.tres`，改数据直接编辑 `.tres`；xlsx 源表与导出脚本冻结归档于 `stick-world/tools/pipeline/archive/excel_pipeline/`（冷数据保留不删除，内容不再与游戏数据同步）。现行工作流见 [Excel数据管线.md](../../技术/教程/Excel数据管线.md)。
- [x] **映射收尾随定案作废**：① `编制预设.xlsx` presets 补映射不作——`config/formations/presets.tres` 本就是真源（组织系统直读消费，tres 侧含 xlsx 没有的 tag 列）；② `法术科技/管理科技` 双表 `spell_techs.tres`/`admin_techs.tres` 已是唯一形态，无需导出链；③ `扩张数据.xlsx` 的 `factions` sheet 早已退役（政权真源 = `config/strategic_map/political_data.json`）。

## 冻结时点消费链核查证据

- 运行时零 xlsx 直读：全仓 `.gd`/`.cs`/`.tscn`/`.py` grep 仅命中 `.tres` 加载路径（`res://config/**/*.tres`）、`_meta` 记录字符串与注释，无任何代码读 xlsx。
- 数据完整性：17 个活跃 sheet 的行 id 与导出产物 `.tres` 全量对齐（openpyxl 只读解析 vs tres 正则比对），无"xlsx 有而 tres 缺失"的数据，废弃不丢数据。
- 已知漂移方向均为 tres 侧更新（如 `variables.tres`、`presets.tres` 的新增列），废弃 xlsx 不受影响。

## 执行落地

- `config/excel/` 12 张 xlsx + `tools/pipeline/export_excel.py` + `requirements.txt` → `tools/pipeline/archive/excel_pipeline/`（含归档 README）；`config/excel/` 目录随之消失。
- 文档改写：`Excel数据管线.md` 重写为 tres 直改工作流；`编辑器工具索引.md`、`CONTRIBUTING.md`、`docs/README.md`、`架构/README.md`、`平衡框架.md`、`武器装备与个人库存.md`、`建筑与聚落.md`、`运行时建筑资产清单.md`、`组织系统架构.md`、`UI/拓展性.md`、`04-科技系统.md`、`15-建筑功能规格.md`、`世界观设定.md`、`并行开发协调.md`（导出冻结令解除）、`待办/建筑系统总账.md` 共 15 处引用清理；`balance_config.gd` 头注释同步。

## 遗留（代码侧，非 Excel 管线范围）

- `config/tech/techs.tres` 旧手写表与 `spell_techs.tres`/`admin_techs.tres` 并存，待科技模块重建后归并接线消费。
