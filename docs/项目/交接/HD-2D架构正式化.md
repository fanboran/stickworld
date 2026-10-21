# HD-2D 架构正式化

> **状态**：迁址批次已合入 main；职责拆分 v2 已执行（2026-10-21），分支 `agent/hd2d-split-v2` 待创始人验收后合 main。
> **worktree**：`.temp/wf-hd2d`（分支 `agent/hd2d-split-v2`）。

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
2. **职责拆分 v2**（2026-10-21 解缓执行完毕，分支 `agent/hd2d-split-v2` 待验收合 main）：
   - 旧成果存档分支 `agent/hd2d-split-wip`（基于旧 proto 版本）已无参考价值，随本批执行作废
   - **落地结构**：门面 `hd2d_world.gd`（世界编排 `_build_world`/solids/相机/光照/小地图烘焙/出图）
     + `scripts/` 职责子目录六组件（`cards/`卡呈现、`placer/`摆街、`ground/`地面、
     `walls/`城墙、`char_stage/`角色舞台、`clouds/`云牌），组件经门面回引 `w` 互访，
     对外 duck API（api.gd）与探针可见内部成员原样留门面
   - **与映射表 v2 的出入**（现状为准）：
     · 卡库字典 `_cards/_props/_nature` 与贴图解析（`_tex_abs` 系）留门面（多组件共享词汇），卡呈现逻辑进 cards
     · 共享常量（SKYLINE_Z/BG_*/WALL_*/S/TILT_DEG 等）全部留门面，组件经 `w.` 只读——避免双份漂移
     · `_spawn_bg_card`/`_place_props`/`_place_nature`/`spawn_nature_card_at` 归 placer（映射表未指派，按"摆街"域归并）
     · `_spawn_building_shadow`（接地影）归 cards（映射表"接地影→cards"指此处，原表写的是常量行）
     · 死代码随域迁移不删：`_pick_card`/`_add_ground_plane`/`_add_decal`/`_add_sidewalk`/`_prop_slots`（写只读无）等保持原样
     · 云组件节点即 `Clouds` 容器（CLOUD_ROOT_NAME），门面 `_place_clouds` 只做组件创建委托
     · 宿主公共代码（3D 挂载/碰撞映射/传送带/出口/资源算法/角色同步/相机镜像/昼夜）
       在 `modules/world/scripts/map/hd2d_map_base.gd`——基类已在役，本批不动

## 四、新会话恢复指引

1. `git worktree list` 找 `.temp/wf-hd2d`（拆分分支）或 `.temp/hd2d-promotion`（迁址分支，已合 main）。
2. 拆分批验收：读本文档 + [`../待办/HD2D代码拆分v2.md`](../待办/HD2D代码拆分v2.md) +
   `git log agent/hd2d-split-v2`；验收过则合 main（合并后同步归档待办条目）。
