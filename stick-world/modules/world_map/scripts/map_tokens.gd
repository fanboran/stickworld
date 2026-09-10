class_name MapTokens
extends RefCounted
## 战略图线条/语义色 token —— 地图渲染器唯一取值处（观感返工 §R8 层2）。
##
## 规则（R8 层2 落地口径）：
## - 渲染器内禁止新增色值/线宽字面量，一切线条取值从本文件（或 StickTokens/SketchDraw）取；
## - 语义色槽：内容线 = CONTENT_PALETTE 派生或群系色（生成端同源）；交互线（hover/选中）
##   = StickTokens.BORDER_STRONG；操作线（快速旅行路由高亮）= StickTokens.ACCENT——
##   琥珀在地图上的唯一合法位置；玩家位置 = 玩家国色（运行时按所在地块政权色取，无常量）；
## - 线宽档：界线三级（§7.3-6 规范表）国 3px 实线 / 地区 2px 长虚线 / 地块 1px 短虚线，
##   屏幕像素口径（政治模式恒定粗细）；非政治模式沿用各视图现状线宽（原值迁移）。
## feedback1 去抖动：手绘笔触参数（SEG_LEN_RATIO/AMP_RATIO）随 wobble 退役删除，
## 线条平滑直绘——token 只管线宽/语义色/虚线分级。

# ────────────────────── 界线三级（观感返工第三批 C19 重设计，政治模式，屏幕像素口径）──
## 设计：**深墨主线 + 浅羊皮纸底衬（casing）**
##   - 旧版国界是「白亮实线」，压在深蓝海洋与饱和政权色上都会跳出来（创始人否决）；
##   - 新版把「亮」从主线移到**底衬**：主线用墨色（与地图标注同墨系），底衬用极浅的
##     暖白压在主线下层——底衬负责「让界线在任何底色上都读得出来」，主线负责
##     「读起来是界线而不是划痕」。这是 OSM carto 行政界线的 casing 做法，
##     也是纸质地图国界的惯例（深墨线 + 浅色描边）。
##   - 三级仍按「国 > 地区 > 地块」递减：国界有底衬且最粗，地区界细长虚线无底衬，
##     地块界更浅更细——同一张图上不会两种界抢语义。

## 国界主线（墨色实线）——宽于底衬的「显形量」经截图实测校准：
## 1.8px 时底衬（4px）占太宽，远看把国界读成「一条亮线」；2.4px 让墨芯成为主体。
const LINE_NATIONAL := 2.4
## 地区界（墨色长虚线）
const LINE_REGION := 1.3
## 地块界（浅墨短虚线；值 ≥ StickTokens.BORDER_W = 1）
const LINE_PLOT := 1.0
## 自由城邦界（国 vs 无归属 253 边的降级样式，与地块界同宽档）
const LINE_FREE := 1.0

# ────────────────────── 界线三级配色（内容线槽）──────────────────────

## 国界底衬色：暖白羊皮纸半透明——压在深蓝海洋上提亮、压在浅色政权上压低，
## 保证主线在两端底色上都有对比（casing 的全部意义就在此）
const LINE_NATIONAL_CASING_COLOR := Color(0.96, 0.95, 0.90, 0.50)
## 国界底衬额外宽度（屏幕像素）：casing 宽 = 主线宽 + 本值（每侧各露一半）
const LINE_NATIONAL_CASING_EXTRA := 1.6
## 国界主线墨色（与标注墨、首都标记墨同族；不再是白色）
const LINE_NATIONAL_COLOR := Color(0.11, 0.10, 0.09, 0.95)
## 地区界墨色（次级：更浅更透，无底衬）
const LINE_REGION_COLOR := Color(0.18, 0.17, 0.16, 0.60)
## 地块界墨色（三级之最弱）。第四批反馈「有的城市界黑线会消失」：0.42 太淡，
## 在中明度政权色上接近隐形 → 提到 0.6（线宽仍 1px，不与地区界抢语义）
const LINE_PLOT_COLOR := Color(0.22, 0.21, 0.20, 0.60)
## 自由城邦界灰（内容语义：无归属陆地；灰族与 PoliticalLut.FREE_CITY_COLOR 同语义）
const LINE_FREE_COLOR := Color(0.42, 0.42, 0.42, 0.75)

## ── 界线几何判定（C19 修正用；8192 级地图单位）──
## l3_city 城块多边形是各自独立平滑的，两侧顶点不共享（实测 34433 条边只有 2192 条
## 能精确配对）——「共享边配对」只能覆盖 6% 的国界，所以改由政权 ID mask 判界：
## 从边中点沿外法向探针采样。
## 探针距离：够远能跨过两侧多边形 1~3px 的平滑差，又不足以跳过一个薄邻块。
const BORDER_PROBE_DIST := 4.0
## 同一物理界两侧各出一条近乎重合的边，用中点空间哈希去重（仅跨城块去重，
## 同城块内相邻边永不去重——否则短边会被吃掉，界线断口）。
const BORDER_WELD_GRID := 8.0

# ────────────────────── 虚线（屏幕像素口径）──────────────────────

## 长虚线（地区界）：实段/空段
const DASH_LONG := 13.0
const DASH_LONG_GAP := 9.0
## 短虚线（地块界）：实段/空段
const DASH_SHORT := 6.0
const DASH_SHORT_GAP := 5.0

# ────────────────────── L1 视图（map_renderer，原值迁移）──────────────────────
## 坐标系 = L1 context（数百~千级），线宽屏幕像素固定（绘制时 ÷zoom 换算）

## 海洋（与生成端 B2 terrain_params.json colors.ocean 同源，改色两端同步）
const L1_OCEAN := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
## 湖泊（与 B2 底图湖色 terrain_params.json colors.lake 同源）
const L1_LAKE := Color(72.0 / 255.0, 116.0 / 255.0, 158.0 / 255.0)
## 河流（与 L2/L3 底图预渲染河流同色，生成端同源）
const L1_RIVER := Color(46.0 / 255.0, 102.0 / 255.0, 140.0 / 255.0)
const L1_RIVER_MIN_WIDTH := 2.0

## 道路（R6：色与生成端 casing 面色 l1_terrain_params.json travel.face_color 同源）
const L1_ROAD_DIRT := Color(166.0 / 255.0, 122.0 / 255.0, 60.0 / 255.0)
const L1_ROAD_PAVED := Color(198.0 / 255.0, 132.0 / 255.0, 82.0 / 255.0)
const L1_ROAD_WIDTH_DIRT := 1.2
const L1_ROAD_WIDTH_PAVED := 3.0

## 群系图例色（B2 地形底图色板图例入口；与 tools/worldgen/l3/biome_generate.py
## BIOME_COLORS 同源，改色两端同步）
const BIOME_LEGEND: Array[Dictionary] = [
	{"color": Color(130.0 / 255.0, 170.0 / 255.0, 90.0 / 255.0), "text": "平原"},
	{"color": Color(70.0 / 255.0, 120.0 / 255.0, 62.0 / 255.0), "text": "森林"},
	{"color": Color(208.0 / 255.0, 182.0 / 255.0, 122.0 / 255.0), "text": "荒漠"},
	{"color": Color(228.0 / 255.0, 233.0 / 255.0, 238.0 / 255.0), "text": "冰原"},
	{"color": Color(95.0 / 255.0, 160.0 / 255.0, 195.0 / 255.0), "text": "水源带"},
	{"color": Color(118.0 / 255.0, 62.0 / 255.0, 54.0 / 255.0), "text": "火山"},
]

## 城市常驻描边（内部城界，灰墨内容线；屏幕像素固定）
const L1_TILE_BORDER_COLOR := Color(0.35, 0.35, 0.35)
const L1_TILE_BORDER_WIDTH := 2.0
## 出生 L1 权威轮廓（深灰墨，略粗区分出生块边界）
const L1_BORDER_COLOR := Color(0.25, 0.25, 0.25)
const L1_BORDER_WIDTH := 2.5
## 邻居老 L1 块空心轮廓（A3 空心化：灰轮廓不填充；与 PoliticalLut.NEIGHBOR_COLOR 同值 0.45 灰）
const L1_NEIGHBOR_COLOR := Color(0.45, 0.45, 0.45)
const L1_NEIGHBOR_BORDER_WIDTH := 2.0
## 内容区"纸张边界"黑框（装裱观感）
const L1_PAPER_BORDER_COLOR := Color(0.08, 0.08, 0.08)
const L1_PAPER_BORDER_WIDTH := 4.0

## hover 描边（交互线槽 = StickTokens.BORDER_STRONG，R8 层2 语义归位）
const L1_HOVER_COLOR := StickTokens.BORDER_STRONG
const L1_HOVER_WIDTH := 3.0

## 城市中心标记点（小圆点 + 细环，屏幕像素固定）
const L1_CITY_DOT_RADIUS := 3.0
const L1_CITY_DOT_RING_WIDTH := 1.0
const L1_CITY_DOT_COLOR := Color(0.95, 0.95, 0.9)
const L1_CITY_DOT_RING := Color(0.12, 0.12, 0.12)

## 城市建成区矢量回退层（烘焙贴图填充底色近似值，生成端概览同款暖灰，改色两端同步）
const L1_BLOB_FILL := Color(198.0 / 255.0, 188.0 / 255.0, 170.0 / 255.0)
const L1_BLOB_EDGE := Color(0.24, 0.20, 0.15)
const L1_BLOB_EDGE_WIDTH := 1.5
## T4+ 白描边
const L1_BLOB_EDGE_T4 := Color(0.95, 0.95, 0.92)
## T5 金描边（内容语义：顶级城市标记。物理值 = StickTokens.CONTENT_PALETTE[9]
## 琥珀棕 amber——内容色板成员，R8 层2 语义归位：不再是体系外金值；
## GDScript const 不支持跨类数组下标，故在此落定值，改色与 StickTokens 两端同步）
const L1_BLOB_EDGE_T5 := Color(0.95, 0.68, 0.25)

## F3 调试：城市编号（调试域专色，非地图语义色，集中定义）
const DEBUG_INK := Color(1.0, 0.9, 0.3, 0.95)
const DEBUG_BG := Color(0.0, 0.0, 0.0, 0.75)
const L1_LABEL_SIZE := 30.0
const L1_LABEL_SCREEN_CAP := 40.0

## 当前所在城市流动描边（"你在这里"，A3 定标双色不透明蓝青）
const L1_GLOW_A := Color(0.35, 0.85, 1.0)
const L1_GLOW_B := Color(0.15, 0.45, 0.95)
const L1_GLOW_WIDTH := 4.0

## 玩家位置标记（R2 GPS 范式；色 = 玩家国色运行时取，无常量）
const L1_PLAYER_DOT_RADIUS := 4.0
const L1_PLAYER_DOT_OUTLINE_W := 1.5
const L1_PLAYER_RING_RADIUS := 12.0
const L1_PLAYER_RING_WIDTH := 1.0
## 静态细环（白，半透明略降避免喧宾夺主；原值迁移）
const L1_PLAYER_RING_COLOR := Color(1.0, 1.0, 1.0, 0.75)
const L1_PLAYER_PULSE_FROM := 12.0
const L1_PLAYER_PULSE_TO := 36.0
const L1_PLAYER_PULSE_PERIOD := 1.5
const L1_PLAYER_PULSE_ALPHA := 0.5

## 快速旅行路由高亮（操作线槽 = StickTokens.ACCENT 琥珀——唯一合法位置。
## 物理值 = ACCENT(0.95,0.68,0.25) + alpha 0.95（GDScript const 不支持跨类成员
## 访问，故在此落定值，改色与 StickTokens 两端同步）
const L1_ROUTE_COLOR := Color(0.95, 0.68, 0.25, 0.95)
const L1_ROUTE_WIDTH_RATIO := 0.008
const L1_ROUTE_DASH_RATIO := 0.014
const L1_ROUTE_GAP_RATIO := 0.010
const L1_ROUTE_NODE_RADIUS := 6.0

# ────────────────────── 地图标注体系（R8 层3，§7.3-3/§7.3-6 规范表）──────────────────────
## 标注 = 三级视觉分级（国名/地区名/城市，两步法相邻档差 ≥2pt）+ 都城星标。
## 尺寸全部屏幕像素口径（绘制时 ÷zoom 换算成地图单位）；字体 = StickHand
## （SketchFonts.hand/bold，与游戏 UI 同源，禁止 fallback 字体）。
## feedback1 定标：创始人反馈「文字太大」→ 全档下调一档
## （国名 18→14 / 地区 14→11 / 首都 13→11 / 城市 12→10；相邻档差仍 ≥2pt 除首都/城市同档
## ——首都用 Bold 字重区分）。halo 换引擎级描边（TextServer 字形轮廓扩张，非四向偏移）。

## 国名 14px Bold（中文无大写——以字距/字重表达层级，§7.3-3）
const LABEL_SIZE_COUNTRY := 14.0
## 地区名 11px
const LABEL_SIZE_REGION := 11.0
## 首都名 11px Bold（与城市同字号，字重区分）
const LABEL_SIZE_CAPITAL := 11.0
## 城市名 10px
const LABEL_SIZE_CITY := 10.0

## 字距（= 字号的倍数）：面要素（国名/地区名）拉字距做层级，点要素（城名）几乎不拉。
## 第三批 C24 重调：国名 0.15→0.18（大字号面标注更需要呼吸感），地区名/城名补档。
const LABEL_COUNTRY_TRACKING := 0.18
const LABEL_REGION_TRACKING := 0.10
const LABEL_CITY_TRACKING := 0.06

## halo 宽（字号 ≈ ×0.20，clamp 1.2~2.4px 屏幕口径；描边 = 引擎级字形轮廓扩张，
## 宽为像素 int）。C24 取值 → 略宽于旧版：墨字落在深蓝海洋/深色政权上时，
## 浅 halo 要够厚才把字形从深底上「托」出来（纸质地图浅底衬的原理）。
const LABEL_HALO_MIN := 1.2
const LABEL_HALO_MAX := 2.4

## 标注配色（第三批 C24 重设计）：**全图统一「墨字 + 浅羊皮纸 halo」**——
## 旧版政治图用「白字 + 深墨 halo」，在饱和政权色上像 UI 浮字、与 L1 的地图字两套语言；
## 新版换纸质地图的经典做法（深墨字 + 极浅底衬），政治图与地形图标注同一套观感，
## 也与 C19 的界线墨色同族（地图上「内容墨」只有一个）。
const LABEL_INK_MAP := Color(0.14, 0.12, 0.10)
const LABEL_HALO_MAP := Color(0.97, 0.96, 0.92, 0.92)
## L1 城市标注用色（浅色地形底图上）：同墨系（比政治图略暖）+ 白 halo
const LABEL_INK_CITY := Color(0.16, 0.14, 0.11)
const LABEL_HALO_CITY := Color(1.0, 1.0, 1.0, 0.88)

## 都城标记（第三批 C20 重设计）：**同心环 + 中心实点**（经典制图学首都符号，
## 取代原五星——星形在彩色底图上过像贴纸且小尺寸下糊成一团）。
## 三层同心：浅色底衬环（让标记在任意底色上读得出，与国界底衬同语言）
## + 墨色外环 + 墨色中心点。恒定屏幕尺寸、任何缩放级别都常显。
const LABEL_CAPITAL_RADIUS := 5.2
const LABEL_CAPITAL_RING_W := 1.5
const LABEL_CAPITAL_DOT_RADIUS := 1.9
const LABEL_CAPITAL_COLOR := Color(0.13, 0.12, 0.11)
const LABEL_CAPITAL_CASING := Color(0.97, 0.96, 0.92, 0.55)
const LABEL_CAPITAL_CASING_EXTRA := 1.8

## 缩放显隐阈值（r = zoom / 视图适配 zoom；OSM carto 国家 z3/城市 z6 的分级思路
## 按我们三级视图定标）。适配 zoom 由层自算 = 视口高 × fit_hint / 地图跨度。
## L3：国名 r≤6 显（全景~中景；再放大即将下钻 L2，国名退场只留都城星标）
const LABEL_ZOOM_COUNTRY_MAX := 6.0
## L2：地区名 r≤6 显；重镇名 r≥1.2 显（默认视角 = 1.75r 打开即显）
const LABEL_ZOOM_REGION_MAX := 6.0
const LABEL_ZOOM_TOWN_MIN := 1.2
## L1：城市名 r≥0.55 显（过度缩小只留首都，防 13+ 城标注互相压盖）
const LABEL_ZOOM_CITY_MIN := 0.55

## 标注锚点间隙（屏幕像素，文字盒相对符号点/锚点的留隙）
const LABEL_ANCHOR_GAP := 3.0
## 碰撞盒外边距（屏幕像素，防文字贴字）
const LABEL_COLLIDE_PAD := 2.0

# ────────────────────── L2 视图（l2_map_renderer，原值迁移）──────────────────────
## 坐标系 = L2 region context（千级），线宽 = 地图单位绝对粗细 + 屏幕上限 clamp

const L2_OCEAN := L1_OCEAN
const L2_LAKE := L1_LAKE
const L2_RIVER := L1_RIVER
const L2_RIVER_MIN_WIDTH := 2.5
## 相邻地区灰色填充（不上色）
const L2_NEIGHBOR := Color(0.45, 0.45, 0.45)
## 地块常驻描边（非政治模式；灰墨）
const L2_TILE_BORDER_COLOR := LINE_PLOT_COLOR
const L2_TILE_BORDER_WIDTH := 5.2
## hover 描边（交互线槽；屏幕像素上限）
const L2_HOVER_COLOR := StickTokens.BORDER_STRONG
const L2_HOVER_WIDTH := 6.5
const L2_HOVER_SCREEN_CAP := 11.7
const L2_HOVER_MARGIN := 2.0
## 相邻地区分界线（非政治模式；深灰墨。宽 = 原 EDGE_WIDTH 6.5 × 1.3 派生值定档）
const L2_BORDER_COLOR := Color(0.25, 0.25, 0.25)
const L2_BORDER_WIDTH := 8.45
const L2_BORDER_SCREEN_CAP := 13.0

# ────────────────────── L3 视图（l3_map_renderer，原值迁移）──────────────────────
## 坐标系 = 8192 级大世界网格，线宽 = 地图单位绝对粗细 + 屏幕上限 clamp

const L3_OCEAN := L1_OCEAN
## L2 地区常驻描边（非政治模式；政治模式下即"地区界"走界线三级样式）
const L3_REGION_BORDER_COLOR := Color(0.14, 0.14, 0.14, 0.85)
const L3_REGION_BORDER_WIDTH := 11.7
const L3_REGION_BORDER_SCREEN_CAP := 20.8
## hover 老 L1 高亮（交互线槽 = BORDER_STRONG；原黄色系琥珀残留已归位）
const L3_HOVER_COLOR := StickTokens.BORDER_STRONG
const L3_HOVER_WIDTH := 6.5
const L3_HOVER_SCREEN_CAP := 10.4
## 玩家所在 L2 地区流动描边（A3 定标双色不透明蓝青，与 L1_GLOW 同语言）。
## 第四批反馈「太粗/画风不对」：10→4（地区轮廓只是位置提示，不该压过政权界线）
const L3_PLAYER_GLOW_A := L1_GLOW_A
const L3_PLAYER_GLOW_B := L1_GLOW_B
const L3_PLAYER_GLOW_WIDTH := 4.0
const L3_PLAYER_GLOW_SCREEN_CAP := 8.0
## F3 调试编号
const L3_LABEL_SIZE := 40.0
