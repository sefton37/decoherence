extends RefCounted
class_name BootAnimator

## Frame-count-driven line-animation engine (Spec #373 / plan-373 SS1-SS2).
## Reuses TerminalGrid's EXISTING write_line()/update_last_line() calls --
## both already emit Signals.line_rendered (Spec #371) -- so every animated
## frame is automatically visible to the probe's PROBE_RENDERED echo with
## ZERO probe-side changes and NO new signal.
##
## Determinism is binding, not a preference (DOD-19 / DOD-TRAP-B): content
## is a PURE function of (style_id, seed_value, frame_index, total_frames).
## frames_for_duration() computes an INTEGER frame count ONCE from a
## duration constant -- it never measures real elapsed time in a
## while-elapsed loop -- and the frame loop below always executes exactly
## `total_frames - 1` waits regardless of real scheduling jitter (Godot's
## one-shot SceneTree.create_timer() always eventually fires exactly once).
## The RNG seed always arrives as a caller-supplied parameter (a pure
## position formula -- stage_index*1000+line_index for the normal boot,
## style_index*100+sample_index for the gallery, both owned by
## boot_controller.gd) -- this file never re-randomizes its generator and
## never reads any elapsed-runtime or system-clock engine call to derive a
## seed.
##
## Prefix/value split: every animated line is split into a frozen `prefix`
## (everything through its trailing dot-leader run + trailing whitespace)
## and a churning `value` (whatever follows) -- lines with no dot-leader
## get prefix="" and the whole line as value. The FINAL frame always
## returns the literal, unmodified `value`, so `prefix + value` on the last
## frame is byte-identical to the un-animated line -- this is what protects
## every existing content assertion (HOST_OK, GPU_OK, DOD-4/6/11, etc.)
## from regression.

const FRAME_INTERVAL_SEC := 0.15
const MIN_FRAMES := 5

const _SPINNER_GLYPHS := ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
const _BAR_WIDTH := 12
const _SWEEP_WIDTH := 10
const _GLYPH_POOL := ["▓", "▒", "░", "▚", "▞", "▛", "▜", "▙", "▟", "◆", "◇", "※", "Ѫ", "Ж", "Σ"]
const _DOT_STATUSES := ["SCANNING", "PROBING", "SYNCING", "VERIFYING", "RESOLVING"]


## Splits `text` on its trailing dot-leader run (2+ literal dots) plus any
## trailing whitespace; group 1 (the frozen prefix) always includes that
## run, group 2 (the value) is everything after it. No dot-leader ->
## prefix="", value=text.
static func split_label_value(text: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("^(.*?\\.{2,}\\s*)(.*)$")
	var m := regex.search(text)
	if m == null:
		return {"prefix": "", "value": text}
	return {"prefix": m.get_string(1), "value": m.get_string(2)}


## Pure arithmetic -- an integer frame count derived once from a duration
## constant, floored at MIN_FRAMES so every animated line clears DOD-15's
## ANIM_OK (>=3 distinct renders of the CPU line) with comfortable margin.
## Never reads real elapsed time.
static func frames_for_duration(duration_ms: int) -> int:
	var raw := int(round(float(duration_ms) / (FRAME_INTERVAL_SEC * 1000.0)))
	return maxi(raw, MIN_FRAMES)


## Deterministic frame content for one style at one frame index. On the
## final frame (frame_index == total_frames - 1) EVERY style returns the
## literal, unmodified `value` -- the one invariant every style must honor.
static func frame_value(style_id: String, value: String, frame_index: int, total_frames: int, rng: RandomNumberGenerator) -> String:
	if frame_index >= total_frames - 1:
		return value
	match style_id:
		"spinner":
			return _spinner_frame(value, rng)
		"progress_bar":
			return _progress_bar_frame(value, frame_index, total_frames)
		"glyph_decode":
			return _glyph_decode_frame(value, frame_index, total_frames, rng)
		"dot_crawl":
			return _dot_crawl_frame(frame_index, rng)
		"percent_counter":
			return _percent_counter_frame(value, frame_index, total_frames, rng)
		"sweep_band":
			return _sweep_band_frame(value, frame_index, total_frames)
		_:
			return value


## Style 1: braille spinner glyph cycling at line start.
static func _spinner_frame(value: String, rng: RandomNumberGenerator) -> String:
	var glyph: String = _SPINNER_GLYPHS[rng.randi_range(0, _SPINNER_GLYPHS.size() - 1)]
	return glyph + " " + value


## Style 2: block progress bar filling left-to-right, proportional to
## frame progress -- purely positional, no RNG needed.
static func _progress_bar_frame(value: String, frame_index: int, total_frames: int) -> String:
	var filled: int = int(round(float(frame_index) / float(total_frames - 1) * _BAR_WIDTH))
	var bar := "[" + "▓".repeat(filled) + "░".repeat(_BAR_WIDTH - filled) + "]"
	return bar + " " + value


## Indeterminate variant of style 2 (progress_bar) for a gate wait whose
## total duration is not known in advance (Spec #375 / model_load gate).
## Reuses _progress_bar_frame's own arithmetic rather than forking a second
## bar-drawing routine: the caller-supplied `tick` (an incrementing
## poll-attempt counter, never a wall-clock read) is capped one slot short
## of _BAR_WIDTH before being handed to _progress_bar_frame, so the
## returned bracket run can NEVER show every slot filled -- the honest-
## completion invariant is enforced by construction, not by convention.
static func indeterminate_bar_frame(value: String, tick: int) -> String:
	var capped_tick: int = mini(tick, _BAR_WIDTH - 1)
	return _progress_bar_frame(value, capped_tick, _BAR_WIDTH + 1)


## The single fully-filled bar frame -- rendered only once the real gate has
## genuinely resolved success (Spec #375). Reuses _progress_bar_frame's own
## final-frame arithmetic (frame_index == total_frames - 1) instead of
## hand-rolling a second "all slots filled" string.
static func full_bar_frame(value: String) -> String:
	return _progress_bar_frame(value, 1, 2)


## Style 3: alien glyphs churn and resolve left-to-right into the final
## text, proportional to frame progress.
static func _glyph_decode_frame(value: String, frame_index: int, total_frames: int, rng: RandomNumberGenerator) -> String:
	var resolved: int = int(round(float(frame_index) / float(total_frames - 1) * value.length()))
	var out := value.substr(0, resolved)
	for i in range(resolved, value.length()):
		out += _GLYPH_POOL[rng.randi_range(0, _GLYPH_POOL.size() - 1)]
	return out


## Style 4: dot-crawl with intermediate status-word flickers.
static func _dot_crawl_frame(frame_index: int, rng: RandomNumberGenerator) -> String:
	var status: String = _DOT_STATUSES[rng.randi_range(0, _DOT_STATUSES.size() - 1)]
	var dots := ".".repeat((frame_index % 4) + 1)
	return status + dots


## Style 5: percentage counter with nonlinear jitter -- the underlying
## progress is linear in frame index, but a seeded jitter term makes each
## reading stall/jump rather than count up smoothly.
static func _percent_counter_frame(value: String, frame_index: int, total_frames: int, rng: RandomNumberGenerator) -> String:
	var linear: float = float(frame_index) / float(total_frames - 1) * 100.0
	var jitter: float = rng.randf_range(-4.0, 4.0)
	var pct: int = clampi(int(round(linear + jitter)), 0, 99)
	return "%3d%%  %s" % [pct, value]


## Style 6: sweep/knight-rider scanning band -- purely positional, no RNG
## needed.
static func _sweep_band_frame(value: String, frame_index: int, total_frames: int) -> String:
	var pos: int = int(round(float(frame_index) / float(total_frames - 1) * float(_SWEEP_WIDTH - 1)))
	var band := ""
	for i in range(_SWEEP_WIDTH):
		band += "█" if i == pos else "-"
	return "[" + band + "] " + value


## Drives one line's full animation lifecycle: writes the first frame via
## write_line() (establishing the row's color, which update_last_line()
## never changes), then a loop of update_last_line() calls -- one per
## FRAME_INTERVAL_SEC tick -- culminating in the exact final `full_text`.
static func animate_line(tree: SceneTree, terminal: TerminalGrid, style_id: String, seed_value: int, full_text: String, color, duration_ms: int) -> void:
	var split := split_label_value(full_text)
	var total_frames := frames_for_duration(duration_ms)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	terminal.write_line(split["prefix"] + frame_value(style_id, split["value"], 0, total_frames, rng), color)
	for i in range(1, total_frames):
		await tree.create_timer(FRAME_INTERVAL_SEC, false).timeout  # pausable: the pause menu (Spec #578) freezes the show
		terminal.update_last_line(split["prefix"] + frame_value(style_id, split["value"], i, total_frames, rng))
