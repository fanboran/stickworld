# 动画产线（Spine 3.8 → Godot）操作手册

> 真相源数据：`spine_import.gd` 的 `SPINE_FILE` 常量（解包 Spine 3.8 JSON，100 动画）。
> 产线只翻译 `spine_import.ANIM_MAP` 清单内的动画（清单即当前入库全集）。
>
> **忠实口径（2026-10-09 创始人裁决）：SWL 轨迹数据直接用**——洗稿层（wash_anims）与
> 手 K 关键帧修正（KEYFRAME_FIXES）都已退役删除，**转换器输出即发布数据**。
> 旧"双轨制（忠实版/洗稿版）"与"先 L1 再生产"的表述随之作废：现在 `_faithful/`
> （gitignored）只是**入库前的验证暂存区**，用途与发布目录同一份数据。
>
> **铁律（不变）：改转换器/骨架/动画后必须过 L1 全绿再入库**——无验收基准 = 回到
> 盲修时代，历史翻车两次。

## 工具一览

| 工具 | 语言 | 作用 |
|---|---|---|
| `spine_import.tscn` | GDScript | Spine JSON → Godot Animation .tres。**rotate → BEZIER 轨**（段曲线精确直译 + 全骨补垫）+ **translate → position 轨**（逐骨位移，见下） |
| `dump_rig_pose.tscn` | GDScript | Godot 骨架 + 指定目录动画 → 姿态 JSON（headless；每骨输出世界 x/y/angle 与局部 lx/ly） |
| `../../tools/dump_spine_pose.py` | Python | Spine JSON → 姿态基准 JSON（与产线同款 unwrap + 曲线感知求值 + 逐骨 translate） |
| `../../tools/compare_pose.py` | Python | **L1 验收**：角度增量 + 逐骨局部位移增量 + 骨架跨度守卫（diff/discover 模式，退出码 0=全绿） |
| `dump_bezier_samples.gd` + `verify_bezier_import.py` | GDScript + Python | rotate 单轨的独立复核（采样 .tres BEZIER 轨 vs 源数据；**未覆盖 translate**） |
| `../../tools/check_anim_semantics.py` | Python | **L2 验收**：方向相关性/摆幅界/事件时刻 |
| `../../tools/render_swl_ref.py` | Python | PIL 渲染原版任意姿势参考帧（`--anim/--time/--focus`） |
| `extract_weapons.tscn` | GDScript | 从 universal.png 图集裁武器贴图（region 名以附件 name 字段为准） |

命令里 `GODOT` = `F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe`。

## 两条通道各自译什么（动数据前必读）

- **rotate → rotation 轨（BEZIER）**：`θ_my = 直立参考角 − Spine 角`（方向取反 + 直立补偿，
  见 `spine_import.gd` 头注释）；`>360°` 螺旋值先按最短角差 unwrap；段曲线
  （linear/stepped/bezier）精确映射到 Godot 键柄。
- **translate → position 轨**：Spine 的 translate 是**相对 setup 的局部偏移增量**（实证：
  按增量解释时头/髋/脚维持直立合理位置，按绝对局部位置解释时整具骨架塌到原点）。
  **写入时换算成绝对局部位置 = 骨架 rest 偏移 + 增量**——Godot position 轨是绝对值，
  只写增量会把有位移的骨拉到父骨原点（人物塌成团块；门禁的增量判据看不出这种整体
  塌陷，故有"骨架跨度守卫"兜底）。增量映射 = x 原样、y 取负（y 镜像，与 rotate 同款）、
  乘骨架尺度 `_scale`；`_scale` = rig 骨架高 / Spine 骨架高（由 `SKELETON_DATA` 与源
  setup 现算，非硬编码常数，与 L1 门禁同一算法）。曲线段按 30Hz 密集采样降级为线性键。
- **不译**：全部 scale / ik / slots 通道（产线口径，两侧一致）。

## 标准流程（改转换器/加骨/加动画后）

```bash
# 1. 重导到验证暂存区（gitignored；产物与发布目录同一份数据）
$GODOT --headless --path stick-world res://tools/baking/spine_import.tscn -- --out-dir=res://tools/baking/_faithful

# 2. Godot 侧姿态 dump（--anims 用 compare_pose.ANIM_MAP 里的 godot 名全集）
$GODOT --headless --path stick-world res://tools/baking/dump_rig_pose.tscn -- \
  --anims=idle,idle_v2,idle_spear,idle_bow,idle_pickaxe,idle_staff,walk,run,attack,block,attack_spear,attack_pickaxe,attack_staff,attack_bow,dead,dead_headshot,hit_front,hit_back,walk_carry,arrive \
  --fps=15 --dir=res://tools/baking/_faithful --out=res://tools/baking/_faithful/rig_pose.json

# 3. Spine 基准 dump（转换器没动可跳过，产物已在）
python tools/dump_spine_pose.py --anims "Swordwrath-Stand1,...(ANIM_MAP 的 spine 名)" \
  --fps 15 --out stick-world/tools/baking/_faithful/spine_pose.json \
  --skeleton "F:/VSCode/game-2/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt"

# 4. L1 验收 —— 必须全部 PASS：角度增量残差 ≤1°、逐骨局部位移增量残差 ≤1px、无跨度异常帧
python tools/compare_pose.py --spine stick-world/tools/baking/_faithful/spine_pose.json \
  --godot stick-world/tools/baking/_faithful/rig_pose.json --mode diff

# 5. 入库（_faithful/*.tres → 发布目录；只覆盖同名文件，别删旧文件——heal_meric_*、 walk_bow_hold 等不在 ANIM_MAP 里，重新导入产不出来）
cp stick-world/tools/baking/_faithful/*.tres stick-world/modules/stick_rig/animations/

# 6. 回归
bash stick-world/tools/dev/gate.sh          # 四段门禁（import 自检 / 改动面编译 / 变更测试 / 报错扫描）
bash stick-world/tools/check_godot_errors.sh
```

## 验收判据怎么读（compare_pose diff）

- **角度增量残差**：两侧骨架零位不同，世界角绝对值差一个每骨常数（结构性差异），
  故判据取增量。两侧互为负号（rig 是 Spine 的 y 镜像）。
- **逐骨局部位移增量残差**：取**局部偏移**（骨相对父骨的 position）而不是世界位置——
  两具骨架骨长不同（Spine 大腿 82.7 vs rig 66），世界位置增量天然不可比。
- **骨架跨度守卫**：每帧全骨世界 y 极差之比须与尺度一致（容差 25%）——专抓"每骨同向
  偏移、增量对比看不出"的整具塌陷。

## 已知豁免与勘误（动数据前必读）

- **指纹/映射同步**：`SPINE_TO_MY`（spine_import）与 `BONE_MAP`（compare_pose）必须
  同步改；骨架改动在 `stickman_skeleton.gd` 的 `SKELETON_DATA`（单一真相源，tscn 已不预置骨）。
- **武器持握**：`weapon_*` 场景参数推导链 = 附件数据直译 + C=0（角度镜像模型
  `Sprite.rotation = C − 挂载骨Spine世界角 − 附件rot − 挂载骨Godot世界角`），
  详见各 tscn 头注释；验收图 `weapon_check_*.png`。参考帧用
  `python tools/render_swl_ref.py --anim Swordwrath-Stand1 --focus sword`
  （该渲染器 2026-08-30 修正过世界角/y 翻转 bug，旧帧不可信）。
- **覆盖不到的地方（改动位移链路时须自查）**：① 2D 人群路径 `crowd_renderer_bake.gd`
  只预烘 rotation 表；② `verify_bezier_import.py` 只核 rotate 轨；③ `bake_walk_bow_hold.gd`
  另有一条持弓行走烘焙链。三者都还没接逐骨位移。
