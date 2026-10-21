# Excel 数据管线冻结归档

Excel→tres 导出管线（`config/excel/*.xlsx` → `config/<域>/<sheet>.tres`）已废弃冻结。**`.tres` 是游戏数据的唯一真源**：改数据直接编辑 `config/**/*.tres`，不再经过 xlsx 中转。

## 本目录内容

- `export_excel.py`：原导出脚本（xlsx 解析 / 校验 / 生成 tres），仅作历史参考，不可再按原路径运行
- `requirements.txt`：其 Python 依赖（openpyxl）
- `*.xlsx`：原 12 张数据源表（平衡变量 / 资源数据 / 建筑数据 / 单位数据 / 制造 / 战斗战术 / 扩张数据 / 法律系统 / 法术科技 / 管理科技 / 编制预设 / 运输数据），冷数据保留，**内容不再与游戏数据同步**

## 口径

- 游戏运行时只读 `config/**/*.tres`（经 `BalanceConfig` 或各模块 catalog 直读），对 xlsx 零依赖。
- xlsx 与 tres 的行级数据在冻结时点已核对一致；此后 tres 侧的直改（如 `variables.tres`、`formations/presets.tres` 的新增列）不会回写 xlsx，xlsx 视为过期快照。
- `扩张数据.xlsx` 的 `factions` sheet 早已退役（政权真源 = `config/strategic_map/political_data.json`）；`编制预设.xlsx` 的 `presets` sheet 从未有导出映射，真源一直是 `config/formations/presets.tres`。
- 现行数据编辑工作流见 `docs/技术/教程/Excel数据管线.md`。
