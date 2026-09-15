# player_control：玩家输入模式分发与附身操控

> 管理输入模式的切换与路由：按当前模式（探索/建设/战斗/附身/室内/UI）把控制权
> 交给对应 handler。实际 WASD/鼠标消费在 units 的 StickmanEntity（P0 简化）；
> 框选/编队/战术指令实现在 combat 模块 scripts/command/，经 GameRoot 装配协同。
>
> 设计文档见 docs/设计/系统/09-输入与操作复刻.md；架构详见
> docs/技术/架构/场景与战斗/战斗与AI.md。

---

## 目录结构

```
modules/player_control/
├── api.gd                          # PlayerControlAPI：Mode 枚举 + InputDispatcher 注册表 + 模式切换规则说明
├── scripts/
│   ├── input_dispatcher.gd         # InputDispatcher：set_mode 切换模式、路由到注册 handler、发射 mode_changed
│   ├── explore_handler.gd          # EXPLORE handler：激活时附身玩家实体；切 BATTLE 保持附身，其余模式释放
│   └── possession_interface.gd     # POSSESS handler：附身选中单位 + 相机跟随居中 + 自动降速 X1 + ESC 退出恢复
└── ui/
    └── possess_panel.gd            # 附身 HUD：HP/士气/武器冷却/情绪/行为/坐标 + 退出附身按钮
```

---

## 对外契约

- 模式枚举 `PlayerControlAPI.Mode`（NONE/EXPLORE/BUILD/BATTLE/POSSESS/INDOOR/UI）
- `PlayerControlAPI.register_input_dispatcher / get_input_dispatcher`：跨模块取
  dispatcher 的唯一入口（units 等经此，不做 group 反查）
- `InputDispatcher` 信号 `mode_changed(old_mode, new_mode)`；`register_handler(mode, handler)`
  注册处理器，handler 实现 `_on_mode_activated` / `_on_mode_deactivated`
- `PossessionInterface.get_possessed_entity / possess(entity) / release()`
- EventBus：`possession_started / possession_ended`（PossessionInterface 发射）

---

## 依赖

- `core/`（EventBus、TimeManager）；装配方 `modules/world/`（SystemSetup 实例化
  dispatcher/handler/面板并注册 handler）；附身候选来自 combat 的 SelectionSystem

---

## 扩展指引

新输入模式三步：`api.gd` 的 Mode 加枚举 → 新 handler 实现激活/停用回调 →
`modules/world/scripts/setup/system_setup.gd` 装配并 `register_handler`。
