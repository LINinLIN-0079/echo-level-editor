@tool
extends Control
## ============================================================================
## EditorScreen —— 关卡编辑器界面（Godot 编辑器插件的主屏幕页）
## ----------------------------------------------------------------------------
## 这是 Round 16/17 那版"游戏内编辑器"的**正确形态**：它现在跑在 Godot 编辑器进程里
## （@tool 脚本 + EditorInterface），游戏导出版里完全不存在，玩家永远进不来。
##
## 与运行时的三处关键差异（也是重构的要点）：
##   1. **不依赖任何 autoload**（SceneRouter / SaveSystem / GameState 在编辑器里不存在），
##      需要的能力改用编辑器 API：试玩=EditorInterface.play_main_scene()、
##      保存后刷新=EditorInterface.get_resource_filesystem().scan()；
##   2. **没有"主菜单"**：这是编辑器的一个页面，切换页面由顶栏负责，Esc 不再做场景跳转；
##   3. **试玩标记写到游戏侧的 user://**（EditorPlaytest 负责算路径），
##      因为编辑器进程的 user:// 与被启动游戏的 user:// 不是同一个目录。
##
## 数据流仍然是"磁盘 JSON 是唯一事实源"：编辑器读写 world.json + rooms/*.json，
## 与游戏运行时共用同一批文件，因此保存后按 F5 立刻能玩到改动。
##
## 界面：工具栏（工具/敌人类型/撤销/重做/校验/保存/重载/面板/试玩）+ 房间列表
##       + 画布（EditorCanvas）+ 检查器（房间元数据/敌人分组/门/校验面板）+ 状态栏。
## 快捷键：1/2/3/4 工具，Ctrl+Z 撤销，Ctrl+Y 重做，Ctrl+S 保存，R 重载。
## ============================================================================

var db := WorldDatabase.new()
var doc: EditorDoc = null
var canvas: EditorCanvas = null

var _status: Label = null
var _note: Label = null          ## 最近一次操作的可见反馈（红字=错误）
## 操作日志（编辑器插件写的开发日志；见 _append_note_log）
const NOTE_LOG_PATH := "res://.editor_notes.log"
var _problems: RichTextLabel = null
var _room_list_box: VBoxContainer = null
var _inspector: VBoxContainer = null
var _enemy_box: VBoxContainer = null
var _door_box: VBoxContainer = null
var _tool_buttons: Dictionary = {}
var _enemy_picker: OptionButton = null
## 放置时的拾取物/触发器种类
var _pickup_picker: OptionButton = null
var _trigger_picker: OptionButton = null
var pickup_kind: StringName = &"gold"
var trigger_kind: StringName = &"message"
## 模板预制体 UI
var _template_picker: OptionButton = null
var _template_hint: Label = null
var _template_anchor_label: Label = null
var _template_id_edit: LineEdit = null
var _template_kind_picker: OptionButton = null
## 最后一次"在房间内"悬停的瓦片。
## 为什么要记住而不是直接用 canvas.hover_tile：鼠标从画布移向检查器按钮时，
## 画布会收到一个界外的 motion 事件，hover_tile 随之变成房外坐标，
## 于是"套用"读到界外锚点 → 静默放弃（实测在 Godot 编辑器里复现：
## 点「套用」后碰撞体积数量不变、也没有任何提示）。
var _template_anchor := Vector2i(-1, -1)
var _dialog: AcceptDialog = null
var _room_panel: PanelContainer = null
var _inspector_panel: PanelContainer = null

var tool: int = EditorCanvas.Tool.PAINT
var enemy_type: StringName = &"crawler"
var _panels_visible := true
## 过场动画面板（第 45 轮：插件 dock 化时要通过它取走"素材库 / 属性检查器"）
var cutscene_panel: EditorCutscenePanel = null

# ============================================================================
# ① 面板 dock 化（第 45 轮）：把过场页里的两栏交给插件去 `add_control_to_dock`
# ----------------------------------------------------------------------------
# 返回 [素材库面板, 属性检查器面板]；若该页还没建好（或已交出去过）返回空数组，
# 插件据此安全跳过（不会让编辑器崩溃，也不会破坏"页面内三栏"这种老用法 ✓）。
# ============================================================================
func take_cutscene_docks() -> Array:
	if cutscene_panel == null:
		return []
	return cutscene_panel.take_dock_panels()

# ============================================================================
# 启动
# ============================================================================
func _ready() -> void:
	# ★ 第 48 轮 UI 美化：在插件根节点挂一次共享主题 —— 所有子页面自动继承 ✓ ★
	# （配色/圆角/内边距/按钮五态/小标题变体都在 EditorTheme 里统一定义 ✓）
	theme = EchoEditorTheme.make()
	_build_ui()
	var ok := db.load_world()
	if not ok:
		_append_problem("世界数据存在问题：\n" + db.problem_summary())
	# 起始房间：优先"上次试玩的那一房"，形成 编辑→试玩→回到同一房 的闭环
	var start_id := db.start_room
	var marker := EditorPlaytest.peek_marker()
	if marker != &"" and db.get_room(marker) != null:
		start_id = marker
	_load_room(start_id)
	_show_note("残响关卡编辑器就绪：左键放置 / 右键擦除 / 中键或空格+左键平移 / 滚轮缩放 / Ctrl+Alt+S 保存 / Ctrl+Alt+R 重载（注意 Ctrl+S 是编辑器本体的「保存场景」，不要用）")

# ============================================================================
# 界面构建
# ============================================================================
func _build_ui() -> void:
	# 两个页签：关卡编辑（本文件）/ 敌人 AI（行为树编辑器，EditorBtPanel）
	# TabContainer 会用子节点名当页签标题，且自动把内容撑满 → 不需要任何锚点魔法
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)
	tabs.add_child(_build_level_tab())

	var bt_panel := EditorBtPanel.new()
	bt_panel.name = "敌人 AI"
	tabs.add_child(bt_panel)

	# 关卡图页：双击房间 → 切回「关卡编辑」页并打开那一房（两页联动）
	var world_panel := EditorWorldPanel.new()
	world_panel.name = "关卡图"
	world_panel.on_open_room = func(room_id: StringName) -> void:
		tabs.current_tab = 0
		_load_room(room_id)
	tabs.add_child(world_panel)

	# 过场动画页：CapCut 式关键帧时间轴（数据在 data/cutscenes/*.json）
	var cut_panel := EditorCutscenePanel.new()
	cut_panel.name = "过场动画"
	tabs.add_child(cut_panel)
	cutscene_panel = cut_panel

	_dialog = AcceptDialog.new()
	_dialog.title = "提示"
	add_child(_dialog)

func _build_level_tab() -> Control:
	# 页面外壳：统一内边距（美化的一部分 —— 内容不贴边，视觉上"有呼吸感" ✓）
	var pad := MarginContainer.new()
	pad.name = "关卡编辑"
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	pad.add_child(root)
	root.add_child(_build_toolbar())

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 4)
	root.add_child(middle)
	middle.add_child(_build_room_list())
	middle.add_child(_build_canvas())
	middle.add_child(_build_inspector())

	# 提示条（最近一次操作的反馈，红字=错误）—— 必须在状态栏之上，用户才看得到
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 11)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.text = "提示会显示在这里（最近一次操作的结果）"
	_note.add_theme_color_override("font_color", Color(0.75, 0.8, 0.86))
	root.add_child(_note)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_FILL
	root.add_child(_status)
	return pad

func _build_toolbar() -> Control:
	# 工具条放进横向滚动容器：按钮多，若参与"最小宽度"计算会把右侧检查器挤出可视区
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 34)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "残响关卡编辑器"
	title.theme_type_variation = &"Title"
	title.tooltip_text = "残响回廊关卡编辑器（Godot 插件：只存在于编辑器进程，游戏导出版里没有它 ✓）"
	bar.add_child(title)
	bar.add_child(VSeparator.new())

	EchoEditorTheme.add_group_title(bar, "工具")
	_add_tool_button(bar, "画笔", EditorCanvas.Tool.PAINT, "1")
	# ✋ 平移工具（第 45 轮）：选中后左键拖动即平移（不画任何东西），最直观的"切换视角"
	_add_tool_button(bar, "✋平移", EditorCanvas.Tool.PAN, "7")
	_add_tool_button(bar, "矩形", EditorCanvas.Tool.RECT, "2")
	_add_tool_button(bar, "敌人", EditorCanvas.Tool.ENEMY, "3")
	_add_tool_button(bar, "选择", EditorCanvas.Tool.SELECT, "4")
	_add_tool_button(bar, "拾取物", EditorCanvas.Tool.PICKUP, "5")
	_add_tool_button(bar, "触发器", EditorCanvas.Tool.TRIGGER, "6")

	EchoEditorTheme.add_group_title(bar, "素材")
	var enemy_label := Label.new()
	enemy_label.text = "敌人类型"
	enemy_label.theme_type_variation = &"Caption"
	bar.add_child(enemy_label)
	_enemy_picker = OptionButton.new()
	for type_id: Variant in EnemyData.known_ids():
		_enemy_picker.add_item(String(type_id))
	_enemy_picker.item_selected.connect(func(idx: int) -> void:
		enemy_type = StringName(_enemy_picker.get_item_text(idx))
		_show_note("当前敌人类型：%s" % String(enemy_type)))
	bar.add_child(_enemy_picker)

	# 拾取物/触发器种类（放置时用；放完还能在右侧检查器里逐条改）
	var pickup_label := Label.new()
	pickup_label.text = "拾取"
	pickup_label.theme_type_variation = &"Caption"
	bar.add_child(pickup_label)
	_pickup_picker = OptionButton.new()
	for k: Variant in Interactables.PICKUP_KINDS.keys():
		_pickup_picker.add_item("%s（%s）" % [String(k), str(Interactables.PICKUP_KINDS[k]["label"])])
	_pickup_picker.item_selected.connect(func(idx: int) -> void:
		pickup_kind = StringName(str(Interactables.PICKUP_KINDS.keys()[idx]))
		_show_note("当前拾取物种类：%s" % String(pickup_kind)))
	bar.add_child(_pickup_picker)

	var trigger_label := Label.new()
	trigger_label.text = "触发"
	trigger_label.theme_type_variation = &"Caption"
	bar.add_child(trigger_label)
	_trigger_picker = OptionButton.new()
	for k2: Variant in Interactables.TRIGGER_KINDS.keys():
		_trigger_picker.add_item("%s（%s）" % [String(k2), str(Interactables.TRIGGER_KINDS[k2]["label"])])
	_trigger_picker.item_selected.connect(func(idx: int) -> void:
		trigger_kind = StringName(str(Interactables.TRIGGER_KINDS.keys()[idx]))
		_show_note("当前触发器种类：%s" % String(trigger_kind)))
	bar.add_child(_trigger_picker)

	bar.add_child(VSeparator.new())
	scroll.add_child(bar)

	# ---- 第二行：**关键动作常驻可见** ----
	# 教训：这些按钮原先跟在滚动行末尾，被横向滚动挤出屏幕 —— 保存/试玩这类
	# "必须一眼找到"的按钮绝不能藏在滚动条后面（真机验证时也点不到）。
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	var shortcuts := Label.new()
	shortcuts.text = "快捷键：保存 Ctrl+Alt+S ｜ 重载 Ctrl+Alt+R ｜ 试玩 Ctrl+Alt+V ｜ 撤销 Ctrl+Z"
	shortcuts.theme_type_variation = &"Hint"
	EchoEditorTheme.add_group_title(actions, "操作")
	_add_action_button(actions, "撤销", _on_undo)
	_add_action_button(actions, "重做", _on_redo)
	_add_action_button(actions, "校验", _on_validate)
	_add_action_button(actions, "保存", _on_save)
	_add_action_button(actions, "重新载入", _on_reload)
	_add_action_button(actions, "面板", _toggle_panels)
	_add_action_button(actions, "试玩", _on_playtest)
	actions.add_child(VSeparator.new())
	actions.add_child(shortcuts)

	var two_rows := VBoxContainer.new()
	two_rows.add_theme_constant_override("separation", 2)
	two_rows.add_child(scroll)
	two_rows.add_child(actions)
	return two_rows

func _add_tool_button(bar: HBoxContainer, text: String, t: int, hint: String) -> void:
	var b := Button.new()
	b.text = "%s(%s)" % [text, hint]
	b.toggle_mode = true
	b.pressed.connect(func() -> void: _set_tool(t))
	bar.add_child(b)
	_tool_buttons[t] = b

func _add_action_button(bar: HBoxContainer, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	bar.add_child(b)

func _build_room_list() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(168, 0)
	_room_panel = panel
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	_room_list_box = VBoxContainer.new()
	_room_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_room_list_box)
	return panel

func _build_canvas() -> Control:
	canvas = EditorCanvas.new()
	canvas.tile_action.connect(_on_tile_action)
	canvas.entity_clicked.connect(_on_entity_clicked)
	canvas.pickup_action.connect(_on_pickup_action)
	canvas.trigger_action.connect(_on_trigger_action)
	canvas.view_changed.connect(_refresh_status)
	canvas.target_grid_provider = func(room_id: StringName) -> Variant:
		var r := db.get_room(room_id)
		return r.grid if r != null else null
	canvas.save_point_provider = func() -> Array:
		return _save_points_of(doc.room_id)
	return canvas

func _build_inspector() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	_inspector_panel = panel
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 4)
	scroll.add_child(_inspector)
	return panel

# ============================================================================
# 房间装载
# ============================================================================
func _load_room(room_id: StringName) -> void:
	if doc != null and doc.is_dirty():
		_dialog.dialog_text = "当前房间（%s）还有未保存的修改。\n请先点「保存」，或用「重新载入」放弃修改。" % doc.room_name
		_dialog.popup_centered()
		return
	doc = EditorDoc.load_room(room_id, db)
	if doc == null:
		_append_problem("无法加载房间：%s" % String(room_id))
		return
	canvas.set_doc(doc)
	canvas.fit_view()
	_refresh_room_list()
	_refresh_inspector()
	_validate_now()
	_refresh_status()

func _refresh_room_list() -> void:
	for c in _room_list_box.get_children():
		c.queue_free()
	for zone in db.zones:
		var header := Label.new()
		header.text = "%s %s" % [String(zone.id), zone.name]
		header.add_theme_font_size_override("font_size", 11)
		header.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
		_room_list_box.add_child(header)
		for rid in zone.rooms:
			var room := db.get_room(rid)
			if room == null:
				continue
			var b := Button.new()
			b.text = "  R%02d %s%s" % [room.ordinal, room.name, "  ★" if room.is_boss else ""]
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.add_theme_font_size_override("font_size", 12)
			b.disabled = doc != null and doc.room_id == rid
			b.pressed.connect(func() -> void: _load_room(rid))
			_room_list_box.add_child(b)

# ============================================================================
# 检查器
# ============================================================================
func _refresh_inspector() -> void:
	for c in _inspector.get_children():
		c.queue_free()
	if doc == null:
		return

	_inspector.add_child(_section("房间"))
	_inspector.add_child(_label("id：%s（序号 %d）" % [String(doc.room_id), db.get_room(doc.room_id).ordinal]))
	_inspector.add_child(_text_field("名称", doc.room_name, func(v: String) -> void:
		if doc.set_field("room_name", v):
			_refresh_status()))
	_inspector.add_child(_spin_field("金币奖励", float(doc.gold_drop), 0, 9999, 1.0,
		func(v: float) -> void:
			if doc.set_field("gold_drop", int(v)):
				_refresh_status()))
	_inspector.add_child(_spin_field("宽（瓦）", float(doc.width), 12, 80, 1.0,
		func(v: float) -> void:
			if doc.set_field("width", int(v)):
				_after_geometry_change()))
	_inspector.add_child(_spin_field("高（瓦）", float(doc.height), 8, 48, 1.0,
		func(v: float) -> void:
			if doc.set_field("height", int(v)):
				_after_geometry_change()))
	_inspector.add_child(_option_field("胜负条件", ["clear_room", "reach_terminal"], String(doc.victory),
		func(v: String) -> void:
			if doc.set_field("victory", StringName(v)):
				_refresh_status()))
	_inspector.add_child(_option_field("能力奖励", ["", "dash", "double_jump", "melee"],
		String(doc.ability_reward), func(v: String) -> void:
			if doc.set_field("ability_reward", StringName(v)):
				_refresh_status()))
	var boss_check := CheckBox.new()
	boss_check.text = "Boss 房"
	boss_check.button_pressed = doc.is_boss
	boss_check.toggled.connect(func(on: bool) -> void:
		if doc.set_field("is_boss", on):
			_refresh_status())
	_inspector.add_child(boss_check)

	_inspector.add_child(_section("敌人分组（数值直接改游戏手感）"))
	_enemy_box = VBoxContainer.new()
	_inspector.add_child(_enemy_box)
	for g: Variant in doc.enemy_groups:
		var group: Dictionary = g
		var type_id := StringName(str(group.get("type", "")))
		var head := Label.new()
		head.text = "%s × %d" % [String(type_id), int(group.get("count", 0))]
		head.add_theme_font_size_override("font_size", 12)
		_enemy_box.add_child(head)
		_enemy_box.add_child(_spin_field("  HP", float(group.get("hp", 1)), 1, 999, 1.0,
			func(v: float) -> void:
				doc.set_group_field(type_id, "hp", int(v))))
		_enemy_box.add_child(_spin_field("  移速", float(group.get("move_speed", 0.0)), 0, 400, 1.0,
			func(v: float) -> void:
				doc.set_group_field(type_id, "move_speed", v)))
		_enemy_box.add_child(_spin_field("  攻击", float(group.get("attack", 1)), 0, 20, 1.0,
			func(v: float) -> void:
				doc.set_group_field(type_id, "attack", int(v))))
	if doc.enemy_groups.is_empty():
		_inspector.add_child(_label("（本房没有敌人）"))

	_inspector.add_child(_section("门（目标房 / 门控）"))
	_door_box = VBoxContainer.new()
	_inspector.add_child(_door_box)
	for i in doc.doors.size():
		var d: Dictionary = doc.doors[i]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = "→ %s" % str(d.get("to", "?"))
		lbl.custom_minimum_size = Vector2(58, 0)
		row.add_child(lbl)
		var gate_pick := OptionButton.new()
		for gate in WorldDatabase.ALLOWED_GATES:
			gate_pick.add_item(gate if gate != "" else "（无门控）")
		var cur_gate := str(d.get("gate", ""))
		gate_pick.selected = maxi(WorldDatabase.ALLOWED_GATES.find(cur_gate), 0)
		var index := i
		gate_pick.item_selected.connect(func(idx: int) -> void:
			doc.set_door_field(index, "gate", WorldDatabase.ALLOWED_GATES[idx])
			_validate_now()
			canvas.queue_redraw())
		row.add_child(gate_pick)
		var del := Button.new()
		del.text = "删"
		del.pressed.connect(func() -> void:
			doc.remove_door(index)
			_refresh_inspector()
			_validate_now()
			canvas.queue_redraw())
		row.add_child(del)
		_door_box.add_child(row)

	var add_row := HBoxContainer.new()
	var room_pick := OptionButton.new()
	for room in db.rooms:
		if room.id != doc.room_id:
			room_pick.add_item(String(room.id))
	add_row.add_child(room_pick)
	var add_btn := Button.new()
	add_btn.text = "加门"
	add_btn.pressed.connect(func() -> void:
		if room_pick.item_count > 0:
			if doc.add_door(StringName(room_pick.get_item_text(room_pick.selected))):
				_refresh_inspector()
				_validate_now()
				canvas.queue_redraw())
	add_row.add_child(add_btn)
	_inspector.add_child(add_row)

	# ---- 拾取物 ----
	_inspector.add_child(_section("拾取物（金币默认带磁吸，靠近自动飞来）"))
	for i in doc.pickups.size():
		var entry: Dictionary = doc.pickups[i]
		var pkind := StringName(str(entry.get("kind", "gold")))
		var prow := HBoxContainer.new()
		var plbl := Label.new()
		plbl.text = "%s @%s" % [String(pkind), str(entry.get("tile", []))]
		plbl.custom_minimum_size = Vector2(96, 0)
		plbl.add_theme_font_size_override("font_size", 11)
		prow.add_child(plbl)
		var pidx := i
		if pkind == &"ability":
			var ability_pick := OptionButton.new()
			for a in ["dash", "double_jump", "melee"]:
				ability_pick.add_item(a)
			ability_pick.selected = maxi(["dash", "double_jump", "melee"].find(str(entry.get("ability", "dash"))), 0)
			ability_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ability_pick.item_selected.connect(func(idx: int) -> void:
				doc.set_pickup_field(pidx, "ability", ["dash", "double_jump", "melee"][idx])
				_validate_now())
			prow.add_child(ability_pick)
		else:
			var amount_spin := SpinBox.new()
			amount_spin.min_value = 1
			amount_spin.max_value = 999
			amount_spin.value = float(entry.get("amount", 1))
			amount_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			amount_spin.value_changed.connect(func(v: float) -> void:
				doc.set_pickup_field(pidx, "amount", int(v))
				_validate_now())
			prow.add_child(amount_spin)
		var pdel := Button.new()
		pdel.text = "删"
		pdel.pressed.connect(func() -> void:
			doc.remove_pickup(pidx)
			_refresh_inspector()
			_validate_now()
			canvas.queue_redraw())
		prow.add_child(pdel)
		_inspector.add_child(prow)
	if doc.pickups.is_empty():
		_inspector.add_child(_label("（没有拾取物：用工具栏「拾取物(5)」在画布上点一下）"))

	# ---- 触发器 ----
	_inspector.add_child(_section("触发器（矩形区域，进入即触发）"))
	for j in doc.triggers.size():
		var tentry: Dictionary = doc.triggers[j]
		var tkind := StringName(str(tentry.get("kind", "message")))
		var tidx := j
		var head := HBoxContainer.new()
		var tlbl := Label.new()
		tlbl.text = "%s @%s" % [String(tkind), str(tentry.get("tile", []))]
		tlbl.custom_minimum_size = Vector2(96, 0)
		tlbl.add_theme_font_size_override("font_size", 11)
		head.add_child(tlbl)
		var kind_pick := OptionButton.new()
		for k: Variant in Interactables.TRIGGER_KINDS.keys():
			kind_pick.add_item(String(k))
		kind_pick.selected = maxi(Interactables.TRIGGER_KINDS.keys().find(String(tkind)), 0)
		kind_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kind_pick.item_selected.connect(func(idx: int) -> void:
			doc.set_trigger_field(tidx, "kind", String(Interactables.TRIGGER_KINDS.keys()[idx]))
			_refresh_inspector()
			_validate_now())
		head.add_child(kind_pick)
		var tdel := Button.new()
		tdel.text = "删"
		tdel.pressed.connect(func() -> void:
			doc.remove_trigger(tidx)
			_refresh_inspector()
			_validate_now()
			canvas.queue_redraw())
		head.add_child(tdel)
		_inspector.add_child(head)

		# 尺寸 W x H（瓦）
		var size_row := HBoxContainer.new()
		var size_lbl := Label.new()
		size_lbl.text = "尺寸(瓦)"
		size_lbl.custom_minimum_size = Vector2(72, 0)
		size_lbl.add_theme_font_size_override("font_size", 11)
		size_row.add_child(size_lbl)
		var tw := SpinBox.new()
		tw.min_value = 1
		tw.max_value = 30
		tw.value = float(EditorCanvas.entry_tile_size(tentry).x)
		tw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tw.value_changed.connect(func(v: float) -> void:
			doc.set_trigger_field(tidx, "size", [int(v), int(EditorCanvas.entry_tile_size(doc.triggers[tidx]).y)])
			canvas.queue_redraw()
			_validate_now())
		size_row.add_child(tw)
		var th := SpinBox.new()
		th.min_value = 1
		th.max_value = 30
		th.value = float(EditorCanvas.entry_tile_size(tentry).y)
		th.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		th.value_changed.connect(func(v: float) -> void:
			doc.set_trigger_field(tidx, "size", [int(EditorCanvas.entry_tile_size(doc.triggers[tidx]).x), int(v)])
			canvas.queue_redraw()
			_validate_now())
		size_row.add_child(th)
		_inspector.add_child(size_row)

		# 文本 + 只触发一次
		if tkind == &"message" or tkind == &"cutscene":
			_inspector.add_child(_text_field("  文本", str(tentry.get("text", "")), func(v: String) -> void:
				doc.set_trigger_field(tidx, "text", v)
				_validate_now()))
		var once_check := CheckBox.new()
		once_check.text = "只触发一次"
		once_check.button_pressed = bool(tentry.get("once", true))
		once_check.toggled.connect(func(on: bool) -> void:
			doc.set_trigger_field(tidx, "once", on))
		_inspector.add_child(once_check)
	if doc.triggers.is_empty():
		_inspector.add_child(_label("（没有触发器：用工具栏「触发器(6)」在画布上点一下）"))

	# ---- 模板预制体 ----
	_inspector.add_child(_section("模板预制体（搭关卡不用从零摆）"))
	_template_picker = OptionButton.new()
	_template_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_template_picker.item_selected.connect(func(_i: int) -> void:
		_refresh_template_hint())
	_inspector.add_child(_template_picker)
	_template_hint = _label("（没有模板；先在下面输入 id 并存一个）")
	_inspector.add_child(_template_hint)
	_inspector.add_child(_label("套用锚点 = **最后一次**在房间内悬停的瓦片（鼠标移到按钮上时锚点不会丢）"))
	_template_anchor_label = _label("当前锚点：%s" % (
		"(%d, %d)" % [_template_anchor.x, _template_anchor.y] if canvas.inside_room(_template_anchor) else "—"))
	_inspector.add_child(_template_anchor_label)

	var apply_row := HBoxContainer.new()
	var apply_btn := Button.new()
	apply_btn.text = "套用（锚点=最后悬停瓦片）"
	apply_btn.pressed.connect(_on_template_apply)
	apply_row.add_child(apply_btn)
	_inspector.add_child(apply_row)

	var save_row := HBoxContainer.new()
	_template_id_edit = LineEdit.new()
	_template_id_edit.placeholder_text = "新模板 id（英文）"
	_template_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(_template_id_edit)
	_template_kind_picker = OptionButton.new()
	for k: Variant in EditorTemplateLib.KINDS.keys():
		_template_kind_picker.add_item(str(EditorTemplateLib.KINDS[k]["label"]))
	save_row.add_child(_template_kind_picker)
	_inspector.add_child(save_row)

	var save_btn_row := HBoxContainer.new()
	var save_btn := Button.new()
	save_btn.text = "把当前房间的这类内容存为模板"
	save_btn.pressed.connect(_on_template_save)
	save_btn_row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "删除选中模板"
	del_btn.pressed.connect(_on_template_delete)
	save_btn_row.add_child(del_btn)
	_inspector.add_child(save_btn_row)
	_refresh_template_picker()

	_inspector.add_child(_section("校验"))
	_problems = RichTextLabel.new()
	_problems.fit_content = true
	_problems.custom_minimum_size = Vector2(0, 110)
	_problems.add_theme_font_size_override("normal_font_size", 11)
	_inspector.add_child(_problems)

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
	row.add_child(l)
	var edit := LineEdit.new()
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(v: String) -> void: on_change.call(v))
	edit.focus_exited.connect(func() -> void: on_change.call(edit.text))
	row.add_child(edit)
	return row

func _spin_field(label: String, value: float, lo: float, hi: float, step: float, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(72, 0)
	row.add_child(l)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = step
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(v: float) -> void: on_change.call(v))
	row.add_child(spin)
	return row

func _option_field(label: String, options: Array, current: String, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(72, 0)
	row.add_child(l)
	var pick := OptionButton.new()
	for o: Variant in options:
		pick.add_item(String(o) if String(o) != "" else "（无）")
	pick.selected = maxi(options.find(current), 0)
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.item_selected.connect(func(idx: int) -> void: on_change.call(String(options[idx])))
	row.add_child(pick)
	return row

# ============================================================================
# 编辑动作
# ============================================================================
func _set_tool(t: int) -> void:
	tool = t
	canvas.tool = t
	for key: Variant in _tool_buttons.keys():
		(_tool_buttons[key] as Button).button_pressed = int(key) == t
	canvas.queue_redraw()
	_show_note("工具：%s" % _tool_name(t))

func _tool_name(t: int) -> String:
	match t:
		EditorCanvas.Tool.PAINT: return "画笔（左键画碰撞体积，右键擦）"
		EditorCanvas.Tool.PAN: return "平移（左键拖动移动视角；也可中键拖动或空格+左键）"
		EditorCanvas.Tool.RECT: return "矩形（左键拖出矩形，右键拖出擦除）"
		EditorCanvas.Tool.ENEMY: return "敌人（左键放，右键删；类型见工具栏）"
		EditorCanvas.Tool.PICKUP: return "拾取物（左键放，右键删；种类见工具栏，金币带磁吸）"
		EditorCanvas.Tool.TRIGGER: return "触发器（左键放 2x2 区域，右键删；种类见工具栏）"
		_: return "选择"

# ============================================================================
# 模板预制体（复用 EditorDoc 的编辑 API，因此撤销/校验/保存自动生效）
# ============================================================================
func _process(_delta: float) -> void:
	# 记住最后一次房内悬停（鼠标移向按钮时 hover_tile 会变成界外，见 _template_anchor 的说明）
	if canvas != null and canvas.inside_room(canvas.hover_tile) and canvas.hover_tile != _template_anchor:
		_template_anchor = canvas.hover_tile
		if _template_anchor_label != null:
			_template_anchor_label.text = "当前锚点：(%d, %d)" % [_template_anchor.x, _template_anchor.y]

func _refresh_template_picker() -> void:
	if _template_picker == null:
		return
	var keep := _selected_template_id()
	_template_picker.clear()
	for id: Variant in EditorTemplateLib.available():
		var t := EditorTemplateLib.load_template(StringName(str(id)))
		_template_picker.add_item("%s ｜ %s" % [String(id), EditorTemplateLib.describe(t)])
	# 尽量保持原选择
	for i in _template_picker.item_count:
		if _template_picker.get_item_text(i).begins_with(String(keep)):
			_template_picker.selected = i
			break
	_refresh_template_hint()

func _selected_template_id() -> StringName:
	if _template_picker == null or _template_picker.item_count == 0:
		return &""
	var text := _template_picker.get_item_text(_template_picker.selected)
	return StringName(text.split(" ")[0])

func _refresh_template_hint() -> void:
	if _template_hint == null:
		return
	var t := EditorTemplateLib.load_template(_selected_template_id())
	if t.is_empty():
		_template_hint.text = "（没有模板；在下面输入 id 并存一个）"
		return
	_template_hint.text = EditorTemplateLib.describe(t)

func _on_template_apply() -> void:
	if doc == null:
		return
	var id := _selected_template_id()
	if String(id) == "":
		_show_note("先选一个模板", true)
		return
	var t := EditorTemplateLib.load_template(id)
	if t.is_empty():
		_show_note("模板读不出来：%s" % String(id), true)
		return
	var anchor := canvas.hover_tile if canvas.inside_room(canvas.hover_tile) else _template_anchor
	if not canvas.inside_room(anchor):
		_show_note("还没有可用的锚点：先把鼠标移到房间格子上悬停一下，再点套用", true)
		return
	var report := EditorTemplateLib.apply_to_doc(doc, t, anchor)
	_refresh_inspector()
	_validate_now()
	canvas.queue_redraw()
	var details: Array = report["details"]
	_show_note(str(details[details.size() - 1]) if not details.is_empty() else "已套用模板",
		int(report["skipped"]) > 0)

func _on_template_save() -> void:
	if doc == null or _template_id_edit == null:
		return
	var id := StringName(_template_id_edit.text.strip_edges())
	if String(id) == "":
		_show_note("先给模板起个 id（英文，如 squad_2crawlers）", true)
		return
	var kinds: Array = EditorTemplateLib.KINDS.keys()
	var kind := StringName(str(kinds[_template_kind_picker.selected]))
	var captured := EditorTemplateLib.capture_from_doc(doc, kind)
	if int(captured["count"]) == 0:
		_show_note("当前房间没有这类内容可存（%s）" % str(EditorTemplateLib.KINDS[kind]["label"]), true)
		return
	var res := EditorTemplateLib.save_template(id, kind, captured["payload"], String(id))
	if bool(res["ok"]):
		_show_note("已存模板 %s（%d 项，坐标已相对化）" % [String(id), int(captured["count"])], false)
		_refresh_template_picker()
	else:
		_show_note("模板保存被拒绝：" + "\n".join(res["errors"]), true)

func _on_template_delete() -> void:
	var id := _selected_template_id()
	if String(id) == "":
		_show_note("先选一个模板", true)
		return
	if EditorTemplateLib.delete_template(id):
		_show_note("已删除模板 %s" % String(id), false)
		_refresh_template_picker()
	else:
		_show_note("删除失败：%s" % String(id), true)

func _on_tile_action(tile: Vector2i, erase: bool, rect_mode: bool, rect_end: Vector2i) -> void:
	if rect_mode:
		var changed := doc.fill_obstacles(tile, rect_end, not erase)
		_show_note("矩形%s：%d 格" % ["擦除" if erase else "填充", changed])
	else:
		doc.set_obstacle(tile, not erase)
	_refresh_status()
	_validate_now()
	canvas.queue_redraw()

func _on_entity_clicked(tile: Vector2i, erase: bool) -> void:
	if erase:
		if doc.remove_enemy_at(tile):
			_show_note("删除敌人 @ (%d,%d)" % [tile.x, tile.y])
	else:
		if doc.add_enemy(enemy_type, tile, db):
			_show_note("放置 %s @ (%d,%d)" % [String(enemy_type), tile.x, tile.y])
		else:
			_show_note("放不下：越界或类型非法")
	_refresh_inspector()
	_refresh_status()
	_validate_now()
	canvas.queue_redraw()

## 拾取物工具：左键放置、右键删除（同格只允许一个）
func _on_pickup_action(tile: Vector2i, erase: bool) -> void:
	if erase:
		var idx := doc.pickup_at(tile)
		if idx >= 0:
			doc.remove_pickup(idx)
			_show_note("删除拾取物 @ (%d,%d)" % [tile.x, tile.y])
	else:
		if doc.add_pickup(pickup_kind, tile):
			# 提示按种类给：金币才提磁吸（演示时发现对能力球也写了"金币默认带磁吸"，文案误导）
			var hint := "（金币默认带磁吸，靠近自动飞来）" if pickup_kind == &"gold" else ""
			_show_note("放置 %s @ (%d,%d)%s" % [String(pickup_kind), tile.x, tile.y, hint])
		else:
			_show_note("放不下：越界，或该格已有拾取物", true)
	_refresh_inspector()
	_refresh_status()
	_validate_now()
	canvas.queue_redraw()

## 触发器工具：左键放置（默认 2x2 瓦）、右键删除
func _on_trigger_action(tile: Vector2i, erase: bool) -> void:
	if erase:
		var idx := doc.trigger_at(tile)
		if idx >= 0:
			doc.remove_trigger(idx)
			_show_note("删除触发器 @ (%d,%d)" % [tile.x, tile.y])
	else:
		if doc.add_trigger(trigger_kind, tile, canvas.trigger_size):
			_show_note("放置触发器 %s @ (%d,%d)（尺寸可在右侧调整）" % [String(trigger_kind), tile.x, tile.y])
		else:
			_show_note("放不下：越界或种类非法", true)
	_refresh_inspector()
	_refresh_status()
	_validate_now()
	canvas.queue_redraw()

func _on_undo() -> void:
	if doc.undo():
		_after_edit("已撤销")
	else:
		_show_note("没有可撤销的操作")

func _on_redo() -> void:
	if doc.redo():
		_after_edit("已重做")
	else:
		_show_note("没有可重做的操作")

func _on_reload() -> void:
	var id := doc.room_id
	doc = EditorDoc.load_room(id, db)
	canvas.set_doc(doc)
	_refresh_inspector()
	_validate_now()
	_refresh_status()
	_show_note("已从磁盘重新载入 %s（未保存的修改已被放弃）" % String(id))

func _on_validate() -> void:
	var problems := doc.validate(db)
	if problems.is_empty():
		_show_note("校验通过：可以保存")
	else:
		_show_note("校验发现 %d 个问题（见右侧面板）" % problems.size())
	_validate_now()

func _on_save() -> void:
	_save(false)

## 保存（返回是否成功）；quiet=true 时不弹提示（试玩流程用）
func _save(quiet: bool) -> bool:
	var res := doc.save(db)
	if bool(res["ok"]):
		_validate_now()
		_refresh_status()
		_refresh_room_list()
		if not quiet:
			_show_note("已保存：%s" % str(res["paths"]))
		# 编辑器进程持有资源缓存：改写磁盘 JSON 后扫一次，让文件系统面板/后续读取立即一致
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
		db.load_world()
		return true
	_show_note("保存被拒绝：数据未通过校验")
	_append_problem("\n".join(res["errors"]))
	_dialog.dialog_text = "保存被拒绝（数据不会写入磁盘）：\n\n" + "\n".join(res["errors"])
	_dialog.popup_centered()
	return false

func _toggle_panels() -> void:
	_panels_visible = not _panels_visible
	_room_panel.visible = _panels_visible
	_inspector_panel.visible = _panels_visible
	canvas.fit_view()
	_show_note("左右面板：%s" % ("显示" if _panels_visible else "隐藏（画布已最大化）"))

## 一键试玩：保存 → 写标记（告诉游戏进哪一房）→ 让编辑器启动游戏
func _on_playtest() -> void:
	if not _save(true):
		return
	if not EditorPlaytest.write_marker(doc.room_id):
		_show_note("试玩启动失败：无法写入标记文件")
		return
	_show_note("已保存并启动游戏试玩（直接进入 %s；结束游戏后回到本页）" % String(doc.room_id))
	if Engine.is_editor_hint():
		EditorInterface.play_main_scene()

func _after_edit(note: String) -> void:
	_refresh_inspector()
	_refresh_status()
	_validate_now()
	canvas.queue_redraw()
	_show_note(note)

func _after_geometry_change() -> void:
	canvas.fit_view()
	_validate_now()
	_refresh_status()
	canvas.queue_redraw()

# ============================================================================
# 状态刷新
# ============================================================================
func _validate_now() -> void:
	if _problems == null or doc == null:
		return
	_problems.clear()
	var problems := doc.validate(db)
	if problems.is_empty():
		_problems.append_text("[color=#8fe38f]✓ 数据合规，可以保存[/color]")
	else:
		_problems.append_text("[color=#ff9b9b]✗ %d 个问题（保存会被拒绝）[/color]\n" % problems.size())
		for p in problems:
			_problems.append_text("· %s\n" % p)

func _refresh_status() -> void:
	if _status == null or doc == null:
		return
	var dirty := "未保存 ●" if doc.is_dirty() else "已保存"
	var hover := "(%d,%d)" % [canvas.hover_tile.x, canvas.hover_tile.y] if canvas.inside_room(canvas.hover_tile) else "—"
	_status.text = "%s %s | 碰撞 %d | 敌人 %d | 门 %d | %s | 缩放 %.2fx | 悬停 %s | 撤销 %d | %s" % [
		String(doc.room_id), doc.room_name, doc.obstacle_count(), doc.enemy_total(),
		doc.door_count(), doc.content_summary(), canvas.zoom, hover, doc.undo_depth(), dirty,
	]

func _show_note(text: String, is_error := false) -> void:
	# 1) 可见的提示条（早期版本只设 tooltip + 打印，页面上看不到反馈 ——
	#    实测在编辑器里点了「套用模板」后无从判断成败，属于必须修的可用性缺陷）
	if _note != null:
		_note.text = text
		_note.add_theme_color_override("font_color",
			Color(1.0, 0.62, 0.62) if is_error else Color(0.85, 0.93, 1.0))
	# 2) tooltip 备用（鼠标停状态栏能看到完整文本）
	if _status != null:
		_status.tooltip_text = text
	# 3) 控制台日志 + 落盘（四个页签共用同一份，见 EditorLog）
	EditorLog.note(text, is_error, "关卡")
	# 4) 顺手刷新状态栏：任何"值得提示"的动作都改了数据，
	#    少了这一步状态栏的计数会停在旧值上（上一条缺陷的同源问题）。
	_refresh_status()

func _append_problem(text: String) -> void:
	if _problems != null:
		_problems.append_text("[color=#ffd27f]%s[/color]\n" % text)

## 本房的存档点瓦片（来自 world.json 的 save_points）
func _save_points_of(room_id: StringName) -> Array:
	var out: Array = []
	for raw: Variant in db.save_points:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		if StringName(str(entry.get("room", ""))) != room_id:
			continue
		var t: Variant = entry.get("tile", [])
		if typeof(t) == TYPE_ARRAY and (t as Array).size() >= 2:
			out.append(Vector2i(int(t[0]), int(t[1])))
	return out

# ============================================================================
# 快捷键
# ============================================================================
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var k := event as InputEventKey
	var key := k.physical_keycode
	# 快捷键一律用 Ctrl+Alt+* —— 因为 **Ctrl+S / Ctrl+R 被 Godot 编辑器本体占用**
	# （Ctrl+S = 保存场景！实测按下去只会存场景，插件收不到，容易误以为"保存没反应"）。
	# 见 docs/EDITOR_SMOKE_MANUAL.md 第 5 节。
	if k.ctrl_pressed and k.alt_pressed:
		match key:
			KEY_S:
				_on_save()
			KEY_R:
				_on_reload()
			KEY_V:
				_on_playtest()
		return
	if k.ctrl_pressed:
		match key:
			KEY_Z:
				if k.shift_pressed:
					_on_redo()
				else:
					_on_undo()
			KEY_Y:
				_on_redo()
		return
	match key:
		KEY_1:
			_set_tool(EditorCanvas.Tool.PAINT)
		KEY_2:
			_set_tool(EditorCanvas.Tool.RECT)
		KEY_3:
			_set_tool(EditorCanvas.Tool.ENEMY)
		KEY_4:
			_set_tool(EditorCanvas.Tool.SELECT)
		KEY_5:
			_set_tool(EditorCanvas.Tool.PICKUP)
		KEY_6:
			_set_tool(EditorCanvas.Tool.TRIGGER)
		KEY_DELETE:
			if doc != null and canvas.inside_room(canvas.hover_tile):
				doc.set_obstacle(canvas.hover_tile, false)
				_after_edit("已擦除 %s" % str(canvas.hover_tile))
