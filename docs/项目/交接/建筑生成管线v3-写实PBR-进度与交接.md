# 建筑生成管线 v3（写实 PBR / Blender）——进度与交接

> **一句话**：推翻旧 `building_gen`，自建"代码建模 → 渲染 → PNG + 元数据"的建筑生成管线。v2（Godot 2D 手绘）因材质天花板被创始人废弃，**现行 v3 = Blender 3D + PBR 材质 + 真实光照**（与 `tools/icon_pipeline` 同构的生产纪律）。
> 设计文档：`docs/技术/架构/建筑管线/建筑生成管线v3-写实PBR.md`（**§8 修订决议、§9 品控结论 —— 当前最重要输入**）
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
9. **观感基准**：**明亮干净（阳光高调）**——AGE 做旧层（溅泥/苔/雨渍/日照褪色）整体下线（`materials.py` `AGE_OFF=True`，表保留登记）；OBJ_VAR 逐体色变保留。实机读不出"岁月感"、只剩脏感（详见 §三 决策 9）。

---

## 七、第十轮（2026-09-14~15）：聚落等级链批次 —— 现行进行中，新会话从本节恢复

### 7.0 本轮创始人诉求台账（接 §〇 续编）

| # | 创始人反馈（要点） | 落实 | 状态 |
|---|---|---|---|
| 24 | 剑与魔法世界要有多种级别聚落（帝国首都/行省首府/大城市/大村镇/大村落/小村落+过渡态）、各级行政建筑、各家族建筑层数宽度随级别上升、兵营/铁匠铺/马厩/赌场/商铺/驿站/研究所、路灯花坛等街道家具、商铺五花八门（花店等，玩家可购买属玩法侧）、**不要被提示词局限发挥想象力** | 任务书 `docs/技术/架构/建筑管线/聚落等级与建筑分级.md`（提案/待定）+ 本轮全部批次 | ◐ 进行中 |
| 25 | **窗口制纠正**：不是每种建筑都有四级阶梯——铁匠铺上限 3 级；有些建筑是下限（只在低档存在）；**全级别只给科研/物流这类系统级** | 任务书第 3 节已改为每族「级别窗口」表（全级 5 族：行政/科研/物流/驿站/城防；3 级 6 族；2 级 1 族；上限低与单件族；smithy1~4 映射 3 级） | ✔ `0eed96c4` |
| 26 | 硬边/无倒角/贴图边缘硬切导致廉价感，要品控；查业界方案与 CS2 做法 | `docs/技术/架构/建筑管线/美术品控-硬边与材质边缘.md`（棱线高光门禁已进装配器验收线） | ✔（父会话已落地倒角体系） |

### 7.1 已完成并入库（main，直接提交无 worktree）

| 批次 | 内容 | 提交 |
|---|---|---|
| 等级任务书 | 八档等级链/行政阶梯五级/9 族 27 档矩阵/缺口 13 装配器（含窗口制修订） | `7b336ad9`、`0eed96c4` |
| 街道家具 | 18 件（石灯/铁灯/壁灯、花坛×4、长椅×2、喷泉×2、公告板、旗杆、雕像基座、里程碑、路标、马槽、水龙头、桶栽）+ `dress_street(W,seed,…)` 沿街节奏（灯 8~12 格错位/组距 10~16/喷泉留广场位） | `d3352336` |
| 行政阶梯 6 件 | council_hall w8 / town_hall w12,16 / governor_palace w16（**剪影 882 压过 cathedral 786**）/ imperial_palace w16（**1068 全档顶点**）/ belfry w4,6 / mint w12,16；阶梯同框图+棱线门禁图 | `daa7d2f5` |
| 行政内景 5 套 | 议事厅/政厅门厅/总督会客厅/**王座厅**（机制图代表）/铸币厂；内景总量 **34 套**，前后两层对齐实测 34/34（`pbr_int_alignment.json`） | `0ca381f2` |
| 批 2 装配器 8 件 | 驿站族 waystation 6,8 / inn_post 12,16 / coach_house 12,16；赌场 gambling_den 8,12 / grand_casino 16；academy 12,16；observatory 8；flower_shop 8,12（提案/待定窗口）。**装配器总量 41** | `ee3f77fa` |

### 7.2 布局器八档重建（**已完成并入库 `9c988f6a`**）

`city_layout.py`/`probe_city_scene.py`/`validate.py` 重写完毕：TIER_SPECS 八档显式参数表（hamlet 80格/10-12栋/围栏140 … capital 256格/40-48栋/砖墙520/总督府882 … metropolis 384格/60-72栋/砖墙640/宫殿1068）；**旧四档×5 seed 零漂移实测（lots/props/walls 逐字节一致）**；行政槽 `admin_slots` 全档写入（town/city 由 guildhall 充当、新四档实装 role="admin"）；批 2 八装配器接线进新四档池（town/city 仅 DEFS 登记、接线待后续——窗口与漂移预算冲突，见 agent 遗留点②）；belfry 走 specials 只增通道（为保"教堂守最高点"只声明 4 格档）；validate 6/6 绿（44 def 0 缺口、78 装配对 0 新 FAIL）。**遗留四点**：①法师塔登记 560 但实测含水晶尖顶约 1030px 仍压过教堂（既有限象，capital/metropolis 靠宫殿压住）；②批 2 "town 起/city 起"窗口与既有档接线未完成；③6 格砖钟楼变体（656px 越位）进不了布局；④八档验收图在 `F:\VSCode\game-2\temp\city8tier\final\`（`pbr_city_<八档>.png` + capital/metropolis 34° 总览 `_top`，大图 23~31MB 需压缩预览，`prev_*.png` 为缩版）。

### 7.3 下一步（按序）

1. 收尾 7.2（八档全图 + capital/metropolis 34° 总览验收）；
2. **HD-2D 主街/城市渲染接入**：新装配器烘卡入 `proto_hd2d` 卡库、行政阶梯进主街天际线、`dress_street` 接主街家具摆位（读 `docs/技术/架构/建筑管线/HD-2D街景系统.md`——运行时真相源）。**注意**：并行会话已在做"主街接初始城市生成器"（main `045aa7c9`，数量定长/中心向两侧/非对称分区/背景实时生成），接线前先看该提交避免重复造轮子；
3. 批 2 的 8 件内景（驿站/赌场/学院/花店…，接 `interiors.py` 既有 34 套体系）；
4. 窗口矩阵剩余待定项提创始人翻（赌场起始档、花店窗口、民居按档选型、windmill/hayloft 消亡档）；
5. 收线：**文档侧已完成（2026-09-15）**——资产清单入库（`docs/技术/架构/建筑管线/建筑资产清单.md`，ddc531f5）、主规范 §十 流程总览+过时口径就地修正（6ecb136f）、管线 10 篇文档独立成夹 `docs/技术/架构/建筑管线/`（含导读 README，f8276d77）、AGENTS.md 导航与登记全部刷新；上面 2~4 项留给下一会话。

### 7.4 本轮关键决策（新会话勿翻案，除非创始人开口）

- **窗口制**：分级=每族窗口［出现档,消亡档］+级数上限，全级仅 5 族（行政/科研/物流/驿站/城防）；smithy1~4→3 级映射；basilica 取消；皇家学院/皇家驿馆/官仓暂不立项。
- **帝国首都**：走"参数化布局+专属建筑池"并入八档，不另起独立管线（任务书两问之一，待创始人最终确认）。
- **帝国宫殿**：16 格单卡极致版，多卡拼接留后续（两问之二，同上）。
- **specials 只增通道**：特殊投放（belfry/mint/observatory）不进核心 lots，保零漂移语义。
- 玩家进店购买属玩法侧，只登记「提案/待定」（任务书第四节），不当已确认设定。

### 7.5 本轮验收图（完整绝对路径）

`F:\VSCode\game-2\stick-world\temp\` 根：`pbr_props5_street.png`（40 格街道家具节奏实景）、`pbr_props5_strip.png`；`pbr_admin_ladder.png`（行政阶梯四件同框）、`pbr_admin_<def>.png`×6、`pbr_admin_edge.png`（棱线门禁）；`pbr_int_layers.png`（王座厅前/后分层）、`pbr_int_sheet2x.png`（34 套总览）；`pbr_b2x_family_post.png`（驿站族）、`pbr_b2x_family_casino.png`、`pbr_b2x_<def>_w<N>.png`×14、`pbr_b2x_edge.png`。

### 7.7 主街街具四连修（2026-09-15，代码已提交、文档行随共享未提交批）

创始人反馈：道路上很多道具浮空、分布离谱、同类物品重复乱放、超级小灯被当路灯摆。四个症状四个根因，全部在 GD 侧（参考实现 props.py dress_street 本身没问题）：

- **浮空（双根因）**：①道具 plat 语义从参考脚本移植起就是错的——路肩台面带只到 z 1.95（建筑脚下细带；楼后地面同标高连片到地平线），z=4.3~5.0 全是路面，带 `plat=true` 即悬空 0.65 格——CityGen 街具 z 全面对齐 + `_spawn_prop` 加 z≥2 强制回路面守卫；②卡底留白下沉公式 rows/32×S 偏小 16 倍（烘卡 px 是建模 px 的 2 倍），"浮空摆件"修复从未生效——`_card_bottom_pad` 按卡元数据密度换算，自然物卡首次接上。
- **小灯当路灯**：灯卡选中查建筑卡表（cards.json 无道具卡）→ 永远落灯笼兜底；改查 props.json 卡宽表（`prop_names()` 值升级为卡宽，兼容旧 has/is_empty 用法）。
- **复读乱放**：家具组固定循环 + 组内件同点抖动互叠 → 每侧 furniture_n 槽均分街宽、组内件按卡宽肩并肩、洗牌袋轮转；路标/里程碑只守街口。
- **城市每进城重排（意外收获）**：`zones.shuffle()`/`defs.shuffle()` 吃全局随机源不吃种子——"确定性种子→多局一致"契约实际是破的；改 `_shuffle_rng`（Fisher-Yates 走 rng），实测同种子两次生成逐字节一致。
- **杂物占格（创始人定案，两轮纠偏后）**：与建筑同 Z 的杂物默认**占水平格**——CityGen §3.5 把仓储/生产六件（crate/barrel/sack_stack、haystack/log_pile/trough）塞入所属分区侧序列的随机位置段，随建筑整格排布推挤（z=1.0 台面、plat，渲染端卡底落地+接地影落在台面）；**占格宽向上取整到整数格**；序列里小概率（12%）塞**一格空位**（占格不出卡的刻意留白）；不设纵向格——路面道具沿用各自的默认 z 标记。

### 7.8 建筑间杂物

**基础机制已落 CityGen**（创始人定案）：与建筑同 Z 的杂物占水平格、塞入随机位置段随建筑排布（见 §7.7 杂物占格条）——纵向格子不设，路面道具沿用各自默认 z 标记。本节留作**加密度/选卡的参考**：示例场景（八档 `probe_city_scene.py`）的 richer 配方 = **跟建筑 def 走的前场配方**（`props.py DRESS` 表，聚簇占建筑门口地块，宽度≤地块）+ **道具型地块**（`PROP_LOTS`：井台组、市集摊组，整组占格）。`sack_stack`（麻袋堆）为标志性件，挂四处：风车 / 城门·军营 / 商铺 / 仓库·面包房（市集配方仓储主读）。已烘卡可直接用的约 20 种（house/barrel·log_pile·haystack·pot·basket，barn/cart·trough，smithy/anvil·tools_rack·grindstone·barrel_stand，shop/hanging_sign·produce_baskets，行政/flower_box·market_table，gatehouse/banner·crate 等）；炼金/图书馆系配方全部未烘，city 档才需要。**摆法规则（创始人定）**：偶尔空一格，不每缝都填；门口悬挂照明勿用 lantern（小手灯），用 hanging_sign/wall_sconce 或补烘挂壁灯卡。

**（2026-09-15 晚更新）本节口径已被 §7.9 覆盖**：杂物扩全带、z 按 footprint 推导、空位两档、占格宽度量换 footprint——以 §7.9 为准。

验证：报错自检干净；八档不变量探针全绿（未烘卡/台面带外 plat/灯笼当路灯/同深叠放四项，探针 `stick-world/temp/check_citygen.gd` 一次性不入库）。契约落 `HD-2D街景系统.md` §6.4。**并行协同**：隔壁会话同窗口期修灯卡选中（同诊断）+ 夜版贴图 + `_card_base_cut` 像素扫描 + 分区杂物堆，改动同文件已合流互认；其 walk-band/F3 批次（§7.6）与本批互不依赖。

---


### 7.6 F3 显示反馈轮（2026-09-15，未提交、与上一会话 F3 修复同批）

创始人反馈：①缩放条 75% 的数字应显示 100%；②碰撞箱位置显示"还是不对、差了很多"。**根因实测（headless 探针 `stick-world/temp/hd2d_probe/`，gitignored）**：F3 地面锚定物绘制位 vs 3D `unproject` 真值误差 0.1px——画的全是对的，错在**实体 Y 行走带钳制**：沿用 2D 图口径（origin=髋、脚=origin+foot_offset → 约束面内收脚距）且深端吃 MapBase 默认 `ground_y=720`，而 HD-2D 的视觉脚线=origin（billboard 脚锚），角色能走到 y≈589（墙脚线外 ~3 格）被楼卡遮挡"消失"、青箱跟着锚进楼里——"青箱与蓝带不对应"的真根因。

修复（4 文件）：`zoom_bar.gd` 显示口径 `user_zoom÷0.75×100`（ZOOM_BASE 常量，默认档=100%，滑块/滚轮域不变）；`MapBase` 虚方法 `_origin_space_walk_band()`（2D 图 false 维持脚部口径）+ `Hd2dStreetMap` 覆写 true 且 `ground_y=WALK_BACK_Y=688` + `StickmanEntity` 钳制按口径分流（`_ground_constraints_origin_space`）——HD-2D 下 origin∈[688,1294]。契约已落 `HD-2D街景系统.md` §4.5。

- **创始人裁决**：楼底疑似被砍/白框 14px 级残差（楼卡立 0.65 格台面、画框按路面投影）**暂不管**，白框保持现状。
- **残余读法（已落档 §4.5）**：被道具蓝带挡停瞬间青箱底悬在蓝带远沿上 ~29×缩放 px——同源 142px 2D 历史锚点，消除须"origin=脚底统一"立项（牵动 AI/交互/存档）。
- **测试**：41/49——7 失败=SUSPENDED 套件空跑（已登记）、1=cross_map_travel 双失败（审计 2026-09-14 同签名），零新增回归；报错自检干净。
- **并行协同**：隔壁 AI 同期在修"蓝箱对齐包"（疑点①道具带与求解器一致性——已核同源：`_prop_solids` 在 `_spawn_prop` 内用最终落位生成；②meta 跳过点保留，白框承担建筑显示）。**给它的关键移交：蓝带/青箱绘制链无需再改，改钳制口径才是对症**。

**第二轮（同日，footprint 反馈，未提交）**：创始人让烘焙管线给每卡导出 `footprint`=[宽格,深格]（cards.json 50/50），并反馈①建筑碰撞箱显示比楼低很多②紫箱不见了③主控框对、悬浮框比角色高很多④青箱待复验。落实：

1. **碰撞体积接真实 footprint**：`_building_solid_rect` 从 `[688, 基线+44]`（前端比楼脚多伸 1.4 格、后端退到街心 z=0——"比楼低很多"的由来）改为墙脚基线向后量深格（探针实证：cottage 带 [707.8, 764.8]=1.78 格×32 ✓）。碰撞墙/紫带/宽度辅助线同源消费。
2. **紫占地带恢复**（F3 building_drawer HD-2D 分支，PassageBarrier 紫口径）——回答"紫色碰撞箱是不是不显示了"：HD-2D 无 2D PassageBarrier 节点，紫框此前被白框顶替。
3. **占地元组扩 8 元**：[6][7]=占位格宽（白包楼框维持创始人已认可口径）、[0][1]=真实墙脚（紫带/辅助线/碰撞）——两口径并存防白框变窄破坏"包楼"语义。
4. **选中/悬浮四角框修锚**（selection_system.gd）：HD-2D 下 origin 经 `remap_fx_pos` 锚视觉脚线——原 2D 直绘比角色高 (1−k)×纵深（y=1000 时 ≈124px@0.75）。主控框走 3D 脚下框本就正确，未动。
5. 文档：`HD-2D街景系统.md` §4.4 重写（8 元元组/紫带/双宽度口径/选中框锚点）。⚠ **规范纠偏（创始人）**：CHANGELOG 只在 GitHub 发版时更新，本批误加的两段已撤、批次记录归交接档——规矩已入 AGENTS.md 文档写作规范。

**第三轮（同日，碰撞行为+前景可行走反馈，未提交）**：创始人反馈①角色碰撞箱碰到别的箱子不停止移动、与表现不符②走不到黄线（两楼之间也被提前拦下）。裁定：**F3=碰撞真相视图，所有箱子都画在真实碰撞位**（"绘制的箱子移动到碰撞箱位置"——此前画在视觉脚线的版本会穿过蓝带停不住）；**黄线以下就是可行走地面范围**（立项起即如此），碰撞箱顶到黄线才停、不留玩法余量；玩家走上台面该抬升。落实：

1. **青箱画回物理位**（debug_drawers entity_collider HD-2D 分支）：箱中心经 remap_fx_pos 压投影域、宽高不压——角色被挡停时青箱恰好压在对方带上，"碰上即停"逐像素可读。物理脚箱（origin+foot_offset）不动。
2. **深端行走界钉黄线**：proto 新增 `DEEP_WALK_Y`（黄线+2px 防与 bg1 卡共面闪烁，非玩法余量）；`Hd2dStreetMap._walk_deep_y()` 虚方法取值（须 _hd 就绪后），`_ready` 重排；城墙碰撞带拉通全深、出口触发器纵深跨整个可行走域。**战场图覆写 `_walk_deep_y` 保旧带 688**（战斗阵型按旧域调的）。
3. **台面/台后地面抬升**：proto `get_ground_lift_world(x,z)`（z<路肩前缘 1.95 且墙内 → PLAT_H，战场/资源图/墙外恒 0）+ `get_ground_lift_px`（×32×cosθ）；char_sprite_3d `set_world_pos` 加 ground_lift（卡/接地影/脚下框/劳作条整体抬）；宿主 `_sync_character_render` 传抬升、`remap_fx_pos` 扣同源抬升——青箱/FX/选中框/黄线自动贴合抬升地面。副作用：建筑白框底的 18.7×缩放 px 残差归零（探针实测全绿，含台面上角色脚 0.1px）。
4. 文档：§4.2 remap 公式加抬升项、§4.4 实体碰撞箱口径、§4.5 行走带深端+已知口径重写（F3=碰撞真相定案入档）。测试 41/49 基线不变、自检干净。

**第四轮（同日，footprint 原点字段，未提交）**：三套烘卡脚本（blender_proto/bake_props/bake_nature）新增 `footprint_off(ob)` 导出 `[dx格,dz格]`——dx=占地中心相对**卡面（剪影）中心**（与取景同源 shape_points/cam_axes）、dz=占地中心相对**墙脚基线**（引擎卡底贴地钉的"卡可视底边内容行"的地面等效 y=min(v)/sin(tilt)），正 dz 朝相机，兜底/异常回退 [0,0]；引擎 `_building_solid_rect` 消费（带中心 x=槽位中心+dx、带=[基线+(dz∓fd/2)×32]），**旧 JSON 无字段默认 [0,−fd/2] 精确退化回旧口径**——三张样卡（cottage_w6/house_w16/cathedral_w16）python 复算逐项相等，重烘前行为不变；重烘后地脚不居中的卡（如 house_w16 地脚偏左 ~192 模型 px）按实测原点精确落位（道具/自然物仅导出、引擎消费端本轮未接）。自检：py_compile×3 过、报错自检净、测试 41/8 基线不变；文档同步 `HD-2D街景系统.md` §4.4+§2.1 字段表。**重烘命令（需 Blender，本机 PATH 无 blender，待创始人/隔壁会话跑）**：
`"F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py`（建筑卡）／`"F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_props.py`（道具卡）／`"F:/SteamLibrary/steamapps/common/Blender/blender.exe" -b --factory-startup -P stick-world/tests/dev/proto_hd2d/bake_nature.py`（自然物卡）

**第五轮（同日，紫带范围两连修，未提交；Blender 实际在 F:/SteamLibrary/steamapps/common/Blender/，建筑卡已由本会话重烘两次）**：创始人指认①紫带比白框窄②紫带是扁片。落实：
1. **宽度口径=占位槽宽**（=白包楼框宽；墙脚实测对 house_w16 只有 3.9 格/槽位 16 格，"比白框还窄"读作错误）——[0][1] 与 [6][7] 归一，footprint_off 的 dx 退出带位计算（字段仍导出备用）。
2. **深度口径=全模型占地深**：三份烘卡脚本新增 `footprint_full(ob)` 导出（不过滤高度的整楼包围盒、含屋顶出檐——墙脚贴地实测对大屋顶建筑只有 1~3 格窄条；坑：`B.measure` 返回 (min,max) 元组对非跨度，除 32 直接 TypeError，改为顶点自算）。引擎深度=max(全深, 2格)、后沿封顶深端行走界。重烘实测：barn_w12 全深 11.92 格（墙脚仅 1.25）、house_w16 全深 14.75 格。
3. **工具教训**：烘卡命令管道接 `tail -N` 会吞光诊断（第二轮重烘看似成功实则 TypeError 半途而废）——重烘日志必须全量落盘看（本轮起 `> stick-world/temp/proto25d_rebake.log`）。
4. tex 快照同步（temp→tex 50/50 含 footprint_full）；自检净；测试 41/49 基线不变；文档 §2.1 字段表补 footprint_full 行、§4.4 口径更新。

### 7.9 带语义定案轮（2026-09-15 晚，未提交）

创始人反馈串（同日多轮对齐）：①杂物不该只堆在仓储/生产带，可以覆盖任何带，且每张卡有自己的纵深（footprint 元数据）；②长椅等街具仍与建筑重合、灯柱/路牌这类高件别立在门前与杂物前；③主街千篇一律全是一层；④**带语义定案：Z 在台面带位置的东西一律"按建筑算"**，街具一律不上台面；⑤空位偶尔两格宽；⑥独轮车暂不上街；⑦喷泉这类广场件可以放建筑区；⑧盆/筐这类超级小件不该虚占格子；⑨杂物也要像建筑一样有双黄线。落实（全在 `city_gen.gd` + `proto_hd2d.gd`）：

1. **带语义（总口径）**：台面/建筑带只留"按建筑算"的东西——建筑 + 杂物占格件 + 贴楼功能小件（铁砧/磨刀石=铁匠工位、旗帜=行政楼前，属建筑语义不动）；灯柱/长椅组/路牌/里程碑全部铺**路面带**（远缘 5.8 / 近缘 7.0 两档纵深错位，原远侧台面位 z1.25~1.85 全撤——长椅叠楼的根源）；喷泉留市集广场位（建筑区，Founder 豁免件）。
2. **杂物扩全带**（§3.5 重写）：五条分区带各 1~2 件（craft 桶/箱/工具架、market 桶/筐、living 桶/盆/花箱；storage/production 原清单保留；**独轮车除名**），洗牌袋确定性取件；杂物 z 按卡自身 footprint 纵深推导（clamp 0.42~1.75），不再统一 1.0。
3. **空位两档**：9% 一格 + 3% 两格（原 12% 一格），占格不出卡的刻意留白。
4. **高件避让**：`_avoid_spans()` ±0.5 步进扫描，灯柱/喷泉/路标/里程碑 x 避让门脸建筑（DOOR_DEFS）与杂物占格段，避不开跳过该盏。**坑**：避让合法落点被 `add_prop` 的 `snappedf(0.1)` 反推进占格段 0.0125 格（city 档 lamp@-33.8 压 tavern 左缘实测）——修法=候选先对齐 0.1 再测（测的值=最终值）。
5. **前排 2 层卡配额**（§3.7，治千篇一律一层楼）：townlet 2 / town 5 / burgh 8 / city 9 / capital 14 / metropolis 18（hamlet/village 村貌不上配额）；白名单九卡（tavern/townhouse/rowhouse/inn_post/coach_house/academy/mint/barracks/library）、每 def ≤2 张从区队列复制补位；第 2 步去重对白名单放宽到 2 张。分区池按级别窗口调整：townlet 市场+tavern（窗口"过渡档提前解锁"本就登记）、town 居住+rowhouse/生产+inn_post、burgh 市场+rowhouse/生产+inn_post、city 市场+flower_shop/仓储+inn_post（rowhouse Lv2=town 起、inn Lv2=town 起、专精店种=town 起，均守 §三窗口表）。
6. **占格宽度量修正**（创始人指正"盆啊啥的超级小东西也占格子"）：占格宽改按 props.json **footprint[0]（真实地面占地宽）**向上取整，弃用画面宽（含透视外扩，盆 1.47 格画面→虚占 2 格）——实测盆 2→1、筐 3→2、花箱 3→2、柴堆 6→5；`prop_footprints()` 返回 [宽,纵深] 两维；卡库缺失兜底 footprint [2.0,1.5]→2 格（空 prop_set 不再爆宽，village 276→239 格）。
7. **杂物进 F3 双黄线**：CityGen 杂物道具带 `occ_cells`（占格宽）出产物；proto_hd2d `_place_props` 收进 `_clutter_occ` 并入 `get_building_rects()`——F3 建筑辅助线给杂物画左右边界双黄线+紫占地带+逐格浅线（4 元组 rect，无直立包楼框），与建筑同口径；碰撞仍走 `_prop_solids` 点障碍。
8. 文档：`HD-2D街景系统.md` props z/plat 契约段 + 层位表第 9 行同步（带语义/footprint 占格/occ_cells/避让 snap 口径）。

验证：五档探针全绿（杂物↔建筑互斥违例 0、台面带违例 0、高件压脸 0；配额 town 6/5、city 10/9、capital 15/14、metropolis 20/18 全达标）；报错自检干净；unit 63/63。**并行协同**：本节与 §7.7/7.8（前会话街具四连修+杂物占格首版）同文件接力，其"12% 一格空位 / z=1.0 / 画面宽取整"口径已被本节覆盖；工作区另有 §7.6 walk-band/F3 未提交批与本批同文件不同区域，提交时注意分批。

**微调轮（2026-09-16 晨，未提交）——创始人拍板"小件全撤、常识重摆"**：反馈=好多小物件（盆之类）摆在建筑区没美感、前排物件互相穿模。落实：

1. **随机街具组轮转整系统删除**（FURNITURE_GROUPS/组槽/洗牌袋）——随机配方是美感杀手；`furniture` 字段暂留 TIERS 不用。
2. **常识摆法**（每件道具必须有功能理由，无理由不上街）：井=市集聚点、摊/桌/果篮=市集两翼（摊+果篮右翼、桌左翼，锚点+避让自组织）、长椅=井旁对置（village 起，聚点语义）、喷泉=镇起广场位（+9/−9 择空，hamlet/village 没喷泉）、铁砧/磨刀石=铁匠工位、旗帜=行政楼前、路标/里程碑=街口侧翼（避让预算 8 防被城门段挤没）、灯=沿街照明、杂物=仓储/生产带占格件（盆/筐/花箱小件全撤出建筑带）。
3. **道具↔道具同带互斥登记表**（实测旧版同带叠对 28~62/城：market_stall 画面宽 8.85 格与井/桌/果篮全叠、街具组压井压灯）：每件道具落位登记 [x0,x1,z]，后放者 `_avoid_spans` 避让 z 差<PROP_EXCL_BAND(1.5 格) 的已放件，≥1.5=前后遮挡合法保留层次；避不开跳过该件；放置顺序=主件先于填充件（井→椅→摊桌→喷泉→灯→街口件）。**坑**：井旁椅曾错用 market_stall 落点作锚（长椅全被摊的画面宽挤死）+ 喷泉排 20 盏灯后同带无窗——顺序修正后全出。
4. 道具量收敛：village 49→32、city 113→57（同带穿模对 28~62→**0**）。
5. 文档：`HD-2D街景系统.md` props 契约段重写（常识摆法清单/同带互斥阈值/组删除）。验证：五档探针（穿模 0/互斥 0/必件无缺：井摊桌果篮椅喷泉路标里程碑各就位）+ 自检干净（首跑 4 错=并行会话日志残留，复扫净）+ unit 63/63。

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

## 二、当前状态（v3：材质 / 几何 / 道具 / **内景** / **自然物** / **地面体系** / **昼夜分层** / **HD-2D 原型** / 自动校验 —— **2026-09-13 全天约 19 批次迭代完毕，待创始人观感验收**）

### 已建成

| 模块 | 文件 | 状态 |
|---|---|---|
| 规范文档 | `docs/技术/架构/建筑管线/建筑生成管线v3-写实PBR.md` | 九章 + §8 修订决议（§8.7 米制）+ §9 品控结论 |
| **今日新增文档** | `建筑室内结构.md`（A/B 类室内+z 序契约+31 def 矩阵）<br>`2.5D与HD-2D可行性.md`（原型档案+实测+分阶段方案；图在 `图/2.5d-proto/` 6 张已入库）<br>`美术品控-硬边与材质边缘.md`（真倒角/边缘磨损/trim 交接/棱线高光门禁，附业界调研）<br>`docs/项目/交接/建筑管线v3-GDD资产候选.md`（**提案/待定**） | 均已提交 |
| 材质库 | `materials.py` | **64 key**：26 基础 → 54（玻璃系 `stained_glass/glass_lead/glass_clear/glass_bottle/crystal/rune_glow/bronze/patina` + 城市地面 10）→ 57（`glow_water/parchment/leather`）→ 64（**`glazing_win` 真透明窗玻璃（隔窗见内景已实证，alpha≈0.075/峰 0.16）**、`bark/leaf_card(alpha 叶卡)/rock/copper_ore/gold_ore/grass_band`）。做旧 AGE 13 key + 逐体色变 OBJ_VAR（跨进程确定）。`glazing_win` 进 ALPHA_KEYS(BLENDED)+透射阴影；`stained_glass`/`glass_lead` 语义收窄"仅 cathedral/chapel"。回归：新旧逐像素 max diff=1/255；25% 门禁自评 PASS |
| 建筑几何库 | `buildings.py` | **27 种装配器**（19 + 第三轮 8：mage_tower/alchemy/library/barracks/warehouse/stable/shelter 独立化 + hayloft；barn 黑盒子已消）。屋顶二轮（檐口断面/檐下 AO/檩条/草束）+ 立面修正（WINDOW_SPEC 窗表/二层补墙/烟囱落地泛水）。**比例审计已校正**：mage_tower 塔身 1×4.6m→2×3.66m、锥顶比 0.85→0.72；stable/hayloft 底层抬到 2.07/2.12m；带门层统一 2.62m（门占 75%）；`STOREY_H_BAND` 196~212；townhouse16 由 FAIL 转 PASS |
| 道具层 | `props.py` | **94 件**（60 + 34 玻璃/魔法/宗教/军政：彩窗板/蒸馏器/符文碑/祭坛/兵器架/蜂箱…）+ 14 套 DRESS 配方（含 alchemy/chapel/library）；挂墙件贴**真实前墙面**（`wall_y/wall_depth/reserved`，cathedral 彩窗板悬空已修）；`MOUNT_SCALE` 小件补偿；炼金坊前场避让 |
| **内景层** | `interiors.py` | **29 def 全覆盖**（7+19+3 别名），每套后墙+地板+楼板+功能家具+暖光；`_back/_front` 两层带 alpha 交付，**像素对齐 29/29 ≤0.5px**（复现游戏 `WallFront.modulate.a=0.3` 机制）；`clip_to_walls()` 修 GAME_SCALE 越界。cottage/shelter 判定需 12 格档；gatehouse=门洞通道 |
| **自然物** | `nature.py` + `field_dist.py` | 16 类（阔叶/窄冠/针叶/枯树/树桩/灌木/芦苇/草丛/蘑菇群/水晶簇/金铜铁矿露头/矿脉带/碎石/巨岩），已换新材质（bark/alpha 叶卡/rock/ore/crystal/grass_band）；三级密度场分布（簇包络×子团×开天窗，实测离散指数 2.7 vs 均匀≈0） |
| **地面体系** | `ground_tiles.py` | **分段链**：3 带（肩/缘/道）× 3 区带（center 石板大理石/mid 旧砖碎石/edge 夯土砾石）× 5 变体，可链式拼接；**规模包含映射**（村=[edge] 子集、镇=mid+edge、城=全档，`_manifest.json`）；**动态建造件**（落地环/门前径/位掩码过渡边角件，跟 PlacementGrid）；decal 8 种带撒布参数；新旧过渡段 3；多尺度补丁（0.4/0.8/1.6m）+ 去竖纹返工。硬指标：周期残差 ~e-13、光照中性 0/57 违规、夜晚调制 -44% |
| **昼夜分层** | `daynight.py` | 发光白名单（按节点 Emission 真值：flat_fire/flat_ember/stained_glass/glass_lead/rune_glow/crystal）；glow 层干净分离（非黑像素 1.72% 全为发光件）；**合成公式已标定：夜 = albedo×tint(0.038,0.049,0.092) + glow×1.0，MAE 0.011**；窗户引擎侧抽 42% 随机亮 |
| **HD-2D 原型** | `stick-world/tests/dev/proto_25d/`、`proto_hd2d/` | **八方旅人式验证通过**：2D 火柴人（真 StickmanRig）经 SubViewport(2x+MSAA4x) 贴相机对齐 billboard；建筑不透明通道写深度/角色透明通道测深度=零成本遮挡；性能唯一成本=后处理 ≈3.3ms；阳光高调（雾零，mean 0.440 无死黑无过曝）。**场景重排进行中**（地面语义/间距/非线性模糊/稀疏封底） |
| 自动校验 | `validate.py` | 六项（def 覆盖/地块/装配/窗规格/纹素/道具挂载），~7 秒；①②④⑤⑥ PASS |
| 城市布局器 | `city_layout.py` | 4 档确定性布局；DEFS 24 种（**新 8 def 未入表，待补**） |
| 探针 | `probe_buildings/props/props3/props4/delivery/city_scene/roof2/facade/d3a/d3b/mat3/mat4/mat5/scale/interiors/nature/ground/daynight` + `probe_city_plan` | 均可复跑（§四） |

### 关键产物（`stick-world/temp/`）
- 材质：`pbr_mat2/mat3/mat4/mat5_*.png`（样片/做旧对照/玻璃地面/透明实证与自然物）
- 建筑：`pbr_buildings_v2.png`、`pbr_b2_*`、`pbr_d3a/d3b_<def>.png`、`pbr_roof2_*`、`pbr_facade_*`、**`pbr_scale_sheet.png`（45 档带 0.5m 刻度尺与偏差标注）** + `pbr_scale_<def>.png`×45
- 道具：`pbr_props{,3,4}_*.png`（94 件总览/实景/挂墙修正对照）
- 内景：`pbr_int_<def>_{back,front}.png`×29、`pbr_int_{sheet2x,layers,window}.png`
- 自然：`pbr_nature_{strip,forest,ore}.png`、`pbr_field_dist.png`
- 地面：`pbr_ground_{segments,chain_demo,pieces,grid_demo,decals,street,night}.png` + `ground_tiles/`（分段/件/decal + `_manifest.json`）
- 昼夜：`pbr_dn_{day,night,glow,layers}.png`
- 城市：`pbr_city_{hamlet,village,town,city}[_2x|_top].png` + `.json`、`city_plan_*`
- HD-2D：`proto25d_*.png`、`proto_hd2d/hd2d_{a,b,c,d,e}_*.png`（入库副本在 `docs/技术/架构/图/2.5d-proto/`）

### 已知落差（诚实清单）
- **比例根因待裁**：20° 俯角把"进深×sin20°"计入屏幕高度（house12 屋顶屏占≈墙高 79%），是"头重脚轻"主因——相机为硬约束未动几何；门宽 0.60~0.76m 与规范 0.9~1.0m 冲突（§8.7 与 §8.3 自相矛盾）；窗宽 0.53~1.15m 待 WINDOW_SPEC 统一；瞭望塔 1.83m/段不达标（改高动城档天际线）。
- 内景：gatehouse 偏暗；cottage/shelter 进深不足家具贴墙一排；塔类层间梯读作长斜板；cathedral 中殿净深 2.6~4m 长椅只 2 排；manor/stone_warehouse/placeholder 运行时 def 未出图。
- 自然物：针叶树冠仍实心锥台（叶卡会上洞）；bark 辨识度一般；叶卡偶见直线边。
- HD-2D：2D 角色与 3D 光照非逐像素耦合（tint 近似）；角色 `depth_draw_never` 在高深度背景前有 DOF 误糊风险；批渲染路径未解算（矢量路径可用）。
- 城市布局器新 8 def（mage_tower/alchemy/library/barracks/warehouse/stable/shelter/hayloft 独立档）未入 `city_layout.DEFS`；validate 的 ASM_TIER_ATTR 待补 stable/shelter。
- 做旧偏克制；布篷无垂坠；灯笼无 bloom（Blender 5.2 合成器不可用）；25% 门禁 canvas/sack/rope/wattle 同族靠色分。
- check_spec 基线 FAIL：house16、townhouse12、barn16、smithy1w6（旧口径遗留，未扩大）。

---

## 三、下一步（2026-09-13 晚更新）

1. ~~HD-2D 场景重排~~ **已完成（`1bb80d47`，见 `2.5D与HD-2D可行性.md` §八）**：地面=整体可走区+建筑挤占、间距 1~3 格、三层稀疏背景逐层模糊（1.6/4/9/12px）、28 道具卡、站位抖动；**遗留决策：零偏航下回退建筑无侧翼**（接受 or 放开 ±几度，待创始人裁）。
2. **地面返工验收**（agent 进行中）：多尺度补丁/去竖纹/预览 alpha，重出四张图。
3. ~~烘焙导出脚本 + 游戏集成规范~~ **已存档（创始人裁决 2026-09-14：烘焙 2D sprite 线与 HD-2D 线互斥，暂不双线推）**：成果保留（`bake_export.py` + 接入规范文档 + 60 档四件套，`a7a2b501`/`1bc273b8`），作为"若最终不走 HD-2D"的备用路线存档。
4. **city_layout 补 8 新 def** + validate ASM_TIER_ATTR 对齐 + 分段地面接入 `probe_city_scene` 全档重渲。
5. **比例遗留提请创始人裁定**：门宽/窗宽规范冲突、瞭望塔段高、（可选）俯角 vs 屋顶屏占。
6. **README 素材库画廊**（创始人点名：挑图复制+索引，体现工作量）。
7. **待创始人观感验收**：比例审计 45 档标注图、真透明窗玻璃实证、内景 29 def、自然物、地面分段体系、昼夜分层、HD-2D 原型。

### 今日关键决策（创始人拍板，2026-09-13）

1. **地面语义**：屏幕下方约 1/3 = **整体可行走区域**；建筑建成后**挤占**该区域一块（落地箱 96px 挡住），**无预留路肩带**；落地裙边/门前小径只属于建筑（=动态建造件）。
2. **地面体系**：分段链 + 区带（center/mid/edge）+ **规模包含**（村=edge 子集/镇=mid+edge/城=全档）+ decal 撒布 + 动态建造件（位掩码过渡）。禁止整条死长条与运行时 autotile。
3. **玻璃口径**：窗玻璃=真透明（`glazing_win`，透视内景）；**彩色玻璃仅 cathedral/chapel**。
4. **室内**：A 类剖视内景全 def 默认；B 类可进入只给地标（提案 4 个待裁）；"窗后内景常驻 vs 交互区门控"待裁（已登记待办）。
5. **HD-2D**：八方旅人式可行且已原型验证；火柴人卡**正对相机**（与建筑卡同取向）；**阳光高调**（雾零、暖主冷补、抬黑、高饱和）；景深=**非线性逐层**、只糊远景、主体全锐；后景**多层稀疏**共同盖住地平线+远山贴图。
6. **硬边品控**：真倒角+边缘磨损（倒角面属性标记，EEVEE 无 Bevel 节点）+ trim 过渡；新增"棱线高光检查图/1x 可见性/交接缝扫描"三门禁。
7. **建筑站位**：约 1/3 回退 0.5~1.5 格+门前小短路、约 15% 凸前、其余贴线；禁止完美直线排。
8. **HD-2D 布局回退（2026-09-14 创始人裁决，推翻本节决策 1 的「无预留路肩带」在该场景的口径）**：`tests/dev/proto_hd2d` 整体回退到初版 `6908836d`——**前排一列建筑 + 远处单排虚化背景（两排制）**、建筑基线靠后、前场地面（路肩观感）必须可见；撤销此后整条改造链：背景近距双层（`e1f8966c`）→ 地面分带重做 → 路肩 3D 石条（`9ed1ae9c`）→ 建筑抬台（`090b6853`）。改动保留在 git 历史，重做版截图备份于 `temp/proto_hd2d/_redo_backup/`。
9. **观感基准 = 明亮干净，做旧层下线（2026-09-14 创始人裁决）**：对比 `_v_pbr_c_cathedral_w16.png`（无做旧）与 `pbr_c_cathedral_w16.png`（挂做旧）拍板——明亮干净的"阳光明媚"为准；实机小尺寸下做旧层读不出"岁月感"、只剩脏感，纯副作用。落地：`tools/blender_buildings/materials.py` 设 `AGE_OFF=True`（`_age_wall` 一律直通，AGE 参数表保留作登记），**OBJ_VAR 逐体色变保留**（治"所有建筑一个色"，不产生脏感）；建筑卡/道具卡全量重烘后游戏端 `temp/` 与工程内 `tex/` 副本同步更新；自然物不挂做旧、不受影响；地面色调与光照不在本裁决范围内。

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

### 待办（HD-2D 样板街，2026-09-14 凌晨移交）

- **基线**：初版 `6908836d`（交接档「今日关键决策」决策 8），已回退对齐。
- **已做**：人行道台面（PBR 高清 albedo+法线，`src/<key>_alb/_nrm`，注意**文件名要去 `_128` 后缀**）从地平线铺到台肩；台肩镶边长石 = **方形截面（高=深=台面高）**、顶面与台面齐平（`c9d9483f`）；建筑抬到台面上、离台肩远近错开。
- **待办**：①`--save-scene` 生成的编辑器场景会把运行时纹理**内嵌**（395MB，已删）——正路是把所需贴图（约 10 余张：band_shoulder/road/kerb 的 _alb/_nrm + 卡片图）复制进 `res://tests/dev/proto_hd2d/tex/`，`_tex_abs` 优先用 res:// 加载，再重新存场景（体积即正常）；②可选 `--freecam` 自由视角模式（创始人想亲眼转视角看石条上表面）。

### HD-2D 样板街 · 下一会话第一优先级（创始人 2026-09-14 定案）

**目标设计**
1. **真实地平线 = 最后一排（第三层背景）建筑的根部**：天空与地面的交界直接压在末排建筑底边——不留"天上露出地面"/>
2. **三层背景、后层插前层缝**：算法计算前排建筑的**缝隙区间**，第二层建筑摆在第一层的缝隙上、第三层插第二层的缝隙；三层叠加把地平线遮死（不是随手摆）
3. **全排建筑吸附整格**：每排建筑的 x 对齐整数格、宽度取整格、排间缝隙也按整格推进（现状 `FRONT_ROW`/`SKYLINE_ROW` 的 x 是手写小数，既没对齐也导致后排互压）

**具体改法**
- `FRONT_ROW`：x 圆整到整格；相邻建筑按"整格宽 + 0/1 格缝"推进
- 缝隙算法：对每排求已占用格区间 → 取补集（缝隙）→ 每段缝隙生成一栋可覆盖它的背景建筑（宽度 ≥ 缝宽，取档位表里最小的够用档）
- 三层 z：主排 z≈0.42；bg1/bg2/bg3 依次后退（建议 −4 / −8 / −12，最后一排 = 地平线所在）
- **地平线对齐**：地面平面（rammed earth 底衬）的远端 z 收到与第三层背景根部同值 → 天空/地面交界正好压在末排底边
- 俯角保持 26°（`TILT_DEG`）；相机 `CAM_CY=11`、`CAM_DIST=40`、正交视宽 74 格（25.9px/格）
- 台面贴图边缘色块：台面改**分段拼接**（用 `ground_tiles` 分段资产、缝按变体错开），替代单张大平面 UV 重复
- 辅助线保留：整格网格（1 格细线/4 格亮线）+ 建筑左右边界紫线（用于核对吸附整格后的宽度与缝隙）

**验收**：①每排建筑左右边界落在网格线上 ②三层背景逐层覆盖前层缝隙、无自发重叠 ③末排底边与天空交界重合（无裸地/无悬空）④台面无杂色块

### HD-2D 样板街当前状态与遗留（2026-09-14 上午更新）

**当前基线**：`proto_hd2d.gd/.tscn`，场景为**运行时代码搭建**（编辑器直接打开 `.tscn` 看不到内容，须运行或 `--save-scene` 导出）。

**创始人裁决（2026-09-14 上午）**：台面材质**不换**；前排密度**已够不动**；第二排**加密**；第二排下边界压**屏幕 1/3 线**（=屏幕三等分靠下的那条线，33.3% 从底）并在该处画横辅助线；第三排也画下边缘辅助线；插缝层次保持（第二排插第一排缝、第三排插第二排缝并遮地平线），但**各层楼间留缝不贴死**。

**本轮实施（已完成，待观感验收）**
- **修三层背景崩塌 bug**：前排 0 缝铺满后「前层占用补集」插缝算法输入为空 → bg1 一张不出、bg2 误把全屏当缝铺在 z≈-14、bg3 又空——画面上只剩一排错位的远层楼。这是此前「背景不对」的根源。
- **新插缝算法**：bg1 自由铺（楼+2~3.5 格缝）；bg2/bg3 **吸附进前层的缝隙**（每条缝中心放楼、本层自身保持 ≥1 格缝、放不下的缝放弃）；末层 >9.8 格残余空缺补楼（近贴 0.6 格缝）遮死地平线。缝按**卡画面宽**算（含出檐，cottage_w6 画面 9.1 格 ≠ 6 格建筑）；选卡用 `_pick_card`（放得下才用）。
- **构图**：`SKYLINE_Z=-6.73`（基线压屏幕下 1/3 线，26° 投影公式解得），层距 `BG_LAYER_GAP=6` 格（屏幕每层差 ≈6.3%）；前排楼身挡 bg1 根部、bg1 从前排楼顶上方露出（高低咬合）；末层基线=真实地平线（底衬远端同步收到实测卡基线）；三层距离染色 `BG_TINTS`（越远越淡越冷）。
- **辅助线**：橙=屏幕 1/3 线（bg1 基线+第一排屏幕区上边界，一线两用）；绿=末层基线（地平线）。z 取实测卡基线中位数（anchor 深度偏移各卡不同，`_spawn_bg_card` 实测）。
- **新参数 `--flat=1`**：关远焦 DOF 出辅助线核对版（DOF 满糊会把线一起晕开）。
- 贴图副本进 `res://tests/dev/proto_hd2d/tex/ground_tiles/`（`_tex_abs` 优先 res:// 加载，场景外链不内嵌）——待办①的贴图侧已就位。

**验收产物（二选一对照看）**
- `F:\VSCode\game-2\.temp\building-pipeline-v2\stick-world\temp\proto_hd2d\hd2d_f2_dof.png`——DOF 正常观感版
- `F:\VSCode\game-2\.temp\building-pipeline-v2\stick-world\temp\proto_hd2d\hd2d_f2_flat.png`——无糊辅助线核对版（橙线=1/3 线、绿线=末层基线）

**第二轮（2026-09-14 上午，创始人十条新指令）**
- **全卡库重烘 26°**：`blender_proto.py`/`bake_props.py` 的烘焙俯角 20°→26°（与场景 TILT_DEG 同步），13 张建筑卡（**新增 shelter_w6 柱撑草棚**）+28 张道具卡全部重烘——建筑/角色/相机三者取向首次完全一致（此前角色 billboard 硬编码 20° 与相机差 6°，即"火柴人身高/角度不对"的根源）。
- **前排进退错落**：z_off 0.35~1.35 为主（楼根离台肩留缝）、~12% 退至 1.6、~10% 不上台面直接落地面（y=0）。
- **道具接回**：28 道具卡（`1bb80d47` 引入、`a016770f` 回退时撤掉的小零件）恢复——市集摊/推车/井/桶/砧/凳等，台面（楼脚前带）与路面两层摆位。
- **路肩=城中心专属**：台面三段化（中段 ±28 格石板+石路肩，两侧夯土台面+土坎），交接线压 gtx 手工收边条；石/土 kerb 分段换色。
- **门前短径**：guildhall 与落地建筑门口贴夯土径（台面段+路面段两截，dc_door_path decal 贴图未烘前先程序化代替）。
- **辅助线收进调试模式**：`--debug=1` 才显示网格/紫线/1-3 线/末层基线（默认干净的成图）。
- **纹理全部落 `res://tests/dev/proto_hd2d/tex/`**（建筑/道具/gtx 过渡，111 张）——`--save-scene` 外链化前提就位（待办①完成贴图侧）。
- 验收产物：`F:\VSCode\game-2\.temp\building-pipeline-v2\stick-world\temp\proto_hd2d\` 下 `hd2d_g3_dof.png`（正常观感）/`hd2d_g3_flat.png`（无糊细节）/`hd2d_g3_debug.png`（辅助线）。

**第三轮（2026-09-14，道具复刻 + 游戏接入）**
- **道具摆位复刻 `1bb80d47` 示例口径**：前排改 gap 推进（0~1.5 格为主、偶有 2~5 格空当），道具按**空当槽位**摆放（slot+dx 引用，不再手撒坐标）。踩过的坑：推进宽度用「卡画面宽」会把街撑到 200+ 格（2/3 在画外）、用「建筑格宽」会让卡互相重叠——**正解 = 画面宽推进 + 生成循环铺满可视范围**（"城市爱多大多大"，不压缩间距）。
- **HD-2D 街景接入游戏**（创始人 2026-09-14：直接接入游戏内场景要玩）：
  - `proto_hd2d.gd` 加静默常驻模式（`--shots` 默认 `none`：不截屏不退出；probe 出图须显式传参）；
  - 新地图 `hd2d_street`：宿主 `Hd2dStreetMap`（`modules/world/scripts/map/hd2d_street_map.gd`，extends MapBase 全套 duck API）+ 场景 `modules/world/scenes/maps/hd2d_street.tscn`（EntityHost 等节点齐全）；
  - `game_root.gd` 注册（MapType.VILLAGE）——设置面板「调试→测试地图」自动出现，战略图 SettlementRef 改 map_id 即可正式接通；
  - 存档：静态布景无专有状态（不实现 save_to_db，SaveHandler 守卫跳过），current_map_id 正常随档；玩家 2D 实体走 entities 表正常存取；
  - 玩家=2D 火柴人浮于 3D 街景之上（canvas 层），WASD 可走——**最小可玩版**；3D 相机固定，玩家横移无视差（待接：玩家 x 映射 3D 相机横移）；
  - 验证探针 `tests/dev/verify_hd2d_map.tscn`（GameRoot 完整装配链加载 hd2d_street → 截图 → 退出），实跑无报错、玩家生成、游戏 HUD/3D 街景同屏。
- **天空复用**：`assets/sky/bg_mountain_far/bg_trees_far.png`（SkyDecor 同源贴图）做成剪影 quad 立于背景之后——剪影 PNG 必须开 `TRANSPARENCY_ALPHA`（否则透明区渲成黑带）；高度/饱和度按空气透视压低压淡。
- 验收产物：`temp/proto_hd2d/hd2d_g6_sky.png`（街景成图）、`temp/proto_hd2d/verify_hd2d_map.png`（**游戏内实机截图**，完整 HUD+3D 街景+附身玩家）。

**第四轮（2026-09-14，六项返修 + 游戏接入深化）**
- **背景重复度**：烘焙清单扩到 19 张卡（新增 barn12/gatehouse8/alchemy8/library12/mage_tower6 等；chapel 无装配器、mage_tower 仅 6 格档——顺序勿改错）。背景改**主题组合段**：西段教堂天际线 / 中段市集街屋 / 东段田园作坊，卡按 x 段从池顺位取（防邻重）；bg2/bg3 均带补洞（阈值 9.8=最小画面宽 cottage_w6 9.1+0.6 缝）。
- **道具穿模根因**：`bake_props` 的 anchor 语义=「画面中心对应点」（与 blender_proto 的落地线 anchor 不同），沿用建筑卡落位公式导致卡底入地（桶 -0.44 格、推车 -0.62、市集摊 -0.94）。修复=**卡底贴地落位**：pos.y=地面高+cosθ·半高、pos.z=基线−sinθ·半高。
- **附身指示**：脚下黄椭圆（`possession_indicator.gd`，二分法定位）改**白色四角线框**；RTS 选中环（`selection_system.gd`）同步改白四角框统一风格。
- **假火柴人**：静默常驻模式不再 spawn 演示 CHARS（出图模式保留用于遮挡验证）；连带修 `_apply_light/_apply_stage/_build_world` 对 `_char_host` 的空引用。
- **碰撞**：`proto_hd2d.get_solid_rects()`（前排建筑按格宽对齐中心+道具收窄 15%，灯笼不挡）→ 宿主 `Hd2dStreetMap._build_solid_bodies()` 生成 2D StaticBody 碰撞墙（y 688~1080 行走带后段，前景留横穿），玩家不再穿透建筑/摆件。
- **出生点**：`GameRoot._on_map_loaded` 加 `map.has_method("get_spawn_point")` 钩子（向后兼容），HD2D 宿主返回街中心前景 (0,1010)。
- 验证：`tests/dev/verify_hd2d_map.tscn` 实机链路全绿（地图切换/玩家生成/白四角框/无假人/无报错）。

**第五轮（2026-09-14，main 合并 + 交接给下一会话）**
- **origin/main 已合并**（零冲突，merge commit `1e8ba99b`）：main 领先 87 提交并入（AI 系统 config/ai、system_setup/save_handler/initial_content/game_root 改动、加载屏两级进度条等）；本分支的 hd2d 注册/出生点钩子合并后完好；报错自检干净。`tools/blender_buildings/` 全部健在（仅存在于本分支，main 没有——`git diff HEAD origin/main` 里的 4.8 万 deletions 是本分支独有文件的显示，非丢失）。
- **子代理**：本对话的子代理欠费不可用；**新会话子代理可用，调研照常派 Explore**（提示词见第 2 条）。

**第六轮（2026-09-14，全部完成）——主场景手工摆 + 启动直连 + 树矿实装 + 覆盖率收口**

创始人补充指令：「村A不用像原来一样简陋，可以弄的规模大一点」→ 街长铺满村A全域 ±67 格（不压缩进单屏），配套把「玩家 x → 3D 相机横移」一并实装（否则大场景看不到）。

1. **指示器归并 ✔**：possessed 白四角框并入 `selection_system.gd`（`_process` 常开自门控、`_draw_corner_bracket` 复用），`possession_indicator.gd` 退役删除。
2. **main 合并 ✔**：本地 main 领先 96 提交（音频线/UI 顶栏/交接文档）零冲突并入（`2a44f77f`）。
3. **语义翻译调研 ✔**（Explore 子代理）：关键发现——①recruit/conquest 两处 `HOME_MAP_ID="village_a"` 硬编码（招兵再生/败仗回村会送回旧图）；②昼夜真钟是 EnvironmentSystem 走 CanvasModulate（2D only），`WorldState.game_time` 单位即小时（0~24）；③HD-2D 图上跑 `spawn_npcs` 会全员待业（无工位/资源点）、`spawn_initial_warehouse` 静默失败（无 PlacementGrid）。
4. **手工摆主场景 ✔**：FRONT_ROW 随机轮转改 9 栋语义清单（西村口民居@-51→石造仓库@-34→铁匠铺@-17→宅邸@+1（guildhall 代 manor，v3 无此装配器）→东民居@+17→谷仓@+33→酒馆@+48→城门塔@+59，两端 cottage/树补景）；道具改绝对坐标随楼；补烘 house_w16/warehouse_w16（修 library 档位 KeyError、剔 chapel 死引用，重烘 20 卡）。
5. **树矿实装 ✔**：新增 `bake_nature.py`（15 件树/矿/石卡，**剔阴影踏板面片修脚下白雾**）；`NATURE_SPOTS` 西森林带+东段散布；实心卡入碰撞；带 `res` 点位由宿主生成 2D ResourceNode（**采集交互复用既有按 F 链路**，2D 笔触视觉隐藏），13 个采集点（木6/石2/铁3/金1/钻1）。
6. **启动直连 ✔**：`START_MAP_ID=hd2d_street`；旅行链全部改挂（村A退役为调试图仍注册）；`supports_village_facilities()=false` 门控跳过仓库/NPC/资源生成；`boot_map_id_override` 供测试声明初始图；家图硬编码两处改 hd2d_street（recruit 的再生家图改实例字段供测试覆盖）；报幕「起始之地」登记。
7. **覆盖率 ✔**：Hd2dStreetMap 补 `town_center_world_x`/`foreground_layer`、地图边界 ±2160（村A城墙语义）、东西村口 ChunkTrigger 出口、昼夜挂钩（game_time→day/night，6:00/19:00 换档）、相机横移；**横移露边穿帮**（相机到村口视窗 ±104 > 旧铺设 ±70）——背景三层/台面夯土/kerb/天幕平铺/灯笼全部扩幅。
8. **验证 ✔**：全量测试 49/49（10 个失败全部修复：2 个断言同步新主街链、7 套集成测试声明 boot 回村A、1 个再生家图覆盖）；报错自检干净；实机探针 6 断言全绿（初始图即主街/玩家/13 资源点/2 出口/44 碰撞墙）；昼夜单位 bug（秒/小时）实测抓出已修。

**遗留/豁免（显式登记）**：①村民 NPC 在主街暂不开（无工作场所，待 HD-2D 化立工位卡后开）；②ResourceNode 枯竭隐藏时 PBR 卡不跟着藏（视觉与数据二态不同步，小事）；③针叶树冠层叠感、矿露头矿色偏淡（v3 已知落差）；④`proto_hd2d_ground.tscn`（探索产物 9.9MB）仍未入库。

**验收产物**（白天四机位巡览 + 实机直连开局 + 夜档）：
`F:\VSCode\game-2\.temp\building-pipeline-v2\stick-world\temp\proto_hd2d\` 下
`hd2d_s_street_x-40.png`（西村口森林带+矿组）/ `hd2d_s_street_x-12.png`（仓库+市集）/ `hd2d_s_street_x20.png`（宅邸+东民居）/ `hd2d_s_street_x50.png`（谷仓+酒馆+城门+水晶簇）/ `verify_hd2d_map.png`（**实机开局**：启动直连主街+玩家白四角框+完整 HUD）/ `hd2d_e_night.png`（夜档窗火）。

**大项登记（下一阶段）**
1. ~~城市搬运 HD-2D~~ **已完成（第七轮，见下）**。
2. **后排动态出现逻辑**：后排背景随前排建筑数量自适应出现/消失（游戏运行时规则，接入时实现）。

**第七轮（2026-09-14，全部完成）——全面 HD-2D 化第一步：删旧世界 + 算法村**

创始人指令链：①废弃代码与旧场景直接删（Git 历史可找回）；②质疑「测试床=在到不了的地方测试是假测试」成立；③**整个游戏都要变成 HD-2D**（村B 也要）；④「之前你说根据村子规模生成建筑排布的算法做了吗」→ 就是 `city_layout.py`，把它接进游戏；⑤同排建筑重叠 → 算法修正；⑥测试快速跳过，要可玩原型。

1. **旧世界清退 ✔**：删 village_a.tscn（旧主场景）、village_b.tscn（2D 村）、v2 Godot 建筑管线 `tools/building_pipeline/`、拍旧村工具 render_village/snapshot_town、探索产物 proto_hd2d_ground.tscn；road_a_b 西端出口改指主街；map_titles/settings 清旧村条目。
2. **city_layout 接进游戏 ✔**（大项 1 落地）：
   - 新增 `tools/blender_buildings/export_city_layout.py`（纯 Python）：`plan_city(tier, seed)` 布局 → HD-2D 布局 JSON（def→卡映射 church→cathedral/plaster_house→house/chapel→tower；market_stall/well→道具层；**同排推挤修正**——布局 x 是墙格位、卡画面含出檐，按画面间隙 ≥0.6 格推挤+质心回正，修创始人指出的同排重叠）；x 中心化（与主街/出生点同坐标系）。
   - `proto_hd2d.gd` 加**布局驱动模式**（`--layout=<名>` 或宿主 set）：前排=布局 row0、bg1=布局后排（bg2/3 保留插缝补满）、道具/树按布局；手摆 FRONT_ROW 保留为主街模式。
   - 补烘 6 卡（barracks12/hayloft8/smithy2-3 w8/smithy4 w12/windmill6），卡库 26 张覆盖布局全部 def。
3. **村B = 第一个算法村 ✔**：`hd2d_village_b.tscn`（Hd2dStreetMap + layout_name="village_b"，village 档 seed 611036 → 14 栋：前排 7+背景 7+道具 7+树 1）；旅行链 主街↔道路↔村B 不变；宿主按布局街宽自适应地图边界。
4. **测试处置 ✔**（快速跳过裁决）：设施类 7 套（工位/采集/招兵/建造/存档往返/驻军/村功能面）SUSPENDED——2D 设施宿主已删，待「玩法设施 HD-2D 化」后在主街/村B 重建；战斗类 4 套 boot 迁 battlefield（生产可达）；cross_map_travel 改新旅行链断言。
5. **运行时资产自洽 ✔**：卡元数据 JSON（cards/props/nature/布局）入库 tex/，`_load_cards`/`_read_json_rel` 支持烘焙工作区缺失时回退读取；地面高清源贴图（rammed_earth 等 5 key）入库——**新机器 clone 后无需先跑烘焙即可玩**。
6. 验证：自检干净；算法村成图 `hd2d_c_final.png`（--layout=village_b）推挤修正后同排零重叠。

**第七轮半~第九轮（2026-09-14 下午~晚间，快速迭代）**

1. **算法村重叠修正**：布局格位直摆互相压（布局 x 是墙格位、卡画面含出檐）——导出器加同排推挤（画面间隙 ≥0.6 格+质心回正），逐排复核零重叠。
2. **全面 HD-2D 化推进**：村B 换算法村（hd2d_village_b.tscn）；删村A/village_b 2D 旧场景、v2 管线；road 西端出口改指主街；设施类测试 7 套 SUSPENDED 摘出矩阵（快速略过裁决）。
3. **角色渲染进 3D 场景**（HD-2D 最佳实践层）：逻辑留 2D、视觉转 char_sprite_3d billboard（每实体独立 SubViewport）——写深度/可遮挡/接地影/纵深缩放；2D RigHost 隐藏。
4. **村民劳作回归主街**：NPC 门控与 2D 设施门控拆分（wants_villager_npcs）；露天工位 duck（铁砧=铁匠工位，profession_registry 回退链）；配比照旧 铁匠1/伐木3/矿工3/待业3。
5. **相机操作接入**：3D 相机镜像 CameraRig（x+zoom）——1/4 跟随/居中/边缘滚动/中键拖拽/滚轮缩放全生效。
6. **碰撞模型修正**：建筑=地基带（格宽×基线外扩1.4格），道具/树=纵深带内点障碍——消除全街空气墙与 NPC 卡死。
7. **描边风波（大量返工，教训落档）**：ID 缓冲融合描边三进三出——最终定稿=全融合（全部零件同 ID，白描边只包外轮廓、内部零描边）+隐藏矢量自备描边层；中间踩坑：shader `#` 注释编译失败白模、basis/scale 互相覆盖、batch_rig 环境变量误导、体色误判（直方图核实与旧版一致）。**全部知识已落档 `docs/技术/架构/建筑管线/HD-2D街景系统.md` §2.5 备查**——本项目火柴人渲染此前无任何记载，是这次返工的根因。
8. 四角框贴脚底（foot_offset 显式下移）→ 进而改 3D billboard 脚下框（2D 画布框在 HD-2D 图必错位）；F3 显示 HD-2D 碰撞墙。
9. 运行时资产入库自洽（卡元数据 JSON+地面高清贴图入库，回退加载），新机器免烘焙可玩。

**第八轮待办（下一会话第一优先）**
1. **玩法设施 HD-2D 化立项**：主街/村B 上接 PlacementGrid/兵营/仓库实体（调研⑦「可以 #12」），完成后重建 7 套 SUSPENDED 测试（在生产图上）。
2. **战场/道路/守城图 HD-2D 化立项**（battlefield 仍 2D）；战斗类测试随迁。
3. 村B 工作场所（铁匠 NPC 站 smithy2 前等）随设施 HD-2D 化一并搬入（原大项 1 的后半）。

**第七轮验收产物**：`F:\VSCode\game-2\stick-world\temp\proto_hd2d\hd2d_c_final.png`（算法村 village_b 成图）；主街巡览四机位与实机开局图沿用第六轮（`F:\VSCode\game-2\.temp\building-pipeline-v2\stick-world\temp\proto_hd2d\`，主工作区重出：`F:\VSCode\game-2\stick-world\temp\proto_hd2d\`）。

**遗留/待反馈**
- 「屏幕下 1/3 线作为第一排上限」按「第一排(+地面)屏幕区的上边界」执行（前排楼根在下 1/3 区、楼身自然伸入中区）；若创始人本意是「前排楼顶不得过线」需回炉（前排须全改 1 层，与闹市 2~3 层冲突，提请再裁）。
- 夜景档（--shots=e）未随本轮重渲，白天版定稿后再出。
- `proto_hd2d_ground.tscn`（9.9MB，--save-scene 导出）仍为探索产物未入库；可选 `--freecam` 自由视角未做。
- 其余待裁项见 `docs/项目/待办事项.md`「需创始人决策」（门宽/窗宽规范冲突、俯角 vs 屏占、零偏航侧翼、B 类室内清单）。

**可调参数速查**（都在 `proto_hd2d.gd`）：`PLAT_H`（台面高 0.65）、`TILT_DEG`（26）、`CAM_CY`（11）、`CAM_W`（74）、`SKYLINE_Z`（−6.73，屏幕下 1/3 线）、`BG_LAYER_GAP`（6，层距）、`BG_TINTS`（三层距离染色）、台面 tint（暖亮 1.04/1.00/0.93）与道路 tint（冷深 0.86/0.89/0.96）。
