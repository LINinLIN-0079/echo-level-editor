@tool
class_name EditorWorldPanel
extends VBoxContainer
## ============================================================================
## EditorWorldPanel —— 插件里的「关卡图」页（可通行性自动校验 + 推演）
## ----------------------------------------------------------------------------
## 它把 WorldReachability 的结论**画出来**，解决的是"单个房间看着都对、整张图走不通"
## 这类只有全局视角才看得见的问题（银河恶魔城最常见的返工原因）。
##
## 界面：
##   顶部  重新载入世界 / 重新分析 / 适应视图 / 假定已获得能力（dash·double_jump 推演开关）
##   左列  结论摘要 + 问题清单（点问题里的房间号可定位）+ 房间清单（点一下定位，双击开房）
##   右侧  关卡图画布（EditorWorldGraph：格子=房间，连线=门，颜色=可达性）
##
## "假定已获得能力"是设计期最有用的推演：
##   例如"如果玩家先拿到了冲刺，还有没有别的地方走不通？" —— 勾一下即可，
##   不需要真的去玩游戏或手改数据。
## ============================================================================

## 由外壳注入：把某房间送去"关卡编辑"页（双击房间时调用）
var on_open_room: Callable = Callable()

var db := WorldDatabase.new()
var graph: EditorWorldGraph = null

var _summary: Label = null
var _problems: RichTextLabel = null
var _room_box: VBoxContainer = null
var _extra_dash := false
var _extra_double_jump := false
var _status: Label = null

func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build_ui()
	reload_world()

# ============================================================================
# 界面
# ============================================================================
func _build_ui() -> void:
	add_child(_build_toolbar())

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 6)
	add_child(middle)

	# ---- 左列 ----
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(320, 0)
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(left_scroll)
	var left_box := VBoxContainer.new()
	left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.add_theme_constant_override("separation", 4)
	left_scroll.add_child(left_box)

	left_box.add_child(_section("结论"))
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_size_override("font_size", 11)
	left_box.add_child(_summary)

	left_box.add_child(_section("问题清单（点击定位）"))
	_problems = RichTextLabel.new()
	_problems.fit_content = true
	_problems.custom_minimum_size = Vector2(0, 120)
	_problems.add_theme_font_size_override("normal_font_size", 11)
	_problems.meta_clicked.connect(_on_problem_clicked)
	left_box.add_child(_problems)

	left_box.add_child(_section("房间清单（单击定位 / 双击开房）"))
	_room_box = VBoxContainer.new()
	_room_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.add_child(_room_box)
	middle.add_child(left)

	# ---- 右侧画布 ----
	graph = EditorWorldGraph.new()
	graph.room_clicked.connect(_on_room_clicked)
	graph.room_activated.connect(_on_room_activated)
	middle.add_child(graph)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

func _build_toolbar() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 32)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	scroll.add_child(bar)

	var title := Label.new()
	title.text = "关卡图（可通行性校验）"
	title.add_theme_font_size_override("font_size", 14)
	bar.add_child(title)
	bar.add_child(VSeparator.new())

	_button(bar, "重新载入世界", _on_reload)
	_button(bar, "重新分析", _on_analyze)
	_button(bar, "适应视图", func() -> void: graph.fit_view())
	_button(bar, "打开选中房", _on_open_selected)

	bar.add_child(VSeparator.new())
	var hint := Label.new()
	hint.text = "假定已获得："
	bar.add_child(hint)
	var dash_check := CheckBox.new()
	dash_check.text = "冲刺"
	dash_check.toggled.connect(func(on: bool) -> void:
		_extra_dash = on
		_on_analyze())
	bar.add_child(dash_check)
	var dj_check := CheckBox.new()
	dj_check.text = "二段跳"
	dj_check.toggled.connect(func(on: bool) -> void:
		_extra_double_jump = on
		_on_analyze())
	bar.add_child(dj_check)
	return scroll

func _button(bar: HBoxContainer, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	bar.add_child(b)
	return b

func _section(title: String) -> Control:
	var l := Label.new()
	l.text = "—— %s ——" % title
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	return l

# ============================================================================
# 数据
# ============================================================================
func reload_world() -> void:
	var ok := db.load_world()
	if not ok:
		_set_status("世界数据加载有问题：\n" + db.problem_summary(), true)
	_on_analyze()
	graph.fit_view()
	_refresh_room_list()

## 当前推演假定的额外能力
func extra_abilities() -> Array:
	var out: Array = []
	if _extra_dash:
		out.append(&"dash")
	if _extra_double_jump:
		out.append(&"double_jump")
	return out

func _on_reload() -> void:
	reload_world()
	_set_status("已重新载入世界数据（%d 个房间）" % db.room_count(), false)

func _on_analyze() -> void:
	var extras := extra_abilities()
	var report := WorldReachability.analyze(db, extras)
	graph.db = db
	graph.analysis = report
	graph.queue_redraw()
	_refresh_summary(report, extras)
	_refresh_problems(report)
	_set_status("分析完成：%s" % WorldReachability.report_line(db), not (report["problems"] as Array).is_empty())

func _refresh_summary(report: Dictionary, extras: Array) -> void:
	var visited: Array = report["visited"]
	var abilities: Array = report["abilities"]
	var parts: Array[String] = []
	parts.append("可达 %d / %d 房间" % [visited.size(), db.room_count()])
	parts.append("终点房 %s" % ("可达" if bool(report["terminal_ok"]) else "不可达"))
	var abil: Array[String] = []
	for a: Variant in abilities:
		abil.append(String(a))
	parts.append("能力：%s" % ("+".join(abil) if not abil.is_empty() else "无"))
	if not extras.is_empty():
		var ex: Array[String] = []
		for e: Variant in extras:
			ex.append(String(e))
		parts.append("（推演假定已获得：%s）" % "+".join(ex))
	_summary.text = "\n".join(parts)
	_summary.add_theme_color_override("font_color",
		Color(1.0, 0.65, 0.65) if not (report["problems"] as Array).is_empty() else Color(0.8, 0.95, 0.85))

func _refresh_problems(report: Dictionary) -> void:
	_problems.clear()
	var problems: Array = report["problems"]
	if problems.is_empty():
		_problems.append_text("[color=#8fe38f]✓ 世界健康：没有可通行性问题[/color]")
		return
	_problems.append_text("[color=#ff9b9b]✗ %d 个可通行性问题：[/color]\n" % problems.size())
	for p: Variant in problems:
		# 把房间号做成可点链接（点一下把画布定位过去）
		# 注意：只替换一次，别再对已生成的 [url=...] 标记做二次替换（否则会套出 [[url=…]]）
		var text := str(p)
		for room in db.rooms:
			text = text.replace(String(room.id),
				"[url=%s]%s[/url]" % [String(room.id), String(room.id)])
		_problems.append_text("· %s\n" % text)

func _refresh_room_list() -> void:
	for c in _room_box.get_children():
		c.queue_free()
	for room in db.rooms:
		var b := Button.new()
		b.text = "R%02d %s%s%s" % [room.ordinal, room.name,
			"  ★" if room.is_boss else "",
			"" if room.ability_reward == &"" else "  [%s]" % String(room.ability_reward)]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 11)
		var rid := room.id
		b.pressed.connect(func() -> void:
			graph.center_on(rid)
			_set_status("已定位 R%02d %s" % [db.get_room(rid).ordinal, db.get_room(rid).name], false))
		b.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and (event as InputEventMouseButton).double_click:
				_on_room_activated(rid))
		_room_box.add_child(b)

# ============================================================================
# 交互
# ============================================================================
func _on_room_clicked(room_id: StringName) -> void:
	var room := db.get_room(room_id)
	if room == null:
		return
	_set_status("R%02d %s ｜ 敌人 %d ｜ 金币 %d ｜ %s" % [room.ordinal, room.name,
		room.total_enemies(), room.gold_drop, WorldReachability.room_summary(db, room_id).get("exits", [])], false)

func _on_room_activated(room_id: StringName) -> void:
	if on_open_room.is_valid():
		on_open_room.call(room_id)
		_set_status("已把 R%02d 送到「关卡编辑」页" % db.get_room(room_id).ordinal, false)
	else:
		_set_status("（没有接上「关卡编辑」页）", true)

func _on_open_selected() -> void:
	if graph.selected == &"":
		_set_status("先在图上点一个房间", true)
		return
	_on_room_activated(graph.selected)

func _on_problem_clicked(meta: Variant) -> void:
	var rid := StringName(str(meta))
	if db.get_room(rid) == null:
		return
	graph.center_on(rid)
	_set_status("已定位到问题房间 %s" % String(rid), true)

func _set_status(text: String, is_error: bool) -> void:
	if _status != null:
		_status.text = text
		_status.add_theme_color_override("font_color",
			Color(1.0, 0.7, 0.7) if is_error else Color(0.85, 0.9, 0.95))
	EditorLog.note(text, is_error, "关卡图")
