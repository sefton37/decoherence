extends RefCounted
class_name HardwareReadout

## Reads THIS machine's real hardware facts at boot (Spec #371 / plan-371).
## No literal per-machine values ever live in this file or any other
## tracked source -- every value below comes from a live engine/OS call,
## never a hardcoded string (DOD-5/6/7 forbid this machine's exact CPU,
## GPU, and hostname strings appearing anywhere in tracked source). The
## returned Dictionary's keys are the exact `{TOKEN}` names
## data/boot_sequence.json's hardware_readout stage lines reference via
## String.format() -- boot_controller.gd applies that formatting.
##
## RenderingServer.get_video_adapter_name() returns EMPTY in a bare
## headless SceneTree context and only resolves once a real window/
## viewport exists (confirmed at spec-authoring time) -- callers must only
## rely on this in the real windowed boot scene, never the headless smoke
## test.

static func read_facts() -> Dictionary:
	var gpu := RenderingServer.get_video_adapter_name()
	var hostname := _read_hostname()
	var mem := OS.get_memory_info()
	var ram_gb := float(mem.get("physical", 0)) / (1024.0 * 1024.0 * 1024.0)
	return {
		"CPU": OS.get_processor_name(),
		"THREADS": str(OS.get_processor_count()),
		"RAM_GB": "%.1f" % ram_gb,
		"GPU": gpu if gpu != "" else "UNKNOWN",
		"HOSTNAME": hostname if hostname != "" else "UNKNOWN",
		"OS_KERNEL": OS.get_name(),
	}


## Reads /etc/hostname directly -- OS.get_environment("HOSTNAME") is
## confirmed EMPTY in this shell/session and must not be relied on as the
## sole mechanism (per spec #371 Implicit note).
static func _read_hostname() -> String:
	var f := FileAccess.open("/etc/hostname", FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text().strip_edges()
	f.close()
	return text
