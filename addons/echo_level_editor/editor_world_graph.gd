@tool
class_name EditorWorldGraph
extends Control
## ============================================================================
## EditorWorldGraph —— 关卡图画布（按 room.grid 把 30 个房间铺成一张图）
## ----------------------------------------------------------------------------
## 为什么值得做：银河恶魔城的关卡设计错误几乎都不是"某个房间画错了"，而是
## **房间之间的连通关系错了** —— 门指向不存在的房、能力门控排在了能力之前、
## 有房间永远走不到。这类错误看单房 JSON 是看不出来的，必须看"整张图"。
##
## 画法：
##   * 每个房间按其 world.json 里的 grid 坐标铺成一个格子（格子大小 = cell_size()）；
##   * 房间之间的门画成连线，带门控的边标上能力名；
##   * 颜色直接表达结论：绿=可达 / 红=永远到不了 / 黄边=Boss 房 / 蓝边=起点 / 金边=终点；
##   * 鼠标点击房间 → 发 room_clicked 信号（外壳据此开这一房或跳到关卡编辑页）。
##
## 与 EditorCanvas 一致：只负责"画 + 把鼠标位置翻译成房间"，不改任何数据。
## ============================================================================

signal room_clicked(room_id: StringName)
signal room_activated(room_id: StringName)      ## 双击

## 一个房间格的基准尺寸与间距（缩放前）
const CELL := Vector2(46.0, 34.0)
const GAP := Vector2(8.0, 12.0)

const COLOR_REACHABLE := Color(0.28, 0.62, 0.42)
const COLOR_UNREACHABLE := Color(0.62, 0.24, 0.24)
const COLOR_BOSS := Color(0.55, 0.42, 0.85)
const COLOR_START := Color(0.30, 0.62, 0.95)
const COLOR_TERMINAL := Color(0.95, 0.78, 0.30)
const COLOR_EDGE := Color(0.62, 0.68, 0.76)
const COLOR_EDGE_GATED := Color(0.95, 0.62, 0.30)
const COLOR_EDGE_BROKEN := Color(0.95, 0.35, 0.35)
const COLOR_TEXT := Color(0.92, 0.95, 0.98)

var db: WorldDatabase = null
## WorldReachability.analyze() 的结果（着色依据）
var analysis: Dictionary = {}
var zoom := 1.0
var pan := Vector2.ZERO
var hover := StringName("")
var selected := StringName("")

var _panning := false
var _pan_last := Vector2.ZERO

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true

# ============================================================================
# 坐标换算（纯函数，便于单测）
# ============================================================================
## 一个房间格在画布上的尺寸（含间距）
static func cell_size() -> Vector2:
	return CELL + GAP

## 房间 grid → 画布矩形（zoom/pan 前是"世界坐标"）
static func grid_rect(grid: Vector2i, grid_size: Vector2i) -> Rect2:
	var c := cell_size()
	return Rect2(Vector2(float(grid.x) * c.x, float(grid.y) * c.y),
		Vector2(maxf(float(grid_size.x), 1.0) * CELL.x + (maxf(float(grid_size.x), 1.0) - 1.0) * GAP.x,
			maxf(float(grid_size.y), 1.0) * CELL.y + (maxf(float(grid_size.y), 1.0) - 1.0) * GAP.y))

func world_to_canvas(world: Vector2) -> Vector2:
	return world * zoom + pan

func canvas_to_world(canvas: Vector2) -> Vector2:
	return (canvas - pan) / maxf(zoom, 0.0001)

## 整个图的包围盒（世界坐标）
func world_bounds() -> Rect2:
	if db == null or db.rooms.is_empty():
		return Rect2()
	var box := grid_rect(db.rooms[0].grid, db.rooms[0].grid_size)
	for room in db.rooms:
		box = box.merge(grid_rect(room.grid, room.grid_size))
	return box

## 某房间在画布上的矩形（含 zoom/pan）
func room_canvas_rect(room: WorldDatabase.Room) -> Rect2:
	var r := grid_rect(room.grid, room.grid_size)
	return Rect2(world_to_canvas(r.position), r.size * zoom)

## 适应视图：把整张图居中放进控件
func fit_view() -> void:
	if db == null or db.rooms.is_empty():
		return
	var box := world_bounds()
	var avail := size
	if avail.x <= 1.0 or avail.y <= 1.0:
		avail = Vector2(640, 360)
	zoom = clampf(minf(avail.x / maxf(box.size.x + 40.0, 1.0), avail.y / maxf(box.size.y + 40.0, 1.0)), 0.2, 3.0)
	pan = (avail - box.size * zoom) * 0.5 - box.position * zoom
	queue_redraw()

## 把某个房间居中（点房间清单时用）
func center_on(room_id: StringName) -> void:
	if db == null:
		return
	var room := db.get_room(room_id)
	if room == null:
		return
	var r := grid_rect(room.grid, room.grid_size)
	var target_world := r.position + r.size * 0.5
	pan = size * 0.5 - target_world * zoom
	selected = room_id
	queue_redraw()

# ============================================================================
# 输入
# ============================================================================
func _gui_input(event: InputEvent) -> void:
	if db == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := canvas_to_world(mb.position)
			zoom = clampf(zoom * (1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.9), 0.2, 4.0)
			pan = mb.position - before * zoom
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_panning = true
				_pan_last = mb.position
				var hit := room_at_canvas(mb.position)
				if hit != &"":
					selected = hit
					room_clicked.emit(hit)
					queue_redraw()
			else:
				if _panning:
					_panning = false
				if mb.double_click:
					var hit2 := room_at_canvas(mb.position)
					if hit2 != &"":
						room_activated.emit(hit2)
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			pan += mm.position - _pan_last
			_pan_last = mm.position
			queue_redraw()
			return
		var h := room_at_canvas(mm.position)
		if h != hover:
			hover = h
			tooltip_text = _room_tooltip(h)
			queue_redraw()

## 画布坐标 → 房间 id（命中测试；空表示没点到）
func room_at_canvas(pos: Vector2) -> StringName:
	if db == null:
		return &""
	# 逆序遍历：后画的在上层
	for i in range(db.rooms.size() - 1, -1, -1):
		var room: WorldDatabase.Room = db.rooms[i]
		if room_canvas_rect(room).has_point(pos):
			return room.id
	return &""

func _room_tooltip(room_id: StringName) -> String:
	if db == null or room_id == &"":
		return ""
	var room := db.get_room(room_id)
	if room == null:
		return ""
	var reach := _is_reachable(room_id)
	var lines: Array[String] = []
	lines.append("R%02d %s（%s）" % [room.ordinal, room.name, "可达" if reach else "永远到不了"])
	lines.append("区域 %s ｜ 敌人 %d ｜ 金币 %d" % [String(room.zone), room.total_enemies(), room.gold_drop])
	if room.is_boss:
		lines.append("BOSS 房，掉落：%s" % String(room.ability_reward))
	for d in room.doors:
		var gate := "（无门控）" if d.gate == &"" else "（需要 %s）" % String(d.gate)
		lines.append("→ %s%s" % [String(d.to), gate])
	return "\n".join(lines)

# ============================================================================
# 绘制
# ============================================================================
func _draw() -> void:
	if db == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.11, 0.13), true)

	# ---- 门（先画边，房间盖在上面）----
	for room in db.rooms:
		var from_rect := room_canvas_rect(room)
		for d in room.doors:
			var target := db.get_room(d.to)
			if target == null:
				# 指向不存在的房间：从房间引一条向右下的红线示意
				var p := from_rect.get_center()
				draw_line(p, p + Vector2(40, 26), COLOR_EDGE_BROKEN, 2.0)
				continue
			var to_rect := room_canvas_rect(target)
			var a := from_rect.get_center()
			var b := to_rect.get_center()
			var gated := d.gate != &""
			var broken := _is_reachable(room.id) and not _is_reachable(d.to)
			var color := COLOR_EDGE_GATED if gated else COLOR_EDGE
			if broken:
				color = COLOR_EDGE_BROKEN
			draw_line(a, b, color, 2.0 if gated else 1.0)
			if gated and zoom >= 0.6:
				var font: Font = ThemeDB.fallback_font
				if font != null:
					var mid := (a + b) * 0.5
					var label := String(d.gate)
					draw_string(font, mid + Vector2(2, -2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color)

	# ---- 房间格 ----
	for room in db.rooms:
		var r := room_canvas_rect(room)
		var reachable := _is_reachable(room.id)
		var fill := COLOR_REACHABLE if reachable else COLOR_UNREACHABLE
		draw_rect(r, Color(fill.r, fill.g, fill.b, 0.55), true)
		var border := fill
		var width := 1.0
		if room.id == db.start_room:
			border = COLOR_START
			width = 2.0
		if room.id == db.terminal_room:
			border = COLOR_TERMINAL
			width = 2.0
		if room.is_boss:
			border = COLOR_BOSS
			width = 2.0
		if room.id == selected:
			border = Color.WHITE
			width = 2.0
		draw_rect(r, border, false, width)

		# 文字：房间号 +（可达/不可达）+ Boss 掉落能力
		var font2: Font = ThemeDB.fallback_font
		if font2 != null and r.size.x > 26.0:
			draw_string(font2, r.position + Vector2(3, 11), "R%02d" % room.ordinal,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_TEXT)
			if room.is_boss and room.ability_reward != &"":
				draw_string(font2, r.position + Vector2(3, 22), String(room.ability_reward).substr(0, 6),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 9, COLOR_BOSS)
			elif not reachable:
				draw_string(font2, r.position + Vector2(3, 22), "X",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 9, COLOR_UNREACHABLE)

## 该房间是否在可达集合里（analysis 为空时按"未知=可达"处理，避免整图刷红）
func _is_reachable(room_id: StringName) -> bool:
	if analysis.is_empty():
		return true
	for v: Variant in analysis.get("visited", []):
		if StringName(str(v)) == room_id:
			return true
	return false
