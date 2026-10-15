# UI 模态栈深化（已收官 2026-10-06）

> 三件全部落地；规则文档 docs/技术/UI/弹窗与模态.md §一（强/弱两级设计本就定稿，实现本次跟上）。

- [x] **强/弱模态分级**：UIModalStack 增 `STRONG_LAYERS`（ESC 屏蔽：消费但不退栈、不落暂停菜单）；载入屏入 `WORLD_LOAD` 强模态层（show_loading 入栈 / 淡出经可见性同步自动退栈）——加载期 ESC 彻底失效。新游戏向导建成时并入 STRONG_LAYERS 即可（机制就绪）
- [x] **战略图并入层键**：Layer 增 `STRATEGIC_MAP`（L1/L2/L3 三视图互斥同键）；三控制器 `visibility_changed` 自注册入栈（open/open_l1/open_region/下钻回显全路径覆盖），关闭/下钻经栈可见性同步自动退栈；GameRoot._handle_escape 的战略图特判删除（L1 的 handle_escape 下钻语义由栈委托保留）。配套：**活层**（`LIVE_LAYERS`，入栈不接管时间——开图不冻结模拟、载入屏时间流归启动序列），暂停簿记按「栈内无非活层才恢复」修正（活层盖在暂停层上再退时不提前恢复）
- [x] **载入屏并入层号常量**：LayerOrder 增 `BOOT_LOADING := 110`（> 全部场景内层号，原手写 100 与 STRATEGIC_L1 撞号）；loading_screen 跳板层引用常量
