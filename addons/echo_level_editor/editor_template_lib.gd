class_name EditorTemplateLib
extends RefCounted
## ============================================================================
## EditorTemplateLib —— 模板预制体（"搭关卡不用每次从零摆"）
## ----------------------------------------------------------------------------
## 数据：data/templates/<id>.json
##   { "id": "...", "name": "...", "kind": "pickups|triggers|enemies|obstacles|skeleton",
##     "payload": { ... 与房间 JSON 同形，但**坐标是相对锚点的** ... } }
##
## 关键设计（决定了实现有多短）：
##   * **套用时一律调 EditorDoc 已有的编辑 API**（add_pickup / add_trigger / add_enemy /
##     set_obstacle …），因此撤销栈、校验、原子写、试玩回流全部自动生效，
##     模板系统本身不需要动存储与保存逻辑；
##   * **坐标相对化**：抓取时把整块内容平移到左上角 (0,0) 附近，套用时再按锚点偏移 ——
##     于是一个模板可以在任何房间的任何位置复用；
##   * **越界只跳过不报错**：套用会把放不下的条目数报给 UI（"3 个放不下"），
##     而不是整批失败 —— 策划拖到墙边时不至于一无所获。
## ============================================================================

const DIR := "res://data/templates/"
const KINDS := {
	&"pickups": {"label": "拾取物组", "field": "pickups"},
	&"triggers": {"label": "触发器组", "field": "triggers"},
	&"enemies": {"label": "敌人小队", "field": "enemies"},
	&"obstacles": {"label": "碰撞体积块", "field": "obstacles"},
	&"skeleton": {"label": "房间骨架（全部内容）", "field": "all"},
}

# ============================================================================
# 枚举 / 载入 / 保存 / 删除
# ============================================================================
static func available() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json") and not f.ends_with(".bak"):
			out.append(String(f.get_basename()))
	out.sort()
	return out

static func path_for(id: StringName) -> String:
	return "%s%s.json" % [DIR, String(id)]

static func load_template(id: StringName) -> Dictionary:
	var path := path_for(id)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

## 保存模板（原子写 + .bak）。payload 里的坐标必须已经是相对坐标。
static func save_template(id: StringName, kind: StringName, payload: Dictionary,
		display_name := "") -> Dictionary:
	if String(id) == "":
		return {"ok": false, "errors": ["模板 id 不能为空"]}
	if not KINDS.has(kind):
		return {"ok": false, "errors": ["未知模板种类：%s（可用 %s）" % [str(kind), str(KINDS.keys())]]}
	var data := {
		"id": String(id),
		"name": display_name if display_name != "" else String(id),
		"kind": String(kind),
		"payload": payload,
	}
	var errors := validate_template(data)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	var abs_path := ProjectSettings.globalize_path(path_for(id))
	var dir_abs := abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.make_dir_recursive_absolute(dir_abs)
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "errors": ["无法写入 %s" % tmp]}
	f.store_string(JSON.stringify(data, "  ") + "\n")
	f.close()
	if FileAccess.file_exists(abs_path):
		var src := FileAccess.open(abs_path, FileAccess.READ)
		if src != null:
			var text := src.get_as_text()
			src.close()
			var bak := FileAccess.open(abs_path + ".bak", FileAccess.WRITE)
			if bak != null:
				bak.store_string(text)
				bak.close()
	var err := DirAccess.rename_absolute(tmp, abs_path)
	if err != OK:
		return {"ok": false, "errors": ["改名失败 %d" % err]}
	return {"ok": true, "errors": [], "paths": [path_for(id)]}

static func delete_template(id: StringName) -> bool:
	var abs_path := ProjectSettings.globalize_path(path_for(id))
	var ok := true
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(abs_path + suffix):
			if DirAccess.remove_absolute(abs_path + suffix) != OK:
				ok = false
	return ok

# ============================================================================
# 校验
# ============================================================================
static func validate_template(data: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	var kind := StringName(str(data.get("kind", "")))
	if not KINDS.has(kind):
		problems.append("未知模板种类：%s" % str(kind))
		return problems
	var payload: Variant = data.get("payload", {})
	if not (payload is Dictionary):
		problems.append("payload 必须是对象")
		return problems
	var p: Dictionary = payload
	var field := str(KINDS[kind]["field"])
	if field == "all":
		for f in ["obstacles", "pickups", "triggers", "enemies"]:
			if p.has(f) and not (p[f] is Array):
				problems.append("payload.%s 必须是数组" % f)
		if not p.has("obstacles") and not p.has("pickups") and not p.has("triggers") and not p.has("enemies"):
			problems.append("房间骨架模板里什么都没有")
		return problems
	if not p.has(field) or not (p[field] is Array):
		problems.append("payload.%s 必须是数组" % field)
		return problems
	var entries: Array = p[field]
	if entries.is_empty():
		problems.append("模板内容为空（%s）" % field)
	for i in entries.size():
		var e: Variant = entries[i]
		if field == "obstacles":
			if not (e is Array) or (e as Array).size() < 2:
				problems.append("obstacles[%d] 不是 [x,y]" % i)
			continue
		if not (e is Dictionary):
			problems.append("%s[%d] 不是对象" % [field, i])
			continue
		var d: Dictionary = e
		if field == "pickups":
			var pk := str(d.get("kind", ""))
			if not Interactables.PICKUP_KINDS.has(StringName(pk)):
				problems.append("pickups[%d] 未知种类 '%s'" % [i, pk])
			if not d.has("tile"):
				problems.append("pickups[%d] 缺 tile（模板里应是相对坐标）" % i)
		elif field == "triggers":
			var tk := str(d.get("kind", ""))
			if not Interactables.TRIGGER_KINDS.has(StringName(tk)):
				problems.append("triggers[%d] 未知种类 '%s'" % [i, tk])
			if not d.has("tile"):
				problems.append("triggers[%d] 缺 tile" % i)
		elif field == "enemies":
			var et := str(d.get("type", ""))
			if not EnemyData.known_ids().has(StringName(et)):
				problems.append("enemies[%d] 未知敌人类型 '%s'" % [i, et])
			var pts: Variant = d.get("spawn_points", [])
			if not (pts is Array) or (pts as Array).is_empty():
				problems.append("enemies[%d] 没有生成点" % i)
	return problems

# ============================================================================
# 抓取（当前房间 → 模板 payload，坐标相对化）
# ============================================================================
## 返回 {"payload": {...}, "count": int}；count=0 表示这类内容当前房间没有
static func capture_from_doc(doc: EditorDoc, kind: StringName) -> Dictionary:
	if doc == null or not KINDS.has(kind):
		return {"payload": {}, "count": 0}
	match kind:
		&"pickups":
			var ps: Array = _rebase_entries(doc.pickups)
			return {"payload": {"pickups": ps}, "count": ps.size()}
		&"triggers":
			var ts: Array = _rebase_entries(doc.triggers)
			return {"payload": {"triggers": ts}, "count": ts.size()}
		&"enemies":
			var es: Array = []
			for g: Variant in doc.enemy_groups:
				es.append((g as Dictionary).duplicate(true))
			es = _rebase_enemies(es)
			return {"payload": {"enemies": es}, "count": es.size()}
		&"obstacles":
			var obs: Array = []
			for key: Variant in doc.obstacles.keys():
				var parts := String(key).split(",")
				if parts.size() == 2:
					obs.append([int(parts[0]), int(parts[1])])
			obs = _rebase_tiles(obs)
			return {"payload": {"obstacles": obs}, "count": obs.size()}
		&"skeleton":
			var all := {
				"obstacles": _rebase_tiles(_obstacle_list(doc)),
				"pickups": _rebase_entries(doc.pickups),
				"triggers": _rebase_entries(doc.triggers),
				"enemies": _rebase_enemies(_dup_enemies(doc)),
			}
			var n := (all["obstacles"] as Array).size() + (all["pickups"] as Array).size() \
				+ (all["triggers"] as Array).size() + (all["enemies"] as Array).size()
			return {"payload": all, "count": n}
	return {"payload": {}, "count": 0}

static func _obstacle_list(doc: EditorDoc) -> Array:
	var out: Array = []
	for key: Variant in doc.obstacles.keys():
		var parts := String(key).split(",")
		if parts.size() == 2:
			out.append([int(parts[0]), int(parts[1])])
	return out

static func _dup_enemies(doc: EditorDoc) -> Array:
	var out: Array = []
	for g: Variant in doc.enemy_groups:
		out.append((g as Dictionary).duplicate(true))
	return out

## 把 [{"tile":[x,y], "size":[w,h]}] 之类的条目平移到左上角
static func _rebase_entries(entries: Array) -> Array:
	var out: Array = []
	if entries.is_empty():
		return out
	var min_tile := Vector2i(1 << 30, 1 << 30)
	for e: Variant in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var t := Interactables.entry_tile(e as Dictionary)
		min_tile.x = mini(min_tile.x, t.x)
		min_tile.y = mini(min_tile.y, t.y)
	for e2: Variant in entries:
		if typeof(e2) != TYPE_DICTIONARY:
			continue
		var copy: Dictionary = (e2 as Dictionary).duplicate(true)
		var t2 := Interactables.entry_tile(copy)
		copy["tile"] = [t2.x - min_tile.x, t2.y - min_tile.y]
		out.append(copy)
	return out

static func _rebase_tiles(tiles: Array) -> Array:
	var out: Array = []
	if tiles.is_empty():
		return out
	var min_tile := Vector2i(1 << 30, 1 << 30)
	for t: Variant in tiles:
		var arr: Array = t
		min_tile.x = mini(min_tile.x, int(arr[0]))
		min_tile.y = mini(min_tile.y, int(arr[1]))
	for t2: Variant in tiles:
		var arr2: Array = t2
		out.append([int(arr2[0]) - min_tile.x, int(arr2[1]) - min_tile.y])
	return out

static func _rebase_enemies(groups: Array) -> Array:
	var out: Array = []
	if groups.is_empty():
		return out
	var min_tile := Vector2i(1 << 30, 1 << 30)
	for g: Variant in groups:
		for p: Variant in (g as Dictionary).get("spawn_points", []):
			var arr: Array = p
			min_tile.x = mini(min_tile.x, int(arr[0]))
			min_tile.y = mini(min_tile.y, int(arr[1]))
	for g2: Variant in groups:
		var copy: Dictionary = (g2 as Dictionary).duplicate(true)
		var pts: Array = []
		for p2: Variant in copy.get("spawn_points", []):
			var arr2: Array = p2
			pts.append([int(arr2[0]) - min_tile.x, int(arr2[1]) - min_tile.y])
		copy["spawn_points"] = pts
		out.append(copy)
	return out

# ============================================================================
# 套用（模板 + 锚点 → 当前房间）
# ============================================================================
## 返回 {"applied": int, "skipped": int, "details": Array[String]}
## 全部通过 EditorDoc 的编辑 API 落地，因此每一步都可撤销、也会参与校验与保存。
static func apply_to_doc(doc: EditorDoc, template: Dictionary, anchor: Vector2i) -> Dictionary:
	var report := {"applied": 0, "skipped": 0, "details": [] as Array}
	if doc == null or template.is_empty():
		report["details"].append("没有可套用的模板")
		return report
	var kind := StringName(str(template.get("kind", "")))
	var payload: Variant = template.get("payload", {})
	if not (payload is Dictionary):
		report["details"].append("模板 payload 非法")
		return report
	var p: Dictionary = payload
	var before := _content_count(doc)

	# 整批只留一个撤销点：用户按一次 Ctrl+Z 就能把"套用模板"整个退回
	doc.begin_batch()
	match kind:
		&"pickups":
			_apply_pickups(doc, p.get("pickups", []), anchor, report)
		&"triggers":
			_apply_triggers(doc, p.get("triggers", []), anchor, report)
		&"enemies":
			_apply_enemies(doc, p.get("enemies", []), anchor, report)
		&"obstacles":
			_apply_obstacles(doc, p.get("obstacles", []), anchor, report)
		&"skeleton":
			_apply_obstacles(doc, p.get("obstacles", []), anchor, report)
			_apply_pickups(doc, p.get("pickups", []), anchor, report)
			_apply_triggers(doc, p.get("triggers", []), anchor, report)
			_apply_enemies(doc, p.get("enemies", []), anchor, report)
		_:
			report["details"].append("未知模板种类：%s" % str(kind))
			doc.end_batch()
			return report
	doc.end_batch()

	report["applied"] = _content_count(doc) - before
	report["details"].append("套用 %s 于 (%d,%d)：成功 %d 项，跳过 %d 项"
		% [str(template.get("name", kind)), anchor.x, anchor.y, report["applied"], report["skipped"]])
	return report

static func _content_count(doc: EditorDoc) -> int:
	return doc.obstacle_count() + doc.enemy_total() + doc.pickups.size() + doc.triggers.size()

static func _apply_obstacles(doc: EditorDoc, tiles: Variant, anchor: Vector2i, report: Dictionary) -> void:
	if not (tiles is Array):
		return
	for t: Variant in tiles:
		var arr: Array = t
		var tile := anchor + Vector2i(int(arr[0]), int(arr[1]))
		if not doc.set_obstacle(tile, true):
			report["skipped"] = int(report["skipped"]) + 1

static func _apply_pickups(doc: EditorDoc, entries: Variant, anchor: Vector2i, report: Dictionary) -> void:
	if not (entries is Array):
		return
	for e: Variant in entries:
		var d: Dictionary = e
		var tile := anchor + Interactables.entry_tile(d)
		var pk := StringName(str(d.get("kind", "gold")))
		var amount := int(d.get("amount", -1))
		var ability := StringName(str(d.get("ability", "dash")))
		if not doc.add_pickup(pk, tile, amount, ability):
			report["skipped"] = int(report["skipped"]) + 1
			continue
		var idx := doc.pickup_at(tile)
		if idx >= 0 and bool(d.get("magnet", false)):
			doc.set_pickup_field(idx, "magnet", true)

static func _apply_triggers(doc: EditorDoc, entries: Variant, anchor: Vector2i, report: Dictionary) -> void:
	if not (entries is Array):
		return
	for e: Variant in entries:
		var d: Dictionary = e
		var tile := anchor + Interactables.entry_tile(d)
		var tk := StringName(str(d.get("kind", "message")))
		var size := Interactables.entry_size(d) / Interactables.TRIGGER_TILE
		var sz := Vector2i(int(size.x), int(size.y))
		if not doc.add_trigger(tk, tile, sz):
			report["skipped"] = int(report["skipped"]) + 1
			continue
		var idx := doc.trigger_at(tile)
		if idx < 0:
			continue
		for field in ["text", "once", "cooldown"]:
			if d.has(field):
				doc.set_trigger_field(idx, field, d[field])
		if d.has("size"):
			doc.set_trigger_field(idx, "size", d["size"])

static func _apply_enemies(doc: EditorDoc, groups: Variant, anchor: Vector2i, report: Dictionary) -> void:
	if not (groups is Array):
		return
	for g: Variant in groups:
		var d: Dictionary = g
		var type_id := StringName(str(d.get("type", "crawler")))
		for p: Variant in d.get("spawn_points", []):
			var arr: Array = p
			var tile := anchor + Vector2i(int(arr[0]), int(arr[1]))
			if not doc.add_enemy(type_id, tile):
				report["skipped"] = int(report["skipped"]) + 1
		# 同类型共用一个分组 → 数值写入会作用于该类型的所有点，这是刻意的简化
		for field in ["hp", "move_speed", "attack"]:
			if d.has(field):
				doc.set_group_field(type_id, field, d[field])

## 一行摘要（下拉列表用）
static func describe(template: Dictionary) -> String:
	if template.is_empty():
		return "（空模板）"
	var kind := StringName(str(template.get("kind", "")))
	var payload: Dictionary = template.get("payload", {})
	var n := 0
	var field := str(KINDS.get(kind, {}).get("field", ""))
	if field == "all":
		for f in ["obstacles", "pickups", "triggers", "enemies"]:
			n += (payload.get(f, []) as Array).size()
	else:
		n = (payload.get(field, []) as Array).size()
	return "%s（%s · %d 项）" % [str(template.get("name", template.get("id", "?"))),
		str(KINDS.get(kind, {}).get("label", str(kind))), n]
