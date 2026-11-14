extends RefCounted
## SPDX-License-Identifier: AGPL-3.0-only
## Spec 581 S1 -- the avatar's gait: a pure function from measured ground distance to joint angles.
## Provenance: procedural and self-made; a two-bone inverse-kinematics walk written for this project from
## the law of cosines. No imported clip, no ported animation code, no third-party data.
##
## No node, no input, no clock and no random number appears here. The phase advances by the DISTANCE the
## body actually travelled divided by the stride length, only while grounded, so a body pushing into a wall
## or frozen by a probe does not run on the spot, and a planted foot does not slide: the stance foot is
## placed so its ground-frame position is constant (it moves backwards under the body at exactly the body's
## own speed). The swing foot is lifted and carried forward to where the next step lands.
##
## Vocabulary (all in the body's sagittal plane, forward is the body's front):
##   hip angle    thigh swing from straight down, forward positive (radians)
##   knee flex    shin bend backwards from the thigh, never negative (radians)
##   ankle        counter-rotation that keeps the sole level
## `cfg` is the flat dictionary built by AvatarBody.gait_cfg: the template's gait block plus the leg geometry
## (leg_l1, leg_l2, ankle_height_m, hip_y).


## A fresh state: standing, breath at the start of its cycle.
static func initial_state() -> Dictionary:
	return {
		"phase": 0.0,  # position in the cycle, 0..1 (left foot lands at 0, right foot at 0.5)
		"phase_total": 0.0,  # the same, unwrapped (the unit harness reads its increments)
		"walk_amt": 0.0,  # 0 standing .. 1 full stride
		"run_blend": 0.0,  # 0 walk stride .. 1 run stride
		"air_amt": 0.0,  # 0 on the ground .. 1 held airborne pose
		"breath_t": 0.0,  # seconds of accumulated frame time, drives the breath and the vitals pulse
		"stride": 1.0,  # the stride length (m) in force on the last step
		"dphase": 0.0,  # the phase increment of the last step
	}


static func _approach(v: float, target: float, max_delta: float) -> float:
	if v < target:
		return minf(v + max_delta, target)
	return maxf(v - max_delta, target)


static func _smooth(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## The stride length (m) for a run blend: walk stride at 0, run stride at 1.
static func stride_for(cfg: Dictionary, run_blend: float) -> float:
	return lerpf(float(cfg["stride_len_m"]), float(cfg["run_stride_len_m"]), run_blend)


## Advances the state by one frame of `dt` seconds in which the body moved `distance_xz` metres along the
## ground. Changes the dictionary in place and returns it.
static func step(state: Dictionary, cfg: Dictionary, distance_xz: float, dt: float, grounded: bool) -> Dictionary:
	state["dphase"] = 0.0
	if dt <= 0.0:
		return state
	var speed := distance_xz / dt
	state["breath_t"] = float(state["breath_t"]) + dt
	# Stride blend: toward the run stride as the measured speed passes the run threshold. Rate limited so
	# the stance foot never jumps when the stride changes under it.
	var run_target := _smooth(float(cfg["walk_speed_ref_mps"]), float(cfg["run_speed_ref_mps"]), speed)
	if grounded and speed > float(cfg["min_speed_mps"]):
		state["run_blend"] = _approach(float(state["run_blend"]), run_target, dt / 0.2)
	elif speed <= float(cfg["min_speed_mps"]):
		state["run_blend"] = _approach(float(state["run_blend"]), 0.0, dt / 0.4)
	var stride := stride_for(cfg, float(state["run_blend"]))
	state["stride"] = stride
	if grounded:
		state["air_amt"] = _approach(float(state["air_amt"]), 0.0, dt / float(cfg["air_out_s"]))
		if distance_xz > 0.0 and speed > float(cfg["min_speed_mps"]):
			var dp := distance_xz / stride
			state["dphase"] = dp
			state["phase_total"] = float(state["phase_total"]) + dp
			state["phase"] = fposmod(float(state["phase"]) + dp, 1.0)
			state["walk_amt"] = _approach(float(state["walk_amt"]), 1.0, dt / float(cfg["walk_in_s"]))
		else:
			state["walk_amt"] = _approach(float(state["walk_amt"]), 0.0, dt / float(cfg["stop_settle_s"]))
	else:
		state["air_amt"] = _approach(float(state["air_amt"]), 1.0, dt / float(cfg["air_in_s"]))
	return state


## Hip angle and knee flex that put the ankle at (fwd, ty) relative to the hip (ty is negative below it).
## The target is pulled inside the leg's reach, so the result is always finite.
static func ik(fwd: float, ty: float, l1: float, l2: float) -> Vector2:
	var d := sqrt(fwd * fwd + ty * ty)
	d = clampf(d, absf(l1 - l2) + 0.001, (l1 + l2) * 0.9995)
	var delta := atan2(fwd, -ty)
	var eps := acos(clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0))
	var gamma := acos(clampf((l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2), -1.0, 1.0))
	return Vector2(delta + eps, PI - gamma)


## The joint targets for the current state. Keys: pelvis_y (hip joint height above the soles' ground),
## hip_l hip_r knee_l knee_r ankle_l ankle_r, arm_l arm_r elbow_l elbow_r, lean (forward positive), twist,
## breath_y (chest rise), pulse (0..1, the vitals light's slow pulse).
static func pose(state: Dictionary, cfg: Dictionary) -> Dictionary:
	var l1 := float(cfg["leg_l1"])
	var l2 := float(cfg["leg_l2"])
	var ah := float(cfg["ankle_height_m"])
	var hip_y := float(cfg["hip_y"])
	var run := float(state["run_blend"])
	var w := float(state["walk_amt"])
	var air := float(state["air_amt"])
	var stride := stride_for(cfg, run)
	var a := stride * 0.25  # the stance foot travels from +a to -a under the body
	var reach := (l1 + l2) * float(cfg["reach_frac"])
	var swing := lerpf(float(cfg["hip_swing_rad"]), float(cfg["run_hip_swing_rad"]), run)
	# Hip-to-ankle height at the stride extremes (where the legs are most spread) and at mid-stance.
	var ey := minf(a / tan(swing), sqrt(maxf(reach * reach - a * a, 0.0001)))
	var bob := lerpf(float(cfg["walk_bob_m"]), float(cfg["run_bob_m"]), run)
	var ey_mid := minf(ey + bob, reach)
	var lift := lerpf(float(cfg["lift_m"]), float(cfg["run_lift_m"]), run)

	var ph := float(state["phase"])
	var left_stance := ph < 0.5
	var u := fposmod(ph, 0.5) * 2.0  # progress through the stance of the planted foot (and the swing of the other)
	var ey_now := ey + (ey_mid - ey) * sin(PI * u)
	var pelvis_walk := ah + ey_now
	var stance_fwd := a - 2.0 * a * u
	var sw := 0.6 * _smooth(0.0, 1.0, u) + 0.4 * u  # eased, but not so much that the legs stop mirroring each other
	var swing_fwd := -a + 2.0 * a * sw
	var swing_ankle_y := ah + lift * sin(PI * u)  # ankle height above the ground
	var fwd_l := stance_fwd if left_stance else swing_fwd
	var fwd_r := swing_fwd if left_stance else stance_fwd
	var ay_l := ah if left_stance else swing_ankle_y
	var ay_r := swing_ankle_y if left_stance else ah

	# Blend the TARGETS (not the angles) between standing and striding, so a foot on the ground stays on it.
	var pelvis := lerpf(hip_y, pelvis_walk, w)
	var tl_f := fwd_l * w
	var tr_f := fwd_r * w
	var tl_y := lerpf(ah, ay_l, w)
	var tr_y := lerpf(ah, ay_r, w)
	# Airborne: a fixed pose (one leg forward and a little up, the other tucked behind), no cycle.
	if air > 0.0:
		tl_f = lerpf(tl_f, float(cfg["air_lead_fwd_m"]), air)
		tr_f = lerpf(tr_f, float(cfg["air_trail_fwd_m"]), air)
		tl_y = lerpf(tl_y, ah + float(cfg["air_lead_up_m"]), air)
		tr_y = lerpf(tr_y, ah + float(cfg["air_trail_up_m"]), air)
		pelvis = lerpf(pelvis, hip_y, air)
	var kl := ik(tl_f, tl_y - pelvis, l1, l2)
	var kr := ik(tr_f, tr_y - pelvis, l1, l2)

	# Arms swing against the same-side leg; the shoulders twist against the hips.
	var arm_amp := lerpf(float(cfg["arm_swing_rad"]), float(cfg["run_arm_swing_rad"]), run)
	var norm_l := clampf(fwd_l / a, -1.0, 1.0)
	var norm_r := clampf(fwd_r / a, -1.0, 1.0)
	var arm_l := -arm_amp * norm_l * w
	var arm_r := -arm_amp * norm_r * w
	var elbow := float(cfg["elbow_rest_rad"]) + w * (lerpf(float(cfg["elbow_walk_rad"]), float(cfg["elbow_run_rad"]), run) - float(cfg["elbow_rest_rad"]))
	var air_arm := float(cfg["air_arm_rad"])
	arm_l = lerpf(arm_l, air_arm, air)
	arm_r = lerpf(arm_r, air_arm, air)
	elbow = lerpf(elbow, float(cfg["elbow_walk_rad"]), air)
	var lean := w * lerpf(float(cfg["lean_walk_rad"]), float(cfg["lean_run_rad"]), run)
	var twist := float(cfg["twist_rad"]) * (norm_l - norm_r) * 0.5 * w * (1.0 - air)
	# Breath and vitals pulse come from the accumulated frame time, fading out while striding or airborne.
	var bt := float(state["breath_t"])
	var calm := (1.0 - w) * (1.0 - air)
	var breath := float(cfg["idle_breath_amp_m"]) * sin(TAU * bt / float(cfg["breath_period_s"])) * calm
	var pulse := 0.5 + 0.5 * sin(TAU * bt / float(cfg["pulse_period_s"]))
	return {
		"pelvis_y": pelvis,
		"hip_l": kl.x, "hip_r": kr.x,
		"knee_l": kl.y, "knee_r": kr.y,
		"ankle_l": -(kl.x - kl.y), "ankle_r": -(kr.x - kr.y),
		"arm_l": arm_l, "arm_r": arm_r,
		"elbow_l": elbow, "elbow_r": elbow,
		"lean": lean, "twist": twist,
		"breath_y": breath, "pulse": pulse,
	}
