@tool
class_name EchoEditorTheme
extends RefCounted
## ============================================================================
## EchoEditorTheme —— 残响关卡编辑器的**统一外观**（第 48 轮 UI 美化）
## ----------------------------------------------------------------------------
## ⚠ 名字里带 Echo 前缀不是审美问题：Godot **编辑器自带一个 `EditorTheme` 类** ✗，
##   直接叫 `EditorTheme` 会与引擎撞名（编译期 "not declared"/被遮蔽，实测踩到 ✓）。
##   这类"内置名冲突"在这个项目里已经踩过第三次（is_boss / reload / EditorTheme），
##   每加全局类前都值得先搜一眼 ✓。
## 为什么要有这个文件：
##   之前各页面各自 `add_theme_color_override(...)` / `add_theme_constant_override(...)` ✗，
##   颜色与间距散落十几处、彼此不一致 —— 看起来"能用但不好看"。
##   现在**只在这里定一套**配色/圆角/内边距/字号，在插件根节点挂一次，
##   所有子页面自动继承 ✓（Godot 的 Theme 是沿节点树继承的 ✓）。
##
## 设计取向（编辑器场景，长时间盯着看）：
##   · 底色偏冷的深灰蓝（不刺眼）；面板比底色**略亮**，靠"亮度差"分层而不是靠边框堆叠；
##   · 强调色用柔和的青蓝（accent），危险/错误用低饱和红（err），不做高饱和艳色；
##   · 圆角统一 4px、按钮最小高度 26px、行内间距 6px —— 手感一致 ✓；
##   · 标题/小标题用字号 + 灰度区分层级（而不是粗体轰炸 ✓）。
## ============================================================================

# ── 调色板（改这里就能整体换肤）────────────────────────────────────────────
const BG := Color(0.145, 0.157, 0.184)          ## 页面底色
const PANEL := Color(0.176, 0.192, 0.227)       ## 面板底
const PANEL_HI := Color(0.208, 0.227, 0.267)    ## 面板高亮（悬停/选中）
const BTN := Color(0.212, 0.231, 0.271)
const BTN_HOVER := Color(0.255, 0.278, 0.325)
const BTN_PRESSED := Color(0.173, 0.290, 0.392)
const BORDER := Color(0.275, 0.302, 0.353)
const TEXT := Color(0.878, 0.894, 0.925)
const TEXT_DIM := Color(0.588, 0.639, 0.706)
const ACCENT := Color(0.404, 0.702, 0.902)      ## 强调（青蓝）
const OK := Color(0.451, 0.784, 0.510)
const WARN := Color(0.949, 0.769, 0.353)
const ERR := Color(0.910, 0.443, 0.451)

const RADIUS := 4
const BTN_H := 26

## 造一个 StyleBoxFlat（统一圆角/边框/内边距，避免各处手搓 ✗）
static func box(bg: Color, border_w := 1, border := BORDER, radius := RADIUS,
		pad_h := 8, pad_v := 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	if border_w > 0:
		sb.border_width_left = border_w
		sb.border_width_right = border_w
		sb.border_width_top = border_w
		sb.border_width_bottom = border_w
		sb.border_color = border
	return sb

## 造出整份主题（在插件根节点赋一次即可）
static func make() -> Theme:
	var t := Theme.new()

	# ── 基础字体色 ────────────────────────────────────────────────────────
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", 12)
	t.set_color("font_color", "Button", TEXT)
	t.set_font_size("font_size", "Button", 12)
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_font_size("font_size", "OptionButton", 12)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_color", "SpinBox", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_color", "TabContainer", TEXT)
	t.set_font_size("font_size", "TabContainer", 12)

	# ── 按钮：常态/悬停/按下/焦点/禁用（五态齐全才"像个编辑器" ✓）─────────
	t.set_stylebox("normal", "Button", box(BTN))
	t.set_stylebox("hover", "Button", box(BTN_HOVER, 1, ACCENT.darkened(0.25)))
	t.set_stylebox("pressed", "Button", box(BTN_PRESSED, 1, ACCENT))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), 1, ACCENT))
	t.set_stylebox("disabled", "Button", box(BTN.darkened(0.25), 1, BORDER.darkened(0.3)))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_pressed_color", "Button", Color(1, 1, 1))
	t.set_color("font_disabled_color", "Button", TEXT_DIM.darkened(0.2))
	t.set_constant("h_separation", "Button", 6)

	# ── 下拉框 ────────────────────────────────────────────────────────────
	t.set_stylebox("normal", "OptionButton", box(BTN))
	t.set_stylebox("hover", "OptionButton", box(BTN_HOVER, 1, ACCENT.darkened(0.25)))
	t.set_stylebox("pressed", "OptionButton", box(BTN_PRESSED, 1, ACCENT))
	t.set_stylebox("focus", "OptionButton", box(Color(0, 0, 0, 0), 1, ACCENT))
	t.set_stylebox("normal", "PopupMenu", box(PANEL, 1, BORDER, RADIUS, 6, 4))
	t.set_stylebox("hover", "PopupMenu", box(BTN_HOVER))

	# ── 输入框类 ──────────────────────────────────────────────────────────
	var field := box(BG.darkened(0.08), 1, BORDER, RADIUS, 6, 3)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", box(BG.darkened(0.08), 1, ACCENT, RADIUS, 6, 3))
	t.set_stylebox("normal", "SpinBox", field)
	t.set_stylebox("normal", "CheckBox", box(Color(0, 0, 0, 0), 0, BORDER, 0, 2, 2))

	# ── 面板：圆角 + 细边框（靠亮度差分层的核心）──────────────────────────
	t.set_stylebox("panel", "PanelContainer", box(PANEL, 1, BORDER, 6, 6, 6))
	t.set_stylebox("panel", "Panel", box(PANEL, 1, BORDER, 6, 6, 6))
	t.set_stylebox("panel", "TabContainer", box(BG, 0, BORDER, 0, 0, 0))
	t.set_stylebox("tab_selected", "TabContainer", box(PANEL_HI, 1, ACCENT, RADIUS, 10, 5))
	t.set_stylebox("tab_unselected", "TabContainer", box(PANEL.darkened(0.12), 1, BORDER, RADIUS, 10, 5))
	t.set_stylebox("tab_hovered", "TabContainer", box(PANEL_HI, 1, BORDER, RADIUS, 10, 5))
	t.set_color("font_selected_color", "TabContainer", Color(1, 1, 1))
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)

	# ── 滚动区/分隔线（细、暗，不抢戏 ✓）──────────────────────────────────
	t.set_stylebox("panel", "ScrollContainer", box(Color(0, 0, 0, 0), 0, BORDER, 0, 0, 0))
	t.set_stylebox("separator", "VSeparator", box(BORDER, 0, BORDER, 0, 0, 0))
	t.set_constant("separation", "VSeparator", 1)
	t.set_stylebox("separator", "HSeparator", box(BORDER, 0, BORDER, 0, 0, 0))
	t.set_stylebox("scroll", "VScrollBar", box(BG.darkened(0.1), 0, BORDER, RADIUS, 2, 2))
	t.set_stylebox("grabber", "VScrollBar", box(BTN_HOVER, 0, BORDER, RADIUS, 2, 2))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(ACCENT.darkened(0.2), 0, BORDER, RADIUS, 2, 2))

	# ── 文本层级：小标题 / 标题（用**类型变体**，各处不再手搓颜色 ✓）────────
	t.set_type_variation(&"Caption", &"Label")
	t.set_color("font_color", "Caption", TEXT_DIM)
	t.set_font_size("font_size", "Caption", 11)
	t.set_type_variation(&"Title", &"Label")
	t.set_color("font_color", "Title", Color(1, 1, 1))
	t.set_font_size("font_size", "Title", 14)
	t.set_type_variation(&"Hint", &"Label")
	t.set_color("font_color", "Hint", TEXT_DIM)
	t.set_font_size("font_size", "Hint", 10)
	t.set_type_variation(&"Danger", &"Label")
	t.set_color("font_color", "Danger", ERR)
	t.set_font_size("font_size", "Danger", 11)

	# ── 语义色：**用类常量暴露**（`EchoEditorTheme.ACCENT` 等）────────────────
	# ⚠ 实测坑：Theme **不接受"自定义类型"的颜色** ✗ ——
	#   `t.set_color("accent_color", "EchoEditorTheme", ...)` 会被静默忽略（has_color 为 false ✗）。
	#   所以语义色统一走文件顶部的常量 ✓（代码里直接 `EchoEditorTheme.ACCENT` 即可 ✓）。
	return t

## 便捷：把某个 Label 设成"小标题"（等价于 set_theme_type_variation ✓）
static func as_caption(lab: Label) -> Label:
	lab.theme_type_variation = &"Caption"
	return lab

## 便捷：一行工具条的"分组标题 + 竖分隔"（统一各处写法 ✓）
static func add_group_title(row: HBoxContainer, text: String) -> void:
	if row.get_child_count() > 0:
		row.add_child(VSeparator.new())
	var lab := Label.new()
	lab.text = text
	lab.theme_type_variation = &"Caption"
	lab.tooltip_text = text
	row.add_child(lab)
