# building_gen：程序化建筑生成系统

> 本模块负责程序化生成建筑实体：
> - `buildings/`：程序化建筑定义（草棚外壳 + 城墙等，核心）
> - 纹理/材质生成已迁移至 [`modules/texture_gen/`](../texture_gen/README.md)，本模块单向依赖之。
> - 编辑器预览/参考场景已归档至 `archive/`（开发参考，运行时无引用）。
>
> 系统级设计规范见 [docs/技术/教程/程序化材质系统.md](file:///f:/VSCode/game-2/stick-world/docs/技术/教程/程序化材质系统.md)。

---

## 目录结构

```
modules/building_gen/
├── api.gd                          # 模块对外 API（def→场景注册表，材质 API 见 TextureGenApi）
├── README.md                       # 本文件：系统级说明
├── buildings/                      # 程序化建筑定义（核心）
│   ├── placeholder.tscn            #   草棚外壳（房屋类建筑共用，16格宽，可拉伸）
│   ├── thatch_hut.gd               #   草棚调色板子类（extends BuildingExterior）
│   ├── building_exterior.gd        #   外观装配基类（外壳几何 + 纹理生成）
│   ├── wall_tier1.tscn             #   低矮土墙（耦合：场景手绘，非材质/模块分离）
│   ├── wall_tier2.tscn             #   标准城墙
│   ├── wall_tier3.tscn             #   大型城墙
│   ├── wall_gate.tscn              #   城门
│   └── reference/                  #   建筑级参考图（设计稿）
├── archive/                        # 归档（开发参考，无运行时引用）
│   ├── smithy_reference.tscn       #   铁匠铺零件参考装配场景（历史）
│   ├── smithy_preview.tscn         #   铁匠铺编辑器预览场景（历史）
│   ├── smithy_reference_textures/  #   零件纹理（配套）
│   ├── smithy_preview.gd / smithy_reference.gd
├── scripts/
│   ├── building.gd                 # Building 基类（class_name）
│   └── building_snap.gd            # 编辑器吸附工具（@tool，配合预览场景做场景搭建/测试）
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