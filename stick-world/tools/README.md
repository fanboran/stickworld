# tools/ 工具目录

项目自定义工具脚本，按功能分三个子目录。

## 目录结构

```
tools/
├── baking/           # 资源烘焙工具（Godot @tool）
├── pipeline/         # 数据管线工具（Python）
├── dev/              # 开发辅助工具（Godot）
├── terrain_viewer/   # 3D 地形查看器（Godot + Python）
└── README.md         # 本文件
```

---

## baking/ — 资源烘焙

从代码中的骨骼/动画数据烘焙生成 `.tres` / `.png` 资源文件。

### bake_anims.tscn / bake_anims.gd

烘焙火柴人动画资源（idle / walk / attack / dead）。

```bash
godot --headless --path "f:/VSCode/game-2/stick-world" res://tools/baking/bake_anims.tscn
```

- **输出位置：** `res://modules/units/animations/*.tres`
- **依赖：** `modules/units/scripts/stickman_skeleton.gd`（骨骼数据）

### bake_textures.tscn / bake_textures.gd

烘焙火柴人骨骼纹理（pill / circle / triangle / ellipse），使用 SSAA + Lanczos 降采样。

```bash
godot --headless --path "f:/VSCode/game-2/stick-world" res://tools/baking/bake_textures.tscn
```

- **输出位置：** `res://modules/units/assets/textures/stickman/*.png`
- **注意：** 骨骼数据（`SWL_SWORDWRATH`）和纹理生成算法复制自 `modules/units/scripts/stickman_rig.gd`，以保证烘焙工具独立运行不依赖运行时脚本。修改骨骼数据时需同步两处。

---

## pipeline/ — 数据管线

### export_excel.py

将 `config/excel/*.xlsx` 导出为 Godot `.tres` 资源文件，支持类型推断、必填校验、引用完整性检查。

```bash
# 安装依赖
pip install -r tools/pipeline/requirements.txt

# 导出所有
python tools/pipeline/export_excel.py

# 只校验不导出
python tools/pipeline/export_excel.py --dry-run
```

- **输入：** `config/excel/*.xlsx`
- **输出：** `config/<output_dir>/<Sheet名>.tres`
- **详细文档：** `docs/技术/Excel 数据管线使用说明书.md`

### requirements.txt

Python 依赖清单（openpyxl）。

---

## dev/ — 开发辅助

### code_scanner.gd

扫描项目中所有 `.gd` 文件的语法和基本质量问题（调试残留 `print()`、TODO 无说明、行过长等）。

```bash
godot --headless --path "f:/VSCode/game-2/stick-world" -s res://tools/dev/code_scanner.gd
```

- **退出码：** `0` = 无问题，`>0` = 有问题
- **扫描目录：** `modules`、`core`、`tests`、`tools`（排除 `addons/`）

### map_grid_drawer.gd

编辑器网格绘制器（`@tool` 脚本），在 2D 编辑器中显示 32px 网格竖线、地面线、建筑占地高亮。

挂在 VillageMap 场景下使用，读取父节点的 `ground_y` / `ground_bottom` / `map_right` 属性。由 `MapEditor` 插件设置 `ghost_*` 属性来高亮建筑将占用的竖条。

- **引用场景：** `modules/world/scenes/test_village_map.tscn`
- **全局类型：** `MapGridDrawer`（通过 `class_name` 注册）

---

## terrain_viewer/ — 3D 地形查看器

将 `tools/worldgen/output/` 生成的 `.npy` 高度图转换为 3D 地形，在 Godot 编辑器中交互查看。

### 使用方式

1. **转换高度图**（首次或高度图更新后）：

```bash
python tools/terrain_viewer/convert_heightmap.py --size 1024
```

2. **在 Godot 编辑器中打开** `res://tools/terrain_viewer/terrain_viewer.tscn`

3. **交互操作**（运行时）：
   - 左键拖拽 → 旋转视角
   - 滚轮 → 缩放
   - 中键拖拽 → 平移

### 文件说明

| 文件 | 说明 |
|------|------|
| `convert_heightmap.py` | Python 脚本：将 `.npy` 下采样并转为 16-bit 灰度 PNG |
| `terrain.gdshader` | 着色器：顶点位移 + 8 级海拔着色（深海→浅海→沙滩→草地→森林→岩石→雪） |
| `terrain_viewer.gd` | `@tool` 脚本：生成地形网格、加载着色器、运行时相机控制 |
| `terrain_viewer.tscn` | 场景文件 |
| `output/heightmap_1024.png` | 转换后的高度图（16-bit 灰度 PNG） |

### 可调参数

在编辑器 Inspector 中选中 TerrainViewer 节点可调整：
- **Height Scale**：地形垂直缩放（默认 60）
- **Sea Level**：海平面在归一化高度图中的位置（默认 0.12）
