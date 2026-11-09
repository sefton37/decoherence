extends Node3D
## Spec #501 chunk streamer: keeps a ring of terrain chunks loaded around a focus point.
##
## The meshing itself is the engine's StalagChunkMesher (C++), run on WorkerThreadPool
## tasks -- never on the main thread (the `sync_build` mutation exists only so the probe
## can prove the frame-budget and main-thread detectors fire). The main thread only
## adopts finished meshes, at most ADOPT_PER_FRAME per frame, and frees far chunks.
##
## Chunks tile the world on the engine's chunk size; a chunk node sits at its origin and
## its mesh vertices are chunk-local, so node placement is part of what the probe checks.

signal chunk_built(coord: Vector2i, vertices: PackedVector3Array)
signal chunk_loaded(coord: Vector2i)
signal chunk_unloaded(coord: Vector2i)
## The water plan could not be solved (an invariant failed); no chunk will ever load.
signal plan_failed(message: String)

## Load every chunk within LOAD_RADIUS (Chebyshev, in chunks) of the focus chunk; free
## those beyond UNLOAD_RADIUS. The gap is hysteresis so the boundary does not thrash.
const LOAD_RADIUS := 2
const UNLOAD_RADIUS := 3
## Tasks in flight at once; the rest wait their turn nearest-first.
const MAX_IN_FLIGHT := 4
const ADOPT_PER_FRAME := 1

## Spec #517: materials are game policy, handed in by the world scene before the first
## chunk. Terrain chunks get grass on surface "grass" and dirt on "dirt"; the water child
## gets the water material. A null falls back to a plain vertex-colour material.
var grass_material: Material
var dirt_material: Material
var water_material: Material

## Debug/negative-control hook: build on the main thread (what the streamer must NOT do).
var sync_build: bool = false

var stats := {"loads": 0, "unloads": 0, "max_loaded": 0, "boundaries_crossed": 0}

var _chunk_m: float
var _grid_min: int
var _grid_max: int
var _material: StandardMaterial3D
var _plan_failed_emitted := false
var _stopped := false  # set by shutdown(): no further builds are ever requested
var _pending_water: Array = []  # [coord, mesh]: attached one per frame, the frame after its chunk
var _focus_chunk := Vector2i(1 << 30, 1 << 30)
var _chunks := {}  # Vector2i -> MeshInstance3D
var _in_flight := {}  # Vector2i -> task id
var _done: Array = []  # finished builds, guarded by _mutex
var _mutex := Mutex.new()


func _ready() -> void:
	_chunk_m = StalagWorld.get_chunk_m()
	var half := StalagWorld.get_half_extent_m()
	_grid_min = floori(-half / _chunk_m)
	_grid_max = floori(half / _chunk_m)
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.metallic_specular = 0.0
	# The whole-world water plan is solved once, on a worker thread, and the streamer asks for
	# no chunk until it is ready: every chunk's terrain and water are functions of it.
	StalagWorld.start_plan()


## The chunk's water child (a MeshInstance3D owned by the chunk node), or null.
func water_node(coord: Vector2i) -> MeshInstance3D:
	var mi: MeshInstance3D = _chunks.get(coord)
	return mi.get_node_or_null("Water") if mi != null else null


func water_nodes() -> Array:
	var out: Array = []
	for c in _chunks.keys():
		var w := water_node(c)
		if w != null:
			out.append(w)
	return out


## The most chunks this streamer will ever hold (the unload ring, clipped to the world).
func cap() -> int:
	var side := mini(2 * UNLOAD_RADIUS + 1, _grid_max - _grid_min + 1)
	return side * side


## True when the focus ring is adopted, nothing is being built, and every water mesh is attached.
func settled() -> bool:
	return ring_ready() and _in_flight.is_empty() and _done.is_empty() and _pending_water.is_empty()


func focus_chunk() -> Vector2i:
	return _focus_chunk


func loaded_count() -> int:
	return _chunks.size()


func pending_count() -> int:
	return _in_flight.size() + _done.size()


func chunk_node(coord: Vector2i) -> MeshInstance3D:
	return _chunks.get(coord)


func chunk_coords() -> Array:
	return _chunks.keys()


func chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / _chunk_m), floori(p.z / _chunk_m))


## True once every chunk of the load ring around the focus is adopted.
func ring_ready() -> bool:
	if _focus_chunk.x == (1 << 30):
		return false
	for c in _wanted(_focus_chunk, LOAD_RADIUS):
		if not _chunks.has(c):
			return false
	return true


func set_focus(p: Vector3) -> void:
	var fc := chunk_of(p)
	if fc != _focus_chunk:
		if _focus_chunk.x != (1 << 30):
			stats["boundaries_crossed"] += 1
		_focus_chunk = fc


func _wanted(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var c := Vector2i(center.x + dx, center.y + dz)
			if c.x < _grid_min or c.x > _grid_max or c.y < _grid_min or c.y > _grid_max:
				continue
			out.append(c)
	return out


func _process(_delta: float) -> void:
	if _stopped:
		return
	if not StalagWorld.plan_ready():
		if StalagWorld.plan_status() == 3 and not _plan_failed_emitted:
			_plan_failed_emitted = true
			plan_failed.emit(StalagWorld.plan_error())
		return
	if _focus_chunk.x == (1 << 30):
		return
	_attach_water()
	_adopt_finished()
	_request_missing()
	_unload_far()
	stats["max_loaded"] = maxi(stats["max_loaded"], _chunks.size())


func _request_missing() -> void:
	var want := _wanted(_focus_chunk, LOAD_RADIUS)
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _cheb_dist2(a) < _cheb_dist2(b))
	for c in want:
		if _chunks.has(c) or _in_flight.has(c):
			continue
		if sync_build:
			# Negative control only: the build runs HERE, on the main thread.
			var res := StalagChunkMesher.build_chunk(c.x, c.y)
			_adopt(c, res)
			return
		if _in_flight.size() >= MAX_IN_FLIGHT:
			return
		_in_flight[c] = WorkerThreadPool.add_task(_build_job.bind(c), false, "stalag chunk %d,%d" % [c.x, c.y])


func _cheb_dist2(c: Vector2i) -> int:
	var dx := c.x - _focus_chunk.x
	var dz := c.y - _focus_chunk.y
	return dx * dx + dz * dz


## Runs on a worker thread.
func _build_job(c: Vector2i) -> void:
	var res := StalagChunkMesher.build_chunk(c.x, c.y)
	_mutex.lock()
	_done.append([c, res])
	_mutex.unlock()


## The water mesh of a chunk is a child of the chunk node (so unloading the chunk frees it),
## attached the frame AFTER the terrain so one frame never pays for both uploads.
func _attach_water() -> void:
	if _pending_water.is_empty():
		return
	var item = _pending_water.pop_front()
	var mi: MeshInstance3D = _chunks.get(item[0])
	if mi == null:
		return  # the chunk was unloaded before its water arrived
	var wi := MeshInstance3D.new()
	wi.name = "Water"
	wi.mesh = item[1]
	wi.material_override = water_material if water_material != null else _material
	wi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_child(wi)


func _adopt_finished() -> void:
	for _i in range(ADOPT_PER_FRAME):
		_mutex.lock()
		var item = _done.pop_front() if not _done.is_empty() else null
		_mutex.unlock()
		if item == null:
			return
		var c: Vector2i = item[0]
		var tid: int = _in_flight.get(c, -1)
		if tid != -1:
			WorkerThreadPool.wait_for_task_completion(tid)  # already finished; reaps the task
			_in_flight.erase(c)
		# Focus may have moved on while it built: do not adopt a chunk nobody wants now.
		if _chebyshev(c, _focus_chunk) > UNLOAD_RADIUS or _chunks.has(c):
			continue
		_adopt(c, item[1])


func _adopt(c: Vector2i, res: Dictionary) -> void:
	var verts: PackedVector3Array = res["vertices"]
	chunk_built.emit(c, verts)
	if verts.is_empty():
		return  # outside the footprint: nothing to show, nothing to hold
	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [c.x, c.y]
	mi.mesh = res["mesh"]
	var kinds: Array = res.get("surface_kinds", [])
	for si in range(kinds.size()):
		var m: Material = grass_material if kinds[si] == "grass" else dirt_material
		mi.set_surface_override_material(si, m if m != null else _material)
	mi.position = Vector3(c.x * _chunk_m, 0.0, c.y * _chunk_m)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if res.has("water"):
		_pending_water.append([c, res["water"]["mesh"]])
	add_child(mi)
	_chunks[c] = mi
	stats["loads"] += 1
	chunk_loaded.emit(c)


func _unload_far() -> void:
	for c in _chunks.keys():
		if _chebyshev(c, _focus_chunk) > UNLOAD_RADIUS:
			var mi: MeshInstance3D = _chunks[c]
			_chunks.erase(c)
			remove_child(mi)
			mi.queue_free()
			stats["unloads"] += 1
			chunk_unloaded.emit(c)


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Waits for in-flight builds and frees every chunk (used by the probe and on module exit).
func shutdown() -> void:
	_stopped = true
	for c in _in_flight.keys():
		WorkerThreadPool.wait_for_task_completion(_in_flight[c])
	_in_flight.clear()
	_pending_water.clear()
	_mutex.lock()
	_done.clear()
	_mutex.unlock()
	for c in _chunks.keys():
		var mi: MeshInstance3D = _chunks[c]
		remove_child(mi)
		mi.free()
	_chunks.clear()
