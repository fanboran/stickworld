# texture_gen：程序化纹理生成模块

> 本模块从 `building_gen` 解耦而来，负责所有程序化纹理/材质的生成。
> 建筑生成模块（`building_gen`）单向依赖本模块，本模块不依赖 building_gen。

## 目录结构

```
modules/texture_gen/
├── api.gd                          # 模块对外 API（class_name TextureGenAPI）
├── README.md                       # 本文件
├── assets/                         # 模块自持资产（white_tex.png，不依赖 building_gen）
├── materials/                      # 材质配方，每种材质一个子目录
│   ├── thatch/                     # 茅草屋顶（CPU 笔迹占位，shader 仅最小测试）
│   │   ├── shaders/thatch.gdshader
│   │   ├── scripts/
│   │   │   ├── thatch_applier.gd   #   CPU 笔迹生成器（v11 油画笔迹）
│   │   │   └── debug/              #   thatch_debug.gd 调参场景、thatch_building_demo.gd 建筑演示
│   │   ├── scenes/                 #   thatch_debug.tscn、thatch_building_demo.tscn
│   │   └── reference/              #   参考图
│   ├── stone_wall/                 # 浅色石墙（已实现，GPU Shader；子目录另有材质级 README.md）
│   │   ├── shaders/stone_wall.gdshader
│   │   ├── scripts/debug/          #   stone_wall_debug.gd
│   │   ├── scenes/                 #   stone_wall_debug.tscn
│   │   └── reference/              #   参考图（白_1.png / 白_2.png）
│   ├── stone_band/                 # 蓝灰石檐（已实现，GPU Shader）
│   │   ├── shaders/stone_band.gdshader
│   │   ├── scripts/debug/          #   stone_band_debug.gd
│   │   ├── scenes/                 #   stone_band_debug.tscn
│   │   └── reference/              #   参考图（灰.png）
│   └── stone_window/               # 拱形石窗（已实现，GPU Shader）
│       ├── shaders/stone_window.gdshader
│       ├── scripts/debug/          #   stone_window_debug.gd
│       ├── scenes/                 #   stone_window_debug.tscn
│       └── reference/              #   参考图（stone_window_ref.png）
├── shaders/lib/                    # 共享 Shader 原语
│   ├── hash.gdshaderinc            #   确定性 hash 原语
│   └── stone_lib.gdshaderinc       #   石头 SDF / 笔触 / 配色原语
├── scripts/
│   ├── procedural_materials.gd     # CPU 合成贴图原语（class_name ProceduralMaterials）
│   ├── stone_brick_gen.gd          # CPU 石砖纹理静态工具（class_name StoneBrickGen，运行时与离线烘焙共用）
│   └── debug/
│       ├── capture_in_game.gd      #   通用：标准运行模式自动截图
│       └── material_debug_panel.gd #   材质调试面板公共基类（四个材质调试场景脚本均继承之）
└── tools/
    └── capture_standard.ps1        # 通用截图 wrapper（支持 -Material）
```

## 技术架构

- **CPU 贴图**：`procedural_materials.gd` 用 `Image` 类在 CPU 上合成纹理，适合小尺寸/一次性贴图
- **GPU Shader**：`materials/<name>/shaders/<name>.gdshader` 在 fragment shader 中实时渲染，适合大尺寸/参数化纹理
- **CPU 笔迹（thatch 占位）**：`thatch_applier.gd` 在 CPU 上生成油画笔触纹理，等 GPU Shader 成熟后替代
- **CPU 石砖**：`stone_brick_gen.gd` 静态工具生成石砖贴图，城墙/城门的运行时生成与离线烘焙共用同一算法

## 调试与截图

```powershell
# 默认捕获 thatch 调试场景
.\modules\texture_gen\tools\capture_standard.ps1

# 按材质名捕获
.\modules\texture_gen\tools\capture_standard.ps1 -Material thatch
.\modules\texture_gen\tools\capture_standard.ps1 -Material stone_wall
.\modules\texture_gen\tools\capture_standard.ps1 -Material stone_band
.\modules\texture_gen\tools\capture_standard.ps1 -Material stone_window
```