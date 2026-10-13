@tool
class_name EditorBtPanel
extends VBoxContainer
## ============================================================================
## EditorBtPanel —— 行为树编辑器界面（插件里的「敌人 AI」页）
## ----------------------------------------------------------------------------
## 自身就是 VBoxContainer：父级 TabContainer 会把页签内容撑满，子控件自动纵向排列
## （用普通 Control + 锚点会踩到"子节点不自动填充"的坑，见 editor_screen.gd 的说明）。
##
## 傻瓜式的具体体现：**界面里没有任何一个节点类型的硬编码**。
##   调色板   ← BTLibrary.catalog_by_category()（分类 + 中文标题）
##   参数表单 ← 目录条目的 params[{key,type,default,hint}]（按 type 自动出控件）
##   合法性   ← 目录条目的 min_children / max_children
## 因此将来新增一种行为（加一个叶子类 + 库里一行），这个界面自动就支持了，零 UI 改动。
##
## 界面：
##   左   敌人列表（data/ai/*.json）
##   中   行为树（Tree 控件，缺子节点的节点标红）+ 编辑工具条
##   右   选中节点的参数表单 + 节点名 + 顶层注释
##   底   摘要（节点数/深度/校验结果）；错误红字、警告黄字
##
## 编辑动作全部走 EditorBtDoc（快照撤销 + 校验 + 原子写），本文件只负责"翻译 UI 事件"。
## ============================================================================

var doc: EditorBtDoc = null

var _enemy_box: VBoxContainer = null
var _tree: Tree = null
var _params_box: VBoxContainer = null
var _status: Label = null
var _note: Label = null          ## 最近一次操作的可见反馈（红字=错误）
var _title: Label = null
var _dialog: AcceptDialog = null
var _name_edit: LineEdit = null
var _comment_edit: TextEdit = null
var _add_menu: MenuButton = null
var _retype_menu: MenuButton = null
var _undo_btn: Button = null
var _redo_btn: Button = null

## 调色板 id → 节点类型（两个菜单共用一份映射）
var _palette: Dictionary = {}
var _selected: Array = []
var _param_widgets: Dictionary = {}

# ============================================================================
# 启动
# ============================================================================
func _ready() -> void:
	_build_ui()
	var types := EditorBtDoc.available_types()
	if types.is_empty():
		_set_status("没有找到 data/ai/*.json", true)
		return
	_load_enemy(StringName(str(types[0])))

func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	var root := HBoxContainer.new()
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# ---------------- 左：敌人列表 ----------------
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(150, 0)
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(left_scroll)
	_enemy_box = VBoxContainer.new()
	_enemy_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(_enemy_box)
	root.add_child(left)

	# ---------------- 中：树 + 工具条 ----------------
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 4)
	root.add_child(mid)
	mid.add_child(_build_tree_toolbar())
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(360, 0)
	_tree.columns = 1
	_tree.hide_root = false
	_tree.select_mode = Tree.SELECT_ROW
	_tree.item_selected.connect(_on_tree_selected)
	mid.add_child(_tree)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 11)
	mid.add_child(_title)

	# ---------------- 右：参数表单 ----------------
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(290, 0)
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(right_scroll)
	_params_box = VBoxContainer.new()
	_params_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_params_box.add_theme_constant_override("separation", 4)
	right_scroll.add_child(_params_box)
	root.add_child(right)

	# ---------------- 底：提示条 + 状态 ----------------
	# 提示条（第 30 轮补）：原来本页只有日志、页面内看不到"刚点了什么、成没成"，
	# 与关卡页的可见提示条对齐（真机点击验证手册要求每页都有可见反馈）。
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 11)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.text = "提示会显示在这里（最近一次操作的结果）"
	_note.add_theme_color_override("font_color", Color(0.75, 0.8, 0.86))
	add_child(_note)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_dialog = AcceptDialog.new()
	_dialog.title = "提示"
	add_child(_dialog)

func _build_tree_toolbar() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 32)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	scroll.add_child(bar)

	_undo_btn = _button(bar, "撤销", _on_undo)
	_redo_btn = _button(bar, "重做", _on_redo)
	_add_menu = MenuButton.new()
	_add_menu.text = "添加子节点"
	_fill_palette(_add_menu.get_popup())
	_add_menu.get_popup().id_pressed.connect(_on_add_child)
	bar.add_child(_add_menu)
	_retype_menu = MenuButton.new()
	_retype_menu.text = "改类型"
	_fill_palette(_retype_menu.get_popup())
	_retype_menu.get_popup().id_pressed.connect(_on_retype)
	bar.add_child(_retype_menu)
	_button(bar, "上移", func() -> void: _move(-1))
	_button(bar, "下移", func() -> void: _move(1))
	_button(bar, "复制子树", _on_duplicate)
	_button(bar, "删除", _on_delete)
	_button(bar, "精简默认值", _on_prune)
	_button(bar, "校验", _on_validate)
	_button(bar, "保存", _on_save)
	_button(bar, "重新载入", _on_reload)
	return scroll

func _button(bar: HBoxContainer, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	bar.add_child(b)
	return b

## 用节点目录填菜单（分类分隔线 + 中文标题）
func _fill_palette(popup: PopupMenu) -> void:
	popup.clear()
	_palette.clear()
	var id := 1
	var by_cat := BTLibrary.catalog_by_category()
	for cat: Variant in by_cat.keys():
		popup.add_separator(String(cat))
		for e: Variant in by_cat[cat]:
			var entry: Dictionary = e
			popup.add_item(str(entry["title"]), id)
			_palette[id] = str(entry["type"])
			id += 1

# ============================================================================
# 载入
# ============================================================================
func _load_enemy(type_id: StringName) -> void:
	if doc != null and doc.is_dirty():
		_dialog.dialog_text = "「%s」还有未保存的修改，请先保存或用「重新载入」放弃。" % String(doc.type_id)
		_dialog.popup_centered()
		return
	doc = EditorBtDoc.load_doc(type_id)
	_selected = []
	_refresh_enemy_list()
	_refresh_tree()
	_refresh_params()
	_refresh_status()
	_set_status("已载入 %s（%s）" % [String(type_id), doc.file_path], false)

func _refresh_enemy_list() -> void:
	for c in _enemy_box.get_children():
		c.queue_free()
	var head := Label.new()
	head.text = "敌人 AI"
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	_enemy_box.add_child(head)
	for t: Variant in EditorBtDoc.available_types():
		var tid := StringName(str(t))
		var b := Button.new()
		b.text = String(tid)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = doc != null and doc.type_id == tid
		b.pressed.connect(func() -> void: _load_enemy(tid))
		_enemy_box.add_child(b)

# ============================================================================
# 树视图
# ============================================================================
func _refresh_tree() -> void:
	_tree.clear()
	if doc == null:
		return
	var root_item := _tree.create_item()
	_build_tree_item(root_item, [], true)
	# 恢复选中
	_restore_selection(_tree.get_root(), _selected)

func _build_tree_item(item: TreeItem, path: Array, is_root: bool) -> void:
	var t := doc.type_of(path)
	var title := EditorBtDoc.title_for(t)
	var node_name := doc.name_of(path)
	var label := title
	if node_name != "":
		label = "%s  「%s」" % [title, node_name]
	var missing := EditorBtDoc.missing_children(t, doc.children_of(path).size())
	if missing > 0:
		label += "   ⚠ 还缺 %d 个子节点" % missing
	item.set_text(0, label)
	item.set_metadata(0, path.duplicate())
	item.set_custom_color(0, Color(1.0, 0.55, 0.55) if missing > 0 else
		(Color(0.75, 0.85, 1.0) if is_root else Color(0.9, 0.9, 0.9)))
	for i in doc.children_of(path).size():
		var child := _tree.create_item(item)
		_build_tree_item(child, path + [i], false)

func _restore_selection(item: TreeItem, path: Array) -> void:
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta is Array and str(meta) == str(path):
		item.select(0)
		return
	var child := item.get_first_child()
	while child != null:
		_restore_selection(child, path)
		child = child.get_next()

func _on_tree_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	_selected = (meta as Array).duplicate() if meta is Array else []
	_refresh_params()
	_refresh_title()

func _refresh_title() -> void:
	if doc == null:
		return
	if _selected.is_empty():
		_title.text = "（根节点）"
	else:
		_title.text = "选中：%s" % _path_text(_selected)

func _path_text(path: Array) -> String:
	if path.is_empty():
		return "根"
	var parts: Array[String] = []
	for seg: Variant in path:
		parts.append(str(seg))
	return "根/" + "/".join(parts)

# ============================================================================
# 参数表单（按目录自动生成）
# ============================================================================
func _refresh_params() -> void:
	for c in _params_box.get_children():
		c.queue_free()
	_param_widgets.clear()
	_name_edit = null
	if doc == null or _selected.is_empty():
		var tip := Label.new()
		tip.text = "选中左侧树里的一个节点即可编辑它的参数。"
		tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_params_box.add_child(tip)
		# 顶层注释始终可编辑（它是"这棵树的用途"说明）
		_params_box.add_child(_section("整棵树的注释（写进 JSON 的 _comment）"))
		_comment_edit = TextEdit.new()
		_comment_edit.custom_minimum_size = Vector2(0, 60)
		_comment_edit.text = doc.comment()
		_comment_edit.focus_exited.connect(func() -> void:
			if doc.set_comment(_comment_edit.text):
				_set_status("已更新注释", false))
		_params_box.add_child(_comment_edit)
		return

	var t := doc.type_of(_selected)
	var entry := EditorBtDoc.entry_for(t)
	_params_box.add_child(_section("%s" % str(entry.get("title", t))))
	_params_box.add_child(_hint("类型：%s（%s）" % [t, str(entry.get("category", "?"))]))
	var minc := int(entry.get("min_children", 0))
	var maxc := int(entry.get("max_children", -1))
	_params_box.add_child(_hint("子节点：%d 个（要求 %d ~ %s）"
		% [doc.children_of(_selected).size(), minc, "不限" if maxc < 0 else str(maxc)]))

	# 节点名
	var name_row := HBoxContainer.new()
	var nl := Label.new()
	nl.text = "节点名"
	nl.custom_minimum_size = Vector2(74, 0)
	name_row.add_child(nl)
	_name_edit = LineEdit.new()
	_name_edit.text = doc.name_of(_selected)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(_on_name_submitted)
	_name_edit.focus_exited.connect(func() -> void: _on_name_submitted(_name_edit.text))
	name_row.add_child(_name_edit)
	_params_box.add_child(name_row)

	# 参数
	var params: Array = entry.get("params", [])
	if params.is_empty():
		_params_box.add_child(_hint("（该节点没有参数）"))
	for p: Variant in params:
		var pd: Dictionary = p
		var key := str(pd["key"])
		var kind := str(pd.get("type", "any"))
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = key
		lbl.custom_minimum_size = Vector2(74, 0)
		lbl.tooltip_text = str(pd.get("hint", ""))
		row.add_child(lbl)
		var widget := _make_param_widget(key, kind, pd)
		row.add_child(widget)
		_params_box.add_child(row)
		if str(pd.get("hint", "")) != "":
			_params_box.add_child(_hint("   ↳ %s" % str(pd["hint"])))

func _make_param_widget(key: String, kind: String, pd: Dictionary) -> Control:
	var current: Variant = doc.get_param(_selected, key, pd.get("default", null))
	match kind:
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(current)
			cb.toggled.connect(func(on: bool) -> void: _apply_param(key, on))
			_param_widgets[key] = cb
			return cb
		"int":
			var si := SpinBox.new()
			si.step = 1
			si.min_value = -9999
			si.max_value = 9999
			si.value = float(current)
			si.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			si.value_changed.connect(func(v: float) -> void: _apply_param(key, int(v)))
			_param_widgets[key] = si
			return si
		"float":
			var sf := SpinBox.new()
			sf.step = 0.05
			sf.min_value = -99999
			sf.max_value = 99999
			sf.value = float(current)
			sf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sf.value_changed.connect(func(v: float) -> void: _apply_param(key, v))
			_param_widgets[key] = sf
			return sf
		"enum":
			var ob := OptionButton.new()
			var options := _enum_options(str(pd.get("hint", "")))
			if options.is_empty():
				options = [str(current)]
			for o: Variant in options:
				ob.add_item(String(o))
			ob.selected = maxi(options.find(str(current)), 0)
			ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ob.item_selected.connect(func(idx: int) -> void: _apply_param(key, options[idx]))
			_param_widgets[key] = ob
			return ob
		"array":
			var la := LineEdit.new()
			la.text = _array_to_text(current)
			la.tooltip_text = "逗号分隔的数字，如 1, 2, 0.5"
			la.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			la.text_submitted.connect(func(v: String) -> void: _apply_param(key, _text_to_array(v)))
			la.focus_exited.connect(func() -> void: _apply_param(key, _text_to_array(la.text)))
			_param_widgets[key] = la
			return la
		"string":
			var ls := LineEdit.new()
			ls.text = str(current)
			ls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ls.text_submitted.connect(func(v: String) -> void: _apply_param(key, v))
			ls.focus_exited.connect(func() -> void: _apply_param(key, ls.text))
			_param_widgets[key] = ls
			return ls
		_:
			# any：允许直接写 true / 12 / 0.5 / 文本（自动识别类型）
			var lx := LineEdit.new()
			lx.text = str(current)
			lx.tooltip_text = "任意值：true / false / 数字 / 文本"
			lx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lx.text_submitted.connect(func(v: String) -> void: _apply_param(key, _text_to_any(v)))
			lx.focus_exited.connect(func() -> void: _apply_param(key, _text_to_any(lx.text)))
			_param_widgets[key] = lx
			return lx

## 从 hint 里解析枚举候选："set / add / toggle" 或 ">= <= > < == !=" 或 "dash / double_jump / melee"
func _enum_options(hint: String) -> Array:
	if hint.contains("/"):
		var out: Array = []
		for part in hint.split("/"):
			var s := part.strip_edges()
			if s != "":
				out.append(s)
		return out
	if hint.contains(" ") and not hint.contains("，") and hint.length() <= 40:
		var out2: Array = []
		for part in hint.split(" "):
			var s2 := part.strip_edges()
			if s2 != "":
				out2.append(s2)
		return out2
	return []

func _apply_param(key: String, value: Variant) -> void:
	if doc == null or _selected.is_empty():
		return
	if doc.set_param(_selected, key, value):
		_refresh_status()

func _on_name_submitted(text: String) -> void:
	if doc == null or _selected.is_empty():
		return
	if doc.set_node_name(_selected, text):
		_refresh_tree()
		_refresh_title()
		_refresh_status()

# ============================================================================
# 编辑动作
# ============================================================================
func _on_add_child(id: int) -> void:
	if doc == null:
		return
	if not _palette.has(id):
		return
	var target := _selected
	var type_name := str(_palette[id])
	var new_path := doc.add_node(target, type_name)
	if new_path.is_empty():
		_set_status("加不了：该节点已有上限数量的子节点，或类型非法", true)
		return
	_selected = new_path
	_refresh_tree()
	_refresh_params()
	_refresh_status()
	_set_status("已添加 %s" % EditorBtDoc.title_for(type_name), false)

func _on_retype(id: int) -> void:
	if doc == null or _selected.is_empty() or not _palette.has(id):
		return
	var type_name := str(_palette[id])
	if doc.set_type(_selected, type_name):
		_refresh_tree()
		_refresh_params()
		_refresh_status()
		_set_status("已改为 %s（参数按目录补齐）" % EditorBtDoc.title_for(type_name), false)

func _on_delete() -> void:
	if doc == null or _selected.is_empty():
		_set_status("根节点不能删除；请先选中一个子节点", true)
		return
	var old := _selected.duplicate()
	if doc.remove_node(_selected):
		_selected = old.slice(0, maxi(old.size() - 1, 0))
		_refresh_tree()
		_refresh_params()
		_refresh_status()
		_set_status("已删除节点", false)

## 复制整棵子树（含子节点）到同级后面 —— 搭"三阶段 Boss"这类重复结构时非常省事
func _on_duplicate() -> void:
	if doc == null or _selected.is_empty():
		_set_status("请先选中要复制的节点（根节点不可复制）", true)
		return
	var new_path := doc.duplicate_node(_selected)
	if new_path.is_empty():
		_set_status("复制失败：同级已达子节点上限", true)
		return
	_selected = new_path
	_refresh_tree()
	_refresh_params()
	_refresh_status()
	_set_status("已复制子树（%d 个节点）" % doc.count_subtree(_selected), false)

func _move(delta: int) -> void:
	if doc == null or _selected.is_empty():
		return
	if doc.move_node(_selected, delta):
		var last := int(_selected[_selected.size() - 1]) + delta
		_selected = _selected.slice(0, _selected.size() - 1) + [last]
		_refresh_tree()
		_refresh_status()
	else:
		_set_status("已经在边界上了", true)

func _on_prune() -> void:
	if doc == null:
		return
	var n := doc.prune_defaults()
	_refresh_tree()
	_refresh_params()
	_refresh_status()
	_set_status("精简掉 %d 个与默认值相同的参数" % n, false)

func _on_undo() -> void:
	if doc != null and doc.undo():
		_refresh_tree()
		_refresh_params()
		_refresh_status()
		_set_status("已撤销", false)

func _on_redo() -> void:
	if doc != null and doc.redo():
		_refresh_tree()
		_refresh_params()
		_refresh_status()
		_set_status("已重做", false)

func _on_validate() -> void:
	if doc == null:
		return
	_refresh_status()
	var v := doc.validate()
	if (v["errors"] as Array).is_empty():
		_set_status("校验通过：%s" % doc.summary(), false)
	else:
		_set_status("校验发现 %d 个错误（见下方列表）" % (v["errors"] as Array).size(), true)

func _on_save() -> void:
	if doc == null:
		return
	var res := doc.save()
	if bool(res["ok"]):
		_set_status("已保存 %s（节点 %d 个）" % [str(res["paths"][0]), int(res["nodes"])], false)
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
		_refresh_enemy_list()
	else:
		_set_status("保存被拒绝：" + "\n".join(res["errors"]), true)

func _on_reload() -> void:
	if doc == null:
		return
	var t := doc.type_id
	doc = EditorBtDoc.load_doc(t)
	_selected = []
	_refresh_tree()
	_refresh_params()
	_refresh_status()
	_set_status("已从磁盘重新载入 %s" % String(t), false)

# ============================================================================
# 状态与小组件
# ============================================================================
func _refresh_status() -> void:
	if doc == null:
		return
	if _undo_btn != null:
		_undo_btn.disabled = not doc.can_undo()
	if _redo_btn != null:
		_redo_btn.disabled = not doc.can_redo()
	var v := doc.validate()
	var lines: Array[String] = []
	lines.append("%s ｜ %s%s" % [String(doc.type_id), doc.summary(),
		"（未保存 ●）" if doc.is_dirty() else ""])
	for e: Variant in v["errors"]:
		lines.append("✗ %s" % str(e))
	for w: Variant in v["warnings"]:
		lines.append("· %s" % str(w))
	_status.text = "\n".join(lines)
	_status.add_theme_color_override("font_color",
		Color(1.0, 0.6, 0.6) if not (v["errors"] as Array).is_empty() else Color(0.85, 0.9, 0.95))

func _set_status(text: String, is_error: bool) -> void:
	# 可见提示条（与关卡页同款）+ 统一日志
	if _note != null:
		_note.text = text
		_note.add_theme_color_override("font_color",
			Color(1.0, 0.62, 0.62) if is_error else Color(0.85, 0.93, 1.0))
	EditorLog.note(text, is_error, "敌人AI")

func _section(title: String) -> Control:
	var l := Label.new()
	l.text = "—— %s ——" % title
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	return l

func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", Color(0.72, 0.78, 0.85))
	return l

func _array_to_text(value: Variant) -> String:
	if not (value is Array):
		return ""
	var parts: Array[String] = []
	for v: Variant in value:
		parts.append(str(v))
	return ", ".join(parts)

func _text_to_array(text: String) -> Array:
	var out: Array = []
	for part in text.split(","):
		var s := part.strip_edges()
		if s == "":
			continue
		out.append(float(s) if s.is_valid_float() else (int(s) if s.is_valid_int() else s))
	return out

func _text_to_any(text: String) -> Variant:
	var s := text.strip_edges()
	if s.to_lower() == "true":
		return true
	if s.to_lower() == "false":
		return false
	if s.is_valid_int():
		return int(s)
	if s.is_valid_float():
		return float(s)
	return s
