extends Node
class_name LlmClient

## Spawns and owns a game-local `llama-server` (llama.cpp) child process
## (Spec #387) -- replaces the previous shared-daemon dependency, making
## Decoherence self-contained. Config (binary/model paths, host, port, ctx
## size, reasoning format) is read once from res://data/llm_config.json;
## every repo-relative path in that file is resolved to an absolute
## filesystem path via ProjectSettings.globalize_path() (valid because
## this ships via `godot --path <repo>`, never an exported build).
##
## Ctx size is passed to llama-server exactly once, via `-c` at spawn --
## send_chat() below never carries a per-request context-window override,
## structurally ruling out the shared-daemon-era trap where such an
## override was silently ignored by the server (project memory).
##
## Streaming (send_chat) uses the low-level HTTPClient, polled every frame
## via `await get_tree().process_frame` -- NOT Godot's higher-level
## whole-response-buffering HTTP request node, which cannot surface
## incremental deltas as they arrive.

## Emitted once check_model_ready() has resolved (success or exhausted
## retries) -- boot_controller.gd awaits this during the "gate":"model_ready"
## boot stage.
signal model_ready(success: bool)

const CONFIG_PATH := "res://data/llm_config.json"
const PID_FILE_NAME := "llm_server.pid"

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8085
const DEFAULT_CTX_SIZE := 8192
const DEFAULT_REASONING_FORMAT := "deepseek"

const READY_POLL_INTERVAL_SEC := 0.5
const READY_MAX_TRIES := 400

var _host: String = DEFAULT_HOST
var _port: int = DEFAULT_PORT
var _ctx_size: int = DEFAULT_CTX_SIZE
var _reasoning_format: String = DEFAULT_REASONING_FORMAT
var _server_binary_abs: String = ""
var _model_path_abs: String = ""

## PID of the llama-server process THIS node is tracking -- either
## freshly spawned this run, or adopted from a still-alive prior run's
## PID-file after _pid_is_llama_server() confirms it genuinely is a
## llama-server (OS.is_process_running() alone only proves the OS pid
## slot is occupied, not that it's still OUR server -- after PID reuse it
## could belong to a completely unrelated process by the time shutdown()
## runs).
var _server_pid: int = -1

## True only for the llama-server process THIS run actually spawned
## itself below -- never set for an adopted/already-running server.
## shutdown() below only ever calls OS.kill() when this is true:
## the game may only ever kill a server it spawned itself, never one it
## merely found alive and reused (Spec #387 Amendment 3 -- a stale
## PID-file trusted on OS.is_process_running() alone could, after PID
## reuse, adopt-and-later-kill a completely unrelated process).
var _owns_server: bool = false


## Reads and resolves data/llm_config.json. Safe to call more than once
## (idempotent) -- check_model_ready() calls it before doing anything else
## that depends on config values.
func _load_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	_host = String(parsed.get("host", DEFAULT_HOST))
	_port = int(parsed.get("port", DEFAULT_PORT))
	_ctx_size = int(parsed.get("ctx_size", DEFAULT_CTX_SIZE))
	_reasoning_format = String(parsed.get("reasoning_format", DEFAULT_REASONING_FORMAT))

	var rel_binary := String(parsed.get("server_binary", ""))
	var rel_model := String(parsed.get("model_path", ""))
	if not rel_binary.is_empty():
		_server_binary_abs = ProjectSettings.globalize_path("res://" + rel_binary)
	if not rel_model.is_empty():
		_model_path_abs = ProjectSettings.globalize_path("res://" + rel_model)


## Spawns (or adopts an already-running) llama-server, then polls /health
## until the boot gate can resolve. Honest crash/stale-orphan mitigation
## via a user://-scoped PID-file (llama-server has no parent-death-signal
## flag to lean on -- grounded: `llama-server --help` lists none) PLUS a
## system-wide reclaim pass (see _reclaim_stale_servers() below) for
## crash-orphans the PID-file mechanism alone cannot see (Spec #387
## Amendment 4).
func check_model_ready() -> void:
	# Narrow, test-only deterministic gate-force-fail hook (Spec #371 /
	# carried forward by Spec #387). Resolves synchronously (no await
	# before this point, and this is the first executable statement in
	# the function -- nothing that spawns the server appears earlier in
	# this file) so a force-fail run never even ticks the boot spinner
	# once and never spawns or touches the live llama-server process.
	if OS.get_environment("DECOHERENCE_FORCE_GATE_FAIL") == "1":
		model_ready.emit(false)
		return

	_load_config()
	await _reclaim_stale_servers()

	var already_running := false
	var existing_pid := _read_pid_file()

	if existing_pid > 0 and OS.is_process_running(existing_pid):
		if _pid_is_llama_server(existing_pid):
			# Case (a): a prior run's server is still alive AND verified
			# to genuinely be llama-server (not a PID the OS has since
			# reused for an unrelated process) -- adopt it, skip spawn,
			# go straight to /health polling. This session did not spawn
			# it, so _owns_server stays false: shutdown() must never
			# kill a process this session doesn't own.
			print("LLM_ALREADY_RUNNING")
			already_running = true
			_server_pid = existing_pid
		else:
			# The OS has reused this PID for an unrelated, innocent
			# process since the PID-file was written -- never adopt it
			# and never kill it. Drop the stale bookkeeping entry and
			# fall through to spawn our own (case d below).
			_delete_pid_file()
	elif existing_pid > 0:
		# Case (b): a PID-file whose recorded process is no longer alive
		# (or already reclaimed above) -- clean up the stale bookkeeping
		# entry and fall through to spawn (case d below). Does NOT print
		# LLM_ORPHAN_CLEANED: deleting a bookkeeping file is not the same
		# as verifiably killing an orphan process, and only
		# _reclaim_stale_servers() above has actually confirmed+killed
		# anything by this point (Amendment 4 marker-honesty fix).
		_delete_pid_file()
	else:
		# Case (c): no PID-file, but something is already answering
		# health on the configured host:port (unrelated process squatting
		# the port) -- never double-spawn onto it. We don't know its PID,
		# so it is never a shutdown() target.
		var probe_code := await _check_health()
		if probe_code == 200 or probe_code == 503:
			print("LLM_ALREADY_RUNNING")
			already_running = true

	if not already_running:
		# Case (d): spawn a fresh server, ctx_size passed exactly once via
		# -c at launch -- never per-request.
		var args := PackedStringArray([
			"-m", _model_path_abs,
			"--host", _host,
			"--port", str(_port),
			"-c", str(_ctx_size),
			"--reasoning-format", _reasoning_format,
			"--jinja",
		])
		var pid := OS.create_process(_server_binary_abs, args, false)
		if pid <= 0:
			model_ready.emit(false)
			return
		_server_pid = pid
		_owns_server = true
		_write_pid_file(pid)
		print("LLM_SPAWNED pid=%d" % pid)

	for _try_index in range(READY_MAX_TRIES):
		var code := await _check_health()
		if code == 200:
			model_ready.emit(true)
			return
		await get_tree().create_timer(READY_POLL_INTERVAL_SEC).timeout
	model_ready.emit(false)


## Streams a chat completion via /v1/chat/completions ("stream": true).
## SSE framing (`data: {...}` lines, terminal `data: [DONE]`) -- the
## server's own --reasoning-format deepseek + --jinja flags (set once at
## spawn) structurally separate delta.reasoning_content from delta.content
## in every streamed frame. Only delta.content ever reaches
## on_delta/on_done; delta.reasoning_content is read and intentionally
## discarded immediately below, never rendered, logged, or forwarded.
func send_chat(messages: Array, on_delta: Callable, on_done: Callable) -> void:
	var client := HTTPClient.new()
	var err := client.connect_to_host(_host, _port)
	if err != OK:
		on_done.call("")
		return
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		on_done.call("")
		return

	var body := JSON.stringify({
		"messages": messages,
		"stream": true,
	})
	var headers := PackedStringArray(["Content-Type: application/json"])
	err = client.request(HTTPClient.METHOD_POST, "/v1/chat/completions", headers, body)
	if err != OK:
		on_done.call("")
		return
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	var accumulated := ""
	var pending := ""
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			await get_tree().process_frame
			continue
		pending += chunk.get_string_from_utf8()
		# SSE: split on newlines, keep the last (possibly partial)
		# fragment buffered for the next tick.
		var split_lines := pending.split("\n")
		pending = split_lines[split_lines.size() - 1]
		for i in range(split_lines.size() - 1):
			var line := split_lines[i].strip_edges()
			if not line.begins_with("data:"):
				continue
			var payload := line.substr(5).strip_edges()
			if payload.is_empty():
				continue
			if payload == "[DONE]":
				on_done.call(accumulated)
				return
			var parsed = JSON.parse_string(payload)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
			var choices: Array = parsed.get("choices", [])
			for choice_variant in choices:
				if typeof(choice_variant) != TYPE_DICTIONARY:
					continue
				var choice: Dictionary = choice_variant
				var delta: Dictionary = choice.get("delta", {})
				# Read (and intentionally discard) reasoning_content --
				# never forwarded to on_delta/on_done. Only delta.content,
				# below, reaches the rendered/forwarded path.
				if delta.has("reasoning_content"):
					pass
				if delta.has("content"):
					var piece = delta["content"]
					if typeof(piece) == TYPE_STRING and piece != "":
						accumulated += piece
						on_delta.call(piece)
				if choice.get("finish_reason", null) != null:
					on_done.call(accumulated)
					return
	on_done.call(accumulated)


## Kills the llama-server process this node itself spawned this run --
## NEVER an adopted/already-running one, even though _server_pid may be
## set for those too (see _owns_server's own doc comment). Called from
## _exit_tree() below rather than an explicit call site -- probe_driver.gd
## (frozen) calls get_tree().quit() from several separate paths, none of
## which can call this node directly, so the kill mechanism must be a
## scene-tree lifecycle hook. Re-verifies identity via
## _pid_is_llama_server() immediately before the kill (Spec #387
## Amendment 5) -- _owns_server alone only proves THIS session spawned
## some process at _server_pid at the time; if that process died early
## and the OS reused the same pid for something else in the window before
## shutdown() runs, _owns_server would still be true for a pid that is no
## longer ours at all. A failed re-verification never kills; it only
## clears this node's own state honestly.
func shutdown() -> void:
	if _owns_server and _server_pid > 0:
		if _pid_is_llama_server(_server_pid):
			OS.kill(_server_pid)
	_server_pid = -1
	_owns_server = false
	_delete_pid_file()


func _exit_tree() -> void:
	shutdown()


## Issues a single GET /health request over a fresh low-level HTTPClient
## and returns the HTTP status code, or -1 if the connection could not be
## made at all. Per llama.cpp's own documented behavior (grounded live):
## connection-refused (-1 here) means the listen socket hasn't opened yet
## (still loading); 503 means "Loading model"; 200 means ready. Callers
## must treat -1 and 503 identically (still loading), never as a hard
## failure.
func _check_health() -> int:
	var client := HTTPClient.new()
	if client.connect_to_host(_host, _port) != OK:
		return -1
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return -1
	if client.request(HTTPClient.METHOD_GET, "/health", PackedStringArray()) != OK:
		return -1
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame
	var status := client.get_status()
	if status != HTTPClient.STATUS_BODY and status != HTTPClient.STATUS_CONNECTED:
		return -1
	var code := client.get_response_code()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		client.read_response_body_chunk()
		await get_tree().process_frame
	return code


## Reads /proc/<pid>/cmdline as a raw NUL-split argv array, or an empty
## array if the pid is dead/inaccessible -- shared by BOTH identity sites
## below (_pid_is_llama_server() and the reclaim scan in
## _reclaim_stale_servers()). Spec #387 Amendment 5 replaces the prior
## NUL-to-space-joined substring approach: a harmless process whose own
## ARGUMENT TEXT happened to contain both needle substrings ("llama-server"
## and "--port <port>") could satisfy a joined-text search without
## genuinely being llama-server (verified live). No joined-text/substring
## matching remains anywhere in this file -- every argv entry below is
## kept as its own exact array element, split at the real NUL boundaries
## /proc/<pid>/cmdline uses between arguments.
func _cmdline_argv(pid: int) -> PackedStringArray:
	var f := FileAccess.open("/proc/%d/cmdline" % pid, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var argv := PackedStringArray()
	var current := PackedByteArray()
	while true:
		var byte := f.get_8()
		if f.eof_reached():
			break
		if byte == 0:
			if not current.is_empty():
				argv.append(current.get_string_from_utf8())
			current = PackedByteArray()
		else:
			current.append(byte)
	f.close()
	if not current.is_empty():
		argv.append(current.get_string_from_utf8())
	return argv


## The identity rule itself, shared by both call sites: argv[0]'s basename
## must be EXACTLY "llama-server" (get_file() strips any directory prefix;
## never a substring/text match of some unrelated argument), AND an
## adjacent "--port" / "<this session's configured port>" token pair must
## appear somewhere in argv as two separate, exact elements -- never a
## substring of a joined string. A process whose own argument TEXT merely
## contains these words (e.g. a log-watching command quoting them) fails
## both conditions and is never touched.
func _argv_matches_llama_server(argv: PackedStringArray) -> bool:
	if argv.is_empty():
		return false
	if argv[0].get_file() != "llama-server":
		return false
	var port_str := str(_port)
	for i in range(argv.size() - 1):
		if argv[i] == "--port" and argv[i + 1] == port_str:
			return true
	return false


## Verifies that `pid` genuinely IS a llama-server process bound to this
## session's configured port before this node ever adopts, or (re-verified
## again in shutdown() below) kills, it -- reads /proc/<pid>/cmdline
## directly rather than trusting the PID-file's bookkeeping +
## OS.is_process_running() alone, which only proves the OS pid slot is
## occupied, not that it's still the same process the PID-file was
## written for (PID reuse hazard, Spec #387 Amendment 3; identity-precision
## hazard, Amendment 5 -- see _argv_matches_llama_server()'s own comment).
func _pid_is_llama_server(pid: int) -> bool:
	return _argv_matches_llama_server(_cmdline_argv(pid))


## Reclaim pass for crash-orphaned llama-server processes this game's own
## lineage left behind after an ungraceful prior exit -- runs from
## check_model_ready() after the force-fail short-circuit and before any
## spawn/PID-file logic there (Spec #387 Amendment 4). OS.is_process_running()
## on this Godot build has CHILD-ONLY semantics (verified live): it
## returns false for any genuinely-alive pid this process instance did
## not itself spawn, so the PID-file-based adopt/cleanup logic below can
## never detect a real crash-orphan left by a PRIOR game session -- only
## a system-wide /proc scan by process IDENTITY can. Scans every numeric
## /proc entry; only a pid whose real argv satisfies
## _argv_matches_llama_server() (never a joined-text/substring match --
## Amendment 5) is unambiguously this game's own lineage. Only a verified
## match is killed, and only a bounded wait that actually CONFIRMS the pid
## is gone (polling /proc/<pid> disappearing, never trusting
## OS.is_process_running on a pid we did not spawn) earns the
## LLM_ORPHAN_CLEANED marker -- a wait that times out prints a distinct,
## honest failure line instead and drops any stale PID-file bookkeeping,
## so the existing honest port-bound path (case c below, LLM_ALREADY_RUNNING)
## handles it rather than a doomed blind respawn onto a still-held port.
func _reclaim_stale_servers() -> void:
	var dir := DirAccess.open("/proc")
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.is_valid_int():
			var pid := entry.to_int()
			if pid != OS.get_process_id():
				var argv := _cmdline_argv(pid)
				if _argv_matches_llama_server(argv):
					OS.kill(pid)
					var tries := 0
					var confirmed_gone := false
					while tries < 50:
						if not FileAccess.file_exists("/proc/%d/cmdline" % pid):
							confirmed_gone = true
							break
						await get_tree().create_timer(0.1).timeout
						tries += 1
					if confirmed_gone:
						print("LLM_ORPHAN_CLEANED")
					else:
						print("LLM_ORPHAN_RECLAIM_FAILED pid=%d" % pid)
						_delete_pid_file()
		entry = dir.get_next()
	dir.list_dir_end()


## Reads the PID recorded from a prior run, or -1 if the file is absent or
## unreadable. Stored under user:// (Godot's per-user runtime-data path),
## deliberately NOT under the repo's gitignored llm/ dir -- a PID-file is
## runtime state, not a portable artifact.
func _read_pid_file() -> int:
	var dir := DirAccess.open("user://")
	if dir == null or not dir.file_exists(PID_FILE_NAME):
		return -1
	var f := FileAccess.open("user://" + PID_FILE_NAME, FileAccess.READ)
	if f == null:
		return -1
	var text := f.get_as_text().strip_edges()
	f.close()
	if not text.is_valid_int():
		return -1
	return text.to_int()


func _write_pid_file(pid: int) -> void:
	var f := FileAccess.open("user://" + PID_FILE_NAME, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(str(pid))
	f.close()


func _delete_pid_file() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(PID_FILE_NAME):
		dir.remove(PID_FILE_NAME)
