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

主街这张图的完整结构解剖（分层坐标 / 构图三钉 / 摆街数据流 / 光照档）见 **§六**——改布局、构图、背景前先读。

## 二、关键设计

### 2.1 卡与落位（proto_hd2d.gd）

- 建筑卡 = Blender 正交相机（yaw 0°/tilt 26°，与游戏 3D 相机同角度）烘的透明底 PNG + glow 层。卡是 QuadMesh 贴图，**写深度**参与遮挡，吃伪法线光照。
- **台基不烘**（创始人 2026-09-15）：地面灰白台基在烘端不生成（`buildings.py PLINTH_ENABLED=False`），接触阴影踏面同步剥除、整楼按实测最低点下沉贴地。引擎 `base_cut` 改口径：**alpha 扫描卡底透明留白**（同 `_prop_bottom_pad`，PAD≈10px 不沉墙脚会浮空），下沉后墙脚回到与台基时代同一条基线，接地影 blob（固定 `BSHADOW_Z`）不用动。
- **地面占地随卡导出**：`cards/props/nature.json` 每条带 `footprint: [宽格, 深格]`（贴地顶点实测，排除出檐悬挑）。宽度档规则（创始人拍板）：**新增档位一律 2 格整数倍**，存量 4/6/8/12/16 档保留不动。
- **卡库 meta 字段契约**（cards.json / props.json / nature.json 同构；烘焙端三脚本产出，`proto_hd2d.gd` 装进 `_cards/_props/_nature` 字典）：

| 字段 | 含义 |
|---|---|
| `card` | 卡名（建筑 `def_w<格数>`，道具/自然物为件名） |
| `def` | 装配器/件名 |
| `cells` | 宽度档格数（仅建筑；新档一律 2 格整数倍） |
| `px` | 卡像素尺寸 |
| `zoom` | 烘焙像素/世界单位（2x） |
| `units` | 卡画面投影宽高（世界单位，**含出檐**——落位/剪影排布用，不是占地） |
| `anchor` | 画面中心对应世界点（卡底贴地落位用） |
| `footprint` | **地面占地 [宽格, 深格]**：贴地顶点（z≤8px）实测、排除出檐；1 格=32。目前仅导出，运行时尚无消费方 |
| `glow_mats` | 参与自发光层的材质名清单 |
| `solid` | 是否挡人（仅 nature.json） |

- 卡落位按 `cards.json` 的 anchor（画面中心对应世界点）；道具/自然物按**卡底贴地**公式（否则卡底入地）。
- 元数据 JSON（cards/props/nature.json）**随包入库 tex/**，加载先找烘焙工作区 `temp/`、缺失回退 `res://…/tex/`——新机器 clone 后不跑 Blender 也能玩。

### 2.2 摆街数据的三种来源（优先级从高到低）

- **宿主运行时生成（游戏内一律此路）**：地图 tscn 挂 `layout_name`（主街 hd2d_street、村B village_b），宿主首次进入时 `CityGen.generate(tier, hash("city:"+名))` 现场生成 plan 注入 `layout_data`——确定性种子多局一致，无中间文件。档位取宿主脚本常量 `CITY_TIER`（当前统一 townlet）。行政槽/推挤/墙线推导等算法口径见 §三点五。
- **布局 JSON（proto 开发链路）**：`export_city_layout.py` 导出 `hd2d_layouts/<名>.json`（def→卡映射、x 中心化、同排推挤），proto 直跑 `--layout=` 读取；游戏内不走 JSON。
- **手摆常量（原型兜底，游戏内不触发）**：FRONT_ROW/PROPS/NATURE_SPOTS（出生村语义翻译），仅无布局时生效。
- 消费映射：前排=plan row0；背景两排运行时生成（bg1 主天际线连铺 + bg2 地平线补缝，规则见 §6.4），plan 的 row1/2 暂不消费（§6.7）。

### 2.3 宿主（Hd2dStreetMap extends MapBase）

- **相机镜像**：3D 正交相机每帧镜像 2D CameraRig 的 x 与 zoom——1/4 区域跟随、顶栏居中、边缘滚动、中键拖拽、滚轮缩放全部在 CameraRig 上驱动。**为什么**：CameraRig 是全部相机操作的单一入口，3D 侧只做镜像；自己钉死玩家 x 会让手动操作全部失效（踩过）。
- **昼夜**：读 `WorldState.game_time`（单位=小时 0~24，EnvironmentSystem 写入），6:00/19:00 切 `_apply_light("day"/"night")`。2D 的 CanvasModulate 够不到 3D 场景，必须自己挂。
- **月夜档（2026-09-15 创始人定稿：月光在 Blender 里烘亮）**：夜观感主体是**夜版卡**——烘卡端每卡多烘一张 `<卡>_night.png`（亮冷蓝月亮方向光 + 低夜环境，窗/火/水晶自发光直接烘进 albedo，建筑/道具/自然物三库全量；月亮必须从**正面高角度**斜打，背面打光会把正立面全留在阴影里）；运行时 `card.gdshader` 的 `night_mix` 整卡切换（夜版缺失回退日版），`night_comp` 用 EMISSION 把烘卡亮度补回 ≈1.0（夜间场景光按地面/角色需要给暗档冷光，不许再压卡）。三条配套口径：① **夜雾删掉**（后景/远处"纯黑"的元凶是近黑雾色+后景吃满雾程；层次交给后景分层染色 + 远焦 DOF）；② 场景月亮方向光只给 0.15 能量、盘面张角缩到 2°（`sun_angle_max`，默认 30° 的巨大盘会被远焦 DOF 糊成斜光带）；③ **窗光去黄 + 半透明发光**——glow 染色暖白 `CARD_GLOW_TINT`、能量降档；夜版发光**不是整块换发光片**，而是 copy 原材质后在 Material Output 前插一枚 **Mix Shader**（原表面占 1-FAC、Emission 占 FAC，字面半透明——Add 加法会把暗原材质淹没成平光块），玻璃的月光反光/框格透出来（窗 FAC 0.65/火 0.85/水晶 0.7）；**道具库裸 `glass` 是井口/水面占位材质**（well 井口、trough 水面），不进发光名单（否则井口烘成白圈），街具灯头走 `glazing_win`/`clear_glass`；后景窗光按 `BG_GLOW_RATIO` 低档点缀（后景卡登记进 `_bg_card_mats`），街灯降饱和降能。
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
- **劳作可见（billboard 通道，2026-09-15）**：镜像层动画**全放行**——attack 是 oneshot，播完实体侧自动回切 idle/walk，逐拍重触发靠 `set_anim` 变更检测天然完成；此前 attack 被强制降级 walk/idle，挥镐/挥锤在街上不可见，干活与罚站无法区分。头顶进度条走双通道：2D 条挂 **RigHost**（街上随 RigHost 整体隐藏，不再重复渲染），billboard 用自带 3D 条（`char_sprite_3d.set_work_progress`，bg+fill 双 quad 左锚定、随 depth 缩放）；数据源统一为 `entity.get_action_progress()`（VisualController 进度值缓存，采集/派工/搬运同源）。
- **读档劳作恢复（2026-09-15）**：职业 id 与 `is_villager` 随 entities.extra_data 落档（`SaveHandler._save_entities`），读档回填并经 `TownLifeAPI.apply_profession_appearance` 重挂装具（工具不入档，按 id 重应用）——此前存档从不带这两字段，读档村民是"无职业、非村民"实体，AI 决策双拒（不采集也不闲逛），主街读档即全员罚站。老档（extra 无字段）安全回退保持默认；配置已删改的职业 id 回待业池。锁：`tests/unit/test_townlife_save_persistence.gd`。

## 三、跑法与资产再生产

```
# 烘卡（改了建筑/道具/自然物库后；三套脚本每卡出 日版/glow/夜版 三张）
blender -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py    # 建筑卡→temp/proto25d/
blender -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_props.py      # 道具卡
blender -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_nature.py     # 自然物卡
# 算法村布局
python tools/blender_buildings/export_city_layout.py --tier village --seed 611036 --name village_b
# 烘完把 temp/{proto25d,proto_hd2d} 的 png+json 同步进 tests/dev/proto_hd2d/tex/（入库）；
# 只补夜版时同步 *_night.png 即可（月夜档，见 §2.3）
# 出图/调试
godot --path stick-world res://tests/dev/proto_hd2d/proto_hd2d.tscn -- --shots=b --layout=village_b
# 实机链路验证
godot --path stick-world res://tests/dev/verify_hd2d_map.tscn
```

## 三点五、地面三带与城市布局生成（2026-09-15 创始人定稿）

**地面三带**（沿 z 从远到近，左右随城市宽度延展；贴图均在 tex/ground_tiles/）：

| 带 | 范围 | 城心（±30 格） | 城市边缘区 | 城外（墙外半屏） |
|---|---|---|---|---|
| **建筑带**（台面，z 0.42~1.95，高 PLAT_H=0.65） | 建筑基座 + 街具 | 石板（band_shoulder_stone） | **草地**（grass_alb_128） | 草地（grass_sparse_alb_128） |
| **道路带**（z 1.9~46，行走面，y=0） | 玩家/村民行走 | 石板路（band_road_stone） | 夯土路（rammed_earth，**唯一不长草的带**） | 草地（草土路） |
| **背景地面带**（城内，远端→0.42，**y=PLAT_H 与建筑带同高**） | 城内地面延续到地平线 | 石板/夯土（与道路带同材质分幅） | 同左 | ——（墙外为城外草地带 y=0） |

**太阳**：场景里的太阳 = **程序化天空自带的太阳盘**（ProceduralSkyMaterial
对场景里的 DirectionalLight3D `_sun` 自动渲染，无独立贴图/无独立节点）；位置由
`_sun.rotation`（昼档 Euler −62°/140°）决定，现居画面**右上**；昼档可见、夜档
随天空变暗。它被建筑卡遮挡 = 深度测试天然处理，无需开关逻辑。改名/挪位都改
`_sun.rotation`，不要新建第二个太阳。

草地规则：**只有道路带不长草**——建筑带台面、城外野地全部草地贴图（草地/稀疏草土两档，ground_tiles.py 的 t_grass/t_grass_sparse 烘制）。

**城市布局生成**（CityGen，首次进入按城名哈希种子生成，多局尽量一致）：

- 长度不写死 = 建筑排完的自然跨度 + 墙留边；**建筑变多 → 城市扩展 → 墙自动前移**，野地资源窗随之露出。
- 行政槽居中（= 出生点/广场），市场/工匠/居住/生产四带随机分配到某侧（轻量配平，非镜像）；特殊建筑（教堂/法师塔/城防塔）浮动插位。
- 排布从中心向两侧逐栋推挤（画面宽保底间隙 0.6 格），产物级修复兜底——零重叠；**位置吸附整格**（中心取整+整格步进推开——创始人：建筑位置必须整格摆放，宽度本就是格整数倍）。
- 建筑池按聚落等级窗口表取（铁匠 3 级封顶、草棚/干草棚/村舍进城消亡、仓库 city 起）；未烘卡自动过滤，资产补烘即生效。
- 城外资源两级：主街墙外带只露 2~3 个（resource_gen 低密度+林线净空），大宗采集走城门传送的**西郊/东郊资源图**（Hd2dResourceMap，密度 0.35）。
- 资源分布口径（2026-09-15）：**整个前景地面段（建筑线→前缘）都可放**，不只道路段；资源间距 ≥96px（树冠卡宽 2~3 格，防互相穿模）；野外树/石**有建模体积**——碰撞收窄成树干/岩心窄条（±0.4 格），村民采集可达；城外开阔带纯景就一两棵树+木头。
- 地面贴图（2026-09-15 定稿）：**全部世界坐标锚定 UV**（同材质跨带无缝续接、缩放全局一致）；背景地面带与建筑带**同高**——建筑带身后的城内地面保持台面标高到地平线，无"踩空"落差（创始人 2026-09-15），与道路带同材质分幅，只铺到**第二排后景根部**（地平线=第二排楼脚）；墙外野地=稀疏草土整块贯通。
- 档位：tiny（无分区随机）/ hamlet（各一基础版）/ townlet（=主街初始档）/ village / town / burgh / city（capital/metropolis 待资产后开）。

## 四、屏幕映射（2D↔3D 逐像素契约）

> 本节是 F3 调试覆盖层、FX 飘字粒子等**一切 2D 画布元素**与 3D 街景对齐的真相源。
> 游戏逻辑全在 2D 世界（行走带 y 688~1294），视觉渲染在 3D 正交相机——两边逐像素
> 重合不是天然的，靠本节三条同步契约 + 地面 y 压缩公式维持。改相机/构图/行走带
> 前先读这节，否则每项 2D 画布改动都要重新逆向一遍投影链。

### 4.0 线名对照与默认缩放档（术语校准，创始人 2026-09-15）

旧文档多把"地平线"用在 1/3 那条线上——术语自本节起校准，读旧文档时按下表对号。
**默认缩放倍率 = 0.75**（CameraRig.user_zoom 默认值）：火柴人观感偏大，整体缩画面
把分界线从 1/3 压到 **1/4**（创始人 2026-09-15）；开场推镜动态读此默认值。下表
"屏幕位置"以默认档为准，zoom=1 的旧口径在括号里：

| 线 | 世界线 | 屏幕位置（默认 zoom 0.75） | 旧称/易混名 |
|---|---|---|---|
| **前后景分界线** | SKYLINE_Z=-6.73 格 ↔ 2D y≈472.6 | 屏幕下 **1/4** 线（270px）（zoom=1 时 1/3 线/720） | 旧文档"地平线"、天际线基线 |
| **新地平线**（真实地平线） | 末排背景基线（底衬远端收于此，见 §三点五） | 高于分界线（更远） | —— |
| **屏幕底沿锚线** | z_near≈18.93 格 ↔ 2D y=1294（WALK_FRONT_Y） | 屏幕底沿（不随缩放变） | —— |
| **F3 黄线** | HD-2D 图 = 前后景分界线；2D 图 = ground_y | 同分界线（世界线随缩放走） | ground_y 线 |

### 4.1 三同步契约（每帧由 Hd2dStreetMap._process 驱动）

| 轴 | 契约 | 实现点 |
|---|---|---|
| **横移 x** | 3D 相机 x（格）= CameraRig.x / 32 | `set_cam_x` |
| **缩放** | 3D 只认 user_zoom（`_cam.size = 1080·宽高比/(32·user_zoom)`，KEEP_WIDTH）；base_zoom 两侧同源（vp_h/1080） | `set_cam_zoom` |
| **垂直锚线** | CameraRig 视野下边界 = 3D 屏幕底沿地面锚线 z_near，都对应 2D 行走带 y=**1294（WALK_FRONT_Y）** | 见 4.3 |

横移+缩放两条合起来：**屏幕上 1 格 = 32·effective_zoom px，x 方向 2D/3D 仿射恒等**
（`world_to_screen` 的 x 分量不需要任何修正）。z_near = SKYLINE_Z + 33.75/(3·sinθ)
≈18.93 格由构图契约（地面占屏幕下 1/3、SKYLINE_Z 压 1/3 线=前后景分界线，见 4.0）反推，
缩放时钉死屏幕底沿。

### 4.2 压缩模型（俯角前缩）

正交相机俯角 θ=26°（TILT_DEG），yaw=0。地面纵深被压缩 **k = sinθ ≈ 0.438**
（`get_ground_squash`）；水平 x 不压缩。对行走带地面点 (x, y)：

```
正变换（世界→屏幕）：  screen_x = (x − cam2d.x)·ez + vp_w/2
                      screen_y = vp_h − (1294 − y)·k·ez        （ez = effective_zoom）
画布等价式：          地面点 (x,y) ≡ 2D 世界点 (x, remap(y)) 按 2D 相机直绘
                      remap_fx_pos(y) = 1294 − (1294 − y)·k
逆变换（屏幕→世界）：  x 按仿射逆；y = 1294 − (vp_h − screen_y)/(k·ez)
                     （map.screen_y_to_ground_y，F3 鼠标世界坐标用）
```

锚点 y=1294 压缩不变（remap 恒等），所以"屏幕底沿"上的元素直绘/remap 两可；
越深的点偏得越多（2D 直绘会比 3D 实际位置低 (1−k)≈56% 纵深距离）。

#### 4.2.1 视觉域坐标协议（唯一出口，2026-09-15 收编）

正逆两式的**数学核**收编在 `Hd2dProjection`（world 模块静态类，正逆互为精确逆，
round-trip 由 `tests/unit/test_hd2d_projection.gd` 锁死）；运行时出口是地图上的
三个方法（`MapBase` 默认恒等=2D 图，`Hd2dStreetMap` 覆写）：

| 方法 | 方向 | 用途 |
|---|---|---|
| `remap_fx_pos(pos)` | 画布域→视觉域 | 一切"画"：飘字粒子/悬浮框/选中框/提示面板的地面锚 |
| `unmap_fx_pos(pos)` | 视觉域→画布域 | 一切"判定"：屏幕点落世界坐标（先 canvas 逆变换落视觉域，再经此逆回画布域） |
| `entity_hover_rect(center, size, entity)` | Range 框→视觉域矩形 | 悬浮框/点选框选锚点（画与判定共用同一矩形=所见即所判） |

**协议铁律**：
1. 消费方一律走地图协议，**禁止手搓相机/压缩公式**（相机半程交给 viewport
   `canvas_transform` 引擎真值；曾因手搓 `(mouse−vp/2)/zoom+cam` + 直绘 origin
   导致悬浮方框悬空在角色上方 100px+、鼠标须悬到角色上方才触发——创始人
   2026-09-15 报告，即本协议收编的直接动因）。
2. 只有**地面锚点**参与压缩；**身体纵向尺寸/偏移不压缩**（billboard 直立绘制，
   俯角只压地面纵深）——悬浮框高、血条偏移、面板上提量（如城门提示 −130px）
   一律原值。
3. HD-2D 图 origin=**视觉脚线**（billboard 脚锚），悬浮框 billboard 几何 =
   底边贴视觉脚线、**高=billboard 视觉身高 `BILLBOARD_BODY_H_PX` 156**
   （130 SV px×SIZE_K 1.2；⚠ 非 Range 的 2D 全身高 277——那是髋部原点语义，
   直接搬用会高出约半个身子），宽随深度缩放（`depth_scale_at`，与
   billboard/2D rig 同源）；Range 框的 2D 局部语义（origin=髋部、框心居
   Range 节点）仅 2D 图适用。
   **白色选中框=全身包裹**（框=悬浮框同一矩形 `entity_hover_rect`，角臂画
   四角，创始人 2026-09-16"框住整个火柴人"）——选中/悬浮/点选/框选判定
   四者共用同一矩形；蓝 F3 碰撞框才贴脚下线。
4. 调用链上已有 remap 的出口（如 `FxPool.spawn_burst` 内部 remap 地面锚），
   上游传视觉域坐标前须先 `unmap_fx_pos` 逆回，防二次压缩。

### 4.3 锚线契约（最易踩的坑）

**CameraRig 不垂直滚动**：`_compute_camera_y` 永远把视野下边界钉在
`ground_y + 1080×ground_ratio`——它**不读** MapBase.ground_bottom 变量。
因此 HD-2D 图必须满足：

```
ground_y + 1080 × ground_ratio == WALK_FRONT_Y (1294)
```

`Hd2dStreetMap._ready` 强制 `ground_ratio = (WALK_FRONT_Y − ground_y)/1080`（tscn
里的静态值不作数）。这条差多少，**一切经 2D 相机投影的画布元素（F3 覆盖层、
FxLibrary 飘字粒子）就整体偏移多少×缩放**；而 3D 世界本身（角色 billboard/楼卡）
不受影响——错位只体现在"2D 画的东西 vs 3D 世界"之间，非常隐蔽。

### 4.4 F3 抽屉口径（debug_drawers.gd）

- **地面锚定物一律经 `_ground_y(map, y)`**（map 声明 remap_fx_pos 时压缩，2D 图
  原样）：地面黄/青线、资源点标记、实体状态文字、水平标尺、建筑宽度线。
- **黄线（ground_line_drawer）**：HD-2D 图画**前后景分界线**世界线（4.0 表，
  zoom=1 压屏幕下 1/3 线——创始人 2026-09-15），不再用 ground_y（2D 村图语义，
  落到街面中间）；青线 = ground_bottom = 屏幕底沿锚线不变。数据口
  `proto.get_fg_bg_boundary_y() → Hd2dStreetMap.get_fg_bg_boundary_y()`。
- **地形分行线（terrain_grid）**：HD-2D 图**不画**——32px 分行语义属于 2D 图
  底部地面条带，HD-2D 的 ground_y~ground_bottom 覆盖整个可见街面，会铺满全屏
  （创始人 2026-09-15）。
- **实体碰撞箱（entity_collider_drawer）**：HD-2D 图画**直立脚框**——底边钉在
  角色**视觉脚线**（billboard 脚锚线，见 4.5），宽=物理箱横向范围、高不压；
  物理箱中心在 origin+(8.5,130)、脚底 origin+142，按物理位直绘会低于角色
  ~62px·ez（创始人 2026-09-15：碰撞箱"比应该待的位置低好多像素"）。2D 图维持
  原中心直绘。
- **障碍箱（蓝/紫 `_draw_area_rect`）**：y0/y1 各自 remap（地面占地投影）。
  HD2DSolids 里前排建筑的形状带 `hd2d_building` meta，此抽屉**跳过**——建筑的
  显示改由下条直立包楼框承担，防双重绘制。
- **建筑直立包楼框（building_drawer HD-2D 分支）**：底=**卡底基线**（卡底贴地
  落位线，四元组 [4]）、宽=**建筑格宽**（[0][1]×32）、高=**卡可见高**（[5]，
  picture 高扣 base_cut 地下裁切）——框住楼的视觉范围（创始人 2026-09-15：
  平铺地面带的碰撞框"垂直范围不对"）；白 0.6 描边不填充。真实地面阻挡带 =
  [2][3]，由同分支的左右边界竖线表达。
- **鼠标世界坐标**：y 走 4.2 逆变换；标签钉鼠标屏幕位（世界 y 已是地面带坐标，
  不能再经 2D 投影回屏幕）。
- **建筑宽度辅助线**（2D 图 F3 版式样原样搬入，白色口径，创始人 2026-09-15）：
  - grid_drawer → HD-2D 分支 `_draw_hd2d_cell_lines`：32px 一条竖线，横纵裁在
    **建筑占地包络**内（"地面的建筑段内"，不铺到街面前段/天上），白 0.08；
  - building_drawer → HD-2D 分支：每栋建筑**左右边界竖线**（跨该栋地基纵深带），
    白 0.6；数据口 `proto.get_building_rects() → Hd2dStreetMap.get_building_rects()`，
    宽度口径=**建筑格宽**（4 格整倍数，与碰撞同源；画面宽含出檐，不用于数格）。
  - ⚠ 占地带元组是**混合口径：x=格（×32 转 px）、y=px**——与 get_solid_rects
    碰撞墙消费端同源同口径，画前先换算 x。完整元组 6 元：
    `[x0格, x1格, 带y0px, 带y1px, 卡基线y px, 卡可见高 px]`。

### 4.5 火柴人锚点与缩放链（防逆向重点）

**2D 实体几何（stickman_entity.tscn，历史口径，全逻辑一致使用）**：

- 实体 **origin = 髋部**（不是脚）：Collider（脚部物理框 83×24）中心在
  origin+(8.5, 130)、**物理脚底 = origin+142**；Hitbox（38×262.5，全身判定）
  中心 ≈ origin+(10, 5.75)；Rig 骨架原生 262px 高、脚底在 rig 空间 +131。
- 行走带钳制、AI 站位、交互判定、存档坐标全部用 origin——物理上"角色站在 P"
  指的是髋部在 P，脚在 P+142。

**HD-2D 视觉链（char_sprite_3d.gd）**：

- RigHost（2D 骨架）与 2D 接触影隐藏；每实体一个 SubViewport billboard：
  骨架按 `rig.scale=0.5` 缩到 131px 高，脚底墨迹钉在 SubViewport 第 144 行
  （FOOT_ROW，含 ~10px 圆头线墨迹修正），quad 以"**脚底落世界 y=0**"贴地落位。
- **视觉脚线 = origin 的地面线**（z=(origin.y−688)/32）——接地影、脚下四角框、
  FX 飘字粒子（remap_fx_pos）全部锚同一条线，互相严格对齐。
- 纵深缩放：`depth = lerp(0.92, 1.10, 行走带 t)` 由宿主逐帧传给
  `set_world_pos`，乘进 billboard 与接地影（Hd2dStreetMap._apply_depth_visual
  是同口径的 2D 侧实现，**当前无人调用**，属死代码——读缩放链别把它算进去）。
- 屏幕上角色高 ≈ 131 × SubViewport 像素倍率 × depth × effective_zoom
  （ez = vp_h/1080 × user_zoom(默认 0.75)）。

**已知口径（勿"修复"）**：物理脚底（origin+142）与视觉脚线（origin）相差
142 纵深 px（屏幕 ≈142·k·ez）。这是 2D 历史锚点约定，碰撞/墙/交互都吃它且
玩法自洽；视觉系全部锚视觉脚线。若要统一（origin=脚底）是牵动 AI/交互/存档的
跨模块重构，须单独立项。F3 角色箱按**视觉脚线**画（4.4），读"角色在哪"不看
物理箱位。

### 4.6 已知边界

- 战场/资源/村B 图继承 Hd2dStreetMap，契约自动生效；2D 旧图（village_map 系）
  走 MapBase 恒等协议（视觉域=画布域，见 4.2.1），行为不变。
- 3D 相机不镜像 cam2d.y（垂直取景固定）——任何"2D 相机 y 与 3D 同步"的假设
  都不成立，垂直对齐只经 4.2/4.3 的锚线+压缩，别无他路。
- DOF far 距离是相机本地量，缩放时须同步换算（set_cam_zoom 已处理，改相机勿删）。

## 五、待迁移与已知边界

- 战场/道路/守城图仍是 2D 旧图；战斗类测试 boot 在 battlefield 上。
- 设施类测试 7 套 SUSPENDED（.tscn.suspended 摘出矩阵）：待玩法设施（PlacementGrid/兵营/仓库实体）接入 HD-2D 图后在生产图重建。
- 角色 billboard 当前无武器/盾渲染（武器挂在 2D WeaponMount，随 RigHost 一起隐藏）——HD-2D 化武器渲染是独立工作项。
- 村民待业/工作行为依赖 WorldState.game_time 节律，与昼夜挂钩同源。

## 六、主街结构解剖（现状基线）

> 本节把"主街这张图由什么组成、每层摆在哪、为什么"一次讲全，是改布局/构图/背景前的必读底账。
> 依据 = `tests/dev/proto_hd2d/proto_hd2d.gd`（3D 街景本体）+ `modules/world/scripts/map/hd2d_street_map.gd`（宿主）+ `modules/world/scripts/map/city_gen.gd`（摆街数据）。
> 战场/资源图 = 同一场景的 `battlefield`/`resource_field` 开关（无墙无街的开阔野地，铺装与摆位走分支），本节只解剖主街形态。

### 6.1 坐标与相机

- 1 格 = 1 Godot 单位 = 32px。x 横向（东正），y 高度，z 纵深（朝相机为正）。
- 2D 行走带 y_px 688~1294（WALK_BACK_Y/WALK_FRONT_Y）↔ z 0~18.93，`z=(y−688)/32`；y=688 是建筑墙脚线，y=1294 同时是屏幕底沿锚线（换算契约见 §四）。
- 相机：正交、yaw 0、俯角 26°、KEEP_WIDTH，视高 = 1080/(32·user_zoom) 格，位置 (跟随 x, 11, 锚线公式反推)；远焦 DOF 挂 CameraAttributesPractical（不在 Environment）。

### 6.2 构图三钉（垂直取景的骨架）

| 钉 | 值 | 含义 |
|---|---|---|
| 屏幕底沿 | z_near = 18.93 格 | 地面占屏幕下 1/3；`set_cam_zoom` 每次缩放按此重钉，缩放不漂 |
| bg1 基线 | SKYLINE_Z = −6.73 | 第一排背景压屏幕下 1/3 线——下 1/3 归前排与街面，中 1/3 起归背景楼群 |
| bg2 基线 = 真实地平线 | far_z = −10.23（= SKYLINE_Z − 层距 3.5；创始人 2026-09-15：第三排**紧贴**第二排） | 末排楼脚；远景地面带/城墙/草地带全部收于此线 |

### 6.3 分层解剖（z 从远到近；遮挡由深度测试天然排序）

| # | 层 | z | 要点 |
|---|---|---|---|
| 1 | 程序化天空 | — | ProceduralSkyMaterial **渐变天空**（昼：天顶深蓝→地平线青白）+ **太阳盘 = 对 `_sun` 方向光的自动渲染**（右上，昼显夜隐，被楼群遮挡由深度测试天然处理，无独立节点）；**漂移云牌** = 2D 手绘云（SketchCloud）烘贴图的 Sprite3D billboard（14 朵池、风驱漂移+出带回绕、昼白/夜暗蓝，z 钉地平线身后）；昼/夜色值都在 `_apply_light` |
| 2 | 远景地面带（城内） | far_z→0.42 | **与建筑带（台面）同高 y=PLAT_H**——建筑带身后的城内地面保持台面标高一直到地平线，无"踩空"落差（创始人 2026-09-15）；城心石板（±30）/ 夯土（±30→±墙线），与道路带同材质分幅；战场/资源图维持 y=0 平铺 |
| 3 | 城外草地（野地） | far_z→46 | 墙外两侧 y=0：稀疏草土**整块贯通**（下边界→地平线不分段，创始人口径） |
| 4 | 兜底大地皮 | far_z→40 | 1200 格宽夯土，y=−0.05 压在所有分段之下，防任意缩放露底；**远端收在第二排后景基线**（=真实地平线，"地平线=第二排楼脚"，§4.0 新地平线） |
| 5 | 背景第二排 bg2（地平线补缝） | ≈−10.2 | **稀疏补缝**：只插在 bg1 露出的地平线缝隙里（一缝一栋、中心整格），紧贴 bg1，楼身站上真实地平线（站台面标高）、穿缝可见、楼顶可越前排露出；tint 最淡最冷档（空气透视）；满档远焦模糊；剪影档渲染（不投影、不进夜景窗火） |
| 6 | 背景第一排 bg1（主天际线） | −6.73 | 整排连铺钉 1/3 分界线（整格摆位、楼间缝 2~4 整格，站台面标高）；**排除过高卡**（画面高 >14 格的塔楼/教堂/宫殿不进 bg1——创始人：第二排别出现太抬高的建筑）；tint 浓一档；半档模糊（DOF 起点=分界线基线） |
| 7 | 城墙 | far_z→19.5 | ±墙线（布局半宽推导，手摆兜底 95）；厚 1.2、高 10 格（town 档 320px）；**纵深贯通到后景地平线**（兼盖住墙线两侧 0.65 台阶的断面）；门洞带 z 8~14（两段墙板夹洞 + 门柱加厚/叠涩内挑/横梁组成门楼），垛口步距 1.7 格 |
| 8 | 前排建筑 row0 | 0.45~2.4 | **中心 x 吸附整格**（宽度=格整数倍，间隙承诺由整格步距兑现）；台面带 z 0.42~1.95 垫高 PLAT_H=0.65（收窄为建筑脚下一条，不再向后延伸）；卡底贴地落位（可视墙脚=z_off）；z 错落 0.45~1.3=台面 / 2.4=落地面（barn/cottage 类）；烘焙台基带 base_cut 整段裁掉；贴地程序化接地影（z 3.3~5.9——卡内烘焙接触影在卡深度面上会被路肩盖掉，必须补才能"钉"在路肩上）；door 建筑加门前短径（楼脚→台肩→路面） |
| 9 | 街具道具 | 4.2~6.2 | 卡底留白 alpha 扫描下沉（防浮空）；点障碍碰撞（卡宽×0.85，灯笼不挡）；铁砧=露天铁匠工位（§2.7） |
| 10 | 道路带 | 1.9~46 | 行走面 y=0：城心石板 ±30 / 夯土过渡（唯一不长草带）/ 墙外草地；角色 z 同 6.1 映射 |
| 11 | 街灯 | 4.2 | 13 盏 OmniLight 暖光（x=−48 起每 8 格，铺城心 ±48，越近城墙越暗）；夜档点亮、隔盏投影 |
| 12 | 角色 billboard | 0~18.93 | 每实体一个 SubViewport billboard，写深度可被前景遮挡（§2.4） |
| 13 | 传送带/出口 | — | 宿主侧：城门内外 ±40px Area2D 竖带（全行走带，只对"朝墙走"触发，玩家走近改弹窗）；东西村口 ChunkTrigger 压地图边界内侧 96px |

所有地面贴图走**世界坐标锚定三平面 UV**（创始人 2026-09-15：前后景地面必须连续对齐）——全部地皮采样同一张全球网格，同材质跨带无缝续接、缩放全局一致；各带 tile 常量 = 该材质每张贴图跨的格数。

### 6.4 摆街数据流

- 三种来源与优先级见 §2.2。**plan 契约**：`{cell_w:32, width_cells, tier, seed, buildings[card/def/x/cells/row(0|1|2)/door/z], props[card/x/z/plat], trees}`。
- **墙线=布局半宽**（width_cells/2）、地图边界=±(半宽+30) 格——width_cells=前排自然跨度+两端墙留边 3 格，所以建筑变多 → 城市扩展 → 墙自动前移，野地资源窗随之露出。
- 消费映射：row0=前排（z 契约 0.45~1.3 台面 / 2.4 落地面直接采用）；props 直用；trees 现恒空——野外资源由宿主 resource_gen 算法（群落散布+林区梯度）撒点后 `spawn_nature_card_at` 落卡；**row1/row2 运行时不消费**（§6.7）。
- **bg1 主天际线=连续扫铺**：从前排跨度两端各收 3 格起逐张顺铺，全卡池随机（只排除附近已用卡——创始人：选卡自由度最高），**中心吸附整格 + 楼间缝 2~3 整格**（取整余数最多再 +1，实际缝 2~4 格），**排除画面高 >14 格的过高卡**（塔楼/教堂/宫殿系，过滤后池空则放开），末卡越界超 2 格收边不出墙；种子按（卡位 x, 层）确定性 → 多局一致。
- **bg2=地平线补缝**（创始人定案：后两排的职责=遮挡地平线）：算出 bg1 覆盖区间的补集（露出的地平线缝，≥1.5 格才补），逐缝稀疏插一栋——中心整格、卡身可越缝宽（越界部分被 bg1 自然遮挡）、收边不出背景跨度。

### 6.5 光照 / 昼夜 / 后处理 / 景深

- 档位：宿主按 WorldState.game_time（小时）在 6:00/19:00 切 day/night；`_apply_light` 幂等（先复位再覆盖）。
- **day = 阳光明媚高调照明**：渐变天空（天顶深蓝→地平线青白）+ 主光暖白 0.48（太阳盘右上）+ 冷天空环境 0.56（两光和≈1.0——卡是烘焙图，光照别双计）+ 冷补光 0.12 抬暗部（明暗比≈1.15:1）；雾关；tonemap LINEAR（filmic/aces 会把烘焙卡压灰）。
- **night**：月光蓝 0.06 + 环境 0.17 + 薄雾 + 窗火 glow 1.15 + 灯笼 1.1 + 角色冷蓝 tint/暖 add（灯池感）。
- 后处理 post_hd2d（layer 100）：移轴 0（**主场景零模糊=全局口径**，层次全交远焦 DOF）、暗角 0.28、曝光 1.14、饱和 1.18、lift/gain 微暖。
- DOF 只开远焦：far 距离钉**世界线**（天际线基线−DOF_FAR_START_AHEAD，随 set_cam_zoom 重算防缩放漂移）；bg1 半档、bg2 满档（amount 0.20、过渡 20）；`--flat=1` 出辅助线核对图时关。

### 6.6 卡渲染要点（card.gdshader）

- albedo 亮度差分伪法线（relief 4.5）→ 平面卡吃真 3D 光照；depth_prepass_alpha 消矩形影；alpha_cut 0.4；窗火 glow 按昼夜档 0/1.15。
- base_cut = anchor 纵深分量/卡高（0.13~0.24）：整段裁掉烘焙台基带，墙脚线=可视底=落地线（"地基上一圈浅灰方形"的处置）。
- 背景剪影档：独立材质不注册窗火表 + 关阴影投射（免得卡影投在无物可接的空地）+ 按层 tint 距离染色。

### 6.7 已知偏差与待收线（改这块之前先看）

- **CityGen plan.row1/row2 运行时不消费**（背景实为扫铺随机补满）：要么运行时吃 plan 背景、要么生成器停排背景，二选一收线，避免两套背景逻辑漂移。
