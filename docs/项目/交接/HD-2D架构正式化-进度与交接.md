# HD-2D 架构正式化 — 进度与交接

> **状态**：迁址批次已验证完成，合回 main 待并行会话窗口；职责拆分缓期（成果已归档）。
> **worktree**：`.temp/hd2d-promotion`（分支 `agent/hd2d-promotion`）。

## 一、任务与裁决

正式化 HD-2D 渲染栈：`tests/dev/proto_hd2d/` 原型 → 正式模块。创始人裁决（2026-09-15）：
**worktree 任务分支执行**；因当天 main 上 HD-2D 代码被并行会话大幅演进（+~1000 行/20 新函数），
改走 **方案 A「迁址先行、拆分缓期」**（试合并实证：带拆分合 main 冲突面巨大；纯迁址近乎干净）。

## 二、已完成

1. **批次①迁址**（5d484c91 + 合并提交 061a9092，分支上）：
   - 3D 世界脚本/场景/char_sprite_3d/5 shader/63MB 随包 tex 镜像 → `modules/hd2d/`
     （scenes/scripts/shaders/assets），场景更名 `hd2d_world.tscn`（root=Hd2dWorld）
   - `api.gd` 公共接口契约（模式注入属性 + 宿主 duck API 面）
   - 贴图解析优先级不变：烘卡机 temp/ 优先 → 随包镜像兜底
   - 宿主 preload 换新路径；验证：双探针全绿 + 自检干净（worktree 无 temp/ 纯镜像跑通）
2. **main 合入分支**：今天全部演进（投影收线/城镇生成器摆法/背景两排化/城门弹窗/内景五套）
   经 rename 检测自动映射进新路径，代码零冲突；419 个资产文件冲突全取 main 版。

## 三、待办（按序）

1. **合回 main**（等隔壁在途批提交后）：main 工作区现余 game_root.gd / hd2d_gate_prompt.gd
   （M）+ hd2d_sky_region_map.gd（新）——均不在合并触碰面内，可安全合并。
   合并后须**随迁**隔壁的未跟踪文件：`tests/dev/proto_hd2d/tex/proto_hd2d/hd2d_layouts/hd2d_street.json`
   → `stick-world/modules/hd2d/assets/tex/proto_hd2d/hd2d_layouts/`（旧 tex 目录已随迁址删除）。
   合并在 main 工作区做：`git merge agent/hd2d-promotion` → 重跑双探针 + 自检 → 提交。
2. **职责拆分 v2**（缓期，待城镇生成器/投影收线批次收口、函数面稳定后启动）：
   - 成果存档：分支 `agent/hd2d-split-wip`（②a 组件拆分 ab94689d + ②b Hd2dMapBase 基类 d9a311eb，
     基于旧 proto 版本，仅作结构与脚本参考，不可直接合）
   - **组件映射表 v2**（新函数 → 目的地）：

| 现在的位置（proto_hd2d.gd/hd2d_world.gd） | 拆分去向 |
|---|---|
| 常量/锚点落位/卡材质/接地影/画面宽 | `hd2d_cards.gd` |
| 前排意图表+摆位求解器 `_resolve_front_row`/背景排 `_pick_bg_card`/`spawn_bg_for_front`/`get_layout_props` | `hd2d_street_placer.gd` |
| `_place_clouds`/`_bake_cloud_texture`/`_apply_cloud_light`/`_drift_clouds`（逐帧漂移） | 新组件 `hd2d_clouds.gd`（Node，自带 _process） |
| `get_ground_lift_world/px`、台面/镶边/底衬/天空背板 | `hd2d_ground.gd` |
| `get_solid_rects`/`get_building_rects`/`_building_solid_rect`/`_apply_hide_groups`/`get_fg_bg_boundary_y`/`_wall_x`/相机/光照档/`_apply_stage` | `hd2d_world.gd`（根门面保留） |
| `_card_bottom_pad`/`_card_base_cut`/`_card_image`/`_card_visual_height` | `hd2d_cards.gd` |
| 宿主公共代码（3D 挂载/碰撞映射/传送带/出口/资源算法/角色同步/相机镜像/昼夜） | `modules/world/scripts/map/hd2d_map_base.gd`（②b 已验证的实现可参考） |

   - 拆分方法论：脚本化块抽取（按函数名分派+标识符加前缀+裸引用检查器），
     见 `agent/hd2d-split-wip` 的提交方式；行为与公共 API 不变、测试零改动为验收线。

## 四、新会话恢复指引

1. `git worktree list` 找 `.temp/hd2d-promotion`；读本文档 + `git log agent/hd2d-promotion -5`。
2. 查隔壁在途批是否已提交（`git -C F:/VSCode/game-2 status --short`）→ 执行三、1。
3. 拆分启动时：从当时的 main 新开分支，按映射表 v2 重新脚本化抽取（不要直接复用 wip 分支内容）。
