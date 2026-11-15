extends Node3D
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 582 S1 -- the far terrain: real terrain shape out to about 840 m, for the `horizon` view level.
##
## A camera-centred pyramid of heightfield tiles (three levels, 2 m, 4 m and 16 m cells) built in GDScript from the
## engine's own bound height function StalagWorld.surface_height, plus tree tiers (real placements for the
## footprint chunks that are not loaded, hashed impostors outside the footprint, cluster billboards far out) and a
## flat haze skirt out to the camera's far plane. It is visual only: no collision, nothing walkable.
##
## Each level of tiles shows only inside its own square window around the focus chunk and outside the finer level's
## window (the shader discards the rest), so the levels meet on one line and never overlap. The finest level is the
## world's own chunk grid: a chunk's tile is hidden exactly while that chunk is loaded. Every tile carries a short
## skirt on its edges that seals the cracks between levels.
##
## Heights come from the engine only. Nothing here invents terrain: there is no noise, no random number and no
## clock; the hashed trees use an integer hash of their cell. Every tile and every tree tile is computed on a worker
## thread (the engine's height and placement functions are the ones its chunk workers already call); the main
## thread only adopts finished arrays into meshes, a few per frame. A probe can drive both halves itself
## (manual_step) to time them.
## Provenance: written for this project. The impostor sprites, the cross mesh, the species table and the integer
## hash are adapted from game/world/backdrop_ring.gd (Spec 580 S4, same project, same licence); everything else is
## new. No image, mesh or sound is loaded from disk.

const TreeAssets := preload("res://game/world/tree_assets.gd")
const SHADER := "res://game/world/far_terrain.gdshader"
const CAMERA_FAR_M := 200000.0  ## the world's camera far plane while the far terrain is on (the skirt reaches it)
const SKIRT_HALF_M := 150000.0
const SKIRT_Y := -4.0  ## the haze skirt lies under every real height (the lowest river bed is above 0 m)
const FLAT_Y := 3.0  ## the negative control's constant height
## The three terrain levels. `tile_m` is the tile side, `cell_m` the grid step, `outer_m` the half side of the
## level's window around the focus chunk's centre, `skirt_m` how far the tile edges drop.
const LEVELS := [
	{"name": "l1", "cell_m": 2.0, "tile_m": 28.0, "outer_m": 154.0, "skirt_m": 1.0},
	{"name": "l2", "cell_m": 4.0, "tile_m": 112.0, "outer_m": 336.0, "skirt_m": 2.0},
	{"name": "l3", "cell_m": 16.0, "tile_m": 448.0, "outer_m": 840.0, "skirt_m": 6.0},
]
const FADE_START_FRAC := 0.7  ## the haze takes over from this share of the outer radius
const MAX_TASKS := 3  ## worker tasks in flight at once (the streamer's chunk workers share the pool)
const STARTS_PER_STEP := 2  ## worker tasks started per frame
const SCAN_PER_STEP := 24  ## queue entries looked at per frame (stale ones are dropped, not built)
const CALM_FRAMES := 3  ## frames the streamer must be settled before the far terrain adopts anything
const ADOPT_PER_STEP := 1  ## finished jobs turned into scene nodes per frame (a mesh or a multimesh costs about 2 ms to adopt)
const HASH_TILE_M := 112.0
const HASH_CELL_M := 4.0
const HASH_CHANCE := 0.5
const HASH_OUTER_M := 560.0  ## hashed impostors stand from the footprint edge to here (from the origin)
const CLUSTER_TILE_M := 224.0
const CLUSTER_CELL_M := 16.0
const CLUSTER_CHANCE := 0.6
const CLUSTER_OUTER_M := 960.0
const TREE_MIN_SCALE := 0.85
const TREE_MAX_SCALE := 1.2
const TREE_WIDTH_FRAC := 0.42
const CLUSTER_W_M := 17.0
const CLUSTER_H_M := 13.0
const LEAF_BAKED := Color(0.78, 1.0, 0.78)
const SPECIES_WEIGHTS := {
	"boreal-fir": 20, "young-spire": 16, "broadleaf-lump": 15, "frost-sapling": 12, "scrub-birch": 12,
	"northwatch-larch": 10, "twin-trunk": 10, "sensor-pine": 3, "tall-pine": 3, "elder-pine": 1,
}
const DEAD_FORMS := ["standing-snag", "cut-stump"]  ## carry no crown, so no far impostor
const GROUND_LOW := Color(0.17, 0.29, 0.08)
const GROUND_HIGH := Color(0.27, 0.32, 0.11)
const GROUND_ROCK := Color(0.36, 0.34, 0.30)
const HIGH_RAMP_M := 90.0  ## the height at which the ground colour reaches GROUND_HIGH
const ROCK_SLOPE_FROM := 0.06  ## 1 - normal.y where rock starts to show (about 20 degrees)
const ROCK_SLOPE_TO := 0.28  ## ... and where the ground is all rock (about 44 degrees)
const WATER_COLOR := Color(0.12, 0.34, 0.36)
const CANOPY_TINT := 0.3  ## share of the mean crown colour mixed into the far end's ground colour
const PLAN_HALF_M := 224.0  ## the water plan's domain: water exists nowhere beyond it
const COLUMN_M := 0.5  ## one plan column
const TERRACE_M := 0.5  ## a water level in the plan is counted in terraces

## A probe sets these before the node enters the tree (or calls set_flat before the first step).
var manual_step := false
var flat_mutation := false  ## the negative control: every tile is built flat
var norelief_mutation := false  ## the negative control: every tile reads the engine height clamped into the plan domain (the valley, no highlands)
var focus_valid := false
var _calm := 0
var last_adopted: Array = []  ## "kind:level" of the jobs the last adopt_pending() turned into nodes (a probe reads it)

var tris := 0  ## triangles held by the built tiles and tree impostors

var _streamer: Node
var _sf := 0.125
var _chunk_m := 28.0
var _half_extent_m := 112.0
var _grid_min := -4
var _grid_max := 4
var _shader: Shader
var _level_mats: Array = []  ## one terrain material per level
var _tree_mat: ShaderMaterial
var _skirt_mat: ShaderMaterial
var _skirt: MeshInstance3D
var _all_mats: Array = []
var _fc := Vector2i(1 << 30, 1 << 30)  ## the focus chunk
var _loaded: Dictionary = {}  ## Vector2i -> true while the chunk is loaded in the streamer
var _attached: Dictionary = {}  ## Vector2i -> true once the streamer has attached that chunk's real trees
var _tiles: Array = [{}, {}, {}]  ## per level: Vector2i -> {node, tris, heights, wet}
var _tier_real: Dictionary = {}  ## chunk Vector2i -> {node, count, pos (PackedVector3Array)}
var _tier_hash: Dictionary = {}  ## tile Vector2i -> {node, count, pos}
var _tier_cluster: Dictionary = {}  ## tile Vector2i -> {node, count, pos}
var _dirty_queue := false
var _jobs: Array = []  ## queued jobs, nearest first
var _job_keys: Dictionary = {}  ## "kind:level:ix:iz" -> true while queued, running or waiting to be adopted
var _running: Array = []  ## jobs being computed on worker tasks
var _pending: Array = []  ## finished jobs waiting to be adopted into the scene
var _species: Array = []
var _weight_total := 0
var _form_nominal: Dictionary = {}
var _species_color: Dictionary = {}
var _canopy_mean := Color(0.2, 0.3, 0.12)
var _sprites: Array = []
var _impostor_mesh: ArrayMesh
var _tree_totals := {"real": 0, "hashed": 0, "cluster": 0}
var _setup_done := false
var _clip_state: Array = []
var _range_cache: Array = [Vector4i(), Vector4i(), Vector4i()]  ## per terrain level: the tile range last planned for
var _hash_range := Vector4i()
var _cluster_range := Vector4i()
var _real_queued := false
var _win: Array = []  ## the three window rectangles of the current focus (recomputed when the focus chunk changes)


## `tree_assets` is the world's TreeAssets (read only: manifest, leaf images and crown tint table); `streamer` the
## world's streamer (its chunk_loaded and chunk_unloaded signals decide which tiles and real trees are shown).
func setup(tree_assets: RefCounted, streamer: Node) -> void:
	_streamer = streamer
	_sf = StalagWorld.get_sf()
	_chunk_m = StalagWorld.get_chunk_m()
	_half_extent_m = StalagWorld.get_half_extent_m()
	_grid_min = floori(-_half_extent_m / _chunk_m)
	_grid_max = floori(_half_extent_m / _chunk_m)
	_shader = load(SHADER)
	for l in range(LEVELS.size()):
		var m := _material()
		_level_mats.append(m)
		_all_mats.append(m)
	_skirt_mat = _material()
	_all_mats.append(_skirt_mat)
	_tree_mat = _material()
	_tree_mat.set_shader_parameter("use_sprite", true)
	_sprites = [_sprite(false), _sprite(true)]
	_tree_mat.set_shader_parameter("sprite_cone", _sprites[0])
	_tree_mat.set_shader_parameter("sprite_round", _sprites[1])
	_all_mats.append(_tree_mat)
	_impostor_mesh = _cross_mesh()
	_build_species(tree_assets)
	_build_skirt()
	if streamer != null:
		streamer.chunk_loaded.connect(_on_chunk_loaded)
		streamer.chunk_unloaded.connect(_on_chunk_unloaded)
		streamer.trees_attached.connect(_on_trees_attached)
		for c in streamer.chunk_coords():
			_loaded[c] = true
	_setup_done = true


func materials() -> Array:
	return _all_mats


## The material the tree impostors wear (a probe gives the same billboards a depth material).
func tree_material() -> ShaderMaterial:
	return _tree_mat


## Pushes the world's fog to every material of the far terrain: `density` is the exp-squared density and
## `haze` the colour the far ground fades to (the preset's ground_haze).
func set_fog(density: float, haze: Color) -> void:
	for m in _all_mats:
		(m as ShaderMaterial).set_shader_parameter("fog_density", density)
		(m as ShaderMaterial).set_shader_parameter("haze_color", haze)
	_clip_state = []  # the fade and clip values are re-pushed with the next focus change


func _material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("fade_start", float(LEVELS[LEVELS.size() - 1]["outer_m"]) * FADE_START_FRAC)
	m.set_shader_parameter("fade_end", float(LEVELS[LEVELS.size() - 1]["outer_m"]))
	return m


# ---------------------------------------------------------------- focus, the plan of tiles, visibility
## Follows the walker (any frame). Re-plans only when the focus chunk changes.
func set_focus(p: Vector3) -> void:
	var c := Vector2i(floori(p.x / _chunk_m), floori(p.z / _chunk_m))
	if c == _fc:
		return
	_fc = c
	focus_valid = true
	var fcm := focus_center()
	_win = []
	for l in range(LEVELS.size()):
		var r := float(LEVELS[l]["outer_m"])
		_win.append(Rect2(fcm - Vector2(r, r), Vector2(2.0 * r, 2.0 * r)))
	_replan()


## The centre of the focus chunk, in metres.
func focus_center() -> Vector2:
	return (Vector2(_fc) + Vector2(0.5, 0.5)) * _chunk_m


func _window(level: int) -> Rect2:
	return _win[level]


## The square window (around the focus chunk's centre) that a level draws inside, in metres.
func window_rect(level: int) -> Rect2:
	return _window(level)


func _tile_rect(level: int, ix: int, iz: int) -> Rect2:
	var s := float(LEVELS[level]["tile_m"])
	return Rect2(Vector2(float(ix) * s, float(iz) * s), Vector2(s, s))


func _cheb(c: Vector2i) -> int:
	return maxi(absi(c.x - _fc.x), absi(c.y - _fc.y))


## Which tiles each level wants right now (a tile is wanted when it can show inside its window).
func _wanted(level: int) -> Array:
	var out: Array = []
	var s := float(LEVELS[level]["tile_m"])
	var r := _index_range(focus_center(), float(LEVELS[level]["outer_m"]) + s, s)  # one tile of margin: built before the window reaches it
	var inner := Rect2()
	if level > 0:
		inner = _window(level - 1).grow(-s)  # hidden under the finer level now and for the next tile of movement
	var has_inner := inner.size.x > 0.0 and inner.size.y > 0.0
	for ix in range(r.x, r.y + 1):
		for iz in range(r.z, r.w + 1):
			if level == 0:
				if _cheb(Vector2i(ix, iz)) < 2 and ix >= _grid_min and ix <= _grid_max and iz >= _grid_min and iz <= _grid_max:
					continue  # the inner chunks of the grid load first; their tiles would only be hidden
			elif has_inner and inner.encloses(_tile_rect(level, ix, iz)):
				continue
			out.append(Vector2i(ix, iz))
	return out


func _inside(r: Rect2, w: Rect2) -> bool:
	return w.encloses(r)


## The tile index range (x0, x1, z0, z1) a square of half side `half` around (cx, cz) touches on a grid of `tile` metres.
func _index_range(c: Vector2, half: float, tile: float) -> Vector4i:
	return Vector4i(floori((c.x - half) / tile), floori((c.x + half - 0.001) / tile), floori((c.y - half) / tile), floori((c.y + half - 0.001) / tile))


func _replan() -> void:
	var fcm := focus_center()
	# terrain tiles: queue the missing wanted ones, free the ones far outside the window. A coarse level's tile
	# range moves only when the focus crosses one of its tile edges, so it is re-planned only then.
	for l in range(LEVELS.size()):
		var s := float(LEVELS[l]["tile_m"])
		var rng := _index_range(fcm, float(LEVELS[l]["outer_m"]) + s, s)
		var can_skip := false
		if l > 0:
			var inner := _window(l - 1).grow(-s)
			can_skip = inner.size.x < s or inner.size.y < s  # no tile of this level can be hidden under the finer one
		if l > 0 and can_skip and rng == _range_cache[l]:
			continue
		_range_cache[l] = rng
		var want := {}
		for k in _wanted(l):
			want[k] = true
			if not _tiles[l].has(k):
				_queue("t", l, k, fcm.distance_squared_to(_tile_rect(l, k.x, k.y).get_center()))
		var keep := _window(l).grow(s * 2.0)
		for k in _tiles[l].keys():
			if not want.has(k) and not keep.intersects(_tiles[l][k]["rect"]):
				_free_tile(l, k)
	# real trees: every footprint chunk (queued nearest first), shown only while its chunk is not loaded; the set is
	# static, so it is queued once
	if not _real_queued:
		_real_queued = true
		for cx in range(_grid_min, _grid_max + 1):
			for cz in range(_grid_min, _grid_max + 1):
				var k := Vector2i(cx, cz)
				if absf((float(cx) + 0.5) * _chunk_m) < _half_extent_m + _chunk_m and absf((float(cz) + 0.5) * _chunk_m) < _half_extent_m + _chunk_m:
					_queue("r", 0, k, fcm.distance_squared_to((Vector2(k) + Vector2(0.5, 0.5)) * _chunk_m) + 1.0e7)
	# hashed impostor tiles and cluster tiles: static grids around the origin, wanted near the focus
	var hr := _index_range(fcm, HASH_OUTER_M + HASH_TILE_M, HASH_TILE_M)
	if hr != _hash_range:
		_hash_range = hr
		for ix in range(hr.x, hr.y + 1):
			for iz in range(hr.z, hr.w + 1):
				var k := Vector2i(ix, iz)
				var cx := (float(ix) + 0.5) * HASH_TILE_M
				var cz := (float(iz) + 0.5) * HASH_TILE_M
				if _tier_hash.has(k) or maxf(absf(cx), absf(cz)) > HASH_OUTER_M + HASH_TILE_M * 0.5:
					continue
				if maxf(absf(cx), absf(cz)) + HASH_TILE_M * 0.5 <= _half_extent_m:
					continue  # wholly inside the footprint: the real placements stand there
				_queue("h", 0, k, fcm.distance_squared_to(Vector2(cx, cz)) + 2.0e7)
	var cr := _index_range(fcm, CLUSTER_OUTER_M, CLUSTER_TILE_M)
	if cr != _cluster_range:
		_cluster_range = cr
		for ix in range(cr.x, cr.y + 1):
			for iz in range(cr.z, cr.w + 1):
				var k := Vector2i(ix, iz)
				var cx := (float(ix) + 0.5) * CLUSTER_TILE_M
				var cz := (float(iz) + 0.5) * CLUSTER_TILE_M
				if _tier_cluster.has(k) or maxf(absf(cx), absf(cz)) - CLUSTER_TILE_M * 0.5 >= CLUSTER_OUTER_M:
					continue
				if maxf(absf(cx), absf(cz)) + CLUSTER_TILE_M * 0.5 <= HASH_OUTER_M:
					continue  # wholly inside the impostor tier
				_queue("c", 0, k, fcm.distance_squared_to(Vector2(cx, cz)) + 3.0e7)
	if _dirty_queue:
		_jobs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["prio"] < b["prio"])
		_dirty_queue = false
	_refresh()


## A job's identity as one integer (kind, level and tile), so the queue check costs one dictionary lookup.
func _job_id(kind: String, level: int, key: Vector2i) -> int:
	var k := 0
	match kind:
		"r":
			k = 1
		"h":
			k = 2
		"c":
			k = 3
	return ((k * 4 + level) << 44) | ((key.x + 32768) << 22) | (key.y + 32768)


func _queue(kind: String, level: int, key: Vector2i, prio: float) -> void:
	var id := _job_id(kind, level, key)
	if _job_keys.has(id):
		return
	_job_keys[id] = true
	_jobs.append({"kind": kind, "level": level, "key": key, "prio": prio, "id": id})
	_dirty_queue = true


func _free_tile(l: int, k: Vector2i) -> void:
	var t: Dictionary = _tiles[l][k]
	tris -= int(t["tris"])
	(t["node"] as Node).queue_free()
	_tiles[l].erase(k)
	_job_keys.erase(_job_id("t", l, k))


## Applies the focus to what is drawn: window clips, fade centre, and which tiles and real-tree nodes are shown.
func _refresh() -> void:
	if not focus_valid:
		return
	var fcm := focus_center()
	var state := [_fc]
	if state != _clip_state:
		_clip_state = state
		var w0 := _window(0)
		var w1 := _window(1)
		var w2 := _window(2)
		var rects := [
			[Vector4(0, 0, 0, 0), Vector4(w0.position.x, w0.position.y, w0.end.x, w0.end.y)],
			[Vector4(w0.position.x, w0.position.y, w0.end.x, w0.end.y), Vector4(w1.position.x, w1.position.y, w1.end.x, w1.end.y)],
			[Vector4(w1.position.x, w1.position.y, w1.end.x, w1.end.y), Vector4(w2.position.x, w2.position.y, w2.end.x, w2.end.y)],
		]
		for l in range(LEVELS.size()):
			(_level_mats[l] as ShaderMaterial).set_shader_parameter("clip_in", rects[l][0])
			(_level_mats[l] as ShaderMaterial).set_shader_parameter("clip_out", rects[l][1])
		for m in _all_mats:
			(m as ShaderMaterial).set_shader_parameter("fade_center", fcm)
	for l in range(LEVELS.size()):
		var tl: Dictionary = _tiles[l]
		for k in tl.keys():
			(tl[k]["node"] as Node3D).visible = _tile_shown(l, k)
	for k in _tier_real.keys():
		var r: Dictionary = _tier_real[k]
		if r["node"] != null:
			(r["node"] as Node3D).visible = not _attached.has(k)


func _tile_shown(l: int, k: Vector2i) -> bool:
	if l == 0:
		return maxi(absi(k.x - _fc.x), absi(k.y - _fc.y)) <= 5 and not _loaded.has(k)
	var r: Rect2 = _tiles[l][k]["rect"]
	return _win[l].intersects(r) and not _win[l - 1].encloses(r)


func _on_chunk_loaded(c: Vector2i) -> void:
	_loaded[c] = true
	if _tiles[0].has(c):
		(_tiles[0][c]["node"] as Node3D).visible = false


func _on_chunk_unloaded(c: Vector2i) -> void:
	_loaded.erase(c)
	_attached.erase(c)
	if _tiles[0].has(c):
		(_tiles[0][c]["node"] as Node3D).visible = _tile_shown(0, c)
	if _tier_real.has(c) and _tier_real[c]["node"] != null:
		(_tier_real[c]["node"] as Node3D).visible = true


## The real trees of a chunk take over from the far impostors once the streamer has attached them.
func _on_trees_attached(c: Vector2i) -> void:
	_attached[c] = true
	if _tier_real.has(c) and _tier_real[c]["node"] != null:
		(_tier_real[c]["node"] as Node3D).visible = false


# ---------------------------------------------------------------- the per-frame step
func _process(_delta: float) -> void:
	if manual_step or not _setup_done:
		return
	step()


func _exit_tree() -> void:
	for r in _running:
		WorkerThreadPool.wait_for_task_completion(int(r["task"]))
	_running = []


## True when nothing is queued, running or waiting to be adopted.
func is_done() -> bool:
	return _jobs.is_empty() and _running.is_empty() and _pending.is_empty() and focus_valid


func queued_count() -> int:
	return _jobs.size() + _running.size() + _pending.size()


## One frame's main-thread work: adopt what the workers finished, then start more tasks.
func step() -> void:
	adopt_pending()
	build_some()


## Turns finished jobs into scene nodes, at most ADOPT_PER_STEP of them (the main-thread cost of a tile).
func adopt_pending() -> void:
	last_adopted = []
	if _pending.is_empty():
		return
	# A mesh upload that lands in the same frames as a chunk's (several MB) can stall for milliseconds, so the far
	# terrain adopts only after the streamer has had nothing pending for CALM_FRAMES frames: nearest chunks first,
	# then the far view.
	if _streamer != null:
		_calm = _calm + 1 if _streamer.settled() else 0
		if _calm < CALM_FRAMES:
			return
	var n := mini(_pending.size(), ADOPT_PER_STEP)
	for q in range(n):
		var job: Dictionary = _pending.pop_front()
		last_adopted.append("%s:%d" % [job["kind"], job["level"]])
		match str(job["kind"]):
			"t":
				_adopt_terrain(job)
			"r":
				_adopt_trees(job, "real")
			"h":
				_adopt_trees(job, "hashed")
			"c":
				_adopt_trees(job, "cluster")


## Collects finished worker tasks and starts queued jobs on workers (up to MAX_TASKS at once, at most
## STARTS_PER_STEP new ones per frame, looking at no more than SCAN_PER_STEP queue entries).
func build_some() -> void:
	# every height and every water level is a function of the water plan: nothing is built before it is solved
	# (a tile built earlier would carry the uncarved terrain, and which tiles that touched would depend on timing)
	if not StalagWorld.plan_ready():
		return
	var still: Array = []
	for r in _running:
		if WorkerThreadPool.is_task_completed(int(r["task"])):
			WorkerThreadPool.wait_for_task_completion(int(r["task"]))
			_pending.append(r)
		else:
			still.append(r)
	_running = still
	var started := 0
	var scanned := 0
	while _running.size() < MAX_TASKS and started < STARTS_PER_STEP and scanned < SCAN_PER_STEP and not _jobs.is_empty():
		var job: Dictionary = _jobs.pop_front()
		scanned += 1
		if _stale(job):
			_job_keys.erase(job["id"])
			continue
		job["task"] = WorkerThreadPool.add_task(_work.bind(job), false, "far terrain")
		_running.append(job)
		started += 1


## Runs on a worker thread: the whole job, to completion.
func _work(job: Dictionary) -> void:
	match str(job["kind"]):
		"t":
			_build_terrain(job)
		"r":
			_build_real(job)
		"h":
			_build_hashed(job, 1 << 30)
		_:
			_build_cluster(job, 1 << 30)


## A tile whose window moved away while it waited is dropped, not built.
func _stale(job: Dictionary) -> bool:
	if str(job["kind"]) != "t":
		return false
	var l: int = job["level"]
	var k: Vector2i = job["key"]
	return not _win[l].grow(float(LEVELS[l]["tile_m"])).intersects(_tile_rect(l, k.x, k.y))


# ---------------------------------------------------------------- terrain tiles
## The engine's height at (x, z) in metres. It is the carved height inside the water plan's domain and the plain
## terrain beyond it. Nothing else is read: the heights of the far terrain are the engine's own.
func _h(x: float, z: float) -> float:
	if flat_mutation:
		return FLAT_Y
	if norelief_mutation:
		x = clampf(x, -PLAN_HALF_M, PLAN_HALF_M)
		z = clampf(z, -PLAN_HALF_M, PLAN_HALF_M)
	return StalagWorld.surface_height(x / _sf, z / _sf) * _sf


func _build_terrain(job: Dictionary) -> int:
	var l: int = job["level"]
	var k: Vector2i = job["key"]
	var lv: Dictionary = LEVELS[l]
	var cell := float(lv["cell_m"])
	var tile := float(lv["tile_m"])
	var n := int(roundf(tile / cell))
	var x0 := float(k.x) * tile
	var z0 := float(k.y) * tile
	var dim := n + 3
	var hs := PackedFloat32Array()
	hs.resize(dim * dim)
	for j in range(dim):
		for i in range(dim):
			hs[j * dim + i] = _h(x0 + float(i - 1) * cell, z0 + float(j - 1) * cell)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var inner := PackedFloat32Array()
	var nv := (n + 1) * (n + 1)
	verts.resize(nv)
	norms.resize(nv)
	cols.resize(nv)
	inner.resize(nv)
	for j in range(n + 1):
		for i in range(n + 1):
			var hc := hs[(j + 1) * dim + (i + 1)]
			var dx := (hs[(j + 1) * dim + (i + 2)] - hs[(j + 1) * dim + i]) / (2.0 * cell)
			var dz := (hs[(j + 2) * dim + (i + 1)] - hs[j * dim + (i + 1)]) / (2.0 * cell)
			var nrm := Vector3(-dx, 1.0, -dz).normalized()
			var x := x0 + float(i) * cell
			var z := z0 + float(j) * cell
			var idx := j * (n + 1) + i
			verts[idx] = Vector3(x, hc, z)
			norms[idx] = nrm
			cols[idx] = _ground_color(x, z, hc, nrm.y, l)
			inner[idx] = hc
	var idxs := PackedInt32Array()
	idxs.resize(n * n * 6)
	var at := 0
	for j in range(n):
		for i in range(n):
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + (n + 1)
			var d := c + 1
			# Godot's front face is clockwise seen from above: a, c, b and b, c, d face up
			idxs[at] = a
			idxs[at + 1] = c
			idxs[at + 2] = b
			idxs[at + 3] = b
			idxs[at + 4] = c
			idxs[at + 5] = d
			at += 6
	var tri_count := 2 * n * n
	# skirts: a dropped copy of each edge vertex, joined to the edge by a strip
	var drop := float(lv["skirt_m"])
	var base := verts.size()
	var edges: Array = []
	var e0 := PackedInt32Array()
	var e1 := PackedInt32Array()
	var e2 := PackedInt32Array()
	var e3 := PackedInt32Array()
	for i in range(n + 1):
		e0.append(i)
		e1.append(n * (n + 1) + i)
		e2.append(i * (n + 1))
		e3.append(i * (n + 1) + n)
	edges = [e0, e1, e2, e3]
	for e in edges:
		var first := verts.size()
		for src in e:
			var v: Vector3 = verts[src]
			verts.append(Vector3(v.x, v.y - drop, v.z))
			norms.append(Vector3.UP)
			cols.append(cols[src])
		for q in range(e.size() - 1):
			var t0: int = e[q]
			var t1: int = e[q + 1]
			var b0 := first + q
			var b1 := first + q + 1
			idxs.append_array([t0, b0, t1, t1, b0, b1])
			tri_count += 2
	var water_verts := PackedVector3Array()
	var water_cols := PackedColorArray()
	var wet := 0
	if l <= 1:
		var wy := _water_cells(x0, z0, n, cell, inner, water_verts, water_cols)
		wet = wy
		tri_count += wet * 2
	job["arrays"] = [verts, norms, cols, idxs]
	job["water"] = [water_verts, water_cols]
	job["heights"] = inner
	job["tris"] = tri_count
	job["done"] = true
	return dim * dim + tri_count


## Flat water quads for the cells of a tile whose plan column holds water above the ground (lakes, springs and
## river courses of the water plan). Returns the number of wet cells. Water exists only inside the plan's domain.
func _water_cells(x0: float, z0: float, n: int, cell: float, inner: PackedFloat32Array, wv: PackedVector3Array, wc: PackedColorArray) -> int:
	var wet := 0
	var dry := StalagWorld.water_dry_sentinel()
	for j in range(n):
		var cz := z0 + (float(j) + 0.5) * cell
		if absf(cz) >= PLAN_HALF_M:
			continue
		for i in range(n):
			var cx := x0 + (float(i) + 0.5) * cell
			if absf(cx) >= PLAN_HALF_M:
				continue
			var gx := floori(cx / COLUMN_M)
			var gz := floori(cz / COLUMN_M)
			var tw := StalagWorld.water_level_at(gx, gz)
			if tw == dry:
				tw = StalagWorld.course_level_at(gx, gz)
			if tw == dry:
				continue
			var y := float(tw) * TERRACE_M
			var a := inner[j * (n + 1) + i]
			var b := inner[j * (n + 1) + i + 1]
			var c := inner[(j + 1) * (n + 1) + i]
			var d := inner[(j + 1) * (n + 1) + i + 1]
			if (a + b + c + d) * 0.25 > y + 0.05:
				continue  # the bank here stands above the level
			var xa := x0 + float(i) * cell
			var za := z0 + float(j) * cell
			wv.append_array([Vector3(xa, y, za), Vector3(xa, y, za + cell), Vector3(xa + cell, y, za), Vector3(xa + cell, y, za), Vector3(xa, y, za + cell), Vector3(xa + cell, y, za + cell)])
			for _q in range(6):
				wc.append(WATER_COLOR)
			wet += 1
	return wet


func _ground_color(x: float, z: float, h: float, ny: float, level: int) -> Color:
	var patch := float(_hash(floori(x / 8.0), floori(z / 8.0), 7) & 255) / 255.0
	# the ground greens from the valley floor up the highland slopes (the ramp spans the height of the mountains,
	# not the few metres of the valley), and rock shows wherever the slope is steep
	var t := clampf(h / HIGH_RAMP_M + (patch - 0.5) * 0.5, 0.0, 1.0)
	var col := GROUND_LOW.lerp(GROUND_HIGH, t)
	var rock := smoothstep(ROCK_SLOPE_FROM, ROCK_SLOPE_TO, 1.0 - ny)
	col = col.lerp(GROUND_ROCK, rock)
	if level == LEVELS.size() - 1:
		# the far end reads as forest where the trees are only clusters; no canopy stands on bare rock
		col = col.lerp(_canopy_mean, CANOPY_TINT * (1.0 - rock))
	return col


func _adopt_terrain(job: Dictionary) -> void:
	var l: int = job["level"]
	var k: Vector2i = job["key"]
	_job_keys.erase(job["id"])
	if _tiles[l].has(k) or _stale(job):
		return
	var arr: Array = job["arrays"]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = arr[0]
	arrays[Mesh.ARRAY_NORMAL] = arr[1]
	arrays[Mesh.ARRAY_COLOR] = arr[2]
	arrays[Mesh.ARRAY_INDEX] = arr[3]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var wv: PackedVector3Array = job["water"][0]
	if not wv.is_empty():
		var wn := PackedVector3Array()
		wn.resize(wv.size())
		wn.fill(Vector3.UP)
		var wa := []
		wa.resize(Mesh.ARRAY_MAX)
		wa[Mesh.ARRAY_VERTEX] = wv
		wa[Mesh.ARRAY_NORMAL] = wn
		wa[Mesh.ARRAY_COLOR] = job["water"][1]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wa)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _level_mats[l]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Tile_%s_%d_%d" % [LEVELS[l]["name"], k.x, k.y]
	mi.visible = false
	add_child(mi)
	tris += int(job["tris"])
	_tiles[l][k] = {"node": mi, "tris": int(job["tris"]), "heights": job["heights"], "rect": _tile_rect(l, k.x, k.y)}
	mi.visible = _tile_shown(l, k)


## The tile mesh's own height at (x, z): the triangle of the built tile that the point lies in, interpolated as
## the renderer would. `level` is 0 to 2. NAN when that tile is not built.
## The built vertices of one terrain level (its grid, not the skirts) that lie at least `min_cheb_m` from the origin
## (Chebyshev), as parallel arrays: x, z, height, normal y and colour. The probe's relief and rock records read it.
func vertex_rows(level: int, min_cheb_m: float) -> Dictionary:
	var lv: Dictionary = LEVELS[level]
	var n := int(roundf(float(lv["tile_m"]) / float(lv["cell_m"])))
	var nv := (n + 1) * (n + 1)
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	var hs := PackedFloat32Array()
	var nys := PackedFloat32Array()
	var cols := PackedColorArray()
	for k in _tiles[level].keys():
		var arrays: Array = (_tiles[level][k]["node"] as MeshInstance3D).mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nr: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var cl: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		for i in range(nv):
			if maxf(absf(v[i].x), absf(v[i].z)) < min_cheb_m:
				continue
			xs.append(v[i].x)
			zs.append(v[i].z)
			hs.append(v[i].y)
			nys.append(nr[i].y)
			cols.append(cl[i])
	return {"x": xs, "z": zs, "h": hs, "ny": nys, "col": cols}


func mesh_height_at(level: int, x: float, z: float) -> float:
	var lv: Dictionary = LEVELS[level]
	var tile := float(lv["tile_m"])
	var cell := float(lv["cell_m"])
	var k := Vector2i(floori(x / tile), floori(z / tile))
	if not _tiles[level].has(k):
		return NAN
	var hs: PackedFloat32Array = _tiles[level][k]["heights"]
	var n := int(roundf(tile / cell))
	var fx := (x - float(k.x) * tile) / cell
	var fz := (z - float(k.y) * tile) / cell
	var i := mini(int(floor(fx)), n - 1)
	var j := mini(int(floor(fz)), n - 1)
	var u := fx - float(i)
	var v := fz - float(j)
	var ha := hs[j * (n + 1) + i]
	var hb := hs[j * (n + 1) + i + 1]
	var hc := hs[(j + 1) * (n + 1) + i]
	var hd := hs[(j + 1) * (n + 1) + i + 1]
	# the cell is split along b-c: a, c, b below it and b, c, d above it
	if u + v <= 1.0:
		return ha + (hb - ha) * u + (hc - ha) * v
	return hd + (hc - hd) * (1.0 - u) + (hb - hd) * (1.0 - v)


# ---------------------------------------------------------------- trees
func _build_species(tree_assets: RefCounted) -> void:
	var means := _leaf_means(tree_assets)
	var leaf_of := {}
	for form in tree_assets.manifest["forms"]:
		_form_nominal[form["id"]] = float(form["nominal_height_m"])
		if form["crown"] != null:
			leaf_of[form["id"]] = str(form["crown"]["leaf_tex"])
	var sum := Vector3.ZERO
	var wsum := 0.0
	for id in SPECIES_WEIGHTS.keys():
		var tint: Color = TreeAssets.crown_tint(TreeAssets.CROWN_TINTS[id])
		var leaf: Color = means[leaf_of[id]]
		var c := Color(leaf.r * LEAF_BAKED.r * tint.r, leaf.g * LEAF_BAKED.g * tint.g, leaf.b * LEAF_BAKED.b * tint.b)
		var rec := {"id": id, "color": c, "round": leaf_of[id] == "warm", "h": float(_form_nominal.get(id, 8.0))}
		_species.append(rec)
		_species_color[id] = rec
		_weight_total += int(SPECIES_WEIGHTS[id])
		sum += Vector3(c.r, c.g, c.b) * float(SPECIES_WEIGHTS[id])
		wsum += float(SPECIES_WEIGHTS[id])
	sum /= maxf(wsum, 1.0)
	_canopy_mean = Color(sum.x, sum.y, sum.z)
	# the dead forms are not drawn; any other form the manifest names gets its table entry or the mean colour
	for id in _form_nominal.keys():
		if not _species_color.has(id) and not DEAD_FORMS.has(id):
			_species_color[id] = {"id": id, "color": _canopy_mean, "round": false, "h": float(_form_nominal[id])}


func _pick_species(r: int) -> Dictionary:
	var a := r % _weight_total
	for s in _species:
		a -= int(SPECIES_WEIGHTS[s["id"]])
		if a < 0:
			return s
	return _species[0]


## Appends one impostor to a buffer: 12 transform floats, 4 colour floats, 4 custom floats (x = 1 for the round crown).
func _push_tree(buf: PackedFloat32Array, pos: Vector3, yaw: float, w: float, h: float, col: Color, round_crown: bool) -> void:
	var cy := cos(yaw)
	var sy := sin(yaw)
	# Basis(UP, yaw) scaled by (w, h, w): columns are (cy*w, 0, -sy*w), (0, h, 0), (sy*w, 0, cy*w); rows are written out
	buf.append_array([cy * w, 0.0, sy * w, pos.x, 0.0, h, 0.0, pos.y, -sy * w, 0.0, cy * w, pos.z])
	buf.append_array([col.r, col.g, col.b, 1.0])
	buf.append_array([1.0 if round_crown else 0.0, 0.0, 0.0, 0.0])


func _wet_at(x: float, z: float) -> bool:
	if absf(x) >= PLAN_HALF_M or absf(z) >= PLAN_HALF_M:
		return false
	var dry := StalagWorld.water_dry_sentinel()
	var gx := floori(x / COLUMN_M)
	var gz := floori(z / COLUMN_M)
	return StalagWorld.water_level_at(gx, gz) != dry or StalagWorld.course_level_at(gx, gz) != dry


## The real placements of a footprint chunk, drawn as impostors with the real colours (nothing is invented).
func _build_real(job: Dictionary) -> int:
	var k: Vector2i = job["key"]
	var d: Dictionary = StalagTrees.place_chunk(k.x, k.y)
	var buf := PackedFloat32Array()
	var pos := PackedVector3Array()
	var count := 0
	for id in d.keys():
		if DEAD_FORMS.has(id) or not _species_color.has(id):
			continue
		var sp: Dictionary = _species_color[id]
		var a: PackedFloat64Array = d[id]
		var m := a.size() / 14
		for q in range(m):
			var o := q * 14
			var th := float(sp["h"]) * float(a[o + 4]) * float(a[o + 7])
			var tw := th * TREE_WIDTH_FRAC * float(a[o + 6])
			var p := Vector3(a[o], a[o + 1] - 0.2, a[o + 2])
			_push_tree(buf, p, float(a[o + 3]), tw, th, sp["color"], bool(sp["round"]))
			pos.append(p)
			count += 1
	job["buf"] = buf
	job["pos"] = pos
	job["count"] = count
	job["done"] = true
	return 300 + count


func _build_hashed(job: Dictionary, budget: int) -> int:
	var k: Vector2i = job["key"]
	var per := int(HASH_TILE_M / HASH_CELL_M)
	if not job.has("row"):
		job["row"] = 0
		job["buf"] = PackedFloat32Array()
		job["pos"] = PackedVector3Array()
		job["count"] = 0
	var spent := 0
	var buf: PackedFloat32Array = job["buf"]
	var pos: PackedVector3Array = job["pos"]
	var row: int = job["row"]
	while row < per and spent < budget:
		var gz := k.y * per + row
		for i in range(per):
			var gx := k.x * per + i
			spent += 3
			var hh := _hash(gx, gz, 13)
			if float(hh & 1023) / 1024.0 >= HASH_CHANCE:
				continue
			var x := (float(gx) + 0.5) * HASH_CELL_M + (float((hh >> 10) & 255) / 255.0 - 0.5) * (HASH_CELL_M - 0.5)
			var z := (float(gz) + 0.5) * HASH_CELL_M + (float((hh >> 18) & 255) / 255.0 - 0.5) * (HASH_CELL_M - 0.5)
			var r := maxf(absf(x), absf(z))
			if r <= _half_extent_m + 1.0 or r > HASH_OUTER_M:
				continue
			spent += 4
			if _wet_at(x, z):
				continue
			var y := _h(x, z)
			var h2 := _hash(gx, gz, 29)
			var sp := _pick_species(int(h2 & 0xffff))
			var th: float = float(sp["h"]) * (TREE_MIN_SCALE + (TREE_MAX_SCALE - TREE_MIN_SCALE) * (float((h2 >> 16) & 255) / 255.0))
			var yaw := float((h2 >> 24) & 255) / 255.0 * TAU
			var p := Vector3(x, y - 0.2, z)
			_push_tree(buf, p, yaw, th * TREE_WIDTH_FRAC, th, sp["color"], bool(sp["round"]))
			pos.append(p)
			job["count"] = int(job["count"]) + 1
		row += 1
	job["row"] = row
	job["buf"] = buf
	job["pos"] = pos
	job["done"] = row >= per
	return maxi(spent, 1)


func _build_cluster(job: Dictionary, budget: int) -> int:
	var k: Vector2i = job["key"]
	var per := int(CLUSTER_TILE_M / CLUSTER_CELL_M)
	if not job.has("row"):
		job["row"] = 0
		job["buf"] = PackedFloat32Array()
		job["pos"] = PackedVector3Array()
		job["count"] = 0
	var spent := 0
	var buf: PackedFloat32Array = job["buf"]
	var pos: PackedVector3Array = job["pos"]
	var row: int = job["row"]
	while row < per and spent < budget:
		var gz := k.y * per + row
		for i in range(per):
			var gx := k.x * per + i
			spent += 3
			var hh := _hash(gx, gz, 41)
			if float(hh & 1023) / 1024.0 >= CLUSTER_CHANCE:
				continue
			var x := (float(gx) + 0.5) * CLUSTER_CELL_M + (float((hh >> 10) & 255) / 255.0 - 0.5) * (CLUSTER_CELL_M - 2.0)
			var z := (float(gz) + 0.5) * CLUSTER_CELL_M + (float((hh >> 18) & 255) / 255.0 - 0.5) * (CLUSTER_CELL_M - 2.0)
			var r := maxf(absf(x), absf(z))
			if r <= HASH_OUTER_M or r > CLUSTER_OUTER_M:
				continue
			spent += 4
			var y := _h(x, z)
			var h2 := _hash(gx, gz, 53)
			var s := 0.8 + 0.4 * (float((h2 >> 16) & 255) / 255.0)
			var shade := 0.82 + 0.18 * (float(h2 & 255) / 255.0)
			var p := Vector3(x, y - 0.3, z)
			_push_tree(buf, p, float((h2 >> 24) & 255) / 255.0 * TAU, CLUSTER_W_M * s, CLUSTER_H_M * s, _canopy_mean * shade, true)
			pos.append(p)
			job["count"] = int(job["count"]) + 1
		row += 1
	job["row"] = row
	job["buf"] = buf
	job["pos"] = pos
	job["done"] = row >= per
	return maxi(spent, 1)


func _adopt_trees(job: Dictionary, tier: String) -> void:
	var store: Dictionary = _tier_real if tier == "real" else (_tier_hash if tier == "hashed" else _tier_cluster)
	var k: Vector2i = job["key"]
	_job_keys.erase(job["id"])
	if store.has(k):
		return
	var count: int = job["count"]
	var rec := {"node": null, "count": count, "pos": job["pos"]}
	if count > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _impostor_mesh
		mm.instance_count = count
		mm.buffer = job["buf"]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _tree_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.name = "Trees_%s_%d_%d" % [job["kind"], k.x, k.y]
		mmi.visible = not (tier == "real" and _attached.has(k))
		add_child(mmi)
		rec["node"] = mmi
		tris += 2 * count
	store[k] = rec
	_tree_totals[tier] = int(_tree_totals[tier]) + count


# ---------------------------------------------------------------- skirt and procedural assets
## One flat quad under the world, from the camera's far plane in, painted with the far haze: the ground that
## keeps going to the horizon, fogged to nothing. It is the last thing the camera sees below the horizon line.
func _build_skirt() -> void:
	var h := SKIRT_HALF_M
	var verts := PackedVector3Array([Vector3(-h, SKIRT_Y, -h), Vector3(-h, SKIRT_Y, h), Vector3(h, SKIRT_Y, -h), Vector3(h, SKIRT_Y, h)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(1, 1, 1), Color(1, 1, 1), Color(1, 1, 1), Color(1, 1, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 2, 1, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(-h, SKIRT_Y - 1.0, -h), Vector3(2.0 * h, 2.0, 2.0 * h))
	_skirt = MeshInstance3D.new()
	_skirt.mesh = mesh
	_skirt.material_override = _skirt_mat
	_skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_skirt.name = "Skirt"
	add_child(_skirt)
	tris += 2


## One vertical quad, one metre wide and tall, standing on y = 0 (scaled per tree; the shader turns it to face the camera).
func _cross_mesh() -> ArrayMesh:
	var verts := PackedVector3Array([Vector3(-0.5, 1.0, 0.0), Vector3(0.5, 1.0, 0.0), Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	var idx := PackedInt32Array([0, 1, 2, 1, 3, 2])
	var normals := PackedVector3Array()
	normals.resize(4)
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A crown silhouette drawn in code: a layered cone (conifers) or a lumpy ellipse (broadleaf), alpha-cut.
func _sprite(round_crown: bool) -> ImageTexture:
	var w := 64
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		var fy := float(y) / float(h - 1)
		for x in range(w):
			var fx := (float(x) + 0.5) / float(w) * 2.0 - 1.0
			var inside := false
			if round_crown:
				var cy := (fy - 0.42) / 0.40
				inside = fx * fx + cy * cy <= 1.0 + 0.12 * sin(float(y) * 1.7 + float(x) * 0.9)
				if fy > 0.82 and absf(fx) < 0.09:
					inside = true
			else:
				var layer := fmod(fy * 7.0, 1.0)
				var half := fy * 0.92 * (0.70 + 0.30 * layer) + 0.04 * sin(float(y) * 2.3)
				inside = fy > 0.04 and absf(fx) <= half
				if fy > 0.9 and absf(fx) < 0.08:
					inside = true
			var v := 0.78 + 0.22 * float((_hash(x, y, 3) & 255)) / 255.0
			img.set_pixel(x, y, Color(v, v, v, 1.0 if inside else 0.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## The mean linear colour of the opaque pixels of each leaf texture ("warm", "cool").
func _leaf_means(tree_assets: RefCounted) -> Dictionary:
	var out := {}
	var imgs: Dictionary = tree_assets.leaf_images()
	for k in imgs.keys():
		var img: Image = imgs[k]
		var key := str(k).trim_prefix("leaf_")
		var sum := Vector3.ZERO
		var n := 0
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var px := img.get_pixel(x, y)
				if px.a > 0.45:
					var lin := px.srgb_to_linear()
					sum += Vector3(lin.r, lin.g, lin.b)
					n += 1
		sum /= float(maxi(n, 1))
		out[key] = Color(sum.x, sum.y, sum.z)
	return out


## A small integer hash of a cell and a salt (xorshift-multiply), deterministic across runs.
func _hash(a: int, b: int, salt: int) -> int:
	var h := (a * 374761393 + b * 668265263 + salt * 2246822519) & 0xffffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
	h = (h ^ (h >> 16)) & 0xffffffff
	return h


# ---------------------------------------------------------------- what the probes read
## Per level: name, cell, the window inside it (the finer level's outer radius, or the loaded ring for the first),
## outer radius, tiles built, triangles built.
func levels_info(load_radius: int) -> Array:
	var out: Array = []
	for l in range(LEVELS.size()):
		var lv: Dictionary = LEVELS[l]
		var t := 0
		for k in _tiles[l].keys():
			t += int(_tiles[l][k]["tris"])
		out.append({
			"name": lv["name"],
			"cell_m": lv["cell_m"],
			"inner_m": (float(load_radius) + 0.5) * _chunk_m if l == 0 else LEVELS[l - 1]["outer_m"],
			"outer_m": lv["outer_m"],
			"tiles": _tiles[l].size(),
			"tris": t,
		})
	return out


func tier_info() -> Array:
	return [
		{"name": "real", "range_m": [0.0, _half_extent_m], "instances": _tree_totals["real"], "kind": "real placements as impostors"},
		{"name": "hashed", "range_m": [_half_extent_m, HASH_OUTER_M], "instances": _tree_totals["hashed"], "kind": "hashed impostors"},
		{"name": "cluster", "range_m": [HASH_OUTER_M, CLUSTER_OUTER_M], "instances": _tree_totals["cluster"], "kind": "cluster billboards"},
	]


func tree_total() -> int:
	return int(_tree_totals["real"]) + int(_tree_totals["hashed"]) + int(_tree_totals["cluster"])


## The real placements of a footprint chunk as the far terrain built them (dead forms left out), or an empty array.
func real_positions(coord: Vector2i) -> PackedVector3Array:
	if _tier_real.has(coord):
		return _tier_real[coord]["pos"]
	return PackedVector3Array()


func real_chunks() -> Array:
	return _tier_real.keys()


## Every tree impostor the far terrain holds that is drawn right now: world positions (visible nodes only).
func drawn_tree_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for store in [_tier_real, _tier_hash, _tier_cluster]:
		for k in store.keys():
			var n = store[k]["node"]
			if n != null and (n as Node3D).visible:
				out.append_array(store[k]["pos"])
	return out


## A SHA-256 over the focus chunk and the heights of every tile the focus wants, in key order: the same world and
## focus give the same hash.
func state_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(PackedInt32Array([_fc.x, _fc.y]).to_byte_array())
	for l in range(LEVELS.size()):
		var keys: Array = _wanted(l)  # a function of the focus alone, so the hash does not depend on build order
		keys.sort()
		for k in keys:
			ctx.update(PackedInt32Array([l, k.x, k.y]).to_byte_array())
			if _tiles[l].has(k):
				ctx.update((_tiles[l][k]["heights"] as PackedFloat32Array).to_byte_array())
	return ctx.finish().hex_encode()


func _clip_rect(level: int, uniform: String) -> Rect2:
	var v: Vector4 = (_level_mats[level] as ShaderMaterial).get_shader_parameter(uniform)
	return Rect2(Vector2(v.x, v.y), Vector2(v.z - v.x, v.w - v.y))


## True when a point is drawn by a visible far tile (its level's window, outside the finer level's window).
func _drawn_by_tile(x: float, z: float) -> bool:
	var p := Vector2(x, z)
	for l in range(LEVELS.size()):
		var tile := float(LEVELS[l]["tile_m"])
		var k := Vector2i(floori(x / tile), floori(z / tile))
		if not _tiles[l].has(k) or not (_tiles[l][k]["node"] as Node3D).visible:
			continue
		if l > 0:
			var cin := _clip_rect(l, "clip_in")
			var cout := _clip_rect(l, "clip_out")
			if cin.has_point(p) or not cout.has_point(p):
				continue
		return true
	return false


## Sample points (step_m apart) inside the outermost window that neither a loaded chunk nor a visible tile covers.
func coverage_gaps(step_m: float) -> int:
	var w := _window(LEVELS.size() - 1)
	var gaps := 0
	var x := w.position.x + step_m * 0.5
	while x < w.end.x:
		var z := w.position.y + step_m * 0.5
		while z < w.end.y:
			var c := Vector2i(floori(x / _chunk_m), floori(z / _chunk_m))
			if not _loaded.has(c) and not _drawn_by_tile(x, z):
				gaps += 1
			z += step_m
		x += step_m
	return gaps


## The share of sample points inside loaded chunks that a visible far tile also draws (a tile over loaded ground).
func overlap_frac(step_m: float) -> float:
	var over := 0
	var total := 0
	for c in _loaded.keys():
		var x0: float = float(c.x) * _chunk_m
		var z0: float = float(c.y) * _chunk_m
		var x := x0 + step_m * 0.5
		while x < x0 + _chunk_m:
			var z := z0 + step_m * 0.5
			while z < z0 + _chunk_m:
				total += 1
				if _drawn_by_tile(x, z):
					over += 1
				z += step_m
			x += step_m
	return float(over) / float(maxi(total, 1))


func loaded_chunks() -> int:
	return _loaded.size()


## Collision objects anywhere under this node (there must be none).
func count_collision(n: Node = null) -> int:
	var node := n if n != null else self
	var k := 1 if node is CollisionObject3D else 0
	for c in node.get_children():
		k += count_collision(c)
	return k
