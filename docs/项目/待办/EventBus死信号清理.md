# EventBus 死信号二次清理

> 2026-09-09 对账刷新：travel_completed（订户 map_transition_overlay）、strategic_map_opened（订户 l3_map_controller）已活，从死信号清单划掉。
> 2026-10 二次对账（全文核订户）：org 状态信号三枚与 map_unloaded EventBus 版实有生产订户，从死信号清单划掉并停手报备；chunk 两枚 EventBus 版与 building_started 确认零订户，已下线。

- [x] chunk_loaded/chunk_unloaded（EventBus 版）已下线：声明 + scene_loader 经 `_emit_event_bus` 的转发一并删除；`scene_loader.gd` 自带同名信号零订户但是 chunk 流式预留接口，按既定裁决保留
- [x] balance_changed 已复活销项：balance_config.gd 发射 + organization/default_behavior_writer.gd 热重载接线（生产订户，改 .tres 免重启）
- [x] building_started（construction/api.gd）已下线：声明 + start_construction/start_construction_at 两处发射删除；`start_construction*` 行为不变（返回值契约不变）
- [ ] map_unloaded（EventBus 版）**是活信号，不下线**：MusicDirector autoload 生产订户（`music_director.gd` `_wire_event_bus` → `_on_map_unloaded` 重置音乐情境 map_type）；另 smoke `test_cross_map_travel` 订阅并断言其转发。`scene_loader.gd` 自带版为另一条活链路（game_root_map_flow 消费）
- [ ] org_created/org_restructured/org_disbanded（organization/api.gd）**是活信号，不下线**：三个组织 UI 生产订户——`org_panel.gd` / `command_chain_view.gd` / `strategic_overview_panel.gd` 各自 `_connect_signals` 订 `_org_api` 三信号全量重建；另有 unit `test_organization_manager.gd` 信号契约测试
- [x] resource_not_enough（resources/api.gd，**resources 模块 api 信号，非 EventBus 信号**）已复活销项：玩家拍板"加上"——`ui_global` 的 ResourceBar 订阅（`resource_bar.gd` `_connect_signals`），扣减失败在资源条对应条目尾部浮出红字"缺N"，2s 节流窗内重复失败只刷新文案不重弹（防加工职业原料断供时每拍重试刷屏）；unit `test_resource_bar_hint.gd` 覆盖提示可见/节流合并/窗外重弹
