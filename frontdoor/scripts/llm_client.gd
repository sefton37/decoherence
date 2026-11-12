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
	_cfg = parsed

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
		_forced_fail = true
		model_ready.emit(false)
		return

	_load_config()
	_source = resolve_source(_cfg, OS.get_environment("DECOHERENCE_LLM_SOURCE"))
	_source_resolved = true
	if _source != SOURCE_OWNED:
		# Spec #519 A1: the development substrate is the house Ollama. No
		# spawn, no pid file, no contact with the owned-mode port.
		await _check_ollama_ready()
		return
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


## --- Stream-side think filter (Spec #562 D12, issue #615) ----------------------------
## A model can put its reasoning in the content stream between think tags. Text
## inside such a span, and the tags themselves, never reach on_delta or on_done: the
## filter is stateful across chunks (a tag split between two deltas is still caught)
## and holds back a trailing fragment that could still turn into a tag. An unterminated
## span at the end of the stream is dropped, never shown.
const THINK_OPEN := "<think>"
const THINK_CLOSE := "</think>"

## Test hook (probes only): false forwards the raw stream, the negative control of the
## #615 check (it must see the leak the filter removes).
var stream_filter_enabled: bool = true


static func new_stream_filter() -> Dictionary:
	return {"buf": "", "hidden": false}


static func _ascii_lc(text: String) -> String:
	var out := ""
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c >= 65 and c <= 90:
			c += 32
		out += char(c)
	return out


## Length of the longest tail of `low` that is a proper prefix of a think tag.
static func _tag_prefix_tail(low: String) -> int:
	var most := mini(low.length(), THINK_CLOSE.length() - 1)
	for n in range(most, 0, -1):
		var tail := low.substr(low.length() - n)
		if THINK_OPEN.begins_with(tail) or THINK_CLOSE.begins_with(tail):
			return n
	return 0


## Feeds one content chunk; returns the text that may be shown.
static func filter_stream_piece(state: Dictionary, piece: String) -> String:
	var buf: String = String(state["buf"]) + piece
	var out := ""
	while true:
		var low := _ascii_lc(buf)
		if bool(state["hidden"]):
			var end_at := low.find(THINK_CLOSE)
			if end_at == -1:
				buf = buf.substr(maxi(buf.length() - (THINK_CLOSE.length() - 1), 0))
				break
			buf = buf.substr(end_at + THINK_CLOSE.length())
			state["hidden"] = false
			continue
		var open_at := low.find(THINK_OPEN)
		var close_at := low.find(THINK_CLOSE)
		if open_at == -1 and close_at == -1:
			var keep := _tag_prefix_tail(low)
			out += buf.substr(0, buf.length() - keep)
			buf = buf.substr(buf.length() - keep)
			break
		if close_at != -1 and (open_at == -1 or close_at < open_at):
			# a closing tag with no opening one: only the tag itself is dropped
			out += buf.substr(0, close_at)
			buf = buf.substr(close_at + THINK_CLOSE.length())
			continue
		out += buf.substr(0, open_at)
		buf = buf.substr(open_at + THINK_OPEN.length())
		state["hidden"] = true
	state["buf"] = buf
	return out


## End of the stream: a held-back fragment that never became a tag is ordinary text; an
## unterminated think span is dropped.
static func filter_stream_flush(state: Dictionary) -> String:
	var tail := "" if bool(state["hidden"]) else String(state["buf"])
	state["buf"] = ""
	state["hidden"] = false
	return tail


## Applies the filter to one chunk (or passes it through when the test hook is off).
func _filtered(state: Dictionary, piece: String) -> String:
	return filter_stream_piece(state, piece) if stream_filter_enabled else piece


## Flushes the filter at the end of a stream and returns the final accumulated text.
func _finish_stream(state: Dictionary, accumulated: String, on_delta: Callable) -> String:
	if not stream_filter_enabled:
		return accumulated
	var tail := filter_stream_flush(state)
	if tail.is_empty():
		return accumulated
	on_delta.call(tail)
	return accumulated + tail


## Streams a chat completion via /v1/chat/completions ("stream": true).
## SSE framing (`data: {...}` lines, terminal `data: [DONE]`) -- the
## server's own --reasoning-format deepseek + --jinja flags (set once at
## spawn) structurally separate delta.reasoning_content from delta.content
## in every streamed frame. Only delta.content ever reaches
## on_delta/on_done; delta.reasoning_content is read and intentionally
## discarded immediately below, never rendered, logged, or forwarded.
func send_chat(messages: Array, on_delta: Callable, on_done: Callable) -> void:
	_ensure_source()
	if _source != SOURCE_OWNED:
		await _send_chat_ollama(messages, on_delta, on_done)
		return
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
	var fstate := new_stream_filter()
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
				on_done.call(_finish_stream(fstate, accumulated, on_delta))
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
						var shown := _filtered(fstate, piece)
						if shown != "":
							accumulated += shown
							on_delta.call(shown)
				if choice.get("finish_reason", null) != null:
					on_done.call(_finish_stream(fstate, accumulated, on_delta))
					return
	on_done.call(_finish_stream(fstate, accumulated, on_delta))


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




## --- Model-source seam (Spec #519 A1) -----------------------------------
## data/llm_config.json carries `source`: "ollama" (default; the house Ollama
## through its NATIVE /api/chat, never /v1 which silently ignores num_ctx) or
## "owned" (the game-spawned llama-server above, kept intact as the shipping
## substrate). Everything below is additive: the owned path is unchanged.

const SOURCE_OLLAMA := "ollama"
const SOURCE_OWNED := "owned"
const SOURCE_INVALID := "invalid"
const OLLAMA_PATH := "/api/chat"
const OLLAMA_TAGS_PATH := "/api/tags"
const OLLAMA_TAGS_TRIES := 3
const OLLAMA_TAGS_TIMEOUT_MS := 5000
const OLLAMA_WARMUP_TIMEOUT_MS := 60000

## The whole parsed llm_config.json (empty until _load_config succeeds).
var _cfg: Dictionary = {}
var _source: String = SOURCE_OLLAMA
var _source_resolved: bool = false
## Set when DECOHERENCE_FORCE_GATE_FAIL=1: ollama-mode calls must not reach a
## real model behind a gate that was forced shut.
var _forced_fail: bool = false

## Count only, never the text: how many reasoning characters the most recent
## complete_structured() reply carried (0 when thinking was off).
var last_reasoning_chars: int = 0

## Number of completion requests issued through complete_structured() (not
## the gate poll, not the warm-up).
var request_count: int = 0

## Whether the most recent complete_structured() request had thinking enabled.
var last_thinking_enabled: bool = false

## Server-reported token counts of the most recent complete_structured() reply
## (ollama: prompt_eval_count / eval_count; owned: usage).
var last_prompt_tokens: int = 0
var last_out_tokens: int = 0


## Pure. Env beats config; absent both means "ollama"; anything other than
## exactly "ollama" or "owned" is "invalid" (the gate then fails honestly --
## a typo never silently picks a backend).
static func resolve_source(cfg: Dictionary, env_value: String) -> String:
	var v := env_value
	if v.is_empty() and cfg.has("source"):
		if typeof(cfg["source"]) != TYPE_STRING:
			return SOURCE_INVALID
		v = String(cfg["source"])
	if v.is_empty():
		return SOURCE_OLLAMA
	if v == SOURCE_OLLAMA or v == SOURCE_OWNED:
		return v
	return SOURCE_INVALID


## Pure. Builds {path, body} for one completion request so the request shape
## is testable with no model. `options` keys (all optional): thinking (bool),
## temperature, seed, max_tokens, cache_prompt, stream (bool, ollama only),
## grammar (String, owned only), schema (Dictionary).
## ollama: native /api/chat; num_ctx comes from config; `think` is explicit;
## the schema travels as `format`; never keep_alive, never a grammar prefix.
## owned: the original /v1/chat/completions body, unchanged.
static func build_structured_body(source: String, cfg: Dictionary, messages: Array, options: Dictionary) -> Dictionary:
	if source == SOURCE_OLLAMA:
		var oc: Dictionary = cfg.get("ollama", {}) if typeof(cfg.get("ollama", {})) == TYPE_DICTIONARY else {}
		var opts := {"num_ctx": int(oc.get("num_ctx", 0))}
		if options.has("temperature"):
			opts["temperature"] = float(options["temperature"])
		if options.has("seed"):
			opts["seed"] = int(options["seed"])
		if options.has("max_tokens"):
			opts["num_predict"] = int(options["max_tokens"])
		var obody := {
			"model": String(oc.get("model", "")),
			"messages": messages,
			"stream": bool(options.get("stream", false)),
			"think": bool(options.get("thinking", oc.get("think", false))),
			"options": opts,
		}
		if options.has("schema"):
			obody["format"] = options["schema"]
		return {"path": OLLAMA_PATH, "body": obody}

	var thinking: bool = bool(options.get("thinking", false))
	var body_dict := {
		"messages": messages,
		"stream": false,
		"temperature": float(options.get("temperature", 0)),
		"seed": int(options.get("seed", 0)),
		"max_tokens": int(options.get("max_tokens", 160)),
		"cache_prompt": bool(options.get("cache_prompt", true)),
		"chat_template_kwargs": {"enable_thinking": thinking},
	}
	if options.has("grammar"):
		# A raw grammar is applied from the first generated token (unlike a
		# response_format schema, which only starts after the reasoning block).
		body_dict["grammar"] = String(options["grammar"])
	elif options.has("schema"):
		body_dict["response_format"] = {"type": "json_schema", "json_schema": {"name": "intent", "strict": true, "schema": options["schema"]}}
		body_dict["json_schema"] = options["schema"]
	return {"path": "/v1/chat/completions", "body": body_dict}


## True when `text` is an Ollama /api/tags payload listing `model`.
static func tags_lists_model(text: String, model: String) -> bool:
	var parser := JSON.new()
	if parser.parse(text) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return false
	for m in parser.data.get("models", []):
		if typeof(m) == TYPE_DICTIONARY and (String(m.get("name", "")) == model or String(m.get("model", "")) == model):
			return true
	return false


func _ensure_source() -> void:
	if _source_resolved:
		return
	_load_config()
	_source = resolve_source(_cfg, OS.get_environment("DECOHERENCE_LLM_SOURCE"))
	_source_resolved = true


## Host and port the active source talks to. Ollama is loopback only: the host
## comes from config and there is no env override; only the port has a
## test-only override.
func _endpoint() -> Dictionary:
	if _source == SOURCE_OWNED:
		return {"host": _host, "port": _port}
	var oc: Dictionary = _cfg.get("ollama", {}) if typeof(_cfg.get("ollama", {})) == TYPE_DICTIONARY else {}
	var port := int(oc.get("port", 0))
	var override := OS.get_environment("DECOHERENCE_OLLAMA_PORT")
	if override.is_valid_int():
		port = override.to_int()
	return {"host": String(oc.get("host", "")), "port": port}


func _ollama_usable() -> bool:
	if _forced_fail or _source != SOURCE_OLLAMA:
		return false
	var ep := _endpoint()
	return String(ep["host"]) == DEFAULT_HOST and int(ep["port"]) > 0 and not String(_cfg.get("ollama", {}).get("model", "")).is_empty()


## One non-streaming HTTP exchange over the low-level client, bounded by
## `timeout_ms`. Returns {ok, code, text, error}.
func _http_exchange(host: String, port: int, method: int, path: String, body: String, timeout_ms: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	var client := HTTPClient.new()
	if client.connect_to_host(host, port) != OK:
		return {"ok": false, "code": 0, "text": "", "error": "connect"}
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		if Time.get_ticks_msec() - started > timeout_ms:
			return {"ok": false, "code": 0, "text": "", "error": "timeout"}
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "code": 0, "text": "", "error": "connect"}
	var headers := PackedStringArray(["Content-Type: application/json"])
	if client.request(method, path, headers, body) != OK:
		return {"ok": false, "code": 0, "text": "", "error": "request"}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() - started > timeout_ms:
			return {"ok": false, "code": 0, "text": "", "error": "timeout"}
		client.poll()
		await get_tree().process_frame
	var raw := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() - started > timeout_ms:
			return {"ok": false, "code": 0, "text": "", "error": "timeout"}
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			await get_tree().process_frame
		else:
			raw.append_array(chunk)
	return {"ok": true, "code": client.get_response_code(), "text": raw.get_string_from_utf8(), "error": ""}


## Ollama-mode boot gate: the model must be listed by /api/tags, then a
## one-token warm-up through the same native endpoint and options makes it
## resident at the configured context before the gate reports success.
## Never spawns anything, never writes a pid file, never touches :8085.
func _check_ollama_ready() -> void:
	if not _ollama_usable():
		print("LLM_SOURCE_UNUSABLE source=%s" % _source)
		model_ready.emit(false)
		return
	var ep := _endpoint()
	var model := String(_cfg["ollama"]["model"])
	var listed := false
	for i in range(OLLAMA_TAGS_TRIES):
		var tags := await _http_exchange(String(ep["host"]), int(ep["port"]), HTTPClient.METHOD_GET, OLLAMA_TAGS_PATH, "", OLLAMA_TAGS_TIMEOUT_MS)
		if tags["ok"] and int(tags["code"]) == 200:
			listed = tags_lists_model(String(tags["text"]), model)
			break
		await get_tree().create_timer(READY_POLL_INTERVAL_SEC).timeout
	if not listed:
		print("LLM_OLLAMA_UNAVAILABLE")
		model_ready.emit(false)
		return
	var warm := build_structured_body(SOURCE_OLLAMA, _cfg, [{"role": "user", "content": "ok"}], {"max_tokens": 1, "temperature": 0, "thinking": false})
	var res := await _http_exchange(String(ep["host"]), int(ep["port"]), HTTPClient.METHOD_POST, String(warm["path"]), JSON.stringify(warm["body"]), OLLAMA_WARMUP_TIMEOUT_MS)
	var ok: bool = bool(res["ok"]) and int(res["code"]) == 200
	print("LLM_OLLAMA_READY" if ok else "LLM_OLLAMA_WARMUP_FAILED")
	model_ready.emit(ok)


## Streaming chat through the native endpoint (NDJSON, one object per line).
## Only message.content reaches on_delta/on_done; message.thinking, if a model
## ever sends it, is dropped here and never forwarded.
func _send_chat_ollama(messages: Array, on_delta: Callable, on_done: Callable) -> void:
	if not _ollama_usable():
		on_done.call("")
		return
	var ep := _endpoint()
	var built := build_structured_body(SOURCE_OLLAMA, _cfg, messages, {"stream": true, "thinking": false})
	var client := HTTPClient.new()
	if client.connect_to_host(String(ep["host"]), int(ep["port"])) != OK:
		on_done.call("")
		return
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		on_done.call("")
		return
	var headers := PackedStringArray(["Content-Type: application/json"])
	if client.request(HTTPClient.METHOD_POST, String(built["path"]), headers, JSON.stringify(built["body"])) != OK:
		on_done.call("")
		return
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame

	var accumulated := ""
	var pending := ""
	var fstate := new_stream_filter()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			await get_tree().process_frame
			continue
		pending += chunk.get_string_from_utf8()
		var split_lines := pending.split("\n")
		pending = split_lines[split_lines.size() - 1]
		for i in range(split_lines.size() - 1):
			var line := split_lines[i].strip_edges()
			if line.is_empty():
				continue
			var parsed = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
			var message = parsed.get("message", {})
			if typeof(message) == TYPE_DICTIONARY:
				var piece = message.get("content", "")
				if typeof(piece) == TYPE_STRING and piece != "":
					var shown := _filtered(fstate, piece)
					if shown != "":
						accumulated += shown
						on_delta.call(shown)
			if bool(parsed.get("done", false)) or parsed.has("error"):
				on_done.call(_finish_stream(fstate, accumulated, on_delta))
				return
	on_done.call(_finish_stream(fstate, accumulated, on_delta))


## One stateless, non-streaming structured completion through the active
## source. `options` keys (all optional): grammar (String, owned only),
## schema (Dictionary; ollama `format`, owned response_format), thinking
## (bool, default false), temperature, seed, max_tokens, cache_prompt,
## timeout_ms (default 8000), reasoning_probe (Callable taking the reasoning
## text; test-only).
## Calls `on_done` once with {ok, content, reasoning_chars, ms, error,
## prompt_tokens, out_tokens}. Only message.content is ever returned as
## content; the reasoning field is measured (length) and handed solely to an
## explicit test probe.
func complete_structured(messages: Array, options: Dictionary, on_done: Callable) -> void:
	request_count += 1
	var started := Time.get_ticks_msec()
	var thinking: bool = bool(options.get("thinking", false))
	last_thinking_enabled = thinking
	last_reasoning_chars = 0
	last_prompt_tokens = 0
	last_out_tokens = 0
	var timeout_ms: int = int(options.get("timeout_ms", 8000))

	_ensure_source()
	if _source == SOURCE_INVALID or (_source == SOURCE_OLLAMA and not _ollama_usable()):
		on_done.call(_structured_result(false, "", 0, started, "source"))
		return
	var ep := _endpoint()
	var built := build_structured_body(_source, _cfg, messages, options)
	var ex := await _http_exchange(String(ep["host"]), int(ep["port"]), HTTPClient.METHOD_POST, String(built["path"]), JSON.stringify(built["body"]), timeout_ms)
	if not ex["ok"]:
		on_done.call(_structured_result(false, "", 0, started, String(ex["error"])))
		return
	if int(ex["code"]) != 200:
		on_done.call(_structured_result(false, "", 0, started, "http_%d" % int(ex["code"])))
		return
	var parsed = JSON.parse_string(String(ex["text"]))
	if typeof(parsed) != TYPE_DICTIONARY:
		on_done.call(_structured_result(false, "", 0, started, "bad_json"))
		return
	var message: Dictionary = {}
	if _source == SOURCE_OLLAMA:
		if typeof(parsed.get("message", null)) != TYPE_DICTIONARY:
			on_done.call(_structured_result(false, "", 0, started, "no_choices"))
			return
		message = parsed["message"]
		last_prompt_tokens = int(parsed.get("prompt_eval_count", 0))
		last_out_tokens = int(parsed.get("eval_count", 0))
	else:
		var choices: Array = parsed.get("choices", [])
		if choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
			on_done.call(_structured_result(false, "", 0, started, "no_choices"))
			return
		message = choices[0].get("message", {})
		var usage = parsed.get("usage", {})
		if typeof(usage) == TYPE_DICTIONARY:
			last_prompt_tokens = int(usage.get("prompt_tokens", 0))
			last_out_tokens = int(usage.get("completion_tokens", 0))
	var content: String = String(message.get("content", ""))
	var reasoning: String = String(message.get("thinking", "")) if _source == SOURCE_OLLAMA else String(message.get("reasoning_content", ""))
	last_reasoning_chars = reasoning.length()
	var probe = options.get("reasoning_probe", null)
	if probe is Callable and probe.is_valid():
		probe.call(reasoning)
	on_done.call(_structured_result(true, content, reasoning.length(), started, ""))


func _structured_result(ok: bool, content: String, reasoning_chars: int, started: int, error: String) -> Dictionary:
	return {
		"ok": ok,
		"content": content,
		"reasoning_chars": reasoning_chars,
		"ms": Time.get_ticks_msec() - started,
		"error": error,
		"prompt_tokens": last_prompt_tokens,
		"out_tokens": last_out_tokens,
	}
