extends RefCounted
class_name EntanglementReadout

## Reads THIS machine's real, fully-LOCAL "entanglement" facts at boot
## (Spec #373 / plan-373 SS5). Zero network egress -- every value below
## comes from a local engine/OS call (IP.get_local_addresses(),
## Time.get_time_zone_from_system(), Time.get_datetime_string_from_system(),
## OS.get_locale()), never a real network round trip and never a
## hardcoded per-machine literal (DOD-13/14 forbid this machine's exact
## Tailscale/LAN IPs and its IANA timezone name from appearing anywhere in
## tracked source). This is the mechanical proof of the spec's Option-A
## sovereignty decision: the "geolocate you in time and space" fiction is
## carried entirely by real LOCAL data, never an outbound GeoIP call.
##
## Honest degradation (mirrors hardware_readout.gd's existing "UNKNOWN"
## fallback convention exactly): a read that comes back empty renders
## "UNRESOLVED"/"UNKNOWN" rather than any fabricated value.
##
## The returned Dictionary's keys are the exact `{TOKEN}` names
## data/boot_sequence.json's entanglement_process stage lines reference via
## String.format() -- boot_controller.gd merges this into the same
## `_hw_facts` dictionary it already applies via .format(), exactly like
## HardwareReadout.read_facts() today.

static func read_facts() -> Dictionary:
	var ip := _pick_local_address(IP.get_local_addresses())
	var tz: Dictionary = Time.get_time_zone_from_system()
	var tz_name := String(tz.get("name", ""))
	var dt := Time.get_datetime_string_from_system()
	var locale := OS.get_locale()
	return {
		"IP_ADDR": ip,
		"TZ_NAME": tz_name if tz_name != "" else "UNKNOWN",
		"TZ_OFFSET": _format_offset(int(tz.get("bias", 0))),
		"LOCAL_DATETIME": dt if dt != "" else "UNRESOLVED",
		"LOCALE": locale if locale != "" else "UNKNOWN",
	}


## Filters IP.get_local_addresses() down to one narratable address ("filtered
## sensibly" per the spec's kickoff prompt). Always excludes loopback
## (127.x / ::1) and link-local (169.254.x / fe80::) -- never theater on a
## bare-loopback-only read. De-prioritizes (does not hard-exclude)
## Docker-bridge noise (172.x) so a real Tailscale/LAN address is preferred
## when one exists. Returns "UNRESOLVED" (never a fabricated IP-shaped
## string) if no non-loopback/non-link-local candidate remains.
static func _pick_local_address(addrs: PackedStringArray) -> String:
	var candidates: Array = []
	for a in addrs:
		var s := String(a)
		if s == "" or s.begins_with("127.") or s == "::1":
			continue
		if s.to_lower().begins_with("fe80:") or s.begins_with("169.254."):
			continue
		candidates.append(s)
	if candidates.is_empty():
		return "UNRESOLVED"
	for c in candidates:
		if not c.begins_with("172."):
			return c
	return candidates[0]


## Renders a signed-minutes UTC bias (Time.get_time_zone_from_system()'s
## "bias" field) as "+HH:MM"/"-HH:MM" -- never assumes a particular sign
## convention beyond what the engine itself returns.
static func _format_offset(bias_minutes: int) -> String:
	var sign_char := "+" if bias_minutes >= 0 else "-"
	var m: int = absi(bias_minutes)
	return "%s%02d:%02d" % [sign_char, m / 60, m % 60]
