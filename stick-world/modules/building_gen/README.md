# building_gen：程序化建筑生成系统

> 本模块负责程序化生成建筑实体：
> - `buildings/`：程序化建筑定义（草棚外壳 + 城墙等，核心）
> - 纹理/材质生成已迁移至 [`modules/texture_gen/`](../texture_gen/README.md)，本模块单向依赖之。
>
> 系统级设计规范见 [docs/技术/教程/程序化材质系统.md](file:///f:/VSCode/game-2/stick-world/docs/技术/教程/程序化材质系统.md)。

---

## 目录结构

```
modules/building_gen/
├── api.gd                          # 模块对外 API（def→场景注册表，材质 API 见 TextureGenAPI）
├── README.md                       # 本文件：系统级说明
├── buildings/                      # 程序化建筑定义（核心；命名约定详见 buildings/README.md）
│   ├── placeholder.tscn            #   草棚外壳（房屋类建筑共用，16格宽，可拉伸）
│   ├── thatch_hut.gd               #   草棚调色板子类（extends BuildingExterior）
│   ├── building_exterior.gd        #   外观装配基类（外壳几何 + 纹理生成）
│   ├── building_palette.gd         #   调色板 Resource（各建筑以 .tres 注入色板）
│   ├── interior_props.gd           #   室内家具程序化生成库（床/桌/灯等）
│   ├── smithy_lv1.gd / .tscn       #   铁匠铺 Lv1（开放锻造棚：石炉/烟囱/铁砧/工作台挂件）
│   ├── barracks.gd / .tscn         #   兵营（军事化外壳：深木色 + 檐口军旗 + 盾牌圆饰）
│   ├── warehouse.gd / .tscn        #   仓库（商贸外壳：暖木色 + 货箱堆 + 麻袋）
│   ├── stone_warehouse.gd / .tscn  #   石造仓库（纯石头建筑：垛口石墙/拱窗/石带/角石）
│   ├── manor.gd / .tscn            #   宅邸（二层半木悬挑建筑：外梯+阳台+穿坡烟囱）
│   ├── timber_cottage.gd / .tscn   #   木骨石基民居（石基+半木+金茅草）
│   ├── grand_hall.gd / .tscn       #   议事厅（地标级混合精修：石砌基层+半木+茅草坡+脊上钟楼）
│   ├── wall_tier1.tscn / wall_tier2.tscn / wall_tier3.tscn / wall_gate.tscn  #  土墙/标准城墙/大型城墙/城门
│   ├── wall_segment.gd             #   城墙段程序化外观（wall_tier 系列共用，extends BuildingExterior）
│   ├── *_palette.tres              #   各建筑调色板（茅草/木作/石作色板注入）
│   └── reference/                  #   建筑级参考图（铁匠铺 lv1-lv4 设计稿）
└── scripts/
    └── building.gd                 # Building 基类（class_name）
```

---

## 依赖

- `modules/texture_gen/`：CPU 程序化贴图（`TextureGenAPI` 静态方法、`StoneBrickGen` 石砖纹理）

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

`.godot/imported/` 目录缓存了旧版本的 `.gd` 脚本解析结果。如果修改了 `run_tests.gd` 之类文件但 Godot 仍报旧的解析错误，说明缓存未刷新。解决：`--editor --quit` 重导入，或手动删 `.godot/` 下的 `global_script_class_cache.cfg`。