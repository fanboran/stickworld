# HD-2D 街景系统

> **定位**：HD-2D 场景图的技术层单一真相源。八方旅人式呈现：3D 场景 + Blender 烘焙卡 + 2D 逻辑角色经 SubViewport billboard 站进场景。
> 原型可行性论证与烘焙管线见 [`2.5D与HD-2D可行性.md`](2.5D与HD-2D可行性.md)；本文写**运行时系统**怎么设计、为什么。
> 场景图（卷轴地图）整体架构见 [`场景与战斗架构.md`](场景与战斗架构.md)。

---

## 一、是什么

当前**全部游戏内地图的呈现形态**（2026-09-14 起）：主街（出生村 hd2d_street）、算法村（hd2d_village_b）均为 HD-2D 图；战场/道路/守城图仍是 2D 旧图（待迁移）。

三个组成部分：

```
Blender 离线端（tools/blender_buildings/）        Godot 运行时端
├─ buildings.py 27 装配器 → 烘建筑卡              ├─ proto_hd2d.tscn  3D 街景（卡+地面+光照）
├─ props.py 94 件 → 烘道具卡          ──卡库──→  ├─ char_sprite_3d   角色 billboard（每实体一个）
├─ nature.py 16 类 → 烘自然物卡                  ├─ Hd2dStreetMap    宿主（MapBase 子类）
└─ city_layout.py 规模档布局算法                  └─ 布局 JSON ←── export_city_layout.py
```

## 二、关键设计

### 2.1 卡与落位（proto_hd2d.gd）

- 建筑卡 = Blender 正交相机（yaw 0°/tilt 26°，与游戏 3D 相机同角度）烘的透明底 PNG + glow 层。卡是 QuadMesh 贴图，**写深度**参与遮挡，吃伪法线光照。
- 卡落位按 `cards.json` 的 anchor（画面中心对应世界点）；道具/自然物按**卡底贴地**公式（否则卡底入地）。
- 元数据 JSON（cards/props/nature.json）**随包入库 tex/**，加载先找烘焙工作区 `temp/`、缺失回退 `res://…/tex/`——新机器 clone 后不跑 Blender 也能玩。

### 2.2 两种摆街模式（proto_hd2d._opts.layout）

- **手摆主街**：FRONT_ROW 常量逐栋写死（出生村语义：西村口民居→仓库→铁匠铺→宅邸→东民居→…），道具/自然物按绝对坐标表。
- **布局驱动（算法村）**：`export_city_layout.py` 把 `city_layout.plan_city(tier, seed)` 的平面布局导出成布局 JSON（def→卡映射、x 中心化、**同排推挤**——布局 x 是墙格位、卡画面含出檐，按画面间隙 ≥0.6 格推挤+质心回正）。场景按 `layout_name` 读 JSON：前排=布局 row0、bg1=布局后排（bg2/3 插缝算法照旧补满）、道具/树按布局。
- 新聚落 = 一条导出命令 + 一张 tscn（挂 `layout_name`），零手工。

### 2.3 宿主（Hd2dStreetMap extends MapBase）

- **相机镜像**：3D 正交相机每帧镜像 2D CameraRig 的 x 与 zoom——1/4 区域跟随、顶栏居中、边缘滚动、中键拖拽、滚轮缩放全部在 CameraRig 上驱动。**为什么**：CameraRig 是全部相机操作的单一入口，3D 侧只做镜像；自己钉死玩家 x 会让手动操作全部失效（踩过）。
- **昼夜**：读 `WorldState.game_time`（单位=小时 0~24，EnvironmentSystem 写入），6:00/19:00 切 `_apply_light("day"/"night")`。2D 的 CanvasModulate 够不到 3D 场景，必须自己挂。
- **边界自适应**：布局驱动模式按布局街宽收 map_left/right（±半宽+8 格）。
- **出口**：东西村口 ChunkTrigger（纯代码创建），旅行链注册在 game_root。
- **设施门控**：`supports_village_facilities()`=false 跳过 2D 建筑设施（仓库/程序化资源点）；`wants_villager_npcs()`=true 照常生成村民——两个门控分开，因为村民不需要 2D 建筑也能干活（见 2.6）。

### 2.4 角色渲染：2D 逻辑 + 3D 视觉（char_sprite_3d.gd）

**为什么**：角色浮在 2D canvas 上永远盖住 3D（无遮挡/无接地/无纵深），且 2D 画布坐标与 3D 投影速度不一致（跟手框错位的根因）。定稿：**逻辑留 2D（物理/输入/AI 不动），视觉转 3D billboard**。

- 每实体一个 char_sprite_3d 实例（独立 SubViewport 288×352 ×2 超采样 + 独立骨架动画），`set_world_pos` 逐帧镜像 x/z/朝向/纵深缩放。
- 2D 侧 RigHost 与 ContactShadow 隐藏（渲染职责移交）；走路/待机动画按 2D velocity 切。
- possessed 脚下四角框也是 3D 贴地 quad（同空间同相机天然同步）；2D 画布框在 HD-2D 图跳过（SelectionSystem 查 `wants_3d_bracket`）。
- 踩坑：**basis 与 scale 先后赋值互相覆盖**（scale setter 从 basis 分解重组）——缩放并入 basis 一次赋值；**朝向翻转走 shader 的 UV 镜像**（basis 负缩放破坏俯仰轴）；shader 注释只能 `//`（`#` 导致整 shader 编译失败→白模）。

### 2.5 全融合描边（stickman_outline.gd + 双 shader）

创始人定稿口径：**白描边只包整体剪影外轮廓，内部零描边**（肘/膝/臂身交界都不出线，肢体靠剪影读形）。

机制（ID Buffer + 邻接表，最早版即此设计）：
1. OutlineGroup 整棵收进 CanvasGroup（**子树同搬**，rig→IK marker 相对路径不变）；
2. 每个零件容器挂 ID shader：把 part_id 写进 alpha（全融合=全部零件同一 ID）；
3. CanvasGroup 自身材质 = 描边 shader：`hint_screen_texture` 采到的就是**组自身缓冲**——前景像素查 8 邻域，不同 ID 且不邻接→分隔线；背景像素邻近前景→外轮廓白线。

生效范围=char_host（每角色独立 SubViewport，屏幕空间描边付得起）；2D 批渲染路径不受影响。

**火柴人渲染踩坑备查**（本节知识曾完全无记载，复排查了两天）：
- 骨架渲染是**全局两遍**（stickman_skeleton.gd）：所有描边层 z=-1 压底、所有填充层 z=0 置顶——肢体重叠处填充无缝融合，描边只在整体剪影外轮廓出线（"只有剪影描边"口径，与 ID Buffer 全融合同语义）。部件间相对遮挡靠填充层之间的树序（`reorder_render_order`）；武器/盾相对 z=+7 盖全身肢体（weapon_mount）。
- 渲染双路径：MultiMesh 批渲染（`render/batch_rig` 工程设置，默认开；环境变量 `STICK_BATCH_RIG` 强制覆盖）vs 矢量 Line2D 路径。批渲染是战场规模的技术，SubViewport 里两条路径都可用。crowd 桶（`render/crowd_renderer` / `STICK_CROWD`）同款"描边先画、填充后画"语义（y 分带内）。
- 描边宽 zoom 补偿（屏幕像素恒定，`Skeleton.outline_world_width`）三条渲染路径都接：矢量 `stickman_rig._update_outline_zoom`（改 stroke 几何）、批渲染 `StickmanBatchRig.set_outline_width`（重烘预烘局部变换）、crowd `CrowdRenderer._refresh_outline_zoom`（重烘静态共享表，按 1.0 体型基准）。
- 体色常量 `Skeleton.DEFAULT_BODY` = 深灰紫 (0.156,0.156,0.182)——经直方图核实与旧版逐像素一致，别再怀疑它。

### 2.6 碰撞模型（get_solid_rects → HD2DSolids）

- **建筑=地基带**：x=建筑格宽，y=行走带后段到建筑基线外扩 1.4 格。不是贯穿全街的竖墙——街上可从建筑前景自由通行。
- **道具/树木/矿=点障碍**：碰撞只在自身纵深带附近（z→y 窄带），可绕行。整带竖墙会把出生在树旁的 NPC 永久卡死（踩过）。
- F3 调试：HD2DSolids 并入 `get_walk_barriers()` 由 debug_drawers 画蓝框。

### 2.7 村民劳作（无 2D 建筑也能运转）

- 落脚点：地图 `get_npc_spawn_points()` 按语义预排（铁砧旁/森林带资源点旁/街市）；没有则退回 2D 村图的两簇硬编码。
- **露天工位** duck：TownLife 找不到建筑工位时，向上找地图 `get_open_work_sites()`——铁匠铺卡前的露天铁砧就是铁匠工位（`work_site_def="smithy_lv1"`）。回退链：建筑 WorkSlots > 露天工位 > 占位表。
- 伐木/矿工直接用场上的 2D ResourceNode（13 个采集点由自然物摆位表驱动生成，2D 笔触视觉隐藏、PBR 卡负责观感）。

## 三、跑法与资产再生产

```
# 烘卡（改了建筑/道具/自然物库后）
blender -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py    # 建筑卡→temp/proto25d/
blender -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_props.py      # 道具卡
blender -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_nature.py     # 自然物卡
# 算法村布局
python tools/blender_buildings/export_city_layout.py --tier village --seed 611036 --name village_b
# 烘完把 temp/{proto25d,proto_hd2d} 的 png+json 同步进 tests/dev/proto_hd2d/tex/（入库）
# 出图/调试
godot --path stick-world res://tests/dev/proto_hd2d/proto_hd2d.tscn -- --shots=b --layout=village_b
# 实机链路验证
godot --path stick-world res://tests/dev/verify_hd2d_map.tscn
```

## 四、待迁移与已知边界

- 战场/道路/守城图仍是 2D 旧图；战斗类测试 boot 在 battlefield 上。
- 设施类测试 7 套 SUSPENDED（.tscn.suspended 摘出矩阵）：待玩法设施（PlacementGrid/兵营/仓库实体）接入 HD-2D 图后在生产图重建。
- 角色 billboard 当前无武器/盾渲染（武器挂在 2D WeaponMount，随 RigHost 一起隐藏）——HD-2D 化武器渲染是独立工作项。
- 村民待业/工作行为依赖 WorldState.game_time 节律，与昼夜挂钩同源。
