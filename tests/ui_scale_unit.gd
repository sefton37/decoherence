extends SceneTree

## Unit test for UiScale (Spec #541): the fullscreen content-scale rule.
## Run via tests/verify_ui_scale_unit.sh. Output contract (parsed by the DoD):
##   UISCALE_UNIT_OK <name>      one per passing case
##   UISCALE_UNIT_FAIL <name>    any failure (script exits 1)
##   UISCALE_NEGCTL_OK <name>    the table DOES catch a deliberately wrong rule

var _failed: int = 0


## (width, height, expected factor, case name)
const _TABLE := [
	[1280, 720, 1.0, "720p_stays_1"],
	[1920, 1080, 1.0, "1080p_is_1"],
	[800, 600, 1.0, "below_1080p_clamped_to_1"],
	[2560, 1440, 1.3333333, "1440p_fractional"],
	[3840, 2160, 2.0, "4k_is_2"],
	[6144, 3456, 3.2, "6k_monitor_is_3_2"],
	[3840, 1080, 1.0, "ultrawide_limited_by_height"],
	[1920, 2160, 1.0, "tall_limited_by_width"],
	[9600, 5400, 5.0, "exactly_at_cap"],
	[19200, 10800, 5.0, "capped_at_5"],
	[0, 0, 1.0, "degenerate_size_is_1"],
]


func _init() -> void:
	for row in _TABLE:
		var got: float = UiScale.factor_for(Vector2i(row[0], row[1]))
		if absf(got - float(row[2])) < 0.0001:
			print("UISCALE_UNIT_OK ", row[3])
		else:
			_fail(String(row[3]), "got %s want %s" % [got, row[2]])
	_check_spacing()
	_negctl()
	quit(1 if _failed > 0 else 0)


func _check_spacing() -> void:
	var ok := absf(UiScale.crt_spacing(1.0) - 4.0) < 0.0001 and absf(UiScale.crt_spacing(2.0) - 8.0) < 0.0001 \
		and absf(UiScale.crt_spacing(5.0) - 20.0) < 0.0001
	if ok:
		print("UISCALE_UNIT_OK crt_spacing_is_4_times_factor")
	else:
		_fail("crt_spacing_is_4_times_factor", "spacing drifted")


## A rule without the >=1 clamp and the cap must disagree with the table, or
## the table is not testing what it claims.
func _negctl() -> void:
	var wrong := 0
	for row in _TABLE:
		var naive := minf(float(row[0]) / 1920.0, float(row[1]) / 1080.0)
		if absf(naive - float(row[2])) >= 0.0001:
			wrong += 1
	if wrong >= 3:
		print("UISCALE_NEGCTL_OK naive_rule_rejected mismatches=%d" % wrong)
	else:
		_fail("negctl", "naive rule matched the table (%d mismatches)" % wrong)


func _fail(name: String, why: String) -> void:
	_failed += 1
	print("UISCALE_UNIT_FAIL ", name, ": ", why)
