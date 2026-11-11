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
## Spec #545: a chunk's flora root was attached (the probe checks this never happens before the plan).
signal flora_attached(coord: Vector2i)
## Spec #549: a chunk's trees (and understory) root was attached.
signal trees_attached(coord: Vector2i)
signal understory_attached(coord: Vector2i)

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

## Spec #545: flora is game policy too. The world scene hands in {form id: {mesh, material, casts}};
## the chunk's placement arrives from the worker inside build_chunk and is adopted one chunk per
## frame, the frame after the terrain and water (never in the same frame as the water upload).
var flora_assets: Dictionary = {}
var flora_enabled: bool = true
## Probe hooks (negative controls only): place the flora on the main thread / shift it vertically.
var sync_flora: bool = false
var flora_y_offset: float = 0.0
var flora_adopt_ms: Array = []  # main-thread cost of attaching one chunk's flora
var flora_instances: int = 0  # instances live now

## Spec #549: trees and the understory are game policy too. The world scene hands in
## {form id: {part: {mesh, material, cast, range_end, colors}}} (parts trunk, crown, shadow) and
## {key: {mesh, material, cast, range_end, colors}}. Placement arrives from the worker inside
## build_chunk and is adopted one chunk per frame, after the flora. `shadows_enabled` false builds
## no shadow proxies and stops the trunks casting (the perf A/B); the numbers (cast settings, the
## distance limit) come from the handed-in assets, none are decided here.
var tree_assets: Dictionary = {}
var trees_enabled: bool = true
var understory_assets: Dictionary = {}
var understory_enabled: bool = true
var shadows_enabled: bool = true
## Probe hooks (negative controls only): place on the main thread / shift vertically.
var sync_trees: bool = false
var trees_y_offset: float = 0.0
var understory_y_offset: float = 0.0
var trees_adopt_ms: Array = []  # main-thread cost of attaching one chunk's trees
var understory_adopt_ms: Array = []
var tree_instances: int = 0  # tree instances live now
var understory_instances: int = 0

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
var _pending_flora: Array = []  # [coord, flora dict or null]: attached one per frame after the water
var _flora_counts := {}  # Vector2i -> instances attached to that chunk
var _pending_trees: Array = []  # [coord, trees dict or null]: attached one per frame after the flora
var _pending_understory: Array = []  # [coord, understory dict or null]: attached one per frame after the trees
var _tree_counts := {}  # Vector2i -> tree instances attached to that chunk
var _understory_counts := {}  # Vector2i -> understory instances attached to that chunk
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
	StalagFlora.set_enabled(flora_enabled)
	StalagTrees.set_enabled(trees_enabled)
	StalagUnderstory.set_enabled(understory_enabled)


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
	return ring_ready() and _in_flight.is_empty() and _done.is_empty() and _pending_water.is_empty() and _pending_flora.is_empty() and _pending_trees.is_empty() and _pending_understory.is_empty()


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
	# the flags may be flipped by a probe after _ready; the workers read them through these switches
	StalagTrees.set_enabled(trees_enabled)
	StalagUnderstory.set_enabled(understory_enabled)
	# One heavy main-thread step per frame: a chunk's water, else its flora, else its trees, else its
	# understory, else the next terrain.
	if not _attach_water() and not _attach_flora() and not _attach_trees() and not _attach_understory():
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
func _attach_water() -> bool:
	if _pending_water.is_empty():
		return false
	var item = _pending_water.pop_front()
	var mi: MeshInstance3D = _chunks.get(item[0])
	if mi == null:
		return true  # the chunk was unloaded before its water arrived
	var wi := MeshInstance3D.new()
	wi.name = "Water"
	wi.mesh = item[1]
	wi.material_override = water_material if water_material != null else _material
	wi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_child(wi)
	return true


## One chunk's flora: a "Flora" node under the chunk node holding one MultiMeshInstance3D per form
## (shared mesh and material). Attached the frame after the terrain and water, one chunk per frame.
func _attach_flora() -> bool:
	if _pending_flora.is_empty():
		return false
	var item = _pending_flora.pop_front()
	var coord: Vector2i = item[0]
	var mi: MeshInstance3D = _chunks.get(coord)
	if mi == null:
		return true  # the chunk was unloaded before its flora arrived
	var t0 := Time.get_ticks_usec()
	# Normally the worker's result; the sync_flora control places it HERE, on the main thread.
	var data: Dictionary = item[1] if item[1] != null else StalagFlora.build_chunk_flora(coord.x, coord.y)
	var root := Node3D.new()
	root.name = "Flora"
	var total := 0
	for id in data.keys():
		var a: Dictionary = flora_assets.get(id, {})
		if a.is_empty():
			continue
		var e: Dictionary = data[id]
		var buf: PackedFloat32Array = e["buffer"]
		if flora_y_offset != 0.0:
			for k in range(7, buf.size(), 12):  # origin.y of each 12-float transform row block
				buf[k] += flora_y_offset
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = a["mesh"]
		mm.instance_count = int(e["count"])
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.name = id
		mmi.multimesh = mm
		mmi.material_override = a["material"]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if a["casts"] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)
		total += int(e["count"])
	mi.add_child(root)
	_flora_counts[coord] = total
	flora_instances += total
	flora_adopt_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	flora_attached.emit(coord)
	return true


## One MultiMeshInstance3D per part under `root`. `buffer` is the transform buffer; the part with
## `colors` takes the 16-float crown buffer instead (transform plus instance colour).
func _add_part(root: Node3D, name: String, part: Dictionary, count: int, buffer: PackedFloat32Array) -> void:
	if int(part["cast"]) == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and not shadows_enabled:
		return  # a shadow-only proxy draws nothing but shadows: with shadows off it is not built
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = bool(part["colors"])
	mm.mesh = part["mesh"]
	mm.instance_count = count
	mm.buffer = buffer
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name
	mmi.multimesh = mm
	if part["material"] != null:
		mmi.material_override = part["material"]
	var cast: int = part["cast"]
	if not shadows_enabled and cast != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		cast = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.cast_shadow = cast
	mmi.set_meta("cast", int(part["cast"]))
	var rng: float = part["range_end"]
	if rng > 0.0:
		mmi.visibility_range_end = rng
	root.add_child(mmi)


func _lift(buf: PackedFloat32Array, stride: int, dy: float) -> void:
	for k in range(7, buf.size(), stride):  # origin.y of each instance's transform
		buf[k] += dy


## One chunk's trees: a "Trees" node under the chunk node holding, per form, a trunk MultiMesh, and
## for the living forms a crown MultiMesh and a shadow-only proxy MultiMesh (not built when shadows
## are off). Attached the frame after the flora, one chunk per frame.
func _attach_trees() -> bool:
	if _pending_trees.is_empty():
		return false
	var item = _pending_trees.pop_front()
	var coord: Vector2i = item[0]
	var mi: MeshInstance3D = _chunks.get(coord)
	if mi == null:
		return true  # the chunk was unloaded before its trees arrived
	var t0 := Time.get_ticks_usec()
	var data: Dictionary = item[1] if item[1] != null else StalagTrees.build_chunk_trees(coord.x, coord.y)
	if data.is_empty():  # a chunk without trees gets no node at all
		_tree_counts[coord] = 0
		trees_adopt_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		trees_attached.emit(coord)
		return true
	var root := Node3D.new()
	root.name = "Trees"
	var total := 0
	for id in data.keys():
		var a: Dictionary = tree_assets.get(id, {})
		if a.is_empty():
			continue
		var e: Dictionary = data[id]
		var n := int(e["count"])
		var buf: PackedFloat32Array = e["buffer"]
		if trees_y_offset != 0.0:
			_lift(buf, 12, trees_y_offset)
		_add_part(root, id + "_trunk", a["trunk"], n, buf)
		if a.has("crown"):
			var cbuf: PackedFloat32Array = e["crown_buffer"]
			if trees_y_offset != 0.0:
				_lift(cbuf, 16, trees_y_offset)
			_add_part(root, id + "_crown", a["crown"], n, cbuf)
			_add_part(root, id + "_shadow", a["shadow"], n, buf)
		total += n
	mi.add_child(root)
	_tree_counts[coord] = total
	tree_instances += total
	trees_adopt_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	trees_attached.emit(coord)
	return true


## One chunk's understory: an "Understory" node with one MultiMesh per shrub species and per flower
## species and tier. Attached the frame after the trees.
func _attach_understory() -> bool:
	if _pending_understory.is_empty():
		return false
	var item = _pending_understory.pop_front()
	var coord: Vector2i = item[0]
	var mi: MeshInstance3D = _chunks.get(coord)
	if mi == null:
		return true
	var t0 := Time.get_ticks_usec()
	var data: Dictionary = item[1] if item[1] != null else StalagUnderstory.build_chunk_understory(coord.x, coord.y)
	var root := Node3D.new()
	root.name = "Understory"
	var total := 0
	for key in data.keys():
		var a: Dictionary = understory_assets.get(key, {})
		if a.is_empty():
			continue
		var e: Dictionary = data[key]
		var buf: PackedFloat32Array = e["buffer"]
		if understory_y_offset != 0.0:
			_lift(buf, 12, understory_y_offset)
		_add_part(root, str(key).replace("/", "_"), a, int(e["count"]), buf)
		total += int(e["count"])
	mi.add_child(root)
	_understory_counts[coord] = total
	understory_instances += total
	understory_adopt_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	understory_attached.emit(coord)
	return true


## Turns the crown shadows on or off for every live chunk (trunks stop or resume casting, the
## shadow proxies are shown or hidden). New chunks follow `shadows_enabled`.
func set_shadows(on: bool) -> void:
	shadows_enabled = on
	for c in _chunks.keys():
		var root: Node = (_chunks[c] as MeshInstance3D).get_node_or_null("Trees")
		if root == null:
			continue
		for n in root.get_children():
			var m := n as MultiMeshInstance3D
			if m == null or not m.has_meta("cast"):
				continue
			var cast: int = m.get_meta("cast")
			if cast == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				continue
			m.cast_shadow = cast if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


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
	if flora_enabled and not flora_assets.is_empty():
		if sync_flora:
			_pending_flora.append([c, null])
		elif res.has("flora"):
			_pending_flora.append([c, res["flora"]])
	if trees_enabled and not tree_assets.is_empty():
		if sync_trees:
			_pending_trees.append([c, null])
		elif res.has("trees"):
			_pending_trees.append([c, res["trees"]])
	if understory_enabled and not understory_assets.is_empty():
		if sync_trees:
			_pending_understory.append([c, null])
		elif res.has("understory"):
			_pending_understory.append([c, res["understory"]])
	add_child(mi)
	_chunks[c] = mi
	stats["loads"] += 1
	chunk_loaded.emit(c)


func _unload_far() -> void:
	for c in _chunks.keys():
		if _chebyshev(c, _focus_chunk) > UNLOAD_RADIUS:
			var mi: MeshInstance3D = _chunks[c]
			_chunks.erase(c)
			flora_instances -= int(_flora_counts.get(c, 0))
			_flora_counts.erase(c)
			tree_instances -= int(_tree_counts.get(c, 0))
			_tree_counts.erase(c)
			understory_instances -= int(_understory_counts.get(c, 0))
			_understory_counts.erase(c)
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
	_pending_flora.clear()
	_pending_trees.clear()
	_pending_understory.clear()
	_flora_counts.clear()
	_tree_counts.clear()
	_understory_counts.clear()
	flora_instances = 0
	tree_instances = 0
	understory_instances = 0
	_mutex.lock()
	_done.clear()
	_mutex.unlock()
	for c in _chunks.keys():
		var mi: MeshInstance3D = _chunks[c]
		remove_child(mi)
		mi.free()
	_chunks.clear()
