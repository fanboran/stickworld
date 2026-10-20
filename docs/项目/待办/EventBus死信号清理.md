# EventBus 死信号二次清理

> 2026-09-09 对账刷新：travel_completed（订户 map_transition_overlay）、strategic_map_opened（订户 l3_map_controller）已活，从死信号清单划掉。

- [ ] 仍死：chunk_loaded/chunk_unloaded 零订户（scene_loader 双发无订阅，运行期活信号为 scene_loader 自带版）、map_unloaded 仅测试订户（运行期活信号为 scene_loader 自带版，EventBus 版零消费）
- [x] balance_changed 已复活销项：balance_config.gd 发射 + organization/default_behavior_writer.gd 热重载接线（生产订户，改 .tres 免重启）
- [ ] 模块 api 状态信号 building_started/resource_not_enough/org_created·restructured·disbanded（已迁各模块 api.gd，非 EventBus）仍零消费方
