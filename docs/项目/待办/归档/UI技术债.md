# UI 系统技术债（已收官 2026-10-06）

> 四项全部完成，收线归档；观感验收见待办事项「待创始人验收」行。

- [x] **PossessPanel 每帧刷新改信号驱动**：HP/士气订阅 health 组件 damaged/healed/morale_changed（附身开始绑、结束拆）；无信号连续值（冷却/情绪/行为/朝向/坐标）0.2s Timer 兜底——每帧字符串重建清零
- [x] **hover_indicator 悬停检测移出 `_process`**：`_unhandled_input` 鼠标移动事件驱动（0.1s 节流合并；GUI 消费过的移动不触发=光标在 UI 上不做世界悬停）；空闲 `set_process(false)` 零轮询，悬停期才跑呼吸+复扫。已知取舍：暂停解除后光标不动则框不重现（TimeManager 无变速信号可钩）
- [x] **Minimap 样式统一**（做做样子④ 收尾）：边框换 `StickTokens.BORDER_STRONG` 白描边、占位底换 `WINDOW_BG` 黑玻璃、语义实体色全部收编内容色板/操作色（sky_blue/grass/sand/clay/DANGER/SUCCESS），token 函数取值装不进 const 故为成员色表
- [x] **QuestPanel 复用与重叠修复**（前置完成）：部件本就 zone 化（体量声明、无自算定位），复用挂 `top_left_stack` 即堆叠区自动排布（重叠根源=手工定位已不存在）；标签硬编码色一并收编 StickTokens（ACCENT/TEXT/TEXT_DIM/SUCCESS）
