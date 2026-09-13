# 建筑生成管线 v3（写实 PBR / Blender）——进度与交接

> **一句话**：推翻旧 `building_gen`，自建"代码建模 → 渲染 → PNG + 元数据"的建筑生成管线。v2（Godot 2D 手绘）因材质天花板被创始人废弃，**现行 v3 = Blender 3D + PBR 材质 + 真实光照**（与 `tools/icon_pipeline` 同构的生产纪律）。
> 设计文档：`docs/技术/架构/建筑生成管线v3-写实PBR.md`（**§8 修订决议、§9 品控结论 —— 当前最重要输入**）
> 参考图：`stick-world/assets/_raw/建筑/smithy.png`（铁匠铺 Lv1~4，创始人给的风格与造型目标）
> 分支 `agent/building-pipeline-v2`（名字沿用，实际做 v3），worktree `.temp/building-pipeline-v2`。

---

## 〇、创始人诉求与反馈台账（新会话必读；改任何东西前先对齐这一节）

### 0.1 启动诉求（第一条指令，原文要点）

> "由你自行设计一套**笔触手绘风格化参数化建筑生成管线**，覆盖各种类型的建筑，用代码/程序化方式建模多种建筑单体，**以正面视角绘制**，技术栈和实现细节你定，**项目原来的建筑管线完全不用管，我准备推翻，只需要在意建筑宽度范围限制就可以**。"

- 唯一沿用的旧约束：**建筑宽度 3~16 格**（1 格 = 32px；出处 `docs/技术/架构/建筑模块化设计.md:510`）。
- 后续演进（见 0.2）已把"手绘"改为"写实 PBR"，但"程序化建模 + 正面视角 + 推翻旧管线 + 宽度整数倍"这四条一直有效。

### 0.2 逐条反馈与落实台账（按时间顺序）

| # | 创始人反馈（要点） | 落实 | 状态 |
|---|---|---|---|
| 1 | 给了参考图 `smithy.png`（铁匠铺 Lv1~4）："你还是有参考生成吧" | 全库色板/材质/造型以该图为基线；铁匠铺做成四级 | ✔ |
| 2 | "别就生成这两张啊，发挥想象力制造一个中世纪欧洲城市" | 建筑谱系扩到 22~25 种（街屋/工坊/公共/田园）+ 城市街景全景 | ✔ 但 6 号反馈后风格推翻重做 |
| 3 | 单层城市（街景一排，不前后堆叠） | 街景改单排 + 城墙背景 | ✔ |
| 4 | 建筑边缘不要硬截断 | 底对齐地平线 + 接地阴影；不再前后叠排 | ✔ |
| 5 | 线条细、细节多、要显高分辨率 | 墨线细化 0.78×、渲染倍率 2x→4x（v2 时期） | ✔（v3 由 PBR 取代） |
| 6 | 质感远不如参考图：稻草要"一根根单像素笔触"、砖要 3D 材质球级做旧、地面草坪重做 | v2 重做纹理层（单像素草茎/做旧砖/草坪）；**仍判定不足 → 转向 v3 PBR** | ✔ 已转向 |
| 7 | 城市要功能区、边缘负责城防、中心市政厅要好看、边缘城墙高一点 | 城市布局器（分区权重/城墙/广场/天际线） | ✔ 数据可用，观感待改造 |
| 8 | "几根柱子那种草棚没了吗？" | `shelter` 柱撑草棚（v2/v3 都在谱系里） | ✔ |
| 9 | "为什么会出现现代款的棚子？" | 市集摊红白条纹棚 → 中世纪麻布棚 | ✔ |
| 10 | 城市背景应是高耸围墙（高到屏幕 2/3），左右两侧也是围墙 | v2 街景做"围墙中的城市"；v3 由 city_layout 的城墙体系承担 | ✔ 待 v3 渲染 |
| 11 | 建筑高度/城市设置/材质设计要"适当看一下文档" | 查得火柴人身高 130px、层数上限（稻草1/木板2/石头3/砖4层）、城墙 64/128/192 | ✔ 已作为硬规范 |
| 12 | 要根据城市规模生成城市（算法） | `city_layout.py` 四规模档（hamlet/village/town/city） | ✔ |
| 13 | 透视：参考图那种木头顶房子的透视要用上 | 参考图拆解（3/4 视 + 大面积屋面）→ 先偏航后改微俯视（见 #19） | ✔ 已修正 |
| 14 | 建筑要留开口，方便功能建筑放进去；材质与功能分离 | meta 输出 barrier/front_wall/workslots；功能=模块、外观=材质的正交设计 | ✔ |
| 15 | 高度比例别失调（看火柴人身高）；有单体天生更高 | 比例锚 130px；塔/教堂单列竖向体量 | ✔ |
| 16 | 组合形态：一层石头+二层草棚合法、A/C 桥接、外楼梯、灯塔、风车磨坊 | 做过 stacked/bridge/stairs/lighthouse/windmill（v2）；v3 由 agent 重做 | ◐ 进行中 |
| 17 | 铁匠铺草棚必须有铁砧火炉，其他类建筑同理 | 炉/砧/桶/凳；后续要求炉火自发光 | ◐ 火光待做 |
| 18 | **"一个个都什么观感啊！太丑了，别手绘风了，写实风吧"** —— 质疑为何 PBR 材质水平差、门高/墙纹理/长宽比都把握不好、不动用城市设计与游戏美术知识；要求"**仔细写层层复杂的设计文档**、用**成熟的游戏生产工作流**、**逐个环节反复品控**" | **管线转向 v3（Blender + PBR）**；写九章规范文档；建立"环节门禁 + 派审查员打回"的品控流程；大量使用子 agent | ✔ 已建立 |
| 19 | "**建筑是微俯视的**" + "**截图直接给我看**，别麻烦我启动游戏" | 视角确认；此后每轮直接贴图 | ✔ |
| 20 | "何意味，这不是**侧视角 2D 微俯视游戏**吗？" | **废除水平偏航 12°**，改**纯正面 + 俯角 20° 微俯视**（横版卷轴里建筑正面朝观众） | ✔ |
| 21 | "建筑为啥都这个高，**头重脚轻**，**距离还这么远**，我幻想是**一大堆宽房子**，好多个**单位宽度的一二三层建筑**" | 屋顶 rise 从墙高 80~95% 压到 ~50%；街排间距 120→28px；火柴人移到建筑前缘；新增 16 格宽档 + 三层联排（agent 在研） | ✔ 主体已改 |
| 22 | "还有一些**特殊单体建筑**，比如**风车、大教堂**之类的" | 派 agent 实现：rowhouse(3层)/windmill/cathedral/tower/gatehouse/lighthouse | ✔ |
| 23 | "**层高要符合现实**啊，长宽比 1:0.85 是何意味？是挑高太高了吗？" | 废除"宽:总高"口径，改**米制换算规范**（§8.7）：1px≈1.31cm、1 格≈0.42m；单层檐高 200~207px、两层 400~413、窗台 69、窗高 92~100；**病因是门占层高 85%（现实 74%）** | ✔ 规范已改，数值调整中 |

### 0.3 当前有效的硬约束（覆盖一切旧口径）

1. **宽度**：房屋类宽度 = **单位宽度 4 格（128px）的整数倍**（4/8/12/16 格）；小物件（井/摊/城墙段）例外。
2. **视角**：**纯正面 + 俯角 20° 微俯视**（2D 侧视微俯视游戏；**禁止水平偏航**）。
   > 注：参考图 `smithy.png` 的原始生成提示词写的是「相机正对物体的平行投影，**无透视，无俯仰角度，无斜视**」——即参考图本身是**零俯角**的。我们仍取 20° 俯角，是因为零俯角下**坡屋面会被压成一条线**（看不到大面积屋面），而这正是创始人反复念叨的"参考图那种木头顶房子的透视"。20° 是"保住屋面可见面积"与"仍是侧视游戏"之间的取舍点。**城市总览图**可另开到 ~34°（读出行深），但那是配图，不是游戏内视角。
3. **比例（米制）**：门高 153px(2.0m)；单层檐高 200~207px(2.6~2.7m)；两层檐高 400~413(5.2~5.4m)；窗台 69(0.9m)；窗高 92~100(1.2~1.3m)；屋顶高 ≈ 檐高 × 0.5。
   > 换算基准：**1 世界单位 ≈ 1.31cm；1 格 = 32 单位 = 0.42m；火柴人 130 单位 = 1.70m**。Builder 的 UV 约定是 **1 个 UV tile = 1 格 = 0.42m**，材质里任何 feature 的尺寸都要按这个换算（这是 texel density 纪律的唯一基准）。
4. **出檐** = 建筑宽 × 18~23%。
5. **风格**：写实 PBR 材质 + 真实光照，造型风格化（不与矢量火柴人冲突）；**禁止 2D 手绘笔触路线**。
6. **流程**：设计文档先行；每环节产出必须过门禁 + 派审查员（玩家/美术视角）打回；大量使用子 agent 并逐轮把关。
7. **交付**：每轮把关键图**直接贴给创始人**，不要让他去开文件或启动游戏。
8. **道具是立面的一部分**：参考图里道具贡献约 1/3 画面信息量；空立面在游戏尺寸下必读作"秃"。道具走 `props.py` + `dress()`，不进建筑本体。

---

## 一、试错史：v2（2D 手绘）为何废弃 —— 教训，不要重走

| 轮次 | 做了什么 | 结果 |
|---|---|---|
| v2-1 | Godot 2D 绘制域：抖动墨线 + cel 分档 + 程序化纹理（茅草/砖/石/木/草坪），开间参数化，22~25 种谱系 | 结构成立但观感"简笔" |
| v2-2 | 按创始人要求重做纹理（单像素草茎、做旧砖多尺寸缺角、草坪草簇、石板路），4x 渲染 | 质感提升，但**缩到游戏尺寸即塌** |
| v2-3 | 围墙城市街景（高墙/塔楼/箭窗/扶壁/分区/规模分级） | 布局可读；风格仍被否 |
| — | 关键 bug 记录：`Image.fill_rect` 是**直接覆盖**不混合（半透明叠加必须 `blend_rect`）；纹理 alpha 合成曾写错导致整库发黑 | 已修，v3 不再涉及 |

**废弃判定（创始人）**：2D 程序化绘制模拟材质有天花板，"你生成 PBR 材质那么牛逼（指 Blender 管线），这游戏里屋顶稻草和墙壁砖头咋都水平这么烂"。
**可复用遗产**：建筑谱系清单、宽度约束、meta 契约、城市分级思路、验收工具形态（拼页/街景/确定性）。
**v2 代码保留**：`stick-world/tools/building_pipeline/`（不再演进，作历史对照）。

---

## 二、当前状态（v3：材质库 / 几何库 / 布局器 / **道具层** / **成图探针** / **自动校验** —— **全部落地并经 2026-09-13 凌晨五批次迭代，待创始人观感验收**）

### 已建成

| 模块 | 文件 | 状态 |
|---|---|---|
| 规范文档 | `docs/技术/架构/建筑生成管线v3-写实PBR.md` | 九章 + §8 修订决议（含 §8.7 米制）+ §9 品控结论 |
| 材质库 **v3.1（已重建）** | `tools/blender_buildings/materials.py` | **36 个 key**（26 结构 + 10 道具追加 cloth_red/blue/ochre、wicker、clay、produce、produce_root、fish、bread、dye_bath），全库改为「现实尺寸 → UV」标定（`M_PER_UV = 0.42`，1 UV = 1 格 = 42cm；入口 `uv_m/uv_cm/uv_mm`，`audit(verbose=True)` 打印每材质换算后的现实特征尺寸）。茅草改**逐根草茎索引**建模（2.8cm 茎宽 + 27cm 层高 + 分撮明暗），铁改低粗糙度大锤打棱面，抹灰暖米白禁锈褐斑，石块大块 + 深砂浆缝。**修掉 `cavity` 硬 bug**（以前 `get()` 返回 None → 回退浅色 → 所有窗洞发亮）。新增 `water/lamp(自发光)/straw/rope/sack/glass_win/wattle/shingle/log_wall/ground/grass_tuft/foliage/vine`。`get()` 为任意已注册 key 的通用入口；`reset_cache()` + `_alive()` 失效探测（救 `read_factory_settings` 坑）。集成校验：buildings 装配名**零纯色回退**；跨进程逐位一致。**2026-09-13 做旧 + 逐体色变**：AGE 表 13 key（近地 35~45cm 溅泥/苔藓 V 向渐入 + 垂直雨渍 ≤6% + 木质大尺度褪色，水平面法线门控）；OBJ_VAR 14 个结构 key 用 Object Info Random 逐体色偏（抹灰 ±3%/木 ±8%/陶瓦 ±6%，跨进程确定性不变，道具系 10 key 不做）；陶瓦/石板逐片双维随机、茅草加 50cm 斑驳；全库校准（暖石 0.68/抹灰暖米白）；**25% 门禁 agent 自评 PASS**（`pbr_mat2_true25.png`） |
| 建筑几何库 | `tools/blender_buildings/buildings.py` | **19 种装配器 × 宽度档**：house/townhouse/barn/smithy1 + rowhouse(3 层)/windmill/cathedral/tower/gatehouse/lighthouse + **cottage/tavern/bakery/shop/guildhall/hayloft/smithy2~4**（2026-09-13，差异点≥两项肉眼可辨）；cathedral 新增 8 格小教堂档（供 chapel 映射）。模块库另有拱券/玫瑰窗/尖拱窗/垛口/隅石/扶壁/锥顶/风车叶/灯室。**屋顶结构二轮**：檐口断面厚度（草顶 16~24 卷唇/瓦木顶封檐板+瓦条）、檐下 AO 暗带（遮挡线下置）、山墙檩条端头（下探到 20° 俯视可见）、茅草檐缘草束+脊穗。**立面修正**：`WINDOW_SPEC` 窗表 10 档（窗台 69/窗高 92~100/同立面 ≤2 型/上下层差异化，全部装配器接入）、wall_panel 去重修掉二层透空、烟囱全部落地+穿屋面泛水裙+基座石裙。`SPEC_COLOR` 补 `cavity/lamp/water/straw/rope/shadow_ao` 回退（`lamp` 进 `EMISSIVE` 强度 2.6），接触阴影三级已压深（shadow_near 0.20） |
| **道具层** | `tools/blender_buildings/props.py` | **60 件道具**（33 基础 + 27 市集/民生扩充：market_stall/awning/hanging_sign/fish_table/chicken_coop(含 4 鸡)/cart_loaded 等）+ `dress()` 门口避让式挂载调度 + `shop`/`market` 两套新配方（8 套既有配方尾部各增强 2~3 件）；`GAME_SCALE=1.45` 解决"现实尺寸道具缩到游戏尺寸不可辨" |
| **自动校验** | `tools/blender_buildings/validate.py` | 六项检查（def 覆盖/地块合规/装配适配/窗规格 lint/纹素密度纪律/道具挂载回归），~7 秒零渲染，退出码 0/1；现状：①②④⑤⑥ PASS，③ 仅剩 barn16/smithy1w6 两条已知基线 FAIL、宽度超 lot=0 |
| 城市布局器 | `tools/blender_buildings/city_layout.py` | 4 档确定性布局 + 平面图 + 天际线 + 断言；**DEFS 表已列 24 种建筑** |
| 探针 | `probe_materials.py` / `probe_buildings.py`（规范自检）<br>`probe_materials_v2.py`（**新材质样片**：材质 × 平面/球/立方体，每格并列 100% 与**物理 25%** 双缩略）<br>`probe_props.py` / `probe_props3.py`（道具，后者 `PROPS3_FOCUS=名` 出单件高清）<br>`probe_delivery.py`（交付图：总图/街景/1:1 游戏尺寸）<br>`probe_city_scene.py`（**城市成图**：布局器数据 → 渲染；well/market_stall 走 `PROP_LOTS` 道具聚簇路径）<br>`probe_roof2 / probe_facade / probe_d3a / probe_mat3`（屋顶/立面/新装配器/材质做旧专项特写） | 均可复跑 |

### 关键产物（`stick-world/temp/`，2026-09-13 最新一轮，已用新材质全量重渲）
- `pbr_mat2_probe.png`（26 材质样片，100% + 物理 25% 双缩略）、`pbr_mat2_true25.png`（整表 25% 出厂门禁真值）
- `pbr_sheet_2x.png`（全部 def×宽度档总图）、`pbr_c_<def>_w<N>.png`（15 个单体特写）
- `pbr_game_1x.png`（**1 px/单位 = 游戏内真实大小**的街排；判断"材质/道具会不会糊"只看这张）、`pbr_street_2x.png`
- `pbr_city_town_top.png`（**城镇总览，俯角 34° + 行距拉伸**，21 栋 + 城墙，最好的一张）、`pbr_city_town.png`（临街 20° 游戏内视角）、`pbr_city_village.png` + 各自 `.json` 摆放清单
- `pbr_props.png`（道具总览条）、`pbr_props_{smithy,house,barn}.png`（前场实景）
- `city_plan_{hamlet,village,town,city}.png|.json`（城市平面数据）
- **2026-09-13 五批次新增**：`pbr_city_{hamlet,village,town,city}.png` + `_2x` + `.json`（四档城市全图，20° 游戏视角）+ `pbr_city_town_top.png`（34° 总览，12/16/22/32 栋）；`pbr_props3_strip.png`（60 件总览条）/`pbr_props3_{shop,market}.png`；`pbr_roof2_{eave,gable,ridge}.png`、`pbr_facade_{win,chimney,gable}.png`、`pbr_d3a_<def>.png`（9 栋新装配器）、`pbr_mat3_*.png`（做旧/逐体色变对照）、`pbr_buildings_v2.png`（29 栋总对比图）

### 已知落差（诚实清单）
- 布局器 **24 种 def ↔ 装配器 19 种**：shelter/stable/hayloft 仍兜底映射 barn、church→cathedral、chapel→cathedral[8]、well/market_stall→PROP_LOTS 道具聚簇。**副作用：barn 系深色木板墙连排读作"黑盒子"**（barn 本体墙面明度所致）。
- 道具层尚未接进建筑本体（目前由探针在渲染时并置，`props.dress()` 独立对象）。
- 布局器 band 余量/院坝不渲染 → hamlet/village 有成片裸地读作空 lot。
- hamlet/village 城墙仅 140/220px、矮于建筑，围城感 town 档才成立（规范 §4.1 与 §3.3 既有冲突，待创始人裁）。
- 做旧仍偏克制（抹灰墙脚仅 −12% 明度，远看偏干净）；布篷/搭布是平板布无垂坠褶皱；鱼摊的鱼在游戏尺寸下读法弱；灯笼/炉火无 bloom 光晕（Blender 5.2 合成器 `node_tree` 不可用）。
- 25% 门禁 agent 自评 PASS，但 canvas/sack/rope/wattle 在 25% 下仍偏"同族纤维面"、靠颜色区分（19px/m 物理极限），终判留给人眼。
- check_spec 既有基线 FAIL（house16、townhouse12/16、barn16、smithy1w6）未清，属旧口径遗留，未扩大。

---

## 三、下一步（按品控优先级，2026-09-13 凌晨五批次后更新）

1. **barn 系独立化**：shelter/stable/hayloft 出各自装配器（或先调 barn 墙面明度），消"黑盒子连排"；church/well/market_stall 独立化可选。
2. **城市观感二轮**：空 lot 院坝内容物（柴堆/菜园/板车/箱桶，消裸地）；hamlet/village 城墙高度问题提请创始人裁定（§4.1 vs §3.3 冲突）。
3. **质感补刀**：做旧加强（墙脚更脏）；布料几何垂坠；鱼摊读法；灯笼光晕替代方案（自发光贴片/辉光 sprite）。
4. **道具层接入装配器/入库烘焙流程**：`dress()` 下沉到装配器调用；烘焙产物入库 `assets/buildings/gen/`。
5. **运行时接入**（批次 5）：def_id 映射、`modules/building_gen/api.gd` 重定向、内饰图。
6. **待创始人观感验收**：屋顶结构二轮、立面修正、材质做旧+逐体色变、60 件道具、19 装配器、四档城市成图（§二 关键产物，直接看图）。

---

## 四、跑法

```bash
BLENDER="/f/SteamLibrary/steamapps/common/Blender/blender.exe"
cd "F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
"$BLENDER" -b --factory-startup -P probe_materials.py     # 材质样片
"$BLENDER" -b --factory-startup -P probe_buildings.py     # 建筑单体规范自检图
"$BLENDER" -b --factory-startup -P probe_props.py         # 道具层
"$BLENDER" -b --factory-startup -P probe_delivery.py      # 交付图（DELIVERY_FAST=1 只出街景）
"$BLENDER" -b --factory-startup -P validate.py             # 六项自动校验（~7 秒，退出码 0/1）
"$BLENDER" -b --factory-startup -P probe_props3.py         # 60 件道具（PROPS3_FOCUS=名 单件高清）
"$BLENDER" -b --factory-startup -P probe_d3a.py            # 9 新装配器特写（D3A_ONLY=名 单栋）
CITY_TIERS=town CITY_ROWS=0,1,2 CITY_TILT=34 \
  "$BLENDER" -b --factory-startup -P probe_city_scene.py  # 城市成图
python probe_city_plan.py                                  # 城市平面图（纯 Python + PIL）
```

---

## 五、新会话恢复指引

1. 读本文档（**§0 台账必读**）+ 设计文档 §8/§9。
2. `git worktree list` 确认 `.temp/building-pipeline-v2`；缺则 `git worktree add .temp/building-pipeline-v2 agent/building-pipeline-v2`。
3. 跑几个 probe 确认环境（§四）；按 §三 优先级推进。
4. 规矩：改任何东西前先对齐 §0.3；每环节产出必须派审查员打回；每轮把图直接贴给创始人。
5. **worktree 里的 v2 脏文件（不是本任务的工作）**：`git status` 会看到 11 个 `stick-world/tools/building_pipeline/`（v2）的未提交改动 + 未跟踪的 `comps_opt.gd`/`dev/`——那是 v2 时代一个子 agent 的半成品，v2 已废弃，**可以直接丢**：
   `git checkout -- stick-world/tools/building_pipeline && rm -rf stick-world/tools/building_pipeline/comps_opt.gd stick-world/tools/building_pipeline/dev`（收线清理时做即可）。
6. 参考图 `stick-world/assets/_raw/建筑/smithy.png` 在主工作区（raw 资源未入库，worktree 里是拷贝）；若 worktree 重建后缺图，从主工作区拷一份。

---

## 六、踩坑记录（探针/渲染层，省得再踩一遍）

| 坑 | 现象 | 正解 |
|---|---|---|
| **中途 `bpy.ops.wm.read_factory_settings`** | 材质/节点组被清掉，而 `buildings._CACHE` 与 materials 内部缓存仍持旧引用 → `_external_material` 校验失败**静默回退 `_flat_pbr` 纯色**，纹理整片消失（会误判成"材质做坏了"） | 一张场景只 `read_factory_settings` **一次**；多图之间只删网格对象（`probe_props.wipe()`），并同步清材质缓存 |
| **`dict.setdefault(k, maker())`** | 默认参数先求值 → 每次都新建材质，越积越多 | 写成显式 `if k not in d: d[k] = maker()` |
| **布局器 `baseline_y` 方向** | 布局器里 y 越大越靠**前**（南），本管线世界坐标 **-Y = 正前**，直接用会把城墙摆到建筑前面糊住整条街 | 世界 y = `-baseline_y` |
| **建筑以原点为中心 vs 前墙面落地线** | 装配器进深向 ±Y 各半，而布局器给的是"前墙面落地线" | 先实测本地 `measure(ob)["y"][0]`，再算平移量对齐前墙面 |
| **多行城市在 20° 俯角下行距不足** | 行距仅建筑进深（160~190 单位），折算到屏幕垂直仅 55~65 单位，后行被前行整个盖住 | 渲染层给每深一行额外后推 `ROW_STRETCH`（2.5D 常规美术手段，不动布局数据）；总览图另开 34° 俯角 |
| **道具"现实尺寸"缩到游戏尺寸不可辨** | 现实 0.55m 的木桶在 130px 火柴人的世界里只有 40px 高 | 挂载统一 `GAME_SCALE`（1.45×）；建模仍按现实尺寸，便于反算 |
| **尖锥形道具被读成"帐篷"** | 草垛/花盆用圆锥 → 游戏尺寸下读成金色小帐篷 | 草垛改"下缓锥 + 上急锥"的矮胖圆顶；花盆改直筒厚唇 |
| **`Geometry > Position` 世界单位跨场景差 32 倍** | 交付场景 1 单位=1px@1:1，样片探针 1 单位=1 格；同一句"世界 Z 0.35m"一处看不见、一处糊满整墙 | 依赖世界尺寸的材质特征（做旧溅泥等）一律走 **UV 的 V 向**（两种场景下 V 都=世界 Z/32）+ 法线门控水平面 |
| **city_layout 塔高断言误触** | 余量窄（村档 ~116px）时随机抽塔极差仅 2px 判"全同高"；`frac` 可达 1.0 使 `round` 顶到 cap 触发严格 `<` 断言 | 黄金比轮转分层 + 每趟相位（不动每塔 rng 取样次数，保下游确定性）+ 显式压 1px |
