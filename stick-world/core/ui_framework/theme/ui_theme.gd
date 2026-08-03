class_name UITheme
extends RefCounted
## UI 主题最小集 —— 从现有面板实测值提炼的字号/颜色常量（2026-08 审计）。
##
## 不做完整设计语言/样式系统（那是阶段 1 打磨期的事），只统一最混乱的两项：
## 字号层级与面板主色。新 UI 直接引用；旧 UI 迁移时"扫地出门"顺手替换。

# ─────────────────────────────── 字号层级 ────────────────────────────────

## 面板/弹窗大标题（如"设置""存档管理"）
const FONT_TITLE := 22
## 区块小标题（面板内分节标题，如"游戏""调试"）
const FONT_SECTION := 13
## 正文/按钮文字
const FONT_BODY := 14
## 提示/辅助文字（按钮组标题、操作提示）
const FONT_HINT := 11

# ─────────────────────────────── 颜色 ────────────────────────────────

## 区块标题色（浅蓝，面板内分节）
const COLOR_SECTION_TITLE := Color(0.7, 0.85, 1.0)
## 灰色小标题（PanelKit.create_section 的标题）
const COLOR_GRAY_TITLE := Color(0.7, 0.7, 0.7)
## 弱化提示文字
const COLOR_DIM_TEXT := Color(0.65, 0.65, 0.65)

# ─────────────────────────────── 遮罩 ────────────────────────────────

## 模态面板遮罩透明度（SettingsMenuPanel）
const BG_MODAL := 0.55
## 全屏导航/强遮挡遮罩透明度（WorldMapPanel 0.7）
const BG_MODAL_STRONG := 0.7
