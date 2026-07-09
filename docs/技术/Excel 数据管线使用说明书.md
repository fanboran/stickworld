# Excel 数据管线使用说明书

> **适用读者**：策划、Mod 作者、开发者
>
> **前两节写给纯策划**——不需要懂代码，只要会用 Excel 就能改游戏数据。

---

## 1. 概述

### 什么是 Excel 驱动

在 stick-world 项目中，所有游戏数据（单位属性、建筑参数、科技树、平衡变量等）的**权威来源**不是代码，而是 Excel 表格。策划在 Excel 里填数据，跑一个脚本，数据就自动变成游戏能读的格式。程序员不需要在代码里硬编码数值，策划也不需要碰代码。

### 完整工作流

```
策划修改 Excel → 运行导出脚本 → 游戏自动读取新数据
```

举个例子：你想把"基础攻击力"从 10 改成 15。

1. 打开 `config/excel/平衡变量.xlsx`
2. 找到 `var_attack_base` 那一行，把 `value` 列从 `10` 改成 `15`
3. 保存，然后在终端运行 `python tools/export_excel.py`
4. 重新启动游戏（或触发热加载），攻击力就变成 15 了

不需要修改任何 `.gd` 脚本，不需要重新编译 Godot 项目。

---

## 2. Excel 表格结构

### 2.1 目录概览

所有 Excel 文件放在 `config/excel/` 目录下：

| 文件名 | 用途 | 对应游戏内容 |
|--------|------|-------------|
| `平衡变量.xlsx` | 全局平衡变量 | 攻击力、税率、研究速度等可调参数 |
| `资源数据.xlsx` | 资源定义 | 食物、木材、石料、铁锭等 |
| `建筑数据.xlsx` | 建筑定义 | 民居、农场、工坊、兵营等 |
| `单位数据.xlsx` | 单位定义 | 兵种、武器、防具 |
| `科技树.xlsx` | 科技树 | 科技层级、前置条件、解锁内容 |
| `编制预设.xlsx` | 组织预设 | 军事编制、科学院架构 |

### 2.2 Sheet 格式规范

每张表（Sheet）遵循统一的格式：

```
第 1 行：英文列名（字段名）      ← 脚本用，不要改
第 2 行：中文说明                ← 给人看的，脚本会跳过
第 3 行起：数据行                ← 你填数据的地方
```

**示例——平衡变量.xlsx 的 variables sheet：**

| id | category | value | min | max | step | description |
|----|----------|-------|-----|-----|------|-------------|
| ID | 类别 | 当前值 | 最小值 | 最大值 | 步长 | 描述 |
| `var_attack_base` | combat | 10 | 1 | 100 | 1 | 基础攻击力 |
| `var_defense_base` | combat | 5 | 1 | 100 | 1 | 基础防御力 |
| ... | ... | ... | ... | ... | ... | ... |

**关键规则：**
- 第 1 行不能有空列（中间跳过的列会被忽略）
- 第 2 行可以随便写，也可以留空，但不能删掉整行
- 数据从第 3 行开始，空行会自动跳过
- 第 1 行和第 2 行都有灰色背景、加粗、居中，数据行有边框，方便区分

### 2.3 字段命名规范

| 规则 | 说明 | 示例 |
|------|------|------|
| 英文蛇形命名 | 小写字母 + 下划线 | `base_price`、`max_hp` |
| `id` 列 | 每行数据的唯一标识，必填 | `res_food`、`bld_house` |
| `id*` 表示必填 | 列名末尾加 `*` 表示该列不能为空 | `id*`（但 `id` 列即使不加 `*` 也会被检查） |
| `xxx_id` 表示引用 | 指向另一张表的 `id` | `unlocked_by_tech_id` 指向科技表的某个 id |

### 2.4 数据类型

脚本会自动识别单元格里的数据类型，你不需要手动标注：

| 你填的内容 | 自动识别为 | 说明 |
|-----------|-----------|------|
| `10` | int（整数） | 纯数字，没有小数点 |
| `3.14` | float（浮点数） | 有小数点的数字 |
| `true` / `false` | bool（布尔值） | 不区分大小写 |
| `食物` | string（字符串） | 普通文本 |
| `[1, 2, 3]` | Array（数组） | 用 JSON 方括号格式 |
| `{"key": "value"}` | Dict（字典） | 用 JSON 花括号格式 |
| 嵌入单元格的图片 | 图片路径 | 见 2.5 图片处理 |
| 空白单元格 | null（空值） | 留空即可 |

**注意**：如果你写 `[1, 2, 3]` 但 JSON 格式不对（比如写成了 `[1, 2, 3` 少了个括号），脚本会把它当作普通字符串处理，不会报错但也不会变成数组。

### 2.5 图片处理

如果想在 Excel 里嵌入图片（比如单位图标），需要**将图片嵌入到单元格内**（不是链接外部文件）。导出脚本会自动提取嵌入的图片，保存到 `assets/` 目录，并在 `.tres` 中记录资源路径。

**注意事项**：
- 图片必须是**嵌入**模式（在 Excel 中右键粘贴图片时选择"嵌入"而非"链接"）
- 支持的格式：PNG、JPG、GIF
- 导出后图片会自动保存到 `assets/<sheet名>/` 目录下

---

## 3. 导出脚本使用

### 3.1 安装依赖（只需一次）

导出脚本依赖 `openpyxl` 库来读写 Excel 文件。在项目根目录下运行：

```bash
pip install openpyxl
```

如果提示权限不足，加上 `--user`：

```bash
pip install openpyxl --user
```

### 3.2 运行导出

在项目根目录（`stick-world/`），用终端运行：

```bash
python stick-world/tools/export_excel.py
```

脚本会做三件事：

1. **第一遍：解析**——扫描 `config/excel/` 下所有 `.xlsx` 文件，读取每个 Sheet 的数据
2. **第二遍：验证**——检查 id 是否重复、必填列是否为空、引用是否正确
3. **第三遍：导出**——生成 `.tres` 文件到 `config/` 对应子目录

**运行成功时的输出示例：**

```
============================================================
  stick-world Excel → .tres 导出工具
============================================================
  Excel 目录: f:\VSCode\game-2\stick-world\config\excel
  输出目录:   f:\VSCode\game-2\stick-world\config
  模式:       正式导出
============================================================
============================================================
第一遍：解析所有 Excel 文件...
============================================================

📄 平衡变量.xlsx
  ├─ Sheet 'variables': 16 行数据, 7 列

📄 建筑数据.xlsx
  ├─ Sheet 'buildings': 6 行数据, 13 列

📄 资源数据.xlsx
  ├─ Sheet 'resources': 7 行数据, 7 列

============================================================
第二遍：数据验证...
============================================================

============================================================
第三遍：导出 .tres 文件...
============================================================
  ✅ config\balance\variables.tres  (16 行)
  ✅ config\buildings\buildings.tres  (6 行)
  ✅ config\resources\resources.tres  (7 行)

============================================================
✅ 导出完成: 3 个 .tres 文件
============================================================
```

### 3.3 只看不导出（干跑模式）

如果你想先检查数据有没有错误，但不实际导出，加上 `--dry-run`：

```bash
python tools/export_excel.py --dry-run
```

干跑模式会执行解析和验证，但不会生成任何 `.tres` 文件。如果验证通过，你会看到：

```
✅ 干跑模式：校验通过
```

### 3.4 错误信息解读

#### 错误 1：重复 id

```
❌ 发现 1 个错误:
  [建筑数据.xlsx] Sheet 'buildings' 第 5 行: id 'bld_house' 重复
```

**原因**：同一个 Sheet 里有两条数据的 `id` 列填了相同的值。

**解决**：打开对应的 Excel 文件，找到重复的那一行，把其中一个 id 改成唯一的。

#### 错误 2：必填列

```
❌ 发现 1 个错误:
  [资源数据.xlsx] Sheet 'resources' 第 3 行: 必填列 'id' 为空
```

**原因**：某列的字段名带 `*` 标记（表示必填），但该行这个单元格为空。

**解决**：找到对应的行和列，填上数据。

#### 错误 3：引用不存在

```
❌ 发现 1 个错误:
  [单位数据.xlsx] Sheet 'stickmen' 第 4 行: 'weapon_id' = 'wep_99' 指向的 id 在 sheet 'weapon' 中不存在
```

**原因**：`weapon_id` 列引用了 `wep_99`，但 `weapons` sheet 里没有 id 为 `wep_99` 的数据。

**解决**：要么去 `weapons` sheet 添加 `wep_99`，要么修改引用为正确的 id。

#### 验证错误时的行为

- 在**干跑模式**下，脚本会列出所有错误但不导出
- 在**正式导出**模式下，脚本会列出所有错误，然后询问你是否继续：

```
⚠️  存在 3 个验证错误，是否继续导出？(y/n):
```

输入 `y` 继续导出（有问题的行会被跳过），输入 `n` 取消导出。

---

## 4. BalanceConfig 对接

### 4.1 导出后的文件位置

运行导出脚本后，`.tres` 文件会按以下规则生成：

```
config/excel/<文件名>.xlsx  →  config/<文件名>/<Sheet名>.tres
```

**示例**：

| Excel 文件 | Sheet 名 | 导出位置 |
|-----------|----------|---------|
| `平衡变量.xlsx` | `variables` | `config/balance/variables.tres` |
| `资源数据.xlsx` | `resources` | `config/resources/resources.tres` |
| `建筑数据.xlsx` | `buildings` | `config/buildings/buildings.tres` |
| `单位数据.xlsx` | `stickmen` | `config/units/stickmen.tres` |
| `单位数据.xlsx` | `weapons` | `config/units/weapons.tres` |

### 4.2 游戏内读取数据

游戏通过 `BalanceConfig` 单例读取数据。`BalanceConfig` 是一个全局 Autoload，在游戏的任何地方都可以直接调用。

**读取方式**：

```gdscript
# 读取单个值
var hp = BalanceConfig.get_value("combat.base_hp")

# 读取整个数据表
var all_resources = BalanceConfig.get_value("resources.data")
```

### 4.3 变量路径说明

`BalanceConfig` 将 `.tres` 文件中的数据加载到内存字典中。路径格式取决于 `.tres` 的结构。

以 `平衡变量.xlsx → variables.tres` 为例，导出后的 `.tres` 中有一个 `variables.data` 数组，包含每条数据行。`BalanceConfig` 会将其展开为以下路径：

```
balance.variables.var_attack_base.value → 10
balance.variables.var_attack_base.min   → 1
balance.variables.var_attack_base.max   → 100
```

**路径规则**：`[Excel文件名].[Sheet名].[数据id].[字段名]`

**使用示例**：

```gdscript
# 在任意游戏脚本中
var attack = BalanceConfig.get_value("balance.variables.var_attack_base.value")
var tax_rate = BalanceConfig.get_value("balance.variables.var_tax_rate.value")
var wood_price = BalanceConfig.get_value("resources.resources.res_wood.base_price")
```

> **注意**：`BalanceConfig` 的 `reload()` 方法目前还在开发中。当前版本修改 Excel 数据后需要重新导出并重启游戏才能生效。热加载功能将在后续版本中实现。

### 4.4 .tres 文件结构说明

每个 `.tres` 文件是一个 Godot 资源文件，基于 [balance_resource.gd](file:///f:/VSCode/game-2/stick-world/config/balance/balance_resource.gd) 类。文件包含：

- `_meta`：元数据（来源文件、Sheet、版本号等）
- `variables.data`：数据数组，每个元素是一个字典，对应 Excel 的一行

不止是代码需要读 `.tres`——如果你想确认导出是否正确，可以直接用文本编辑器打开 `.tres` 文件查看内容。

---

## 5. 添加新数据类型

### 5.1 新建 Excel 文件

假设你要新增一个"技能"表（`skills.xlsx`）：

1. 在 `config/excel/` 目录下新建 `skills.xlsx`
2. 按规范填写 Sheet：

   - **第 1 行**：`id`, `name_zh`, `type`, `power`, `cooldown`, `description`
   - **第 2 行**：`ID`, `名称`, `类型`, `威力`, `冷却时间`, `描述`
   - **第 3 行起**：填入具体数据

3. 保存文件

### 5.2 不需要注册

导出脚本 `export_excel.py` 会**自动扫描** `config/excel/` 下的所有 `.xlsx` 文件。你不需要在脚本里做任何注册操作。放进去就能被识别。

### 5.3 运行导出

```bash
python tools/export_excel.py
```

导出后，你的数据会自动生成到 `config/skills/<Sheet名>.tres`。

### 5.4 在代码中读取

```gdscript
# 读取整个技能表
var skills = BalanceConfig.get_value("skills.技能Sheet名")
```

### 5.5 批量生成 Excel（可选）

如果你需要一次性生成多张表（比如初始化项目时），可以使用 `config/excel/generate_excel.py` 和 `generate_org_tech.py`。这两个脚本会生成带有标准格式、样式和冻结表头的 Excel 模板。

```bash
python config/excel/generate_excel.py
python config/excel/generate_org_tech.py
```

---

## 6. Mod 支持

> **本节为预留设计，当前版本尚未完全实现。**

### 6.1 设计思路

Mod 作者可以创建自己的 Excel 数据文件，覆盖或扩展游戏的基础数据。工作流程与主数据管线一致，但使用独立的导出脚本。

### 6.2 Mod 开发流程（规划）

1. **获取模板**：从 `config/excel/` 目录复制任意 `.xlsx` 文件作为模板
2. **修改数据**：按自己的需要修改数值，但保持列结构不变（第 1 行和第 2 行不动）
3. **独立导出**：将导出的 `.tres` 放入 Mod 目录
4. **游戏加载**：游戏启动时检测 Mod 目录，用 Mod 数据覆盖基础数据

### 6.3 当前可用方式

在 Mod 系统完全实现之前，Mod 作者可以：
- 直接修改 `config/excel/` 下的 `.xlsx` 文件并重新导出
- 或将修改后的 `.tres` 文件放在 `config/` 目录下，覆盖原有文件

---

## 7. 常见问题

### Q1：Excel 里改了数据但游戏没变化

**A**：90% 的情况是忘了运行导出脚本。修改 Excel 后必须执行：

```bash
python tools/export_excel.py
```

修改 `.xlsx` 不会自动更新 `.tres`。Excel 是源文件，`.tres` 是导出产物，游戏读的是 `.tres`。

### Q2：导出报错"重复 id"

**A**：检查对应 Sheet 的 `id` 列，确保每行的 id 都是唯一的。常见情况是复制粘贴数据行时忘了改 id。

### Q3：图片无法导出

**A**：确认图片是**嵌入到单元格**的，而不是链接外部文件。在 Excel 中右键图片 → 选择"更改图片"时，确保没有勾选"链接到文件"。嵌入的图片数据会存在 `.xlsx` 文件内部，脚本才能提取出来。

### Q4：数组/Dict 格式的数据导出来不对

**A**：数组必须用 `[ ]` 包裹，字典必须用 `{ }` 包裹，且必须是合法的 JSON 格式。常见错误：

- 错误：`[1, 2, 3`（少了一个 `]`）
- 正确：`[1, 2, 3]`
- 错误：`{key: value}`（key 没有加引号）
- 正确：`{"key": "value"}`

### Q5：导出时提示"数据不足（至少需要 3 行）"

**A**：每个 Sheet 至少需要 3 行——第 1 行字段名、第 2 行说明、第 3 行起数据。如果 Sheet 里只有表头没有数据，导出会跳过。

### Q6：新增了一列，但导出后看不到

**A**：检查第 1 行的列名是否填写正确。如果列名为空，那一列会被忽略。另外，确保列名没有和其他列重复——重复的列名会导致验证错误。

### Q7：Excel 文件打不开，导出报错

**A**：确保 `.xlsx` 文件没有被其他程序（如 Excel、WPS）以独占模式打开。关闭文件后再运行导出。

### Q8：能在一个 Excel 文件里放多个 Sheet 吗

**A**：可以。导出脚本会遍历每个 `.xlsx` 文件的所有 Sheet。比如 `单位数据.xlsx` 里可以同时有 `stickmen`、`weapons`、`armors` 三个 Sheet，每个 Sheet 会导出为独立的 `.tres` 文件。

---

## 附录：文件结构速查

```
stick-world/
├── config/
│   ├── excel/                          ← Excel 源文件（策划改这里）
│   │   ├── 平衡变量.xlsx
│   │   ├── 资源数据.xlsx
│   │   ├── 建筑数据.xlsx
│   │   ├── 单位数据.xlsx
│   │   ├── 科技树.xlsx
│   │   ├── 编制预设.xlsx
│   │   ├── generate_excel.py           ← 批量生成 Excel 模板
│   │   └── generate_org_tech.py        ← 生成组织和科技树 Excel
│   ├── balance/
│   │   ├── balance_resource.gd         ← .tres 资源基类
│   │   └── variables.tres              ← 导出产物（游戏读这个）
│   ├── resources/
│   │   └── resources.tres
│   ├── buildings/
│   │   └── buildings.tres
│   └── ...
├── tools/
│   └── export_excel.py                 ← 导出脚本
├── core/
│   └── autoload/
│       └── balance_config.gd           ← 游戏内读取接口
└── docs/
    └── technical/
        └── excel-pipeline.md           ← 本文档
```