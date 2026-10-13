@tool
class_name EditorCutscenePanel
extends VBoxContainer
## ============================================================================
## EditorCutscenePanel —— 插件里的「过场动画」页（CapCut 式关键帧时间轴）
## ----------------------------------------------------------------------------
## 界面：
##   顶部  过场选择 / 新建 / 时长 / 播放·停止 / 撤销·重做·校验·保存·重新载入
##          + 两种录制入口：「导入实时录制」「在播放头打点」
##   中间  时间轴（EditorTimeline：刻度尺 + 轨道行 + 可拖拽关键帧 + 播放头）
##   右侧  检查器：轨道信息与增删、选中关键帧的字段表单（按轨道种类自动出控件）、
##          以及"播放头处各轨道的采样读数"（手动打点时的参照）
##   底部  状态（校验问题、干跑问题、未保存标记）
##
## 两种录制模式（对应需求里的"两种录制模式"）：
##   ① **实时录制**：在游戏里按 F6 采样玩家轨迹（写 user://cutscene_recording.json），
##      回到这里点「导入实时录制」→ EditorCutsceneDoc.stamp_from_samples() 生成 actor 轨道；
##   ② **手动打点**：拖播放头到某时刻 → 点「在播放头打点」→ 以当前采样值插一帧，
##      再在右侧把 x/y/zoom 等调到想要的数值。
## ============================================================================

var doc: EditorCutsceneDoc = null
var timeline: EditorTimeline = null
## 画面预览监视器（第 35 轮新增）：时间轴正上方的"画面参考"。
## 没有它就只能盲编 —— 看不到镜头取景/角色走位/字幕压上来的时刻。
var preview: EditorCutscenePreview = null
## 工作区分栏（第 40 轮，剪映版式；第 41 轮修"左右分栏拖不动"）
## ----------------------------------------------------------------------------
## 第 41 轮修的真 bug：默认布局用 `int(size.x) - 520` 计算，而 `_build_ui()` 时
## 面板 size 还是 0 → 负值被 maxi 兜成写死的 320/200 ✗；再加上子控件最小尺寸
## （320/300/190）几乎吃满可用宽度 → SplitContainer 没有余量，于是**拖不动**。
## 现在：① 按当前尺寸 × **比例**分配；② 尺寸未就绪时什么都不做（等 resized）；
## ③ 子控件最小尺寸调小、**分隔条加宽到 10px**（好抓）；④ `dragged` 后把比例记下来，
## 窗口变化不会把用户的调整冲掉；⑤ 另给两个一键收起按钮（拖不动时的保底手段）。
var _main_split: VSplitContainer = null
## 上排（素材库 | 播放器 | 检查器）——普通 HBox + 精确宽度，第 41 轮最终方案
var _top_row: HBoxContainer = null
var _library_panel: PanelContainer = null
var _cutscene_list: VBoxContainer = null
var _inspector_panel: PanelContainer = null
## 布局比例（用户改动后更新；窗口 resize 时按比例还原，不写死像素）
var layout_top_ratio := 0.60      ## 上排占总高度
var layout_lib_ratio := 0.16      ## 素材库占总宽度
var layout_insp_ratio := 0.20     ## 属性检查器占总宽度
## 两栏的最小宽度（保证按钮/字段能用）
const LIB_MIN_W := 190.0
const INSP_MIN_W := 240.0
var _lib_btn: Button = null
var _insp_btn: Button = null
## 显式宽度数值框（第 41 轮：主调整手段，不依赖拖拽手感）
var _lib_spin: SpinBox = null
var _insp_spin: SpinBox = null
## 播放器窗口高度数值框（第 43 轮：让"窗口可拉伸压缩"变成确定可改）
var _pre_spin: SpinBox = null
## 布局行与左右拖动把手（第 41 轮最终修法：常驻可见 + 自绘把手）
var _layout_bar: HBoxContainer = null
var _handle_l: Control = null
var _handle_r: Control = null
var _dragging_handle := -1
## 第 45 轮（① 面板 dock 化）：把"素材库 / 属性检查器"交给编辑器侧栏后，页面里不再持有它们
var _lib_dock: Control = null
var _insp_dock: Control = null
var _dock_mode := false
## 拖拽捕获：按下时的鼠标 x 与两栏起始比例（绝对增量法）
var _drag_anchor_x := 0.0
var _drag_start_lib := 0.0
var _drag_start_insp := 0.0

var _picker: OptionButton = null
var _inspector: VBoxContainer = null
var _status: Label = null
var _duration_spin: SpinBox = null
var _play_btn: Button = null
var _playing := false
var _dialog: AcceptDialog = null
var _recording_path := "user://cutscene_recording.json"

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build_ui()
	set_process(true)
	# 关键：布局要等面板真正拿到尺寸后再算一次（`_build_ui` 时 size 还是 0）
	_apply_layout_ratios.call_deferred()
	var ids := EditorCutsceneDoc.available_ids()
	if ids.is_empty():
		_set_status("data/cutscenes/ 里还没有过场，点「新建」开始", false)
	else:
		_load_cutscene(StringName(str(ids[0])))

# ============================================================================
# 界面
# ============================================================================
func _build_ui() -> void:
	add_child(_build_toolbar())
	# 第 41 轮最终修法：**布局控件单独一行常驻显示**。
	# 之前我把它们加进上面那条工具条里，而工具条是横向 ScrollContainer ✗ →
	# 控件全落在可视区外，用户根本看不到（"屁用没有"的真因之一）。
	add_child(_build_layout_bar())

	# ========================================================================
	# 工作区：**照剪映重排**（第 40 轮，用户明确要求）
	# ------------------------------------------------------------------------
	# 剪映的版式是四块：
	#   左 = 素材库          ｜ 中 = 播放器（预览）  ｜ 右 = 属性检查器
	#   下 = 时间线（**横跨全宽**）
	# 之前我做成了"播放器在最上方、时间线与检查器左右并排"——与剪映不一致。
	# 现在：外层 VSplit[ 上排 , 时间线 ]，上排再 HSplit[ 素材库 , HSplit[ 播放器 , 检查器 ] ]。
	# 三条分隔条都能拖；「默认布局」复位；「全屏」收起左右两栏。
	# ========================================================================
	_main_split = VSplitContainer.new()
	_main_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 分隔条加宽到 10px：6px 时几乎抓不住（第 41 轮用户反馈"拖不动"的体感原因之一）
	_main_split.add_theme_constant_override("separation", 10)
	add_child(_main_split)

	# ---- 上排：素材库 | 播放器 | 检查器 ----
	# 第 41 轮最终方案：左右两栏用**精确宽度**（custom_minimum_size + 不吃多余空间），
	# 只有**播放器**吃剩余空间。这样"改宽度"是确定性的，不依赖 SplitContainer 的内部
	# 语义与鼠标抓取（它在嵌套布局里反复出现"设了偏移但宽度不变"）。
	var top := HBoxContainer.new()
	_top_row = top
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 6)
	_main_split.add_child(top)

	# ① 左：素材库（固定宽度；点条目 = 插到播放头）
	_library_panel = _build_library()
	_library_panel.size_flags_horizontal = Control.SIZE_FILL
	top.add_child(_library_panel)

	# 左把手：拖它改"素材库 ↔ 播放器"的分界（自绘 + 自己处理拖动，见 _on_handle_input）
	_handle_l = _build_drag_handle(0)
	top.add_child(_handle_l)

	# ② 中：播放器（画面预览监视器；唯一 SIZE_EXPAND_FILL → 吃掉剩余宽度）
	preview = EditorCutscenePreview.new()
	preview.custom_minimum_size = Vector2(240, 140)
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.seek_requested.connect(_on_preview_seek)
	preview.play_requested.connect(_toggle_play)
	preview.step_requested.connect(_on_preview_step)
	# 第 39 轮：在预览里拖/滚改镜头 → 打关键帧（真的写进 camera 轨道）+ 全屏预览
	preview.key_requested.connect(_on_preview_key)
	preview.fullscreen_toggled.connect(_on_preview_fullscreen)
	top.add_child(preview)

	# 右把手：拖它改"播放器 ↔ 属性检查器"的分界
	_handle_r = _build_drag_handle(1)
	top.add_child(_handle_r)

	# ③ 右：属性检查器（固定宽度）
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(300, 0)
	right.size_flags_horizontal = Control.SIZE_FILL
	_inspector_panel = right
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 4)
	scroll.add_child(_inspector)
	top.add_child(right)

	# 面板尺寸变化（打开/切页/改窗口）→ 按比例重排；尺寸未就绪时本函数会自己跳过
	resized.connect(_apply_layout_ratios)

	# ④ 下：时间线（横跨全宽）
	timeline = EditorTimeline.new()
	timeline.custom_minimum_size = Vector2(0, 150)
	timeline.playhead_changed.connect(_on_playhead_changed)
	timeline.key_selected.connect(_on_key_selected)
	timeline.key_moved.connect(_on_key_moved)
	timeline.track_selected.connect(func(i: int) -> void:
		_refresh_inspector())
	# 用户抓住刻度尺/播放头开始拖动 → 立刻停止播放（手动擦洗与播放推进不能抢时间轴）
	timeline.scrub_began.connect(_on_scrub_began)
	_main_split.add_child(timeline)

	# 初始分配（之后由用户拖；「默认布局」回到这里）
	_apply_default_layout()

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_dialog = AcceptDialog.new()
	_dialog.title = "提示"
	add_child(_dialog)

# ============================================================================
# 布局控件行（常驻可见）+ 左右拖动把手（第 41 轮最终修法）
# ----------------------------------------------------------------------------
# 教训：把布局控件塞进横向滚动的工具条 = 用户看不见 = "屁用没有"。
# 所以这一行**独立成行、永远可见**；左右分界用**自绘把手**（10px 宽 + 三个点），
# 拖动逻辑完全由我自己实现（改比例 → 重排），不依赖 SplitContainer 的内部行为。
# ============================================================================
# ============================================================================
# 工具条"最小宽度"隔离（第 44 轮，用户最重要的反馈）
# ----------------------------------------------------------------------------
# 症状：打开动画编辑器后，**整页比窗口宽** ✗ → 右侧被挤出屏幕、预览的中心跑到
# 可视区外（看起来就是"画面被压到右边、左边空一大片"），用户必须横向滚动/缩小才能看全。
# 根因：工具条内容很宽（几十个控件），而 ScrollContainer **仍会把内容的最小宽度
# 向上传递**给页面容器 → 页面最小宽度 = 3789px > 窗口宽度。
# 修法：外面套一个 `clip_contents = true` 的**纯 Control**（不是 Container，不参与最小
# 尺寸传递），它的最小宽度固定为 0；内层滚动区由 `resized` 手动铺满宿主。
# 于是"内容再宽也只在本行里滚动"，整页永远能塞进窗口 ✓。
# ============================================================================
func _wrap_scroll_no_min(inner_scroll: ScrollContainer, row_h: float) -> Control:
	var host := Control.new()
	host.clip_contents = true
	host.custom_minimum_size = Vector2(0, row_h)
	host.size_flags_horizontal = Control.SIZE_FILL
	host.add_child(inner_scroll)
	host.resized.connect(func() -> void:
		inner_scroll.position = Vector2.ZERO
		inner_scroll.size = host.size)
	return host

func _build_layout_bar() -> Control:
	var bar := HBoxContainer.new()
	_layout_bar = bar
	bar.add_theme_constant_override("separation", 6)
	var t := Label.new()
	t.text = "布局"
	t.add_theme_font_size_override("font_size", 11)
	bar.add_child(t)

	_lib_btn = Button.new()
	_lib_btn.text = "◧ 素材库"
	_lib_btn.toggle_mode = true
	_lib_btn.tooltip_text = "收起/展开左侧素材库"
	_lib_btn.pressed.connect(_toggle_library)
	bar.add_child(_lib_btn)

	var l1 := Label.new()
	l1.text = "宽"
	l1.add_theme_font_size_override("font_size", 11)
	bar.add_child(l1)
	_lib_spin = SpinBox.new()
	_lib_spin.min_value = 0
	_lib_spin.max_value = 900
	_lib_spin.step = 10
	_lib_spin.custom_minimum_size = Vector2(84, 0)
	_lib_spin.tooltip_text = "素材库宽度（像素）；0 = 收起。也可直接拖画面上那根把手"
	_lib_spin.value_changed.connect(func(v: float) -> void: _set_lib_width(int(v)))
	bar.add_child(_lib_spin)

	var l2 := Label.new()
	l2.text = "属性宽"
	l2.add_theme_font_size_override("font_size", 11)
	bar.add_child(l2)
	_insp_spin = SpinBox.new()
	_insp_spin.min_value = 0
	_insp_spin.max_value = 900
	_insp_spin.step = 10
	_insp_spin.custom_minimum_size = Vector2(84, 0)
	_insp_spin.tooltip_text = "属性检查器宽度（像素）；0 = 收起"
	_insp_spin.value_changed.connect(func(v: float) -> void: _set_insp_width(int(v)))
	bar.add_child(_insp_spin)

	_insp_btn = Button.new()
	_insp_btn.text = "属性 ◨"
	_insp_btn.toggle_mode = true
	_insp_btn.tooltip_text = "收起/展开右侧属性检查器"
	_insp_btn.pressed.connect(_toggle_inspector)
	bar.add_child(_insp_btn)

	# 播放器窗口高度（第 43 轮用户要求："窗口可拉伸压缩"）
	# 上下方向原本就能拖分隔条，但拖动不易发现 → 这里再给一个数值框，确定可改。
	var l3 := Label.new()
	l3.text = "预览高"
	l3.add_theme_font_size_override("font_size", 11)
	bar.add_child(l3)
	_pre_spin = SpinBox.new()
	_pre_spin.min_value = 120
	_pre_spin.max_value = 1400
	_pre_spin.step = 10
	_pre_spin.custom_minimum_size = Vector2(88, 0)
	_pre_spin.tooltip_text = "播放器窗口的高度（像素）；也可直接拖画面下方那根分隔条"
	_pre_spin.value_changed.connect(func(v: float) -> void: _set_preview_height(int(v)))
	bar.add_child(_pre_spin)

	bar.add_child(VSeparator.new())
	for preset: Array in [["1:3:1", 1.0, 3.0, 1.0], ["1:4:2", 1.0, 4.0, 2.0], ["大播放器", 0.0, 1.0, 0.0]]:
		var b := Button.new()
		b.text = str(preset[0])
		b.add_theme_font_size_override("font_size", 11)
		var pw := float(preset[1])
		var mw := float(preset[2])
		var iw := float(preset[3])
		b.pressed.connect(func() -> void: _apply_layout_preset(pw, mw, iw))
		bar.add_child(b)
	var reset := Button.new()
	reset.text = "默认布局"
	reset.add_theme_font_size_override("font_size", 11)
	reset.pressed.connect(_on_reset_layout)
	bar.add_child(reset)
	var logb := Button.new()
	logb.text = "布局信息"
	logb.add_theme_font_size_override("font_size", 11)
	logb.tooltip_text = "把当前各栏真实宽度写进 .editor_notes.log（排查用）"
	logb.pressed.connect(func() -> void: _log_layout("手动"))
	bar.add_child(logb)
	# 布局行也做最小宽度隔离：窄窗口下它不会把整页撑宽（内容超宽时本行内滚动）
	var bar_scroll := ScrollContainer.new()
	bar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bar_scroll.add_child(bar)
	bar_scroll.resized.connect(func() -> void:
		bar.position = Vector2.ZERO
		bar.size = Vector2(maxf(bar.get_combined_minimum_size().x, bar_scroll.size.x), bar_scroll.size.y))
	return _wrap_scroll_no_min(bar_scroll, 32.0)

## 自绘拖动把手（10px 宽，三个点做可视抓手；光标为左右箭头）
func _build_drag_handle(idx: int) -> Control:
	var h := Control.new()
	h.custom_minimum_size = Vector2(10, 0)
	h.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h.mouse_filter = Control.MOUSE_FILTER_STOP
	h.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	h.tooltip_text = "拖动我调整左右栏宽度（等价于上面的数值框）"
	h.draw.connect(func() -> void:
		var c := Color(0.55, 0.62, 0.72)
		var cx := h.size.x * 0.5
		var cy := h.size.y * 0.5
		for i in range(-1, 2):
			h.draw_circle(Vector2(cx, cy + float(i) * 7.0), 1.8, c))
	h.gui_input.connect(func(e: InputEvent) -> void: _on_handle_input(idx, e, h))
	return h

## 把手按下：开始拖拽捕获（记住锚点世界坐标，之后用**绝对位置**算增量）
func _on_handle_input(idx: int, e: InputEvent, h: Control) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_dragging_handle = idx
			_drag_anchor_x = mb.global_position.x
			_drag_start_lib = layout_lib_ratio
			_drag_start_insp = layout_insp_ratio
			h.accept_event()

## 拖拽捕获：**在面板的 _input 里**处理后续移动。
## 为什么不能只在把手的 gui_input 里做（第 41 轮踩到的坑）：
##   Godot 只把鼠标移动事件发给"光标下那个控件" ✗ —— 光标一旦离开 10px 宽的把手，
##   后续移动就给了别的控件，于是拖动只生效了最初几像素（实测 540→520 ✗）。
## 正确做法：按下时记锚点，之后在 _input 里用**绝对坐标差**重算比例（一次大跳也能全额生效）。
func _input(event: InputEvent) -> void:
	if _dragging_handle < 0:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_drag_to(mm.global_position.x)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_dragging_handle = -1
			_log_layout("把手松手")

func _drag_to(global_x: float) -> void:
	var w := maxf(size.x, 1.0)
	var dx := global_x - _drag_anchor_x
	if _dragging_handle == 0:
		layout_lib_ratio = clampf(_drag_start_lib + dx / w, 0.05, 0.45)
	else:
		layout_insp_ratio = clampf(_drag_start_insp - dx / w, 0.06, 0.55)
	_apply_layout_ratios()

## 拖动把手改比例：左把手往右拖 = 素材库变宽；右把手往左拖 = 属性栏变宽
func _drag_layout(idx: int, dx: float) -> void:
	var w := maxf(size.x, 1.0)
	if idx == 0:
		layout_lib_ratio = clampf(layout_lib_ratio + dx / w, 0.05, 0.45)
	else:
		layout_insp_ratio = clampf(layout_insp_ratio - dx / w, 0.06, 0.55)
	_apply_layout_ratios()

# ============================================================================
# 素材库（剪映左栏）：过场列表 + 可插入的素材
# ----------------------------------------------------------------------------
# 剪映是从左栏把素材拖到时间线；这里等价物是"**点一下 = 在播放头插一个关键帧**"
# （拖拽放进时间线的交互等布局稳定后再加）。插入逻辑一律走 EditorCutsceneDoc，
# 因此天然可撤销、可保存、可被游戏读回。
# ============================================================================
func _build_library() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(190, 0)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	scroll.add_child(box)

	box.add_child(_section("过场列表（点击载入）"))
	_cutscene_list = VBoxContainer.new()
	_cutscene_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_cutscene_list)

	box.add_child(_section("素材（点击插到播放头）"))
	var hint := Label.new()
	hint.text = "等价于剪映把素材拖进时间线"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.60, 0.66, 0.74))
	box.add_child(hint)
	_lib_button(box, "🎬 镜头关键帧（当前镜头）", func() -> void: _lib_insert(&"camera"))
	_lib_button(box, "🧍 角色·player 关键帧（当前位置）", func() -> void: _lib_insert(&"actor"))
	_lib_button(box, "✨ 特效关键帧（sfx=door）", func() -> void: _lib_insert(&"effect"))
	_lib_button(box, "💬 字幕关键帧（空文本）", func() -> void: _lib_insert(&"text"))
	_lib_button(box, "👾 生成关键帧（放一只怪）", func() -> void: _lib_insert(&"spawn"))
	return panel

func _lib_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

## 刷新左栏"过场列表"
func _refresh_library_list() -> void:
	if _cutscene_list == null:
		return
	for c in _cutscene_list.get_children():
		c.queue_free()
	for raw: Variant in EditorCutsceneDoc.available_ids():
		var id := StringName(str(raw))
		var b := Button.new()
		var mark := "●" if (doc != null and doc.data != null and doc.data.id == id) else "○"
		var dirty := "（未保存）" if (doc != null and doc.data != null and doc.data.id == id and doc.is_dirty()) else ""
		b.text = "%s %s%s" % [mark, String(id), dirty]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(func() -> void: _load_cutscene(id))
		_cutscene_list.add_child(b)

## 素材点一下 = 在播放头插一个关键帧（没有该轨道就建）
func _lib_insert(kind: StringName) -> void:
	if doc == null:
		_set_status("先选一段过场", true)
		return
	var ti := -1
	for i in doc.track_count():
		if StringName(str(doc.track(i).get("kind", ""))) == kind:
			ti = i
			break
	if ti < 0:
		ti = doc.add_track(kind)
	var t := timeline.playhead
	var values := {}
	var state: Dictionary = {}
	if preview != null:
		state = preview.sampled_state(t)
	match kind:
		&"camera":
			var cam: Dictionary = state.get("camera", {})
			# 优先用"预览里拖出来的镜头"（未打点的那份），否则用采样值
			if preview != null and preview.has_camera_edit():
				cam = preview.current_camera()
			values = {
				"x": float(cam.get("x", 0.0)), "y": float(cam.get("y", 0.0)),
				"zoom": float(cam.get("zoom", 1.0)),
			}
		&"actor":
			var a: Dictionary = state.get("actor", {})
			values = {
				"x": float(a.get("x", 32.0)), "y": float(a.get("y", 174.0)),
				"facing": float(a.get("facing", 1.0)),
			}
		&"effect":
			var fx: Dictionary = state.get("effect", {})
			values = {"sfx": str(fx.get("sfx", "door"))}
		&"text":
			values = {"text": "（在这里写字幕）"}
		&"spawn":
			# 生成/销毁实体（第 46 轮）：默认在镜头位置放一只爬行者
			var cam2: Dictionary = state.get("camera", {})
			values = {
				"type": "crawler",
				"x": float(cam2.get("x", 200.0)), "y": float(cam2.get("y", 160.0)),
				"count": 1, "action": "spawn",
			}
		_:
			values = {}
	var k := doc.add_key(ti, t, values)
	_after_edit("素材插入：%s 关键帧 @ %.2fs（第 %d 帧）" % [
		String(Cutscene.TRACK_KINDS.get(kind, {}).get("label", String(kind))), t, k + 1])
	if timeline != null:
		timeline.queue_redraw()

## 默认工作区（剪映版式）：按**当前尺寸 × 比例**分配，而不是写死像素。
## 关键修复（第 41 轮）：`_build_ui()` 里面板 size 还是 0，算出来的偏移会是垃圾值
## → 分隔条一开始就贴在最小尺寸上没有余量 → "拖不动"。所以尺寸未就绪时直接跳过，
## 等 `resized` 触发（打开页面/改窗口）再算。
func _apply_default_layout() -> void:
	# 「默认布局」才强制两栏可见；按比例的日常重排**不许**动可见性（否则收起按钮会被撤销）
	if _library_panel != null:
		_library_panel.visible = true
	if _inspector_panel != null:
		_inspector_panel.visible = true
	if _lib_btn != null:
		_lib_btn.button_pressed = false
	if _insp_btn != null:
		_insp_btn.button_pressed = false
	_apply_layout_ratios()

func _apply_layout_ratios() -> void:
	var w := size.x
	var h := size.y
	if h < 140.0 or w < 520.0:
		return                      # 还没排版：等 resized
	var slack := 40.0
	# 上下：上排 / 时间线（VSplitContainer 的 split_offset = 第一栏高度）
	if _main_split != null and _top_row != null:
		_main_split.split_offset = int(clampf(h * layout_top_ratio, 150.0, maxf(h - 140.0, 150.0)))
	# 左右：**精确宽度**
	#   素材库 / 属性检查器 = custom_minimum_size.x（SIZE_FILL，不抢剩余）
	#   播放器 = SIZE_EXPAND_FILL（吃掉剩余宽度）→ 改宽度一定生效，不依赖 SplitContainer
	var ins_px := 0.0
	if _inspector_panel != null and _inspector_panel.visible:
		ins_px = clampf(w * layout_insp_ratio, INSP_MIN_W, maxf(w * 0.55, INSP_MIN_W + 20.0))
	if _library_panel != null and _library_panel.visible:
		var lib_max := maxf(w - ins_px - (preview.custom_minimum_size.x + slack) - 40.0, LIB_MIN_W)
		var lib_px := clampf(w * layout_lib_ratio, LIB_MIN_W, lib_max)
		_library_panel.custom_minimum_size.x = lib_px
	if _inspector_panel != null:
		_inspector_panel.custom_minimum_size.x = ins_px if _inspector_panel.visible else 0.0
	_sync_layout_spins()

## 用户拖过上下分隔条 → 记住比例（左右两栏现在是精确宽度，不走拖拽）
func _on_split_dragged(_offset: int) -> void:
	var h := size.y
	if h > 1.0 and _main_split != null:
		layout_top_ratio = clampf(float(_main_split.split_offset) / h, 0.25, 0.88)
	_log_layout("拖动后")          # 真机诊断：写进 .editor_notes.log，便于远程核对

## 布局诊断：把面板/三栏/上下分栏的真实数值写进统一日志。
## 为什么需要它：编辑器插件里没有"看运行期变量"的通道，而日志文件是我能读到的唯一窗口；
## 上一轮"拖不动/改不动"就是靠这种诊断行定位的（面板尺寸=最小尺寸 → 没有余量；写了硬上限 → 改大无效）。
func _log_layout(why: String) -> void:
	var lib_w := _library_panel.size.x if _library_panel != null else -1.0
	var pv_w := preview.size.x if preview != null else -1.0
	var ins_w := _inspector_panel.size.x if _inspector_panel != null else -1.0
	EditorLog.note("布局[%s]：面板 %d×%d ｜ 素材库 %d(可见 %s,目标 %d) ｜ 播放器 %d ｜ 属性 %d(可见 %s,目标 %d) ｜ 上排高 %d ｜ 比例 %.2f/%.2f/%.2f" % [
		why, int(size.x), int(size.y), int(lib_w),
		str(_library_panel.visible if _library_panel != null else false),
		int(_library_panel.custom_minimum_size.x if _library_panel != null else 0),
		int(pv_w), int(ins_w),
		str(_inspector_panel.visible if _inspector_panel != null else false),
		int(_inspector_panel.custom_minimum_size.x if _inspector_panel != null else 0),
		int(_main_split.split_offset if _main_split != null else 0),
		layout_top_ratio, layout_lib_ratio, layout_insp_ratio], false, "过场")

## ══════════════════════════════════════════════════════════════════════════
## ① 面板 dock 化（第 45 轮）：把左/右两栏交给编辑器的 `add_control_to_dock()`
## ----------------------------------------------------------------------------
## 为什么这样做：注册成**真正的编辑器侧栏面板**后，白拿编辑器原生能力 ——
##   拖拽停靠（换到左/右侧栏）、浮动成独立窗口、与其它面板合并成标签、
##   从"编辑器 → 视图"里显示/隐藏；这些都是引擎给的，比自绘一套停靠系统可靠得多。
## 页面里则只剩"播放器 + 时间线"（播放器自动占满整宽 ✓）。
## 注意：dock 的宽度由侧栏决定，所以两个"宽"数值框在 dock 模式下禁用；
##       `◧素材库 / 属性◨` 按钮改为显示/隐藏对应 dock ✓。
## ══════════════════════════════════════════════════════════════════════════
func take_dock_panels() -> Array:
	if _dock_mode or _library_panel == null or _inspector_panel == null:
		return []
	_lib_dock = _library_panel
	_insp_dock = _inspector_panel
	_top_row.remove_child(_lib_dock)          # 摘出来（不释放）：交给插件去停靠
	_top_row.remove_child(_insp_dock)
	_library_panel = null
	_inspector_panel = null
	# 左右把手随两栏一起收掉（页面里没东西可拖了）
	for h: Control in [_handle_l, _handle_r]:
		if h != null:
			_top_row.remove_child(h)
			h.queue_free()
	_handle_l = null
	_handle_r = null
	_dock_mode = true
	if _lib_spin != null:
		_lib_spin.editable = false
		_lib_spin.tooltip_text = "已停靠到编辑器侧栏：宽度由侧栏决定（拖侧栏分隔条调整）"
	if _insp_spin != null:
		_insp_spin.editable = false
		_insp_spin.tooltip_text = "已停靠到编辑器侧栏：宽度由侧栏决定（拖侧栏分隔条调整）"
	if _lib_btn != null:
		_lib_btn.tooltip_text = "显示/隐藏已停靠的素材库面板（也可在编辑器「视图」里切换）"
	if _insp_btn != null:
		_insp_btn.tooltip_text = "显示/隐藏已停靠的属性面板（也可在编辑器「视图」里切换）"
	_apply_layout_ratios()
	_set_status("素材库 / 属性检查器已停靠到编辑器侧栏（可拖动、可浮动、可合并标签）", false)
	return [_lib_dock, _insp_dock]

## 收起/展开的目标：页面内那份，或已停靠的那份
func _panel_target(inpage: PanelContainer, dock: Control) -> Control:
	return inpage if inpage != null else dock

## 一键收起/展开：拖不动时的保底手段（也便于快速腾出空间看画面）
func _toggle_library() -> void:
	var target := _panel_target(_library_panel, _lib_dock)
	if target == null:
		return
	target.visible = not target.visible
	if not target.visible:
		layout_lib_ratio = 0.05
	_apply_layout_ratios()
	_sync_layout_spins()
	_set_status("素材库：%s" % ("显示" if target.visible else "已收起"), false)

func _toggle_inspector() -> void:
	var target := _panel_target(_inspector_panel, _insp_dock)
	if target == null:
		return
	target.visible = not target.visible
	if not target.visible:
		layout_insp_ratio = 0.08
	_apply_layout_ratios()
	_sync_layout_spins()
	_set_status("属性检查器：%s" % ("显示" if target.visible else "已收起"), false)

# ============================================================================
# 显式调整左右栏（第 41 轮，用户两次反馈"无法调整"后的主手段）
# ----------------------------------------------------------------------------
# 数值框/预设按钮 → 直接改比例并重排，**不依赖分隔条的鼠标抓取**。
# 由于数值框可能被程序改动（收起/预设），同步时要 `set_value_no_signal` 免得递归。
# ============================================================================
func _set_lib_width(px: int) -> void:
	if _library_panel == null:
		return
	if px <= 0:
		_library_panel.visible = false
		layout_lib_ratio = 0.05
	else:
		_library_panel.visible = true
		layout_lib_ratio = clampf(float(px) / maxf(size.x, 1.0), 0.05, 0.40)
	if _lib_btn != null:
		_lib_btn.button_pressed = not _library_panel.visible
	_apply_layout_ratios()
	_set_status("素材库宽度 → %d px" % int(_library_panel.size.x), false)

func _set_insp_width(px: int) -> void:
	if _inspector_panel == null:
		return
	if px <= 0:
		_inspector_panel.visible = false
		layout_insp_ratio = 0.08
	else:
		_inspector_panel.visible = true
		layout_insp_ratio = clampf(float(px) / maxf(size.x, 1.0), 0.08, 0.50)
	if _insp_btn != null:
		_insp_btn.button_pressed = not _inspector_panel.visible
	_apply_layout_ratios()
	_set_status("属性检查器宽度 → %d px" % int(_inspector_panel.size.x), false)

## 布局预设：按"素材库 : 播放器 : 属性"的权重分配宽度（0 权重 = 收起该栏）
func _apply_layout_preset(lib_w: float, play_w: float, insp_w: float) -> void:
	var total := lib_w + play_w + insp_w
	if total <= 0.0:
		return
	_library_panel.visible = lib_w > 0.0
	_inspector_panel.visible = insp_w > 0.0
	layout_lib_ratio = lib_w / total if lib_w > 0.0 else 0.05
	layout_insp_ratio = insp_w / total if insp_w > 0.0 else 0.08
	if _lib_btn != null:
		_lib_btn.button_pressed = not _library_panel.visible
	if _insp_btn != null:
		_insp_btn.button_pressed = not _inspector_panel.visible
	_apply_layout_ratios()
	_sync_layout_spins()
	_set_status("布局 %s：" % [str(lib_w) + ":" + str(play_w) + ":" + str(insp_w)], false)
	_log_layout("预设 %s:%s:%s" % [str(lib_w), str(play_w), str(insp_w)])

## 播放器窗口高度（第 43 轮）：上下分隔条 vs 数值框，两条路都能改
func _set_preview_height(px: int) -> void:
	if size.y < 140.0 or _main_split == null:
		return
	layout_top_ratio = clampf(float(px) / size.y, 0.25, 0.90)
	_apply_layout_ratios()
	_set_status("播放器窗口高度 → %d px（时间线占其余高度）" % int(_main_split.split_offset), false)

## 把当前实际宽度写回数值框（不触发信号，免得递归）
func _sync_layout_spins() -> void:
	if _lib_spin != null and _library_panel != null:
		_lib_spin.set_value_no_signal(float(int(_library_panel.size.x)) if _library_panel.visible else 0.0)
	if _insp_spin != null and _inspector_panel != null:
		_insp_spin.set_value_no_signal(float(int(_inspector_panel.size.x)) if _inspector_panel.visible else 0.0)
	if _pre_spin != null and _main_split != null:
		_pre_spin.set_value_no_signal(float(int(_main_split.split_offset)))

func _build_toolbar() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 34)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	scroll.add_child(bar)

	var title := Label.new()
	title.text = "过场动画（关键帧时间轴）"
	title.add_theme_font_size_override("font_size", 14)
	bar.add_child(title)
	bar.add_child(VSeparator.new())

	_picker = OptionButton.new()
	_picker.custom_minimum_size = Vector2(150, 0)
	_picker.item_selected.connect(func(idx: int) -> void:
		_load_cutscene(StringName(_picker.get_item_text(idx))))
	bar.add_child(_picker)

	_button(bar, "新建", _on_new)
	bar.add_child(VSeparator.new())
	_duration_spin = SpinBox.new()
	_duration_spin.min_value = 0.2
	_duration_spin.max_value = 120.0
	_duration_spin.step = 0.1
	_duration_spin.tooltip_text = "过场总时长（秒）"
	_duration_spin.value_changed.connect(func(v: float) -> void:
		if doc != null and doc.set_duration(v):
			_after_edit("时长改为 %.1fs" % v))
	bar.add_child(_duration_spin)

	_play_btn = _button(bar, "播放", _toggle_play)
	_button(bar, "回到开头", func() -> void:
		if timeline != null:
			timeline.playhead = 0.0
			timeline.queue_redraw()
			_refresh_inspector())
	_button(bar, "适应视图", func() -> void:
		if timeline != null:
			timeline.fit_view())
	bar.add_child(VSeparator.new())
	_button(bar, "撤销", _on_undo)
	_button(bar, "重做", _on_redo)
	_button(bar, "校验", _on_validate)
	_button(bar, "保存", _on_save)
	_button(bar, "重新载入", _on_reload)
	bar.add_child(VSeparator.new())
	_button(bar, "在播放头打点", _on_stamp)
	_button(bar, "导入实时录制", _on_import_recording)
	# 注意：**布局相关控件不放在这里**。这条工具条是横向 ScrollContainer，
	# 控件多了就会被挤出可视区（用户根本看不到 = "屁用没有"）。
	# 布局控件统一放在 `_build_layout_bar()` 那条**常驻可见**的行里。
	# 第 44 轮：再用"裁剪宿主"隔离它的最小宽度，防止整页被撑得比窗口还宽 ✗
	return _wrap_scroll_no_min(scroll, 62.0)

func _button(bar: HBoxContainer, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	bar.add_child(b)
	return b

# ============================================================================
# 载入 / 新建
# ============================================================================
func _refresh_picker() -> void:
	# 顶部下拉与左栏"过场列表"是同一份数据的两种呈现，一起刷新
	_refresh_library_list()
	if _picker == null:
		return
	_picker.clear()
	for id: Variant in EditorCutsceneDoc.available_ids():
		_picker.add_item(String(id))
	if doc != null:
		var idx := _picker.get_item_index(_picker.get_item_count() - 1)
		for i in _picker.item_count:
			if _picker.get_item_text(i) == String(doc.data.id):
				idx = i
				break
		_picker.selected = idx

func _load_cutscene(id: StringName) -> void:
	if doc != null and doc.is_dirty():
		_dialog.dialog_text = "「%s」还有未保存的修改，请先保存或用「重新载入」放弃。" % String(doc.data.id)
		_dialog.popup_centered()
		return
	doc = EditorCutsceneDoc.load_doc(id)
	if doc == null:
		_set_status("载入失败：%s" % String(id), true)
		return
	_stop_play()
	timeline.set_doc(doc)
	timeline.fit_view()
	_sync_preview_on_new_doc()
	if _duration_spin != null:
		_duration_spin.set_value_no_signal(doc.duration())
	_refresh_picker()
	_refresh_inspector()
	_set_status("已载入 %s ｜ %s" % [String(id), doc.summary()], false)

## 换了文档后同步监视器：重新推断房间 + 立刻画当前播放头那一帧。
## （载入已有过场、新建过场两条路径都要走，抽出来避免只改一处）
func _sync_preview_on_new_doc() -> void:
	if preview == null:
		return
	preview.setup(doc)
	preview.set_time(timeline.playhead)
	preview.set_playing(_playing)

func _on_new() -> void:
	var id := "new_cutscene"
	var n := 1
	while EditorCutsceneDoc.available_ids().has(id):
		n += 1
		id = "new_cutscene%d" % n
	doc = EditorCutsceneDoc.create_doc(StringName(id))
	_stop_play()
	timeline.set_doc(doc)
	timeline.fit_view()
	_sync_preview_on_new_doc()
	if _duration_spin != null:
		_duration_spin.set_value_no_signal(doc.duration())
	_refresh_inspector()
	_set_status("已新建 %s（保存后才会真正写盘）" % id, false)

# ============================================================================
# 检查器
# ============================================================================
func _refresh_inspector() -> void:
	for c in _inspector.get_children():
		c.queue_free()
	if doc == null:
		return

	# ---- 概览 ----
	_inspector.add_child(_section("过场"))
	_inspector.add_child(_text_field("名称", doc.data.name, func(v: String) -> void:
		if doc.set_name(v):
			_refresh_status()))
	_inspector.add_child(_label("id：%s" % String(doc.data.id)))
	_inspector.add_child(_label(doc.summary()))

	# ---- 轨道 ----
	_inspector.add_child(_section("轨道（点时间轴左侧选中）"))
	var add_row := HBoxContainer.new()
	var kind_pick := OptionButton.new()
	var kinds: Array = Cutscene.TRACK_KINDS.keys()
	for k: Variant in kinds:
		kind_pick.add_item("%s（%s）" % [str(Cutscene.TRACK_KINDS[k]["label"]), str(k)])
	kind_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(kind_pick)
	var add_btn := Button.new()
	add_btn.text = "加轨道"
	add_btn.pressed.connect(func() -> void:
		var idx := doc.add_track(StringName(str(kinds[kind_pick.selected])))
		if idx >= 0:
			timeline.selected_track = idx
			timeline.selected_key = -1
			_after_edit("已加一条轨道"))
	add_row.add_child(add_btn)
	_inspector.add_child(add_row)

	var ti := timeline.selected_track
	# tr 提到函数作用域：下面"轨道"与"关键帧"两个分支都要用它
	# （早期写在 if 里，导致关键帧分支里 tr 越界、编译器把未知标识符判成 Callable）
	var tr := doc.track(ti)
	if ti >= 0 and ti < doc.track_count():
		_inspector.add_child(_label("选中轨道[%d]：%s%s" % [ti, str(tr.get("kind", "")),
			"" if str(tr.get("target", "")) == "" else " · %s" % str(tr["target"])]))
		if StringName(str(tr.get("kind", ""))) == &"actor":
			_inspector.add_child(_text_field("  target", str(tr.get("target", "player")), func(v: String) -> void:
				if doc.set_track_field(ti, "target", v):
					_after_edit("角色目标改为 %s" % v)))
		var del_track := Button.new()
		del_track.text = "删除该轨道"
		del_track.pressed.connect(func() -> void:
			if doc.remove_track(ti):
				timeline.selected_track = -1
				timeline.selected_key = -1
				_after_edit("已删除轨道"))
		_inspector.add_child(del_track)
	else:
		_inspector.add_child(_label("（没有选中轨道）"))

	# ---- 关键帧 ----
	_inspector.add_child(_section("关键帧（点时间轴上的菱形选中）"))
	var ki := timeline.selected_key
	if ti >= 0 and ki >= 0 and ki < doc.keys(ti).size():
		var kd := doc.key(ti, ki)
		_inspector.add_child(_label("t = %.2fs（可拖动菱形改时间）" % float(kd.get("t", 0.0))))
		_inspector.add_child(_float_field("  t", float(kd.get("t", 0.0)), 0.0, doc.duration(),
			func(v: float) -> void:
				var new_i := doc.move_key(ti, ki, v)
				timeline.selected_key = new_i
				_after_edit("关键帧时间改为 %.2fs" % v)))
		var kind := StringName(str(tr.get("kind", "")))
		# 注意：不能写 Cutscene.TRACK_KINDS.get(kind, {}).get("fields", []) ——
		# 链式 get() 在静态分析里会被判成对 Callable 取成员（实测编译报错），
		# 因此先取到显式 Dictionary 再取字段。
		var kind_entry: Dictionary = Cutscene.TRACK_KINDS.get(kind, {})
		for field: Variant in kind_entry.get("fields", []):
			var f := str(field)
			_inspector.add_child(_key_field(ti, ki, f, kd))
		# 缓动
		var ease_pick := OptionButton.new()
		for e: Variant in Cutscene.EASINGS:
			ease_pick.add_item(str(e))
		ease_pick.selected = maxi(Cutscene.EASINGS.find(str(kd.get("ease", "linear"))), 0)
		var ease_row := HBoxContainer.new()
		var el := Label.new()
		el.text = "  ease"
		el.custom_minimum_size = Vector2(72, 0)
		ease_row.add_child(el)
		ease_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ease_pick.item_selected.connect(func(idx: int) -> void:
			if doc.set_key_field(ti, ki, "ease", Cutscene.EASINGS[idx]):
				_after_edit("缓动改为 %s" % Cutscene.EASINGS[idx]))
		ease_row.add_child(ease_pick)
		_inspector.add_child(ease_row)

		var del_key := Button.new()
		del_key.text = "删除该关键帧"
		del_key.pressed.connect(func() -> void:
			if doc.remove_key(ti, ki):
				timeline.selected_key = -1
				_after_edit("已删除关键帧"))
		_inspector.add_child(del_key)
	else:
		_inspector.add_child(_label("（没有选中关键帧；先把播放头拖到某时刻，再点「在播放头打点」）"))

	# ---- 播放头处的采样读数（手动打点的参照）----
	_inspector.add_child(_section("播放头 %.2fs 处的采样" % timeline.playhead))
	for i in doc.track_count():
		var tr2 := doc.track(i)
		var kind2 := StringName(str(tr2.get("kind", "")))
		var values := Cutscene.sample_track(tr2, timeline.playhead)
		var kind_entry2: Dictionary = Cutscene.TRACK_KINDS.get(kind2, {})
		_inspector.add_child(_label("%s%s → %s" % [
			str(kind_entry2.get("label", str(kind2))),
			"" if str(tr2.get("target", "")) == "" else "·%s" % str(tr2["target"]),
			str(values),
		]))

func _key_field(ti: int, ki: int, field: String, kd: Dictionary) -> Control:
	var kind := StringName(str(doc.track(ti).get("kind", "")))
	var current: Variant = kd.get(field, null)
	match field:
		"visible":
			var cb := CheckBox.new()
			cb.text = field
			cb.button_pressed = bool(current) if current != null else true
			cb.toggled.connect(func(on: bool) -> void:
				if doc.set_key_field(ti, ki, field, on):
					_after_edit("%s = %s" % [field, str(on)]))
			return cb
		"facing":
			return _int_field("  " + field, int(current) if current != null else 1, -1, 1,
				func(v: int) -> void:
					if doc.set_key_field(ti, ki, field, v):
						_after_edit("%s = %d" % [field, v]))
		"sfx", "music", "text":
			return _text_field("  " + field, str(current) if current != null else "", func(v: String) -> void:
				if doc.set_key_field(ti, ki, field, v):
					_after_edit("%s 已改" % field))
		"dur":
			return _float_field("  " + field, float(current) if current != null else 1.5, 0.0, 60.0,
				func(v: float) -> void:
					if doc.set_key_field(ti, ki, field, v):
						_after_edit("字幕时长 %.2fs" % v))
		_:
			return _float_field("  " + field, float(current) if current != null else 0.0, -9999.0, 9999.0,
				func(v: float) -> void:
					if doc.set_key_field(ti, ki, field, v):
						_after_edit("%s = %.1f" % [field, v]))

# ============================================================================
# 时间轴交互
# ============================================================================
func _on_playhead_changed(time: float) -> void:
	_refresh_inspector_status_only(time)
	# 监视器必须跟着播放头实时刷新 —— 这是"所见即所编"的关键一步
	if preview != null:
		preview.set_time(time)

## 用户开始拖动播放头（刻度尺或红线）：先停播放，免得两套推进互相打架。
## 这也是"拖着红线看画面"能稳定工作的前提：擦洗期间只有鼠标在改 playhead。
func _on_scrub_began() -> void:
	if _playing:
		_stop_play()
	_set_status("擦洗播放头：拖动时监视器实时跟随（松手停住）", false)

# ============================================================================
# 剪映同款快捷键 + 默认布局（第 38 轮，依据剪映手册）
# ----------------------------------------------------------------------------
# 剪映：时间线缩放 = `-` / `+`（或 Ctrl+滚轮、右上角图标与滑块）；
#       **全局预览缩放 = Shift+Z**（把超出屏幕的素材一次性显示全）；
#       工作区可自定义，也能"恢复默认布局"。
# 注意：这些快捷键只在"过场动画"页可见时生效，且不抢占编辑器本体的键。
# ============================================================================
func _unhandled_key_input(event: InputEvent) -> void:
	if timeline == null or not is_visible_in_tree():
		return
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var k := event as InputEventKey
	if k.echo:
		return
	match k.keycode:
		KEY_MINUS, KEY_KP_SUBTRACT:
			timeline.zoom_step(false)
			_set_status("时间线缩放：%.0f px/秒（剪映：- / + 与 Ctrl+滚轮）" % timeline.px_per_sec, false)
			timeline.queue_redraw()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			timeline.zoom_step(true)
			_set_status("时间线缩放：%.0f px/秒（剪映：- / + 与 Ctrl+滚轮）" % timeline.px_per_sec, false)
			timeline.queue_redraw()
		KEY_Z:
			if k.shift_pressed:
				timeline.fit_global()
				_set_status("全局预览缩放：整段铺满可视宽度（%.0f px/秒）" % timeline.px_per_sec, false)
				timeline.queue_redraw()

## 恢复默认工作区（剪映"恢复默认布局"）：三栏 + 时间线回到初始分配
func _on_reset_layout() -> void:
	if preview != null and preview.is_collapsed():
		preview._toggle_collapse()
	_apply_default_layout()
	if timeline != null:
		timeline.fit_global()
		timeline.set_row_h(0.0)
		timeline.queue_redraw()
	_after_edit("已恢复默认布局（素材库/播放器/检查器 + 时间线，分隔条复位）")

# ============================================================================
# 预览里编辑镜头 → 打关键帧（第 39 轮，用户自定义的核心需求）
# ----------------------------------------------------------------------------
# 用户在播放器画面上拖动/滚轮改出想要的构图后点「打关键帧」：
#   · 没有 camera 轨道就建一条；
#   · **播放头 ±0.02s 已有帧就改它**（同一时刻不重复插帧，符合剪辑习惯）；
#   · 否则插新帧；
#   · 落数据后清掉预览的"未打点"状态，画面回到"数据驱动"。
# ============================================================================
func _on_preview_key(camera: Dictionary) -> void:
	if doc == null:
		_set_status("先选一段过场再打关键帧", true)
		return
	if camera.is_empty():
		_set_status("没有可打的镜头：先点『镜头编辑』在画面上拖/滚一下", true)
		return
	var ti := -1
	for i in doc.track_count():
		if StringName(str(doc.track(i).get("kind", ""))) == &"camera":
			ti = i
			break
	if ti < 0:
		ti = doc.add_track(&"camera")
	var t := timeline.playhead
	var ki := -1
	var ks := doc.keys(ti)
	for j in ks.size():
		if absf(float((ks[j] as Dictionary).get("t", 0.0)) - t) <= 0.02:
			ki = j
			break
	var cx := float(camera.get("x", 0.0))
	var cy := float(camera.get("y", 0.0))
	var cz := float(camera.get("zoom", 1.0))
	if ki >= 0:
		# 第 49 轮：x/y/zoom 一次性写入 → **只算一步撤销** ✓
		# （之前逐个 set_key_field 会写 3 步 ✗，按一次撤销只退回一个字段 ✗）
		var n := doc.set_key_fields(ti, ki, {"x": cx, "y": cy, "zoom": cz})
		_after_edit("%s %.2fs 的既有镜头帧：x=%.0f y=%.0f zoom=%.2f（一步撤销 · %d 个字段）" % [
			"改到" if n > 0 else "未变（已是该值）", t, cx, cy, cz, n])
	else:
		var k := doc.add_key(ti, t, {"x": cx, "y": cy, "zoom": cz})
		_after_edit("在 %.2fs 打了镜头关键帧：x=%.0f y=%.0f zoom=%.2f（第 %d 帧）" % [t, cx, cy, cz, k + 1])
	if timeline != null:
		timeline.queue_redraw()
	if preview != null:
		preview.clear_camera_edit()          # 已落数据 → 退出"未打点"状态
		preview.set_time(t)

## 全屏预览（剪映式）：收起左素材库与右属性检查器，把整屏让给播放器
func _on_preview_fullscreen(on: bool) -> void:
	if _library_panel != null:
		_library_panel.visible = not on
	if _inspector_panel != null:
		_inspector_panel.visible = not on
	if _main_split != null:
		_main_split.split_offset = maxi(int(size.y) - 170, 240) if on else maxi(int(size.y) - 250, 200)
	_set_status("全屏预览：%s（收起素材库与属性面板；再点一次退出）" % ("开" if on else "关"), false)

func _refresh_inspector_status_only(_t: float) -> void:
	# 播放头移动时只刷新"采样读数"那一节，避免每帧重建整个检查器（会打断输入焦点）
	if doc == null or _inspector == null:
		return
	_status.tooltip_text = "播放头 %.2fs / %.2fs" % [timeline.playhead, doc.duration()]

func _on_key_selected(track_i: int, _key_i: int) -> void:
	timeline.selected_track = track_i
	_refresh_inspector()

func _on_key_moved(track_i: int, key_i: int, new_time: float) -> void:
	if doc.move_key(track_i, key_i, new_time) >= 0:
		_refresh_status()
		timeline.queue_redraw()

# ============================================================================
# 播放（编辑器内预览：只推进播放头，真正的演出在游戏里）
# ============================================================================
func _toggle_play() -> void:
	if _playing:
		_stop_play()
		return
	if doc == null:
		return
	_playing = true
	if _play_btn != null:
		_play_btn.text = "暂停"
	if preview != null:
		preview.set_playing(true)

func _stop_play() -> void:
	_playing = false
	if _play_btn != null:
		_play_btn.text = "播放"
	if preview != null:
		preview.set_playing(false)

func _process(delta: float) -> void:
	if not _playing or doc == null or timeline == null:
		return
	timeline.playhead += delta
	if timeline.playhead >= doc.duration():
		timeline.playhead = doc.duration()
		_stop_play()
	timeline.queue_redraw()
	# 播放时同样要推监视器（_process 里直接改 playhead 不会触发 playhead_changed 信号）
	if preview != null:
		preview.set_time(timeline.playhead)

# ============================================================================
# 监视器传送控制（意图来自 preview 的信号，时钟仍在 timeline）
# ============================================================================
func _on_preview_seek(t: float) -> void:
	if doc == null or timeline == null:
		return
	timeline.playhead = clampf(t, 0.0, doc.duration())
	timeline.queue_redraw()
	if preview != null:
		preview.set_time(timeline.playhead)

## 跳关键帧：把四条轨道所有关键帧时间收成一个有序表，找上/下一个
func _on_preview_step(direction: int) -> void:
	if doc == null or timeline == null:
		return
	var times: Array[float] = []
	for i in doc.track_count():
		for k: Variant in doc.keys(i):
			times.append(float((k as Dictionary).get("t", 0.0)))
	if times.is_empty():
		return
	times.sort()
	var cur := timeline.playhead
	var target := cur
	if direction > 0:
		target = doc.duration()
		for t in times:
			if t > cur + 0.001:
				target = t
				break
	else:
		target = 0.0
		for i in range(times.size() - 1, -1, -1):
			if times[i] < cur - 0.001:
				target = times[i]
				break
	_on_preview_seek(target)
	_set_status("跳到 %.2fs（%s）" % [target, "下一关键帧" if direction > 0 else "上一关键帧"], false)

# ============================================================================
# 录制
# ============================================================================
## 手动打点：在播放头处按当前采样值插一帧（之后可在右侧逐个字段微调）
func _on_stamp() -> void:
	if doc == null:
		_set_status("先选一段过场", true)
		return
	var ti := timeline.selected_track
	if ti < 0:
		_set_status("先在时间轴上选中一条轨道", true)
		return
	var values := Cutscene.sample_track(doc.track(ti), timeline.playhead)
	if values.is_empty():
		# 空轨道：按字段表放一个零值，避免打出空帧
		var kind := StringName(str(doc.track(ti).get("kind", "")))
		var kind_entry3: Dictionary = Cutscene.TRACK_KINDS.get(kind, {})
		for field: Variant in kind_entry3.get("fields", []):
			values[str(field)] = 0.0
	var ki := doc.add_key(ti, timeline.playhead, values)
	if ki < 0:
		_set_status("打点失败（轨道无效）", true)
		return
	timeline.selected_key = ki
	_after_edit("已在 %.2fs 打点（%s）" % [timeline.playhead, str(values)])

## 实时录制导入：读游戏里 F6 录下的采样 → 生成/覆盖该目标的 actor 轨道
func _on_import_recording() -> void:
	if doc == null:
		_set_status("先选一段过场", true)
		return
	var samples := EditorCutsceneDoc.read_recording(_recording_path)
	if samples.is_empty():
		_set_status("没有找到录制数据（%s）：在游戏里按 F6 开始/结束录制" % _recording_path, true)
		return
	var n := doc.stamp_from_samples(samples, 0.1, "player")
	timeline.fit_view()
	if _duration_spin != null:
		_duration_spin.set_value_no_signal(doc.duration())
	_after_edit("已导入 %d 个采样点 → actor·player 轨道（%d 帧）" % [samples.size(), n])

# ============================================================================
# 保存 / 撤销 / 状态
# ============================================================================
func _on_undo() -> void:
	if doc != null and doc.undo():
		_after_edit("已撤销")

func _on_redo() -> void:
	if doc != null and doc.redo():
		_after_edit("已重做")

func _on_validate() -> void:
	if doc == null:
		return
	var errors := doc.validate()
	var dry := doc.dry_run()
	_refresh_status()
	if errors.is_empty() and dry.is_empty():
		_set_status("校验通过：%s" % doc.summary(), false)
	else:
		_set_status("校验发现 %d + %d 个问题（见下方）" % [errors.size(), dry.size()], true)

func _on_save() -> void:
	if doc == null:
		return
	var res := doc.save()
	if bool(res["ok"]):
		_set_status("已保存 %s" % str(res["paths"][0]), false)
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
		_refresh_picker()
	else:
		_set_status("保存被拒绝：" + "\n".join(res["errors"]), true)

func _on_reload() -> void:
	if doc == null:
		return
	var id := doc.data.id
	doc = EditorCutsceneDoc.load_doc(id)
	if doc == null:
		_set_status("重新载入失败：%s" % String(id), true)
		return
	_stop_play()
	timeline.set_doc(doc)
	timeline.fit_view()
	_refresh_inspector()
	_set_status("已从磁盘重新载入 %s" % String(id), false)

func _after_edit(note: String) -> void:
	timeline.queue_redraw()
	_refresh_inspector()
	_refresh_library_list()        # 左栏要显示"●当前 / （未保存）"标记
	_set_status(note, false)

func _refresh_status() -> void:
	if doc == null:
		return
	_set_status("%s%s" % [doc.summary(), "（未保存 ●）" if doc.is_dirty() else ""], false)

func _set_status(text: String, is_error: bool) -> void:
	if _status != null:
		_status.text = text
		_status.add_theme_color_override("font_color",
			Color(1.0, 0.7, 0.7) if is_error else Color(0.85, 0.9, 0.95))
	EditorLog.note(text, is_error, "过场")

# ============================================================================
# 小组件
# ============================================================================
func _section(title: String) -> Control:
	var l := Label.new()
	l.text = "—— %s ——" % title
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	return l

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _text_field(label: String, value: String, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(72, 0)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(v: String) -> void: on_change.call(v))
	edit.focus_exited.connect(func() -> void: on_change.call(edit.text))
	row.add_child(edit)
	return row

func _float_field(label: String, value: float, lo: float, hi: float, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(72, 0)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = 0.1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(v: float) -> void: on_change.call(v))
	row.add_child(spin)
	return row

func _int_field(label: String, value: int, lo: int, hi: int, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(72, 0)
	l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = 1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(v: float) -> void: on_change.call(int(v)))
	row.add_child(spin)
	return row
