# 建筑生成管线 v3（写实 PBR / Blender）——进度与交接

> **方向变更**：v2（Godot 2D 手绘笔触，`stick-world/tools/building_pipeline/`）**废弃**——创始人判定 2D 程序化绘制模拟材质有天花板，"材质水平太烂"。v3 改用 **Blender 3D + PBR 材质 + 真实光照**（与项目 `tools/icon_pipeline` 同构的生产纪律）。
> 设计文档：`docs/技术/架构/建筑生成管线v3-写实PBR.md`（§8 规范修订决议、§9 首次品控结论与改造清单 —— **这两节是本任务当前最重要的输入**）
> 参考图：`stick-world/assets/_raw/建筑/smithy.png`（铁匠铺 Lv1~4）
> 分支 `agent/building-pipeline-v2`，worktree `.temp/building-pipeline-v2`。

---

## 一、当前状态（第一批基础设施 + 首次品控）

### 已建成

| 模块 | 文件 | 状态 |
|---|---|---|
| 规范文档 | `docs/技术/架构/建筑生成管线v3-写实PBR.md` | 九章：方向定位/技术管线/规格/城市设计/美术规范/品控/批次 + §8 修订决议 + §9 品控结论 |
| 材质库 | `tools/blender_buildings/materials.py`（12 种 PBR 材质 + UV 工具） | 已跑通，6 轮自迭代；**品控判定"游戏尺寸下塌成 4 组"** |
| 建筑几何库 | `tools/blender_buildings/buildings.py`（模块 + 6 def × 宽度档装配） | 已跑通，4 轮迭代；门高 150 / 出檐 20.5% / 长宽比全档 PASS；**品控判定"立面是纸板"** |
| 城市布局器 | `tools/blender_buildings/city_layout.py`（确定性求解 + 断言 + CLI） | 4 档布局 + 平面图 + 天际线剖面；**品控判定"作为美术方案不能看，作为布局数据可用"** |
| 渲染探针 | `probe_materials.py` / `probe_buildings.py` / `probe_city_plan.py` | 均可复跑 |

### 关键产物（在 `stick-world/temp/`）
- `pbr_materials.png` + `pbr_materials_25pct.png`（材质样片 / 25% 游戏尺寸自检）
- `pbr_buildings_v2.png`（回炉后建筑总图 7294×1546，含 130px 火柴人剪影）；`pbr_buildings_v1.png`（留档）
- `city_plan_{hamlet,village,town,city}.png|.json`（城市平面 + 布局数据）
- `pbr_yaw_compare.png`（正视 vs 12° 偏航对照 —— 证明"必须偏航"）

### 已拍板的关键规范（详见文档 §8）
- **视角：3/4 偏航 12° + 俯角 10°**（纯正视做不出参考图的大面积屋面）
- **带门建筑最小宽度 8 格**（6 格是长宽比天花板；加宽正是"别太窄"的正解）
- 长宽比：网格宽 : 剪影总高 = 1 : 0.85~1.5；双层单列（层高 175~195）
- 出檐 = 建筑宽 × 18~23%
- 门净高 150（≈1.15 火柴人身高）；复合门洞（谷仓大门/马厩开口）豁免
- 光照：太阳仰角 40° / 方位 -38° / 强度 3.0~3.5；**环境光 0.60**（0.8~1.0 会把暖色洗成橄榄绿）
- 抹灰禁锈褐斑；材料缩到 25% 必须仍可辨（出厂门禁）

---

## 二、下一轮工作（按品控优先级，见文档 §9.2）

1. **立面修正**：屋面厚度（檐口板/压条/脊瓦/山墙封檐）、檐下 AO、窗型表化（窗台≥0.9m、窗:门高≤0.75、同立面同窗型≤2、上下层差异化）、烟囱落地带泛水、二层几何差异化。
2. **材质标准重建**：定 texel density；重铺 12 种使"游戏内 1:1 可辨"；重做 iron/thatch；污渍改 decal；补 wattle-and-daub/木瓦/原木/玻璃/自发光。
3. **消灭程序生成感**：路网层级化（禁等距平行）、连续街墙 + 退线随机、L 形院落、后巷、广场实体化、院坝填附属物；出图分"真实材质版/调试版"。
4. **道具层与灯光层**：20~30 件道具库（桶/柴垛/招牌/灯笼/推车/篱笆/货箱…）；炉火/灯火自发光 + 暖色点光；正午/黄昏两套环境光。
5. **校验工具**：真火柴人剪影（现在 `pbr_silhouette.png` 是空图）+ 人高刻度；道路格占用校验；纹素密度差 ≤2 倍校验；材质 25% 可辨校验。

---

## 三、跑法

```bash
BLENDER="/f/SteamLibrary/steamapps/common/Blender/blender.exe"
cd "F:/VSCode/game-2/.temp/building-pipeline-v2/tools/blender_buildings"
"$BLENDER" -b --factory-startup -P probe_materials.py     # 材质样片
"$BLENDER" -b --factory-startup -P probe_buildings.py     # 建筑单体总图
python probe_city_plan.py                                  # 城市平面图（纯 Python + PIL）
```

## 四、新会话恢复指引

1. 读本文档 + 设计文档（重点 §8/§9）。
2. `git worktree list` 确认 `.temp/building-pipeline-v2`；缺则 `git worktree add .temp/building-pipeline-v2 agent/building-pipeline-v2`。
3. 跑一遍三个 probe 确认环境；按 §9.2 优先级逐项改造，**每项产出必须派品控审查（美术总监视角 + 玩家视角）后才进下一项**。
4. v2 的 2D 管线（`stick-world/tools/building_pipeline/`）保留作历史对照，不再演进。
