# UI 面板体系迁移余项（已收官 2026-10-06）

> 布局真相源与模板体系迁移收口；观感验收见待办事项「待创始人验收」行。

- [x] 未迁模板六面板清零：
  - **BuildMenu → DOCK**（首个 DOCK 业务面板，验证了模板）：列表窗 `BuildListWindow extends StickWindow(DOCK, BOTTOM_RIGHT)`——右下停靠 + 安全矩形夹紧（底带让位）+ 标题栏✕ + ESC 自关 + 面板外穿透；入口「建造」按钮与选址提示同步合规化（dock 出口 / 避开 top_right zone）；死场景 build_menu.tscn（无脚本无引用）根除
  - **DebugToolsPanel → FLOATING**：手写标题栏拖动/根全屏锚全数删去，改继承 StickWindow(FLOATING)（基类拖动/ESC/夹紧），点放模式 _unhandled_input 保留并接通基类
  - **BattlePanel / PossessPanel → 底栏部件标准**：裸 Control 根加 PanelContainer + `StickStyle.window_panel_light` 黑玻璃通栏 + MarginContainer（HUD 部件标准，与顶栏/资源条同质感），手写 offset 清零
  - **ContextPanel / ModePanel → 结构合规（无需迁移）**：均为 .tscn 声明的槽容器（布局真相源），经 UIRoot._apply_theme 挂 StickTheme，自身零代码建控件——「未迁」标记针对的实为 ModePanel 内的 Battle/Possess 占位，已随上项收口
- [x] DOCK/POPOVER 接首个业务面板验证：**DOCK 已验证**（BuildMenu，含基类补强：dock_corner 四角可选 + DOCK 也夹安全矩形——原实现硬编码 TOP_RIGHT 且不夹紧，接首个业务面板即暴露即修）；POPOVER 仍无业务消费方，接首个下拉/选择器时再验（届时无待办挂账，属模板例行验证）
- [x] `debug_overlay.gd` 余 2 处 `Control.new()` 根迁 UIKit.full_rect（_draw_control 直迁；_entity_info_panel 连带根治——debug_info_panel.gd 删手动 size 自管，根锚定归装配出口）
