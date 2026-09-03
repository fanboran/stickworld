# Excel 数据管线实装 — Agent 启动提示词

> 分 2 轮。每轮内 Agent 可并行启动。
> 所有 Agent 的上下文都是独立的——复制→粘贴→发送。
> 完成后跑 `python tools/export_excel.py` 验证管线。

---

## 第 1 轮：管线基础设施 + Excel 模板（4 Agent 并行）

### Agent E1：编写导出脚本

```
你是 stick-world 项目的 Python 开发者。

【任务】
创建 tools/export_excel.py —— 一个把 config/excel/*.xlsx 导出为 Godot .tres 文件的脚本。

【功能需求】
1. 扫描 config/excel/ 下所有 .xlsx 文件
2. 对每个文件的每个 Sheet：
   - 第 1 行是英文字段名（作为 .tres 的键）
   - 第 2 行是中文字段说明（跳过）
   - 第 3 行起是数据
3. 每个 Sheet 生成一个 Godot Resource (.tres) 文件到 config/ 对应子目录
4. 支持以下数据类型的自动检测和正确写入：
   - int, float → 直接写入
   - bool → true/false
   - string → 引号包裹
   - Array → Godot 数组格式 [val1, val2, ...]
   - Dict → Godot 字典格式 {"key": val}
   - 图片列 → 提取到 assets/ 对应目录，列值变为资源路径字符串
5. 内置验证：
   - id 列不可重复
   - 必填列不能为空（用*标记的列名，如 id*）
   - 引用完整性检查（如 weapon_id 指向的武器必须存在于 weapons sheet）
6. 命令行用法：
   python tools/export_excel.py          # 导出所有
   python tools/export_excel.py --dry-run  # 只校验不导出

【输出格式示例】
输入: config/excel/单位数据.xlsx → stickmen sheet → 3 行数据
输出: config/units/stickmen.tres（一个包含 Array[Resource] 的 Resource 文件）

【依赖】
- openpyxl（读 .xlsx）
- 标准库 json, os, sys, re

【约束】
- 只创建 tools/export_excel.py 和更新 tools/requirements.txt（加 openpyxl）
- 代码用中文注释
- 错误时有清晰的报错信息（哪张表、哪行、什么字段、什么错误）
- 支持 col_name* 格式的必填列检查
- 图片提取功能用 openpyxl 的图片 API（先实现结构，图片提取可作为可选步骤）
```

---

### Agent E2：创建 Excel 单位数据模板

```
你是 stick-world 项目的策划数据设计师。

【任务】
创建 config/excel/单位数据.xlsx，包含以下 Sheet：

### Sheet 1: stickmen（火柴人种族/变体）
字段（第1行英文，第2行中文说明）：
id* | name_zh | race | variant | base_hp | base_attack | base_defense | base_speed | base_stamina | asphalt_cost | icon_path | description
（每个字段在第2行写中文说明，第3行起留空或填示例数据）
race 可选值：plain / volcano / source / desert / ocean / forest / ice
variant 可选值：normal / giant / long_arm / centaur / winged / multi_head

### Sheet 2: weapons（武器）
id* | name_zh | type | attack_mult | speed_mult | range_bonus | armor_penetration | asphalt_cost | weight | icon_path
type 可选值：sword / spear / bow / crossbow / staff / bare_hand

### Sheet 3: armors（盔甲）
id* | name_zh | type | damage_reduction | speed_penalty | weight | asphalt_cost | icon_path
type 可选值：cloth / leather / chain / plate / magic_shield

【约束】
- 用 openpyxl 库创建 .xlsx 文件。如果 openpyxl 不可用，创建一个 .md 文件描述表格结构，并附上示例 CSV 作为模板
- 第1行：英文字段名
- 第2行：中文字段说明
- 第3行起：至少填 1-2 行示例数据（数值用占位值如 100 即可）
- 每个 Sheet 设置列宽适当（openpyxl 的 column_dimensions）
- 第1行加粗 + 灰色背景（openpyxl 的 Font + PatternFill）
```

---

### Agent E3：创建 Excel 资源/建筑/平衡模板

```
你是 stick-world 项目的策划数据设计师。

【任务】
创建 config/excel/ 下的资源、建筑、平衡三张表（可以分开存三个 .xlsx，也可以放一个文件的不同 Sheet）。

### 表 A: 资源数据.xlsx
Sheet: resources
id* | name_zh | category | base_price | weight_per_unit | perishable | icon_path
category 可选值：basic / processed / strategic / luxury
perishable 是 bool (true/false)
至少填 5 行示例：食物、木材、石料、金属矿、黑色沥青

### 表 B: 建筑数据.xlsx
Sheet: buildings
id* | name_zh | type | tier | build_time | build_cost_food | build_cost_wood | build_cost_stone | build_cost_metal | max_hp | workers_required | unlocked_by_tech | description
type 可选值：house / farm / workshop / mine / barracks / academy / market / warehouse / wonder
至少填 3 行示例

### 表 C: 平衡变量.xlsx
Sheet: variables
id* | category | value | min | max | step | description
category: combat / economy / tech / org / expansion / logistics / population / global
所有 value 用占位值（如 100, 0.5 等）
至少填 10 行覆盖所有 category

【约束】
- 同 Agent E2 的格式规范（第1行英文、第2行中文、第3行起数据、加粗+灰色背景表头）
- 如果 openpyxl 不可用，创建 .md + .csv 替代
```

---

### Agent E4：创建 Excel 编制预设/科技树模板

```
你是 stick-world 项目的策划数据设计师。

【任务】
创建 config/excel/ 下的科技树和编制预设表。

### 表 A: 编制预设.xlsx
Sheet: presets
id* | name_zh | tag | preset_data_json
tag 可选值：military / research / engineering / administration / commerce
preset_data_json 列：一个 JSON 字符串描述该预设的层级结构（如 {"tiers":[{"name":"师","children":[{"name":"团","subdivisions":3}...]}]}）
至少填 2 行：标准军事编制、科学院架构

### 表 B: 科技树.xlsx
Sheet: techs
id* | name_zh | tier | category | prerequisites | research_cost | unlocks
tier: 1-5
category: military / economy / science / administration
prerequisites: 逗号分隔的 tech_id（如 "tech_stone_tools,tech_fire"）
unlocks: JSON 数组描述解锁内容（如 ["warrior","spear","barracks"]）
至少填 5 行从 tier 1 到 tier 3

【约束】
- 同 Agent E2 的格式规范
- preset_data_json 和 unlocks 列写完整 JSON 字符串（单行，不含换行）
- prerequisites 为空时填 ""（不是留空）
```

---

## 第 2 轮：文档 + 配置整合（3 Agent 并行）

### Agent E5：编写 Excel 管线使用说明书

```
你是 stick-world 项目的技术文档撰写者。

【任务】
创建 docs/技术/excel-pipeline.md —— Excel 数据管线完整使用说明书。

【内容大纲】
1. 概述
   - 什么是 Excel 驱动
   - 工作流：改 Excel → 跑脚本 → 游戏自动读
   
2. Excel 表格结构
   - config/excel/ 目录下每张表的用途
   - Sheet 格式规范（第1行字段名、第2行说明、第3行起数据）
   - 字段命名规范（id* 表示必填、英文蛇形命名）
   - 数据类型（int, float, bool, string, Array, Dict, 图片）

3. 导出脚本使用
   - 安装依赖：pip install openpyxl
   - 运行：python tools/export_excel.py
   - 只看不导出：python tools/export_excel.py --dry-run
   - 错误信息解读

4. BalanceConfig 对接
   - 导出后的 .tres 在 config/ 目录
   - 游戏通过 BalanceConfig.get_var("combat.unit_base_hp") 读取
   - 变量路径对应 Excel 的 [文件名].[Sheet名].[id].[字段名]

5. 添加新数据类型
   - 新建 .xlsx 文件 → 在 export_excel.py 中注册 → 重新导出

6. Mod 支持
   - 提供空白模板 config/excel/_template.xlsx
   - Mod 作者填写后运行独立导出脚本
   - 游戏加载 mod 数据的方式

7. 常见问题
   - Excel 里改了数据但游戏没变化 → 忘了跑导出脚本
   - 导出报错"重复 id" → 检查 Sheet 中的 id 列
   - 图片无法导出 → 检查图片是否嵌入到单元格而非链接

【约束】
- 用中文写
- 不要假设读者有编程背景，前两段写给纯策划看
- 给每个步骤配具体示例（不要空洞的"请执行脚本"）
```

---

### Agent E6：更新 BalanceConfig 对接导出管线

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md。

【必须先读】
core/autoload/balance_config.gd
docs/技术/架构/自动加载依赖.md（看 BalanceConfig 部分）

【任务】
更新 balance_config.gd，使其与 Excel 导出管线对接：

1. 修改 reload() 方法：
   - 扫描 config/ 目录下的所有 .tres 文件（包括子目录）
   - 加载每个 .tres
   - 将数据合并到 data Dictionary 中
   - 合并规则：路径 = 文件名/Sheet名（如 config/units/stickmen.tres → 路径 "units.stickmen"）

2. 修改 get_value(path: String) -> Variant：
   - 支持点号路径：如 "units.stickmen.warrior.base_hp"
   - 如果路径不存在，返回 null 并打印警告

3. 添加 get_all_of_type(type_path: String) -> Array：
   - 如 get_all_of_type("units.stickmen") 返回所有火柴人数据的数组

4. 添加 reload_single(file_path: String)：
   - 热重载单个 .tres 文件（用于仅改了某张 Excel 时）

5. 注释中说明数据来源是 Excel 导出管线

【约束】
- 只改 balance_config.gd
- 保持现有接口向后兼容
- 不依赖任何具体的 Excel 格式（只读 .tres）
- 加载失败时清晰报错路径
```

---

### Agent E7：更新 rule.md 和文档索引

```
你是 stick-world 项目的文档维护者。

【任务】
更新以下文件中对数据配置的引用：

1. .trae/rules/rule.md 的"项目文档导航"表：
   新增一行：| 游戏数据表 | `config/excel/` 目录 + `docs/技术/excel-pipeline.md` |

2. docs/README.md 的文档导航表：
   新增一行：| Excel 数据管线 | `technical/excel-pipeline.md` |

3. docs/技术/架构/平衡框架.md：
   在开头加一段：变量来源已迁移到 Excel 管线，原始 .xlsx 在 config/excel/，导出目标为 config/*.tres，详见 excel-pipeline.md

4. docs/技术/架构/agent-prompts.md：
   在顶部加注释：数据表已迁移到 Excel 管线，不再手动写 .tres。数据 Agent 应该改 Excel 而非直接改 .tres。

【约束】
- 只做文档更新，不写代码
- 每次改动后写 CHANGELOG
```

---

## 验证步骤

全部完成后：
```
pip install openpyxl
python tools/export_excel.py --dry-run     # 先校验
python tools/export_excel.py               # 正式导出
```

如果输出一堆 "✅ xxx → config/xxx/xxx.tres" 则管线跑通。
