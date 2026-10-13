@tool
class_name EditorCutscenePreview
extends VBoxContainer
## ============================================================================
## EditorCutscenePreview —— 过场动画「画面预览监视器」
## ----------------------------------------------------------------------------
## 为什么要有它（用户反馈）：之前「过场动画」页只有一条完整的时间轴 —— **没有画面**，
## 编过场等于盲编：看不到"镜头此刻取到什么景、角色站在哪、字幕什么时候压上来"。
## 参考商业剪辑软件（剪映等），监视器必须在**时间轴正上方**，播放头一动画面就跟着动。
##
## ============================================================================
## 第 39 轮（用户确认的需求，照剪映）
## ----------------------------------------------------------------------------
## 【① 在预览画面里直接改镜头 → 打关键帧】（用户自定义的核心需求）
##   剪映式的"所见即所得"：在播放器画面上**拖拽 = 平移镜头、滚轮 = 缩放镜头**，
##   画面立刻跟着变；满意后点「打关键帧」，把当前 x/y/zoom **写进 camera 轨道**的
##   播放头位置（同一时刻已有帧就改它，不重复插帧 → 一次操作 = 一个撤销点）。
##   实现要点：编辑态下**不再动 view_zoom/pan**（那是"看"，不是"改"），
##   而是维护 `cam_edit`（x/y/zoom 覆盖值），`base_view()` 优先用它。
##
## 【② 播放器（预览窗口）自身的控件】—— 手册明确"播放器缩放 ≠ 时间线缩放"
##   比例下拉（适应 / 25% / 50% / 100% / 200% / 400%）、全屏预览、背景（黑 / 棋盘格）、
##   安全框（90% 标题安全 + 80% 动作安全 + 中心十字）。
## ============================================================================

## 播放器比例档位（剪映：适应 + 若干百分比；这里 100% = 1 像素:1 像素的世界尺度）
const RATIO_PRESETS := [0.0, 0.25, 0.5, 1.0, 2.0, 4.0]
const RATIO_LABELS := ["适应", "25%", "50%", "100%", "200%", "400%"]
## 镜头编辑时的缩放范围（对应 camera.zoom）
const CAM_ZOOM_MIN := 0.25
const CAM_ZOOM_MAX := 8.0

## 镜头编辑：非空 = 有未打点的镜头改动（x/y/zoom）
var cam_edit: Dictionary = {}
## 是否处于"镜头编辑"模式（拖拽/滚轮改镜头而不是看画面）
var edit_mode := false
## 本轮（第 43 轮）默认 **true = 等比**：面板是"播放器窗口"，窗口**内部**才是 16:9 的画面
## ——用户明确要求"一个窗口，内部是动画预览，而不是窗口整个是动画预览" ✓
## 想要"画面铺满窗口、无黑边"时点标题栏按钮切到「铺满」即可。
var letterbox_ui := true
## 监视器标题栏按钮（第 42 轮：铺满 / 等比 一键切换）
var _lb_btn: Button = null
## 播放器比例（0 = 适应）
var view_ratio := 0.0
## 背景棋盘格 / 安全框
var checker_bg := false
var safe_frames := false
var _panning_cam := false

## 用户请求打关键帧（面板负责写进 EditorCutsceneDoc）
signal key_requested(camera: Dictionary)
## 用户切换全屏预览（面板负责收起/展开其它面板）
signal fullscreen_toggled(on: bool)

## ============================================================================
## 第 37 轮修的三件事（用户实测反馈）
## ----------------------------------------------------------------------------
## 【反馈 1】预览画面是"把原本画面强行拉伸的结果"
##   原因：`_draw_monitor()` 把"要显示的世界矩形"直接铺满整个可用区域，
##   **完全没有保持宽高比** —— 面板多宽多高，画面就被拉成什么形状。
##   修法：监视器本体变成一个**信封盒（letterbox）**：
##   `_layout_monitor()` 按目标宽高比（游戏视口 640×360，总览模式用房间宽高比）
##   在可用空间里算出最大的等比矩形，居中摆放，四周留黑边；监视器自己
##   `clip_contents = true`，于是任何越界绘制都被引擎裁掉（缩放后也不会溢出）。
##   纯函数 `fit_rect(avail, aspect)` 由 smoke_editor 断言：比例误差 <0.1%、
##   居中、且永不超过可用空间。
##
## 【反馈 2】缺少放大 / 缩小预览画面的能力
##   修法：加 `view_zoom`（0.25×~8×）+ `pan`（像素）：
##     · 滚轮在监视器上 = 以鼠标处为锚点缩放（鼠标下的世界点保持不动）；
##     · 中键拖动 = 平移；双击 = 复位到"适应"；
##     · 标题栏 `− 100% + 适应` 按钮，带百分比读数。
##   锚点不变量由 smoke_editor 断言：钉住鼠标点缩放后，该点对应的世界坐标不变。
##
## 【反馈 3】缺少调整工作区的能力
##   修法：面板改用 **VSplitContainer / HSplitContainer**（可拖拽分隔条），
##   并且监视器高度可折叠（标题栏「折叠」按钮）—— 编辑时间轴时能把它收起来。
##
## 它画什么（全部是**纯绘制**，不跑游戏、不碰运行期单例）：
##   1. 主画面 = 镜头此刻看到的东西：按 `Cutscene.sample_track()` 取相机 x/y/zoom，
##      换算"可见世界矩形"（视口 ÷ zoom），把房间地板/障碍/敌人/门/存档点铺上去；
##   2. 角色：采样位置 + 朝向箭头 + 整段走位轨迹折线；
##   3. 字幕：采样文本压在主画面底部（游戏同款底条）；
##   4. 特效：显示采样到的 sfx/music，贴近关键帧时高亮；
##   5. 右下角小窗：整房缩略图 + 镜头框（随时知道镜头在房间何处）。
##
## 数据来源与边界：
##   - 房间几何来自 `WorldDatabase`（core/level_data.gd，纯数据类）——编辑器插件
##     **不允许**碰 SceneRouter/SaveSystem/GameState/EventBus/AudioManager（有守卫），
##     WorldDatabase 不在此列；
##   - 过场数据本身**不带 room 字段**（相机坐标就是世界坐标），所以本组件会
##     自动推断"哪间房包含镜头中心"，并允许在标题栏用下拉手动指定。
##
## 与时间轴的分工：**时钟只有一个**（面板的 `timeline.playhead`）。
## 本组件不自己走时间，只提供 `seek_requested / play_requested / step_requested`
## 三个意图信号，由面板统一驱动 —— 避免两套时钟互相打架。
## ============================================================================

## 视口尺寸（游戏里是 640×360；编辑器里从项目设置读，读不到就用兜底值）
const FALLBACK_VIEW := Vector2(640.0, 360.0)
## 监视器四周留白（黑边之外的呼吸空间）
const FRAME_PAD := 6.0
## 缩放范围与步进
const ZOOM_MIN := 0.25
const ZOOM_MAX := 8.0
const ZOOM_STEP := 1.15
## 右下角"整房缩略图"占监视器宽度比例
const INSET_RATIO := 0.26
## 特效高亮窗口（秒）：播放头距特效关键帧这么近就高亮，方便对齐
const EFFECT_HIGHLIGHT := 0.15
## 监视器展开时的高度
const BODY_HEIGHT := 236.0

## 意图信号：由面板接住并统一驱动时间轴
signal seek_requested(time: float)
signal play_requested()
signal step_requested(direction: int)          # -1 上一关键帧 / +1 下一关键帧

## 房间几何（世界数据，只读）
var _db: WorldDatabase = null
var _db_tried := false
## 当前过场文档（只为采样）
var doc: EditorCutsceneDoc = null
## 手动指定的房间（空 = 自动推断）
var room_override: StringName = &""
## 当前时间（由面板 set_time 推入）
var _time := 0.0
## 预览缩放与平移（反馈 2）
var view_zoom := 1.0
var pan := Vector2.ZERO                        # 单位：监视器像素
var _panning := false
var _pan_last := Vector2.ZERO

## 标题栏第一行（取景 + 播放导航）
var _header: HBoxContainer = null
## 标题栏第二行（显示 + 镜头编辑）——第 48 轮 UI/UX 重排：拆两行，不再挤在一起 ✓
var _header2: HBoxContainer = null
var _room_pick: OptionButton = null
var _timecode: Label = null
var _follow_pick: OptionButton = null
var _zoom_label: Label = null
var _play_btn: Button = null
var _collapse_btn: Button = null
## 播放器自身控件（第 39 轮）
var _ratio_pick: OptionButton = null
var _bg_btn: Button = null
var _safe_btn: Button = null
var _fs_btn: Button = null
## 镜头编辑控件
var _edit_btn: Button = null
var _key_btn: Button = null
var _discard_btn: Button = null
var _body: Control = null                      # 黑底容器（撑满可用空间）
var _monitor: Control = null                   # 等比信封盒，clip_contents=true，实际画布
var _note: Label = null
var _collapsed := false

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build_ui()

# ============================================================================
# 界面骨架
# ============================================================================
func _build_ui() -> void:
	# ══════════════════════════════════════════════════════════════════════
	# 标题栏（第 48 轮做了一次 UI/UX 重排）
	# ----------------------------------------------------------------------
	# 问题（用户反馈）：顶部选项**挤在一行**（≈25 个控件）✗，看不清分组、点起来累。
	# 重排原则：
	#   ① **分两行**：第一行 = "在看什么 + 播放导航"；第二行 = "怎么显示 + 镜头编辑"；
	#   ② 每组之间用 `VSeparator` 隔开，并加**灰字小标题**（「显示」「镜头」）✓；
	#   ③ 同一行内统一间距（6px）+ 行距（4px），不再靠"挤"来省地方 ✓；
	#   ④ 每个控件都补 tooltip（含下拉框 ✓），鼠标停一下就知道是什么；
	#   ⑤ 仍然用"裁剪宿主 + 可滚动"包住两行：内容再宽也不会把整页撑宽 ✓
	#      （第 44 轮踩过的坑：撑宽 → 页面比窗口宽 → 画面中心跑到可视区外 ✗）。
	# ══════════════════════════════════════════════════════════════════════
	var header_host := Control.new()
	header_host.clip_contents = true
	header_host.custom_minimum_size = Vector2(0, 58)          # 两行的高度
	header_host.size_flags_horizontal = Control.SIZE_FILL
	header_host.tooltip_text = "预览窗口标题栏（两行：上=取景/播放，下=显示/镜头）"
	add_child(header_host)
	var header_scroll := ScrollContainer.new()
	header_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	header_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	header_host.add_child(header_scroll)
	var header_rows := VBoxContainer.new()
	header_rows.add_theme_constant_override("separation", 4)
	header_rows.size_flags_horizontal = Control.SIZE_FILL
	header_scroll.add_child(header_rows)
	# 宿主自己排版：内层滚动区永远填满宿主（绕开容器的最小尺寸传递）
	header_host.resized.connect(func() -> void:
		header_scroll.position = Vector2.ZERO
		header_scroll.size = header_host.size)
	header_scroll.resized.connect(func() -> void:
		header_rows.position = Vector2.ZERO
		header_rows.size = Vector2(maxf(header_rows.get_combined_minimum_size().x, header_scroll.size.x),
			header_scroll.size.y))

	# ── 第一行：取景（房间/取景方式）+ 缩放 + 播放导航 ──────────────────
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 6)
	row1.size_flags_horizontal = Control.SIZE_FILL
	header_rows.add_child(row1)
	_header = row1                                  # 兼容旧引用（对外接口没变 ✓）

	var title := Label.new()
	title.text = "画面预览"
	title.add_theme_font_size_override("font_size", 12)
	title.tooltip_text = "这里显示当前播放头时刻的过场画面（只预览，不改数据）"
	row1.add_child(title)

	row1.add_child(VSeparator.new())
	var room_label := Label.new()
	room_label.text = "房间"
	room_label.tooltip_text = "预览用哪一间房的几何（过场数据里写了舞台就用舞台 ✓）"
	row1.add_child(room_label)

	_room_pick = OptionButton.new()
	_room_pick.custom_minimum_size = Vector2(120, 0)
	_room_pick.tooltip_text = "选择预览背景房间"
	_room_pick.item_selected.connect(_on_room_picked)
	row1.add_child(_room_pick)

	_follow_pick = OptionButton.new()
	_follow_pick.add_item("跟随镜头")
	_follow_pick.add_item("整房总览")
	_follow_pick.custom_minimum_size = Vector2(98, 0)
	_follow_pick.tooltip_text = "跟随镜头 = 游戏视角；整房总览 = 看整间房"
	_follow_pick.item_selected.connect(func(_i: int) -> void:
		_reset_view()                       # 换取景方式 → 缩放/平移复位，免得看到一半的怪异构图
		_layout_monitor()
		_refresh_monitor())
	row1.add_child(_follow_pick)

	# ---- 缩放控制（反馈 2）----
	row1.add_child(VSeparator.new())
	var zoom_out := Button.new()
	zoom_out.text = "−"
	zoom_out.tooltip_text = "缩小预览（也可在画面上滚轮）"
	zoom_out.custom_minimum_size = Vector2(28, 0)
	zoom_out.pressed.connect(func() -> void: _zoom_at(1.0 / ZOOM_STEP, _monitor_center()))
	row1.add_child(zoom_out)
	_zoom_label = Label.new()
	_zoom_label.text = "100%"
	_zoom_label.custom_minimum_size = Vector2(46, 0)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_label.tooltip_text = "当前预览缩放（与时间线缩放是两回事 ✓）"
	row1.add_child(_zoom_label)
	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.tooltip_text = "放大预览（也可在画面上滚轮）"
	zoom_in.custom_minimum_size = Vector2(28, 0)
	zoom_in.pressed.connect(func() -> void: _zoom_at(ZOOM_STEP, _monitor_center()))
	row1.add_child(zoom_in)
	var zoom_fit := Button.new()
	zoom_fit.text = "适应"
	zoom_fit.tooltip_text = "复位缩放与平移（双击画面同效）"
	zoom_fit.pressed.connect(func() -> void: _reset_view())
	row1.add_child(zoom_fit)

	# ---- 播放导航 ----
	row1.add_child(VSeparator.new())
	var to_start := Button.new()
	to_start.text = "⏮"
	to_start.tooltip_text = "回到开头"
	to_start.pressed.connect(func() -> void: seek_requested.emit(0.0))
	row1.add_child(to_start)
	var prev := Button.new()
	prev.text = "◀|"
	prev.tooltip_text = "上一个关键帧"
	prev.pressed.connect(func() -> void: step_requested.emit(-1))
	row1.add_child(prev)
	_play_btn = Button.new()
	_play_btn.text = "▶ 播放"
	_play_btn.tooltip_text = "在监视器里预览整段过场（只动播放头，不改数据）"
	_play_btn.pressed.connect(func() -> void: play_requested.emit())
	row1.add_child(_play_btn)
	var next_btn := Button.new()
	next_btn.text = "|▶"
	next_btn.tooltip_text = "下一个关键帧"
	next_btn.pressed.connect(func() -> void: step_requested.emit(1))
	row1.add_child(next_btn)

	_timecode = Label.new()
	_timecode.text = "0.00 / 0.00s"
	_timecode.add_theme_font_size_override("font_size", 12)
	_timecode.tooltip_text = "播放头时间 / 过场总时长"
	row1.add_child(_timecode)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(spacer)

	_collapse_btn = Button.new()
	_collapse_btn.text = "折叠"
	_collapse_btn.tooltip_text = "收起/展开预览画面（腾空间给时间线）"
	_collapse_btn.pressed.connect(_toggle_collapse)
	row1.add_child(_collapse_btn)

	# ── 第二行：显示（比例/背景/安全框/取景模式/全屏）+ 镜头编辑 ────────
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	row2.size_flags_horizontal = Control.SIZE_FILL
	header_rows.add_child(row2)
	_header2 = row2

	_hdr_caption(row2, "显示")
	_lb_btn = Button.new()
	_lb_btn.text = "等比"
	# ⚠ 顺序很重要（第 43 轮真机踩到）：必须先 toggle_mode 再设状态，且用
	# `set_pressed_no_signal`，否则那次赋值会触发 `toggled(false)` 把默认值改回「铺满」✗
	_lb_btn.toggle_mode = true
	_lb_btn.set_pressed_no_signal(letterbox_ui)
	_lb_btn.tooltip_text = "铺满：画面填满预览区、无黑边（横向会多看到一点世界）\n等比：与游戏 16:9 完全一致，面板更宽时左右留黑边"
	_lb_btn.toggled.connect(func(on: bool) -> void:
		letterbox_ui = on
		_lb_btn.text = "等比" if on else "铺满"
		_layout_monitor()
		if _monitor != null:
			_monitor.queue_redraw())
	row2.add_child(_lb_btn)

	var ratio_label := Label.new()
	ratio_label.text = "比例"
	ratio_label.tooltip_text = "播放器自身的缩放（只改怎么看，不改镜头数据 ✓）"
	row2.add_child(ratio_label)
	_ratio_pick = OptionButton.new()
	for lab: String in RATIO_LABELS:
		_ratio_pick.add_item(lab)
	_ratio_pick.custom_minimum_size = Vector2(76, 0)
	_ratio_pick.tooltip_text = "适应 / 25% / 50% / 100% / 200% / 400%"
	_ratio_pick.item_selected.connect(func(i: int) -> void:
		view_ratio = float(RATIO_PRESETS[clampi(i, 0, RATIO_PRESETS.size() - 1)])
		_layout_monitor()
		_refresh_monitor())
	row2.add_child(_ratio_pick)

	_bg_btn = Button.new()
	_bg_btn.text = "背景:黑"
	_bg_btn.tooltip_text = "切换预览背景（黑 / 棋盘格）"
	_bg_btn.pressed.connect(func() -> void:
		checker_bg = not checker_bg
		_bg_btn.text = "背景:棋盘" if checker_bg else "背景:黑"
		if _monitor != null:
			_monitor.queue_redraw())
	row2.add_child(_bg_btn)

	_safe_btn = Button.new()
	_safe_btn.text = "安全框"
	_safe_btn.toggle_mode = true
	_safe_btn.tooltip_text = "90% 标题安全 / 80% 动作安全 / 中心十字"
	_safe_btn.toggled.connect(func(on: bool) -> void:
		safe_frames = on
		if _monitor != null:
			_monitor.queue_redraw())
	row2.add_child(_safe_btn)

	_fs_btn = Button.new()
	_fs_btn.text = "全屏"
	_fs_btn.tooltip_text = "全屏预览（收起左侧素材与右侧属性，只留播放器+时间线）"
	_fs_btn.toggle_mode = true
	_fs_btn.toggled.connect(func(on: bool) -> void:
		_fs_btn.text = "退出全屏" if on else "全屏"
		fullscreen_toggled.emit(on))
	row2.add_child(_fs_btn)

	row2.add_child(VSeparator.new())
	# ---- 镜头编辑（第 39 轮②核心：拖/滚改镜头 → 打关键帧）----
	_hdr_caption(row2, "镜头")
	_edit_btn = Button.new()
	_edit_btn.text = "镜头编辑"
	_edit_btn.toggle_mode = true
	_edit_btn.tooltip_text = "打开后：在画面上拖动 = 平移镜头，滚轮 = 缩放镜头（满意后点『打关键帧』）"
	_edit_btn.toggled.connect(func(on: bool) -> void:
		if on:
			begin_camera_edit()
		else:
			edit_mode = false
			_refresh_monitor())
	row2.add_child(_edit_btn)

	_key_btn = Button.new()
	_key_btn.text = "打关键帧"
	_key_btn.tooltip_text = "把当前镜头（x/y/zoom）写进 camera 轨道的播放头位置（一步撤销 ✓）"
	_key_btn.pressed.connect(func() -> void: key_requested.emit(current_camera()))
	row2.add_child(_key_btn)

	_discard_btn = Button.new()
	_discard_btn.text = "放弃改动"
	_discard_btn.tooltip_text = "丢掉尚未打点的镜头改动，回到数据里的镜头"
	_discard_btn.pressed.connect(func() -> void: clear_camera_edit())
	row2.add_child(_discard_btn)

	var spacer2 := Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(spacer2)

	# ---- 黑底容器 + 等比信封盒监视器 ----
	# _body 撑满可用空间并画黑边（letterbox）；_monitor 是等比的真实画布，
	# 自己 clip_contents=true → 缩放后越界的内容由引擎裁掉，不会溢出到面板上。
	_body = Control.new()
	_body.custom_minimum_size = Vector2(0, BODY_HEIGHT)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.clip_contents = true
	_body.draw.connect(_draw_body)
	_body.resized.connect(_layout_monitor)
	add_child(_body)

	_monitor = Control.new()
	_monitor.mouse_filter = Control.MOUSE_FILTER_STOP      # 需要接收滚轮/中键拖动
	_monitor.clip_contents = true
	_monitor.draw.connect(_draw_monitor)
	_monitor.gui_input.connect(_on_monitor_input)
	_body.add_child(_monitor)

	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 10)
	_note.add_theme_color_override("font_color", Color(0.62, 0.70, 0.78))
	_note.text = "滚轮缩放 · 中键拖动平移 · 双击复位 · 拖动上方分隔条可调整工作区"
	add_child(_note)

## 行内小标题：让"这一撮控件是一组"一眼可见 ✓
## 第 48 轮：样式改从**共享主题**取（`Caption` 类型变体），不再手搓颜色 ✗→✓
func _hdr_caption(row: HBoxContainer, text: String) -> void:
	EchoEditorTheme.add_group_title(row, text)

# ============================================================================
# 对外接口
# ============================================================================
## 绑定一段过场（面板在 _load_cutscene 里调用）
func setup(p_doc: EditorCutsceneDoc) -> void:
	doc = p_doc
	room_override = &""
	ensure_world()
	_refresh_room_picker()
	_time = 0.0
	_reset_view()
	_layout_monitor()
	_refresh_monitor()

## 面板在播放头变化 / 播放推进时调用（唯一的时间入口）
func set_time(t: float) -> void:
	_time = maxf(t, 0.0)
	if doc != null:
		_time = minf(_time, doc.duration())
	_refresh_monitor()

## 播放按钮文案跟着面板的播放状态走
func set_playing(p: bool) -> void:
	if _play_btn != null:
		_play_btn.text = "⏸ 暂停" if p else "▶ 播放"

func time() -> float:
	return _time

## 折叠/展开监视器（工作区调整，反馈 3）
func _toggle_collapse() -> void:
	_collapsed = not _collapsed
	if _body != null:
		_body.visible = not _collapsed
		_body.custom_minimum_size = Vector2(0, 0 if _collapsed else BODY_HEIGHT)
	if _collapse_btn != null:
		_collapse_btn.text = "展开" if _collapsed else "折叠"
	if _note != null:
		_note.visible = not _collapsed
	if not _collapsed:
		_layout_monitor()
	if _monitor != null:
		_monitor.queue_redraw()

func is_collapsed() -> bool:
	return _collapsed

## 懒加载世界数据（编辑器里只读，加载失败也不报错，只是画面退化成提示）
func ensure_world() -> void:
	if _db != null or _db_tried:
		return
	_db_tried = true
	_db = WorldDatabase.new()
	if not _db.load_world():
		_db = null

func room_ids() -> Array:
	ensure_world()
	var out: Array = []
	if _db == null:
		return out
	for r: WorldDatabase.Room in _db.rooms:
		out.append(r.id)
	return out

## 当前预览的房间：手动指定优先，否则按镜头位置自动推断，最后兜底第一间
func current_room_id() -> StringName:
	ensure_world()
	if _db == null or _db.rooms.is_empty():
		return &""
	if room_override != &"":
		return room_override
	var inferred := room_for_camera(_time)
	return inferred if inferred != &"" else _db.rooms[0].id

func room() -> WorldDatabase.Room:
	ensure_world()
	if _db == null:
		return null
	# 第 46 轮：**舞台优先** —— camera 关键帧上写了 room 就用它（过场里换背景 ✓）；
	# 没写才退回"按镜头位置猜房间"的老逻辑（绝大多数过场都不需要写 ✓）
	if doc != null and doc.data != null:
		var st := Cutscene.stage_at(doc.data, _time)
		if st != &"" and _db.get_room(st) != null:
			return _db.get_room(st)
	return _db.get_room(current_room_id())

# ============================================================================
# 等比信封盒（反馈 1 的核心）
# ============================================================================
## 目标宽高比：跟随镜头 = 游戏视口；整房总览 = 房间本身
func target_aspect() -> float:
	var v := _view_size()
	var view_aspect := v.x / maxf(v.y, 1.0)
	if _follow_pick != null and _follow_pick.selected == 1:
		var r := room()
		if r != null and r.width > 0 and r.height > 0:
			return float(r.width) / float(r.height)
	return view_aspect

## 纯函数：在 avail 里取"最大的等比矩形"并居中（信封盒）。
## 由 smoke_editor 断言：比例误差 < 0.1%、居中、永不超过可用空间。
static func fit_rect(avail: Vector2, aspect: float) -> Rect2:
	if avail.x <= 0.0 or avail.y <= 0.0 or aspect <= 0.0:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var w := avail.x
	var h := w / aspect
	if h > avail.y:
		h = avail.y
		w = h * aspect
	var pos := ((avail - Vector2(w, h)) * 0.5).floor()
	return Rect2(pos, Vector2(w, h))

## 把监视器摆好（第 42 轮：默认**铺满**，可切**等比**）
## ----------------------------------------------------------------------------
## 第 37 轮我为了"绝不拉伸"做了等比信封盒（letterbox）→ 面板一宽，画面两侧就留黑边 ✗。
## 现在默认走第三条路：**铺满 + 均匀缩放** ——
##   监视器 = 整个可用区域；"要显示的世界矩形"按键"**面板自身宽高比**"算
##   （纵向取景仍由镜头 zoom 决定，横向随面板变宽而多看一点世界）。
## 于是"世界→屏幕"在 x/y 上的比例**完全相同** → 画面不变形，也**没有黑边** ✓。
## 若想要"与游戏 1:1 一致（16:9）"，点标题栏的「铺满/等比」切到等比即可（那时才留黑边）。
func _layout_monitor() -> void:
	if _body == null or _monitor == null:
		return
	var avail := _body.size - Vector2(FRAME_PAD, FRAME_PAD) * 2.0
	if avail.x < 8.0 or avail.y < 8.0:
		return
	if letterbox_ui:
		var fr := fit_rect(avail, target_aspect())
		if fr.size.x < 2.0 or fr.size.y < 2.0:
			return
		_monitor.position = fr.position + Vector2(FRAME_PAD, FRAME_PAD)
		_monitor.size = fr.size
	else:
		_monitor.position = Vector2(FRAME_PAD, FRAME_PAD)
		_monitor.size = avail
	_monitor.queue_redraw()
	_body.queue_redraw()

## 监视器在 _body 里的矩形（供测试与绘制黑边用）
func monitor_rect_local() -> Rect2:
	if _monitor == null:
		return Rect2()
	return Rect2(_monitor.position, _monitor.size)

# ============================================================================
# 缩放 / 平移（反馈 2 的核心）
# ============================================================================
func _monitor_center() -> Vector2:
	if _monitor == null:
		return Vector2.ZERO
	return _monitor.size * 0.5

func _reset_view() -> void:
	view_zoom = 1.0
	pan = Vector2.ZERO
	_update_zoom_label()
	if _monitor != null:
		_monitor.queue_redraw()

func _update_zoom_label() -> void:
	if _zoom_label != null:
		_zoom_label.text = "%d%%" % int(round(view_zoom * 100.0))

## 以"监视器内的某个点为锚"缩放：缩放后该点对应的**世界坐标保持不变**。
## 推导：世界显示矩形 = 以 (基视图中心 − pan换算的世界位移) 为中心、尺寸 = 基尺寸/zoom；
## 于是"锚点世界坐标 w = f(zoom, pan)"，反解 pan 即可让 w 钉在原处。
func _zoom_at(factor: float, anchor_local: Vector2) -> void:
	if _monitor == null or _monitor.size.x <= 0.0:
		return
	var world_before := world_at(anchor_local)
	view_zoom = clampf(view_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var base := base_view()
	if base.size.x > 0.0 and base.size.y > 0.0:
		var size_w := base.size / view_zoom
		var size_px := _monitor.size
		var pan_world := (base.get_center() - size_w * 0.5) + (anchor_local / size_px) * size_w - world_before
		pan = pan_world * size_px / size_w
	_update_zoom_label()
	_monitor.queue_redraw()

## 供测试/快捷键直接设缩放（锚点取监视器中心）
func set_zoom(z: float) -> void:
	_zoom_at(clampf(z, ZOOM_MIN, ZOOM_MAX) / maxf(view_zoom, 0.0001), _monitor_center())

## 基视图（zoom=1 时想看到的世界矩形）：跟随镜头 = 相机可见矩形；总览 = 整房
## 基视图：要显示的世界矩形（zoom=1 时）
## ----------------------------------------------------------------------------
## 第 42 轮改为"**按面板宽高比取景**"：
##   · 纵向：仍由镜头 zoom 决定（视口高 ÷ zoom）→ 游戏的纵向构图不变；
##   · 横向：= 纵向 × 面板宽高比       → 面板越宽，左右看到越多世界（不会留黑边）；
##   · 因此世界→屏幕的 x/y 缩放**同一个值** → 既不变形，也没有黑边。
func base_view() -> Rect2:
	var state := sampled_state(_time)
	var cam: Dictionary = state.get("camera", {})
	if not cam_edit.is_empty():
		cam = cam_edit.duplicate()          # 编辑态：以"当前拖出来的镜头"为准（未打点的改动）
	var overview := _follow_pick != null and _follow_pick.selected == 1
	var r := room()
	var aspect := 16.0 / 9.0
	if _monitor != null and _monitor.size.y > 1.0 and _monitor.size.x > 1.0:
		aspect = clampf(_monitor.size.x / _monitor.size.y, 0.25, 6.0)
	var zoom := maxf(float(cam.get("zoom", 1.0)), 0.05)
	var h_world := _view_size().y / zoom
	# 等比模式：横向按游戏视口的 16:9 算（与游戏画面 1:1，代价是面板更宽时留黑边）
	if letterbox_ui:
		aspect = target_aspect()
	var w_world := h_world * aspect
	if view_ratio > 0.0:
		# 播放器比例（纯观看）：数值越大 = 看得越"近"（显示范围越小）
		var f := 1.0 / maxf(view_ratio, 0.05)
		h_world *= f
		w_world *= f
	var center := Vector2(float(cam.get("x", 0.0)), float(cam.get("y", 0.0)))
	if cam.is_empty():
		center = room_pixel_rect(r).get_center() if r != null else Vector2.ZERO
	if overview and r != null:
		# 整房总览：以房间为准（同样按面板比例铺开，允许看到房间外一点）
		var rb := room_pixel_rect(r)
		center = rb.get_center()
		var need := maxf(rb.size.y, rb.size.x / maxf(aspect, 0.05))
		h_world = need
		w_world = need * aspect
	return Rect2(center - Vector2(w_world, h_world) * 0.5, Vector2(w_world, h_world))

# ============================================================================
# 镜头编辑（第 39 轮核心：在预览画面里拖/滚 → 打关键帧 → 镜头变化）
# ============================================================================
## 当前镜头（编辑态优先；返回值可直接写进 camera 轨道）
func current_camera() -> Dictionary:
	if not cam_edit.is_empty():
		return cam_edit.duplicate()
	return (sampled_state(_time).get("camera", {}) as Dictionary).duplicate()

func has_camera_edit() -> bool:
	return not cam_edit.is_empty()

## 打开镜头编辑：以当前采样值为起点（不改数据，只是拿到一份可拖的覆盖值）
func begin_camera_edit() -> void:
	edit_mode = true
	if cam_edit.is_empty():
		var cam: Dictionary = sampled_state(_time).get("camera", {})
		cam_edit = {
			"x": float(cam.get("x", 0.0)),
			"y": float(cam.get("y", 0.0)),
			"zoom": float(cam.get("zoom", 1.0)),
		}
	_refresh_monitor()

## 放弃未打点的改动（回到数据里的镜头）
func clear_camera_edit() -> void:
	cam_edit.clear()
	edit_mode = false
	_refresh_monitor()

## 拖拽 = 平移镜头（世界位移 = 像素位移 × 当前"屏幕→世界"比例）
func _pan_camera(rel_px: Vector2) -> void:
	if cam_edit.is_empty():
		begin_camera_edit()
	var view := base_view()
	if _monitor.size.x <= 0.0 or view.size.x <= 0.0:
		return
	var scale := view.size / _monitor.size
	cam_edit["x"] = float(cam_edit.get("x", 0.0)) - rel_px.x * scale.x
	cam_edit["y"] = float(cam_edit.get("y", 0.0)) - rel_px.y * scale.y
	_clamp_cam_edit()
	_refresh_monitor()

## 滚轮 = 缩放镜头（以鼠标处为锚：锚点的世界坐标保持不变）
## 写法刻意"与取景公式无关"：改完 zoom 后再问一次锚点处的世界坐标，把差值补回相机位置。
## 这样以后无论 `base_view()` 怎么改（16:9 / 面板比例 / 总览…），锚点都不会漂。
func _zoom_camera(factor: float, anchor_local: Vector2) -> void:
	if cam_edit.is_empty():
		begin_camera_edit()
	var world_before := world_at(anchor_local)
	cam_edit["zoom"] = clampf(float(cam_edit.get("zoom", 1.0)) * factor, CAM_ZOOM_MIN, CAM_ZOOM_MAX)
	var world_after := world_at(anchor_local)
	cam_edit["x"] = float(cam_edit.get("x", 0.0)) + (world_before.x - world_after.x)
	cam_edit["y"] = float(cam_edit.get("y", 0.0)) + (world_before.y - world_after.y)
	_clamp_cam_edit()
	_refresh_monitor()

## 镜头夹取：别把相机拖出当前房间
func _clamp_cam_edit() -> void:
	var r := room()
	if r == null or cam_edit.is_empty():
		return
	var rb := room_pixel_rect(r)
	cam_edit["x"] = clampf(float(cam_edit.get("x", 0.0)), rb.position.x, rb.position.x + rb.size.x)
	cam_edit["y"] = clampf(float(cam_edit.get("y", 0.0)), rb.position.y, rb.position.y + rb.size.y)

## 实际显示的世界矩形（把 zoom 与 pan 算进去），并把中心夹在房间范围内
func _world_shown() -> Rect2:
	var base := base_view()
	if base.size.x <= 0.0 or base.size.y <= 0.0:
		return base
	var size_w := base.size / maxf(view_zoom, 0.001)
	var size_px := _monitor.size
	var center := base.get_center()
	if size_px.x > 0.0 and size_px.y > 0.0:
		center -= pan * (size_w / size_px)     # pan 是像素 → 换算成世界位移
	# 夹取：不许把画面拖到房间外（总览模式下就是整房，等同于不许拖出边界）
	var r := room()
	if r != null and pan != Vector2.ZERO:
		var rb := room_pixel_rect(r)
		center.x = clampf(center.x, rb.position.x, rb.position.x + rb.size.x)
		center.y = clampf(center.y, rb.position.y, rb.position.y + rb.size.y)
	return Rect2(center - size_w * 0.5, size_w)

## 世界坐标 → 监视器内显示坐标
func map_world(p: Vector2) -> Vector2:
	return map_world_in(p, Rect2(Vector2.ZERO, _monitor.size), _world_shown())

## 监视器内某点 → 世界坐标（滚轮锚点、命中测试用）
func world_at(local: Vector2) -> Vector2:
	var view := _world_shown()
	if _monitor.size.x <= 0.0 or view.size.x <= 0.0:
		return view.position
	return view.position + (local / _monitor.size) * view.size

## 通用映射（也用于右下角缩略图：把世界矩形铺到任意目标矩形）
func map_world_in(p: Vector2, area: Rect2, view: Rect2) -> Vector2:
	if view.size.x <= 0.0 or view.size.y <= 0.0:
		return area.position
	return area.position + (p - view.position) / view.size * area.size

# ============================================================================
# 采样（与游戏共用 Cutscene.sample_track，所以"编辑器里看到的就是游戏里播的"）
# ============================================================================
## 取 t 时刻四条轨道的采样值（缺轨道就是空字典）
func sampled_state(t: float) -> Dictionary:
	var out := {"camera": {}, "actor": {}, "effect": {}, "text": {}}
	if doc == null or doc.data == null:
		return out
	for i in doc.track_count():
		var tr := doc.track(i)
		var kind := StringName(str(tr.get("kind", "")))
		if not out.has(kind):
			continue
		out[kind] = Cutscene.sample_track(tr, t)
	return out

## 镜头此刻"看得见"的世界矩形（视口 ÷ zoom，以相机为中心）。
## 纯函数：给 smoke_editor 做无头断言用，因此不读任何成员状态。
static func visible_rect(camera: Dictionary, view := FALLBACK_VIEW) -> Rect2:
	var zoom := maxf(float(camera.get("zoom", 1.0)), 0.05)
	var size := view / zoom
	var center := Vector2(float(camera.get("x", 0.0)), float(camera.get("y", 0.0)))
	return Rect2(center - size * 0.5, size)

## 哪间房的像素范围包含镜头中心（过场数据没有 room 字段，只能这样推断）
func room_for_camera(t: float) -> StringName:
	if _db == null:
		return &""
	var cam: Dictionary = sampled_state(t).get("camera", {})
	if cam.is_empty():
		return _db.rooms[0].id if not _db.rooms.is_empty() else &""
	var center := Vector2(float(cam.get("x", 0.0)), float(cam.get("y", 0.0)))
	for r: WorldDatabase.Room in _db.rooms:
		if room_pixel_rect(r).has_point(center):
			return r.id
	return _db.rooms[0].id if not _db.rooms.is_empty() else &""

## 房间的像素范围（世界坐标；原点在房间左上角）
static func room_pixel_rect(r: WorldDatabase.Room) -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(float(r.width), float(r.height)) * float(GameConstants.TILE))

func _view_size() -> Vector2:
	var w := float(ProjectSettings.get_setting("display/window/size/viewport_width", int(FALLBACK_VIEW.x)))
	var h := float(ProjectSettings.get_setting("display/window/size/viewport_height", int(FALLBACK_VIEW.y)))
	if w <= 1.0 or h <= 1.0:
		return FALLBACK_VIEW
	return Vector2(w, h)

# ============================================================================
# 输入（缩放 / 平移，反馈 2）
# ============================================================================
func _on_monitor_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if edit_mode:
				_zoom_camera(ZOOM_STEP, mb.position)      # 编辑态：滚轮改**镜头**
			else:
				_zoom_at(ZOOM_STEP, mb.position)          # 观看态：滚轮改**预览**
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if edit_mode:
				_zoom_camera(1.0 / ZOOM_STEP, mb.position)
			else:
				_zoom_at(1.0 / ZOOM_STEP, mb.position)
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 镜头编辑态 + 没按空格 → 左键 = 平移镜头（第 39 轮）
				if edit_mode and not Input.is_key_pressed(KEY_SPACE):
					_panning_cam = true
					accept_event()
					return
				if mb.double_click:
					_reset_view()
					accept_event()
					return
				# ★第 45 轮：左键 = 平移预览画面（含"空格+左键"）
				# 用户原话："在过场动画里无法用鼠标长按拖放来切换视角位置" ✗ → 现在左键直接能拖 ✓
				_panning = true
				_pan_last = mb.position
				accept_event()
				return
			else:
				_panning_cam = false
				_panning = false
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning_cam:
			_pan_camera(mm.relative)
			accept_event()
			return
		if _panning:
			pan += mm.relative
			_monitor.queue_redraw()
			accept_event()

# ============================================================================
# 绘制
# ============================================================================
func _refresh_monitor() -> void:
	if doc != null:
		_timecode.text = "%.2f / %.2fs" % [_time, doc.duration()]
	else:
		_timecode.text = "0.00 / 0.00s"
	_update_zoom_label()
	if _monitor != null:
		_monitor.queue_redraw()

## 播放器窗口的底：**明显的"窗口"观感** ——
## 外层是较亮的窗口底色，里面才是画面；
## 等比模式下画面四周留出的就是这块窗口底色（不再是"整个区域都是动画"）。
func _draw_body() -> void:
	if _body == null:
		return
	_body.draw_rect(Rect2(Vector2.ZERO, _body.size), Color(0.13, 0.14, 0.17))   # 窗口底
	var mr := monitor_rect_local()
	if mr.size.x > 2.0 and mr.size.y > 2.0:
		# 画面外框：让"窗口里的预览"这件事一眼可见
		_body.draw_rect(mr, Color(0.32, 0.36, 0.42), false, 2.0)

func _draw_monitor() -> void:
	var m := _monitor
	if m == null:
		return
	var size := m.size
	if checker_bg:
		# 棋盘格背景（剪映"透明背景"的表示法）：8px 格
		var cell := 8.0
		var i := 0
		var yy := 0.0
		while yy < size.y:
			var xx := 0.0
			var j := i
			while xx < size.x:
				if j % 2 == 0:
					m.draw_rect(Rect2(xx, yy, cell, cell), Color(0.16, 0.17, 0.20))
				else:
					m.draw_rect(Rect2(xx, yy, cell, cell), Color(0.11, 0.12, 0.14))
				xx += cell
				j += 1
			yy += cell
			i += 1
	else:
		m.draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08))

	if doc == null or doc.data == null:
		_center_text(m, size, "先选一段过场（上方下拉）")
		return
	ensure_world()
	if _db == null:
		_center_text(m, size, "读不到世界数据（res://data/world.json）")
		return
	var r := room()
	if r == null:
		_center_text(m, size, "当前房间不存在")
		return

	var state := sampled_state(_time)
	var cam: Dictionary = state.get("camera", {})
	var view := _world_shown()

	# 主画面就是整块监视器（因为监视器本身已按目标宽高比摆好 = 不拉伸）
	var area := Rect2(Vector2.ZERO, size)
	_draw_room(m, area, view, r)
	_draw_actors(m, area, view, state)
	_draw_camera_frame(m, area, view, cam)
	_draw_text_bar(m, area, state)
	_draw_effect_badge(m, area, state)
	_draw_inset(m, size, r, cam)
	_draw_readouts(m, size, area, view, cam)
	_draw_safe_frames(m, area)
	_draw_edit_badge(m, area)

## 安全框（第 39 轮）：90% 标题安全 + 80% 动作安全 + 中心十字
func _draw_safe_frames(m: Control, area: Rect2) -> void:
	if not safe_frames:
		return
	var c := area.get_center()
	var col := Color(0.95, 0.95, 1.0, 0.35)
	for f: float in [0.9, 0.8]:
		var r := Rect2(area.position + area.size * (1.0 - f) * 0.5, area.size * f)
		m.draw_rect(r, col, false, 1.0)
	m.draw_line(Vector2(c.x - 8.0, c.y), Vector2(c.x + 8.0, c.y), col, 1.0)
	m.draw_line(Vector2(c.x, c.y - 8.0), Vector2(c.x, c.y + 8.0), col, 1.0)

## 镜头编辑提示条（第 39 轮）：显示"有未打点的改动"+当前 x/y/zoom
func _draw_edit_badge(m: Control, area: Rect2) -> void:
	if cam_edit.is_empty():
		return
	var f := ThemeDB.fallback_font
	var s := "镜头未打点：x=%.0f y=%.0f zoom=%.2f（点『打关键帧』写入）" % [
		float(cam_edit.get("x", 0.0)), float(cam_edit.get("y", 0.0)), float(cam_edit.get("zoom", 1.0))]
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var bar := Rect2(area.position + Vector2(6, area.size.y - 40.0), Vector2(w + 12.0, 18.0))
	m.draw_rect(bar, Color(0.55, 0.42, 0.10, 0.85))
	m.draw_string(f, bar.position + Vector2(6, 13), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(1.0, 0.95, 0.75))

## 房间几何：地板带 + 障碍 + 门 + 存档点 + 敌人
func _draw_room(m: Control, area: Rect2, view: Rect2, r: WorldDatabase.Room) -> void:
	var ts := float(GameConstants.TILE)
	var floor_row := r.floor_top_row()
	var fr_tl := map_world_in(Vector2(0.0, float(floor_row) * ts), area, view)
	var fr_br := map_world_in(Vector2(float(r.width) * ts, float(r.height) * ts), area, view)
	var floor_rect := Rect2(fr_tl, fr_br - fr_tl).intersection(area)
	if floor_rect.size.x > 0.0 and floor_rect.size.y > 0.0:
		m.draw_rect(floor_rect, Color(0.20, 0.24, 0.33))
		m.draw_rect(floor_rect, Color(0.34, 0.42, 0.55), false, 1.0)
	for t: Vector2i in r.obstacles:
		var p := map_world_in(Vector2(t) * ts, area, view)
		var s := Vector2(ts, ts) / view.size * area.size
		var rect := Rect2(p, s).intersection(area)
		if rect.size.x > 0.5 and rect.size.y > 0.5:
			m.draw_rect(rect, Color(0.30, 0.35, 0.46))
	for d: WorldDatabase.DoorLink in r.doors:
		var dp := map_world_in(Vector2(d.at) * ts, area, view)
		if not area.grow(8.0).has_point(dp):
			continue
		var col := Color(0.45, 0.85, 0.55) if d.gate == &"" else Color(0.95, 0.55, 0.35)
		m.draw_rect(Rect2(dp - Vector2(3, 10), Vector2(6, 20)), col)
	if _db != null:
		for sp: Variant in _db.save_points:
			if typeof(sp) != TYPE_DICTIONARY:
				continue
			var e: Dictionary = sp
			if StringName(str(e.get("room", ""))) != r.id:
				continue
			var tv: Variant = e.get("tile", [])
			if typeof(tv) != TYPE_ARRAY or (tv as Array).size() < 2:
				continue
			var p2 := map_world_in(Vector2(float((tv as Array)[0]), float((tv as Array)[1])) * ts, area, view)
			if area.grow(8.0).has_point(p2):
				m.draw_circle(p2, 4.0, Color(0.40, 0.85, 0.95))
	for g: WorldDatabase.EnemyGroup in r.enemy_groups:
		var col2 := _enemy_color(g.type)
		for t: Vector2i in g.spawn_points:
			var p3 := map_world_in(Vector2(t) * ts, area, view)
			if area.grow(8.0).has_point(p3):
				m.draw_rect(Rect2(p3 - Vector2(4, 6), Vector2(8, 12)), col2)

## 角色：轨迹折线 + 当前位置 + 朝向箭头
func _draw_actors(m: Control, area: Rect2, view: Rect2, state: Dictionary) -> void:
	# 轨迹：把 actor 轨道所有关键帧连起来（编运镜时能看出一条走位）
	if doc != null:
		for i in doc.track_count():
			var tr := doc.track(i)
			if StringName(str(tr.get("kind", ""))) != &"actor":
				continue
			var pts := PackedVector2Array()
			for k: Variant in doc.keys(i):
				var kd: Dictionary = k
				pts.append(map_world_in(Vector2(float(kd.get("x", 0.0)), float(kd.get("y", 0.0))), area, view))
			for j in range(1, pts.size()):
				m.draw_line(pts[j - 1], pts[j], Color(0.55, 0.60, 0.75, 0.7), 1.0)
			for j in pts.size():
				m.draw_circle(pts[j], 2.5, Color(0.60, 0.66, 0.80))
	var actor: Dictionary = state.get("actor", {})
	if actor.is_empty():
		return
	var pos := map_world_in(Vector2(float(actor.get("x", 0.0)), float(actor.get("y", 0.0))), area, view)
	if not area.grow(24.0).has_point(pos):
		return
	var facing := float(actor.get("facing", 1.0))
	var visible_actor := bool(actor.get("visible", true))
	var body := Color(0.95, 0.95, 0.98) if visible_actor else Color(0.45, 0.45, 0.50)
	m.draw_rect(Rect2(pos - Vector2(5, 12), Vector2(10, 24)), body)
	var tip := pos + Vector2(14.0 * signf(facing if facing != 0.0 else 1.0), 0.0)
	m.draw_line(pos, tip, Color(1.0, 0.85, 0.35), 2.0)
	m.draw_circle(tip, 2.0, Color(1.0, 0.85, 0.35))
	m.draw_line(pos + Vector2(-7, 13), pos + Vector2(7, 13), Color(0, 0, 0, 0.5), 2.0)

## 镜头框：只在"整房总览"下画（跟随模式下框就是画面边缘，画了反而糊）
func _draw_camera_frame(m: Control, area: Rect2, view: Rect2, cam: Dictionary) -> void:
	if cam.is_empty():
		return
	if _follow_pick != null and _follow_pick.selected != 1:
		return
	var vr := visible_rect(cam, _view_size())
	var tl := map_world_in(vr.position, area, view)
	var br := map_world_in(vr.position + vr.size, area, view)
	m.draw_rect(Rect2(tl, br - tl), Color(1.0, 0.55, 0.55, 0.9), false, 1.0)

## 字幕（游戏同款：底部深色条 + 居中亮字）
func _draw_text_bar(m: Control, area: Rect2, state: Dictionary) -> void:
	var txt: Dictionary = state.get("text", {})
	var s := str(txt.get("text", ""))
	if s.strip_edges() == "":
		return
	var bar_h := 20.0
	var bar := Rect2(Vector2(area.position.x, area.position.y + area.size.y - bar_h), Vector2(area.size.x, bar_h))
	m.draw_rect(bar, Color(0.02, 0.03, 0.05, 0.82))
	var f := ThemeDB.fallback_font
	var fs := 12
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	m.draw_string(f, Vector2(bar.position.x + maxf((bar.size.x - w) * 0.5, 4.0), bar.position.y + 15.0),
		s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.94, 0.96, 1.0))

## 特效读数：显示采样到的 sfx/music；贴近关键帧时高亮（对齐打点用）
func _draw_effect_badge(m: Control, area: Rect2, state: Dictionary) -> void:
	var fx: Dictionary = state.get("effect", {})
	var parts: Array[String] = []
	if str(fx.get("sfx", "")) != "":
		parts.append("sfx " + str(fx.get("sfx")))
	if str(fx.get("music", "")) != "":
		parts.append("music " + str(fx.get("music")))
	if parts.is_empty():
		return
	var near := _near_effect_key(_time)
	var col := Color(1.0, 0.85, 0.35) if near else Color(0.70, 0.78, 0.88)
	m.draw_string(ThemeDB.fallback_font, area.position + Vector2(6, 14),
		" ｜ ".join(parts), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

## 播放头是否贴近某个特效关键帧
func _near_effect_key(t: float) -> bool:
	if doc == null:
		return false
	for i in doc.track_count():
		if StringName(str(doc.track(i).get("kind", ""))) != &"effect":
			continue
		for k: Variant in doc.keys(i):
			if absf(float((k as Dictionary).get("t", 0.0)) - t) <= EFFECT_HIGHLIGHT:
				return true
	return false

## 右下角：整房缩略图 + 镜头框
func _draw_inset(m: Control, size: Vector2, r: WorldDatabase.Room, cam: Dictionary) -> void:
	var rb := room_pixel_rect(r)
	if rb.size.x <= 0.0 or rb.size.y <= 0.0:
		return
	var iw := size.x * INSET_RATIO
	var ih := iw * (rb.size.y / rb.size.x)
	var ia := Rect2(Vector2(size.x - iw - 6.0, size.y - ih - 6.0), Vector2(iw, ih))
	m.draw_rect(ia, Color(0.08, 0.09, 0.12, 0.9))
	m.draw_rect(ia, Color(0.40, 0.46, 0.55), false, 1.0)
	var ts := float(GameConstants.TILE)
	var fr := Rect2(ia.position, Vector2(ia.size.x, ia.size.y * float(r.height - r.floor_top_row()) / float(r.height)))
	fr.position.y = ia.position.y + ia.size.y * float(r.floor_top_row()) / float(r.height)
	m.draw_rect(fr, Color(0.20, 0.24, 0.33))
	for t: Vector2i in r.obstacles:
		var p := map_world_in(Vector2(t) * ts, ia, rb)
		m.draw_rect(Rect2(p, Vector2(ts, ts) / rb.size * ia.size), Color(0.32, 0.37, 0.48))
	if not cam.is_empty():
		var vr := visible_rect(cam, _view_size())
		var tl := map_world_in(vr.position, ia, rb)
		var br := map_world_in(vr.position + vr.size, ia, rb)
		m.draw_rect(Rect2(tl, br - tl), Color(1.0, 0.45, 0.45), false, 1.0)

## 底部读数：镜头 / 取景方式 / 视窗尺寸 / 缩放
func _draw_readouts(m: Control, size: Vector2, area: Rect2, view: Rect2, cam: Dictionary) -> void:
	var f := ThemeDB.fallback_font
	var y := size.y - 4.0
	var cam_s := "镜头 —"
	if not cam.is_empty():
		var vr := visible_rect(cam, _view_size())
		cam_s = "镜头 x=%.0f y=%.0f zoom=%.2f ｜ 可见 %.0f×%.0f" % [
			float(cam.get("x", 0.0)), float(cam.get("y", 0.0)), float(cam.get("zoom", 1.0)),
			vr.size.x, vr.size.y]
	m.draw_string(f, Vector2(area.position.x + 4.0, y), cam_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
		Color(0.72, 0.80, 0.90))
	var mode := "整房总览" if (_follow_pick != null and _follow_pick.selected == 1) else "跟随镜头"
	var shown := "视窗 %.0f×%.0f ｜ %d%%" % [view.size.x, view.size.y, int(round(view_zoom * 100.0))]
	m.draw_string(f, Vector2(area.position.x + area.size.x - 210.0, y),
		mode + " ｜ " + shown, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.62, 0.72))

func _center_text(m: Control, size: Vector2, s: String) -> void:
	var f := ThemeDB.fallback_font
	var fs := 13
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	m.draw_string(f, Vector2((size.x - w) * 0.5, size.y * 0.5), s,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.70, 0.76, 0.85))

func _enemy_color(type: StringName) -> Color:
	match type:
		&"crawler":
			return Color(0.72, 0.45, 0.95)
		&"turret":
			return Color(0.95, 0.45, 0.35)
		&"drone":
			return Color(0.95, 0.70, 0.35)
		&"pouncer":
			return Color(0.95, 0.35, 0.55)
		&"boss_gatekeeper":
			return Color(1.0, 0.30, 0.30)
	return Color(0.80, 0.80, 0.85)

# ============================================================================
# 交互
# ============================================================================
func _refresh_room_picker() -> void:
	if _room_pick == null:
		return
	_room_pick.clear()
	var ids := room_ids()
	if ids.is_empty():
		_room_pick.add_item("（无世界数据）")
		return
	var cur := current_room_id()
	var sel := 0
	for i in ids.size():
		_room_pick.add_item(str(ids[i]))
		if StringName(str(ids[i])) == cur:
			sel = i
	_room_pick.selected = sel

func _on_room_picked(idx: int) -> void:
	var ids := room_ids()
	if idx < 0 or idx >= ids.size():
		return
	room_override = StringName(str(ids[idx]))
	_reset_view()
	_layout_monitor()
	_refresh_monitor()
