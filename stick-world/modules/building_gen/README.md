# building_gen：程序化建筑生成系统

> 本模块负责程序化生成建筑实体：
> - `buildings/` + `scenes/` + `scripts/preview/`：建筑零件装配、编辑器预览、建筑定义（核心）
> - 纹理/材质生成已迁移至 [`modules/texture_gen/`](../texture_gen/README.md)，本模块单向依赖之。
>
> 系统级设计规范见 [docs/技术/教程/程序化材质系统.md](file:///f:/VSCode/game-2/stick-world/docs/技术/教程/程序化材质系统.md)。

---

## 目录结构

```
modules/building_gen/
├── api.gd                          # 模块对外 API（仅建筑实例化，材质 API 见 TextureGenApi）
├── README.md                       # 本文件：系统级说明
├── buildings/                      # 程序化建筑定义（核心）
│   ├── bld_workshop.tscn           #   @deprecated 旧预制场景，待新版替换
│   ├── pg_smithy_lv1.gd            #   铁匠铺 Lv1 生成脚本（继承 Building 基类）
│   ├── pg_smithy_lv1.tscn          #   铁匠铺 Lv1 场景（碰撞/交互区/工作槽位）
│   └── reference/                  #   建筑级参考图
│       ├── smithy_lv1.png ~ smithy_lv4.png
│       ├── smithy_lv1_thatch.png
│       └── smithy_lv1_thatch_tile.png
├── scenes/                         # 建筑编辑/预览场景（核心）
│   ├── smithy_reference.tscn       #   铁匠铺完整参考场景（程序化零件装配）
│   ├── smithy_preview.tscn         #   铁匠铺编辑器实时预览场景
│   └── smithy_reference_textures/  #   smithy 建筑零件纹理（与 smithy_reference.tscn 配套）
├── scripts/
│   ├── building.gd                 # Building 基类（class_name）
│   ├── building_snap.gd            # 编辑器吸附脚本（@tool）
│   └── preview/                    # @tool 预览脚本（编辑器实时渲染）
│       ├── smithy_reference.gd     #   装配铁匠铺所有零件到场景
│       └── smithy_preview.gd       #   编辑器内实时预览
└── assets/
    └── white_tex.png               # 4x4 白色纹理，激活 Sprite2D UV
```

---

## 依赖

- `modules/texture_gen/`：CPU 程序化贴图（`ProceduralMaterials`）、GPU Shader 材质、截图工具链

---

## 开发注意事项

### Godot 编辑器 mmap 文件锁

Godot 编辑器对 `.tscn` 文件使用内存映射文件（mmap），导致 PowerShell 的 `Set-Content` 或 `[System.IO.File]::WriteAllText` 直接写入会报错。

**绕过方法**：先写入临时文件，再用 `Move-Item` 原地替换：

```powershell
$tmp = "$f.tmp"; $c = [System.IO.File]::ReadAllText($f)
# 编辑 $c ...
[System.IO.File]::WriteAllText($tmp, $c)
Move-Item -Path $tmp -Destination $f -Force
```

### Godot 脚本缓存导致旧错误反复出现

`.godot/imported/` 目录缓存了旧版本的 `.gd` 脚本解析结果。如果修改了 `run_tests.gd` 之类文件但 Godot 仍报旧的解析错误，说明缓存未刷新。解决：`--editor --quit` 重导入，或手动删 `.godot/global_script_class_cache.cfg`。