extends Node
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 581 S1 stage probe: renders every preset in the avatar template on a plain stage from four angles
## (front, three-quarter, side, back) into one contact sheet, and the default preset's stride as a strip of
## eight phases seen from the side, on a REAL renderer. It MEASURES; the DoD's jq judges. The sheet is what
## the owner looks at to pick a preset (a one-line data edit); the numbers prove the sheet is not empty and
## that the presets are not the same picture.
##   covered_px    the pixels of a cell that differ from the same camera on an empty stage
##   min_pair_diff_frac  across preset pairs, the share of the front views' covered pixels that differ
##   strip min_adjacent_diff_frac  the same share between neighbouring stride phases
## MUTATION=hidden hides every body before every render: the same predicates must FAIL.
##
## Env: OUT_DIR (required), MUTATION (none | hidden)
## Writes sheet.json and contact_sheet.png and walk_strip.png (or the _hidden twins).

const AvatarBody := preload("res://game/avatar/avatar_body.gd")
const AvatarGait := preload("res://game/avatar/avatar_gait.gd")
const TEMPLATE_PATH := "res://game/avatar/avatar_template.json"

const CELL_W := 480
const CELL_H := 360
const SHEET_W := 1920
const SHEET_H := 1080
const STRIP_PHASES := 8
const PIX_TOL := 4
const VIEWS := ["front", "three_quarter", "side", "back"]
const VIEW_AZIMUTH_DEG := {"front": 0.0, "three_quarter": 35.0, "side": 90.0, "back": 180.0}
const CAM_DIST := 4.0
const CAM_Y := 0.9

var _mutation := "none"
var _out := ""
var _vp: SubViewport
var _cam: Camera3D
var _stage: Node3D
var _label: Label3D
var _body: Node3D
var _joints := {}


func _ready() -> void:
	_out = OS.get_environment("OUT_DIR")
	var m := OS.get_environment("MUTATION")
	_mutation = m if not m.is_empty() else "none"
	if _out.is_empty() or not (_mutation == "none" or _mutation == "hidden"):
		push_error("avatar_sheet: OUT_DIR is required and MUTATION must be none or hidden")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _stage_up() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(CELL_W, CELL_H)
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.20, 0.23, 0.28)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.64)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, 215.0, 0.0)  # shines toward the body's +Z side, so its front (-Z) is the lit one
	sun.light_energy = 1.0
	sun.shadow_enabled = false  # the shadow would run off the cell's edge and into the coverage count
	_vp.add_child(sun)
	_stage = Node3D.new()
	_vp.add_child(_stage)
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = 1.1
	floor_mesh.bottom_radius = 1.1
	floor_mesh.height = 0.02
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.17, 0.18, 0.20)
	floor_mat.roughness = 1.0
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = floor_mat
	floor_mi.position = Vector3(0.0, -0.01, 0.0)
	_stage.add_child(floor_mi)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.pixel_size = 0.0035
	_label.font_size = 48
	_label.outline_size = 8
	_label.position = Vector3(0.0, 1.84, 0.0)
	_stage.add_child(_label)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	_cam.current = true
	_vp.add_child(_cam)


func _point_camera(view_azimuth_deg: float) -> void:
	var az := deg_to_rad(view_azimuth_deg)
	# The body faces -Z; azimuth 0 puts the camera in front of it (on its -Z side), 90 on its +X side.
	_cam.position = Vector3(sin(az) * CAM_DIST, CAM_Y, -cos(az) * CAM_DIST)
	_cam.look_at(Vector3(0.0, CAM_Y, 0.0), Vector3.UP)


func _set_body(preset_id: String) -> void:
	if _body != null:
		_stage.remove_child(_body)
		_body.free()
	var tpl := AvatarBody.load_template(TEMPLATE_PATH)
	tpl["preset_id"] = preset_id
	_body = AvatarBody.build(tpl)
	_stage.add_child(_body)
	_joints = AvatarBody.joints(_body)
	_label.text = preset_id


func _render() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


## Renders the current camera with the body shown (unless the control hides it) and on the empty stage.
func _pair() -> Dictionary:
	_body.visible = _mutation != "hidden"
	var with_body := await _render()
	_body.visible = false
	var empty := await _render()
	_body.visible = _mutation != "hidden"
	return {"img": with_body, "empty": empty}


## The set of pixels that differ between two images (per-channel tolerance), as a byte mask.
static func _mask(a: Image, b: Image) -> PackedByteArray:
	var da := a.get_data()
	var db := b.get_data()
	var n := a.get_width() * a.get_height()
	var m := PackedByteArray()
	m.resize(n)
	for p in range(n):
		var i := p * 3
		if absi(da[i] - db[i]) > PIX_TOL or absi(da[i + 1] - db[i + 1]) > PIX_TOL or absi(da[i + 2] - db[i + 2]) > PIX_TOL:
			m[p] = 1
	return m


static func _count(m: PackedByteArray) -> int:
	var n := 0
	for v in m:
		n += v
	return n


## Of the pixels covered in either mask, the share where the two images (rendered with the same camera) differ.
static func _pair_diff(img_a: Image, mask_a: PackedByteArray, img_b: Image, mask_b: PackedByteArray) -> float:
	var da := img_a.get_data()
	var db := img_b.get_data()
	var uni := 0
	var diff := 0
	for p in range(mask_a.size()):
		if mask_a[p] != 0 or mask_b[p] != 0:
			uni += 1
			var i := p * 3
			if absi(da[i] - db[i]) > PIX_TOL or absi(da[i + 1] - db[i + 1]) > PIX_TOL or absi(da[i + 2] - db[i + 2]) > PIX_TOL:
				diff += 1
	return float(diff) / float(maxi(uni, 1))


## True when the covered pixels exist and none touches the cell's border.
static func _inside(m: PackedByteArray, w: int, h: int) -> bool:
	var any := false
	for y in range(h):
		for x in range(w):
			if m[y * w + x] != 0:
				any = true
				if x < 2 or y < 2 or x >= w - 2 or y >= h - 2:
					return false
	return any


static func _luma_mean(img: Image) -> float:
	var d := img.get_data()
	var s := 0.0
	var n := img.get_width() * img.get_height()
	for p in range(0, n, 2):
		var i := p * 3
		s += 0.2126 * float(d[i]) + 0.7152 * float(d[i + 1]) + 0.0722 * float(d[i + 2])
	return s / float(maxi(n / 2, 1)) / 255.0


func _run() -> void:
	_stage_up()
	await get_tree().process_frame
	var tpl := AvatarBody.load_template(TEMPLATE_PATH)
	var presets: Array = []
	for p in tpl["presets"]:
		presets.append(String(p["id"]))
	var sheet := Image.create(SHEET_W, SHEET_H, false, Image.FORMAT_RGB8)
	var order: Array = []
	var cells: Array = []
	var fronts: Array = []  # [image, mask] of every preset's front view
	for row in range(presets.size()):
		_set_body(presets[row])
		for col in range(VIEWS.size()):
			var view: String = VIEWS[col]
			_point_camera(VIEW_AZIMUTH_DEG[view])
			var pr := await _pair()
			var mask := _mask(pr["img"], pr["empty"])
			var covered := _count(mask)
			order.append("%s:%s" % [presets[row], view])
			cells.append({"preset": presets[row], "view": view, "in_viewport": _inside(mask, CELL_W, CELL_H),
				"covered_px": covered, "luma_mean": _luma_mean(pr["img"])})
			sheet.blit_rect(pr["img"], Rect2i(0, 0, CELL_W, CELL_H), Vector2i(col * CELL_W, row * CELL_H))
			if view == "front":
				fronts.append([pr["img"], mask])
	var min_pair := INF
	for i in range(fronts.size()):
		for j in range(i + 1, fronts.size()):
			min_pair = minf(min_pair, _pair_diff(fronts[i][0], fronts[i][1], fronts[j][0], fronts[j][1]))

	# The stride strip: the default preset, side view, eight phases of the cycle.
	var default_id := String(tpl["default_preset"])
	_set_body(default_id)
	_point_camera(VIEW_AZIMUTH_DEG["side"])
	var cfg := AvatarBody.gait_cfg(tpl, default_id)
	var strip := Image.create(STRIP_PHASES * (CELL_W / 2), CELL_H, false, Image.FORMAT_RGB8)
	var tiles: Array = []
	for k in range(STRIP_PHASES):
		var st := AvatarGait.initial_state()
		st["phase"] = float(k) / float(STRIP_PHASES)
		st["walk_amt"] = 1.0
		AvatarBody.apply_pose(_joints, AvatarGait.pose(st, cfg))
		var pr2 := await _pair()
		var crop := Rect2i(CELL_W / 4, 0, CELL_W / 2, CELL_H)
		var img_c: Image = (pr2["img"] as Image).get_region(crop)
		var emp_c: Image = (pr2["empty"] as Image).get_region(crop)
		tiles.append([img_c, _mask(img_c, emp_c)])
		strip.blit_rect(img_c, Rect2i(0, 0, CELL_W / 2, CELL_H), Vector2i(k * (CELL_W / 2), 0))
	var min_adj := INF
	for k in range(STRIP_PHASES):
		var nxt := (k + 1) % STRIP_PHASES
		min_adj = minf(min_adj, _pair_diff(tiles[k][0], tiles[k][1], tiles[nxt][0], tiles[nxt][1]))

	var tag := "" if _mutation == "none" else "_hidden"
	sheet.save_png(_out.path_join("contact_sheet%s.png" % tag))
	strip.save_png(_out.path_join("walk_strip%s.png" % tag))
	var rec := {
		"generated_epoch": int(Time.get_unix_time_from_system()),
		"mutation": _mutation,
		"headless": DisplayServer.get_name() == "headless",
		"preset_count": presets.size(),
		"default_preset": default_id,
		"sheet": {"w": sheet.get_width(), "h": sheet.get_height(), "order": order},
		"cells": cells,
		"distinct": {"min_pair_diff_frac": min_pair},
		"strip": {"w": strip.get_width(), "h": strip.get_height(), "phases": STRIP_PHASES, "min_adjacent_diff_frac": min_adj},
	}
	var f := FileAccess.open(_out.path_join("sheet.json" if _mutation == "none" else "sheet_hidden.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rec, "  "))
	f.close()
	print("avatar_sheet: wrote sheet records and images (", _mutation, ")")
	get_tree().quit(0)
