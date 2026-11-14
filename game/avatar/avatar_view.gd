extends Node3D
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 581 S1 -- the view node that puts the player's body into the world. It sits after the Walker in
## world.tscn, finds that sibling, removes the walker's placeholder capsule and visor, hangs the procedural
## body (avatar_body.gd) under walker.body_node() and, every frame, turns the walker's measured ground
## movement into a pose (avatar_gait.gd). The body hangs UNDER the walker's body node on purpose: the
## walker's yaw, its body_offset_y hook and every probe's hide-the-body differential keep working unchanged.
## Provenance: procedural and self-made; no imported art, nothing ported from elsewhere.
##
## Arrival-cutscene hook (Spec 576 S2): hold_pose(phase, moving) freezes the body in a pose the caller
## chooses, and release_pose() hands it back to the walker. A scripted drive is added by S2.

const AvatarBody := preload("res://game/avatar/avatar_body.gd")
const AvatarGait := preload("res://game/avatar/avatar_gait.gd")
const TEMPLATE_PATH := "res://game/avatar/avatar_template.json"
const TELEPORT_M := 1.5  ## a one-frame move longer than this is a teleport, not a step
const RING := 2048  ## per-frame update times kept for stats()
const WARMUP_CALLS := 120  ## the first frames after attach share the frame with world start-up (chunk builds, shader compiles); stats() leaves them out

## The preset to wear; empty means the template's default_preset.
@export var preset: String = ""

var _tpl := {}
var _cfg := {}
var _walker: Node3D
var _body: Node3D
var _joints := {}
var _state := {}
var _last := Vector3.ZERO
var _held := false
var _ring := PackedInt32Array()
var _calls := 0
var _seen := 0
var _head := 0


func _ready() -> void:
	_ring.resize(RING)
	_tpl = AvatarBody.load_template(TEMPLATE_PATH)
	if _tpl.is_empty():
		push_warning("avatar_view: the template did not load; the walker keeps its placeholder body")
		return
	var w := get_parent().get_node_or_null("Walker") if get_parent() != null else null
	if w != null:
		attach(w)


## Attaches to a walker: frees whatever is under its body node and builds the body there.
func attach(walker: Node3D) -> void:
	_walker = walker
	var host: Node3D = walker.body_node()
	for c in host.get_children():
		host.remove_child(c)
		c.queue_free()
	_build(host)
	_last = walker.pos


func _build(host: Node3D) -> void:
	if _body != null:
		_body.get_parent().remove_child(_body)
		_body.queue_free()
	var pid := preset if not preset.is_empty() else String(_tpl["default_preset"])
	_cfg = AvatarBody.gait_cfg(_tpl, pid)
	var c: Dictionary = _tpl.duplicate(true)
	c["preset_id"] = pid
	_body = AvatarBody.build(c)
	host.add_child(_body)
	_joints = AvatarBody.joints(_body)
	_state = AvatarGait.initial_state()
	_apply()


## Switches to another preset by id. Returns false (and changes nothing) for an id the template lacks.
func set_preset(id: String) -> bool:
	if _tpl.is_empty() or _walker == null:
		return false
	for p in _tpl["presets"]:
		if String(p["id"]) == id:
			preset = id
			_build(_walker.body_node())
			return true
	return false


## Freezes the body in the pose at this point of the cycle (0..1): striding when `moving`, standing when not.
## The walker no longer drives the body until release_pose().
func hold_pose(phase: float, moving: bool) -> void:
	if _body == null:
		return
	_held = true
	_state = AvatarGait.initial_state()
	_state["phase"] = fposmod(phase, 1.0)
	_state["walk_amt"] = 1.0 if moving else 0.0
	_apply()


func release_pose() -> void:
	_held = false
	if _walker != null:
		_last = _walker.pos


## Update-time statistics (microseconds) over the last RING frames after the first WARMUP_CALLS: calls (counted
## after the warm-up), mean, p95, max.
func stats() -> Dictionary:
	var n := mini(_calls, RING)
	if n == 0:
		return {"calls": 0, "mean_us": 0.0, "p95_us": 0.0, "max_us": 0.0}
	var xs := _ring.slice(0, n)
	xs.sort()
	var sum := 0
	for v in xs:
		sum += v
	return {"calls": _calls, "mean_us": float(sum) / float(n), "p95_us": float(xs[int(floor(0.95 * float(n - 1)))]), "max_us": float(xs[n - 1])}


## The built body, its joints, and the preset in force (the probes read these).
func body() -> Node3D:
	return _body


func joint_nodes() -> Dictionary:
	return _joints


func preset_id() -> String:
	return String(_body.get_meta("preset_id")) if _body != null else ""


func _apply() -> void:
	if _body != null:
		AvatarBody.apply_pose(_joints, AvatarGait.pose(_state, _cfg))


func _process(delta: float) -> void:
	if _held or _walker == null or _body == null:
		return
	var t0 := Time.get_ticks_usec()
	var p: Vector3 = _walker.pos
	var d := Vector2(p.x - _last.x, p.z - _last.z).length()
	_last = p
	if d > TELEPORT_M:
		d = 0.0
	AvatarGait.step(_state, _cfg, d, minf(delta, 0.1), _walker.on_ground)
	_apply()
	_seen += 1
	if _seen > WARMUP_CALLS:
		_ring[_head] = Time.get_ticks_usec() - t0
		_head = (_head + 1) % RING
		_calls += 1
