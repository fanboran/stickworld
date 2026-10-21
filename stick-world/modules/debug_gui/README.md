# debug_gui：运行时调试可视化（F3 覆盖层 / F4 工具面板 / F9 热重载）

> F3 切换绘制覆盖层，把运行时不可见的标记画出来（网格/障碍/碰撞箱/地面线/资源点/
> 实体状态/世界标尺等，各绘制器独立开关）；F4 是交互式工具面板（特效试放/市场/
> 环境/建筑四页签）；F9 热重载 BalanceConfig。api.gd 经 project.godot 注册为
> autoload 单例 `DebugApi`。

---

## 目录结构

```
modules/debug_gui/
├── api.gd                          # DebugApi（autoload）：绘制器注册表/独立开关/可见性/ctx 附加数据/状态持久化
├── scenes/
│   └── debug_overlay.tscn          # 覆盖层场景（根节点挂 scripts/debug_overlay.gd）
└── scripts/
    ├── debug_overlay.gd            # DebugOverlay（CanvasLayer）：F3/F9 快捷键，管理 4 个子控件
    ├── debug_draw_control.gd       # 每帧构造 ctx（camera/map/map_paths…）调用全部启用的绘制器
    ├── debug_drawers.gd            # DebugDrawers：13 个静态绘制函数（签名 func(control, ctx)）
    ├── debug_panel.gd              # 可拖动开关面板（绘制器中文复选框 + 工具面板开关）
    ├── debug_info_panel.gd         # FPS/实体数/鼠标悬停单位文本框（随 F3 + entity_info 开关）
    ├── debug_tools_panel.gd        # F4 四页签：特效试放 / 资源×区域市场表 / 时间轴环境 / 建筑升级修理
    ├── ai_viz_window.gd            # AI 决策观察窗（StickWindow FLOATING）：单位列表→选中详情（行为注册表/目标理由/阈值余量）+ 切换日志
    ├── ai_viz_snapshot.gd          # 观测快照层（纯只读静态查询库：实体枚举/行摘要/详情快照/切换原因推断）
    └── dev_scene_escape.gd         # 开发场景 ESC 统一弹窗拦截
```

---

## AI 决策观察窗（ai_viz_*）

信息密度对标 LimboAI 调试器：单位列表 → 选中看详情（当前行为/目标及选择理由/
关键阈值余量/决策时钟）+ 状态切换日志。**纯观测零行为改动**——唯一 AI 侧改动是
`BehaviorStateMachine.travel` 末尾发射 `EventBus.ai_behavior_switched`（唯一入口埋点，
无订户零成本），切换原因由观测侧在信号时点推断（瞬时态事后不可考）。窗口由调试
场景自行挂开关（默认关）：观察场 V 键；观测数据面详见
[UI.md §10.5.9](../../docs/技术/架构/场景与战斗/UI.md)。

---

## 对外契约

- `DebugApi.register_drawer(name, callable)` / `unregister_drawer`：各模块注册自己的
  绘制器，签名 `func(control: Control, ctx: Dictionary)`；ctx 含 camera/effective_zoom/
  map/map_paths 等（map_paths 由 world 装配层经 `set_ctx_extra` 注入）
- 信号：`visibility_changed` / `legend_visibility_changed` / `drawer_enabled_changed` /
  `tools_visibility_changed`（工具面板显隐独立于 F3 总开关）
- 可见性/开关/面板位置持久化到用户配置 debug_settings.cfg（ConfigManager 的
  debug/overlay、debug/legend 设置项优先）

---

## 依赖

- `core/`（EventBus、ConfigManager、BalanceConfig）；`modules/ui_global/`（LayerOrder
  层级常量、StickKit 主题）；F4 特效试放调 `modules/fx/`（FxLibrary/FxPool）
- 绘制器注册与地图路径表由 `modules/world/scripts/setup/system_setup.gd`
  （register_debug_drawers）装配注入

---

## 扩展指引

新绘制器三步：`debug_drawers.gd` 加 static func → world 侧 register_debug_drawers
登记 → `debug_panel.gd` 的 DRAWER_NAMES_ZH 补中文名。HD-2D 图画"地面锚定物"
（线/框/文字/标记）必须经 `DebugDrawers._ground_y` 重映射，禁止按 2D y 直绘
（公式见 docs/技术/架构/建筑管线/HD-2D街景系统.md）。
