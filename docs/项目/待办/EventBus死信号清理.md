# EventBus 死信号二次清理

> 2026-09-09 对账刷新：travel_completed（订户 map_transition_overlay）、strategic_map_opened（订户 l3_map_controller）已活，从死信号清单划掉。

- [ ] 仍死：chunk_loaded/chunk_unloaded 零订户（scene_loader 双发无订阅）、map_unloaded 仅测试订户、balance_changed 有发射零生产订户（balance_config.gd 自注「热重载预留」）
- [ ] 模块 api 状态信号 building_started/resource_not_enough/org_created·restructured·disbanded（已迁各模块 api.gd，非 EventBus）仍零消费方
