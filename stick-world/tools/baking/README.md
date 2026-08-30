# 动画产线（Spine 3.8 → Godot）双轨操作手册

> 真相源数据：`F:/VSCode/game-2-aux/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt`
> （100 动画）。产线只翻译 `spine_import.ANIM_MAP` 清单内的 17 个动画。
>
> **双轨制**（防指认抄袭与翻译保真兼得）：
> - **忠实版**（未洗稿）= 翻译正确性的载体，L1 逐帧验收的对象，**不进版本库**
> - **发布版**（洗稿后）= 游戏实际使用的数据，L2 语义验收的对象，在 `modules/units/animations/`
>
> **铁律：任何转换器/骨架改动后，必须先 L1 全绿、再洗稿入库。禁止跳过 L1 直接洗稿
> （无验收基准 = 回到盲修时代，历史翻车两次）。**

## 工具一览

| 工具 | 语言 | 作用 |
|---|---|---|
| `spine_import.tscn` | GDScript | Spine JSON → Godot Animation .tres（转换核心：unwrap + θ=ref−raw + KEYFRAME_FIXES） |
| `wash_anims.tscn` | GDScript | 洗稿（确定性扰动，种子 20260817），保留并缩放事件元数据 |
| `extract_weapons.tscn` | GDScript | 从 universal.png 图集裁武器贴图（region 名以附件 name 字段为准） |
| `dump_rig_pose.tscn` | GDScript | Godot 骨架 + 指定目录动画 → 姿态 JSON（headless） |
| `verify_anims/verify_overlay/render_shot` | GDScript | 辅助验证（曲线采样/叠加层/SubViewport 截图） |
| `../../tools/dump_spine_pose.py` | Python | Spine JSON → 姿态基准 JSON（unwrap 与产线同算法） |
| `../../tools/compare_pose.py` | Python | **L1 验收**：增量制对比（diff/discover 模式，退出码 0=全绿） |
| `../../tools/check_anim_semantics.py` | Python | **L2 验收**：方向相关性/摆幅界/事件时刻 |
| `../../tools/render_swl_ref.py` | Python | PIL 渲染原版任意姿势参考帧（`--anim/--time/--focus`） |

命令里 `GODOT` = `F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe`，
均在仓库根 `F:/VSCode/game-2-aux/` 下执行。

## 标准流程（改转换器/加骨/加动画后）

```bash
# 1. 忠实版重导（17 个动画到 _faithful/，gitignored）
$GODOT --headless --path stick-world res://tools/baking/spine_import.tscn -- --out-dir=res://tools/baking/_faithful

# 2. Godot 侧忠实版姿态 dump（--anims 用 ANIM_MAP 全部 17 个）
$GODOT --headless --path stick-world res://tools/baking/dump_rig_pose.tscn -- \
  --anims=idle,idle_v2,walk,run,attack,block,attack_spear,attack_pickaxe,attack_staff,attack_bow,dead,dead_headshot,hit_front,hit_back,walk_carry,arrive \
  --fps=15 --dir=res://tools/baking/_faithful --out=res://tools/baking/_faithful/rig_pose.json

# 3. Spine 基准 dump（转换器没动可跳过，产物已在）
python tools/dump_spine_pose.py --anims "Swordwrath-Stand1,...(ANIM_MAP 的 spine 名)" \
  --fps 15 --out stick-world/tools/baking/_faithful/spine_pose.json

# 4. L1 验收 —— 必须 16/16 PASS、未豁免骨残差 ≤0.03°
python tools/compare_pose.py --spine stick-world/tools/baking/_faithful/spine_pose.json \
  --godot stick-world/tools/baking/_faithful/rig_pose.json --mode diff

# 5. 发布版重导 + 洗稿
$GODOT --headless --path stick-world res://tools/baking/spine_import.tscn
$GODOT --headless --path stick-world res://tools/baking/wash_anims.tscn

# 6. L2 验收（发布版 dump + 语义断言）
$GODOT --headless --path stick-world res://tools/baking/dump_rig_pose.tscn -- \
  --anims=...(同上) --fps=15 --dir=res://modules/units/animations \
  --out=res://tools/baking/_faithful/rig_pose_pub.json
python tools/check_anim_semantics.py --faithful stick-world/tools/baking/_faithful/rig_pose.json \
  --pub stick-world/tools/baking/_faithful/rig_pose_pub.json

# 7. 回归
bash stick-world/tests/run_all.sh（预期 27/28，test_menu_navigation 既有无关失败）
bash stick-world/tools/check_godot_errors.sh
```

## 已知豁免与勘误（动数据前必读）

- **KEYFRAME_FIXES**（spine_import 内）：walk/run 的手臂轨道为手工重写值
  （修 idle→walk 切换"伸手卡顿"，因这两动画手臂键少实为整条轨道替换）。
  L1 以 compare_pose 的 `KNOWN_FIXES` 豁免；**改这里必须过画面验收**。
- **武器持握**：`weapon_*` 场景参数推导链 = 附件数据直译 + C=0（角度镜像模型
  `Sprite.rotation = C − 挂载骨Spine世界角 − 附件rot − 挂载骨Godot世界角`），
  详见各 tscn 头注释；验收图 `weapon_check_*.png`。参考帧用
  `python tools/render_swl_ref.py --anim Swordwrath-Stand1 --focus sword`
  （该渲染器 2026-08-30 修正过世界角/y 翻转 bug，旧帧不可信）。
- **骨骼映射**：SPINE_TO_MY（spine_import）与 BONE_MAP（compare_pose）必须同步改；
  骨架改动在 `stickman_skeleton.gd` 的 SKELETON_DATA（单一真相源，tscn 已不预置骨）。
