@tool
class_name EditorPlaytest
extends RefCounted
## ============================================================================
## EditorPlaytest —— 「一键试玩」的标记文件读写（纯逻辑，编辑器插件与游戏两侧共用）
## ----------------------------------------------------------------------------
## 为什么需要标记文件：编辑器插件（Godot 编辑器进程）与游戏（被启动的项目进程）
## 是两个独立进程，中间没有共享内存。想做到"编辑器里点试玩 → 游戏直接进入我正在
## 编辑的那一房"，只能靠磁盘上的一个小文件传递意图。
##
## 路径为什么选 res://（踩过的坑）：
##   最初想写进"游戏侧 user://"，于是用 OS.get_data_dir() + 项目名去拼 —— 实测
##   Windows 上 OS.get_data_dir() 返回的是 `%APPDATA%`（**不含 Godot 一级**），
##   而游戏真实目录是 `%APPDATA%/Godot/app_userdata/<项目名>`，两边对不上，
##   编辑器写的标记游戏永远读不到（headless 自测还测不出来，因为两侧用了同一个错函数）。
##   改成项目目录下的隐藏文件后，编辑器与游戏看到的是**同一个 res:// 路径**，
##   不再需要任何路径推算；导出包里该文件也不存在（点号开头的文件不会被导出）。
## ============================================================================

## 标记文件（项目目录下的隐藏文件；两侧共用这一个常量）
const MARKER_REL := "res://.editor_playtest.json"

## 供 FileAccess/DirAccess 使用的绝对路径（编辑器写盘用）
static func marker_abs_path() -> String:
	return ProjectSettings.globalize_path(MARKER_REL)

## 标记的 res:// 路径（游戏读用；等价于 MARKER_REL）
static func marker_path() -> String:
	return MARKER_REL

## 写标记（插件调用）：声明"下次启动游戏时直接进入 room_id 这一房"
static func write_marker(room_id: StringName) -> bool:
	var f := FileAccess.open(marker_abs_path(), FileAccess.WRITE)
	if f == null:
		push_warning("EditorPlaytest：无法写入标记 %s" % marker_abs_path())
		return false
	f.store_string(JSON.stringify({"room": String(room_id)}))
	f.close()
	return true

## 读并删除标记（游戏启动时调用；返回空表示这次不是试玩启动）
static func consume_marker() -> StringName:
	var room := peek_marker()
	if room != &"":
		clear_marker()
	return room

## 只读不删（编辑器启动时用来回到刚才编辑的那一房）
static func peek_marker() -> StringName:
	if not FileAccess.file_exists(MARKER_REL):
		return &""
	var text := FileAccess.get_file_as_string(MARKER_REL)
	if text.is_empty():
		return &""
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return &""
	return StringName(str((parsed as Dictionary).get("room", "")))

static func clear_marker() -> void:
	var abs := marker_abs_path()
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)
	elif FileAccess.file_exists(MARKER_REL):
		DirAccess.remove_absolute(MARKER_REL)
