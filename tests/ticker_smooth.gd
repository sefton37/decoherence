extends Node

## Smooth-scroll test for the BUS> ticker and the other conveyors (issue #865,
## follow-up to Spec #519). Run via tests/verify_ticker_smooth.sh. Output:
##   TICKER_UNIT_OK <name> / TICKER_UNIT_FAIL <name>: <why>   (script exits 1)
##   TICKER_NEGCTL_OK <name>   the checker DOES reject the old one-cell stepping
##   TICKER_FRAMES mode=<m> n=<n> min=<px> max=<px> mean=<px> total=<px>
##   TICKER_RENDER_OK frames=<n> ...   (only with TICKER_RENDER=1, on a display)
## Set TICKER_DUMP=<dir> to also write the per-frame offsets and strip crops.

const CW := PanelLayout.CELL_W
const CH := PanelLayout.CELL_H

var _failed: int = 0


func _ready() -> void:
	_run()


func _run() -> void:
	_unit_offsets_fixed_delta()
	_unit_offsets_jittery_delta()
	_unit_decoupled_from_grid_tick()
	_unit_speed_is_data()
	_unit_source_discipline()
	_negctl_legacy_stepping()
	if OS.get_environment("TICKER_RENDER") == "1":
		await _render_frames()
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(name: String) -> void:
	print("TICKER_UNIT_OK ", name)


func _fail(name: String, why: String) -> void:
	_failed += 1
	print("TICKER_UNIT_FAIL %s: %s" % [name, why])


func _panels(preset: String = "full_bus") -> BootPanels:
	var p := BootPanels.new()
	add_child(p)
	p.setup(preset, Vector2i(1920, 1080), true)
	return p


## Consecutive-frame check: every step is > 0 (it moves), < `limit` (sub-cell)
## and the series is monotone. Returns "" when fine, else the reason.
static func judge(series: Array, limit: float) -> String:
	for i in range(1, series.size()):
		var d: float = float(series[i]) - float(series[i - 1])
		if d <= 0.0:
			return "no forward movement at frame %d (step %.3f)" % [i, d]
		if d >= limit:
			return "step %.3f px at frame %d is not sub-cell (< %.1f)" % [d, i, limit]
	return ""


func _report(mode: String, series: Array) -> void:
	var mn := 1e9
	var mx := -1e9
	var sum := 0.0
	for i in range(1, series.size()):
		var d: float = float(series[i]) - float(series[i - 1])
		mn = minf(mn, d)
		mx = maxf(mx, d)
		sum += d
	print("TICKER_FRAMES mode=%s n=%d min=%.3f max=%.3f mean=%.3f total=%.1f" % [mode, series.size(), mn, mx, sum / float(series.size() - 1), sum])


func _unit_offsets_fixed_delta() -> void:
	var p := _panels()
	var boot: Array = [p.ticker_offset_px()]
	var hexo: Array = [p.hex_offset_px()]
	var spk: Array = [p.spark_offset_px()]
	for i in range(240):  # 4 s at 60 fps
		p._process(1.0 / 60.0)
		boot.append(p.ticker_offset_px())
		hexo.append(p.hex_offset_px())
		spk.append(p.spark_offset_px())
	_report("boot", boot)
	var why := judge(boot, float(CW))
	if why != "":
		return _fail("ticker_boot_subcell", why)
	_ok("ticker_boot_subcell")
	why = judge(hexo, float(CH))
	if why != "":
		return _fail("hex_subrow", why)
	_ok("hex_subrow")
	why = judge(spk, float(CW))
	if why != "":
		return _fail("spark_subcell", why)
	_ok("spark_subcell")
	var avg: float = (float(boot[-1]) - float(boot[0])) / 4.0
	if absf(avg - 120.0) > 1.0:
		return _fail("ticker_boot_speed", "mean %.2f px/s, want 120 (12 cells/s as before)" % avg)
	_ok("ticker_boot_speed")
	# Shell mode: roughly the old one cell per 3 ticks = 40 px/s.
	p.enter_shell_mode()
	var shell: Array = [p.ticker_offset_px()]
	for i in range(240):
		p._process(1.0 / 60.0)
		shell.append(p.ticker_offset_px())
	_report("shell", shell)
	why = judge(shell, float(CW))
	if why != "":
		return _fail("ticker_shell_subcell", why)
	_ok("ticker_shell_subcell")
	avg = (float(shell[-1]) - float(shell[0])) / 4.0
	if absf(avg - 40.0) > 1.0:
		return _fail("ticker_shell_speed", "mean %.2f px/s, want 40" % avg)
	_ok("ticker_shell_speed")
	p.queue_free()


func _unit_offsets_jittery_delta() -> void:
	# Frame times from 240 fps to 20 fps (50 ms): still strictly sub-cell.
	var p := _panels()
	var deltas := [1.0 / 240.0, 1.0 / 144.0, 1.0 / 60.0, 1.0 / 30.0, 0.05, 1.0 / 90.0]
	var series: Array = [p.ticker_offset_px()]
	for i in range(120):
		p._process(deltas[i % deltas.size()])
		series.append(p.ticker_offset_px())
	var why := judge(series, float(CW))
	if why != "":
		return _fail("ticker_jittery_frames", why)
	_ok("ticker_jittery_frames")
	p.queue_free()


func _unit_decoupled_from_grid_tick() -> void:
	# At 60 fps the 12 Hz grid tick fires every 5th frame; the ticker must move
	# on every frame, including the four frames between ticks.
	var p := _panels()
	var moved_between := 0
	var between := 0
	for i in range(120):
		var f0: int = p._frame
		var o0: float = p.ticker_offset_px()
		p._process(1.0 / 60.0)
		if p._frame == f0:
			between += 1
			if p.ticker_offset_px() > o0:
				moved_between += 1
	if between < 60 or moved_between != between:
		return _fail("ticker_moves_between_ticks", "moved %d of %d between-tick frames" % [moved_between, between])
	_ok("ticker_moves_between_ticks")
	p.queue_free()


func _unit_speed_is_data() -> void:
	var parsed = IntentRouter.load_json(BootPanels.DATA_PATH)
	var sc: Dictionary = parsed.get("smooth_scroll", {}) if typeof(parsed) == TYPE_DICTIONARY else {}
	for k in ["ticker_boot_px_per_sec", "ticker_shell_px_per_sec", "hex_px_per_sec", "spark_px_per_sec"]:
		if not sc.has(k) or float(sc[k]) <= 0.0:
			return _fail("speed_in_data", "boot_panels.json smooth_scroll.%s missing or not positive" % k)
	_ok("speed_in_data")


func _unit_source_discipline() -> void:
	# text_speed must not reach the ticker and the CRT flicker stays independent.
	var src := FileAccess.get_file_as_string("res://frontdoor/scripts/boot_panels.gd")
	var code := ""
	for line in src.split("\n"):
		if not line.strip_edges().begins_with("#"):
			code += line + "\n"
	for banned in ["text_speed", "flicker", "SettingsStore", "get_ticks_", "Time.get_"]:
		if code.find(banned) != -1:
			return _fail("source_discipline", "boot_panels.gd code mentions '%s'" % banned)
	_ok("source_discipline")


func _negctl_legacy_stepping() -> void:
	# The old behaviour: one whole cell per 12 Hz tick, sampled at 60 fps.
	var legacy: Array = []
	for i in range(241):
		legacy.append(float((i * 12 / 60) * CW))
	var why := judge(legacy, float(CW))
	if why == "":
		_fail("negctl_legacy_stepping", "judge accepted the old tick-stepping series")
		return
	print("TICKER_NEGCTL_OK legacy_stepping rejected: ", why)
	# A series that jumps a whole cell or reverses must also be rejected.
	if judge([0.0, 2.0, 12.0], float(CW)) == "" or judge([0.0, 2.0, 1.0], float(CW)) == "":
		_fail("negctl_jump_or_reverse", "judge accepted a jump or a reversal")
		return
	print("TICKER_NEGCTL_OK jump_and_reverse rejected")


## Real frames on a real renderer: the offset series and the ticker's actual
## pixels, frame by frame.
func _render_frames() -> void:
	var p := _panels()
	await get_tree().process_frame
	await get_tree().process_frame
	var series: Array = []
	var shifts: Array = []
	var prev_prof := PackedFloat32Array()
	var dump := OS.get_environment("TICKER_DUMP")
	var lines: PackedStringArray = []
	var sw := 700  # strip crop width, past the "BUS>" label
	for i in range(100):
		await get_tree().process_frame
		series.append(p.ticker_offset_px())
		var img := get_tree().root.get_texture().get_image()
		var crop := img.get_region(Rect2i(50, 1080 - 40, sw, CH))
		var prof := PackedFloat32Array()
		prof.resize(sw)
		for x in range(sw):
			var s := 0.0
			for y in range(CH):
				s += crop.get_pixel(x, y).get_luminance()
			prof[x] = s
		var shift := -1
		if prev_prof.size() == sw:
			# Text moves LEFT: current[x] == previous[x + d]; pick the best d in 0..CW.
			var best := 1e18
			for d in range(0, CW + 1):
				var err := 0.0
				for x in range(0, sw - CW - 1):
					err += absf(prof[x] - prev_prof[x + d])
				if err < best:
					best = err
					shift = d
		shifts.append(shift)
		prev_prof = prof
		lines.append("%d %.3f %d" % [i, p.ticker_offset_px(), shift])
		if dump != "" and i >= 10 and i <= 15:
			crop.save_png("%s/strip_%03d.png" % [dump, i])
	if dump != "":
		var f := FileAccess.open(dump + "/offsets.txt", FileAccess.WRITE)
		f.store_string("frame offset_px measured_pixel_shift\n" + "\n".join(lines) + "\n")
	var why := judge(series, float(CW))
	if why != "":
		return _fail("render_ticker_offsets", why)
	_report("render", series)
	# Pixels: the strip really moves by sub-cell amounts on frames, and over
	# the run the ink advanced about as far as the offsets say.
	var moved := 0
	var worst := 0
	var total := 0
	for i in range(1, shifts.size()):
		var sh: int = shifts[i]
		if sh > 0:
			moved += 1
		worst = maxi(worst, sh)
		total += sh
	var want: float = float(series[-1]) - float(series[1])
	if worst >= CW:
		return _fail("render_pixel_shift", "a frame moved the strip %d px (>= a whole cell)" % worst)
	if absf(float(total) - want) > want * 0.05 + float(CW):
		return _fail("render_pixel_total", "pixels advanced %d px, offsets say %.1f" % [total, want])
	print("TICKER_RENDER_OK frames=%d moved_frames=%d max_px_shift=%d pixel_total=%d offset_total=%.1f" % [series.size(), moved, worst, total, want])
	p.queue_free()
