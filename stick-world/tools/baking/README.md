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
| `spine_import.tscn` | GDScript | Spine JSON → Godot Animation .tres。**rotate → BEZIER 轨**（段曲线精确直译 + 全骨补垫）+ **root translate → hip position 轨**（身体起伏） |
| `dump_rig_pose.tscn` | GDScript | Godot 骨架 + 指定目录动画 → 姿态 JSON（headless；每骨输出世界 x/y/angle） |
| `../../tools/dump_spine_pose.py` | Python | Spine JSON → 姿态基准 JSON（与产线同款 unwrap + 曲线感知求值 + root translate） |
| `../../tools/compare_pose.py` | Python | **L1 验收**：角度增量残差（diff/discover 模式，退出码 0=全绿） |
| `dump_bezier_samples.gd` + `verify_bezier_import.py` | GDScript + Python | rotate 单轨的独立复核（采样 .tres BEZIER 轨 vs 源数据） |
| `../../tools/check_anim_semantics.py` | Python | **L2 验收**：方向相关性/摆幅界/事件时刻 |
| `../../tools/render_swl_ref.py` | Python | PIL 渲染原版任意姿势参考帧（`--anim/--time/--focus`） |
| `extract_weapons.tscn` | GDScript | 从 universal.png 图集裁武器贴图（region 名以附件 name 字段为准） |

命令里 `GODOT` = `F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe`。

## 两条通道各自译什么（动数据前必读）

- **rotate → rotation 轨（BEZIER）**：`θ_my = 直立参考角 − Spine 角`（方向取反 + 直立补偿，
  见 `spine_import.gd` 头注释）；`>360°` 螺旋值先按最短角差 unwrap；段曲线
  （linear/stepped/bezier）精确映射到 Godot 键柄。
- **root translate → hip position 轨（VALUE）**：只取 `root` 骨的 y 上下起伏（x 行走位移
  不做，避免角色漂移），y 取负（Spine y-up → Godot y-down）。当前源数据里该通道全零占位。
- **不译**：全部 scale / ik / slots 通道（产线口径，两侧一致）。
- **⚠ 逐骨 translate 不得导入**（血泪条款，2026-10-11 实拍实证后整体回退）：本项目 rig
  是**重新手写**的骨架——`SKELETON_DATA` 的 rest 偏移自成一套参数化（与 Spine setup
  不同源、不同量纲：Spine `bone3` 偏移 (19.56, 0.16) vs rig `upper_torso` (2.85, −15.25)；
  Spine `bone`(spine_root) 在根上方 −109.76 vs rig 为 (0, 0)），站立姿态是烘进 rest 偏移
  与容器旋转的；且**肢体是建骨时一次成型的静态胶囊**（`stickman_skeleton.build_limbs`），
  胶囊挂在父骨、端点钉在子骨 rest 偏移上，**运行时不重建**。因此运行时改子骨 `position`
  只会让胶囊与关节脱开、相邻肢体叠压、剪影融成一团（实测躯干相对髋下坠 6~22px、整具
  压缩 2~4%，观感即"姜饼人/穿裙"）。rotate 之所以能译，是因为它走"相对直立参考姿态的
  差值"（θ = ref − spine角），天生不依赖两具骨架的参数化一致；position 是绝对值，做不到。
  要真吃下 SWL 的位移通道需每帧重建肢体几何（2D 矢量 rig 做不到；HD-2D 图集路径有可能），
  属架构级改造，不在当前范围。

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

# 4. L1 验收 —— 必须全部 PASS：角度增量残差 ≤1°（逐骨全帧）
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
- 曲线必须两侧同款求值（stepped/bezier），否则基准侧的线性近似会凭空造出残差
  （attack 族 39° 假残差即此，2026-10-11 修）。

## 已知豁免与勘误（动数据前必读）

- **指纹/映射同步**：`SPINE_TO_MY`（spine_import）与 `BONE_MAP`（compare_pose）必须
  同步改；骨架改动在 `stickman_skeleton.gd` 的 `SKELETON_DATA`（单一真相源，tscn 已不预置骨）。
- **武器持握**：`weapon_*` 场景参数推导链 = 附件数据直译 + C=0（角度镜像模型
  `Sprite.rotation = C − 挂载骨Spine世界角 − 附件rot − 挂载骨Godot世界角`），
  详见各 tscn 头注释；验收图 `weapon_check_*.png`。参考帧用
  `python tools/render_swl_ref.py --anim Swordwrath-Stand1 --focus sword`
  （该渲染器 2026-08-30 修正过世界角/y 翻转 bug，旧帧不可信）。
- **姿态保真的已知边界**：逐骨位移通道整体不导入（见上"血泪条款"），故 SWL 里靠 translate
  表达的内容（跑步起伏、刺击前冲、拉弓手位移、倒地平移）在本项目 rig 上**丢失**，姿势偏
  "发僵"。这是 rig 架构（静态胶囊 + 自成一套 rest 参数化）的固有边界，不是漏译。三者另
  有独立烘焙链，同样只吃 rotate：① 2D 人群路径 `crowd_renderer_bake.gd` 只预烘 rotation 表；
  ② `verify_bezier_import.py` 只核 rotate 轨；③ `bake_walk_bow_hold.gd` 的持弓行走链。
