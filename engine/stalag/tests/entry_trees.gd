extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #549 -- the real-entry measurement for the forest, the understory and the crown shadows.
## Called by frontdoor/scripts/probe_driver.gd (world mode) inside the REAL app: the player's own
## entry, through the shell, with the CRT overlay. It reads what the renderer holds (chunk meshes,
## MultiMesh instances, the live camera) and captures frames through the same viewport the player
## sees. Frozen Stalag prototype (tag prototype-final) is the reference: the counts it prints are
## compared by tests/verify_world_entry.sh against tools/baseline/js_trees_oracle.mjs --view-count.
##
## Prints one line:  PROBE_WORLD_TREES {mutation, resolution, pose, trees, flowers, shrubs, meadow,
##                                       shadow, pixels, files}
## Mutations (env ENTRY_TREES_MUTATE): none, hidden_at_entry, unbuilt_at_entry,
## understory_hidden_at_entry, shadows_off_at_entry. They act BEFORE the saved entry shot, so the
## on-disk entry_world.png is the mutated frame (the data keeps saying "trees", the pixels say none).

const MeshRay := preload("res://engine/stalag/tests/mesh_ray.gd")
const PIX_TOL := 4  # per-channel difference (0..255) that counts as a changed pixel
const NEAR := 0.05


static func _roots(w: Node, name: String) -> Array:
	var out: Array = []
	var streamer: Node3D = w.get_node("Streamer")
	for c in streamer.chunk_coords():
		var n: Node = streamer.chunk_node(c).get_node_or_null(name)
		if n != null:
			out.append(n)
	return out


## Before the entry shot: freeze the shared wind clock (so frames differ only by what is toggled)
## and apply the at-entry negative controls.
static func prepare(w: Node, mutation: String) -> void:
	w.flora_clock_frozen = true
	var streamer: Node3D = w.get_node("Streamer")
	if mutation == "hidden_at_entry":
		for r in _roots(w, "Trees"):
			r.visible = false
	elif mutation == "unbuilt_at_entry":
		for r in _roots(w, "Trees"):
			r.get_parent().remove_child(r)
			r.free()
	elif mutation == "understory_hidden_at_entry":
		for r in _roots(w, "Understory"):
			r.visible = false
	elif mutation == "shadows_off_at_entry":
		streamer.set_shadows(false)


static func _frame(w: Node) -> Image:
	await w.get_tree().process_frame
	await w.get_tree().process_frame
	var img := w.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


# {frac, dist, darker, luma_drop}: share of ALL pixels that differ by more than PIX_TOL in any channel;
# the mean colour distance and the share (and mean luma loss) of those where `a` is darker than `b`.
static func _diff(a: Image, b: Image) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var n := a.get_width() * a.get_height()
	var changed := 0
	var dist_sum := 0.0
	var darker := 0
	var luma_sum := 0.0
	for p in range(n):
		var i := p * 3
		var dr := absi(da[i] - db[i])
		var dg := absi(da[i + 1] - db[i + 1])
		var dbb := absi(da[i + 2] - db[i + 2])
		if dr > PIX_TOL or dg > PIX_TOL or dbb > PIX_TOL:
			changed += 1
			dist_sum += sqrt(float(dr * dr + dg * dg + dbb * dbb))
			var la := 0.2126 * da[i] + 0.7152 * da[i + 1] + 0.0722 * da[i + 2]
			var lb := 0.2126 * db[i] + 0.7152 * db[i + 1] + 0.0722 * db[i + 2]
			if la < lb:
				darker += 1
			luma_sum += lb - la
	return {
		"frac": float(changed) / float(maxi(n, 1)),
		"dist": dist_sum / float(maxi(changed, 1)),
		"darker": float(darker) / float(maxi(changed, 1)),
		"luma_drop": luma_sum / float(maxi(changed, 1)),
	}


# What the chunk meshes hold: the triangle soup of every chunk's terrain surfaces, as a MeshRay.
static func _mesh_ray(w: Node) -> MeshRay:
	var streamer: Node3D = w.get_node("Streamer")
	var ray := MeshRay.new(StalagWorld.get_chunk_m())
	for c in streamer.chunk_coords():
		var mi: MeshInstance3D = streamer.chunk_node(c)
		var soup := PackedVector3Array()
		var mesh: ArrayMesh = mi.mesh
		for s in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx = arrays[Mesh.ARRAY_INDEX]
			if idx != null and (idx as PackedInt32Array).size() > 0:
				for k in (idx as PackedInt32Array):
					soup.append(v[k])
			else:
				soup.append_array(v)
		ray.add_chunk(c, soup)
	return ray


# every root origin of a class, in world metres: [[x, y, z, form id], ...]
static func _instances(w: Node, root_name: String, keep: Callable) -> Array:
	var out: Array = []
	var streamer: Node3D = w.get_node("Streamer")
	for c in streamer.chunk_coords():
		var mi: MeshInstance3D = streamer.chunk_node(c)
		var root: Node = mi.get_node_or_null(root_name)
		if root == null:
			continue
		for n in root.get_children():
			var m := n as MultiMeshInstance3D
			if m == null:
				continue
			var nm := String(m.name)
			if not keep.call(nm):
				continue
			var form := nm.rsplit("_", true, 1)[0]  # Godot node names cannot hold a dot: "<form>_<part>"
			var mm := m.multimesh
			for i in range(mm.instance_count):
				var o := mm.get_instance_transform(i).origin
				out.append([mi.position.x + o.x, mi.position.y + o.y, mi.position.z + o.z, form])
	return out


# Counts for one class from the live camera. `marker` is the height above the root of the point that
# stands for the instance. All arithmetic is in doubles (GDScript floats), the pose being the one
# printed, so tools/baseline/js_trees_oracle.mjs --view-count reproduces it from the pose alone.
static func _view(items: Array, marker: float, pose: Dictionary, ray: MeshRay) -> Dictionary:
	var cam: Array = pose["cam"]
	var fwd: Array = pose["fwd"]
	var th := tan(deg_to_rad(float(pose["fov_deg"])) / 2.0)
	var asp: float = pose["aspect"]
	# right = fwd x up(0,1,0), up' = right x fwd
	var rx: float = fwd[1] * 0.0 - fwd[2] * 1.0
	var ry: float = fwd[2] * 0.0 - fwd[0] * 0.0
	var rz: float = fwd[0] * 1.0 - fwd[1] * 0.0
	var rl := sqrt(rx * rx + ry * ry + rz * rz)
	rx /= rl
	ry /= rl
	rz /= rl
	var ux: float = ry * fwd[2] - rz * fwd[1]
	var uy: float = rz * fwd[0] - rx * fwd[2]
	var uz: float = rx * fwd[1] - ry * fwd[0]
	var in_f := 0
	var w30 := 0
	var unocc := 0
	var nearest := INF
	var forms := {}
	for it in items:
		nearest = minf(nearest, sqrt(it[0] * it[0] + it[2] * it[2]))
		var px: float = it[0] - cam[0]
		var py: float = it[1] + marker - cam[1]
		var pz: float = it[2] - cam[2]
		var z: float = px * fwd[0] + py * fwd[1] + pz * fwd[2]
		if z <= NEAR:
			continue
		var x: float = px * rx + py * ry + pz * rz
		var y: float = px * ux + py * uy + pz * uz
		if absf(x) > z * th * asp or absf(y) > z * th:
			continue
		in_f += 1
		forms[it[3]] = true
		var dist := sqrt(px * px + py * py + pz * pz)
		if dist <= 30.0:
			w30 += 1
		# straight segment from the camera to the marker, sampled every 0.5 m (the samples strictly between
		# the two ends); occluded if any sample is below the highest mesh surface there minus 5 cm
		var occluded := false
		var steps := int(dist / 0.5)
		for s in range(1, steps):
			var t := float(s) * 0.5 / dist
			var sx: float = cam[0] + px * t
			var sy: float = cam[1] + py * t
			var sz: float = cam[2] + pz * t
			var h := ray.height_at(sx, sz, 1000.0)
			if not is_nan(h) and sy < h - 0.05:
				occluded = true
				break
		if not occluded:
			unocc += 1
	return {"instances_total": items.size(), "in_frustum": in_f, "within_30m": w30, "unoccluded": unocc,
		"forms_in_view": forms.size(), "nearest_root_m": nearest if nearest != INF else -1.0}


static func _set_visible(w: Node, root_name: String, prefix: String, on: bool) -> void:
	for r in _roots(w, root_name):
		for n in r.get_children():
			if prefix.is_empty() or String(n.name).begins_with(prefix):
				n.visible = on


static func _hide_class(w: Node, cls: String, on: bool) -> void:
	if cls == "trees":
		for r in _roots(w, "Trees"):
			r.visible = on
	elif cls == "flowers":
		_set_visible(w, "Understory", "flower-", on)
	elif cls == "shrubs":
		for r in _roots(w, "Understory"):
			for n in r.get_children():
				var s := String(n.name)
				if s.begins_with("t1-") or s.begins_with("t2-") or s.begins_with("t3-"):
					n.visible = on


static func _casters(w: Node) -> int:
	var n := 0
	for r in _roots(w, "Trees"):
		for m in r.get_children():
			if m is MultiMeshInstance3D and (m as MultiMeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				n += 1
	return n


## After the entry shot was saved: measure and print the PROBE_WORLD_TREES line. Returns the record.
static func measure(w: Node, saved_path: String, shots_dir: String, mutation: String) -> Dictionary:
	var streamer: Node3D = w.get_node("Streamer")
	var camn: Camera3D = w.get_viewport().get_camera_3d()
	var size := w.get_viewport().get_visible_rect().size
	var fwd3 := -camn.global_transform.basis.z
	var pose := {
		"cam": [camn.global_position.x, camn.global_position.y, camn.global_position.z],
		"fwd": [fwd3.x, fwd3.y, fwd3.z],
		"fov_deg": camn.fov,
		"aspect": size.x / size.y,
	}
	var ray := _mesh_ray(w)
	var rec := {"mutation": mutation, "resolution": {"w": int(size.x), "h": int(size.y)}, "pose": pose}
	rec["trees"] = _view(_instances(w, "Trees", func(n: String) -> bool: return n.ends_with("_trunk")), 3.0, pose, ray)
	rec["flowers"] = _view(_instances(w, "Understory", func(n: String) -> bool: return n.begins_with("flower-")), 0.5, pose, ray)
	rec["shrubs"] = _view(_instances(w, "Understory", func(n: String) -> bool: return not n.begins_with("flower-")), 0.5, pose, ray)
	var meadow := 0
	for c in streamer.chunk_coords():
		var fl: Node = streamer.chunk_node(c).get_node_or_null("Flora")
		if fl == null:
			continue
		for m in fl.get_children():
			if m is MultiMeshInstance3D:
				meadow += (m as MultiMeshInstance3D).multimesh.instance_count
	rec["meadow"] = {"instances_total": meadow}

	# frames: A as the player sees it (mutations included), B trees hidden, C hidden again, D shown again
	var a := await _frame(w)
	_hide_class(w, "trees", false)
	var b := await _frame(w)
	var c := await _frame(w)
	_hide_class(w, "trees", true)
	var d := await _frame(w)
	var saved := Image.load_from_file(saved_path)
	saved.convert(Image.FORMAT_RGB8)
	var d_ab := _diff(a, b)
	var d_bc := _diff(b, c)
	var d_ad := _diff(a, d)
	var d_sb := _diff(saved, b)
	var hidden_path := shots_dir.path_join("entry_world_trees_hidden.png")
	b.save_png(hidden_path)
	# the understory classes: hide each in turn
	_hide_class(w, "flowers", false)
	var f_img := await _frame(w)
	_hide_class(w, "flowers", true)
	_hide_class(w, "shrubs", false)
	var s_img := await _frame(w)
	_hide_class(w, "shrubs", true)
	var d_fl := _diff(a, f_img)
	var d_sh := _diff(a, s_img)
	# crown shadows: A everything on, S the tree casters off, S2 a frame later still off
	var casters_on := _casters(w)
	streamer.set_shadows(false)
	var casters_left := _casters(w)
	var s1 := await _frame(w)
	var s2 := await _frame(w)
	streamer.set_shadows(true)
	var d_as := _diff(a, s1)
	var d_ss := _diff(s1, s2)
	var d_saved_s := _diff(saved, s1)
	rec["shadow"] = {
		"casters_off_resolution_ok": casters_left == 0,
		"diff_frac": d_as["frac"], "darker_frac": d_as["darker"], "mean_luma_drop": d_as["luma_drop"],
		"noise_floor_frac": d_ss["frac"], "saved_shot_diff_frac": d_saved_s["frac"], "caster_mmis": casters_on,
	}
	rec["pixels"] = {
		"diff_frac": d_ab["frac"], "mean_rgb_dist": d_ab["dist"], "noise_floor_frac": d_bc["frac"],
		"saved_shot_diff_frac": d_sb["frac"], "restore_frac": d_ad["frac"],
		"flower_diff_frac": d_fl["frac"], "shrub_diff_frac": d_sh["frac"],
	}
	rec["files"] = {"shot": saved_path, "hidden_shot": hidden_path}
	print("PROBE_WORLD_TREES " + JSON.stringify(rec))
	return rec
