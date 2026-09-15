# environment：跨场景昼夜环境（时间 / 光照 / 天空底色 / 全屏后处理）

> 环境时钟推进（接 WorldState.game_time）并映射到两条独立色彩轨道：环境光
> （CanvasModulate，染地表一切，夜晚压至剪影量级）与天空底色（RenderingServer
> 清屏色，不经 CanvasModulate）；画在默认画布的发光体（星月/极光/萤火）经
> `unmodulate` 除法补偿穿透夜间压暗。另挂全屏后处理层（layer 0.5，压在游戏世界
> 之上、UIROOT 之下，UI 永不受后处理污染）。

---

## 目录结构

```
modules/environment/
├── api.gd                          # EnvironmentAPI：昼夜关键帧双轨表 + 插值采样 + unmodulate（全局类，纯静态）
├── scripts/
│   ├── environment_system.gd       # EnvironmentSystem：时钟推进（sim_delta 倍速感知）+ CanvasModulate + 清屏色 + 营火光（默认关）
│   └── post_process_layer.gd       # PostProcessLayer：全屏后处理（bind_env 昼夜联动，暂停时炫光淡出）
└── shaders/
    ├── post_process.gdshader       # 六层后处理一次采样：色差/暖色分级/顶部天光/太阳炫光/渐晕/颗粒（颗粒恒 0）
    └── pond_reflection.gdshader    # 水面倒影（屏幕纹理沿水面线镜像 + 正弦波纹），使用方在 modules/world 的 pond.gd
```

---

## 对外契约

- `EnvironmentAPI.sample_light_color(hour)` / `sample_sky_bg_color(hour)`：关键帧插值采样
- `EnvironmentAPI.unmodulate(color, canvas_modulate_color)`：发光体补偿（world 的
  星月/极光/萤火绘制在用）
- `EnvironmentSystem.get_current_light_color()`：当前环境光色（后处理层与 units
  战斗 AI 查询）
- `EnvironmentSystem.reset_to_new_run_clock()`：新开局重置到清晨（GameRoot 新游戏分支调）

---

## 依赖

- `core/`（WorldState、TimeManager.sim_delta、EventBus.game_loaded）；装配方
  `modules/world/`（SystemSetup 创建 EnvironmentSystem 与 PostProcessLayer 并 bind_env）

---

## 开发注意事项

- 调昼夜观感改 `api.gd` 的 LIGHT_KEYFRAMES / SKY_BG_KEYFRAMES（hour 升序、首尾同值闭环）
- 倍速/暂停一律经 TimeManager：暂停冻结由引擎总闸负责，步长必须走 sim_delta；
  读档时钟对齐依赖 game_loaded 连接顺序（WorldState 先连）
