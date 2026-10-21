# EventBus 死信号二次清理

> 2026-09-09 对账刷新：travel_completed（订户 map_transition_overlay）、strategic_map_opened（订户 l3_map_controller）已活，从死信号清单划掉。
> 2026-10 二次对账（全文核订户）：org 状态信号三枚与 map_unloaded EventBus 版实有生产订户，从死信号清单划掉并停手报备；chunk 两枚 EventBus 版与 building_started 确认零订户，已下线。

- [x] chunk_loaded/chunk_unloaded（EventBus 版）已下线：声明 + scene_loader 经 `_emit_event_bus` 的转发一并删除；`scene_loader.gd` 自带同名信号零订户但是 chunk 流式预留接口，按既定裁决保留
- [x] balance_changed 已复活销项：balance_config.gd 发射 + organization/default_behavior_writer.gd 热重载接线（生产订户，改 .tres 免重启）
- [x] building_started（construction/api.gd）已下线：声明 + start_construction/start_construction_at 两处发射删除；`start_construction*` 行为不变（返回值契约不变）
- [ ] map_unloaded（EventBus 版）**是活信号，不下线**：MusicDirector autoload 生产订户（`music_director.gd` `_wire_event_bus` → `_on_map_unloaded` 重置音乐情境 map_type）；另 smoke `test_cross_map_travel` 订阅并断言其转发。`scene_loader.gd` 自带版为另一条活链路（game_root_map_flow 消费）
- [ ] org_created/org_restructured/org_disbanded（organization/api.gd）**是活信号，不下线**：三个组织 UI 生产订户——`org_panel.gd` / `command_chain_view.gd` / `strategic_overview_panel.gd` 各自 `_connect_signals` 订 `_org_api` 三信号全量重建；另有 unit `test_organization_manager.gd` 信号契约测试
- [ ] resource_not_enough（resources/api.gd）**待裁决**：生产零订户，但 unit `test_resources_api.gd` 订阅并断言（consume 不足通知调用方 = api 契约行为），下线须同步删契约测试与 api 注释——是否清理由创始人定
