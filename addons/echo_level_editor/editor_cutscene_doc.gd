class_name EditorCutsceneDoc
extends RefCounted
## ============================================================================
## EditorCutsceneDoc —— 过场动画编辑器的文档模型（时间轴的数据层）
## ----------------------------------------------------------------------------
## 与 EditorDoc / EditorBtDoc 同一套可靠性原则：
##   1. **JSON 是唯一事实源**：数据载体直接用运行时的 Cutscene（to_data/apply_data），
##      因此编辑器写出的文件必然能被游戏读回；
##   2. **快照式撤销栈**：整段过场只有几 KB，快照永远不会出现半撤销状态；
##   3. **写盘前三重校验**：① Cutscene.validate()（结构/字段/时间）；
##      ② **干跑自检 dry_run()**（在多个时间点采样每条轨道，确认不会崩、不会空）；
##      ③ 原子写 + .bak（与关卡/行为树编辑器一致）。
##
## 两种录制模式都收敛到这里（UI 只负责触发）：
##   * **实时录制**：游戏里按 F6 采样玩家轨迹 → user://cutscene_recording.json
##     → `stamp_from_samples()` 把采样点变成 actor 轨道关键帧（可设采样间隔与目标）；
##   * **手动打点**：`add_key()` / `set_key_field()` —— 在播放头位置按当前参数插一帧。
## ============================================================================

const MAX_UNDO := 120

var data: Cutscene = null
var source_path := ""
var _undo_stack: Array = []
var _redo_stack: Array = []
var _dirty := false

# ============================================================================
# 加载 / 新建
# ============================================================================
static func available_ids() -> Array:
	return Cutscene.available_ids()

static func load_doc(p_id: StringName) -> EditorCutsceneDoc:
	var cut := Cutscene.load_cutscene(p_id)
	if cut == null:
		return null
	var doc := EditorCutsceneDoc.new()
	doc.data = cut
	doc.source_path = cut.source_path
	doc._dirty = false
	return doc

## 新建一段过场（默认 6 秒，预置一条镜头轨与一条角色轨，各自一帧 —— 打开就能动）
static func create_doc(p_id: StringName) -> EditorCutsceneDoc:
	var doc := EditorCutsceneDoc.new()
	doc.data = Cutscene.new()
	doc.data.id = p_id
	doc.data.apply_data({
		"name": String(p_id),
		"duration": 6.0,
		"tracks": [
			{"kind": "camera", "keys": [{"t": 0.0, "x": 160.0, "y": 140.0, "zoom": 2.0}]},
			{"kind": "actor", "target": "player", "keys": [{"t": 0.0, "x": 32.0, "y": 174.0, "facing": 1}]},
		],
	})
	doc.source_path = "%s%s.json" % [Cutscene.DIR, String(p_id)]
	doc._dirty = true
	return doc

# ============================================================================
# 查询
# ============================================================================
func is_dirty() -> bool:
	return _dirty

func track_count() -> int:
	return data.track_count()

func key_count() -> int:
	return data.key_count()

func duration() -> float:
	return data.duration

func track(i: int) -> Dictionary:
	if i < 0 or i >= data.tracks.size():
		return {}
	return data.tracks[i]

func keys(i: int) -> Array:
	return track(i).get("keys", [])

func key(track_i: int, key_i: int) -> Dictionary:
	var ks := keys(track_i)
	if key_i < 0 or key_i >= ks.size():
		return {}
	return ks[key_i]

func summary() -> String:
	return data.summary()

# ============================================================================
# 编辑（每个操作先压快照 → 都可撤销）
# ============================================================================
func set_name(v: String) -> bool:
	if data.name == v:
		return false
	_push_undo()
	data.name = v
	_dirty = true
	return true

## 时长；若缩短到比最后一个关键帧还短，则同时把越界的关键帧夹回时长内
func set_duration(v: float) -> bool:
	var d := maxf(v, 0.1)
	if is_equal_approx(data.duration, d):
		return false
	_push_undo()
	data.duration = d
	for tr: Variant in data.tracks:
		var ks: Array = (tr as Dictionary).get("keys", [])
		for k: Variant in ks:
			var kd: Dictionary = k
			if float(kd.get("t", 0.0)) > d:
				kd["t"] = d
	_dirty = true
	return true

## 加一条轨道；返回下标（失败 -1）
func add_track(kind: StringName, target := "") -> int:
	if not Cutscene.TRACK_KINDS.has(kind):
		return -1
	if kind == &"actor" and target == "":
		target = "player"
	_push_undo()
	data.tracks.append({"kind": String(kind), "target": target, "keys": []})
	_dirty = true
	return data.tracks.size() - 1

func remove_track(i: int) -> bool:
	if i < 0 or i >= data.tracks.size():
		return false
	_push_undo()
	data.tracks.remove_at(i)
	_dirty = true
	return true

func set_track_field(i: int, key: String, value: Variant) -> bool:
	var tr := track(i)
	if tr.is_empty() or tr.get(key, null) == value:
		return false
	_push_undo()
	tr[key] = value
	_dirty = true
	return true

## 在指定时间插一个关键帧（手动打点）；values 为要写入的字段
## 返回新关键帧下标（时间重复时覆盖同刻的那一帧）
func add_key(track_i: int, time: float, values: Dictionary = {}) -> int:
	var tr := track(track_i)
	if tr.is_empty():
		return -1
	_push_undo()
	var ks: Array = tr.get("keys", [])
	var t := clampf(time, 0.0, data.duration)
	for i in ks.size():
		if is_equal_approx(float((ks[i] as Dictionary).get("t", -1.0)), t):
			for k: Variant in values.keys():
				(ks[i] as Dictionary)[k] = values[k]
			_dirty = true
			return i
	var entry := {"t": t}
	for k2: Variant in values.keys():
		entry[str(k2)] = values[k2]
	ks.append(entry)
	ks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_dirty = true
	return ks.find(entry)

func remove_key(track_i: int, key_i: int) -> bool:
	var ks := keys(track_i)
	if key_i < 0 or key_i >= ks.size():
		return false
	_push_undo()
	ks.remove_at(key_i)
	_dirty = true
	return true

## 一次写入同一关键帧的**多个字段**，只产生**一步撤销**（第 49 轮）
## ----------------------------------------------------------------------------
## 为什么需要：预览里点一次「打关键帧」要写 x/y/zoom 三个字段 ✗，
## 若逐个调 `set_key_field` 就是 3 步撤销 ✗ → 用户按一次撤销只退回一个字段 ✗。
## 这里先算"哪些字段真的变了"，只有确实有变化才 `_push_undo()` 一次，
## 然后一次性写回 → 一次操作 = 一个撤销点 ✓（与主流编辑器的直觉一致）。
func set_key_fields(track_i: int, key_i: int, values: Dictionary) -> int:
	var kd := key(track_i, key_i)
	if kd.is_empty():
		return 0
	var changed := 0
	for k: Variant in values.keys():
		if kd.get(str(k), null) != values[k]:
			changed += 1
	if changed == 0:
		return 0
	_push_undo()                       # ← 只有一步（关键）
	for k2: Variant in values.keys():
		kd[str(k2)] = values[k2]
	if values.has("t"):
		kd["t"] = clampf(float(values["t"]), 0.0, data.duration)
		var ks := keys(track_i)
		ks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_dirty = true
	return changed

func set_key_field(track_i: int, key_i: int, key: String, value: Variant) -> bool:
	var kd := key(track_i, key_i)
	if kd.is_empty() or kd.get(key, null) == value:
		return false
	_push_undo()
	kd[key] = value
	if key == "t":
		kd["t"] = clampf(float(value), 0.0, data.duration)
		var ks := keys(track_i)
		ks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_dirty = true
	return true

## 拖动关键帧（改时间并重排）；返回它在排序后的新下标
func move_key(track_i: int, key_i: int, new_time: float) -> int:
	var kd := key(track_i, key_i)
	if kd.is_empty():
		return -1
	var t := clampf(new_time, 0.0, data.duration)
	if is_equal_approx(float(kd.get("t", 0.0)), t):
		return key_i
	_push_undo()
	kd["t"] = t
	var ks := keys(track_i)
	ks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	_dirty = true
	return ks.find(kd)

## 实时录制导入：把游戏采样点变成某条 actor 轨道的关键帧
## samples: [{"t": float, "x": float, "y": float, "facing": int}, ...]
## spacing: 采样间隔（秒）；会把落在同一格的点合并；返回写入的关键帧数
func stamp_from_samples(samples: Array, spacing := 0.1, target := "player") -> int:
	if samples.is_empty():
		return 0
	# 找（或建）目标 actor 轨道
	var track_i := -1
	for i in data.tracks.size():
		var tr: Dictionary = data.tracks[i]
		if StringName(str(tr.get("kind", ""))) == &"actor" and str(tr.get("target", "")) == target:
			track_i = i
			break
	if track_i < 0:
		track_i = add_track(&"actor", target)
	_push_undo()
	var ks: Array = track(track_i).get("keys", [])
	ks.clear()
	var step := maxf(spacing, 0.02)
	var next_t := 0.0
	for s: Variant in samples:
		var sample: Dictionary = s
		var t := float(sample.get("t", 0.0))
		if t < next_t - 0.0001:
			continue
		next_t = t + step
		ks.append({
			"t": clampf(t, 0.0, data.duration),
			"x": float(sample.get("x", 0.0)),
			"y": float(sample.get("y", 0.0)),
			"facing": int(sample.get("facing", 1)),
		})
	# 录制比过场长时自动延长时间轴
	var last_t := float((ks[ks.size() - 1] as Dictionary).get("t", 0.0))
	if last_t > data.duration:
		data.duration = last_t + 0.5
	_dirty = true
	return ks.size()

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
	_redo_stack.append(data.to_data().duplicate(true))
	data.apply_data(_undo_stack.pop_back())
	_dirty = true
	return true

func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(data.to_data().duplicate(true))
	data.apply_data(_redo_stack.pop_back())
	_dirty = true
	return true

func _push_undo() -> void:
	_undo_stack.append(data.to_data().duplicate(true))
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()

# ============================================================================
# 校验 / 干跑 / 保存
# ============================================================================
func validate() -> Array[String]:
	return data.validate()

## 干跑自检：在 0 / 1/4 / 1/2 / 3/4 / 末 五个时间点采样每条轨道。
## 编辑器能保存 ≠ 游戏能播 —— 这一步专门抓"采样时会崩/会空"的数据。
func dry_run() -> Array[String]:
	var problems: Array[String] = []
	if data.tracks.is_empty():
		problems.append("干跑：没有任何轨道")
		return problems
	for i in data.tracks.size():
		var tr: Dictionary = data.tracks[i]
		var kind := str(tr.get("kind", ""))
		for frac in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var t := data.duration * float(frac)
			var values := Cutscene.sample_track(tr, t)
			if values.is_empty() and not keys(i).is_empty():
				problems.append("干跑：轨道[%d]（%s）在 %.2fs 采样为空" % [i, kind, t])
	return problems

## 保存：校验 + 干跑 + 原子写 + .bak；成功返回 {"ok":true, "paths":[..]}
func save() -> Dictionary:
	var errors: Array[String] = []
	errors.append_array(validate())
	errors.append_array(dry_run())
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "paths": []}
	if not _write_atomic(source_path, data.to_data()):
		return {"ok": false, "errors": ["写入失败：%s" % source_path], "paths": []}
	# 存完立刻用游戏侧读回一次（最硬的回归）
	var back := Cutscene.load_cutscene(data.id)
	if back == null:
		return {"ok": false, "errors": ["写盘后游戏侧读不回来：%s" % source_path], "paths": []}
	_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	return {"ok": true, "errors": [], "paths": [source_path]}

func _write_atomic(path: String, payload: Dictionary) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("EditorCutsceneDoc：无法写入 %s" % tmp)
		return false
	f.store_string(JSON.stringify(payload, "  ") + "\n")
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
		push_error("EditorCutsceneDoc：改名失败 %d（%s）" % [err, abs_path])
		return false
	return true

## 录制采样文件的读取（游戏里 F6 录制时写的）
static func read_recording(path := "user://cutscene_recording.json") -> Array:
	if not FileAccess.file_exists(path):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	var arr: Variant = (parsed as Dictionary).get("samples", [])
	return arr if arr is Array else []
