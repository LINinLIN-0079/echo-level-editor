class_name EditorBtDoc
extends RefCounted
## ============================================================================
## EditorBtDoc —— 行为树编辑器文档模型（敌人 AI 可视化编辑的纯数据层）
## ----------------------------------------------------------------------------
## 设计目标（对应"直接控制敌人状态…代替底层代码编辑"）：
##   策划在编辑器里点几下就能改敌人 AI —— 加一个"血量低于 30% 就狂暴"的分支，
##   不需要碰任何 GDScript。做完的树写回 data/ai/<敌人>.json，游戏立刻生效。
##
## 三条与 EditorDoc（关卡文档）一致的可靠性原则：
##   1. **JSON 是唯一事实源**：直接把磁盘上的嵌套字典当编辑对象，未知字段原样保留
##      （含顶层 `_comment`），因此"加载 → 改 → 存"是无损往返；
##   2. **快照式撤销栈**：整棵树只有几 KB，快照比命令模式简单且绝不会出现半撤销状态；
##   3. **写盘前双重校验**：先按 BTLibrary.catalog() 校验结构与参数类型，
##      再用**游戏侧**的 BehaviorTree.from_data() 真构建一次 —— 编辑器写出的数据
##      必须能被运行时读回，这是最硬的回归。
##
## 节点定位用"路径"（Array[int]，从根出发的子节点下标序列）：[] 是根，
## [1, 0] 是"根的第二个子节点的第一个子节点"。路径比对象引用更适合 UI（Tree 控件天然给路径）。
## ============================================================================

const AI_DIR := "res://data/ai/"
const MAX_UNDO := 120
## 超出这些阈值只提示不阻塞（防手滑写出巨型树）
const SOFT_DEPTH := 12
const SOFT_NODES := 200

var type_id: StringName = &""          ## 敌人类型（= 文件名，如 crawler）
var file_path := ""                    ## res://data/ai/<type>.json
## 根节点字典（同时也是"整份 JSON 文档"：顶层 _comment 等额外字段都在这里）
var root: Dictionary = {}

var _undo_stack: Array = []
var _redo_stack: Array = []
var _dirty := false

# ============================================================================
# 加载
# ============================================================================
## 现有哪些敌人行为数据（编辑器左侧列表直接用）
static func available_types() -> Array:
	var out: Array = []
	var dir := DirAccess.open(AI_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json") and not f.ends_with(".bak"):
			out.append(String(f.get_basename()))
	out.sort()
	return out

## 加载某个敌人的行为数据；文件不存在时给一棵最小可用树（让编辑器能"从零开始"）
static func load_doc(p_type: StringName) -> EditorBtDoc:
	var doc := EditorBtDoc.new()
	doc.type_id = p_type
	doc.file_path = "%s%s.json" % [AI_DIR, String(p_type)]
	var raw := _read_json(doc.file_path)
	if raw.is_empty() or not raw.has("type"):
		doc.root = {"type": "selector", "name": "根", "children": [{"type": "action.idle"}]}
		doc._dirty = true
		return doc
	doc.root = raw
	doc._dirty = false
	return doc

# ============================================================================
# 查询
# ============================================================================
func is_dirty() -> bool:
	return _dirty

## 顶层注释（保留在 JSON 里，方便策划写"这棵树是干什么的"）
func comment() -> String:
	return str(root.get("_comment", ""))

func set_comment(text: String) -> bool:
	if comment() == text:
		return false
	_push_undo()
	root["_comment"] = text
	_dirty = true
	return true

## 路径 → 节点字典（不存在返回空字典）。注意：返回的是**引用**，就地改它即改树。
func node_at(path: Array) -> Dictionary:
	var node := root
	for seg: Variant in path:
		var kids: Array = node.get("children", [])
		var i := int(seg)
		if i < 0 or i >= kids.size():
			return {}
		var kid: Variant = kids[i]
		if typeof(kid) != TYPE_DICTIONARY:
			return {}
		node = kid
	return node

## 路径 → [父节点字典, 该节点在父节点 children 里的下标]；根返回 [{}, -1]
func parent_and_index(path: Array) -> Array:
	if path.is_empty():
		return [{}, -1]
	return [node_at(path.slice(0, path.size() - 1)), int(path[path.size() - 1])]

func children_of(path: Array) -> Array:
	var n := node_at(path)
	if n.is_empty():
		return []
	var kids: Variant = n.get("children", [])
	return kids if kids is Array else []

func type_of(path: Array) -> String:
	return str(node_at(path).get("type", ""))

func name_of(path: Array) -> String:
	return str(node_at(path).get("name", ""))

## 规范化类型名（把别名如 "patrol" 解成标准名 "action.patrol_move"）
static func canonical(type_name: String) -> String:
	var n := BTLibrary.create(type_name)
	return n.type_name if n != null else ""

## 目录条目（自动解析别名）
static func entry_for(type_name: String) -> Dictionary:
	var c := canonical(type_name)
	if c == "":
		return {}
	return BTLibrary.entry_for(c)

## 某个节点的显示标题（"顺序（全部成功才成功）"）
static func title_for(type_name: String) -> String:
	var e := entry_for(type_name)
	if e.is_empty():
		return "未知类型：%s" % type_name
	return str(e.get("title", type_name))

## 该节点还缺几个子节点（>0 表示不合法；UI 用它标红）
static func missing_children(type_name: String, child_count: int) -> int:
	var e := entry_for(type_name)
	if e.is_empty():
		return 0
	return maxi(int(e.get("min_children", 0)) - child_count, 0)

## 该节点是否还能再加子节点
static func can_accept_child(type_name: String, child_count: int) -> bool:
	var e := entry_for(type_name)
	if e.is_empty():
		return false
	var maxc := int(e.get("max_children", -1))
	return maxc < 0 or child_count < maxc

func node_count() -> int:
	return _count(root)

func depth() -> int:
	return _depth(root)

func _count(n: Dictionary) -> int:
	var total := 1
	for k: Variant in n.get("children", []):
		if k is Dictionary:
			total += _count(k)
	return total

func _depth(n: Dictionary) -> int:
	var best := 1
	for k: Variant in n.get("children", []):
		if k is Dictionary:
			best = maxi(best, 1 + _depth(k))
	return best

## 扁平列表（UI 的 Tree 控件按它逐行构建）：[{path, depth, type, title, missing, children}]
func flat_list() -> Array:
	var out: Array = []
	_flatten(root, [], 0, out)
	return out

func _flatten(n: Dictionary, path: Array, d: int, out: Array) -> void:
	var t := str(n.get("type", ""))
	var kids: Array = n.get("children", [])
	out.append({
		"path": path.duplicate(),
		"depth": d,
		"type": t,
		"title": title_for(t),
		"name": str(n.get("name", "")),
		"missing": missing_children(t, kids.size()),
		"child_count": kids.size(),
	})
	for i in kids.size():
		var k: Variant = kids[i]
		if k is Dictionary:
			_flatten(k, path + [i], d + 1, out)

# ============================================================================
# 编辑（每个操作先压快照 → 都可撤销）
# ============================================================================
## 在 parent_path 下加一个节点；返回新节点的路径（失败返回 []）
## 会把目录里的参数默认值写进数据 —— 加完即可运行，不必逐个填参数（傻瓜式）
func add_node(parent_path: Array, type_name: String, at_index: int = -1) -> Array:
	var parent := node_at(parent_path)
	if parent.is_empty():
		return []
	var c := canonical(type_name)
	if c == "":
		return []
	var kids := _ensure_children(parent)
	# 注意：要判断的是**父节点**还能不能收子节点（父节点类型 + 它当前的孩子数），
	# 而不是新子节点自己的容量 —— 早期版本传错参数，导致"给 sequence 加叶子"总被拒。
	if not can_accept_child(str(parent.get("type", "")), kids.size()):
		return []
	_push_undo()
	var node := {"type": c}
	var e := entry_for(c)
	var params := {}
	for p: Variant in e.get("params", []):
		var pd: Dictionary = p
		params[str(pd["key"])] = pd.get("default", null)
	if not params.is_empty():
		node["params"] = params
	var idx := at_index if at_index >= 0 and at_index <= kids.size() else kids.size()
	kids.insert(idx, node)
	_dirty = true
	return parent_path + [idx]

## 删节点（根不能删）
func remove_node(path: Array) -> bool:
	if path.is_empty():
		return false
	var res := parent_and_index(path)
	var parent: Dictionary = res[0]
	var idx := int(res[1])
	if parent.is_empty() or idx < 0:
		return false
	_push_undo()
	(parent["children"] as Array).remove_at(idx)
	_dirty = true
	return true

## 在同级里上/下移（delta = -1 / +1）
func move_node(path: Array, delta: int) -> bool:
	if path.is_empty():
		return false
	var res := parent_and_index(path)
	var parent: Dictionary = res[0]
	var idx := int(res[1])
	if parent.is_empty():
		return false
	var kids: Array = parent.get("children", [])
	var target := idx + delta
	if target < 0 or target >= kids.size():
		return false
	_push_undo()
	var n: Variant = kids[idx]
	kids.remove_at(idx)
	kids.insert(target, n)
	_dirty = true
	return true

## 把节点挂到另一个父节点下（拒绝挂到自己或自己的后代 → 防环）
func reparent(path: Array, new_parent_path: Array) -> bool:
	if path.is_empty():
		return false
	if _is_prefix(path, new_parent_path):
		return false
	var node := node_at(path)
	var new_parent := node_at(new_parent_path)
	if node.is_empty() or new_parent.is_empty():
		return false
	var kids := _ensure_children(new_parent)
	if not can_accept_child(str(new_parent.get("type", "")), kids.size()):
		return false
	_push_undo()
	var res := parent_and_index(path)
	if not (res[0] as Dictionary).is_empty():
		((res[0] as Dictionary)["children"] as Array).remove_at(int(res[1]))
	# new_parent 是字典引用，移走旧位置不会让它失效，因此这里追加是安全的
	_ensure_children(new_parent).append(node)
	_dirty = true
	return true

## 改节点类型：保留子节点；参数保留新类型也声明的部分，其余按目录默认值补齐
func set_type(path: Array, type_name: String) -> bool:
	var node := node_at(path)
	if node.is_empty():
		return false
	var c := canonical(type_name)
	if c == "" or str(node.get("type", "")) == c:
		return false
	_push_undo()
	var old: Dictionary = node.get("params", {}) if node.get("params", {}) is Dictionary else {}
	var e := entry_for(c)
	var params := {}
	for p: Variant in e.get("params", []):
		var pd: Dictionary = p
		var key := str(pd["key"])
		params[key] = old[key] if old.has(key) else pd.get("default", null)
	node["type"] = c
	if params.is_empty():
		node.erase("params")
	else:
		node["params"] = params
	_dirty = true
	return true

func set_param(path: Array, key: String, value: Variant) -> bool:
	var node := node_at(path)
	if node.is_empty():
		return false
	var params: Variant = node.get("params", {})
	if not (params is Dictionary):
		params = {}
		node["params"] = params
	if (params as Dictionary).get(key, null) == value:
		return false
	_push_undo()
	(params as Dictionary)[key] = value
	_dirty = true
	return true

func get_param(path: Array, key: String, fallback: Variant = null) -> Variant:
	var params: Variant = node_at(path).get("params", {})
	if params is Dictionary and (params as Dictionary).has(key):
		return (params as Dictionary)[key]
	var e := entry_for(type_of(path))
	for p: Variant in e.get("params", []):
		var pd: Dictionary = p
		if str(pd["key"]) == key:
			return pd.get("default", fallback)
	return fallback

func set_node_name(path: Array, node_name: String) -> bool:
	var node := node_at(path)
	if node.is_empty() or str(node.get("name", "")) == node_name:
		return false
	_push_undo()
	if node_name == "":
		node.erase("name")
	else:
		node["name"] = node_name
	_dirty = true
	return true

## 移除与目录默认值相同的参数（让 JSON 精简、只留"真正的调参"）
func prune_defaults() -> int:
	_push_undo()
	var removed := _prune(root)
	if removed > 0:
		_dirty = true
	else:
		_undo_stack.pop_back()
	return removed

func _prune(n: Dictionary) -> int:
	var removed := 0
	var e := entry_for(str(n.get("type", "")))
	if e.is_empty():
		return 0
	var params: Variant = n.get("params", {})
	if params is Dictionary:
		for p: Variant in e.get("params", []):
			var pd: Dictionary = p
			var key := str(pd["key"])
			if (params as Dictionary).has(key) and (params as Dictionary)[key] == pd.get("default", null):
				(params as Dictionary).erase(key)
				removed += 1
		if (params as Dictionary).is_empty():
			n.erase("params")
	for k: Variant in n.get("children", []):
		if k is Dictionary:
			removed += _prune(k)
	return removed

## 复制子树（含全部子孙）到同级后面；返回新节点路径（失败返回 []）
func duplicate_node(path: Array) -> Array:
	if path.is_empty():
		return []
	var res := parent_and_index(path)
	var parent: Dictionary = res[0]
	var idx := int(res[1])
	if parent.is_empty() or idx < 0:
		return []
	var kids: Array = parent.get("children", [])
	if not can_accept_child(str(parent.get("type", "")), kids.size()):
		return []
	_push_undo()
	var copy: Variant = (kids[idx] as Dictionary).duplicate(true)
	kids.insert(idx + 1, copy)
	_dirty = true
	return path.slice(0, path.size() - 1) + [idx + 1]

## 子树节点数（复制后用状态栏汇报）
func count_subtree(path: Array) -> int:
	var n := node_at(path)
	return 0 if n.is_empty() else _count(n)

## 取（必要时创建）节点的 children 数组。
## ⚠ 必须把新数组**写回节点**：曾写成 `node.get("children", [])`，缺失键时拿到的是
##   临时数组字面量，插进去就丢了 —— 表现是"给刚建的节点加子节点永远无效"（实测抓到）。
func _ensure_children(node: Dictionary) -> Array:
	var kids: Variant = node.get("children", null)
	if kids is Array:
		return kids
	var fresh: Array = []
	node["children"] = fresh
	return fresh

func _is_prefix(path: Array, other: Array) -> bool:
	if path.size() > other.size():
		return false
	for i in path.size():
		if int(path[i]) != int(other[i]):
			return false
	return true

# ============================================================================
# 撤销 / 重做（快照栈）
# ============================================================================
func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

func undo_depth() -> int:
	return _undo_stack.size()

func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_redo_stack.append(root.duplicate(true))
	root = _undo_stack.pop_back()
	_dirty = true
	return true

func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(root.duplicate(true))
	root = _redo_stack.pop_back()
	_dirty = true
	return true

func _push_undo() -> void:
	_undo_stack.append(root.duplicate(true))
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()

# ============================================================================
# 校验（写盘前的守门员）
# ============================================================================
## 返回 {"errors": [...], "warnings": [...]}；errors 非空则拒绝保存
func validate() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if root.is_empty() or str(root.get("type", "")) == "":
		errors.append("根节点缺失或没有 type")
		return {"errors": errors, "warnings": warnings}

	_validate_node(root, "根", errors, warnings)

	if depth() > SOFT_DEPTH:
		warnings.append("树深 %d 层，偏深（建议 ≤ %d）" % [depth(), SOFT_DEPTH])
	if node_count() > SOFT_NODES:
		warnings.append("节点数 %d，偏多（建议 ≤ %d）" % [node_count(), SOFT_NODES])
	var root_entry := entry_for(str(root.get("type", "")))
	if root_entry.is_empty() or int(root_entry.get("min_children", 0)) == 0:
		warnings.append("根节点是叶子（如「待机」）：整棵树只有一种行为，通常应换成「选择/顺序」")
	return {"errors": errors, "warnings": warnings}

func _validate_node(n: Dictionary, where: String, errors: Array[String], warnings: Array[String]) -> void:
	var t := str(n.get("type", ""))
	var e := entry_for(t)
	if e.is_empty():
		errors.append("%s：未知节点类型 '%s'（不在 BTLibrary 目录里）" % [where, t])
		return
	var kids: Variant = n.get("children", [])
	if not (kids is Array):
		errors.append("%s（%s）：children 不是数组" % [where, t])
		return
	var kid_arr: Array = kids
	var minc := int(e.get("min_children", 0))
	var maxc := int(e.get("max_children", -1))
	if kid_arr.size() < minc:
		errors.append("%s（%s）：至少需要 %d 个子节点，当前 %d 个" % [where, str(e.get("title", t)), minc, kid_arr.size()])
	if maxc >= 0 and kid_arr.size() > maxc:
		errors.append("%s（%s）：最多 %d 个子节点，当前 %d 个" % [where, str(e.get("title", t)), maxc, kid_arr.size()])

	# 参数类型
	var params: Variant = n.get("params", {})
	var declared: Array = e.get("params", [])
	if params is Dictionary:
		for p: Variant in declared:
			var pd: Dictionary = p
			var key := str(pd["key"])
			if not (params as Dictionary).has(key):
				continue
			if not _param_type_ok(str(pd.get("type", "any")), (params as Dictionary)[key]):
				errors.append("%s（%s）：参数 %s 需要 %s 类型，当前是 %s"
					% [where, t, key, str(pd.get("type", "any")), type_string(typeof((params as Dictionary)[key]))])
		var declared_keys: Array = []
		for p: Variant in declared:
			declared_keys.append(str((p as Dictionary)["key"]))
		for k: Variant in (params as Dictionary).keys():
			if not declared_keys.has(str(k)):
				warnings.append("%s（%s）：参数 %s 不在目录里（运行时会被忽略）" % [where, t, str(k)])
	elif params != null and not (params is Dictionary) and n.has("params"):
		errors.append("%s（%s）：params 不是对象" % [where, t])

	# guard 语义提示：第一个子节点应为条件
	if t == "guard" and kid_arr.size() >= 1:
		var first: Variant = kid_arr[0]
		if first is Dictionary and not str((first as Dictionary).get("type", "")).begins_with("condition."):
			warnings.append("%s：guard 的第一个子节点通常应是条件（当前是 %s）"
				% [where, str((first as Dictionary).get("type", ""))])

	for i in kid_arr.size():
		var k: Variant = kid_arr[i]
		if k is Dictionary:
			_validate_node(k, "%s/%d" % [where, i], errors, warnings)
		else:
			errors.append("%s：第 %d 个子节点不是对象" % [where, i])

func _param_type_ok(kind: String, value: Variant) -> bool:
	match kind:
		"int", "float":
			return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
		"bool":
			return typeof(value) == TYPE_BOOL
		"string", "enum":
			return typeof(value) == TYPE_STRING
		"array":
			return typeof(value) == TYPE_ARRAY
		_:
			return true          # any：任何类型都行

## UI 状态栏用的一行摘要
func summary() -> String:
	var v := validate()
	return "节点 %d · 深 %d · %s" % [
		node_count(), depth(),
		"校验通过" if (v["errors"] as Array).is_empty() else "%d 个错误" % (v["errors"] as Array).size(),
	]

# ============================================================================
# 保存
# ============================================================================
func to_data() -> Dictionary:
	if comment() != "":
		root["_comment"] = comment()
	return root

## 保存：目录校验 → 游戏侧真构建一次 → 原子写 + .bak
## 返回 {"ok", "errors", "warnings", "paths", "nodes"}
func save() -> Dictionary:
	var v := validate()
	var errors: Array = v["errors"]
	var warnings: Array = v["warnings"]
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "warnings": warnings, "paths": [], "nodes": 0}

	# 最硬的回归：用游戏侧代码把数据建成真行为树，构建不了就绝不写盘
	var tree := BehaviorTree.from_data(to_data())
	if not tree.is_valid():
		return {"ok": false, "errors": ["游戏侧无法构建（空树）"], "warnings": warnings, "paths": [], "nodes": 0}
	if not tree.unknown_types.is_empty():
		return {"ok": false,
			"errors": ["游戏侧不认识这些类型：%s" % str(tree.unknown_types)],
			"warnings": warnings, "paths": [], "nodes": tree.node_count()}

	if not _write_atomic(file_path, to_data()):
		return {"ok": false, "errors": ["写入失败：%s" % file_path], "warnings": warnings, "paths": [], "nodes": tree.node_count()}
	_dirty = false
	_undo_stack.clear()
	_redo_stack.clear()
	return {"ok": true, "errors": [], "warnings": warnings, "paths": [file_path], "nodes": tree.node_count()}

## 原子写：先写 .tmp，把上一版备份成 .bak，再改名替换（与关卡编辑器同一套策略）
func _write_atomic(path: String, data: Dictionary) -> bool:
	if path.begins_with("res://"):
		return _write_abs(ProjectSettings.globalize_path(path), data)
	return _write_abs(path, data)

func _write_abs(abs_path: String, data: Dictionary) -> bool:
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("EditorBtDoc：无法写入 %s" % tmp)
		return false
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
		push_error("EditorBtDoc：改名失败 %d（%s）" % [err, abs_path])
		return false
	return true

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
