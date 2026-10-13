@tool
class_name EditorTimeline
extends Control
## ============================================================================
## EditorTimeline —— 过场动画时间轴画布（刻度 / 轨道行 / 关键帧 / 播放头）
## ----------------------------------------------------------------------------
## 职责边界与 EditorCanvas / EditorWorldGraph 一致：**只画 + 只把鼠标位置翻译成
## (轨道, 关键帧或时间)**，然后发信号；所有数据改动由面板调 EditorCutsceneDoc 完成。
##
## 交互（CapCut / 剪辑软件的习惯）：
##   按住刻度尺左右拖   → **擦洗播放头**（scrub，实时看画面；这是第 36 轮修的）
##   按住播放头红线拖   → 同上（红线本身就是抓手，不用非得point中刻度尺）
##   点轨道行           → 选中该轨道并把播放头挪到点击处
##   点关键帧           → 选中；按住拖动 → 改时间（实时跟随）
##   滚轮               → 横向缩放（以鼠标处为锚点）
##   中键拖动           → 平移视图
##
## 坐标换算（纯函数，便于单测）：
##   x = gutter + (t - view_start) * px_per_sec
##
## ============================================================================
## 第 38 轮：按剪映手册补齐"时间线缩放"控件与轨道高度
## ----------------------------------------------------------------------------
## 依据（剪映专业版手册/教程，已核对）：
##   ① **两套独立缩放**：时间线缩放 ≠ 播放器（预览窗口）缩放 —— 用途不同，各自有控件；
##   ② 时间线缩放的入口在**时间线右上角**：`缩小`/`放大` 图标 + **中间滑块**，
##      快捷键 `-` / `+`，**Ctrl+滚轮**；另有 **全局预览缩放（Shift+Z）**
##      一次性把超出屏幕的素材全部显示出来（= 我们说的"适应视图/铺满"）；
##   ③ **轨道高度可调**（剪映能调整时间轨道的大小/行高）。
## 上一轮我把缩放做在监视器里、并且让"裸滚轮直接缩放时间线" —— 都不符合剪映习惯：
##   本轮修正为：时间线右上角一套 `↕− ↕+ ｜ 全局 ｜ − ──●── +`，
##   裸滚轮 = 横向平移（浏览），**Ctrl+滚轮 = 缩放**，并给面板暴露 `-`/`+`/`Shift+Z` 快捷键。
## ============================================================================
## 第 36 轮修的两个真 bug（用户报的）
## ----------------------------------------------------------------------------
## 【bug 1】放大缩小时**时间标尺会消失**
##   原因：刻度间隔阶梯写死 `[0.1, 0.25, 0.5, 1.0, 2.0, 5.0]` 且"取第一个满足
##   `step*px_per_sec >= 42` 的"，一旦缩小到 px_per_sec 很小（例如 8 px/秒），
##   `5.0*8 = 40 < 42` —— **一个候选都不满足**，step 就退回默认 0.5：
##   于是每 0.5 秒画一个标签（间距仅 4px），文字互相覆盖成一团灰，
##   看起来就是"标尺没了"。放大时的表现也不稳。
##   修法：① 阶梯向下/向上都延长到 [0.02 … 600]；② **取不到满足条件的一律用
##   阶梯里最大的那个**（绝不再退回小步长）；③ 缩放范围放宽到 [2, 800] px/秒；
##   ④ 主刻度只标数字，中间再加无标签的小刻度（视觉上永远有刻度）；
##   ⑤ 把"选步长/算刻度"抽成纯函数 `ruler_step()` / `ruler_ticks()`，
##      由 smoke_editor 第 [16] 节断言"任何缩放下标签间距都 ≥ 42px"。
##
## 【bug 2】点刻度尺能定位，但**按住拖动不能擦洗**（看不到画面跟着动）
##   原因：`_gui_input` 里左键在刻度尺上只做了"按下定位一次"，没有拖动状态机。
##   修法：加 `_scrubbing` 状态 + `scrub_began` 信号（面板据此暂停播放，避免
##   播放推进与手动擦洗抢时间）；红线本身也是抓手（命中宽度 ±6px，任意高度）。
## ============================================================================

signal playhead_changed(time: float)
signal key_selected(track_i: int, key_i: int)
signal key_moved(track_i: int, key_i: int, new_time: float)
signal track_selected(track_i: int)
## 开始擦洗（面板接住后应暂停播放：手动拖与播放推进不能同时抢时间轴）
signal scrub_began()

const GUTTER := 96.0          ## 左侧留给轨道名的宽度
const RULER_H := 22.0         ## 顶部刻度尺高度
const ROW_H := 26.0           ## 每行轨道高度
const KEY_R := 5.0            ## 关键帧菱形半径
const PLAYHEAD_GRAB := 6.0    ## 播放头红线的抓取半宽（px）
## 时间线右上角"缩放控件"的布局（剪映同款，见文件头第 38 轮说明）
const BAR_H := 14.0           ## 控件高度
const BAR_BTN := 16.0         ## 小按钮宽度
const BAR_TRACK_W := 88.0     ## 缩放滑块轨道宽度
const BAR_GAP := 4.0          ## 控件间距
const BAR_GLOBAL_W := 44.0    ## 「全局」按钮宽度
## 轨道行高可调范围（剪映能调时间轨道大小）
const ROW_H_MIN := 16.0
const ROW_H_MAX := 48.0
## 缩放范围：放宽到 [2, 800] px/秒 —— 太窄会让"整段铺满"落在边界上，标尺跟着失真
const ZOOM_MIN := 2.0
const ZOOM_MAX := 800.0
## 主刻度标签之间的最小像素距离（小于它就会糊成一团，见 bug 1）
const MIN_LABEL_PX := 42.0
## 刻度阶梯（1-2-5 序列，向下到 0.02s、向上到 600s）
const RULER_LADDER := [
	0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0,
	60.0, 120.0, 300.0, 600.0,
]

const ROW_BG := Color(0.14, 0.15, 0.18)
const ROW_BG_ALT := Color(0.17, 0.18, 0.22)
const ROW_SEL := Color(0.22, 0.26, 0.34)
const GRID := Color(0.30, 0.34, 0.40, 0.8)
const GRID_MAJOR := Color(0.45, 0.52, 0.60, 0.9)
const KEY_COLOR := Color(0.95, 0.85, 0.45)
const KEY_SEL := Color(1.0, 1.0, 1.0)
const PLAYHEAD := Color(1.0, 0.4, 0.4)
const RULER_BG := Color(0.13, 0.14, 0.17)
const TRACK_COLORS := {
	&"camera": Color(0.55, 0.75, 1.0),
	&"actor": Color(0.60, 0.95, 0.65),
	&"effect": Color(0.95, 0.70, 0.95),
	&"text": Color(0.95, 0.90, 0.60),
}

var doc: EditorCutsceneDoc = null
var playhead := 0.0
var selected_track := -1
var selected_key := -1
var px_per_sec := 90.0
var view_start := 0.0
## 每行轨道高度（第 38 轮：可调，剪映能改时间轨道大小）
var row_h := ROW_H
## 每轨单独高度（第 46 轮：可以拖某一轨的下边界改它的高度，剪映同款）
var track_h: Array[float] = []
var _drag_row := -1              ## 正在拖高度的轨道序号（-1 = 没在拖）
var _drag_row_y0 := 0.0
var _drag_row_h0 := 0.0
var _row_edge_hover := -1        ## 当前悬停在哪条边界上（用于变光标）
## 鼠标最后停留的 x（第 48 轮：按钮/滑块缩放时要"锚在鼠标处"）
var _last_mouse_x := -1.0
const DRAG_EDGE_PX := 3.5        ## 边界命中容差（像素）
const TRACK_H_MAX := 96.0        ## 单轨高度上限（拖拽用；比按钮的 48 更宽松）
## 滑块拖动中
var _dragging_zoom := false
var _dragging_key := false
var _panning := false
var _pan_last := Vector2.ZERO
var _scrubbing := false          ## 正在拖播放头（bug 2 的状态机）
var _user_view := false          ## 用户是否手动缩放/平移过（窗口尺寸变化时不要覆盖它）

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, RULER_H + row_h * 4.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	# 关键：面板在 _load_cutscene 里调 fit_view() 时，本控件的 size 往往还是 0
	# （布局还没跑），于是 avail 落到兜底 60px → 缩放被算成 ~12px/秒，
	# 5 秒的过场会被铺成 0~100s 的刻度（看起来"刻度乱七八糟"）。
	# 这里监听尺寸变化：只要用户没手动动过缩放，尺寸一就绪就重新适应视图。
	resized.connect(_on_resized)

## 尺寸变化：用户没手动调过缩放时，重新适应视图（修"启动时缩放算错"）
func _on_resized() -> void:
	if doc == null or _user_view:
		return
	fit_view()

func set_doc(p_doc: EditorCutsceneDoc) -> void:
	doc = p_doc
	playhead = 0.0
	selected_track = -1
	selected_key = -1
	view_start = 0.0
	_scrubbing = false
	_dragging_key = false
	_panning = false
	_user_view = false           # 换了文档就重新"自动适应"
	fit_view()
	queue_redraw()

# ============================================================================
# 坐标换算（纯函数）
# ============================================================================
func time_to_x(t: float) -> float:
	return GUTTER + (t - view_start) * px_per_sec

func x_to_time(x: float) -> float:
	return maxf(view_start + (x - GUTTER) / maxf(px_per_sec, 1.0), 0.0)

## ══════════════════════════════════════════════════════════════════════════
## ③ 轨道缩略图 / 波形（第 47 轮）
## ----------------------------------------------------------------------------
## 剪映的轨道里不是空白：视频轨有帧缩略、音频轨有波形、字幕轨有文字。
## 这里按**数据真实内容**给出同类信息：
##   · 镜头轨 / 角色轨 → 真实关键帧数值的**折线图**（位置轨迹一眼可见）
##   · 字幕轨          → 该时刻的**字幕文字**（照剪映）
##   · 特效轨          → 特效名 + **确定性示意波形**（没有真实音频，用名字哈希生成；
##                        等接入音频文件后再换成真波形，这里不做假承诺）
## 取样函数都是纯函数（只吃 keys / 名字），便于单测断言归一化与确定性 ✓
## ══════════════════════════════════════════════════════════════════════════

## 在时间 t 处对某字段做**线性插值**（关键帧之间线性，与游戏里 Cutscene 的采样一致）
func sample_field(ti: int, field: String, t: float, fallback: float = 0.0) -> float:
	var ks := doc.keys(ti)
	if ks.is_empty():
		return fallback
	var prev: Dictionary = ks[0]
	var next: Dictionary = ks[ks.size() - 1]
	for k: Variant in ks:
		var kt := float((k as Dictionary).get("t", 0.0))
		if kt <= t:
			prev = k as Dictionary
		if kt >= t:
			next = k as Dictionary
			break
	var t0 := float(prev.get("t", 0.0))
	var t1 := float(next.get("t", 0.0))
	var v0 := float(prev.get(field, fallback))
	var v1 := float(next.get(field, fallback))
	if t1 - t0 <= 0.0001:
		return v1
	return lerpf(v0, v1, clampf((t - t0) / (t1 - t0), 0.0, 1.0))

## 某字段随时间变化的归一化折线：返回 samples+1 个点，坐标都在 [0,1]² 内
## （u = 时间进度，v = 0=最小值 1=最大值；全是同一个值时就画在中线）
func curve_points(ti: int, field: String, samples: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := maxi(samples, 2)
	var dur := doc.duration()
	var lo := INF
	var hi := -INF
	var vals := PackedFloat32Array()
	for i in n + 1:
		var t := dur * float(i) / float(n)
		var v := sample_field(ti, field, t, 0.0)
		vals.append(v)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := hi - lo
	for i in vals.size():
		var u := float(i) / float(maxi(n, 1))
		var v := 0.5 if span <= 0.0001 else (vals[i] - lo) / span
		out.append(Vector2(u, v))
	return out

## 字幕缩略：取 t 时刻（前一个关键帧）的字幕文字
func text_thumb(ti: int, t: float) -> String:
	var ks := doc.keys(ti)
	var best := ""
	for k: Variant in ks:
		if float((k as Dictionary).get("t", 0.0)) <= t + 0.0001:
			best = str((k as Dictionary).get("text", ""))
	return best

## 特效缩略：该轨用到的音效名（去重后拼起来）
func effect_thumb(ti: int) -> String:
	var seen: Array[String] = []
	for k: Variant in doc.keys(ti):
		var s := str((k as Dictionary).get("sfx", ""))
		if s != "" and not seen.has(s):
			seen.append(s)
	return ", ".join(seen)

## 确定性示意波形：同一名字永远得到同一条波形（单测可断言）
func pseudo_wave(seed_text: String, samples: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := maxi(samples, 2)
	var h := float(hash(seed_text) % 100000) / 100000.0
	for i in n + 1:
		# 用两个正弦叠加 + 种子相位：形状稳定、不依赖随机数（可复现 ✓）
		var u := float(i) / float(n)
		var v := 0.5 + 0.32 * sin(u * TAU * 3.0 + h * TAU) + 0.16 * sin(u * TAU * 7.0 + h * 5.0)
		out.append(clampf(v, 0.02, 0.98))
	return out

# ══════════════════════════════════════════════════════════════════════════
# ② 真波形（第 50 轮）
# ----------------------------------------------------------------------------
# 规则：**能读到真实音频就画真波形，读不到才回退示意图**（并在提示里写明"示意"）。
# 查找路径与游戏 `AudioManager.SFX_DIRS` **完全一致**：
#     res://data/audio/sfx/<id>.tres   →   res://assets/audio/sfx/<id>.wav
# 于是"把音频文件丢进去"这一个动作，对游戏与编辑器**同时生效** ✓（真·所见即所得）。
# 为什么不在编辑器里直接问 AudioManager 要波形：插件界面**禁止引用运行时单例**
# （smoke_editor 里有专门断言守住这条 ✗→✓），所以只读磁盘资源 ✓。
# ══════════════════════════════════════════════════════════════════════════
const SFX_DIRS := ["res://data/audio/sfx/", "res://assets/audio/sfx/"]
const WAVE_EXT := ["tres", "wav"]
var _wave_cache: Dictionary = {}      ## id -> {"peaks": PackedFloat32Array, "real": bool, "path": String}

## 找该 id 对应的真实音频文件（找不到返回 ""）
static func find_sfx_file(id: String) -> String:
	if id.strip_edges() == "":
		return ""
	for dir: String in SFX_DIRS:
		for ext: String in WAVE_EXT:
			var p := "%s%s.%s" % [dir, id, ext]
			if ResourceLoader.exists(p):
				return p
	return ""

## 把 AudioStreamWAV 的 16 位 PCM 压成 samples+1 个峰值（0..1，绝对值归一化）
static func peaks_from_wav(stream: AudioStreamWAV, samples: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := maxi(samples, 2)
	var data := stream.data
	if data.is_empty():
		return out
	var bits := stream.format
	var stereo := stream.stereo
	var frame_bytes := 2 if bits == AudioStreamWAV.FORMAT_16_BITS else 1
	if stereo:
		frame_bytes *= 2
	var frames := data.size() / maxi(frame_bytes, 1)
	if frames <= 0:
		return out
	for i in n:
		var a := int(float(frames) * float(i) / float(n))
		var b := int(float(frames) * float(i + 1) / float(n))
		b = mini(maxi(b, a + 1), frames)      # ⚠ 必须夹到 frames：否则会读到缓冲区末尾之后 ✗
		var peak := 0.0
		var step := maxi((b - a) / 256, 1)          # 每桶最多看 256 个采样，够画了
		var idx := a
		while idx < b:
			var off := idx * frame_bytes
			var v := 0.0
			if bits == AudioStreamWAV.FORMAT_16_BITS:
				v = float(data.decode_s16(off)) / 32768.0
			else:
				v = (float(data[off]) - 128.0) / 128.0
			peak = maxf(peak, absf(v))
			idx += step
		out.append(clampf(peak, 0.02, 1.0))
	# 末点 = 最后一个桶（保证点数 = n+1，且不像上面那样越界读成 0）
	out.append(out[out.size() - 1] if out.size() > 0 else 0.02)
	return out

## 取某音效的波形：真实文件优先，缺文件时回退示意图波形（并在 real 里标明）
func wave_for(id: String, samples: int) -> Dictionary:
	var key := "%s@%d" % [id, samples]
	if _wave_cache.has(key):
		return _wave_cache[key]
	var result := {"peaks": pseudo_wave(id, samples), "real": false, "path": ""}
	var path := find_sfx_file(id)
	if path != "":
		var res: Resource = load(path)
		if res is AudioStreamWAV:
			var peaks := peaks_from_wav(res as AudioStreamWAV, samples)
			if peaks.size() >= 2:
				result = {"peaks": peaks, "real": true, "path": path}
	_wave_cache[key] = result
	return result

## 某轨高度：单独设过就用它，否则跟随全局 row_h
func row_height(i: int) -> float:
	if i >= 0 and i < track_h.size():
		return track_h[i]
	return row_h

## ══════════════════════════════════════════════════════════════════════════
## ③ 轨道缩略的绘制：把上面的纯函数结果画进轨道行
## ══════════════════════════════════════════════════════════════════════════
func _draw_track_thumb(i: int, y: float, h: float, color: Color) -> void:
	if doc == null or h < 10.0:
		return
	var kind := StringName(str(doc.track(i).get("kind", "")))
	var dur := maxf(doc.duration(), 0.001)
	var thick := 1.0 if h < 24.0 else 1.5
	match kind:
		&"camera", &"actor":
			# 真实数据轨迹：x（实线）与 y（虚线）各自归一化到行内
			for entry: Array in [["x", false], ["y", true]]:
				var pts := curve_points(i, str(entry[0]), 48)
				if pts.size() < 2:
					continue
				var top := y + 3.0
				var bottom := y + h - 4.0
				var line := PackedVector2Array()
				for p: Vector2 in pts:
					line.append(Vector2(GUTTER + p.x * maxf(size.x - GUTTER, 1.0),
						lerpf(bottom, top, p.y)))
				var col := Color(color.r, color.g, color.b, 0.75 if not entry[1] else 0.45)
				if entry[1]:
					# 虚线：逐段画短划，区分 x / y
					for s in range(0, line.size() - 1, 2):
						draw_line(line[s], line[s + 1], col, thick)
				else:
					draw_polyline(line, col, thick)
		&"text":
			# 字幕缩略：沿时间显示该时刻的文字（照剪映的字幕轨）
			if font_ok():
				var steps := maxi(int(dur / 0.5), 1)
				for s in steps:
					var t := float(s) * 0.5
					var txt := text_thumb(i, t)
					if txt == "":
						continue
					var x := time_to_x(t)
					if x < GUTTER or x > size.x:
						continue
					draw_string(ThemeDB.fallback_font, Vector2(x + 3.0, y + h * 0.68),
						txt.substr(0, 8), HORIZONTAL_ALIGNMENT_LEFT, 70, 10,
						Color(1.0, 1.0, 1.0, 0.72))
		&"spawn":
			# 生成轨（第 46 轮）：每个关键帧画一个"出场/退场"标记 + 敌人类型
			for k: Variant in doc.keys(i):
				var kd: Dictionary = k
				var kx := time_to_x(float(kd.get("t", 0.0)))
				if kx < GUTTER or kx > size.x:
					continue
				var sp := str(kd.get("action", "spawn")) == "despawn"
				var col2 := Color(0.95, 0.45, 0.35) if sp else Color(0.55, 0.95, 0.55)
				var cy2 := y + h * 0.5
				draw_line(Vector2(kx, y + 2.0), Vector2(kx, y + h - 2.0), col2, 1.2)
				draw_circle(Vector2(kx, cy2), 2.5, col2)
				if font_ok() and h >= 20.0:
					draw_string(ThemeDB.fallback_font, Vector2(kx + 4.0, y + h * 0.72),
						"%s×%d" % [str(kd.get("type", "?")), int(kd.get("count", 1))],
						HORIZONTAL_ALIGNMENT_LEFT, 90, 9, col2)
		&"effect":
			# 特效轨：名字 + **真实波形优先**（没有音频文件时才用示意图波形并标注）
			var name := effect_thumb(i)
			var wf := wave_for(name, 40)
			var wave: PackedFloat32Array = wf["peaks"]
			var is_real: bool = wf["real"]
			var mid := y + h * 0.5
			var amp := maxf(h * 0.5 - 4.0, 2.0)
			for s in wave.size():
				var x := GUTTER + (float(s) / float(maxi(wave.size() - 1, 1))) * maxf(size.x - GUTTER, 1.0)
				var v := (wave[s] - 0.5) * 2.0
				draw_line(Vector2(x, mid), Vector2(x, mid - v * amp),
					Color(color.r, color.g, color.b, 0.72 if is_real else 0.5),
					thick * (1.4 if is_real else 1.0))
			if font_ok():
				var tag := name if is_real else "%s（示意）" % name
				draw_string(ThemeDB.fallback_font, Vector2(GUTTER + 6.0, y + h * 0.72),
					tag, HORIZONTAL_ALIGNMENT_LEFT, 160, 10,
					Color(1.0, 1.0, 1.0, 0.88 if is_real else 0.8))

func font_ok() -> bool:
	return ThemeDB.fallback_font != null

## 内容总高（决定 custom_minimum_size：轨道多了时间线会滚动）
func content_height() -> float:
	var n := maxi(doc.track_count(), 1) if doc != null else 1
	var total := RULER_H
	for i in n:
		total += row_height(i)
	return total

## 第 i 轨的顶部 y（逐轨累加，所以每轨高度可以不同）
func track_to_y(i: int) -> float:
	var y := RULER_H
	for k in maxi(i, 0):
		y += row_height(k)
	return y

func y_to_track(y: float) -> int:
	if y < RULER_H or doc == null:
		return -1
	var acc := RULER_H
	for i in doc.track_count():
		var h := row_height(i)
		if y < acc + h:
			return i
		acc += h
	return -1

## 鼠标是否压在"第 i 轨的下边界"上（拖动改高度 / 悬停变光标用）
func row_edge_at(pos: Vector2) -> int:
	if doc == null:
		return -1
	for i in doc.track_count():
		var bottom := track_to_y(i) + row_height(i)
		if absf(pos.y - bottom) <= DRAG_EDGE_PX:
			return i
	return -1

# ============================================================================
# 时间线右上角的缩放控件（第 38 轮，剪映同款）
# ----------------------------------------------------------------------------
# 布局（从左到右）：`↕−` `↕+` ｜ `全局` ｜ `−` ──●── `+`
#   · ↕−/↕+ ：轨道行高（剪映"调整时间轨道"）
#   · 全局   ：全局预览缩放（剪映 Shift+Z）= 把整段铺满可视宽度
#   · −/滑块/+ ：时间线缩放（px/秒）
# 纯几何，便于单测：断言各控件不重叠、都在刻度尺内、点 − 变小点 + 变大。
# ============================================================================
func zoom_bar_rects() -> Dictionary:
	var y := (RULER_H - BAR_H) * 0.5
	var right := size.x - BAR_GAP
	var plus := Rect2(right - BAR_BTN, y, BAR_BTN, BAR_H)
	var track := Rect2(plus.position.x - BAR_GAP - BAR_TRACK_W, y, BAR_TRACK_W, BAR_H)
	var minus := Rect2(track.position.x - BAR_GAP - BAR_BTN, y, BAR_BTN, BAR_H)
	var global_btn := Rect2(minus.position.x - BAR_GAP - BAR_GLOBAL_W, y, BAR_GLOBAL_W, BAR_H)
	var row_plus := Rect2(global_btn.position.x - BAR_GAP - BAR_BTN, y, BAR_BTN, BAR_H)
	var row_minus := Rect2(row_plus.position.x - BAR_GAP - BAR_BTN, y, BAR_BTN, BAR_H)
	return {
		"row_minus": row_minus, "row_plus": row_plus, "global": global_btn,
		"minus": minus, "track": track, "plus": plus,
	}

## 滑块位置 ↔ 缩放：用对数刻度（8→800 px/秒），滑块在 0..1 间线性
func _zoom_to_slider() -> float:
	var lo := log(ZOOM_MIN)
	var hi := log(ZOOM_MAX)
	return clampf((log(clampf(px_per_sec, ZOOM_MIN, ZOOM_MAX)) - lo) / maxf(hi - lo, 0.0001), 0.0, 1.0)

func _slider_to_zoom(ratio: float) -> float:
	var lo := log(ZOOM_MIN)
	var hi := log(ZOOM_MAX)
	return clampf(exp(lo + (hi - lo) * clampf(ratio, 0.0, 1.0)), ZOOM_MIN, ZOOM_MAX)

## 缩放：**锚在鼠标处**（第 48 轮，用户要求"缩放锚在鼠标处"）
## ----------------------------------------------------------------------------
## 之前按钮/滑块一律以**视图中心**为锚 ✗ → 想看某处细节，缩放后它就跑掉了。
## 现在：按钮/滑块都用"鼠标最后停留的 x"作锚（没鼠标信息时退回视图中心 ✓），
## 于是"鼠标指着哪，缩放后就还看着哪" ✓（Ctrl+滚轮本来就是这个行为 ✓）。
func zoom_step(zoom_in: bool, anchor_x: float = -1.0) -> void:
	zoom_around(px_per_sec * (1.25 if zoom_in else 0.8), anchor_x)

## 把缩放设成某个值，并保持 anchor_x 处的时间不动
func zoom_around(new_px_per_sec: float, anchor_x: float = -1.0) -> void:
	var ax := anchor_x if anchor_x >= GUTTER else (GUTTER + size.x) * 0.5
	var anchor_t := x_to_time(ax)
	var before := px_per_sec
	px_per_sec = clampf(new_px_per_sec, ZOOM_MIN, ZOOM_MAX)
	if absf(px_per_sec - before) < 0.0001:
		return
	view_start = anchor_t - (ax - GUTTER) / px_per_sec
	_user_view = true
	_clamp_view()
	queue_redraw()

## 滑块上的刻度（第 48 轮）：5 条等距刻度，点它可直接跳到该缩放
## 纯几何、可单测：都在滑块轨道内、从左到右单调递增
func tick_ratios() -> PackedFloat32Array:
	return PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])

func tick_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var tr: Rect2 = zoom_bar_rects()["track"]
	for r: float in tick_ratios():
		out.append(Rect2(tr.position.x + tr.size.x * r - 1.0, tr.position.y + tr.size.y - 4.0, 2.0, 4.0))
	return out

## 点击刻度 → 直接跳到该缩放（同样锚在鼠标处 ✓）
func _handle_tick_click(pos: Vector2, anchor_x: float = -1.0) -> bool:
	var tr: Rect2 = zoom_bar_rects()["track"]
	if not tr.has_point(pos):
		return false
	var ratios := tick_ratios()
	for i in ratios.size():
		var x := tr.position.x + tr.size.x * ratios[i]
		if absf(pos.x - x) <= 4.0:
			zoom_around(_slider_to_zoom(ratios[i]), anchor_x)
			return true
	return false

## 全局预览缩放（剪映 Shift+Z）：整段铺满可视宽度
func fit_global() -> void:
	_user_view = false
	fit_view()

## 轨道行高调整（剪映"调整时间轨道"）：`↕±` 按钮 = 所有轨道一起改
func set_row_h(delta: float) -> void:
	row_h = clampf(row_h + delta, ROW_H_MIN, ROW_H_MAX)
	for i in track_h.size():
		track_h[i] = clampf(track_h[i] + delta, ROW_H_MIN, TRACK_H_MAX)
	_after_row_change()

## 单独设某轨高度（第 46 轮：拖这条轨的下边界）
func set_track_h(i: int, h: float) -> void:
	if doc == null or i < 0 or i >= doc.track_count():
		return
	_ensure_track_h()
	track_h[i] = clampf(h, ROW_H_MIN, TRACK_H_MAX)
	_after_row_change()

## 轨道数变化时同步 track_h 长度（多退少补，值沿用全局 row_h）
func _ensure_track_h() -> void:
	var n := doc.track_count() if doc != null else 0
	while track_h.size() < n:
		track_h.append(row_h)
	if track_h.size() > n:
		track_h.resize(n)

func _after_row_change() -> void:
	custom_minimum_size = Vector2(0, content_height())
	queue_redraw()

## 处理右上角缩放控件的点击；返回 true = 已消费（不要再当刻度尺/擦洗用）
## 注意（第 48 轮）：`+`/`−`/滑块都用 `_last_mouse_x` 作锚 → "鼠标指着哪就缩放哪" ✓
func _handle_bar_click(pos: Vector2) -> bool:
	var r := zoom_bar_rects()
	if (r["plus"] as Rect2).has_point(pos):
		zoom_step(true, _last_mouse_x)
		return true
	if (r["minus"] as Rect2).has_point(pos):
		zoom_step(false, _last_mouse_x)
		return true
	if (r["global"] as Rect2).has_point(pos):
		fit_global()
		return true
	if (r["row_plus"] as Rect2).has_point(pos):
		set_row_h(4.0)
		return true
	if (r["row_minus"] as Rect2).has_point(pos):
		set_row_h(-4.0)
		return true
	if (r["track"] as Rect2).has_point(pos):
		var tr: Rect2 = r["track"]
		_dragging_zoom = true
		zoom_around(_slider_to_zoom((pos.x - tr.position.x) / maxf(tr.size.x, 1.0)), _last_mouse_x)
		return true
	return false

## 当前缩放下的主刻度间隔（纯函数；smoke_editor 直接断言它）
## 关键点：**永远返回阶梯里满足条件的第一个；一个都不满足就返回最大的那个**，
## 绝不能退回小步长 —— 那正是"标尺消失"的成因。
static func ruler_step(p_px_per_sec: float) -> float:
	var pps := maxf(p_px_per_sec, 0.001)
	for candidate: float in RULER_LADDER:
		if candidate * pps >= MIN_LABEL_PX:
			return candidate
	return float(RULER_LADDER[RULER_LADDER.size() - 1])

## 可见范围内的主刻度时间点（纯函数）：从 view_start 之前一点开始，铺到右边界外一点
static func ruler_ticks(p_view_start: float, width: float, p_px_per_sec: float, step: float) -> Array[float]:
	var out: Array[float] = []
	if step <= 0.0 or p_px_per_sec <= 0.0 or width <= 0.0:
		return out
	var t := floorf(maxf(p_view_start, 0.0) / step) * step
	var guard := 0
	# 上限保护：即使参数异常也不会画无限多个刻度（每帧调用，宁少勿卡）
	while t * p_px_per_sec - p_view_start * p_px_per_sec <= width + step * p_px_per_sec:
		out.append(t)
		t += step
		guard += 1
		if guard > 4000:
			break
	return out

## 播放头命中测试（红线本身也是抓手，任意高度都能拖）
func hit_playhead(pos: Vector2) -> bool:
	return absf(pos.x - time_to_x(playhead)) <= PLAYHEAD_GRAB

## 适应视图：让整段过场铺满可用宽度
func fit_view() -> void:
	if doc == null or doc.duration() <= 0.0:
		return
	var avail := maxf(size.x - GUTTER - 12.0, 60.0)
	px_per_sec = clampf(avail / doc.duration(), ZOOM_MIN, ZOOM_MAX)
	view_start = 0.0
	queue_redraw()

## 命中测试：返回 [track_i, key_i]（没命中返回 [-1, -1]）
func hit_key(pos: Vector2) -> Array:
	if doc == null:
		return [-1, -1]
	var ti := y_to_track(pos.y)
	if ti < 0:
		return [-1, -1]
	var ks := doc.keys(ti)
	for ki in ks.size():
		var kx := time_to_x(float((ks[ki] as Dictionary).get("t", 0.0)))
		var ky := track_to_y(ti) + row_height(ti) * 0.5
		if absf(pos.x - kx) <= KEY_R + 3.0 and absf(pos.y - ky) <= KEY_R + 3.0:
			return [ti, ki]
	return [-1, -1]

# ============================================================================
# 播放头：唯一的设置入口（夹范围 + 发信号 + 重绘）
# ============================================================================
func set_playhead(t: float, emit_signal_now := true) -> void:
	var d := doc.duration() if doc != null else 0.0
	playhead = clampf(t, 0.0, maxf(d, 0.0))
	if emit_signal_now:
		playhead_changed.emit(playhead)
	queue_redraw()

## 视图起点夹取：不许滚过内容末尾（滚进空白会让人以为"标尺/内容没了"）
func _clamp_view() -> void:
	var limit := doc.duration() if doc != null else 0.0
	view_start = clampf(view_start, 0.0, maxf(limit, 0.0))

## 擦洗时把鼠标位置翻译成时间；靠近左右边缘自动滚动视图（长过场也能一路拖）
func _scrub_to(x: float) -> void:
	var edge := 14.0
	if x > size.x - edge:
		view_start += (x - (size.x - edge)) / maxf(px_per_sec, 1.0)
	elif x < GUTTER + edge:
		view_start -= ((GUTTER + edge) - x) / maxf(px_per_sec, 1.0)
	_clamp_view()
	set_playhead(x_to_time(x))

# ============================================================================
# 输入
# ============================================================================
func _gui_input(event: InputEvent) -> void:
	if doc == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_last_mouse_x = mb.position.x          # 缩放锚点 = 鼠标最后位置（第 48 轮）
		# ---- 滚轮（剪映习惯）：**Ctrl+滚轮 = 缩放**；裸滚轮 = 横向浏览 ----
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var step_in := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			if mb.ctrl_pressed:
				var anchor_t := x_to_time(mb.position.x)
				px_per_sec = clampf(px_per_sec * (1.15 if step_in else 0.87), ZOOM_MIN, ZOOM_MAX)
				view_start = anchor_t - (mb.position.x - GUTTER) / px_per_sec
				_user_view = true          # 用户接管缩放：此后窗口变化不再自动适应
				_clamp_view()
			else:
				view_start += (-60.0 if step_in else 60.0) / maxf(px_per_sec, 1.0)
				_clamp_view()
			queue_redraw()
			accept_event()
			return
		# ---- 中键：平移 ----
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_pan_last = mb.position
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# ⓪ **先判刻度**（第 48 轮）：点滑块上的刻度直接跳到该缩放（也锚在鼠标处）
				if _handle_tick_click(mb.position, _last_mouse_x):
					accept_event()
					return
				# ⓪ **再判右上角缩放控件**（第 38 轮，剪映同款）——
				# 它们也在刻度尺带内，必须先于"擦洗"分支处理，否则点滑块会变成挪播放头
				if _handle_bar_click(mb.position):
					accept_event()
					return
				# ⓪′ **轨道下边界 → 拖动改该轨高度**（第 46 轮）。
				# 必须先于"选中轨道/擦洗"，否则拖边界会变成挪播放头 ✗
				var edge := row_edge_at(mb.position)
				if edge >= 0:
					_drag_row = edge
					_drag_row_y0 = mb.position.y
					_drag_row_h0 = row_height(edge)
					mouse_default_cursor_shape = Control.CURSOR_VSIZE
					accept_event()
					return
				# ① 刻度尺 或 播放头红线 → 进入"擦洗"（按住拖动持续定位）
				if mb.position.y < RULER_H or hit_playhead(mb.position):
					_scrubbing = true
					mouse_default_cursor_shape = Control.CURSOR_DRAG   # 拖动光标，明确"正在拖"
					scrub_began.emit()          # 面板据此暂停播放，避免抢时间轴
					_scrub_to(mb.position.x)
					accept_event()
					return
				# ② 关键帧 → 选中并进入拖动
				var hit := hit_key(mb.position)
				if int(hit[0]) >= 0:
					selected_track = int(hit[0])
					selected_key = int(hit[1])
					_dragging_key = true
					key_selected.emit(selected_track, selected_key)
					track_selected.emit(selected_track)
					queue_redraw()
					accept_event()
					return
				# ③ 轨道行 → 选中轨道 + 把播放头挪到点击处
				var ti := y_to_track(mb.position.y)
				if ti >= 0:
					selected_track = ti
					selected_key = -1
					track_selected.emit(ti)
					set_playhead(x_to_time(mb.position.x))
					accept_event()
			else:
				_dragging_key = false
				_panning = false
				_scrubbing = false
				_dragging_zoom = false
				_drag_row = -1
				mouse_default_cursor_shape = Control.CURSOR_ARROW
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# 拖动轨道下边界改高度（第 46 轮，剪映同款）
		if _drag_row >= 0:
			set_track_h(_drag_row, _drag_row_h0 + (mm.position.y - _drag_row_y0))
			accept_event()
			return
		# 悬停在边界上 → 上下箭头光标（让人知道"这里能拖"）
		var hover_edge := row_edge_at(mm.position)
		if hover_edge != _row_edge_hover:
			_row_edge_hover = hover_edge
			mouse_default_cursor_shape = Control.CURSOR_VSIZE if hover_edge >= 0 else Control.CURSOR_ARROW
		# 拖动缩放滑块（剪映：时间线右上角滑块）
		if _dragging_zoom:
			var rects := zoom_bar_rects()
			var tr: Rect2 = rects["track"]
			px_per_sec = _slider_to_zoom((mm.position.x - tr.position.x) / maxf(tr.size.x, 1.0))
			_user_view = true
			queue_redraw()
			accept_event()
			return
		# 拖动播放头（bug 2 的核心修复）
		if _scrubbing:
			_scrub_to(mm.position.x)
			accept_event()
			return
		if _panning:
			view_start -= mm.relative.x / maxf(px_per_sec, 1.0)
			_user_view = true
			_clamp_view()
			queue_redraw()
			return
		if _dragging_key and selected_track >= 0 and selected_key >= 0:
			var nt := clampf(x_to_time(mm.position.x), 0.0, doc.duration())
			key_moved.emit(selected_track, selected_key, nt)
			queue_redraw()
			return
		# 悬停反馈：刻度尺与播放头红线用左右箭头光标，告诉用户"这里能拖"
		if mm.position.y < RULER_H or hit_playhead(mm.position):
			mouse_default_cursor_shape = Control.CURSOR_HSIZE
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

func previous_mouse_shape() -> void:
	# 保留空实现以免旧调用点报错（第 36 轮已把光标设置内联到 _gui_input）
	pass

# ============================================================================
# 绘制
# ============================================================================
func _draw() -> void:
	if doc == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.11, 0.14), true)
	_draw_ruler()
	_draw_rows()
	_draw_playhead()

func _draw_ruler() -> void:
	draw_rect(Rect2(0, 0, size.x, RULER_H), RULER_BG, true)
	draw_line(Vector2(0, RULER_H), Vector2(size.x, RULER_H), GRID_MAJOR, 1.0)

	# ---- 主刻度（带数字）----
	# 步长由纯函数决定：任何缩放下标签间距都 ≥ MIN_LABEL_PX，绝不会糊成一团
	var step := ruler_step(px_per_sec)
	var font: Font = ThemeDB.fallback_font
	var ticks := ruler_ticks(view_start, size.x, px_per_sec, step)
	for t: float in ticks:
		var x := time_to_x(t)
		if x < GUTTER - 1.0:
			continue
		draw_line(Vector2(x, 0), Vector2(x, RULER_H), GRID_MAJOR, 1.0)
		if font != null:
			# 步长 <1s 显示两位小数，≥1s 显示整数秒（带 s 后缀），避免出现"5.00"这种冗余
			var label := "%.2f" % t if step < 1.0 else "%.0fs" % t
			draw_string(font, Vector2(x + 3, RULER_H - 6), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.78, 0.83, 0.88))
		# ---- 小刻度（无标签，1/5 步长）：保证任何缩放下都"看得见刻度" ----
		var sub := step / 5.0
		if sub * px_per_sec >= 5.0:
			for i in range(1, 5):
				var sx := time_to_x(t + sub * float(i))
				if sx >= GUTTER and sx <= size.x:
					draw_line(Vector2(sx, RULER_H - 5.0), Vector2(sx, RULER_H), GRID, 1.0)

	# ---- 起点 0 与时长终点（把"零刻度"和"END"永远钉在标尺上）----
	var zero_x := time_to_x(0.0)
	if zero_x >= GUTTER - 1.0 and zero_x <= size.x:
		draw_line(Vector2(zero_x, 0), Vector2(zero_x, RULER_H), Color(0.6, 0.68, 0.78), 1.0)
	var end_x := time_to_x(doc.duration())
	if end_x >= GUTTER - 1.0 and end_x <= size.x:
		draw_line(Vector2(end_x, 0), Vector2(end_x, size.y), Color(0.9, 0.6, 0.3, 0.9), 2.0)
		draw_string(font, Vector2(end_x + 3, RULER_H - 6), "END",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.95, 0.7, 0.4))
	# ---- 右上角缩放控件（第 38 轮，剪映同款）----
	_draw_zoom_bar(font)

## 右上角控件：`↕− ↕+ ｜ 全局 ｜ − ──●── +`（轨道高度 / 全局预览 / 时间线缩放）
func _draw_zoom_bar(font: Font) -> void:
	var r := zoom_bar_rects()
	var bg := Color(0.20, 0.22, 0.27)
	var fg := Color(0.82, 0.87, 0.94)
	for k: String in ["row_minus", "row_plus", "global", "minus", "plus"]:
		var rect: Rect2 = r[k]
		draw_rect(rect, bg, true)
		var label := ""
		match k:
			"row_minus":
				label = "↕−"
			"row_plus":
				label = "↕+"
			"global":
				label = "全局"
			"minus":
				label = "−"
			"plus":
				label = "+"
		if font != null:
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			draw_string(font, Vector2(rect.position.x + (rect.size.x - w) * 0.5, rect.position.y + rect.size.y - 3.0),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, fg)
	# 滑块轨道 + 把手 + 当前 px/秒读数
	var tr: Rect2 = r["track"]
	draw_rect(tr, Color(0.15, 0.17, 0.21), true)
	draw_rect(tr, Color(0.32, 0.36, 0.44), false, 1.0)
	# 第 48 轮：滑块**带刻度**（5 条，点它直接跳到该缩放）；刻度处标 px/秒便于对照
	for i in tick_rects().size():
		var t := tick_rects()[i]
		draw_rect(t, Color(0.45, 0.52, 0.62, 0.9), true)
		if font != null and i % 2 == 0:
			draw_string(font, Vector2(t.position.x + 3.0, tr.position.y + tr.size.y - 5.0),
				"%.0f" % _slider_to_zoom(tick_ratios()[i]), HORIZONTAL_ALIGNMENT_LEFT, 34.0, 8,
				Color(0.55, 0.62, 0.72))
	var cx := tr.position.x + 2.0 + (tr.size.x - 4.0) * _zoom_to_slider()
	draw_rect(Rect2(cx - 3.0, tr.position.y + 2.0, 6.0, tr.size.y - 4.0), Color(0.95, 0.85, 0.45))
	if font != null:
		draw_string(font, Vector2(tr.position.x + 2.0, tr.position.y + tr.size.y - 3.0),
			"%.0f" % px_per_sec, HORIZONTAL_ALIGNMENT_LEFT, tr.size.x - 10.0, 8, Color(0.62, 0.68, 0.78))
	# 鼠标锚点指示（第 48 轮）：让"缩放锚在鼠标处"这件事可见
	if _last_mouse_x >= GUTTER and _last_mouse_x <= size.x:
		draw_line(Vector2(_last_mouse_x, RULER_H - 4.0), Vector2(_last_mouse_x, content_height()),
			Color(0.95, 0.85, 0.45, 0.28), 1.0)

func _draw_rows() -> void:
	var font: Font = ThemeDB.fallback_font
	for i in doc.track_count():
		var tr := doc.track(i)
		var y := track_to_y(i)
		var h := row_height(i)          # 第 46 轮：逐轨高度（可单独拖）
		var bg := ROW_SEL if i == selected_track else (ROW_BG_ALT if i % 2 == 1 else ROW_BG)
		draw_rect(Rect2(0, y, size.x, h), bg, true)
		draw_line(Vector2(0, y + h), Vector2(size.x, y + h), GRID, 1.0)
		# 下边界的"抓手"：三个小点，明确"这里可以拖高度"（剪映也有这根分隔条）
		var grip_col := Color(0.62, 0.70, 0.82, 0.85 if _row_edge_hover == i else 0.45)
		for g in range(-1, 2):
			draw_rect(Rect2(GUTTER + 8.0 + float(g) * 6.0, y + h - 1.0, 4.0, 2.0), grip_col, true)
		var kind := StringName(str(tr.get("kind", "")))
		var color: Color = TRACK_COLORS.get(kind, Color(0.8, 0.8, 0.8))
		# 轨道名（左侧栏）
		if font != null:
			var kind_entry: Dictionary = Cutscene.TRACK_KINDS.get(kind, {})
			var label := "%s" % str(kind_entry.get("label", str(kind)))
			if str(tr.get("target", "")) != "":
				label += "·%s" % str(tr["target"])
			draw_string(font, Vector2(6, y + h * 0.66), label, HORIZONTAL_ALIGNMENT_LEFT, GUTTER - 10, 11, color)
		draw_line(Vector2(GUTTER, y), Vector2(GUTTER, y + h), GRID_MAJOR, 1.0)
		# ---- ③ 轨道缩略：按轨道种类画"内容"（照剪映：轨道里不是空白）----
		_draw_track_thumb(i, y, h, color)
		# 关键帧之间的连线（让"这段在动"一眼可见）
		var ks := doc.keys(i)
		for ki in ks.size():
			var kx := time_to_x(float((ks[ki] as Dictionary).get("t", 0.0)))
			var ky := y + h * 0.5
			if ki > 0:
				var px := time_to_x(float((ks[ki - 1] as Dictionary).get("t", 0.0)))
				draw_line(Vector2(px, ky), Vector2(kx, ky), Color(color.r, color.g, color.b, 0.5), 1.0)
		for k2 in ks.size():
			var kx2 := time_to_x(float((ks[k2] as Dictionary).get("t", 0.0)))
			var ky2 := y + h * 0.5
			var selected := (i == selected_track and k2 == selected_key)
			var kc := KEY_SEL if selected else KEY_COLOR
			var pts := PackedVector2Array([
				Vector2(kx2, ky2 - KEY_R), Vector2(kx2 + KEY_R, ky2),
				Vector2(kx2, ky2 + KEY_R), Vector2(kx2 - KEY_R, ky2),
			])
			draw_colored_polygon(pts, kc)

func _draw_playhead() -> void:
	var x := time_to_x(playhead)
	if x < GUTTER or x > size.x:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), PLAYHEAD, 1.0)
	# 抓手做大一点（±6px 的梯形），让"这根线可以拖"一眼看得出来
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 6, 0), Vector2(x + 6, 0),
		Vector2(x + 3, 9), Vector2(x - 3, 9),
	]), PLAYHEAD)
	if _scrubbing:
		# 擦洗中在标尺上叠一层浅色，明确"正在拖播放头"
		draw_rect(Rect2(Vector2(GUTTER, 0), Vector2(maxf(size.x - GUTTER, 0.0), 3.0)),
			Color(1.0, 0.6, 0.6, 0.55), true)
