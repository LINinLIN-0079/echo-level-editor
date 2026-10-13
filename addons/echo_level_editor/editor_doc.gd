class_name EditorDoc
extends RefCounted
## ============================================================================
## EditorDoc —— 关卡编辑器文档模型（一个房间的可编辑状态 + 撤销栈 + 安全保存）
## ----------------------------------------------------------------------------
## 设计要点（"傻瓜式编辑器"的可靠底座）：
##   1. **磁盘 JSON 是唯一事实源**：本模型只做「加载 → 改 → 校验 → 原子写回」，
##      绝不引入第二套数据格式。因此编辑器保存后游戏立刻能用，零转换步骤。
##   2. **撤销/重做用快照栈**：单个房间数据只有几 KB，快照比命令模式简单得多，
##      而且永远不会出现"撤销到一半状态错乱"（命令模式最经典的一类 bug）。
##   3. **写盘前必校验**：越界瓦片 / 悬空生成点 / 指向不存在房间的门 / 非法敌人类型
##      一律**拒绝写入**并把问题清单交回 UI（与素材校验器同一套"不合规就拒收"原则）。
##   4. **原子写 + .bak**：与 SaveSystem 相同的策略（先写 .tmp 再改名），
##      编辑过程中任何一次崩溃都不会留下半个坏文件。
##   5. 门与地图格坐标存在 world.json（不在房间文件里），因此保存要同时更新两个文件；
##      本模型把这件事封装成一次 save()，调用方拿到的只有"成功/失败 + 问题清单"。
## ============================================================================

## 房间标识（不可改：改名等于换房间）
var room_id: StringName = &""
## 元数据
var room_name: String = ""
var zone: StringName = &"Z1"
var theme: String = "chamber_metal"
var width: int = 30
var height: int = 14
var grid := Vector2i.ZERO
var grid_size := Vector2i.ONE
var gold_drop: int = 0
var is_boss := false
var ability_reward: StringName = &""
var victory: StringName = &"clear_room"

## 碰撞体积（障碍物）：用字典存 "x,y" -> true，增删 O(1)，导出时再排序成数组
var obstacles: Dictionary = {}
## 敌人分组（结构与房间 JSON 的 enemies 完全一致，避免两套模型）
var enemy_groups: Array = []
## 门（结构与 world.json 的 doors 完全一致）
var doors: Array = []
## 拾取物与触发器（结构与房间 JSON 的 pickups / triggers 完全一致）
## 校验直接调用运行时的 Interactables.validate —— 规则只有一份，编辑器与游戏不会漂移
var pickups: Array = []
var triggers: Array = []

# ---------------------------------------------------------------- 撤销栈
const MAX_UNDO := 120
var _undo_stack: Array = []
var _redo_stack: Array = []
var _dirty := false
## 批处理深度：套用模板/粘贴区域这类"一次操作 = 多次子编辑"的场景，
## 整批只应留下**一个**撤销点（否则用户要按十几次 Ctrl+Z 才能退回原状 —— 实测反馈）。
var _batch_depth := 0
var _batch_snapshot: Dictionary = {}

# ============================================================================
# 加载
# ============================================================================
## 从世界数据库加载一个房间为可编辑文档（数据来自已解析的 Room + world.json 原始条目）
static func load_room(p_room_id: StringName, db: WorldDatabase) -> EditorDoc:
	var room := db.get_room(p_room_id)
	if room == null:
		return null
	var doc := EditorDoc.new()
	doc.room_id = room.id
	doc.room_name = room.name
	doc.zone = room.zone
	doc.theme = room.theme
	doc.width = room.width
	doc.height = room.height
	doc.grid = room.grid
	doc.grid_size = room.grid_size
	doc.gold_drop = room.gold_drop
	doc.is_boss = room.is_boss
	doc.ability_reward = room.ability_reward
	doc.victory = room.victory

	# 障碍物
	for t in room.obstacles:
		doc.obstacles[_key(t)] = true

	# 敌人分组：从磁盘 JSON 读原始形态（Room 里的 spawn_points 已被解析成 Vector2i，
	# 但分组字段（count/hp/speed/attack）需要原样保留，故直接读文件最保真）
	var room_path := "res://data/%s" % _room_rel_path(p_room_id)
	var raw := _read_json(room_path)
	if not raw.is_empty():
		var groups: Variant = raw.get("enemies", [])
		if groups is Array:
			doc.enemy_groups = (groups as Array).duplicate(true)
		var raw_pickups: Variant = raw.get("pickups", [])
		if raw_pickups is Array:
			doc.pickups = (raw_pickups as Array).duplicate(true)
		var raw_triggers: Variant = raw.get("triggers", [])
		if raw_triggers is Array:
			doc.triggers = (raw_triggers as Array).duplicate(true)
	# 门：world.json 的原始条目（Room.doors 已解析，但 at/one_way 需要原样保留）
	for d in room.doors:
		doc.doors.append({
			"to": String(d.to),
			"at": [d.at.x, d.at.y],
			"gate": String(d.gate),
			"one_way": d.one_way,
		})
	doc._dirty = false
	return doc

## 房间文件相对 data/ 的路径（与 world.json 的 file 字段一致）
static func _room_rel_path(room_id: StringName) -> String:
	return "rooms/%s.json" % String(room_id)

# ============================================================================
# 查询
# ============================================================================
func is_dirty() -> bool:
	return _dirty

func obstacle_count() -> int:
	return obstacles.size()

func enemy_total() -> int:
	var n := 0
	for g: Variant in enemy_groups:
		n += int((g as Dictionary).get("count", 0))
	return n

func door_count() -> int:
	return doors.size()

func tile_is_obstacle(tile: Vector2i) -> bool:
	return obstacles.has(_key(tile))

## 房间像素尺寸（画布用）
func pixel_size() -> Vector2:
	return Vector2(float(width), float(height)) * float(GameConstants.TILE)

## 瓦片 → 字典键（静态：既供实例方法用，也供静态的 load_room 用）
static func _key(tile: Vector2i) -> String:
	return "%d,%d" % [tile.x, tile.y]

# ============================================================================
# 编辑操作（每个操作先压快照，因此都可以撤销）
# ============================================================================
## 画/擦一块碰撞体积
func set_obstacle(tile: Vector2i, present: bool) -> bool:
	if tile.x < 0 or tile.y < 0 or tile.x >= width or tile.y >= height:
		return false
	var key := _key(tile)
	if present == obstacles.has(key):
		return false                      # 状态没变 → 不产生撤销记录
	_push_undo()
	if present:
		obstacles[key] = true
	else:
		obstacles.erase(key)
	_dirty = true
	return true

## 矩形填充（拖拽画框）
func fill_obstacles(from: Vector2i, to: Vector2i, present: bool) -> int:
	var x0 := mini(from.x, to.x)
	var x1 := maxi(from.x, to.x)
	var y0 := mini(from.y, to.y)
	var y1 := maxi(from.y, to.y)
	var changed := 0
	var before := obstacles.duplicate()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var tile := Vector2i(x, y)
			if tile.x < 0 or tile.y < 0 or tile.x >= width or tile.y >= height:
				continue
			var key := _key(tile)
			if present:
				if not obstacles.has(key):
					obstacles[key] = true
					changed += 1
			else:
				if obstacles.has(key):
					obstacles.erase(key)
					changed += 1
	if changed > 0:
		_push_undo_with(before)
		_dirty = true
	return changed

## 某类型敌人数量
func count_enemies_of(type_id: StringName) -> int:
	var n := 0
	for g: Variant in enemy_groups:
		if StringName(str((g as Dictionary).get("type", ""))) == type_id:
			n += int((g as Dictionary).get("count", 0))
	return n

## 新建敌人分组时的兜底数值（优先从世界里已有同类型分组复制，保证与游戏调参一致；
## 只有在世界里也找不到该类型时才用这张表 —— 它现在来自 **.tres 资源**
## （data/enemies/*.tres，也就是可以在 Godot 检查器里直接改的那份；资源缺失回落到内置常量）。
func _enemy_defaults() -> Dictionary:
	return EnemyData.default_stats()

## 在瓦片处放置一个敌人（同类型分组不存在则新建）
## db 非空时会先从世界里已有同类型分组复制 hp/move_speed/attack（保持调参一致）
func add_enemy(type_id: StringName, tile: Vector2i, db: WorldDatabase = null) -> bool:
	if tile.x < 0 or tile.y < 0 or tile.x >= width or tile.y >= height:
		return false
	if not EnemyData.known_ids().has(type_id):
		return false
	_push_undo()
	var group := _find_group(type_id)
	if group.is_empty():
		var stats := _stats_for(type_id, db)
		group = {
			"type": String(type_id),
			"count": 0,
			"hp": int(stats["hp"]),
			"move_speed": float(stats["move_speed"]),
			"attack": int(stats["attack"]),
			"spawn_points": [],
		}
		enemy_groups.append(group)
	var points: Array = group["spawn_points"]
	points.append([tile.x, tile.y])
	group["count"] = points.size()
	_dirty = true
	return true

## 取该类型的数值：先在世界里找同类型分组，其次用 .tres 资源里的默认值
func _stats_for(type_id: StringName, db: WorldDatabase) -> Dictionary:
	if db != null:
		for room in db.rooms:
			for g: Variant in room.enemy_groups:
				var grp: WorldDatabase.EnemyGroup = g
				if grp.type == type_id:
					return {"hp": grp.hp, "move_speed": grp.move_speed, "attack": grp.attack}
	var defaults := _enemy_defaults()
	if defaults.has(type_id):
		return defaults[type_id]
	return {"hp": 2, "move_speed": 40.0, "attack": 1}

## 删除瓦片上的敌人（返回是否删掉了什么）
func remove_enemy_at(tile: Vector2i) -> bool:
	for i in enemy_groups.size():
		var group: Dictionary = enemy_groups[i]
		var points: Array = group.get("spawn_points", [])
		for j in points.size():
			var p: Variant = points[j]
			if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2 \
					and int(p[0]) == tile.x and int(p[1]) == tile.y:
				_push_undo()
				points.remove_at(j)
				group["count"] = points.size()
				if points.is_empty():
					enemy_groups.remove_at(i)
				_dirty = true
				return true
	return false

## 查瓦片上的敌人（返回 {"group": i, "point": j, "type": String} 或空字典）
func enemy_at(tile: Vector2i) -> Dictionary:
	for i in enemy_groups.size():
		var group: Dictionary = enemy_groups[i]
		var points: Array = group.get("spawn_points", [])
		for j in points.size():
			var p: Variant = points[j]
			if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2 \
					and int(p[0]) == tile.x and int(p[1]) == tile.y:
				return {"group": i, "point": j, "type": str(group.get("type", "crawler"))}
	return {}

## 把某个敌人的生成点从 from 移到 to
func move_enemy(from: Vector2i, to: Vector2i) -> bool:
	if to.x < 0 or to.y < 0 or to.x >= width or to.y >= height:
		return false
	var found := enemy_at(from)
	if found.is_empty():
		return false
	if not enemy_at(to).is_empty():
		return false
	_push_undo()
	var group: Dictionary = enemy_groups[int(found["group"])]
	var points: Array = group["spawn_points"]
	points[int(found["point"])] = [to.x, to.y]
	_dirty = true
	return true

## 改某类型分组的字段（hp / move_speed / attack / type）
func set_group_field(type_id: StringName, key: String, value: Variant) -> bool:
	var group := _find_group(type_id)
	if group.is_empty():
		return false
	if group.get(key, null) == value:
		return false
	_push_undo()
	group[key] = value
	_dirty = true
	return true

func group_field(type_id: StringName, key: String, fallback: Variant = null) -> Variant:
	var group := _find_group(type_id)
	if group.is_empty():
		return fallback
	return group.get(key, fallback)

## 增删门
func add_door(to_room: StringName, gate: StringName = &"", at: Vector2i = Vector2i.ZERO) -> bool:
	if String(to_room) == "":
		return false
	for d: Variant in doors:
		if StringName(str((d as Dictionary).get("to", ""))) == to_room:
			return false                      # 同一目标房只留一扇门
	_push_undo()
	doors.append({"to": String(to_room), "at": [at.x, at.y], "gate": String(gate), "one_way": false})
	_dirty = true
	return true

func remove_door(index: int) -> bool:
	if index < 0 or index >= doors.size():
		return false
	_push_undo()
	doors.remove_at(index)
	_dirty = true
	return true

func set_door_field(index: int, key: String, value: Variant) -> bool:
	if index < 0 or index >= doors.size():
		return false
	var d: Dictionary = doors[index]
	if d.get(key, null) == value:
		return false
	_push_undo()
	d[key] = value
	_dirty = true
	return true

# ---------------------------------------------------------------- 拾取物 / 触发器
## 在瓦片处放一个拾取物（同格已有则拒绝，避免叠在一起看不见）
func add_pickup(kind: StringName, tile: Vector2i, amount: int = -1, ability_id: StringName = &"dash") -> bool:
	if not Interactables.PICKUP_KINDS.has(kind):
		return false
	if not _in_bounds(tile) or pickup_at(tile) >= 0:
		return false
	var table: Dictionary = Interactables.PICKUP_KINDS[kind]
	_push_undo()
	var entry := {"kind": String(kind), "tile": [tile.x, tile.y]}
	if kind == &"ability":
		entry["ability"] = String(ability_id)
	else:
		entry["amount"] = amount if amount > 0 else int(table.get("amount", 0))
	pickups.append(entry)
	_dirty = true
	return true

func pickup_at(tile: Vector2i) -> int:
	return _entry_at(pickups, tile)

func remove_pickup(index: int) -> bool:
	return _remove_entry(pickups, index)

## 在瓦片处放一个触发器（默认 2x2 瓦；尺寸可在检查器里改）
func add_trigger(kind: StringName, tile: Vector2i, size := Vector2i(2, 2)) -> bool:
	if not Interactables.TRIGGER_KINDS.has(kind):
		return false
	if not _in_bounds(tile):
		return false
	_push_undo()
	var entry := {
		"kind": String(kind),
		"tile": [tile.x, tile.y],
		"size": [size.x, size.y],
		"once": true,
	}
	if kind == &"message":
		entry["text"] = "（在这里写提示）"
	triggers.append(entry)
	_dirty = true
	return true

func trigger_at(tile: Vector2i) -> int:
	return _entry_at(triggers, tile)

func remove_trigger(index: int) -> bool:
	return _remove_entry(triggers, index)

## 改拾取物/触发器的字段（kind / amount / ability / text / size / once …）
func set_pickup_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(pickups, index, key, value)

func set_trigger_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(triggers, index, key, value)

func pickup_field(index: int, key: String, fallback: Variant = null) -> Variant:
	return _entry_field(pickups, index, key, fallback)

func trigger_field(index: int, key: String, fallback: Variant = null) -> Variant:
	return _entry_field(triggers, index, key, fallback)

func _in_bounds(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < width and tile.y < height

func _entry_at(list: Array, tile: Vector2i) -> int:
	for i in list.size():
		var e: Variant = list[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var t: Variant = (e as Dictionary).get("tile", [])
		if typeof(t) == TYPE_ARRAY and (t as Array).size() >= 2 \
				and int(t[0]) == tile.x and int(t[1]) == tile.y:
			return i
	return -1

func _remove_entry(list: Array, index: int) -> bool:
	if index < 0 or index >= list.size():
		return false
	_push_undo()
	list.remove_at(index)
	_dirty = true
	return true

func _set_entry_field(list: Array, index: int, key: String, value: Variant) -> bool:
	if index < 0 or index >= list.size():
		return false
	var e: Dictionary = list[index]
	if e.get(key, null) == value:
		return false
	_push_undo()
	e[key] = value
	_dirty = true
	return true

func _entry_field(list: Array, index: int, key: String, fallback: Variant = null) -> Variant:
	if index < 0 or index >= list.size():
		return fallback
	return (list[index] as Dictionary).get(key, fallback)

## 房间内容摘要（状态栏显示"拾取物 N · 触发器 M"）
func content_summary() -> String:
	return "拾取物 %d · 触发器 %d" % [pickups.size(), triggers.size()]

## 改元数据（name / zone / theme / gold_drop / is_boss / ability_reward / victory / grid / size）
## 注意：方法名不能叫 set_meta —— 那是 Object 的原生方法，GDScript 会报
## "Could not resolve external class member"（实测踩到的坑）。
func set_field(key: String, value: Variant) -> bool:
	var cur: Variant = get(key)
	if cur == value:
		return false
	_push_undo()
	set(key, value)
	_dirty = true
	return true

# ============================================================================
# 撤销 / 重做
# ============================================================================
func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_redo_stack.append(_snapshot())
	_apply(_undo_stack.pop_back())
	_dirty = true
	return true

func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(_snapshot())
	_apply(_redo_stack.pop_back())
	_dirty = true
	return true

func undo_depth() -> int:
	return _undo_stack.size()

func redo_depth() -> int:
	return _redo_stack.size()

func _push_undo() -> void:
	# 批处理中：中间的子编辑不压快照，整批由 begin_batch() 压的那一个负责
	if _batch_depth > 0:
		return
	_push_undo_with(_snapshot())

## 开始一次批处理：整批共用一个撤销点
func begin_batch() -> void:
	if _batch_depth == 0:
		_batch_snapshot = _snapshot()
		_push_undo_with(_batch_snapshot)
	_batch_depth += 1

## 结束批处理；若整批**内容没有任何变化**，就把那个空撤销点丢掉。
## 判据用"批前快照 vs 现在快照"的内容比较 —— 不能用 _dirty：
## 文档在批处理前就可能已经是脏的，那样会把真实改动误判成空批（实测踩到的坑）。
func end_batch() -> void:
	_batch_depth = maxi(_batch_depth - 1, 0)
	if _batch_depth == 0 and not _batch_snapshot.is_empty():
		if str(_batch_snapshot) == str(_snapshot()) and not _undo_stack.is_empty():
			_undo_stack.pop_back()
		_batch_snapshot = {}

func in_batch() -> bool:
	return _batch_depth > 0

func _push_undo_with(snap: Dictionary) -> void:
	_undo_stack.append(snap)
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()                       # 新操作会截断重做分支（标准编辑器语义）

func _snapshot() -> Dictionary:
	return {
		"room_name": room_name, "zone": String(zone), "theme": theme,
		"width": width, "height": height,
		"grid": [grid.x, grid.y], "grid_size": [grid_size.x, grid_size.y],
		"gold_drop": gold_drop, "is_boss": is_boss,
		"ability_reward": String(ability_reward), "victory": String(victory),
		"obstacles": obstacles.duplicate(),
		"enemy_groups": enemy_groups.duplicate(true),
		"doors": doors.duplicate(true),
		"pickups": pickups.duplicate(true),
		"triggers": triggers.duplicate(true),
	}

func _apply(snap: Dictionary) -> void:
	room_name = String(snap.get("room_name", room_name))
	zone = StringName(str(snap.get("zone", String(zone))))
	theme = String(snap.get("theme", theme))
	width = int(snap.get("width", width))
	height = int(snap.get("height", height))
	var g: Array = snap.get("grid", [grid.x, grid.y])
	grid = Vector2i(int(g[0]), int(g[1]))
	var gs: Array = snap.get("grid_size", [grid_size.x, grid_size.y])
	grid_size = Vector2i(int(gs[0]), int(gs[1]))
	gold_drop = int(snap.get("gold_drop", gold_drop))
	is_boss = bool(snap.get("is_boss", is_boss))
	ability_reward = StringName(str(snap.get("ability_reward", String(ability_reward))))
	victory = StringName(str(snap.get("victory", String(victory))))
	obstacles = (snap.get("obstacles", {}) as Dictionary).duplicate()
	enemy_groups = (snap.get("enemy_groups", []) as Array).duplicate(true)
	doors = (snap.get("doors", []) as Array).duplicate(true)
	pickups = (snap.get("pickups", []) as Array).duplicate(true)
	triggers = (snap.get("triggers", []) as Array).duplicate(true)

# ============================================================================
# 校验（写盘前的守门员）
# ============================================================================
## 返回问题清单（空 = 可以安全写盘）
func validate(db: WorldDatabase) -> Array[String]:
	var problems: Array[String] = []

	# ---- 尺寸 ----
	if width < 12 or width > 80:
		problems.append("房间宽度应在 12..80 瓦之间（当前 %d）" % width)
	if height < 8 or height > 48:
		problems.append("房间高度应在 8..48 瓦之间（当前 %d）" % height)
	if room_name.strip_edges() == "":
		problems.append("房间名不能为空")

	# ---- 碰撞体积 ----
	var floor_top := maxi(height - (3 if height >= 30 else 2), 0)
	for key: Variant in obstacles.keys():
		var parts := String(key).split(",")
		if parts.size() != 2:
			problems.append("障碍物键非法：%s" % String(key))
			continue
		var x := int(parts[0])
		var y := int(parts[1])
		if x < 0 or y < 0 or x >= width or y >= height:
			problems.append("障碍物越界：(%d,%d)" % [x, y])
		elif y >= floor_top:
			problems.append("障碍物在地板行内（无意义）：(%d,%d)" % [x, y])

	# ---- 敌人 ----
	for gi in enemy_groups.size():
		var group: Dictionary = enemy_groups[gi]
		var type_id := StringName(str(group.get("type", "")))
		if not EnemyData.known_ids().has(type_id):
			problems.append("敌人类型未知：%s（已知：%s）"
				% [str(type_id), str(EnemyData.known_ids())])
			continue
		var points: Array = group.get("spawn_points", [])
		if int(group.get("count", 0)) != points.size():
			problems.append("%s：count(%d) 与生成点数量(%d) 不一致"
				% [str(type_id), int(group.get("count", 0)), points.size()])
		for p: Variant in points:
			if typeof(p) != TYPE_ARRAY or (p as Array).size() < 2:
				problems.append("%s：生成点格式非法 %s" % [str(type_id), str(p)])
				continue
			var tx := int(p[0])
			var ty := int(p[1])
			if tx < 0 or ty < 0 or tx >= width or ty >= height:
				problems.append("%s：生成点越界 (%d,%d)" % [str(type_id), tx, ty])
				continue
			if obstacles.has("%d,%d" % [tx, ty]):
				problems.append("%s：生成点落在碰撞体积里 (%d,%d)" % [str(type_id), tx, ty])
			# 贴脸出生（实机事故的回归防护）：地面敌人不得靠在玩家出生侧
			if type_id != &"drone" and ty >= floor_top - 2 and tx < WorldDatabase.MIN_GROUND_ENEMY_X:
				problems.append("%s：地面敌人贴脸出生 (%d,%d)（x 需 >= %d）"
					% [str(type_id), tx, ty, WorldDatabase.MIN_GROUND_ENEMY_X])

	# ---- 门 ----
	for d: Variant in doors:
		var dd: Dictionary = d
		var to := StringName(str(dd.get("to", "")))
		if String(to) == "":
			problems.append("存在没有目标房的门")
			continue
		if db != null and db.get_room(to) == null:
			problems.append("门指向不存在的房间：%s" % str(to))
		var gate := str(dd.get("gate", ""))
		if not WorldDatabase.ALLOWED_GATES.has(gate):
			problems.append("门控非法：%s（允许：%s）" % [gate, str(WorldDatabase.ALLOWED_GATES)])

	# ---- 拾取物 / 触发器（直接调运行时的 Interactables.validate：规则只有一份）----
	var probe := WorldDatabase.Room.new()
	probe.width = width
	probe.height = height
	for p: Variant in Interactables.validate(pickups, "pickups", probe):
		problems.append(str(p))
	for t: Variant in Interactables.validate(triggers, "triggers", probe):
		problems.append(str(t))

	# ---- 能力/胜负字段 ----
	if String(ability_reward) != "" and not ["dash", "double_jump", "melee"].has(String(ability_reward)):
		problems.append("能力奖励非法：%s" % String(ability_reward))
	if not ["clear_room", "reach_terminal"].has(String(victory)):
		problems.append("胜负条件非法：%s" % String(victory))

	return problems

# ============================================================================
# 导出
# ============================================================================
## 导出为房间 JSON（字段与磁盘上的 R*.json 完全一致）
func to_room_dict() -> Dictionary:
	var tiles: Array = []
	for key: Variant in obstacles.keys():
		var parts := String(key).split(",")
		if parts.size() == 2:
			tiles.append([int(parts[0]), int(parts[1])])
	tiles.sort_custom(func(a: Array, b: Array) -> bool:
		if int(a[1]) != int(b[1]):
			return int(a[1]) < int(b[1])
		return int(a[0]) < int(b[0]))
	var out := {
		"id": String(room_id),
		"name": room_name,
		"zone": String(zone),
		"theme": theme,
		"room_size": {"width": width, "height": height},
		"grid": {"col": grid.x, "row": grid.y, "w": grid_size.x, "h": grid_size.y},
		"gold_drop": gold_drop,
		"is_boss": is_boss,
		"ability_reward": String(ability_reward),
		"victory": String(victory),
		"enemies": enemy_groups,
		"obstacles": tiles,
	}
	# 只有真的有内容时才写这两个字段：老房间文件保持干净（diff 友好，且不改动既有数据）
	if not pickups.is_empty():
		out["pickups"] = pickups
	if not triggers.is_empty():
		out["triggers"] = triggers
	return out

## 导出为 world.json 里本房的条目（门与地图格坐标存在这里）
func to_world_entry() -> Dictionary:
	var ds: Array = []
	for d: Variant in doors:
		ds.append((d as Dictionary).duplicate(true))
	return {
		"file": EditorDoc._room_rel_path(room_id),
		"name": room_name,
		"zone": String(zone),
		"grid": [grid.x, grid.y, grid_size.x, grid_size.y],
		"doors": ds,
	}

# ============================================================================
# 保存（校验 → 原子写房间文件 + 更新 world.json）
# ============================================================================
## 返回 {"ok": bool, "errors": [...], "paths": [...]}
## p_world_path / p_rooms_dir 可覆盖（用于"另存为模板"或测试写到 user://，
## 默认写回游戏实际读取的路径，因此编辑器保存后立刻可在游戏里验证）
func save(db: WorldDatabase, p_world_path: String = WorldDatabase.WORLD_PATH,
		p_rooms_dir: String = "res://data/rooms/") -> Dictionary:
	var errors := validate(db)
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "paths": []}

	var paths: Array[String] = []
	var room_path := p_rooms_dir + "%s.json" % String(room_id)
	if not _write_json_atomic(room_path, to_room_dict()):
		return {"ok": false, "errors": ["房间文件写入失败：%s" % room_path], "paths": paths}
	paths.append(room_path)

	# world.json：只替换本房条目，其余房间原样保留（避免把别人的手改覆盖掉）
	var world_path := p_world_path
	var world := _read_json(world_path)
	if world.is_empty():
		return {"ok": false, "errors": ["world.json 读取失败：%s" % world_path], "paths": paths}
	var rooms_raw: Variant = world.get("rooms", {})
	if typeof(rooms_raw) != TYPE_DICTIONARY:
		return {"ok": false, "errors": ["world.json 缺少 rooms 段"], "paths": paths}
	(rooms_raw as Dictionary)[String(room_id)] = to_world_entry()
	world["rooms"] = rooms_raw
	if not _write_json_atomic(world_path, world):
		return {"ok": false, "errors": ["world.json 写入失败"], "paths": paths}
	paths.append(world_path)

	_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	return {"ok": true, "errors": [], "paths": paths}

## 原子写：先写 .tmp，再把上一版备份成 .bak，最后改名替换
func _write_json_atomic(path: String, data: Dictionary) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("EditorDoc：无法写入 %s" % tmp)
		return false
	f.store_string(JSON.stringify(data, "  ") + "\n")
	f.close()
	# 备份上一版（人可读 JSON，出问题时可手工对比还原）
	if FileAccess.file_exists(path):
		var src := FileAccess.open(path, FileAccess.READ)
		if src != null:
			var text := src.get_as_text()
			src.close()
			var bak := FileAccess.open(path + ".bak", FileAccess.WRITE)
			if bak != null:
				bak.store_string(text)
				bak.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("EditorDoc：改名失败 %d（%s）" % [err, path])
		return false
	return true

# ============================================================================
# 内部工具
# ============================================================================
func _find_group(type_id: StringName) -> Dictionary:
	for g: Variant in enemy_groups:
		var gd: Dictionary = g
		if StringName(str(gd.get("type", ""))) == type_id:
			return gd
	return {}

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
