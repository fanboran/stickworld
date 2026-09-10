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

# ────────────────────── 界线三级（§7.3-6 规范表，政治模式，屏幕像素口径）──────────────────────

## 国界 3px 实线（政治模式最粗界；「亮」= 白亮线压彩色政权底图）
const LINE_NATIONAL := 3.0
## 地区界 2px 长虚线
const LINE_REGION := 2.0
## 地块界 1px 短虚线（值 = StickTokens.BORDER_W = 1）
const LINE_PLOT := 1.0
## 自由城邦界 1px（feedback2 A：国 vs 无归属 253 边的降级样式，与地块界同宽档）
const LINE_FREE := 1.0

# ────────────────────── 界线三级配色（内容线槽）──────────────────────

## 国界亮线色：全 token 体系中最亮的中性色（取 StickTokens.TEXT 0.93 白），
## 压在 LUT 彩色政权底图上保证「最显眼的界」
const LINE_NATIONAL_COLOR := StickTokens.TEXT
## 地区界墨色（原 L3MapRenderer.L2_BORDER_COLOR，深墨近黑，政治模式沿用为次级界）
const LINE_REGION_COLOR := Color(0.14, 0.14, 0.14, 0.85)
## 地块界墨色（原 L2MapRenderer.TILE_BORDER_COLOR 灰墨）
const LINE_PLOT_COLOR := Color(0.35, 0.35, 0.35)
## 自由城邦界灰（feedback2 A：0.45 中性灰 = L1_NEIGHBOR_COLOR/PoliticalLut
## NEIGHBOR_COLOR 同值灰族；弱于地块界，防与国界抢语义）
const LINE_FREE_COLOR := Color(0.45, 0.45, 0.45)

# ────────────────────── 虚线（屏幕像素口径）──────────────────────

## 长虚线（地区界）：实段/空段
const DASH_LONG := 16.0
const DASH_LONG_GAP := 8.0
## 短虚线（地块界）：实段/空段
const DASH_SHORT := 7.0
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

## 国名字距 = 字号的 15%（§7.3-6 规范表「全大写字距 15%」的中文等价表达）
const LABEL_COUNTRY_TRACKING := 0.15

## halo 宽（字号 1/6~1/5 ≈ ×0.18，clamp 1.0~2.0px 屏幕口径；随字号下调同步收窄，
## 防小字 halo 过宽显脏；描边 = 引擎级字形轮廓扩张，宽为像素 int）
const LABEL_HALO_MIN := 1.0
const LABEL_HALO_MAX := 2.0

## 政治模式标注用色（L3/L2，彩色政权底图上）：墨白字 + 深墨 halo——
## 高对比可读优先（任务详单「国名用高对比墨白」）；深墨 = 墨色系（LINE_REGION_COLOR 同族）
const LABEL_INK_MAP := StickTokens.TEXT
const LABEL_HALO_DARK := Color(0.06, 0.06, 0.06, 0.72)
## L1 城市标注用色（浅色地形底图上）：暖墨字 + 白 halo（§7.3-3「白 halo」正例）
const LABEL_INK_CITY := Color(0.16, 0.14, 0.11)
const LABEL_HALO_WHITE := Color(1.0, 1.0, 1.0, 0.85)

## 都城星标：外接圆直径 7px 简洁矢量五星（规范表「首都星标」惯例；feedback1 随字号
## 下调 8→7 同步缩一档；首都惯例 = 星形符号，OSM carto place-capital）。
## 金 = CONTENT_PALETTE[9] 琥珀棕——顶级聚落语义（与 L1_BLOB_EDGE_T5 同值同源，
## 改色两端同步）；描边 = 墨色（LINE_REGION_COLOR 复用）
const LABEL_STAR_SIZE := 7.0
const LABEL_STAR_FILL := Color(0.95, 0.68, 0.25)
const LABEL_STAR_OUTLINE := LINE_REGION_COLOR

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
## 玩家所在 L2 地区流动描边（A3 定标双色不透明蓝青，与 L1_GLOW 同语言）
const L3_PLAYER_GLOW_A := L1_GLOW_A
const L3_PLAYER_GLOW_B := L1_GLOW_B
const L3_PLAYER_GLOW_WIDTH := 10.0
const L3_PLAYER_GLOW_SCREEN_CAP := 20.0
## F3 调试编号
const L3_LABEL_SIZE := 40.0
