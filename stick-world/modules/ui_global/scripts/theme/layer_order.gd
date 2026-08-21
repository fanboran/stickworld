class_name LayerOrder
extends RefCounted
## 全游戏 UI 层号统一常量 —— 一处定义、处处引用，杜绝魔法数字。
##
## 参照《药剂工艺》SpriteSortingLayers 集中式层序（见 docs/设计/UI/10-UI系统重构参考.md）。
## 分两类：
##   CanvasLayer.layer   —— 不同 CanvasLayer 之间的层序
##   UIRoot 内 z_index   —— 同一 CanvasLayer 内 Control 之间的层序

# ─────────────────────────────── CanvasLayer 层号 ────────────────────────────────

## UIRoot（全局 UI：HUD / 模式 / 上下文 / 模态 / 系统 / 调试 都在其内，用 z_index 细分）
const HUD := 1
## 世界加载覆盖层（game_root 下独立 CanvasLayer，须高于 UIRoot）
const WORLD_LOADING := 10
## 调试覆盖层（debug_GUI，F3）
const DEBUG_OVERLAY := 20
## 战略图 L1（Tab）
const STRATEGIC_L1 := 100
## 战略图 L3（M）
const STRATEGIC_L3 := 101
## 战略图 L2（L3 下钻）
const STRATEGIC_L2 := 102

# ─────────────────────────────── UIRoot 内 z_index ────────────────────────────────

## HUD 槽（GlobalHUD / ModePanel / ContextPanel / HudOverlay / ResourceBar）
const Z_HUD := 0
## 模态层（ModalOverlay：排他模态盖住 HUD 槽）
const Z_MODAL := 50
## 系统层（SystemOverlay：toast / 确认框，在模态之上）
const Z_SYSTEM := 90
## F3 调试 inspect（最高，纯绘制）
const Z_INSPECTOR := 100
