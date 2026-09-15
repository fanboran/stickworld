# -*- coding: utf-8 -*-
"""西幻城镇平面布局求解器（纯 Python，普通 python 即可跑，不依赖 Blender / Godot）。

规范来源：docs/技术/架构/建筑生成管线v3-写实PBR.md
  §3.1 尺寸基准 / §3.2 长宽比 / §3.3 建筑规格表 / §4 城市设计规范（§4.1 规模分级、
  §4.2 功能分区权重、§4.3 街道与广场、§4.4 天际线与视觉重心、§4.5 街景构图）。

坐标契约（与 tools/worldgen/l1/city_profiles.json 对齐）
------------------------------------------------------------------
  cell_w   = 32 px
  ground_y = 720 px（运行时街立面基线）
  width_px：hamlet 2560 / village 3072 / townlet 3584 / town 4096 / burgh 5120 /
            city 6144 / capital 8192 / metropolis 12288
            （八档 = 4 既有档 + 2 过渡档（townlet/burgh）+ 2 高级行政档
            （capital/metropolis），分级依据 docs/技术/架构/聚落等级与建筑分级.md
            【AI 提案/待定】）

  平面 x_px ∈ [0, width_px)   —— 横向；左右两端为城墙（§4.5「左右两端以城墙转角收边」）
  平面 y_px ∈ [0, depth_px)   —— 0 = 城后（北）边缘，正方向指向观察者（南/前）

  后移格数 b：以**主街北缘**为原点向北计数（b=0 紧贴主街北缘）。建筑前进线（南缘）在
  b_s 处，运行时基线 baseline_y = ground_y - b_s*32 —— 最前排 row 0（面向主街的街立面
  排）baseline_y == ground_y，越靠后（画面上方）越小。

  行编号：row 0 = 最前排（贴主街）… row lot_rows-1 = 最深排（贴后城墙）。
  §4.4「唯一最高点位于城市中心偏后」→ 实现为最高点必落最深排。

算法总览（确定性：同 tier+seed → 逐字节同布局）
------------------------------------------------------------------
  A 规模与数量：§4.1 档位取建筑总数 N（取区间上限保密度），§4.2 权重取各区数量
  B 抽 def：每区「必配 def」前缀 + 剩余槽位按权重抽；带高楼预算护 §4.4 墙顶规则
  C 选宽度：优先满足 §3.2 的最小允许宽度；按可用宽度预算确定性降档
  D 左右分侧：逐 def 交替分配，保证每侧 def 混合（能排出不相邻同 def 的序）
  E 行分配：各区在允许行内贪心均衡 → 每排载荷 → 各区 x 带宽（下限 = 最大单体 + 巷）
  F 分带：core | 市场 | 工匠 | 居住 | 生产（由中心向两侧镜像，§4.2），带间纵向支路/巷道
  G 总宽超可用 → 降档最宽建筑后重算（确定性循环）
  H y 分带（b 空间）：主街 → row0 → 巷 → row1 → …（广场侵入的排补余量）
  I 广场：居中于核心带、紧贴主街北缘、6~10 格（§4.3），中心放水井 + 市集摊群
  J 打包 lot：逐排逐段落位，前进线贴街（退线）+ 每 4~6 栋留 1 格小巷（§4.3），余量记 yard
  J3 特殊建筑投放：mage_tower/library/barracks/warehouse/alchemy 按 SPECIAL_DEFS 的
     区带权重与档位频率，落进 J2 的院坝空段（**独立通道**：不消耗既有 rng 取样，
     既有 def 的 x/行/宽逐位不变）；落位按 §8.2 **出檐留位**（剪影口径，见 EAVE_RATIO
     段）—— 先扣两侧邻居出檐的缺口，剩余段放得下剪影才落，放不下降档/换段
  K 城墙：左/右/后三趟等分墙段 + 塔楼（间距 800~1200px 带抖动、塔高 ±15%）+ 左右城门
  L 前景 props（§4.5 桶/摊/树/车，必须落在街道内）
  M 天际线：逐列取最高点得 profile；唯一最高点 / 墙顶高于 80% 建筑 / 等高连排校验
  N verify_plan：五条规范量化断言 + 打印校验结果
"""
from __future__ import annotations

import argparse
import json
import random
from collections import Counter

CELL_W = 32
GROUND_Y = 720

# ── §4.4 天际线常量 ─────────────────────────────────────────────────────
WALL_SEG_CELLS = 4                    # 城墙段等分长度（4 格 = 128px，对应 wall_seg 4 格档）
TOWER_GAP_PX = (800, 1200)            # 塔楼间距区间（§4.4）
TOWER_GAP_JITTER = 0.10               # 间距抖动 ±10%（防「等距得发假」）
TOWER_H_JITTER = 0.15                 # 塔楼高度抖动 ±15%（§4.4）
TOWER_EXTRA_RATIO = 0.38              # 塔楼高出墙顶的比例（再作 ±15% 抖动）
MERLON_PX = 24                        # 垛口（§3.3 wall_seg）

# ── §4.3 街道常量 ───────────────────────────────────────────────────────
ALLEY_EVERY = (4, 6)                  # 每 4~6 栋留 1 格小巷
ALLEY_W = 1
LANE_W = 2                            # 排间服务巷
ROAD_W = 2                            # 纵向支路
MAX_GAP_EXTRA = 3                     # 余量并入巷口时的单缝上限（保持街面密实）

# ── §4.2 功能分区权重（严格） ────────────────────────────────────────────
ZONE_ORDER = ["core", "market", "artisan", "residential", "production"]
ZONE_WEIGHTS = {"core": 0.08, "market": 0.22, "artisan": 0.22,
                "residential": 0.34, "production": 0.14}
ZONE_CN = {"core": "核心", "market": "市场", "artisan": "工匠",
           "residential": "居住", "production": "生产"}

# ── §4.1 规模分级（4 既有档 + townlet/burgh 过渡档 + capital/metropolis 行政档） ──
# **零漂移硬约束（SPECIAL_DEFS 表头既律）**：既有 4 行一个数字都不动——TIER_ORDER
# 整数是 `_rng_for` 的种子盐与街具数公式的输入，改了即全档漂移。新档：
#   · TIER_ORDER 续 4~7（只作 rng 盐；街具数/塔间距等新档一律用本表**显式参数**，
#     见 §7.4 第 9 条）；
#   · 过渡档 = 低档建筑池拷贝 + 解锁 1~2 个高档 def（townlet 解锁 tavern/bakery+
#     教堂 w12 首现；burgh 解锁 smithy4/mage_tower），行政建筑按任务书 §二进 core
#     forced（moot_hall/city_hall）；
#   · capital/metropolis 按任务书折中方案 = 同一参数化管线 + 专属建筑池
#     （GDD 口径 T5"单独建筑集"不走常规档——是否另起管线提请创始人裁决，见任务书
#     §7.4 第 8 条）；行政建筑（governor_palace/imperial_palace）进 core forced 且
#     以 tower_h 800/1040 **首次夺天际线最高点**（教堂 630 压其下）。
# street_band/plaza_band/tower_gap/n_props 为 verify_plan 与街具数的**按档显式值**；
# 既有 4 档不带这些键 → .get 默认值逐位复现旧行为（checks 输出也零漂移）。
TIER_ORDER = {"hamlet": 0, "village": 1, "town": 2, "city": 3,
              "townlet": 4, "burgh": 5, "capital": 6, "metropolis": 7}
TIER_SPECS = {
    "hamlet": dict(cols=80, width_px=2560, wall_h=140, wall_tier=1, n=(10, 12),
                   street=2, lot_rows=2, plaza=None, margin=2, side_roads=1),
    "village": dict(cols=96, width_px=3072, wall_h=220, wall_tier=1, n=(14, 16),
                    street=2, lot_rows=2, plaza=6, margin=2, side_roads=1),
    "town": dict(cols=128, width_px=4096, wall_h=320, wall_tier=2, n=(18, 22),
                 street=3, lot_rows=3, plaza=8, margin=3, side_roads=2),
    "city": dict(cols=192, width_px=6144, wall_h=420, wall_tier=2, n=(26, 32),
                 street=3, lot_rows=3, plaza=10, margin=3, side_roads=4),
    # ── 以下为新档（任务书 §一表；提案/待定） ─────────────────────────────
    "townlet": dict(cols=112, width_px=3584, wall_h=270, wall_tier=1, n=(16, 18),
                    street=2, lot_rows=3, plaza=6, margin=2, side_roads=1,
                    n_props=9, tower_gap=(800, 1200), street_band=(2, 3),
                    plaza_band=(6, 10)),
    "burgh": dict(cols=160, width_px=5120, wall_h=370, wall_tier=2, n=(22, 26),
                  street=3, lot_rows=3, plaza=8, margin=3, side_roads=3,
                  n_props=12, tower_gap=(800, 1200), street_band=(2, 3),
                  plaza_band=(6, 10)),
    "capital": dict(cols=256, width_px=8192, wall_h=520, wall_tier=3, n=(40, 48),
                    street=4, lot_rows=3, plaza=12, margin=4, side_roads=5,
                    n_props=18, tower_gap=(700, 1000), street_band=(3, 4),
                    plaza_band=(6, 16)),
    "metropolis": dict(cols=384, width_px=12288, wall_h=640, wall_tier=3,
                       n=(60, 72), street=5, lot_rows=3, plaza=16, margin=4,
                       side_roads=6, n_props=24, tower_gap=(600, 900),
                       street_band=(4, 6), plaza_band=(6, 16)),
}

# ── 每档元数据（消费端读：地面分段区带 / 天际线地标槽位 / 行政建筑） ────────
# ground_bands：ground_tiles 的三区带（center 石板 / mid 旧砖 / edge 夯土），
#   沿交接档「规模包含」口径（村=edge 子集、镇=mid+edge、城=全档）；
# landmark：天际线唯一最高点（def, 顶高 px），与 DEFS 的 tower_h 联动登记；
# admin：行政建筑 def 名（任务书 §二阶梯；None = 无专职，hamlet 井+礼拜堂为中心）。
TIER_META = {
    "hamlet":     dict(ground_bands=["edge"],
                       landmark=("chapel", 390), admin=None),
    "village":    dict(ground_bands=["edge"],
                       landmark=("chapel", 390), admin="council_hall"),
    "townlet":    dict(ground_bands=["edge"],
                       landmark=("church", 630), admin="town_hall"),
    "town":       dict(ground_bands=["mid", "edge"],
                       landmark=("church", 630), admin="town_hall"),
    "burgh":      dict(ground_bands=["mid", "edge"],
                       landmark=("church", 630), admin="city_hall"),
    "city":       dict(ground_bands=["center", "mid", "edge"],
                       landmark=("church", 630), admin="city_hall"),
    "capital":    dict(ground_bands=["center", "mid", "edge"],
                       landmark=("governor_palace", 882), admin="governor_palace"),
    "metropolis": dict(ground_bands=["center", "mid", "edge"],
                       landmark=("imperial_palace", 1068), admin="imperial_palace"),
}

# ── §3.3 建筑规格表 ─────────────────────────────────────────────────────
# widths 允许宽度档 / wall_h 墙高 / roof 屋顶 rise / tower_h 竖向 landmark 顶高（含尖顶）
# depth 平面进深（格）/ wall_mat·roof_mat·variant 材质与色差档（§5.1 茅草新/旧等）
#
# **宽度下限 = 可装配下限**：带门建筑 §8.2 已取消 4 格档（门 150 + 楣梁装不下），
# 且每个 def 只能装配到它映射的装配器支持的最小档。布局器一旦排出更窄的 lot，
# 渲染端只能拿超宽建筑去填 → 撑出地块压邻居。故 widths 的最小值必须 ≥ 装配器最小档：
#   cottage 6 / house·shop·shelter·stable 8 / smithy2·smithy3·church·townhouse 12 /
#   smithy4 12 / tavern 12 / chapel 8 / market_stall 8（道具型，见探针的 PROP_LOTS）
DEFS = {
    "cottage":       dict(cn="茅草农舍", widths=[6, 8],          wall_h=200, roof=110,
                          depth=5, wall_mat="plaster", roof_mat="thatch", variant="old"),
    "house":         dict(cn="民居",     widths=[8, 12],         wall_h=210, roof=115,
                          depth=6, wall_mat="plaster", roof_mat="thatch", variant="new"),
    "townhouse":     dict(cn="木骨街屋", widths=[12, 16],        wall_h=390, roof=120,
                          depth=7, wall_mat="plaster_timber", roof_mat="tile", variant="a"),
    "plaster_house": dict(cn="抹灰街屋", widths=[8, 12],         wall_h=390, roof=110,
                          depth=7, wall_mat="plaster", roof_mat="slate", variant="a"),
    "tavern":        dict(cn="酒馆",     widths=[12],            wall_h=400, roof=120,
                          depth=7, wall_mat="wood", roof_mat="tile", variant="a"),
    "bakery":        dict(cn="面包房",   widths=[8, 12],         wall_h=380, roof=105,
                          depth=7, wall_mat="brick", roof_mat="tile", variant="b"),
    "shop":          dict(cn="商铺",     widths=[8],             wall_h=205, roof=115,
                          depth=5, wall_mat="wood", roof_mat="thatch", variant="new"),
    "guildhall":     dict(cn="行会馆",   widths=[12, 16],        wall_h=430, roof=130,
                          depth=8, wall_mat="stone", roof_mat="tile", variant="a"),
    "hayloft":       dict(cn="草棚顶民居", widths=[8, 12],       wall_h=325, roof=115,
                          depth=7, wall_mat="plaster", roof_mat="thatch", variant="old"),
    "smithy1":       dict(cn="茅草棚工坊", widths=[6, 8],        wall_h=190, roof=130,
                          depth=5, wall_mat="timber", roof_mat="thatch", variant="old"),
    "smithy2":       dict(cn="木屋工坊", widths=[8, 12],         wall_h=210, roof=130,
                          depth=5, wall_mat="plank", roof_mat="plank", variant="a"),
    "smithy3":       dict(cn="石砌工坊", widths=[8, 12],         wall_h=220, roof=95,
                          depth=5, wall_mat="stone", roof_mat="slate", variant="a"),
    "smithy4":       dict(cn="砖石行会", widths=[12, 16],        wall_h=235, roof=120,
                          depth=6, wall_mat="brick", roof_mat="tile", variant="c"),
    "church":        dict(cn="教堂",     widths=[12, 16],        wall_h=280, roof=150,
                          tower_h=630, depth=10, wall_mat="stone", roof_mat="slate",
                          variant="a", aspect_exempt=True),
    "chapel":        dict(cn="小礼拜堂", widths=[8],             wall_h=200, roof=100,
                          tower_h=390, depth=6, wall_mat="stone", roof_mat="slate",
                          variant="b", aspect_exempt=True),
    "tower":         dict(cn="瞭望塔",   widths=[4, 6],          wall_h=400, roof=30,
                          depth=4, wall_mat="stone", roof_mat="slate", variant="a",
                          aspect_exempt=True),
    "gatehouse":     dict(cn="城门楼",   widths=[6, 8, 12],      wall_h=300, roof=30,
                          depth=6, wall_mat="stone", roof_mat="slate", variant="c",
                          aspect_exempt=True),
    "lighthouse":    dict(cn="灯塔",     widths=[4, 6],          wall_h=400, roof=70,
                          depth=4, wall_mat="stone_white", roof_mat="slate", variant="a",
                          aspect_exempt=True),
    # shelter：装配器实际支持 4/6/8（buildings.SHELTER_TIERS），布局层**只声明 8**：
    #   ① 4/6 两档不满足 §3.2 剪影比（柱撑草棚顶高 320px ÷ 6 格 192px = 1.67 > 带顶
    #      1.40），declare 了也只是被 _aspect_ratio_ok 挡住；
    #   ② 更要紧的是 G 步降档：`_pick_width` 取首个合规档（仍 = 8），但降档候选
    #      「w_cells > min(widths)」一旦因声明 4 而降为 4，8 格草棚就成了降档候选，
    #      会被降到 6 格 → hamlet/village/town 整城漂移（实测 36 组合中 22 组变化）。
    #   故 widths 保留 [8]：城市肌理里草棚只用得到 8 格，4/6 档由 DEF_MAP（探针接线）
    #      + validate 检查 3（装配支持面逐档实测）覆盖，不属于布局层的合规档。
    "shelter":       dict(cn="草棚",     widths=[8],             wall_h=190, roof=130,
                          depth=5, wall_mat="timber", roof_mat="thatch", variant="new"),
    "barn":          dict(cn="谷仓",     widths=[8, 12, 16],     wall_h=210, roof=160,
                          depth=8, wall_mat="plank", roof_mat="plank", variant="b"),
    # stable：装配器实际支持 8/12（buildings.STABLE_TIERS），声明同一组（对齐）。
    #   实测加 12 档**零漂移**：_pick_width 取首个合规档仍 = 8（12 格的剪影比
    #   265/384 = 0.69 不达标），且 8 格马厩不因多一个更大的档而进入 G 步降档候选。
    "stable":        dict(cn="马厩",     widths=[8, 12],         wall_h=175, roof=90,
                          depth=5, wall_mat="wood", roof_mat="thatch", variant="old"),
    "windmill":      dict(cn="风车磨坊", widths=[4, 6],          wall_h=300, roof=80,
                          depth=5, wall_mat="stone", roof_mat="cone", variant="a",
                          aspect_exempt=True),
    "well":          dict(cn="水井",     widths=[4],             wall_h=120, roof=60,
                          depth=4, wall_mat="stone", roof_mat="thatch", variant="new",
                          aspect_exempt=True),
    "market_stall":  dict(cn="市集摊",   widths=[8],             wall_h=150, roof=70,
                          depth=4, wall_mat="wood", roof_mat="linen", variant="a",
                          aspect_exempt=True),
    # ── 第三轮装配器新 def（第三轮共 8 个：mage_tower/alchemy/library/barracks/
    #    warehouse/stable/shelter/hayloft；后三个已在表，stable/shelter 的宽度档
    #    与装配器对齐情况见各自的 widths 注释）
    # 顶高口径：登记 buildings.py 各 *_TIERS 的**实测 total_h**（主体 + 屋面），
    # 不登记细尖顶/悬浮件——§4.4「唯一最高点 = 核心 landmark」由它守。
    # mage_tower 例外：按塔身（不含水晶灯室与尖锥顶）登记 560，压在教堂（630）之下，
    # 否则一座塔就会夺走「唯一最高点」而违 §4.4（装配实测塔顶 ~1030px，见
    # buildings.MAGE_TOWER_TIERS；布局层只登记天际线有效体量高度）。
    "mage_tower":    dict(cn="法师塔",   widths=[4, 6, 8],      wall_h=536, roof=224,
                          tower_h=560, depth=7, wall_mat="stone", roof_mat="slate",
                          variant="mage", aspect_exempt=True),
    "alchemy":       dict(cn="炼金工坊", widths=[8, 12],         wall_h=200, roof=142,
                          depth=7, wall_mat="stone", roof_mat="tile", variant="b"),
    "library":       dict(cn="图书馆",   widths=[12, 16],        wall_h=400, roof=114,
                          depth=8, wall_mat="stone", roof_mat="slate", variant="b"),
    "barracks":      dict(cn="兵营",     widths=[12, 16],        wall_h=400, roof=110,
                          depth=8, wall_mat="stone", roof_mat="tile", variant="c"),
    "warehouse":     dict(cn="货栈",     widths=[12, 16],        wall_h=270, roof=155,
                          depth=8, wall_mat="brick", roof_mat="tile", variant="a"),
    # ── 行政建筑阶梯（任务书 §二，AI 提案/待定；装配器已由行政批次交付入
    #    buildings.py——登记名与装配器实名一致，宽度档照 COUNCIL_TIERS/
    #    TOWNHALL_TIERS/GOVERNOR_TIERS/IMPERIAL_TIERS 实测） ────────────────
    # 顶高口径与 §4.4「唯一最高点」联动：L4 总督府 882 / L5 宫殿 1068 = 该档天际线
    # 最高点（**行政建筑首次夺最高点**，教堂 630 压其下）；council_hall/town_hall
    # 压在教堂之下。充当关系：town/city 两档（零漂移硬约束）不新增 lot，由
    # plan["admin_slots"] 指认既有 guildhall lot（acting_for）。
    "council_hall":  dict(cn="村议事小屋", widths=[8],              wall_h=216, roof=104,
                          depth=6, wall_mat="timber", roof_mat="shingle", variant="a"),
    "town_hall":     dict(cn="镇政厅",   widths=[12, 16],           wall_h=430, roof=94,
                          depth=8, wall_mat="stone", roof_mat="tile", variant="a"),
    "city_hall":     dict(cn="城市政厅", widths=[16],               wall_h=430, roof=130,
                          depth=8, wall_mat="brick", roof_mat="tile", variant="a"),
    "governor_palace": dict(cn="行省总督府", widths=[16],           wall_h=641, roof=78,
                          tower_h=882, depth=14, wall_mat="brick", roof_mat="copper",
                          variant="a", aspect_exempt=True),
    "imperial_palace": dict(cn="帝国宫殿", widths=[16],             wall_h=669, roof=100,
                          tower_h=1068, depth=16, wall_mat="stone_white",
                          roof_mat="gold", variant="a", aspect_exempt=True),
    # belfry（钟楼，任务书 §五）：独立细高塔天际线点缀，走 SPECIAL_DEFS 独立通道
    # （§7.4 第 4 条；city 档按「只增不改」 specials 追加口径批准接入——既有 lots
    # 逐字段不动）。布局层只声明 4 格档：6 格砖塔身实测顶 656px 会压过教堂 630
    # （shelter 只声明 8 的同一先例）；4 格木塔身 594px 守在教堂之下。
    "belfry":        dict(cn="钟楼",     widths=[4],               wall_h=466, roof=128,
                          tower_h=594, depth=4, wall_mat="wood", roof_mat="slate",
                          variant="a", aspect_exempt=True),
    # mint（铸币厂，任务书 §五）：铁栅重门+铸币烟囱，capital 起（生产带低权重投放）。
    "mint":          dict(cn="铸币厂",   widths=[12, 16],          wall_h=422, roof=96,
                          depth=8, wall_mat="brick", roof_mat="slate", variant="a"),
    # ── 批 2 装配器（驿站族/赌场族/科研族/花店；窗口按修订版任务书，与文档命名
    #    有差异处以装配器实名为准） ─────────────────────────────────────────
    # 窗口里的 town/city 属既有档：零漂移硬约束下不动其抽签池——窗口先在此登记、
    # 接线从新四档（townlet/burgh/capital/metropolis）起步，既有档待漂移预算审批。
    # waystation 6 格档按 smithy1 w6 先例开"小物件"口子（与 4 格倍数硬约束存在
    # 口径张力，任务方知情登记）；布局层 aspect 带会把 6 档挡在 _pick_width 之外，
    # 实际只落 8 格档。inn_post/coach_house 前凸翼向基线前伸 58~72px：depth 按
    # D+翼实测总延伸取整格（探针按包围盒前缘对齐基线，登记不足后墙顶进排间巷）。
    "waystation":    dict(cn="路驿马棚", widths=[6, 8],           wall_h=200, roof=78,
                          depth=6, wall_mat="wood", roof_mat="shingle", variant="a"),
    "inn_post":      dict(cn="客栈驿站", widths=[12, 16],         wall_h=424, roof=118,
                          depth=10, wall_mat="plaster_timber", roof_mat="tile",
                          variant="a"),
    "coach_house":   dict(cn="车马行",   widths=[12, 16],         wall_h=300, roof=118,
                          depth=10, wall_mat="brick", roof_mat="slate", variant="a"),
    "gambling_den":  dict(cn="赌坊",     widths=[8, 12],          wall_h=220, roof=98,
                          depth=7, wall_mat="wood", roof_mat="tile", variant="a"),
    "grand_casino":  dict(cn="大赌场",   widths=[16],             wall_h=428, roof=100,
                          depth=9, wall_mat="plaster", roof_mat="copper", variant="a"),
    "academy":       dict(cn="学院",     widths=[12, 16],         wall_h=418, roof=96,
                          depth=8, wall_mat="stone", roof_mat="slate", variant="a"),
    # observatory：收分圆塔 → 登记天际线有效体量（塔身+铜穹顶+尖顶 390，压在教堂
    # 630 之下）；探针挂墙件按圆塔前墙面取切点（probe 的 WALL_Y_DEPTH2）。
    "observatory":   dict(cn="观星台",   widths=[8],              wall_h=320, roof=54,
                          tower_h=390, depth=6, wall_mat="stone", roof_mat="copper",
                          variant="a", aspect_exempt=True),
    "flower_shop":   dict(cn="花店",     widths=[8, 12],          wall_h=218, roof=96,
                          depth=7, wall_mat="plaster", roof_mat="tile", variant="a"),
}

#: 部分 def 的**进深随宽度档变化**（= 装配器 *_TIERS 的 D 实测值 ÷ 32 取上整）。
#: 由 J2 之后的特殊建筑投放使用：落位排的 b 带深度必须 ≥ 该档实际进深，否则后墙
#: 会压进排间巷（verify_plan ② 退线断言会打回）。DEFS[...]["depth"] 取其中的最大值。
DEPTH_BY_WIDTH = {
    "mage_tower": {4: 4, 6: 5, 8: 7},          # D = 2R：108 / 160 / 212
    "alchemy":    {8: 6, 12: 7},               # D：168 / 200
    "library":    {12: 7, 16: 8},              # D：204 / 236
    "barracks":   {12: 7, 16: 8},              # D：208 / 240
    "warehouse":  {12: 7, 16: 8},              # D：204 / 236
    "town_hall":  {12: 7, 16: 8},              # D：208 / 236
    "mint":       {12: 7, 16: 8},              # D：212 / 232
    # 总督府/宫殿：占地进深 + 前院（court/podium+大台阶）沿 y 的实测总延伸，
    # 取整格上整——装配器把前院/台阶也建在 y 负向，探针按包围盒前缘对齐基线，
    # 进深登记不足会让后墙顶进城墙带（verify ② 的口径按登记值算，须登记真值）。
    "governor_palace": {16: 14},               # D 252 + 前院 170 = 422px ≈ 13.2 格
    "imperial_palace": {16: 16},               # D 264 + 台基/大台阶 ≈ 490px ≈ 15.3 格
    # 批 2：前凸翼/雨篷向基线前伸的 def 按总延伸登记（主池 lot 用 DEFS.depth，
    # 此处供 J3 投放与登记复核；inn_post/coach_house 的 depth 字段已是总延伸）。
    "inn_post":     {12: 9, 16: 10},           # D 204/232 + 翼前伸 64/72
    "coach_house":  {12: 9, 16: 10},           # D 198/226 + 翼前伸 58/64
    "grand_casino": {16: 9},                   # D 236 + 门楼前凸 26
    "academy":      {12: 7, 16: 8},            # D：196 / 224
    "flower_shop":  {8: 6, 12: 7},             # D：158 / 196
}

# ── 特殊建筑投放：区带权重 + 出现频率克制（§4.2 / §4.1） ───────────────
# **为什么不进 ZONE_POOLS**：抽签池一旦加入新 def，B 步的 `_weighted_pick` 结果、
# 单元宽度、solve_bands 的 rng.shuffle 次数都会变 → 既有 24 def 的布局整城漂移。
# 硬约束（同 seed 逐字节一致 + 既有布局不漂移）要求新 def 走**独立通道**：J2 打包
# 完成后，把新 def 投进各带/排的院坝（yard）空段里——不新增任何 rng 取样，
# 既有 lots 的 x / 行 / 宽度逐位不变，只多出几栋稀疏的特殊建筑。
#
# zone_weight：区带权重（越大越优先；0 = 该带不许落）。区带序由中心向外：
#   core → market → artisan → residential → production（§4.2 镜像带）。
# freq：各规模档的上限（缺档默认 0 = 不出现）；特殊建筑只在镇/城级出现，
#   村档院坝余量（≤9 格）本就装不下 8~16 格建筑，且 §4.4 的礼拜堂（390）压不住
#   兵营/图书馆/货栈（425~514）——与 ZONE_POOLS 里「酒馆/面包房属镇级设施」同口径。
#   新档扩编（任务书 §7.4 第 4 条，既有档键值不动 → 既有布局 rng 逐位不变）：
#   burgh 解锁 mage_tower（法师塔 560 < 教堂 630，安全）；capital：mage_tower 1 /
#   library 2 / barracks 2；metropolis 翻倍加密。
# near：center = 贴城市中轴选段；gate = 贴左右城墙（城门在左右两端）选段。
# row_pref：front = 贴主街那排（立面与门前家什可读）；deep = 后排（塔类与大体量公共
#   建筑退后，20° 微俯视下不遮前排街面；两档落在同一 x 段时**让高者退后**，
#   免得高的把矮的整栋遮住——镇档的 12 格余段只有一处 x，兵营/货栈只能上下叠）。
#   注：deep 只影响同权重同锚点的排序，不改变区带优先（权重更高者仍先挑）。
# 档位取舍：mage_tower 只投 city——镇档中轴/市场带没有 8 格以上的余段（中轴段被
#   广场占满），而 1026px 的塔放进 344px 城墙的镇里读作"巨人"；镇档频率让给
#   warehouse（镇档真正的边缘带余量只有 8~9 格，12 格货栈只能落工匠带 16 格段）。
SPECIAL_DEFS = {
    "mage_tower": dict(zone_weight={"core": 4, "market": 3, "artisan": 1,
                                    "production": 1},
                       freq={"city": 1, "burgh": 1, "capital": 1, "metropolis": 2},
                       near="center", row_pref="deep"),
    "library":    dict(zone_weight={"core": 4, "market": 3, "artisan": 1},
                       freq={"town": 1, "city": 1, "metropolis": 2},
                       near="center", row_pref="deep"),
    "barracks":   dict(zone_weight={"production": 4, "artisan": 2, "residential": 1},
                       freq={"town": 1, "city": 1, "capital": 2, "metropolis": 2},
                       near="gate", row_pref="deep"),
    "warehouse":  dict(zone_weight={"production": 4, "artisan": 2, "residential": 1},
                       freq={"town": 1, "city": 1, "capital": 2, "metropolis": 3},
                       near="gate", row_pref="front"),
    "alchemy":    dict(zone_weight={"artisan": 4, "production": 2, "residential": 1,
                                    "market": 1},
                       freq={"town": 1, "city": 1, "capital": 2, "metropolis": 2},
                       near="gate", row_pref="front"),
    # belfry（钟楼）：行政批次交付的天际线点缀，走 J3 独立通道（任务书 §7.4 第 4
    # 条）。city 档按创始人批准的「只增不改」口径：既有 lots 逐字段不动，钟楼只以
    # specials 追加（确定性落位、不消耗既有 rng）——零漂移语义保住。freq=上限：
    # 院坝放不下就放弃（稀缺"变奏地标"，约半数城市出现属预期）。
    "belfry":     dict(zone_weight={"core": 3, "market": 2, "artisan": 1},
                       freq={"city": 1, "burgh": 1, "capital": 1, "metropolis": 2},
                       near="center", row_pref="deep"),
    # observatory（观星台，科研族 capital 识别件，批 2 交付）：同 J3 通道，
    # capital 专属（freq=1），贴中轴退后排（圆塔+铜穹顶读天际线）。
    "observatory": dict(zone_weight={"core": 3, "market": 2, "artisan": 1},
                        freq={"capital": 1}, near="center", row_pref="deep"),
}
#: 投放顺序（前面的先挑段；确定性，不消耗 rng）。追加项（belfry/observatory）排在
#: 既有五 def 之后：不参与前段挑选 → 既有档既有 def 的落位逐位不变（零漂移）。
SPECIAL_ORDER = ("library", "mage_tower", "barracks", "warehouse", "alchemy",
                 "belfry", "observatory")

# §4.4「墙顶高于 80% 建筑」中的「高建筑」= 顶高超过城墙档者
TALL_DEFS = {"townhouse", "plaster_house", "tavern", "bakery", "guildhall",
             "church", "hayloft", "lighthouse", "tower", "chapel"}

# §3.2 长宽比：表头 1:0.75~1.15 与逐档例值（4 格 110~170 / 8 格 220~340 /
# 12 格 330~500 / 16 格 440~680）换算带宽 [0.86, 1.33] 不自洽，校验取逐档例值带 + 容差
ASPECT_BAND = (0.86, 1.33)
ASPECT_TOL = 0.05

# ── §8.2 出檐留位（**可见剪影**口径，非占地框） ─────────────────────────
# 根因（烘焙图查实）：出檐 = 建筑宽 × 20.5%/侧（`buildings.eave_over`，规范带
#   18~23%），故**可见剪影宽 ≈ 占地宽 × 1.4**（实测 8 格 → 12 格 / 12 格 → 16 格 /
#   16 格 → 22 格，见 `sil_w_cells`）。相邻两栋若按**占地框**排布，两侧出檐必然互压
#   （檐口平面互相穿刺，就是"建筑重叠"的根因）：两栋 8 格民居贴排时檐口各伸 1.63 格，
#   净距 0 → 剪影互压 3.3 格；16 格货栈贴 8 格厩舍 → 互压 4.9 格。
# 口径：**排布推进按「有效占宽」= 剪影宽，不按占地宽**；两个占地框之间净距至少
#   `eave(a) + eave(b) + EAVE_NET_MIN`（EAVE_NET_MIN 见下：取 0 = 剪影可相触但
#   不互压；满铺肌理付不起"留 1 格巷"，见下一段的实测）。
#
# 【本档落实范围与结构性限制（实测数字，非估计）】
#   · **新增 def 全部按剪影留位**：J3 特殊建筑投放（SPECIAL_DEFS）从院坝空段落位时，
#     先扣掉两侧邻居的出檐（+1 格巷），剩余段必须放得下 `sil_w_cells(w)`，否则降档
#     或放弃该段（频率克制的一部分）。既有 lot 的 x/行/宽逐位不动（独立通道）。
#   · **既有 24 def 的肌理不适用**：肌理是"带宽 = 该区最宽排载荷"的满铺解
#     （solve_bands），四档的可用侧宽与 §4.1 建筑数互为约束。实测：同排相邻对的
#     可用空隙合计 **0.0 格**（city 仅 2.0 格），而按剪影口径需要 **6.6~36.5 格**；
#     单侧总需求（把 row_load 换成剪影宽后实跑）hamlet 37 > 可用 31 / village 49
#     > 39 / town 53 > 52 / city 48 ≤ 84（按区一带）。**并区（4 带并成 1 带）后**最
#     接近可行：hamlet 33 > 31（差 2 格）/ village 44 > 39（差 5）/ town 51 ≤ 52
#     （恰卡线）/ city 可行 —— 即只有镇级及以上勉强能整城按剪影排，且并区会同时抹掉
#     §4.2 的分带支路（`separators` 归零）。⇒ 属**设计口径变更**（四档总宽 ×1.4，
#     或明确下调 §4.1 建筑数 8~25%，或接受肌理檐口相接），不在布局层单方面推翻；
#     故肌理保留占地满铺，由 `verify_plan` 的 `eave` 检查**如实报出**同排剪影互压
#     对数与缺口格数供裁决。
EAVE_RATIO = 0.205
#: 剪影之间要求的最小净距（格）。取 **0 = 只要求不互压**（檐口可相触，读作连排屋
#: 檐——真实镇子的连排本就是檐口相接）；取 1 会每个相邻对多吃 2 格，实测把 J3 的
#: 大体量新 def（兵营/货栈 12~16 格 → 剪影 16~22 格）在镇/城全部挤掉：院坝是满铺
#: 肌理的余量（最大的生产带院坝实测 ~20 格），22 格的需求无段可落。故净距下限取 0，
#: "不互压"是硬门禁，"留 1 格巷"在满铺肌理里付不起。
EAVE_NET_MIN = 0


def eave_cells(w_cells: int) -> int:
    """每侧出檐（格）：与 `buildings.eave_over(grid_w)` 同口径（px 取整后换格）。"""
    return int(int(w_cells * CELL_W * EAVE_RATIO + 0.5) / float(CELL_W) + 0.5)


def sil_w_cells(w_cells: int) -> int:
    """可见剪影占宽（格）= 占地宽 + 两侧出檐 ≈ 占地宽 × 1.4。"""
    return w_cells + 2 * eave_cells(w_cells)

# ── 各区 def 池（forced 必配；weight 剩余槽位按权重抽） ──────────────────
ZONE_POOLS = {
    "hamlet": {
        "core":        dict(forced=["chapel"], weight=[]),
        # 无广场档：水井不进市场带，按 §4.1「教堂/水井为中心」落核心带 row0 中轴
        # （见 plan_city 的 special_well）；市场带抽签数相应减 1 以守 §4.2 配比
        "market":      dict(forced=["shop"], weight=[("shop", 3), ("market_stall", 2)]),
        "artisan":     dict(forced=["smithy1"], weight=[("stable", 3), ("smithy2", 2)]),
        "residential": dict(forced=["house"], weight=[("house", 3), ("cottage", 4)]),
        "production":  dict(forced=["shelter"], weight=[("windmill", 1)]),
    },
    "village": {
        "core":        dict(forced=["chapel"], weight=[]),
        # 村档市场不含 2 层街屋档（§3.3 酒馆/面包房是 2 层，属镇级设施）：
        # 否则 520px 的酒馆会盖过 390px 的礼拜堂，违 §4.4 唯一最高点
        "market":      dict(forced=["shop"], weight=[("market_stall", 3), ("shop", 2)]),
        "artisan":     dict(forced=["smithy1"], weight=[("stable", 3), ("smithy2", 3),
                                                         ("smithy3", 1)]),
        # 村档居住同样不含 2 层档（抹灰街屋 500 会盖过 390 的礼拜堂）
        "residential": dict(forced=["house"], weight=[("house", 3), ("cottage", 4)]),
        "production":  dict(forced=["barn"], weight=[("shelter", 3), ("windmill", 1)]),
    },
    "town": {
        "core":        dict(forced=["church", "guildhall"], weight=[]),
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 4), ("market_stall", 2)]),
        "artisan":     dict(forced=["smithy2", "smithy3"],
                            weight=[("stable", 3), ("hayloft", 1)]),
        "residential": dict(forced=["house", "townhouse"],
                            weight=[("house", 4), ("cottage", 3), ("plaster_house", 2)]),
        "production":  dict(forced=["barn"], weight=[("shelter", 3), ("windmill", 2)]),
    },
    "city": {
        "core":        dict(forced=["church", "guildhall"], weight=[("chapel", 1)]),
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 5), ("market_stall", 3)]),
        "artisan":     dict(forced=["smithy2", "smithy3"],
                            weight=[("smithy1", 2), ("smithy4", 3), ("stable", 2),
                                    ("hayloft", 1)]),
        "residential": dict(forced=["house", "townhouse"],
                            weight=[("house", 5), ("cottage", 3), ("plaster_house", 2)]),
        "production":  dict(forced=["barn"], weight=[("barn", 2), ("shelter", 3),
                                                     ("windmill", 1)]),
    },
    # ── 新档池（任务书 §7.4 第 2 条：过渡档 = 低档池拷贝 + 解锁 1~2 个高档 def；
    #    首府/首都 = 专属池，行政建筑进 core forced。注意：SPECIAL_DEFS 管的
    #    mage_tower/library/barracks/warehouse/alchemy 走 J3 独立通道，
    #    **不得**进抽签池——否则抽签 rng 漂移 + 双重落位） ──────────────────
    # townlet（村镇过渡）：村池底子 + 解锁 tavern/bakery（市场带）+ 教堂 w12 首现
    #   （替代礼拜堂守 630 天际线）+ town_hall（行政 L2，w12 档）进 core。
    "townlet": {
        "core":        dict(forced=["church", "town_hall"], weight=[]),
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 3), ("market_stall", 2)]),
        "artisan":     dict(forced=["smithy1"], weight=[("stable", 3), ("smithy2", 3),
                                                        ("smithy3", 1)]),
        "residential": dict(forced=["house"], weight=[("house", 3), ("cottage", 4)]),
        "production":  dict(forced=["barn"], weight=[("shelter", 3), ("windmill", 1),
                                                     ("waystation", 1)]),
    },
    # burgh（城镇过渡）：镇池底子 + 解锁 smithy4（工匠带）/mage_tower（J3 频率 1）
    #   + city_hall（行政 L3，过渡期 guildhall[16] 兼当装配）。
    "burgh": {
        "core":        dict(forced=["church", "city_hall"], weight=[("chapel", 1)]),
        # 批 2 窗口（burgh 起）：赌坊/花店/客栈入市场带，学院入工匠带（core 候补
        # 待 core_count 参数化后再进 core），路驿入生产带。
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 5), ("market_stall", 3),
                                    ("gambling_den", 1), ("flower_shop", 1),
                                    ("inn_post", 1)]),
        "artisan":     dict(forced=["smithy2", "smithy3"],
                            weight=[("smithy4", 2), ("stable", 3), ("hayloft", 1),
                                    ("academy", 1)]),
        "residential": dict(forced=["house", "townhouse"],
                            weight=[("house", 4), ("cottage", 3), ("plaster_house", 2)]),
        "production":  dict(forced=["barn"], weight=[("shelter", 3), ("windmill", 2),
                                                     ("waystation", 1)]),
    },
    # capital（行省首府）：总督府进 core forced（tower_h 882 夺天际线最高点）；
    #   生产带解锁 mint 铸币厂（低权重保稀缺，软上限 ~1 座）；工匠/公共建筑靠
    #   J3 频率 library 2 / barracks 2 / warehouse 2 / belfry 加密。
    "capital": {
        "core":        dict(forced=["church", "governor_palace"], weight=[("chapel", 1)]),
        # 批 2 窗口（city 起，city 属既有档故从 capital 落地）：赌坊/花店/客栈/
        # 大赌场入市场带，车马行入工匠带；academy 接管 library 的学术位（library
        # 的 capital freq 撤除，town/city/metropolis 不变）。
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 5), ("market_stall", 3),
                                    ("gambling_den", 1), ("grand_casino", 1),
                                    ("flower_shop", 1), ("inn_post", 1)]),
        "artisan":     dict(forced=["smithy2", "smithy3"],
                            weight=[("smithy1", 2), ("smithy4", 3), ("stable", 2),
                                    ("hayloft", 1), ("coach_house", 1),
                                    ("academy", 2)]),
        "residential": dict(forced=["house", "townhouse"],
                            weight=[("house", 5), ("cottage", 2), ("plaster_house", 3)]),
        "production":  dict(forced=["barn"], weight=[("barn", 2), ("shelter", 3),
                                                     ("windmill", 1), ("mint", 1)]),
    },
    # metropolis（帝国首都）：宫殿进 core forced（tower_h 1068 = 全链最高点）；
    #   任务书折中方案 = 同一参数化管线 + 专属池（不另起 T5 独立管线，§7.4 第 8 条
    #   是否保留独立管线提请创始人裁决）。
    "metropolis": {
        "core":        dict(forced=["church", "imperial_palace"], weight=[("chapel", 1)]),
        # 批 2 窗口：与 capital 同批入带（academy 权重降为 1，library 保留 2）。
        "market":      dict(forced=["tavern", "bakery"],
                            weight=[("shop", 5), ("market_stall", 3),
                                    ("gambling_den", 1), ("grand_casino", 1),
                                    ("flower_shop", 1), ("inn_post", 1)]),
        "artisan":     dict(forced=["smithy2", "smithy3"],
                            weight=[("smithy1", 2), ("smithy4", 3), ("stable", 2),
                                    ("hayloft", 1), ("coach_house", 1),
                                    ("academy", 1)]),
        "residential": dict(forced=["house", "townhouse"],
                            weight=[("house", 5), ("cottage", 2), ("plaster_house", 3)]),
        "production":  dict(forced=["barn"], weight=[("barn", 2), ("shelter", 3),
                                                     ("windmill", 1), ("mint", 1)]),
    },
}

# 高楼预算（占总数比例）：§4.4 要求墙顶高于 80% 建筑 → 高楼占比 ≤ 20%。
# 小档城墙矮（140/220），该规则与 §4.1 档位本身不自洽 → 预算放宽，校验项记录冲突。
# 新档按任务书 §7.4 第 5 条统一取 0.20（显式按档登记，既有 4 档不动）。
MAX_TALL_RATIO = {"hamlet": 0.30, "village": 0.30, "town": 0.30, "city": 0.20,
                  "townlet": 0.20, "burgh": 0.20, "capital": 0.20,
                  "metropolis": 0.20}

# ── 行政建筑槽位（任务书第 2 节） ────────────────────────────────────────
# · 实装档（新 4 档）：行政 def 进 core forced，落位后 lot 打 `role="admin"` 标记；
# · 充当档（town/city，零漂移硬约束）：不新增/不改既有 lots——由 plan["admin_slots"]
#   指认既有 guildhall lot（acting_for = 任务书行政名）；
# · 预留档（village）：moot_hall 装配器未落地 + 零漂移不许动 lots → admin_slots 记
#   status="reserved" 的槽位（井旁核心带），待漂移预算审批后实装。
ADMIN_LOT_DEFS = ("council_hall", "town_hall", "city_hall", "governor_palace",
                  "imperial_palace")
#: 充当关系：tier → (既有 def, 任务书行政名)。行政装配器已交付（council_hall/
#: town_hall/governor_palace/imperial_palace），town/city 仍按零漂移硬约束由
#: 既有 guildhall lot 充当（drift 预算批准后可换真装配器 lot）。
ADMIN_ACTING = {"town": ("guildhall", "town_hall"), "city": ("guildhall", "city_hall")}


# ══════════════════════════════════════════════════════════════════════════
# 工具
# ══════════════════════════════════════════════════════════════════════════
def def_top_h(name: str) -> int:
    """建筑顶高（px）：竖向 landmark 取钟楼/塔顶，其余取墙高 + 屋顶 rise。"""
    d = DEFS[name]
    return int(d.get("tower_h") or (d["wall_h"] + d["roof"]))


def _material_id(name: str) -> tuple:
    d = DEFS[name]
    return (d["wall_mat"], d["roof_mat"], d["variant"])


def _compatible(a: str, b: str) -> bool:
    """§4.4 禁止等高建筑连排：相邻两者须高差 ≥15% 或材质/颜色不同。"""
    if a == b:
        return False
    ta, tb = def_top_h(a), def_top_h(b)
    if abs(ta - tb) / max(ta, tb) >= 0.15:
        return True
    return _material_id(a) != _material_id(b)


def _aspect_ratio_ok(name: str, w_cells: int, tol: float = ASPECT_TOL) -> bool:
    d = DEFS[name]
    if d.get("aspect_exempt"):
        return True
    facade = w_cells * CELL_W
    lo, hi = ASPECT_BAND
    return (lo * (1 - tol)) * facade <= def_top_h(name) <= (hi * (1 + tol)) * facade


def _has_compliant_width(name: str) -> bool:
    return any(_aspect_ratio_ok(name, w) for w in DEFS[name]["widths"])


def _pick_width(name: str) -> int:
    """优先满足 §3.2 的最小允许宽度；无合规档位时取最大允许宽度。"""
    ws = DEFS[name]["widths"]
    ok = [w for w in ws if _aspect_ratio_ok(name, w)]
    return ok[0] if ok else max(ws)


def _rng_for(tier: str, seed: int) -> random.Random:
    """确定性 rng：不用 hash()（PYTHONHASHSEED 不稳定）。"""
    return random.Random(int(seed) * 7919 + TIER_ORDER[tier] * 104729 + 13)


def _weighted_pick(rng, items):
    total = sum(w for _, w in items)
    if total <= 0:
        return items[0][0]
    r = rng.random() * total
    acc = 0.0
    for v, w in items:
        acc += w
        if r <= acc:
            return v
    return items[-1][0]


def _order_defs(rng, defs):
    """把一个区的 def 多重集排成列：相邻不同 def 且不违 §4.4。返回 (序列, 违规数)。"""
    best, best_bad = None, 10 ** 9
    for _ in range(240):
        pool = list(defs)
        rng.shuffle(pool)
        out, bad = [], 0
        while pool:
            cnt = Counter(pool)
            cand = [i for i, d in enumerate(pool)
                    if (not out) or _compatible(out[-1], d)]
            if not cand:
                cand = [0]
                bad += 1
            pick = max(cand, key=lambda i: (cnt[pool[i]], -i))
            out.append(pool.pop(pick))
        if bad < best_bad:
            best, best_bad = out, bad
        if bad == 0:
            break
    return best, best_bad


def _push_yard(yards, x0, x1, row, zone, side):
    """记一段院坝/田地；1 格空隙留给巷道，不记。"""
    if x1 - x0 >= 2:
        yards.append({"x0": int(x0), "x1": int(x1), "row": int(row), "zone": zone,
                      "side": side,
                      "kind": "field" if zone == "production" else "yard"})


def _eave_deficit(row_lots, edge_x, to_left):
    """在院坝边缘 `edge_x` 处，为该侧邻居的**出檐 + 1 格巷**还缺几格（0 = 已够）。

    剪影口径（§8.2，见 EAVE_RATIO 段）：本栋占地框到邻居占地框的净距至少要
    `eave(邻居) + eave(本栋) + EAVE_NET_MIN`。本栋那半由 `sil_w_cells(w) ≤ span`
    保证，本函数只管**邻居那半**：院坝边缘到邻居实际空隙不足「邻居出檐 + 净距」的
    部分从院坝里扣掉（`to_left=True` 找左邻，False 找右邻；无邻居 = 段外是巷道/墙 → 0）。
    """
    if to_left:
        nb = [l for l in row_lots if l["x_cells"][1] <= edge_x]
        if not nb:
            return 0
        n = max(nb, key=lambda l: l["x_cells"][1])
        gap = edge_x - n["x_cells"][1]
    else:
        nb = [l for l in row_lots if l["x_cells"][0] >= edge_x]
        if not nb:
            return 0
        n = min(nb, key=lambda l: l["x_cells"][0])
        gap = n["x_cells"][0] - edge_x
    return int(max(0, eave_cells(n["w_cells"]) + EAVE_NET_MIN - gap))


def _split_sides(defs):
    """左右分侧：逐 def 交替分配，保证每侧 def 混合（可排出不相邻同 def 的序）。"""
    by_def = {}
    for d in defs:
        by_def.setdefault(d, []).append(d)
    left, right = [], []
    for name in sorted(by_def):
        for i, d in enumerate(by_def[name]):
            (left if i % 2 == 0 else right).append(d)
    return left, right


def build_admin_slots(tier: str, lots: list, cols: int) -> list:
    """行政建筑槽位（任务书第 2 节）：写在 plan["admin_slots"]，消费端可识别。

    · 实装（新 4 档）：行政 def 的 lot 打 `role="admin"`，槽位指认该 lot；
    · 充当（town/city，零漂移）：指认既有 guildhall lot，acting_for 记任务书行政名；
    · 预留（village）：moot_hall 待装配器落地 + 漂移预算审批，槽位只登记不落 lot；
    · hamlet 无专职（井+礼拜堂为中心）→ 空表。
    """
    slots = []
    for l in lots:
        if l["def"] in ADMIN_LOT_DEFS:
            l["role"] = "admin"
            slots.append({"role": "admin", "def": l["def"], "def_cn": l["def_cn"],
                          "status": "built", "lot_index": l["index"],
                          "x_cells": list(l["x_cells"]), "row": l["row"],
                          "baseline_y": l["baseline_y"],
                          "top_h_px": l["top_h_px"]})
    if tier in ADMIN_ACTING:
        acting, admin_def = ADMIN_ACTING[tier]
        for l in lots:
            if l["def"] == acting and l["zone"] == "core":
                slots.append({"role": "admin", "def": acting, "admin_def": admin_def,
                              "def_cn": "%s（兼%s）" % (DEFS[acting]["cn"],
                                                       DEFS[admin_def]["cn"]),
                              "status": "built", "acting_for": admin_def,
                              "lot_index": l["index"],
                              "x_cells": list(l["x_cells"]), "row": l["row"],
                              "baseline_y": l["baseline_y"],
                              "top_h_px": l["top_h_px"],
                              "note": "任务书 §二：guildhall 直接充当；零漂移硬约束下"
                                      "不改既有 lots，DRESS 语义变体待装配器批次"})
                break
    if tier == "village":
        slots.append({"role": "admin", "def": "council_hall",
                      "def_cn": DEFS["council_hall"]["cn"], "status": "reserved",
                      "lot_index": None, "row": 0, "zone": "core",
                      "x_cells": [cols // 2 - 4, cols // 2 + 4],
                      "note": "任务书 §二 L1：井旁核心带预留槽位（装配器 council_hall "
                              "w8 已交付）；零漂移硬约束下暂不落 lot，按漂移预算审批接入"})
    return slots


# ══════════════════════════════════════════════════════════════════════════
# 主求解
# ══════════════════════════════════════════════════════════════════════════
def plan_city(tier: str, seed: int = 611036, width_px: int = None,
              depth_cells: int = None, has_gate: bool = None,
              has_plaza: bool = None, n_buildings: int = None,
              wall: bool = True) -> dict:
    """求解一个规模档的城镇平面布局。返回 JSON-able dict（同 tier+seed 结果确定）。"""
    if tier not in TIER_SPECS:
        raise ValueError("未知规模档 %r（可选 %s）" % (tier, sorted(TIER_SPECS)))
    spec = TIER_SPECS[tier]
    rng = _rng_for(tier, seed)

    # ── A 规模与数量 ────────────────────────────────────────────────────
    cols = int(width_px // CELL_W) if width_px else spec["cols"]
    width_px = cols * CELL_W
    n_total = int(n_buildings or spec["n"][1])
    n_total = max(spec["n"][0], min(spec["n"][1], n_total))
    # 核心区建筑巨大（教堂 10 + 行会馆 12 格），数量按 §4.2 取整会撑爆核心带 →
    # 核心数按档固定（小档 1 座礼拜堂 / 大档 2 座教堂+行会馆），其余按权重最大余数法分配
    core_count = 1 if tier in ("hamlet", "village") else 2
    rest = [z for z in ZONE_ORDER if z != "core"]
    rest_w = sum(ZONE_WEIGHTS[z] for z in rest)
    left = n_total - core_count
    counts = {z: max(1, int(left * ZONE_WEIGHTS[z] / rest_w)) for z in rest}
    # 贪心补足剩余：每次给「相对 §4.2 目标最亏」的区 +1（直接压最大偏差）
    while sum(counts.values()) < left:
        tot = sum(counts.values())
        z = max(rest, key=lambda q: (ZONE_WEIGHTS[q] * tot - counts[q],
                                     -ZONE_ORDER.index(q)))
        counts[z] += 1
    while sum(counts.values()) > left:
        tot = sum(counts.values())
        z = min(rest, key=lambda q: (ZONE_WEIGHTS[q] * tot - counts[q],
                                     ZONE_ORDER.index(q)))
        if counts[z] <= 1:
            z = [q for q in rest if counts[q] > 1][0]
        counts[z] -= 1
    counts["core"] = core_count

    plaza_w = spec["plaza"]
    if has_plaza is False:
        plaza_w = None
    if has_plaza is True and plaza_w is None:
        plaza_w = 6
    if has_gate is None:
        has_gate = True

    street_w = spec["street"]
    lot_rows = spec["lot_rows"]
    margin = spec["margin"]
    wall_h = spec["wall_h"] if wall else 0
    wall_th = 1 if wall else 0

    # ── B 抽 def ────────────────────────────────────────────────────────
    # §4.1 无广场档（hamlet）：水井不进市场带，改按「教堂/水井为中心」落在核心带
    # row0 中轴（见下 special_well），故市场抽签槽位让出 1 个以守 §4.2 配比。
    special_well = plaza_w is None
    draw_counts = dict(counts)
    if special_well:
        draw_counts["market"] = max(1, draw_counts["market"] - 1)

    tall_budget = int(n_total * MAX_TALL_RATIO[tier])
    defs_by_zone = {}
    for z in ZONE_ORDER:
        pool = ZONE_POOLS[tier][z]
        chosen = list(pool["forced"])
        slots = draw_counts[z] - len(chosen)
        tall_used = sum(1 for d in chosen if d in TALL_DEFS)
        soft_cap = {}
        if pool["weight"]:
            tot_w = sum(w for _, w in pool["weight"])
            for d, w in pool["weight"]:
                soft_cap[d] = max(1, int(round(draw_counts[z] * w / tot_w)))
        for _ in range(max(0, slots)):
            cand = []
            for d, w in pool["weight"]:
                if d in TALL_DEFS and tall_used >= tall_budget:
                    continue
                if sum(1 for x in chosen if x == d) >= soft_cap.get(d, 99):
                    continue
                cand.append((d, w))
            if not cand:      # 软上限卡死 → 放开软上限（仍守高楼预算）
                cand = [(d, w) for d, w in pool["weight"]
                        if not (d in TALL_DEFS and tall_used >= tall_budget)]
            if not cand:      # 该区无 weight（core）→ 复用 forced 首个
                cand = [(pool["forced"][0], 1.0)]
            d = _weighted_pick(rng, cand)
            chosen.append(d)
            if d in TALL_DEFS:
                tall_used += 1
        defs_by_zone[z] = chosen

    # ── C/D 分侧 + 选宽（同排相邻的 def 排序放到行分配之后，见下） ────────
    def build_zone_units(z):
        """核心区不左右分（独占中轴带）；其余区按「宽度均衡 + 同 def 摊到两侧」分侧。"""
        if z == "core":
            return [{"side": "center", "def": d, "w_cells": _pick_width(d)}
                    for d in sorted(defs_by_zone[z])]
        us = [{"def": d, "w_cells": _pick_width(d)} for d in defs_by_zone[z]]
        us.sort(key=lambda u: (-u["w_cells"], u["def"]))
        sides = {"left": [], "right": []}
        for u in us:
            def key(s):
                arr = sides[s]
                return (sum(1 for x in arr if x["def"] == u["def"]),
                        sum(x["w_cells"] for x in arr),
                        0 if s == "left" else 1)
            sides[min(("left", "right"), key=key)].append(u)
        return [{"side": s, "def": u["def"], "w_cells": u["w_cells"]}
                for s in ("left", "right") for u in sides[s]]

    units = {z: build_zone_units(z) for z in ZONE_ORDER}

    def zone_sides(z):
        return ["center"] if z == "core" else ["left", "right"]

    def order_in_rows(row_units):
        """行分配后按排排序：只有同排真正相邻的单元才需守 §4.4 连排规则。"""
        bad_total = 0
        for key, us in list(row_units.items()):
            if len(us) < 2:
                continue
            ordered, bad = _order_defs(rng, [u["def"] for u in us])
            bad_total += bad
            by_def = {}
            for u in us:
                by_def.setdefault(u["def"], []).append(u)
            row_units[key] = [by_def[d].pop(0) for d in ordered]
        return bad_total

    def zone_rows(z):
        if z == "core":
            return [lot_rows - 1] if lot_rows == 1 else [lot_rows - 2, lot_rows - 1]
        if z == "production":
            return [lot_rows - 1, lot_rows - 2] if lot_rows > 1 else [0]
        return list(range(lot_rows))

    side_zones = ["market", "artisan", "residential", "production"]

    # ── E/F/G 行分配 → 带宽 → 降档循环 ─────────────────────────────────
    def row_load(built):
        """一排所需临街宽：Σ宽 + 小巷数（每 4~6 栋 1 格，取下限 4 取最坏情况）。"""
        gaps = (max(0, len(built) - 1)) // ALLEY_EVERY[0]
        return sum(u["w_cells"] for u in built) + gaps

    def grouping_variants():
        """带结构降级方案：每区一带 → 取消分隔 → 由外向内并区（小档放不下 9 条带时）。

        并区只合并相邻功能区，带内仍按「由中心向两侧」(§4.2) 的顺序落位，
        故分区的空间秩序不变，只是区界由「支路/巷」退化为「同带内的 1 格巷」。
        """
        r0 = ROAD_W if spec["side_roads"] >= 1 else ALLEY_W
        r1 = ROAD_W if spec["side_roads"] >= 2 else ALLEY_W
        yield ([["market"], ["artisan"], ["residential"], ["production"]],
               [r0, r1, ALLEY_W, ALLEY_W])
        yield ([["market"], ["artisan"], ["residential"], ["production"]],
               [r0, ALLEY_W, ALLEY_W, ALLEY_W])
        yield ([["market"], ["artisan"], ["residential"], ["production"]],
               [r0, 0, 0, 0])
        yield ([["market"], ["artisan"], ["residential", "production"]],
               [r0, ALLEY_W, 0])
        yield ([["market", "artisan"], ["residential", "production"]], [r0, 0])
        yield ([["market", "artisan", "residential", "production"]], [r0])

    def solve_bands(max_tries=80):
        last_err = None
        for groups, sep_w_list in grouping_variants():
            for _ in range(max_tries):
                row_units = {}
                band_w = {}
                for z in ZONE_ORDER:
                    rows = zone_rows(z)
                    slots = {r: [] for r in rows}
                    for side in zone_sides(z):
                        sus = [u for u in units[z] if u["side"] == side]
                        if not sus:
                            continue
                        if z == "core":
                            # 最高 def → 最深排（§4.4 唯一最高点位于中心偏后）
                            sus = sorted(sus, key=lambda u: (-def_top_h(u["def"]),
                                                             u["def"]))
                            deep = rows[-1]
                            first = sus.pop(0)
                            row_units.setdefault((z, side, deep), []).append(first)
                            slots[deep].append(first)
                        else:
                            sus = sorted(sus, key=lambda u: (-u["w_cells"], u["def"]))
                        for u in sus:
                            # 优先级：同 def 摊到别排（防同 def 相邻）→ 载荷均衡 → 前面优先
                            idx = min(range(len(rows)),
                                      key=lambda i: (
                                          sum(1 for x in slots[rows[i]]
                                              if x["def"] == u["def"]),
                                          row_load(slots[rows[i]]), i))
                            r = rows[idx]
                            row_units.setdefault((z, side, r), []).append(u)
                            slots[r].append(u)
                    band_w[z] = max([row_load(slots[r]) for r in rows] + [1])
                order_bad = order_in_rows(row_units)
                # 合并带的宽 = 该带各区「同排」载荷之和 + 区内区界巷
                for side in ("left", "right"):
                    for g in groups:
                        loads = []
                        for r in range(lot_rows):
                            tot = (len(g) - 1) * ALLEY_W
                            for z in g:
                                tot += row_load(row_units.get((z, side, r), []))
                            loads.append(tot)
                        band_w[("g", side, tuple(g))] = max(loads + [1])
                # 核心带居中 → 左右两侧各自可用宽 = (cols-core_w)//2 - 墙 - 净空
                avail_side = (cols - band_w["core"]) // 2 - wall_th - margin
                side_used = {s: (sum(band_w[("g", s, tuple(g))] for g in groups)
                                 + sum(sep_w_list)) for s in ("left", "right")}
                if max(side_used.values()) <= avail_side:
                    return (row_units, band_w, groups, sep_w_list, avail_side,
                            side_used)
                last_err = ("档 %s：核心 %d 格，单侧需 %s > 可用 %d（总宽 %dpx）"
                            % (tier, band_w["core"], side_used, avail_side,
                               cols * CELL_W))
                cands = [u for z in ZONE_ORDER for u in units[z]
                         if u["w_cells"] > min(DEFS[u["def"]]["widths"])]
                if not cands:
                    break
                cands.sort(key=lambda u: (-u["w_cells"], u["def"]))
                u = cands[0]
                smaller = [w for w in DEFS[u["def"]]["widths"] if w < u["w_cells"]]
                ok_ws = [w for w in smaller if _aspect_ratio_ok(u["def"], w)]
                u["w_cells"] = ok_ws[0] if ok_ws else max(smaller)
        raise ValueError(last_err or ("档 %s 迭代降档失败" % tier))

    row_units, band_w, groups, sep_list, avail_side, side_used = solve_bands()

    # 余量按 §4.2 权重摊进本侧各带（核心带留紧，护广场 6~10 格；最大余数法保证精确）
    wsum = sum(ZONE_WEIGHTS[z] for z in ZONE_ORDER if z != "core")
    band_slack = {}
    for side in ("left", "right"):
        slack = max(0, avail_side - side_used[side])
        keys = [(side, tuple(g)) for g in groups]
        raw = {k: slack * sum(ZONE_WEIGHTS[z] for z in k[1]) / wsum for k in keys}
        add = {k: int(raw[k]) for k in keys}
        rest = slack - sum(add.values())
        for k in sorted(keys, key=lambda k: (-(raw[k] - int(raw[k])), str(k))):
            if rest <= 0:
                break
            add[k] += 1
            rest -= 1
        for k in keys:
            band_w[("g", k[0], k[1])] += add[k]
        band_slack[side] = slack

    # band x 边界：侧带上按「由中心向两侧」的顺序（P R A M | core | M A R P）
    core_w = band_w["core"]
    core_x0 = (cols - core_w) // 2
    core_x1 = core_x0 + core_w
    bands = [{"zone": "core", "zones": ["core"], "side": "center",
              "x0": core_x0, "x1": core_x1}]
    band_index = {("core",): bands[0]}
    side_band_keys = []
    seps = []
    for side in ("left", "right"):
        x = core_x0 if side == "left" else core_x1
        for i, g in enumerate(groups):
            gz = list(reversed(g)) if side == "right" else list(g)
            sw = sep_list[i]
            w = band_w[("g", side, tuple(g))]
            if side == "left":
                seps.append({"x0": x - sw, "x1": x, "side": side, "w": sw,
                             "kind": "road" if sw == ROAD_W else "alley"})
                x -= sw
                band_index[(side, i)] = {"zone": gz[0], "zones": gz, "side": side,
                                         "x0": x - w, "x1": x}
                x -= w
            else:
                seps.append({"x0": x, "x1": x + sw, "side": side, "w": sw,
                             "kind": "road" if sw == ROAD_W else "alley"})
                x += sw
                band_index[(side, i)] = {"zone": gz[0], "zones": gz, "side": side,
                                         "x0": x, "x1": x + w}
                x += w
            side_band_keys.append((side, i))
    bands += [band_index[k] for k in side_band_keys]

    # ── H y 分带（b 空间：0 = 主街北缘，向北递增） ──────────────────────
    plaza_h = 0
    if plaza_w:
        plaza_h = min(10, max(plaza_w, 6))

    def band_depth_of(row):
        ds = []
        for (z, s, r), us in row_units.items():
            if r == row:
                ds += [DEFS[u["def"]]["depth"] for u in us]
        return max(ds) if ds else 5

    row_off, row_depth, row_intrude = {}, {}, {}
    b = 0
    for r in range(lot_rows):
        row_off[r] = b
        # 广场贴主街向北铺：row0 带不因广场加深（广场只是把该列建筑挤到北边），
        # row≥1 被广场侵入的深度需补给该排（教堂/行会馆北退后仍要有自身进深）
        intr = max(0, plaza_h - b) if (plaza_w and r > 0) else 0
        row_depth[r] = band_depth_of(r) + intr
        row_intrude[r] = intr
        b += row_depth[r]
        if r < lot_rows - 1:
            b += LANE_W
    lot_max_b = b
    total_b = lot_max_b + margin
    rows = street_w + total_b + wall_th
    if depth_cells and depth_cells > rows:
        extra_d = depth_cells - rows
        lot_max_b += extra_d
        total_b += extra_d
        rows = street_w + total_b + wall_th
    depth_px = rows * CELL_W

    def cell_y(b_off: int) -> int:
        """b 空间 → 平面 y 格（y 向下变大 = 前方在下）。"""
        return (rows - street_w - 1) - b_off

    street_y0 = rows - street_w

    # ── I 广场（居中于核心带，紧贴主街北缘） ────────────────────────────
    plaza = None
    if plaza_w:
        pw = min(plaza_w, core_w)
        px0 = core_x0 + (core_w - pw) // 2
        plaza = {"x0": px0, "x1": px0 + pw, "b0": 0, "b1": plaza_h,
                 "w_cells": pw, "h_cells": plaza_h, "zone": "market"}

    # ── J 打包 lot ──────────────────────────────────────────────────────
    lots, yards = [], []
    lot_no = 0
    branches = []
    for side in ("left", "right"):
        for s in [q for q in seps if q["side"] == side and q["kind"] == "road"]:
            branches.append({"x0": s["x0"], "x1": s["x1"], "w": s["w"],
                             "side": side, "b0": 0, "b1": lot_max_b + margin})

    def plaza_cols(row):
        """被广场吃光的列：剩余进深不足最小建筑进深（4 格）才算堵死。"""
        if not plaza:
            return set()
        if row_off[row] >= plaza["b1"] or row_off[row] + row_depth[row] <= plaza["b0"]:
            return set()
        avail = row_off[row] + row_depth[row] - max(row_off[row], plaza["b1"])
        return set(range(plaza["x0"], plaza["x1"])) if avail < 4 else set()

    def runs_in(x0, x1, blocked):
        """把 [x0,x1) 切成不含 blocked 列的连续段，返回 [start, end) 半开区间。"""
        out, cur = [], None
        for c in range(x0, x1):
            if c in blocked:
                if cur is not None:
                    out.append(cur)
                    cur = None
            else:
                cur = (c, c + 1) if cur is None else (cur[0], c + 1)
        if cur is not None:
            out.append(cur)
        return out

    remaining = {}

    def plaza_overlaps(row):
        """该排 b 带与广场 b 带是否相交。"""
        if not plaza:
            return False
        return not (row_off[row] >= plaza["b1"]
                    or row_off[row] + row_depth[row] <= plaza["b0"])

    def run_fronts(row, bd):
        """把 band 拆成可落位段 (x0,x1)：只排除被广场整段吃光（剩余进深<4）的列。"""
        return [(a, bb) for (a, bb) in
                runs_in(bd["x0"], bd["x1"], plaza_cols(row))
                if bb - a >= 4]

    def front_b_for(row, u, x0):
        """该 lot 前进线 b 偏移：lot 中列落在广场 x 区间内 → 退到广场北缘。"""
        if plaza and plaza_overlaps(row) and \
                plaza["x0"] <= x0 + u["w_cells"] // 2 < plaza["x1"]:
            return plaza["b1"]
        return row_off[row]

    def pack(row, side_tag, bd, queue):
        """把 (zone,unit) 队列顺序落进 bd 的可用段：左对齐试排 → 余量并入巷口/端头。

        广场只把「压在其上的」lot 前进线北退（不切断带），进深不够者顺延到后排。
        """
        nonlocal lot_no
        if not queue:
            return
        for (a, bb) in run_fronts(row, bd):
            if not queue:
                break
            placed, x = [], a
            since, threshold = 0, rng.randint(*ALLEY_EVERY)
            prev_zone, deferred = None, []
            while queue:
                z, u = queue[0]
                gap = ALLEY_W if (placed and since >= threshold) else 0
                if prev_zone is not None and z != prev_zone:
                    gap = max(gap, ALLEY_W)          # 区界至少 1 格巷
                # §4.4 同 def 不相邻：本单元与刚落位单元同 def 且将**无缝**相邻
                # （放下去必判违规）时，从队列找第一个异 def 单元顶上（确定性，
                # 不消耗 rng）；整队同 def 才退而留 1 格巷。该分支仅在「不处理就
                # 违规」时触发——既有 4 档零违规 ⇒ 取样序/落位逐位不变（零漂移）。
                if gap == 0 and placed and u["def"] == placed[-1]["unit"]["def"]:
                    alt_i = next((i for i, (_zz, uu) in enumerate(queue)
                                  if uu["def"] != u["def"]), None)
                    if alt_i is not None:
                        queue.insert(0, queue.pop(alt_i))
                        z, u = queue[0]
                        if prev_zone is not None and z != prev_zone:
                            gap = max(gap, ALLEY_W)  # 换上的单元跨区界 → 补巷
                    else:
                        gap = ALLEY_W
                if x + gap + u["w_cells"] > bb:
                    break
                fb = front_b_for(row, u, x + gap)
                if fb + DEFS[u["def"]]["depth"] > row_off[row] + row_depth[row]:
                    queue.pop(0)                     # 进深不够 → 顺延到后排
                    deferred.append((z, u))
                    continue
                queue.pop(0)
                x += gap
                if gap:
                    since = 0
                    threshold = rng.randint(*ALLEY_EVERY)
                placed.append({"zone": z, "unit": u, "x0": x, "gap": gap, "front_b": fb})
                x += u["w_cells"]
                since += 1
                prev_zone = z
            queue.extend(deferred)
            if not placed:
                continue
            used = x - a
            leftover = (bb - a) - used
            gaps = [i for i, p in enumerate(placed) if p["gap"]]
            per_gap = min(MAX_GAP_EXTRA, leftover // max(1, len(gaps) + 1))
            lead = 0
            if per_gap:
                leftover -= per_gap * len(gaps)
                for i in gaps:
                    placed[i]["shift_extra"] = per_gap * sum(1 for j in gaps if j < i)
                lead = min(leftover // 2, 4)
            else:
                lead = min(leftover // 2, 6)
            for p in placed:
                z, u = p["zone"], p["unit"]
                d = DEFS[u["def"]]
                x0 = p["x0"] + p.get("shift_extra", 0) + lead
                fb = front_b_for(row, u, x0)
                lot_no += 1
                lots.append({
                    "index": lot_no, "def": u["def"], "def_cn": d["cn"],
                    "zone": z, "side": side_tag, "row": row,
                    "w_cells": u["w_cells"], "depth_cells": d["depth"],
                    "x_cells": [x0, x0 + u["w_cells"]],
                    "x_px": x0 * CELL_W, "w_px": u["w_cells"] * CELL_W,
                    "front_b": fb, "baseline_y": GROUND_Y - fb * CELL_W,
                    "facing": "S", "front_faces_plaza": bool(fb != row_off[row]),
                    "front_y_cell": cell_y(fb),
                    "back_y_cell": cell_y(fb) - d["depth"] + 1,
                    "top_h_px": def_top_h(u["def"]),
                    "wall_mat": d["wall_mat"], "roof_mat": d["roof_mat"],
                })
            if leftover >= 2:
                pass        # 余量统一由 J2 的 yard 补齐（避免与后处理重复）

    for r in range(lot_rows):
        # 核心带（独占中轴，不与侧带并区）
        bd_core = band_index[("core",)]
        q = [("core", u) for u in row_units.get(("core", "center", r), [])]
        q += [("core", u) for u in remaining.pop(("core", "center"), [])]
        if special_well and r == 0:
            # §4.1「教堂/水井为中心」：无广场档水井落核心带 row0 中轴（正对主街）
            wdef = DEFS["well"]
            ww = _pick_width("well")
            wx = core_x0 + (core_w - ww) // 2
            lot_no += 1
            lots.append({
                "index": lot_no, "def": "well", "def_cn": wdef["cn"],
                "zone": "market", "side": "center", "row": 0,
                "w_cells": ww, "depth_cells": wdef["depth"],
                "x_cells": [wx, wx + ww], "x_px": wx * CELL_W, "w_px": ww * CELL_W,
                "front_b": row_off[0], "baseline_y": GROUND_Y,
                "facing": "S", "front_faces_plaza": False,
                "front_y_cell": cell_y(row_off[0]),
                "back_y_cell": cell_y(row_off[0]) - wdef["depth"] + 1,
                "top_h_px": def_top_h("well"),
                "wall_mat": wdef["wall_mat"], "roof_mat": wdef["roof_mat"],
                "center_anchor": True})
        pack(r, "center", bd_core, q)
        if q:
            remaining[("core", "center")] = [u for (z, u) in q]
        for side in ("left", "right"):
            for gi, g in enumerate(groups):
                bd = band_index[(side, gi)]
                queue = []
                for z in bd["zones"]:
                    queue += [(z, u) for u in row_units.get((z, side, r), [])]
                    queue += [(z, u) for u in remaining.pop((z, side), [])]
                pack(r, side, bd, queue)
                for z in bd["zones"]:
                    rem = [u for (zz, u) in queue if zz == z]
                    if rem:
                        remaining[(z, side)] = rem

    leftover_units = [{"zone": k[0], "side": k[1], "missing": len(v)}
                      for k, v in sorted(remaining.items())]

    # ── J2 院坝/田地补齐：逐带逐排把未落建筑的空段记为 yard（生产区记 field）。
    # 平面图不留「说不清的空地」；渲染端可据此铺后院/菜地/田垄。
    yards = []
    for key, bd in band_index.items():
        side = "center" if len(key) == 1 else key[0]
        for r in range(lot_rows):
            blocked = set(plaza_cols(r)) if side == "core" else set()
            taken = sorted((l["x_cells"][0], l["x_cells"][1]) for l in lots
                           if l["row"] == r and l["side"] == side
                           and l["x_cells"][0] >= bd["x0"]
                           and l["x_cells"][1] <= bd["x1"])
            for (a, bb) in runs_in(bd["x0"], bd["x1"], blocked):
                cur = a
                for (s0, s1) in taken:
                    if s0 > cur:
                        _push_yard(yards, cur, s0, r, bd["zone"], side)
                    cur = max(cur, s1)
                if bb > cur:
                    _push_yard(yards, cur, bb, r, bd["zone"], side)

    # ── J3 特殊建筑投放（§4.2 区带权重 + 频率克制，见 SPECIAL_DEFS 表头） ──
    # 只在 J2 的院坝空段里落位：不碰既有 lots 的 x / 行 / 宽度，也不消耗任何
    # 既有 rng 取样 → 「同 seed 逐字节一致 + 既有 24 def 布局不漂移」两条硬约束
    # 同时成立。落位规则（全部确定性）：区带权重 → 锚点距离（中轴/城门）→ 排偏好
    # → 档宽 → x；宽度取段内可用的最大合规档；进深必须落进该排 b 带。
    special_lots = []

    def place_specials():
        nonlocal lot_no
        for dname in SPECIAL_ORDER:
            cfg = SPECIAL_DEFS[dname]
            for _ in range(int(cfg["freq"].get(tier, 0))):
                best = None
                for y in yards:
                    wz = cfg["zone_weight"].get(y["zone"], 0)
                    if wz <= 0:
                        continue
                    row = y["row"]
                    # §4.3 广场内不放建筑（well/摊除外）：与广场 b×x 区间相交即跳过
                    if plaza and not (row_off[row] >= plaza["b1"]
                                      or row_off[row] + row_depth[row]
                                      <= plaza["b0"]) \
                            and y["x0"] < plaza["x1"] and y["x1"] > plaza["x0"]:
                        continue
                    # ── §8.2 出檐留位（剪影口径，见文件头 EAVE_RATIO 段） ──
                    # 院坝空段的左右边缘各自扣掉「该侧邻居出檐 + EAVE_NET_MIN」的
                    # 缺口（缺多少扣多少；段外是巷道/端头则不用扣），剩余段必须容得下
                    # 本栋**剪影** sil_w_cells(w)。放不下就降档，仍放不下换下一个段。
                    row_lots = [l for l in lots if l["row"] == row
                                and l.get("side") == y["side"]]
                    lp = _eave_deficit(row_lots, y["x0"], True)
                    rp = _eave_deficit(row_lots, y["x1"], False)
                    span = (y["x1"] - y["x0"]) - lp - rp
                    ws = [w for w in DEFS[dname]["widths"]
                          if sil_w_cells(w) <= span and _aspect_ratio_ok(dname, w)
                          and DEPTH_BY_WIDTH.get(dname, {}).get(w, DEFS[dname]["depth"])
                          <= row_depth[row]]
                    if not ws:
                        continue
                    w = max(ws)
                    near_key = (-abs((y["x0"] + y["x1"]) / 2.0 - cols / 2.0)
                                if cfg["near"] == "center"
                                else -min(y["x0"], cols - y["x1"]))
                    # key 取最大：front = 排号小者优先（贴主街），deep = 排号大者优先
                    row_key = -y["row"] if cfg["row_pref"] == "front" else y["row"]
                    key = (wz, near_key, row_key, w, -y["x0"])
                    if best is None or key > best[0]:
                        best = (key, y, w, lp, rp)
                if best is None:
                    continue
                _key, y, w, lp, rp = best
                row = y["row"]
                # 剪影在剩余段内居中 → 占地框两侧各退一个出檐
                x0 = (y["x0"] + lp
                      + max(0, ((y["x1"] - y["x0"]) - lp - rp
                                - sil_w_cells(w)) // 2)
                      + eave_cells(w))
                d = DEFS[dname]
                depth = DEPTH_BY_WIDTH.get(dname, {}).get(w, d["depth"])
                fb = row_off[row]
                lot_no += 1
                lots.append({
                    "index": lot_no, "def": dname, "def_cn": d["cn"],
                    "zone": y["zone"], "side": y["side"], "row": row,
                    "w_cells": w, "depth_cells": depth,
                    "x_cells": [x0, x0 + w], "x_px": x0 * CELL_W,
                    "w_px": w * CELL_W,
                    "front_b": fb, "baseline_y": GROUND_Y - fb * CELL_W,
                    "facing": "S", "front_faces_plaza": False,
                    "front_y_cell": cell_y(fb),
                    "back_y_cell": cell_y(fb) - depth + 1,
                    "top_h_px": def_top_h(dname),
                    "wall_mat": d["wall_mat"], "roof_mat": d["roof_mat"],
                    "special": True,
                })
                special_lots.append({
                    "def": dname, "def_cn": d["cn"], "zone": y["zone"],
                    "side": y["side"], "row": row, "w_cells": w,
                    "depth_cells": depth, "x_cells": [x0, x0 + w],
                    "x_px": x0 * CELL_W, "baseline_y": GROUND_Y - fb * CELL_W,
                    "top_h_px": def_top_h(dname),
                    "band_weight": cfg["zone_weight"].get(y["zone"], 0),
                    "near": cfg["near"]})
                # 抠掉已用段（余下左右两段 ≥2 格才留）
                nl = []
                for yy in yards:
                    if yy is not y:
                        nl.append(yy)
                        continue
                    _push_yard(nl, y["x0"], x0, row, y["zone"], y["side"])
                    _push_yard(nl, x0 + w, y["x1"], row, y["zone"], y["side"])
                yards[:] = nl

    place_specials()

    # ── K 城墙 / 塔楼 / 城门 ────────────────────────────────────────────
    # 塔楼间距按档（任务书 §7.4 第 9 条）：既有 4 档不带 tower_gap 键 → 取全局
    # TOWER_GAP_PX，取样序逐位不变；capital/metropolis 城墙长 → 间距加密登记。
    gap_lo, gap_hi = spec.get("tower_gap", TOWER_GAP_PX)
    walls = {"tier": spec["wall_tier"], "height_px": wall_h,
             "seg_cells": WALL_SEG_CELLS, "runs": [], "towers": [], "gates": []}
    if wall:
        runs_def = [("left", 0, 1, 0, rows), ("right", cols - 1, cols, 0, rows),
                    ("back", 0, cols, 0, 1)]
        for side, x0, x1, y0, y1 in runs_def:
            axis = "x" if side == "back" else "y"
            length_cells = (x1 - x0) if axis == "x" else (y1 - y0)
            segs = []
            i = 0
            while i < length_cells:
                n = min(WALL_SEG_CELLS, length_cells - i)
                segs.append({"i0": i, "len_cells": n, "len_px": n * CELL_W,
                             "height_px": wall_h, "crest_px": wall_h + MERLON_PX})
                i += n
            walls["runs"].append({
                "side": side, "axis": axis,
                "x_cells": [x0, x1], "y_cells": [y0, y1],
                "length_px": length_cells * CELL_W, "height_px": wall_h,
                "segments": segs,
                "visible_in_elevation": side in ("left", "right", "back"),
                "elevation_role": {"left": "左收边", "right": "右收边",
                                   "back": "城市轮廓基线（天际线）",
                                   "front": "剖切面/前景"}[side]})
            tw = wall_th + margin
            tw_px = tw * CELL_W
            total_len = length_cells * CELL_W
            pos = 0.0                     # 上一座塔的**中心**位置（沿趟的 px）
            while True:
                spacing = (rng.uniform(gap_lo, gap_hi)
                           * (1 + rng.uniform(-TOWER_GAP_JITTER, TOWER_GAP_JITTER)))
                center = pos + spacing
                if center + tw_px / 2 > total_len:
                    break
                h = (wall_h + MERLON_PX
                     + wall_h * TOWER_EXTRA_RATIO
                     * (1 + rng.uniform(-TOWER_H_JITTER, TOWER_H_JITTER)))
                walls["towers"].append({
                    "side": side, "axis": axis,
                    "i_px": int(round(center)),            # 塔中心（间距校验用）
                    "i_cells": int(center // CELL_W),
                    "w_cells": tw, "w_px": tw_px, "height_px": int(round(h)),
                    "gap_from_prev_px": (int(round(spacing))
                                         if walls["towers"] and
                                         walls["towers"][-1]["side"] == side else None),
                    "height_jitter_pct": round(
                        (h - (wall_h + MERLON_PX + wall_h * TOWER_EXTRA_RATIO))
                        / max(1.0, wall_h * TOWER_EXTRA_RATIO) * 100, 1)})
                pos = center

        if has_gate:
            gd = wall_th + margin
            gw = street_w + 2
            for side, gx0 in (("left", 0), ("right", cols - gd)):
                walls["gates"].append({
                    "side": side, "def": "gatehouse", "def_cn": DEFS["gatehouse"]["cn"],
                    "x_cells": [gx0, gx0 + gd], "depth_cells": gd,
                    "x_px": gx0 * CELL_W, "w_px": gd * CELL_W,
                    "facade_w_cells": gw, "arch_cells": street_w,
                    "height_px": DEFS["gatehouse"]["wall_h"] + MERLON_PX,
                    "baseline_y": GROUND_Y, "passable": True})

    # 塔楼高度：夹到「唯一最高点（教堂钟楼）之下」，并把可用余量**分层**摊开。
    # 分层是必须的：村档可分配余量只有 ~116px，纯随机抽 3 座塔会挤成一簇（实测极差
    # 仅 2px），被 §4.4「高低错落、防等高发假」判定为全同高。这里用低差异序列
    # （黄金比轮转 + 每趟相位）保证同一趟内的塔天然拉开，抖动只作微调。
    core_lots = [l for l in lots if l["zone"] == "core"]
    cap = (max(l["top_h_px"] for l in core_lots) - 30) if core_lots else None
    base = wall_h + MERLON_PX
    room = max(0.0, (cap - base)) if cap else wall_h * TOWER_EXTRA_RATIO * 1.15
    gold = 0.6180339887498949
    phase = {"left": 0.0, "right": 0.37, "back": 0.71}
    for side in ("left", "right", "back"):
        for k, t in enumerate([q for q in walls["towers"] if q["side"] == side]):
            jit = rng.random()          # 每塔一次取样（与旧实现同序，下游 rng 流不变）
            frac = 0.35 + 0.65 * (((k + 1) * gold + phase[side]) % 1.0) \
                + (jit - 0.5) * 0.06
            h = int(round(base + room * frac))
            if cap:
                # round 可能顶到 cap 正上方；压 1px 保住"严格低于唯一最高点"
                h = min(h, int(cap) - 1)
            t["height_px"] = h
            t["height_frac"] = round(frac, 3)
            if cap:
                t["capped_below_core"] = True
            assert t["height_px"] < (cap if cap else 10 ** 9), t

    # ── L 前景 props（§4.5：桶/摊/树/车，必须落在街道内） ───────────────
    props = []
    prop_kinds = ["barrel", "crate", "hay", "cart", "tree", "stall"]
    # 街具数（任务书 §7.4 第 9 条）：既有 4 档 = 4 + TIER_ORDER×3（公式与取样序
    # 逐位不动）；新档用 TIER_SPECS 的显式 n_props（townlet 9 / burgh 12 /
    # capital 18 / metropolis 24，任务书 §一「街具密度」列）。
    n_props = spec["n_props"] if "n_props" in spec else 4 + TIER_ORDER[tier] * 3
    for i in range(n_props):
        c = int(cols * (i + 0.5) / n_props) + rng.randint(-2, 2)
        c = max(wall_th + margin, min(cols - wall_th - margin - 1, c))
        props.append({"kind": prop_kinds[i % len(prop_kinds)],
                      "x_cells": [c, c + 1],
                      "y_cells": [rng.randint(street_y0, street_y0 + street_w - 1),
                                  rng.randint(street_y0, street_y0 + street_w - 1)],
                      "in_street": True})
    if special_well:
        # 水井两侧的市集摊（§4.1 村中心：水井 + 摊群）
        wl = [l for l in lots if l.get("center_anchor")]
        if wl:
            wx = wl[0]["x_cells"][0]
            for dx in (-4, wl[0]["w_cells"]):
                props.append({"kind": "market_stall",
                              "x_cells": [wx + dx, wx + dx + 3],
                              "y_cells": [cell_y(1), cell_y(1)],
                              "in_core_forecourt": True, "zone": "market"})
    if plaza:
        pc = (plaza["x0"] + plaza["x1"]) // 2
        props.append({"kind": "well", "x_cells": [pc - 1, pc + 1],
                      "y_cells": [cell_y(plaza_h // 2), cell_y(plaza_h // 2) + 1],
                      "in_plaza": True, "zone": "market"})
        for i in range(4):
            c = plaza["x0"] if i % 2 == 0 else max(plaza["x0"], plaza["x1"] - 2)
            bb = 1 + i * max(1, (plaza_h - 2) // 4)
            bb = min(bb, max(1, plaza_h - 2))
            props.append({"kind": "market_stall", "x_cells": [c, c + 2],
                          "y_cells": [cell_y(bb), cell_y(bb) + 1],
                          "in_plaza": True, "zone": "market"})

    # ── M 天际线 ────────────────────────────────────────────────────────
    profile = [0] * cols
    owner = [None] * cols
    for l in lots:
        for c in range(l["x_cells"][0], min(l["x_cells"][1], cols)):
            if l["top_h_px"] > profile[c]:
                profile[c] = l["top_h_px"]
                owner[c] = l["def"]
    if wall:
        for t in walls["towers"]:
            if t["axis"] == "y":
                cc = 0 if t["side"] == "left" else cols - 1
                rng_cols = range(cc, min(cc + t["w_cells"], cols))
            else:
                rng_cols = range(t["i_cells"], min(t["i_cells"] + t["w_cells"], cols))
            for c in rng_cols:
                if t["height_px"] > profile[c]:
                    profile[c] = t["height_px"]
                    owner[c] = "tower"
        for c in (0, cols - 1):
            if wall_h + MERLON_PX > profile[c]:
                profile[c] = wall_h + MERLON_PX
                owner[c] = "wall_seg"

    sorted_lots = sorted(lots, key=lambda l: (-l["top_h_px"], l["x_px"]))
    tallest = sorted_lots[0] if sorted_lots else None
    second = sorted_lots[1] if len(sorted_lots) > 1 else None
    tallest_point = max(profile)
    # 核心 landmark 名单：教堂系 + 行会馆 + 行政阶梯（L4 起行政建筑夺最高点，
    # 任务书 §7.4 第 3 条）
    core_names = {"church", "chapel", "guildhall", "moot_hall", "town_hall",
                  "city_hall", "governor_palace", "imperial_palace"}
    core_tall = [l for l in lots if l["def"] in core_names]
    highest_is_core = bool(core_tall) and max(l["top_h_px"] for l in core_tall) \
        == tallest["top_h_px"] and tallest["def"] in core_names
    wall_above = sum(1 for l in lots if l["top_h_px"] <= wall_h + MERLON_PX)
    non_core = [l for l in lots if l["zone"] != "core"]
    wall_above_nc = sum(1 for l in non_core if l["top_h_px"] <= wall_h + MERLON_PX)

    margin_px = (tallest["top_h_px"] - second["top_h_px"]) if second else 9999
    skyline = {
        "profile_px": profile,
        "owner": owner,
        "tallest": ({"def": tallest["def"], "def_cn": tallest["def_cn"],
                     "zone": tallest["zone"], "x_px": tallest["x_px"],
                     "x_cells": tallest["x_cells"], "row": tallest["row"],
                     "top_h_px": tallest["top_h_px"]} if tallest else None),
        "second_highest": ({"def": second["def"], "top_h_px": second["top_h_px"],
                            "row": second["row"]} if second else None),
        "unique_highest": (second is None or margin_px > 0),
        "unique_margin_px": margin_px,
        "unique_margin_pct": (round(100.0 * margin_px / max(1, tallest["top_h_px"]), 1)
                              if second else 100.0),
        "tallest_is_core": highest_is_core,
        "tallest_x_offset_cells": (tallest["x_cells"][0] + tallest["w_cells"] // 2
                                   - cols // 2) if tallest else None,
        "tallest_row": tallest["row"] if tallest else None,
        "profile_max_px": tallest_point,
        "wall_crest_px": wall_h + MERLON_PX,
        "wall_above_ratio": round(wall_above / max(1, len(lots)), 4),
        "wall_above_ratio_non_core": round(wall_above_nc / max(1, len(non_core)), 4),
        "buildings": [{"def": l["def"], "zone": l["zone"], "row": l["row"],
                       "x_px": l["x_px"], "w_cells": l["w_cells"],
                       "top_h_px": l["top_h_px"]}
                      for l in sorted(lots, key=lambda l: l["x_px"])],
    }

    # ── 行政建筑槽位（任务书第 2 节）：新档实装 lot 打 role 标记，town/city 充当
    #    指认既有 guildhall，village 预留——零漂移硬约束见 ADMIN_LOT_DEFS 注释。
    admin_slots = build_admin_slots(tier, lots, cols)

    plan = {
        "tier": tier, "seed": int(seed), "cell_w": CELL_W, "ground_y": GROUND_Y,
        "width_px": width_px, "depth_px": depth_px, "cols": cols, "rows": rows,
        "wall_tier": spec["wall_tier"],
        "params": {"has_gate": bool(has_gate), "has_plaza": bool(plaza_w),
                   "street_w_cells": street_w, "lane_w_cells": LANE_W,
                   "lot_rows": lot_rows, "margin_cells": margin,
                   "n_buildings": n_total, "plaza_cells": plaza_w,
                   "wall_h_px": wall_h, "band_slack_cells": band_slack,
                   "avail_side_cells": avail_side},
        "counts": counts,
        "bands": [{"zone": b["zone"], "side": b["side"],
                   "x_cells": [b["x0"], b["x1"]],
                   "x_px": [b["x0"] * CELL_W, b["x1"] * CELL_W],
                   "w_cells": b["x1"] - b["x0"],
                   "w_px": (b["x1"] - b["x0"]) * CELL_W} for b in bands],
        "separators": [{"kind": s["kind"], "side": s["side"], "w_cells": s["w"],
                        "x_cells": [s["x0"], s["x1"]],
                        "x_px": [s["x0"] * CELL_W, s["x1"] * CELL_W]}
                       for s in seps],
        "rows_bands": [{"row": r, "b0": row_off[r], "b1": row_off[r] + row_depth[r],
                        "depth_cells": row_depth[r],
                        "plaza_intrude_cells": row_intrude[r],
                        "baseline_y": GROUND_Y - row_off[r] * CELL_W}
                       for r in range(lot_rows)],
        "walls": walls,
            "roads": {
            "main": {"axis": "x", "x_cells": [0, cols],
                     "y_cells": [street_y0, rows], "w_cells": street_w,
                     "w_px": street_w * CELL_W,
                     "kind": "dirt" if tier in ("hamlet", "village", "townlet")
                             else "stone",
                     "through": True, "baseline_y": GROUND_Y},
            "branches": branches,
            "lanes": [{"b0": row_off[r] + row_depth[r],
                       "b1": row_off[r] + row_depth[r] + LANE_W,
                       "y_cells": [cell_y(row_off[r] + row_depth[r] + LANE_W - 1),
                                   cell_y(row_off[r] + row_depth[r]) + 1],
                       "w_cells": LANE_W} for r in range(lot_rows - 1)],
            "plaza": ({"x_cells": [plaza["x0"], plaza["x1"]],
                       "y_cells": [cell_y(plaza["b1"] - 1), cell_y(plaza["b0"]) + 1],
                       "w_cells": plaza["w_cells"], "h_cells": plaza["h_cells"],
                       "zone": "market", "flush_north_of_main_street": True,
                       "center_x_px": ((plaza["x0"] + plaza["x1"]) // 2) * CELL_W,
                       "center_y_px": (rows - street_w - plaza_h // 2) * CELL_W}
                      if plaza else None),
        },
        "lots": lots,
        "admin_slots": admin_slots,
        "specials": special_lots,
        "yards": yards,
        "props": props,
        "anchors": {
            "gate": [{"x_px": g["x_px"], "side": g["side"],
                      "baseline_y": GROUND_Y} for g in walls["gates"]],
            "plaza_center": ({"x_px": ((plaza["x0"] + plaza["x1"]) // 2) * CELL_W,
                              "baseline_y": GROUND_Y - (plaza_h // 2) * CELL_W}
                             if plaza else None),
            "core": ({"def": tallest["def"], "x_px": tallest["x_px"],
                      "baseline_y": tallest["baseline_y"]} if tallest else None),
            "main_street": {"x_px": [0, width_px], "baseline_y": GROUND_Y},
        },
        "skyline": skyline,
        "leftover_units": leftover_units,
    }
    plan["checks"] = verify_plan(plan, strict=True)
    return plan


# ══════════════════════════════════════════════════════════════════════════
# 校验：五条规范 + 分区权重 + §3.2 长宽比
# ══════════════════════════════════════════════════════════════════════════
def verify_plan(plan: dict, strict: bool = True) -> dict:
    cols, rows = plan["cols"], plan["rows"]
    lots = plan["lots"]
    tier = plan["tier"]
    street_w = plan["params"]["street_w_cells"]
    issues, notes = [], []

    def is_road_cell(c, y):
        m = plan["roads"]["main"]
        if m["y_cells"][0] <= y < m["y_cells"][1]:
            return True
        for br in plan["roads"]["branches"]:
            y0 = (rows - street_w - 1) - br["b1"]
            y1 = (rows - street_w - 1) - br["b0"] + 1
            if br["x0"] <= c < br["x1"] and y0 <= y < y1:
                return True
        for ln in plan["roads"]["lanes"]:
            if ln["y_cells"][0] <= y < ln["y_cells"][1]:
                return True
        pl = plan["roads"]["plaza"]
        if pl and pl["y_cells"][0] <= y < pl["y_cells"][1] \
                and pl["x_cells"][0] <= c < pl["x_cells"][1]:
            return True
        return False

    road_cells = set()
    for c in range(cols):
        for y in range(rows):
            if is_road_cell(c, y):
                road_cells.add((c, y))

    # ① 街道宽度 §4.3（主街按档带：L1~L3 2~3 格 / L4=4 / L5=4~6 大道，任务书
    #    §7.4 第 5 条；支路/巷维持 2~3）。既有 4 档不带 street_band 键 → (2,3) 原样。
    spec_band = TIER_SPECS[tier].get("street_band", (2, 3))
    branch_ws = sorted({b["w"] for b in plan["roads"]["branches"]})
    lane_ws = sorted({l["w_cells"] for l in plan["roads"]["lanes"]})
    street_ok = (spec_band[0] <= street_w <= spec_band[1]) \
        and all(2 <= w <= 3 for w in branch_ws + lane_ws)
    if not street_ok:
        issues.append("街宽越界：主街 %d（档带 %s）/ 支路 %s / 巷 %s"
                      % (street_w, list(spec_band), branch_ws, lane_ws))

    # ② 建筑退线：不侵路；前进线须贴街
    overlap = 0
    no_frontage = []
    for l in lots:
        for c in range(l["x_cells"][0], l["x_cells"][1]):
            for y in range(l["back_y_cell"], l["front_y_cell"] + 1):
                if (c, y) in road_cells:
                    overlap += 1
        c = l["x_cells"][0] + l["w_cells"] // 2
        if (c, l["front_y_cell"] + 1) not in road_cells:
            no_frontage.append({"def": l["def"], "x_cells": l["x_cells"],
                                "row": l["row"], "front_y": l["front_y_cell"]})
    if overlap:
        issues.append("退线违规：%d 个建筑格压在路上" % overlap)
    if no_frontage:
        issues.append("退线违规：%d 栋前进线不贴街 %s"
                      % (len(no_frontage), no_frontage[:4]))

    # ③ 小巷 §4.3
    max_run, alley_count = 0, 0
    by_row = {}
    for l in lots:
        by_row.setdefault(l["row"], []).append(l)
    for r, ls in by_row.items():
        ls = sorted(ls, key=lambda l: l["x_cells"][0])
        run = 1
        for a, b2 in zip(ls, ls[1:]):
            if a["x_cells"][1] < b2["x_cells"][0]:
                alley_count += 1
                run = 1
            else:
                run += 1
            max_run = max(max_run, run)
    alley_ok = max_run <= ALLEY_EVERY[1]
    if not alley_ok:
        issues.append("小巷违规：同排最长连排 %d 栋（上限 %d）"
                      % (max_run, ALLEY_EVERY[1]))

    # ④ 广场 §4.3（[6,10]，首府/首都放宽到 16：任务书 §7.4 第 5 条）
    plaza_band = TIER_SPECS[tier].get("plaza_band", (6, 10))
    pl = plan["roads"]["plaza"]
    if pl is None:
        plaza_ok, plaza_info = True, {"none": True, "note": "§4.1 hamlet 无广场"}
    else:
        lots_inside = sum(1 for l in lots
                          if l["x_cells"][0] >= pl["x_cells"][0]
                          and l["x_cells"][1] <= pl["x_cells"][1]
                          and l["front_y_cell"] >= pl["y_cells"][0]
                          and l["back_y_cell"] <= pl["y_cells"][1])
        plaza_props = sum(1 for p in plan["props"] if p.get("in_plaza"))
        plaza_ok = bool(plaza_band[0] <= pl["w_cells"] <= plaza_band[1]
                        and plaza_band[0] <= pl["h_cells"] <= plaza_band[1]
                        and pl["zone"] == "market" and lots_inside == 0
                        and pl["flush_north_of_main_street"])
        plaza_info = {"w_cells": pl["w_cells"], "h_cells": pl["h_cells"],
                      "zone": pl["zone"], "lots_inside": lots_inside,
                      "plaza_props": plaza_props, "flushed": True}
        if not plaza_ok:
            issues.append("广场违规：%s" % plaza_info)

    # ⑤ 天际线 §4.4（塔间距带按档：既有 4 档 = 全局 TOWER_GAP_PX 原样）
    tg_lo, tg_hi = TIER_SPECS[tier].get("tower_gap", TOWER_GAP_PX)
    sky = plan["skyline"]
    tower_gaps = []
    for side in ("left", "right", "back"):
        ts = sorted([t for t in plan["walls"]["towers"] if t["side"] == side],
                    key=lambda t: t["i_px"])
        for a, b2 in zip(ts, ts[1:]):
            tower_gaps.append(b2["i_px"] - a["i_px"])
    gap_ok = all(tg_lo * 0.9 <= g <= tg_hi * 1.1 for g in tower_gaps) \
        if tower_gaps else True
    tower_hs = [t["height_px"] for t in plan["walls"]["towers"]]
    h_spread = (max(tower_hs) - min(tower_hs)) if tower_hs else 0
    fake_equidistant = bool(gap_ok and len(tower_gaps) >= 3
                            and len(set(tower_gaps)) <= 1)
    fake_same_height = bool(len(tower_hs) >= 3 and h_spread < 8)
    if not gap_ok and tower_gaps:
        issues.append("塔楼间距越界：min %d max %d px（档带 %d~%d）"
                      % (min(tower_gaps), max(tower_gaps), tg_lo, tg_hi))
    if fake_equidistant:
        issues.append("塔楼间距完全等距（%d 段同距）→ 观感发假" % len(tower_gaps))
    h_range_pct = (((max(tower_hs) - min(tower_hs)) / (sum(tower_hs) / len(tower_hs)))
                   * 100) if len(tower_hs) > 1 else 0.0
    if tower_hs and h_range_pct < 15.0:
        notes.append("§4.4「塔楼高低错落 ±15%%」未满：实测极差 %.1f%%（墙 %dpx 与教堂顶 %s "
                     "之间可分配高度有限，受「唯一最高点=教堂」挤压）"
                     % (h_range_pct, plan["walls"]["height_px"],
                        sky["tallest"]["top_h_px"] if sky.get("tallest") else "?"))
    if fake_same_height:
        issues.append("塔楼高度几乎全同（极差 %dpx / %d 座）→ §4.4 高低错落失效"
                      % (h_spread, len(tower_hs)))

    same_def_adj, equal_run, max_run_len = 0, 0, 0
    for r, ls in by_row.items():
        ls = sorted(ls, key=lambda l: l["x_cells"][0])
        chain = 0
        for a, b2 in zip(ls, ls[1:]):
            if a["x_cells"][1] == b2["x_cells"][0]:
                if a["def"] == b2["def"]:
                    same_def_adj += 1
                if not _compatible(a["def"], b2["def"]):
                    equal_run += 1
                    chain += 1
                    max_run_len = max(max_run_len, chain + 1)
                else:
                    chain = 0
            else:
                chain = 0
    if same_def_adj:
        issues.append("同 def 相邻 %d 处" % same_def_adj)
    if equal_run:
        issues.append("等高/同材连排 %d 处（最长 %d 栋，§4.4 禁止）"
                      % (equal_run, max_run_len))

    if not sky["unique_highest"]:
        issues.append("最高点不唯一（次高 %s 差 %d px）"
                      % (sky["second_highest"]["def"],
                         sky["tallest"]["top_h_px"] - sky["second_highest"]["top_h_px"]))
    elif sky["unique_margin_pct"] < 8.0:
        notes.append("§4.4「唯一最高点」在小档读不出焦点：最高 %s %dpx 仅高出次高 %s "
                     "%dpx（%.1f%%）——§3.3 的礼拜堂 390 与谷仓 370/风车 380 高度太近"
                     % (sky["tallest"]["def"], sky["tallest"]["top_h_px"],
                        sky["second_highest"]["def"], sky["second_highest"]["top_h_px"],
                        sky["unique_margin_pct"]))
    if not sky["tallest_is_core"]:
        issues.append("最高点非核心 landmark（实际 %s）" % sky["tallest"]["def"])
    if abs(sky["tallest_x_offset_cells"] or 0) > 3:
        issues.append("最高点偏离中轴 %d 格" % sky["tallest_x_offset_cells"])
    if (sky["tallest_row"] or 0) < 1:
        issues.append("最高点不在偏后排（row=%d）" % sky["tallest_row"])

    wall_ratio, wall_ratio_all = sky["wall_above_ratio_non_core"], sky["wall_above_ratio"]
    wall_ok = wall_ratio >= 0.80
    if not wall_ok:
        notes.append("§4.4「墙顶高于 80%% 建筑」未达：%s 档墙顶 %dpx，非核心建筑达标率 "
                     "%.0f%%（全体 %.0f%%）——§4.1 墙高档与 §3.3 建筑总高不自洽"
                     % (tier, sky["wall_crest_px"], wall_ratio * 100,
                        wall_ratio_all * 100))

    # 分区权重 §4.2（按建筑数量）
    # **特殊建筑（J3 投放的 landmark）不计入本项**：它们按 SPECIAL_DEFS 的区带权重
    # 稀疏落位（另一套设计律，如兵营必须靠城门/生产带），把 1~5 栋 landmark 摊进
    # §4.2 的比例会把小档城镇推过 ±8pp（实测 120 个 seed 中 town 17 例断言失败）；
    # §4.2 管的是城市**肌理**（民居/工匠/市场的配比），landmark 是叠加层。
    # 计入项 = 非 special 的 lot，数量记在 `specials_excluded` 以便复核。
    fabric = [l for l in lots if not l.get("special")]
    cnt = Counter(l["zone"] for l in fabric if l["zone"] in ZONE_WEIGHTS)
    total = sum(cnt.values())
    share = {z: cnt[z] / max(1, total) for z in ZONE_ORDER}
    frontage = {z: 0 for z in ZONE_ORDER}
    for l in fabric:
        if l["zone"] in frontage:
            frontage[l["zone"]] += l["w_cells"]
    tot_f = max(1, sum(frontage.values()))
    dev = {z: abs(share[z] - ZONE_WEIGHTS[z]) for z in ZONE_ORDER}
    weight_ok = max(dev.values()) <= 0.08
    if not weight_ok:
        issues.append("分区权重偏差 > 8pp：%s"
                      % {z: round(dev[z] * 100, 1) for z in ZONE_ORDER})

    # §3.2 长宽比
    asp_bad = [{"def": l["def"], "w_cells": l["w_cells"], "top_h_px": l["top_h_px"]}
               for l in lots if not _aspect_ratio_ok(l["def"], l["w_cells"])]
    no_compliant = sorted({l["def"] for l in lots
                           if not _has_compliant_width(l["def"])
                           and not DEFS[l["def"]].get("aspect_exempt")})

    # ⑦ 出檐留位（§8.2 剪影口径，见 EAVE_RATIO 段）：**诊断，不作断言**
    # 同排同侧相邻对要求净距 ≥ eave(a) + eave(b) + ALLEY_W。新增 def（J3 投放）
    # 已按此口径留位；既有肌理是满铺解（可用空隙实测 0.0 格），缺口如实报出。
    eave_pairs, eave_fabric, special_bad = 0, [], []
    eave_short_cells = 0
    for r, ls in by_row.items():
        for side in ("left", "right", "center"):
            seq = sorted([l for l in ls if l.get("side") == side],
                         key=lambda l: l["x_cells"][0])
            for a, b in zip(seq, seq[1:]):
                need = eave_cells(a["w_cells"]) + eave_cells(b["w_cells"]) + EAVE_NET_MIN
                gap = b["x_cells"][0] - a["x_cells"][1]
                eave_pairs += 1
                if gap >= need:
                    continue
                rec = {"row": r, "a": a["def"], "b": b["def"], "gap": gap,
                       "need": need, "a_special": bool(a.get("special")),
                       "b_special": bool(b.get("special"))}
                eave_short_cells += need - gap
                if a.get("special") or b.get("special"):
                    special_bad.append(rec)
                else:
                    eave_fabric.append(rec)
    if eave_fabric:
        notes.append("§8.2 出檐留位：肌理同排相邻对 %d/%d 对仍剪影互压（缺 %d 格）——"
                     "既有 24 def 是满铺解（可用空隙 0 格），按剪影推进需砍 §4.1 建筑数"
                     "或加宽档位总宽，属设计口径变更，见文件头 EAVE_RATIO 段"
                     % (len(eave_fabric), eave_pairs, eave_short_cells))
    if special_bad:
        issues.append("§8.2 出檐留位失效（J3 投放的新 def 与邻居剪影互压 %d 对）：%s"
                      % (len(special_bad), special_bad[:3]))

    # §4.4 次高点应为城墙塔楼（塔并入高度排序校验；报告里 second_highest 仍只列建筑）
    tower_top = max(tower_hs) if tower_hs else 0
    towers_below_core = bool(not tower_hs or tower_top < sky["tallest"]["top_h_px"])
    second_lot_top = (sky["second_highest"]["top_h_px"]
                      if sky.get("second_highest") else 0)
    tower_is_second = bool(tower_hs and tower_top >= second_lot_top)
    if tower_hs and not tower_is_second and tower_top < second_lot_top:
        notes.append("§4.4「次高点 = 城墙塔楼」未成立：最高塔 %dpx < 次高建筑 %s %dpx（塔高被"
                     "「唯一最高点 %s %dpx」压住，塔可分配高度仅 %dpx）"
                     % (tower_top, sky["second_highest"]["def"], second_lot_top,
                        sky["tallest"]["def"], sky["tallest"]["top_h_px"],
                        max(0, sky["tallest"]["top_h_px"] - 30
                            - plan["walls"]["height_px"])))
    if tower_hs and not towers_below_core:
        issues.append("城墙塔楼高 %dpx ≥ 唯一最高点 %s %dpx → §4.4 视觉重心被夺"
                      % (tower_top, sky["tallest"]["def"],
                         sky["tallest"]["top_h_px"]))

    checks = {
        "street_width": {"main_cells": street_w, "branch_cells": branch_ws,
                         "lane_cells": lane_ws, "spec_cells": list(spec_band),
                         "ok": bool(street_ok)},
        "setback": {"lot_road_overlap_cells": overlap,
                    "lots_without_frontage": len(no_frontage),
                    "frontage_bad": no_frontage[:6],
                    "ok": bool(overlap == 0 and not no_frontage)},
        "alley": {"max_block_run": max_run, "spec": list(ALLEY_EVERY),
                  "alley_count": alley_count, "ok": bool(alley_ok)},
        "plaza": dict(plaza_info, ok=bool(plaza_ok)),
        "skyline": {"tallest": sky["tallest"], "second_highest": sky["second_highest"],
                    "unique_highest": sky["unique_highest"],
                    "tallest_is_core": sky["tallest_is_core"],
                    "tallest_x_offset_cells": sky["tallest_x_offset_cells"],
                    "tallest_row": sky["tallest_row"],
                    "wall_crest_px": sky["wall_crest_px"],
                    "wall_above_ratio": wall_ratio_all,
                    "wall_above_ratio_non_core": wall_ratio,
                    "wall_above_80pct_non_core": bool(wall_ok),
                    "tower_count": len(tower_hs),
                    "tower_gap_px": tower_gaps,
                    "tower_gap_distinct": len(set(tower_gaps)),
                    "tower_gap_ok": bool(gap_ok and not fake_equidistant),
                    "tower_height_spread_px": h_spread,
                    "tower_height_range_pct": round(h_range_pct, 1),
                    "tower_top_px": tower_top,
                    "towers_below_core": towers_below_core,
                    "tower_is_second_highest": tower_is_second,
                    "tower_height_frac": [t.get("height_frac")
                                          for t in plan["walls"]["towers"]],
                    "tower_height_ok": bool(not fake_same_height),
                    "same_def_adjacent": same_def_adj,
                    "equal_or_same_mat_runs": equal_run,
                    "max_equal_run_len": max_run_len,
                    "ok": bool(sky["unique_highest"] and sky["tallest_is_core"]
                               and gap_ok and not fake_equidistant
                               and same_def_adj == 0 and equal_run == 0
                               and abs(sky["tallest_x_offset_cells"] or 0) <= 3
                               and (sky["tallest_row"] or 0) >= 1)},
        "zone_weight": {"target": ZONE_WEIGHTS, "count": dict(cnt),
                        "count_share": {z: round(share[z], 4) for z in ZONE_ORDER},
                        "max_dev_pp": round(max(dev.values()) * 100, 2),
                        "frontage_share": {z: round(frontage[z] / tot_f, 4)
                                           for z in ZONE_ORDER},
                        "specials_excluded": len(lots) - len(fabric),
                        "ok": bool(weight_ok)},
        "aspect": {"checked": len(lots), "violations": asp_bad,
                   "defs_without_compliant_width": no_compliant,
                   "band": list(ASPECT_BAND), "tolerance": ASPECT_TOL,
                   "note": "§3.2 表头比 1:0.75~1.15 与逐档例值换算带宽 [0.86,1.33] "
                           "不自洽；本校验取逐档例值带 +5% 容差",
                   "ok": not asp_bad},
        "eave": {"pairs": eave_pairs, "fabric_bad": len(eave_fabric),
                 "specials_bad": len(special_bad),
                 "shortfall_cells": eave_short_cells,
                 "shortfall_pairs": eave_fabric + special_bad,
                 "caliber": {"eave_per_side": "建筑宽 × 20.5%",
                             "sil_w": "占地宽 × ≈1.4",
                             "net_min_cells": EAVE_NET_MIN,
                             "scope": "新增 def（J3）已留位；肌理为满铺解，缺口如实报出"},
                 "ok": not (eave_fabric or special_bad)},
        "leftover_units": plan.get("leftover_units", []),
        "issues": issues,
        "notes": notes,
    }
    checks["ok"] = bool(not issues)

    if strict:
        assert checks["setback"]["ok"], checks["setback"]
        assert checks["street_width"]["ok"], checks["street_width"]
        assert checks["alley"]["ok"], checks["alley"]
        assert checks["plaza"]["ok"], checks["plaza"]
        assert checks["zone_weight"]["ok"], checks["zone_weight"]
        assert checks["skyline"]["unique_highest"], checks["skyline"]["tallest"]
        assert checks["skyline"]["tallest_is_core"], checks["skyline"]["tallest"]
        assert checks["skyline"]["tower_gap_ok"], checks["skyline"]["tower_gap_px"]
        assert checks["skyline"]["tower_height_ok"], checks["skyline"]["tower_height_spread_px"]
        assert checks["skyline"]["towers_below_core"], checks["skyline"]["tower_top_px"]
        assert checks["skyline"]["same_def_adjacent"] == 0, "同 def 相邻"
        assert checks["skyline"]["equal_or_same_mat_runs"] == 0, "等高/同材连排"
        assert not checks["leftover_units"], checks["leftover_units"]
        for l in lots:
            assert 0 <= l["x_cells"][0] and l["x_cells"][1] <= cols, l
            assert 0 <= l["back_y_cell"] <= l["front_y_cell"] < rows, l
    return checks


# ══════════════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════════════
def summary(plan: dict) -> str:
    c = plan["checks"]
    sk, pl = c["skyline"], c["plaza"]
    return "\n".join([
        "【%s】cols=%d rows=%d  width=%dpx depth=%dpx  buildings=%d  zones=%s"
        % (plan["tier"], plan["cols"], plan["rows"], plan["width_px"],
           plan["depth_px"], len(plan["lots"]), plan["counts"]),
        "  ① 街宽：主街 %d 格 / 支路 %s / 巷 %s → %s"
        % (c["street_width"]["main_cells"], c["street_width"]["branch_cells"],
           c["street_width"]["lane_cells"], "OK" if c["street_width"]["ok"] else "FAIL"),
        "  ② 退线：压路 %d 格 / 不贴街 %d 栋 → %s"
        % (c["setback"]["lot_road_overlap_cells"],
           c["setback"]["lots_without_frontage"],
           "OK" if c["setback"]["ok"] else "FAIL"),
        "  ③ 小巷：最长连排 %d 栋（上限 6）/ 缝 %d 处 → %s"
        % (c["alley"]["max_block_run"], c["alley"]["alley_count"],
           "OK" if c["alley"]["ok"] else "FAIL"),
        "  ④ 广场：%s → %s"
        % (("无（§4.1 hamlet）" if pl.get("none") else
            "%d×%d 格 zone=%s 内无建筑=%s 摊/井 %d 个"
            % (pl.get("w_cells"), pl.get("h_cells"), pl.get("zone"),
               pl.get("lots_inside") == 0, pl.get("plaza_props"))),
           "OK" if pl["ok"] else "FAIL"),
        "  ⑤ 天际线：最高 %s %dpx（偏移 %s 格 / 第 %d 排）| 次高建筑 %s(%dpx) / 最高塔 %dpx | 唯一=%s"
        % (sk["tallest"]["def"], sk["tallest"]["top_h_px"],
           sk["tallest_x_offset_cells"], sk["tallest_row"],
           sk["second_highest"]["def"], sk["second_highest"]["top_h_px"],
           sk["tower_top_px"], sk["unique_highest"]),
        "     墙顶 %dpx：高于非核心 %.0f%% / 全体 %.0f%%（§4.4 目标 80%%）| 塔 %d 座 间距 %s"
        % (sk["wall_crest_px"], sk["wall_above_ratio_non_core"] * 100,
           sk["wall_above_ratio"] * 100, sk["tower_count"], sk["tower_gap_px"]),
        "     同 def 相邻 %d / 等高同材连排 %d / 塔高极差 %dpx"
        % (sk["same_def_adjacent"], sk["equal_or_same_mat_runs"],
           sk["tower_height_spread_px"]),
        "  权重：%s（目标 %s，最大偏差 %.1fpp）"
        % (c["zone_weight"]["count_share"], ZONE_WEIGHTS,
           c["zone_weight"]["max_dev_pp"]),
        "  长宽比：%d 栋中违规 %d，无合规档位 def=%s"
        % (c["aspect"]["checked"], len(c["aspect"]["violations"]),
           c["aspect"]["defs_without_compliant_width"]),
        "  出檐：同排相邻 %d 对，剪影互压 %d 对（肌理 %d / 新 def %d，共缺 %d 格）"
        % (c["eave"]["pairs"], len(c["eave"]["shortfall_pairs"]),
           c["eave"]["fabric_bad"], c["eave"]["specials_bad"],
           c["eave"]["shortfall_cells"]),
        "  特殊建筑（区带权重/频率克制）：%s"
        % (", ".join("%s[%s/%s带 r%d x%d %d格]"
                     % (s["def"], s["def_cn"], s["zone"], s["row"],
                        s["x_cells"][0], s["w_cells"])
                     for s in plan.get("specials", [])) or "无（该档不投）"),
    ] + (["  ISSUES: " + " | ".join(c["issues"])] if c["issues"] else [])
      + (["  NOTES: " + " | ".join(c["notes"])] if c["notes"] else []))


def _dump(o):
    return json.dumps(o, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def main():
    ap = argparse.ArgumentParser(description="城镇平面布局求解器（§4 城市设计规范）")
    ap.add_argument("--tier", default="city",
                    choices=["hamlet", "village", "townlet", "town", "burgh",
                             "city", "capital", "metropolis", "all"])
    ap.add_argument("--seed", type=int, default=611036)
    ap.add_argument("--out", default=None, help="布局 JSON 输出路径（--tier all 时为目录）")
    ap.add_argument("--selftest", action="store_true", help="确定性自检")
    args = ap.parse_args()

    tiers = (["hamlet", "village", "townlet", "town", "burgh", "city",
              "capital", "metropolis"] if args.tier == "all" else [args.tier])
    plans = {}
    for t in tiers:
        p = plan_city(t, seed=args.seed)
        plans[t] = p
        print(summary(p))
        if args.selftest:
            q = plan_city(t, seed=args.seed)
            assert _dump(p) == _dump(q), "确定性失败：%s" % t
            r = plan_city(t, seed=args.seed + 1)
            assert _dump(p) != _dump(r), "异 seed 无差异：%s" % t
            print("  确定性自检：同 seed 逐字节一致 / 异 seed 有差异 → OK")
        print()
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(plans, f, ensure_ascii=False, indent=1)
        print("→", args.out)


if __name__ == "__main__":
    main()
