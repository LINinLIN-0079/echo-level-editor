class_name EditorCanvas
extends Control
## ============================================================================
## EditorCanvas —— 编辑器画布（网格 / 碰撞体积 / 实体 / 门 / 地板 + 缩放平移 + 工具交互）
## ----------------------------------------------------------------------------
## 职责边界：**只画 + 只把鼠标位置翻译成瓦片坐标**，然后通过信号把"用户想做什么"
## 抛给外壳（level_editor.gd）。所有数据改动都由外壳调用 EditorDoc 完成，
## 因此撤销栈、校验、保存都只有一条路径 —— 画布永远不会偷偷改数据。
##
## 坐标系：世界像素 ↔ 画布像素（含缩放与平移）
##   canvas_px = world_px * zoom + pan
##   瓦片 = world_px / TILE
##
## 交互约定（与主流 2D 关卡编辑器一致，玩家一看就会）：
##   左键  = 用当前工具"放置"（画笔/矩形/敌人/拾取物/触发器）
##   右键  = "擦除"（擦碰撞体积 / 删敌人 / 删拾取物 / 删触发器）
##   中键拖动 或 空格+左键拖动 = 平移视图
##   **左键长按 0.3 秒再拖 = 平移视图**（第 45 轮用户要求："鼠标长按拖放切换视角"）
##   **`✋ 平移` 工具（7）= 左键拖动即平移**（最直观、零风险）
##   滚轮  = 以鼠标为中心缩放
## ============================================================================

signal tile_action(tile: Vector2i, erase: bool, rect_mode: bool, rect_end: Vector2i)
signal entity_clicked(tile: Vector2i, erase: bool)
signal pickup_action(tile: Vector2i, erase: bool)
signal trigger_action(tile: Vector2i, erase: bool)
signal view_changed()

## 工具枚举（外壳切换）
enum Tool { PAINT, RECT, ENEMY, SELECT, PICKUP, TRIGGER, PAN }

## 长按判定：按住不动超过它 → 转成"平移"而不是"画"
const LONG_PRESS_MS := 300
const LONG_PRESS_SLOP := 4.0

var doc: EditorDoc = null
var tool: int = Tool.PAINT
var zoom := 2.0
var pan := Vector2.ZERO
## 待放置的敌人类型（ENEMY 工具用）
var enemy_type: StringName = &"crawler"
## 待放置的拾取物/触发器种类与尺寸（PICKUP / TRIGGER 工具用）
var pickup_kind: StringName = &"gold"
var trigger_kind: StringName = &"message"
var trigger_size := Vector2i(2, 2)
## 门编辑模式（点击瓦片改门的 at）
var door_mode := false
## 悬停瓦片（用于高亮）
var hover_tile := Vector2i(-1, -1)
## 选区（矩形工具拖动中）
var _rect_start := Vector2i(-1, -1)
var _rect_end := Vector2i(-1, -1)
var _dragging_rect := false
var _panning := false
var _pan_last := Vector2.ZERO
## 长按平移（第 45 轮）：左键按下后先"待定"——按住不动超过阈值=平移，先移动=画
var _press_pending := false
var _press_pos := Vector2.ZERO
var _press_ms := 0
var _pan_from_press := false
## 统计（测试用）
var last_action_tile := Vector2i(-1, -1)
var action_count := 0

const GRID_COLOR := Color(0.22, 0.26, 0.32, 0.7)
const GRID_MAJOR := Color(0.32, 0.38, 0.46, 0.9)
const FLOOR_COLOR := Color(0.20, 0.30, 0.44)
const OBSTACLE_COLOR := Color(0.42, 0.52, 0.66)
const ENEMY_COLORS := {
	&"crawler": Color(0.42, 0.29, 0.55),
	&"drone": Color(0.85, 0.45, 0.20),
	&"turret": Color(0.75, 0.30, 0.55),
	&"pouncer": Color(0.30, 0.60, 0.85),
	&"boss_gatekeeper": Color(0.55, 0.62, 0.78),
}
const DOOR_COLOR := Color(0.55, 1.0, 0.75)
const PICKUP_COLORS := {
	&"gold": Color(1.0, 0.85, 0.35),
	&"heal": Color(0.45, 0.95, 0.55),
	&"ability": Color(0.55, 0.9, 1.0),
}
const TRIGGER_COLOR := Color(0.85, 0.70, 1.0)
const LOCKED_DOOR_COLOR := Color(1.0, 0.45, 0.45)
const SAVE_COLOR := Color(0.55, 0.85, 1.0)
const SPAWN_COLOR := Color(0.20, 0.90, 0.60)

func _ready() -> void:
	# 吃满父容器，并把鼠标事件交给自己处理
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	set_process(true)

func set_doc(p_doc: EditorDoc) -> void:
	doc = p_doc
	queue_redraw()

## 把视图居中到房间（切换房间时调用）
func fit_view() -> void:
	if doc == null:
		return
	var room_px := doc.pixel_size()
	var avail := size
	if avail.x <= 1.0 or avail.y <= 1.0:
		avail = Vector2(640, 360)
	zoom = clampf(minf(avail.x / maxf(room_px.x, 1.0), avail.y / maxf(room_px.y, 1.0)) * 0.92, 0.25, 8.0)
	pan = (avail - room_px * zoom) * 0.5
	view_changed.emit()
	queue_redraw()

# ============================================================================
# 坐标换算
# ============================================================================
func world_to_canvas(world: Vector2) -> Vector2:
	return world * zoom + pan

func canvas_to_world(canvas: Vector2) -> Vector2:
	return (canvas - pan) / maxf(zoom, 0.0001)

func canvas_to_tile(canvas: Vector2) -> Vector2i:
	var w := canvas_to_world(canvas)
	return Vector2i(int(floorf(w.x / float(GameConstants.TILE))), int(floorf(w.y / float(GameConstants.TILE))))

func inside_room(tile: Vector2i) -> bool:
	if doc == null:
		return false
	return tile.x >= 0 and tile.y >= 0 and tile.x < doc.width and tile.y < doc.height

# ============================================================================
# 输入
# ============================================================================
func _gui_input(event: InputEvent) -> void:
	if doc == null:
		return

	# ---- 缩放（以鼠标为中心） ----
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := canvas_to_world(mb.position)
			zoom = clampf(zoom * (1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.9), 0.25, 8.0)
			pan = mb.position - before * zoom
			view_changed.emit()
			queue_redraw()
			accept_event()
			return

	# ---- 平移（中键拖动 / 空格+左键 / ✋平移工具 / 左键长按） ----
	if event is InputEventMouseButton:
		var mbb := event as InputEventMouseButton
		if mbb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mbb.pressed
			_pan_last = mbb.position
			accept_event()
			return
		if mbb.button_index == MOUSE_BUTTON_LEFT:
			if mbb.pressed:
				# ✋平移工具 或 空格+左键：立刻进入平移（最直观的两种方式）
				if tool == Tool.PAN or Input.is_key_pressed(KEY_SPACE):
					_panning = true
					_pan_from_press = true
					_pan_last = mbb.position
					accept_event()
					return
				# 普通左键：先"待定"——长按不动 → 平移；先移动 → 照旧画/框选
				_press_pending = true
				_press_pos = mbb.position
				_press_ms = Time.get_ticks_msec()
				_pan_last = mbb.position
				accept_event()
				return
			# ---- 左键松开 ----
			# ⚠ 修复（第 45 轮）：以前这里只更新 _dragging_rect，
			#   空格+左键平移后 `_panning` 永远停在 true ✗ → 松手后视角还跟着鼠标跑 ✗
			if _pan_from_press or _panning:
				_panning = false
				_pan_from_press = false
			if _press_pending:
				# 待定状态松手 = 一次"单击" → 补上那一下绘制（与旧行为一致）
				_press_pending = false
				var tile_click := canvas_to_tile(mbb.position)
				if tool == Tool.RECT:
					tile_action.emit(tile_click, false, true, tile_click)
					action_count += 1
					last_action_tile = tile_click
				elif tool == Tool.PAINT or tool == Tool.ENEMY or tool == Tool.PICKUP or tool == Tool.TRIGGER:
					_apply(tile_click, false)
				queue_redraw()
			if _dragging_rect:
				_dragging_rect = false
				tile_action.emit(_rect_start, false, true, canvas_to_tile(mbb.position))
				action_count += 1
				last_action_tile = canvas_to_tile(mbb.position)
				queue_redraw()
			accept_event()
			return
		if mbb.button_index == MOUSE_BUTTON_RIGHT:
			# 右键 = 擦除（保持立即生效：擦除没有"长按"语义）
			var tile_r := canvas_to_tile(mbb.position)
			if mbb.pressed:
				_apply(tile_r, true)
			accept_event()
			return

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			pan += mm.position - _pan_last
			_pan_last = mm.position
			view_changed.emit()
			queue_redraw()
			return
		# 待定中的左键：一旦移动超过容差就"确定是画"，否则继续等长按
		if _press_pending and mm.position.distance_to(_press_pos) > LONG_PRESS_SLOP:
			_press_pending = false
			_apply(canvas_to_tile(mm.position), false)
			queue_redraw()
			return
		hover_tile = canvas_to_tile(mm.position)
		if _dragging_rect:
			_rect_end = hover_tile
		elif tool == Tool.PAINT and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_apply(hover_tile, false)          # 拖动连续画
		elif (tool == Tool.PAINT or tool == Tool.ENEMY or tool == Tool.PICKUP
				or tool == Tool.TRIGGER) and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_apply(hover_tile, true)           # 拖动连续擦
		queue_redraw()

## 长按判定（第 45 轮）：按住不动超过 LONG_PRESS_MS → 把这次左键从"画"改成"平移"。
## 抽成独立函数（并把"现在几点"作为参数）是为了**可单测**：测试可以喂一个假时间 ✗→✓。
func _maybe_start_long_press(now_ms: int) -> bool:
	if not _press_pending:
		return false
	if now_ms - _press_ms < LONG_PRESS_MS:
		return false
	_press_pending = false
	_panning = true
	_pan_from_press = true
	return true

func _process(_delta: float) -> void:
	# 长按平移：只有"还按着左键且没怎么动"时才转平移（避免误伤正常拖动绘制）
	if _press_pending and _maybe_start_long_press(Time.get_ticks_msec()):
		mouse_default_cursor_shape = Control.CURSOR_DRAG
		queue_redraw()

func _apply(tile: Vector2i, erase: bool) -> void:
	if not inside_room(tile):
		return
	last_action_tile = tile
	action_count += 1
	# 敌人工具只发 entity_clicked，地形工具只发 tile_action —— 各发一次。
	# （曾写成两段 if，导致"放一只敌人"实际放了两次 —— 实测抓到的 bug）
	match tool:
		Tool.ENEMY:
			entity_clicked.emit(tile, erase)
		Tool.PICKUP:
			pickup_action.emit(tile, erase)
		Tool.TRIGGER:
			trigger_action.emit(tile, erase)
		_:
			tile_action.emit(tile, erase, false, tile)
	queue_redraw()

# ============================================================================
# 交互物条目的小工具（查看用；数据改动一律由外壳调 EditorDoc 完成）
# ============================================================================
## 条目里的 tile 字段 → 瓦片坐标
static func entry_tile(entry: Dictionary) -> Vector2i:
	var t: Variant = entry.get("tile", [0, 0])
	if typeof(t) == TYPE_ARRAY and (t as Array).size() >= 2:
		return Vector2i(int(t[0]), int(t[1]))
	return Vector2i.ZERO

## 条目里的 size 字段 → 瓦片尺寸（缺省 2x2）
static func entry_tile_size(entry: Dictionary) -> Vector2:
	var s: Variant = entry.get("size", [2, 2])
	if typeof(s) == TYPE_ARRAY and (s as Array).size() >= 2:
		return Vector2(maxi(int(s[0]), 1), maxi(int(s[1]), 1))
	return Vector2(2, 2)

## 供测试/外壳直接调用（不经过鼠标事件）
func apply_at(tile: Vector2i, erase: bool) -> void:
	_apply(tile, erase)

# ============================================================================
# 绘制
# ============================================================================
func _draw() -> void:
	if doc == null:
		return
	var tile_px := float(GameConstants.TILE) * zoom
	var room_px := doc.pixel_size() * zoom

	# 背景板（房间外区域暗一点，让边界一目了然）
	draw_rect(Rect2(pan - Vector2(40, 40), room_px + Vector2(80, 80)), Color(0.06, 0.07, 0.09), true)
	draw_rect(Rect2(pan, room_px), Color(0.10, 0.12, 0.15), true)

	# 地板（由房间高度推导，与游戏一致：height-2 / height-3）
	var floor_top := maxi(doc.height - (3 if doc.height >= 30 else 2), 0)
	draw_rect(Rect2(pan + Vector2(0, float(floor_top) * tile_px),
		Vector2(room_px.x, float(doc.height - floor_top) * tile_px)), FLOOR_COLOR, true)

	# 网格（每 5 格加粗，便于数格子）
	for x in range(doc.width + 1):
		var c := GRID_MAJOR if x % 5 == 0 else GRID_COLOR
		var px := pan.x + float(x) * tile_px
		draw_line(Vector2(px, pan.y), Vector2(px, pan.y + room_px.y), c, 1.0)
	for y in range(doc.height + 1):
		var c2 := GRID_MAJOR if y % 5 == 0 else GRID_COLOR
		var py := pan.y + float(y) * tile_px
		draw_line(Vector2(pan.x, py), Vector2(pan.x + room_px.x, py), c2, 1.0)

	# 碰撞体积
	for key: Variant in doc.obstacles.keys():
		var parts := String(key).split(",")
		if parts.size() != 2:
			continue
		var t := Vector2i(int(parts[0]), int(parts[1]))
		draw_rect(Rect2(pan + Vector2(t) * tile_px, Vector2(tile_px, tile_px)), OBSTACLE_COLOR, true)

	# 存档点（world.json 里属于本房的）
	for sp: Variant in _room_save_points():
		var spt := Vector2i(int(sp.x), int(sp.y))
		draw_rect(Rect2(pan + Vector2(spt) * tile_px + Vector2(2, 2),
			Vector2(tile_px - 4, tile_px - 4)), SAVE_COLOR, false, 2.0)

	# 玩家默认出生点（让策划知道玩家会落在哪）
	var spawn_tile := Vector2i(GameConstants.PLAYER_SPAWN_COLUMN,
		maxi(floor_top - GameConstants.PLAYER_SPAWN_HEIGHT_ABOVE_FLOOR, 0))
	draw_rect(Rect2(pan + Vector2(spawn_tile) * tile_px, Vector2(tile_px, tile_px * 2)), SPAWN_COLOR, false, 2.0)

	# 敌人
	for g: Variant in doc.enemy_groups:
		var group: Dictionary = g
		var type_id := StringName(str(group.get("type", "crawler")))
		var color: Color = ENEMY_COLORS.get(type_id, Color(0.8, 0.8, 0.8))
		for p: Variant in group.get("spawn_points", []):
			if typeof(p) != TYPE_ARRAY or (p as Array).size() < 2:
				continue
			var t2 := Vector2i(int(p[0]), int(p[1]))
			var r := Rect2(pan + Vector2(t2) * tile_px + Vector2(2, 2), Vector2(tile_px - 4, tile_px - 4))
			draw_rect(r, color, true)
			draw_rect(r, Color(1, 1, 1, 0.85), false, 1.0)
			if tile_px >= 18.0:
				var font: Font = ThemeDB.fallback_font
				if font != null:
					draw_string(font, r.position + Vector2(2, tile_px * 0.55), String(type_id).substr(0, 3),
						HORIZONTAL_ALIGNMENT_LEFT, -1, int(clampf(tile_px * 0.35, 7, 12)), Color(1, 1, 1, 0.9))

	# 门（含门控标记；门的位置由房间图推导，这里用 Door 的同一套算法画出来）
	for d: Variant in doc.doors:
		var dd: Dictionary = d
		var rect := door_rect_for(dd)
		var locked := str(dd.get("gate", "")) != ""
		var color2 := LOCKED_DOOR_COLOR if locked else DOOR_COLOR
		var dr := Rect2(pan + rect.position * zoom, rect.size * zoom)
		draw_rect(dr, Color(color2.r, color2.g, color2.b, 0.55), true)
		draw_rect(dr, color2, false, 2.0)
		var font2: Font = ThemeDB.fallback_font
		if font2 != null:
			var label := str(dd.get("to", "?"))
			if locked:
				label += "[%s]" % str(dd.get("gate", ""))
			draw_string(font2, dr.position + Vector2(2, -3), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color2)

	# 拾取物（小方块，颜色按种类）
	for p: Variant in doc.pickups:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pe: Dictionary = p
		var ptile := entry_tile(pe)
		var pr := Rect2(pan + Vector2(ptile) * tile_px + Vector2(4, 4) * zoom,
			Vector2(tile_px, tile_px) - Vector2(8, 8) * zoom)
		var pk := StringName(str(pe.get("kind", "gold")))
		var pc: Color = PICKUP_COLORS.get(pk, Color(1, 1, 1, 0.9))
		draw_rect(pr, pc, true)
		draw_rect(pr, Color(1, 1, 1, 0.85), false, 1.0)

	# 触发器（矩形区域 + 种类标记）
	for t: Variant in doc.triggers:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var te: Dictionary = t
		var ttile := entry_tile(te)
		var tr := Rect2(pan + Vector2(ttile) * tile_px, entry_tile_size(te) * tile_px)
		draw_rect(tr, Color(TRIGGER_COLOR.r, TRIGGER_COLOR.g, TRIGGER_COLOR.b, 0.22), true)
		draw_rect(tr, Color(TRIGGER_COLOR.r, TRIGGER_COLOR.g, TRIGGER_COLOR.b, 0.9), false, 1.0)
		var font3: Font = ThemeDB.fallback_font
		if font3 != null and tile_px >= 12.0:
			draw_string(font3, tr.position + Vector2(2, -3), str(te.get("kind", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, TRIGGER_COLOR)

	# 悬停高亮 + 矩形预览
	if inside_room(hover_tile):
		draw_rect(Rect2(pan + Vector2(hover_tile) * tile_px, Vector2(tile_px, tile_px)),
			Color(1, 1, 1, 0.55), false, 1.0)
	if _dragging_rect:
		var x0 := mini(_rect_start.x, _rect_end.x)
		var y0 := mini(_rect_start.y, _rect_end.y)
		var x1 := maxi(_rect_start.x, _rect_end.x)
		var y1 := maxi(_rect_start.y, _rect_end.y)
		var rr := Rect2(pan + Vector2(x0, y0) * tile_px, Vector2(x1 - x0 + 1, y1 - y0 + 1) * tile_px)
		draw_rect(rr, Color(1, 0.9, 0.4, 0.25), true)
		draw_rect(rr, Color(1, 0.9, 0.4), false, 1.0)

## 门的像素矩形：与运行时 core/door.gd 的算法一致（保证"编辑器所见 = 游戏所走"）
func door_rect_for(d: Dictionary) -> Rect2:
	var tile := float(GameConstants.TILE)
	var w := float(doc.width) * tile
	var floor_y := float(doc.height - (3 if doc.height >= 30 else 2)) * tile
	var at: Variant = d.get("at", [0, 0])
	if typeof(at) == TYPE_ARRAY and (at as Array).size() >= 2 \
			and (int(at[0]) != 0 or int(at[1]) != 0):
		return Rect2(Vector2(int(at[0]), int(at[1])) * tile, Vector2(tile, tile * 2.0))
	# 与 Door 相同：比较目标房与本房的 grid 决定方位
	var target := _target_grid(d)
	var dxy := target - doc.grid
	var door_h := tile * 2.0
	if dxy.x != 0 and absi(dxy.x) >= absi(dxy.y):
		if dxy.x > 0:
			return Rect2(Vector2(w - Door.DOOR_THICK, floor_y - door_h), Vector2(Door.DOOR_THICK, door_h))
		return Rect2(Vector2(0.0, floor_y - door_h), Vector2(Door.DOOR_THICK, door_h))
	if dxy.y > 0:
		return Rect2(Vector2(clampf(w * 0.5 - tile, tile, maxf(w - tile * 2.0, tile)), floor_y - 4.0),
			Vector2(tile * 2.0, 4.0))
	return Rect2(Vector2(clampf(w * 0.5 - tile, tile, maxf(w - tile * 2.0, tile)), floor_y - 4.0),
		Vector2(tile * 2.0, 4.0))

## 目标房的网格坐标（由外壳注入 world 数据查询；缺省回退到本房 → 画成东侧）
var target_grid_provider: Callable = Callable()
func _target_grid(d: Dictionary) -> Vector2i:
	if target_grid_provider.is_valid():
		var g: Variant = target_grid_provider.call(StringName(str(d.get("to", ""))))
		if g is Vector2i:
			return g
	return doc.grid + Vector2i(1, 0) if doc != null else Vector2i.ZERO

## 本房的存档点瓦片（由外壳注入；world.json 的 save_points）
var save_point_provider: Callable = Callable()
func _room_save_points() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if save_point_provider.is_valid():
		var v: Variant = save_point_provider.call()
		if v is Array:
			for item: Variant in v:
				if item is Vector2i:
					out.append(item)
	return out
