# HD-2D 坐标投影协议收编-进度与交接

> 任务：HD-2D 投影数学一劳永逸收编——画布域↔视觉域坐标变换唯一出口协议，
> 修复悬浮方框悬空（创始人 2026-09-15 报告）并统一全部消费点判定域。
> **状态：已合并收线（2026-09-16）**——`45df93e3` 合并入 main（冲突解：静态核
> +保留台面 lift）+ `081fe908` 蓝框贴脚下线 revert-fix；worktree 与分支已删；
> 三轮创始人裁决迭代（悬空修复→视觉身高 156→选中框全身包裹）；待创始人
> main 实机复验。实测对比图 `F:\VSCode\game-2\temp\bracket_probe\`（main
> 修复前/修复后/放大）。

## 一、问题与根因

创始人报告：鼠标悬浮方框出现在角色实际位置上方很远处，鼠标也须悬到角色上方
很远处才触发。根因 = `hover_indicator.gd` 完全工作在 2D 画布域：绘制锚
`Range.global_position`（2D 行走带原点）与命中判定（手搓相机逆变换 + 原始
Range 矩形）都不做 HD-2D 投影压缩，而角色 billboard 视觉位置在压缩域——画与
判定同错一个方向。此前 fx_library / debug_drawers / selection_system（选中框，
`4cf59697`）各按需修过，悬浮框是漏网的一个；同日排查还发现框选/点选判定域
混用（视觉域鼠标 vs 画布域 origin）与城门提示/调试 FX 放置同类错位。

## 二、方案（已实现）

**数学核**：`modules/world/scripts/map/hd2d_projection.gd`（Hd2dProjection 静态类）
——正交投影 k=sinθ 下闭式即精确解：`ground_to_visual_y` / `visual_to_ground_y`
（互为精确逆）/ `squash_k` / `billboard_hover_rect`（悬浮框 billboard 几何）。

**运行时出口**（MapBase 默认恒等=2D 图，Hd2dStreetMap 覆写，战场/资源图继承）：
- `remap_fx_pos` —— 画布→视觉（已有，改为委托静态核）；
- `unmap_fx_pos` —— 视觉→画布（新增逆）；
- `entity_hover_rect` —— Range 框→视觉域矩形（新增；HD-2D = 底边贴视觉脚线
  + 宽高随 `depth_scale_at` 深度缩放；2D = Range 原框恒等，行为不变）。

**协议铁律**（写在 MapBase 协议段 + HD-2D街景系统.md §4.2.1）：
1. 一切画/判定走地图协议，禁止手搓相机公式（相机半程交给 viewport
   canvas_transform）；
2. 只有地面锚点参与压缩，身体纵向尺寸/偏移不压缩；
3. HD-2D origin=视觉脚线（2D origin=髋部的局部语义不跨图使用）；
4. 上游传视觉域坐标给内部已有 remap 的出口（FxPool.spawn_burst）前先 unmap，
   防二次压缩。

**消费点收编**：
- `hover_indicator.gd`（本次 bug 主修）：画与判定共用 `_hovered_visual_rect()`
  （=entity_hover_rect 输出），鼠标经 canvas 逆变换进视觉域；setup 签名去掉
  不再使用的 camera_rig（system_setup 装配点同步）；
- `selection_system.gd`：框选/点选锚点统一 `_unit_anchor()` = 悬浮框矩形中心
  （与悬浮判定同一几何；点胸口不脱靶），Range 缺失回退 origin 经 remap；
  **选中框锚半身高**（第二轮创始人裁决"别当成脚下的线框"——白选中框锚悬浮框
  矩形中心=脚线上方约 78px，非脚下）；
- `hd2d_gate_prompt.gd`：选项框锚经 remap（fx_pos_remapper 组查找），−130px
  上提为身体纵向不压缩；
- `debug_tools_panel.gd`：FX 放置 canvas 逆变换后先 unmap 防二次压缩；
- `hd2d_street_map.gd`：三处内联深度缩放 lerp 收编 `depth_scale_at()`（billboard
  渲染 / 2D rig 镜像 / 悬浮框几何同源）。

**第三轮修正（创始人实机验收裁决，2026-09-16）**：白色选中框=**全身包裹**——
与悬浮框/点选/框选判定共用同一 `entity_hover_rect` 矩形，角臂画四角（此前
半身高/脚下两版均废弃）。实测工具：`tests/dev/probe_brackets.tscn`（窗口模式
起真实 GameRoot→选中玩家+悬停→截屏 `temp/probe_brackets.png`，渲染最终验证）。
对比截图归档 `F:\VSCode\game-2\temp\bracket_probe\`（main 构建 vs 修复分支）。

**合并前置（已解除）**：建筑管线v3 会话已于 2026-09-16 00:42 将在途批次全部
落库（`969052eb` 台面 lift remap/行走带/`1e7ec7be` 街景契约等），merge 遂可执行。
其中 debug_drawers 蓝框"物理碰撞位"画法与创始人 09-16 裁决冲突，已按计划
补 revert-fix `081fe908`（蓝框贴脚下线）。

**第四轮修正（创始人实机复验反馈，2026-09-16）**：合并后蓝框贴脚线但
"显示偏上、实际逻辑位置也偏很多，合并前蓝紫相撞真的会停"——病根=HD-2D
（origin 空间）实体 Collider 仍挂 2D 髋部语义的 origin+foot_offset（≈130），
物理脚印悬在视觉脚线"前方" ~130·k·ez，停位与视觉脱节。修复=origin 空间图
**Collider 居 origin**（物理脚印=视觉脚线；`set_ground_constraints` 旗帜门控
+口径翻转重摆 `_apply_scale`，2D 图不变）；F3 蓝框回**物理碰撞位**渲染——
修复后物理位=脚下线框位，"碰撞真相"与"贴脚下线框"两裁决合一。同轮缩放
收编：F3 `world_to_screen` 走 viewport canvas_transform（ctx 注入 control）；
选中框矩形整体过变换+角臂自缩放（此前画布像素直当屏幕像素，框大 1.33×）。
单测新增实体碰撞箱门控用例（unit 63/63 全绿）。

**分类核验为无需改动**：fx_library、resource_node（已走 remap 协议）；
debug_drawers F3 口径（创始人已裁决的数据口径，坐标换算已走 remap）；
pond/tree_yarn_ball/rock_painting（2D 图专属装饰，恒等域）；siege_gate_prompt
（2D 攻城图）；ambient_motes/fireflies/weather/unit_lod_director/crowd_renderer/
stickman_rig（屏幕中心/缩放标量用途，非投影）；2D 侧血条悬浮判定为画布域内
自洽（HD-2D 血条走 3D billboard 侧）。

## 三、验证状态

- 单元测试 `tests/unit/test_hd2d_projection.gd`（已登记 batch_runner）：k 锚点值/
  round-trip 恒等/MapBase 恒等（2D 行为不变线）/街图 mock k 互逆/悬浮框几何/
  未就绪回退——**unit 批量 63/63 全绿**。
- 报错自检 `check_godot_errors.sh` 干净；`tools/audit_deps.py` 通过（4 处既有
  豁免项，无本次引入）。
- 全量 `run_all.sh`：41 通过 / 8 失败——**8 失败经 stash 对照实验证实为 HEAD
  既有、与本次改动无关**（失败签名与基线逐字节一致）：7 个悬置套件空跑
  （`.tscn` 已在 `9641bb87` 旧世界清退中改名 `.suspended` 存根，run_all.sh
  INTEGRATION_SUITES 未同步剔除——即 代码审计_2026-09-14 记载的「悬置套件
  空跑」）+ cross_map_travel（同审计记载的「稳定失败」）。⇒ 待办：run_all.sh
  清单剔除悬置套件（归旧代码清理任务，本分支不动）。
- **待创始人实机验收**：HD-2D 街景悬浮方框贴角色、鼠标悬角色即触发；框选/点选
  深处单位正常；城门提示贴玩家头顶；F 工具 FX 放置落点=点击点。

## 四、关键决策

1. **只提交 selection_system 修复进 main 作为前置**（`4cf59697`，已获创始人
   批准）——主工作区建筑管线v3 会话的在途未提交改动（台面 lift remap/行走带/
   origin 空间约束等）**未裹入**，本分支与该批次解耦：合并后 lift 自动流经
   `remap_fx_pos`，协议无需改动（billboard_hover_rect 的脚线锚调用链天然受益）。
2. **点选锚用悬浮框中心而非脚线**：HD-2D origin=脚，若锚脚线则点胸口
   （脚上 ~70px）会脱出 45px 容差；与悬浮判定统一为"所见即所判"。2D 图
   Range 框中心≈髋部（origin+9.5），与旧 origin 口径差 ≤9.5px，接受。
3. **协议方法挂 MapBase 而非独立工具类**：沿用 duck-call 模式不破坏 L1/L2→L3
   分层（ui_global/combat 不 preload world，经 game_root 注入的 map 引用调用）。
4. **逆变换为路面口径**：台面 lift 区逆解未含（与 screen_y_to_ground_y 同口径，
   文档 §4.2 已声明）；主工作区在途 lift 批次如需精确逆可在
   Hd2dProjection.visual_to_ground_y 上扩展分段解。

## 五、给 hd2d-promotion 会话的交叠提示

`agent/hd2d-promotion`（Hd2dMapBase 宿主基类提炼）与本分支在
`hd2d_street_map.gd` / `map_base.gd` 交叠：协议三方法 + `depth_scale_at` 归属
新基类时直接搬移即可（Hd2dProjection 静态核不依赖地图类型）；合并冲突预期
集中在 remap_fx_pos/unmap_fx_pos/entity_hover_rect 函数体附近。

## 六、恢复指引

新会话恢复：`git worktree list` 确认 worktree →读本档 §二/§四 →`git log` 看批次
→ 跑 `bash stick-world/tests/run_unit.sh` 确认 63/63 基线。
