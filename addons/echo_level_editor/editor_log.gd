class_name EditorLog
extends RefCounted
## ============================================================================
## EditorLog —— 编辑器插件的统一操作日志（res://.editor_notes.log）
## ----------------------------------------------------------------------------
## 为什么需要它：编辑器是"点在编辑器里、运行在引擎里"的，出问题时看不到任何痕迹。
## 四个页签（关卡 / 敌人 AI / 关卡图 / 过场动画）现在都往**同一个文件**追加一行
## "时间 + 页签 + 操作结果"，于是：
##   * 真机点击验证有了确定性读出口（截图只能看"当前像素"，日志有先后顺序）；
##   * 用户报"点了没反应"时，先看日志就能区分"没点到 / 点到了但被校验拒绝 / 真出错"。
##
## 约定：成功与失败都写；错误行带 [错误] 前缀（便于 grep）。
## 只保留最近 MAX_LINES 行（编辑器会一直开着，文件不能无限增长）。
## ============================================================================

const PATH := "res://.editor_notes.log"
const MAX_LINES := 400

## 记一条：tag 是页签短名（关卡 / 敌人AI / 关卡图 / 过场）
static func note(text: String, is_error := false, tag := "关卡") -> void:
	print("[残响%s]%s %s" % [tag, "[错误]" if is_error else "", text])
	_append("[%s]%s %s %s" % [tag, "[错误]" if is_error else "", _clock(), text])

## 清空日志（页签初始化时可选调用）
static func clear() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("")
		f.close()

## 读全部行（真机验证时读它 / 用户排查时可全选复制）
static func read_all() -> PackedStringArray:
	if not FileAccess.file_exists(PATH):
		return PackedStringArray()
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var text := f.get_as_text()
	f.close()
	return text.split("\n")

## 只看带 [错误] 的行
static func errors_only() -> PackedStringArray:
	var out := PackedStringArray()
	for line in read_all():
		if line.contains("[错误]"):
			out.append(line)
	return out

static func _append(line: String) -> void:
	var lines := read_all()
	# split 会留一个空尾元素，先去掉再追加，避免文件里全是空行
	while not lines.is_empty() and lines[lines.size() - 1].strip_edges() == "":
		lines.remove_at(lines.size() - 1)
	lines.append(line)
	while lines.size() > MAX_LINES:
		lines.remove_at(0)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()

static func _clock() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d:%02d" % [int(t["hour"]), int(t["minute"]), int(t["second"])]
