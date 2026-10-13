@tool
extends EditorPlugin
## ============================================================================
## EchoLevelEditorPlugin —— 插件入口：在 Godot 编辑器里挂出一个"残响关卡"主屏幕
## ----------------------------------------------------------------------------
## 为什么用"主屏幕插件"而不是停靠面板：
##   关卡编辑器需要整块画布（2D 网格 + 检查器），停靠面板太窄；
##   主屏幕会像 2D/3D/脚本 那样在顶栏多出一个页面，点开即整屏编辑。
##   Godot 4 的主屏幕配方就是下面这四件事：
##     _has_main_screen()  → true
##     _get_plugin_name()  → 顶栏页名
##     _get_plugin_icon()  → 顶栏图标
##     _make_visible()     → 页面切换时显隐
##   然后在 _enter_tree() 里把 UI 挂到 EditorInterface.get_editor_main_screen()。
##
## 与运行时的边界（重要）：
##   本插件只在**编辑器进程**里存在，游戏导出版里没有任何插件代码，
##   因此玩家不可能进到编辑器里 —— 这正是"编辑器属于引擎、不属于游戏"的落地方式。
##   插件与游戏唯一的耦合是磁盘上的数据文件（world.json / rooms/*.json）
##   与一个可选的试玩标记文件（见 EditorPlaytest）。
## ============================================================================

const SCREEN_SCENE := "res://addons/echo_level_editor/editor_screen.tscn"

## 主屏幕页（顶栏"残响关卡"）
var _screen: Control = null
## ① 面板 dock 化（第 45 轮）：交给编辑器侧栏的两块面板（素材库 / 属性检查器）
var _docks: Array[Control] = []
const DOCK_MENU_LIB := "残响：显示/隐藏 素材库面板"
const DOCK_MENU_INSP := "残响：显示/隐藏 属性面板"

func _enter_tree() -> void:
	var packed: PackedScene = load(SCREEN_SCENE)
	if packed == null:
		push_error("残响关卡编辑器：找不到界面场景 %s" % SCREEN_SCENE)
		return
	_screen = packed.instantiate()
	# 关键：主屏幕容器按"最小尺寸"摆放子控件，若不显式声明填充，
	# 界面只会显示成顶部一条（工具栏+状态栏），中间画布区域是空的（实测踩到的坑）。
	_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(_screen)
	_make_visible(false)          # 初始隐藏，等用户点顶栏页签
	# 面板要等 _screen._ready() 建完再取（deferred 保证此时已建好）
	_setup_docks.call_deferred()

# ══════════════════════════════════════════════════════════════════════════
# ① 面板 dock 化（第 45 轮）
# ----------------------------------------------------------------------------
# 把"素材库 / 属性检查器"注册为**编辑器侧栏面板**，白拿引擎原生能力：
#   拖拽停靠 / 浮动成独立窗口 / 与其它面板合并成标签 / 「视图」里显隐切换 ✓
# 若界面还没准备好（或面板已被别处接管），安全跳过 —— 此时页面内仍是三栏老布局 ✓。
# ══════════════════════════════════════════════════════════════════════════
func _setup_docks() -> void:
	if _screen == null or not _screen.has_method("take_cutscene_docks"):
		return
	var panels: Array = _screen.take_cutscene_docks()
	if panels.size() != 2:
		return
	_docks = [panels[0], panels[1]]
	# 页签名要自己起（否则编辑器显示成 `@PanelContainer@20188` 这种自动名 ✗，实测）
	panels[0].name = "过场素材库"
	panels[1].name = "过场属性"
	# ⚠ 槽位选择（实测教训）：`LEFT_BR` 是"左栏第二列的底部"，默认是折叠的 → 看不见 ✗；
	#   放到 `*_UL`（场景/导入、检查器/信号 所在的那一列主区）才会直接多出一个页签 ✓
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UL, panels[0])    # 素材库 → 左栏主区
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, panels[1])   # 属性   → 右栏主区
	add_tool_menu_item(DOCK_MENU_LIB, _toggle_dock_lib)
	add_tool_menu_item(DOCK_MENU_INSP, _toggle_dock_insp)

func _toggle_dock_lib() -> void:
	if not _docks.is_empty() and _docks[0] != null:
		_docks[0].visible = not _docks[0].visible

func _toggle_dock_insp() -> void:
	if _docks.size() >= 2 and _docks[1] != null:
		_docks[1].visible = not _docks[1].visible

func _exit_tree() -> void:
	remove_tool_menu_item(DOCK_MENU_LIB)
	remove_tool_menu_item(DOCK_MENU_INSP)
	for d: Control in _docks:
		if d != null:
			remove_control_from_docks(d)
			d.queue_free()
	_docks.clear()
	if _screen != null:
		_screen.queue_free()
		_screen = null

# ---------------------------------------------------------------- 主屏幕协议
func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "残响关卡"

func _get_plugin_icon() -> Texture2D:
	# 复用引擎自带图标即可，避免插件依赖额外美术资源（美术后期再补）
	return EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")

func _make_visible(visible: bool) -> void:
	if _screen != null:
		_screen.visible = visible
