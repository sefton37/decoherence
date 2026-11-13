extends RefCounted
class_name FunnelProbe

## Spec #573 probe modes (additive; inert unless the probe driver dispatches to
## it): the recruitment funnel driven end to end through the real frontdoor. Every
## player action is an InputEventKey into the viewport (one per character, then
## Enter); the probe only READS the room, the model and the client to observe, and
## it never calls a method that performs a user action (direct_calls stays 0). The
## clock is the room's simulated clock (Chatroom.sim_enable), advanced by hand, so a
## five-to-eight minute funnel runs in seconds of wall time. Each mode writes one
## part file with exactly the keys the DoD reads; tests/verify_chat_client.sh
## merges it. No authored word is spelled here: expected text always comes from the
## data files.

const STAGES := ["lurk", "contact", "qualify", "pushback", "dm", "pitch", "ask", "rename", "launch"]
const STEP_MS := 1000
const HELLO := "hello anyone here"
const SEED_BASE := 573000

var d  # the probe driver node (untyped on purpose: its helpers are called dynamically)
var cr: Chatroom
var llm: LlmClient
var shell: ShellController
var keys_driven: int = 0
var typed_chars: int = 0
var direct_calls: int = 0
var grants: int = 0
var _qn: int = 0
var _reply_due: int = -1
var _think_ms: int = 6000
var _type_ms: int = 140
var _handle: String = "Ember_77"
var _hold_until: int = -1
var _out: Dictionary = {}


func _init(driver) -> void:
	d = driver


func run(mode: String) -> void:
	shell = d._shell_node()
	shell.world_dry_run = true
	cr = d._cr()
	llm = d._llm_node()
	Signals.chatroom_entry_granted.connect(_on_granted)
	match mode:
		"funnel_e2e":
			await _mode_e2e()
		"funnel_refuse":
			await _mode_refuse()
		"funnel_persist":
			await _mode_persist()
		"funnel_memory":
			await _mode_memory()
		"funnel_canon":
			await _mode_canon()
		"funnel_nolie":
			await _mode_nolie()
		"funnel_mutate":
			await _mode_mutate()
		"funnel_shots":
			await _mode_shots()
		"funnel_leak_live":
			await _mode_leak_live()
	var tag := OS.get_environment("DECOHERENCE_PROBE_TAG")
	d._cr_part(mode if tag.is_empty() else mode + "_" + tag, _out)
	cr.reset_session(-1)


func _on_granted() -> void:
	grants += 1


## --- Driving ------------------------------------------------------------------------------------

func _cfg() -> Dictionary:
	return ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel.json")


func _tree_frame() -> void:
	await d.get_tree().process_frame


## Leaves the room if inside, starts a fresh session on the simulated clock and opens `chat`.
func open_session(seed_value: int, keep_profile: bool = false) -> void:
	await _leave_module()
	if cr.is_inside():
		d._cr_say("leave")
		await d._wait_frames(3)
	cr.reset_session(seed_value, keep_profile)
	cr.sim_enable(0)
	_qn = 0
	_reply_due = -1
	_hold_until = -1
	d._cr_say("chat")
	await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
	await d._wait_frames(3)


## The funnel now ends in the HANDLER module (Spec #575): a session that reached it leaves with Esc,
## the one key the screen answers to, and the shell prompt takes the keyboard back.
func _leave_module() -> void:
	if shell.current_state_name() == "HANDLER":
		await press(KEY_ESCAPE)
		await d._wait_frames(2)
		shell.world_closed()


## After the funnel ended in the module, the player's way back to the room: Esc, then the typed `chat`.
func reenter_chat() -> void:
	await _leave_module()
	if not d._cc().is_mounted():
		d._cr_say("chat")
		await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
		await d._wait_frames(3)


## One tick of the simulated clock. A model reply in flight is waited for in wall time first.
func step(ms: int = STEP_MS) -> void:
	while cr.is_busy():
		await _tree_frame()
	cr.sim_advance(ms)
	await _tree_frame()


## The player types: time passes (per character), then one key event per character, then Enter.
func send(text: String, per_char_ms: int = 0) -> void:
	if per_char_ms > 0:
		cr.sim_advance(text.length() * per_char_ms)
	for i in range(text.length()):
		Input.parse_input_event(d._key_event(KEY_NONE, text.unicode_at(i)))
		typed_chars += 1
		keys_driven += 1
	Input.parse_input_event(d._key_event(KEY_ENTER))
	keys_driven += 1
	await d._wait_frames(2)


func press(keycode: int, ctrl: bool = false) -> void:
	Input.parse_input_event(d._key_event(keycode, 0, false, ctrl))
	keys_driven += 1
	await d._wait_frames(2)


func model_buf() -> ChatModel:
	return cr.model


func handler() -> String:
	return cr.contact_handle()


func dm_buffer() -> String:
	return ChatModel.dm_id(handler())


## The buffer the handler's thread is in right now.
func thread_buffer() -> String:
	if cr.funnel.stage >= cr.funnel.index_of("dm"):
		return dm_buffer()
	return cr._thread_buf if not String(cr._thread_buf).is_empty() else String(cr._contact_target)


## Brings the thread's buffer to the screen with real keys (Ctrl+N cycles open buffers).
func goto(buffer: String) -> void:
	var tries := 0
	while cr.model.active != buffer and tries < 12 and cr.model.is_open(buffer):
		await press(KEY_N, true)
		tries += 1


## What the scripted player says, by stage. Only what a person would type: no authored word.
func line_for(prof: Dictionary) -> String:
	match cr.funnel.stage_id():
		"contact":
			return String(prof.get("contact", "hello, i just got here"))
		"qualify":
			_qn += 1
			return String(prof.get("origin", "i live on the north coast of an island")) if _qn == 1 else String(prof.get("doing", "i work nights stacking shelves"))
		"pushback":
			return String(prof.get("pushback", "what do you mean by that"))
		"dm":
			return String(prof.get("dm", "ok, i read your message"))
		"pitch":
			return String(prof.get("pitch", "that makes sense, tell me more"))
		"ask":
			return String(prof.get("ask", "yes"))
		"rename":
			return String(prof.get("handle", _handle))
	return "ok"


## One decision of the scripted player: answer once she is waiting for it. Returns the line sent or "".
func agent_tick(prof: Dictionary) -> String:
	var f := cr.funnel
	if f == null or cr.is_busy():
		return ""
	if not f.pending_wait():
		_reply_due = -1
		return ""
	var now := cr.now_ms()
	if _reply_due < 0:
		var think := _think_ms
		if _hold_until > 0 and f.stage_id() == String(prof.get("hold_stage", "")):
			think = _hold_until
			_hold_until = -1
		_reply_due = maxi(f.wait_since(), now) + think
		return ""
	if now < _reply_due:
		return ""
	_reply_due = -1
	var line := line_for(prof)
	await goto(thread_buffer())
	await send(line, _type_ms)
	return line


## All rows of every buffer: [{buffer, kind, handle, text}] (no timestamps).
func all_rows() -> Array:
	var out: Array = []
	for id in cr.model.buffers:
		for r in cr.model.buffers[id]["rows"]:
			out.append({"buffer": String(id), "kind": String(r["kind"]), "handle": String(r["handle"]), "text": String(r["text"])})
	return out


## A hash of what the session wrote, with no timestamps and a fixed buffer order.
func rows_hash() -> String:
	var ids: Array = cr.model.buffers.keys()
	ids.sort()
	var blob := ""
	var n := 0
	for id in ids:
		for r in cr.model.buffers[id]["rows"]:
			blob += "%s|%s|%s|%s\n" % [id, String(r["kind"]), String(r["handle"]), String(r["text"])]
			n += 1
	return "%d:%s" % [n, blob.sha256_text()]


func rows_count() -> int:
	var n := 0
	for id in cr.model.buffers:
		n += (cr.model.buffers[id]["rows"] as Array).size()
	return n


func stage_trail() -> Array:
	var out: Array = ["lurk"]
	for tr in cr.funnel.transitions:
		out.append(STAGES[int(tr[1])])
	return out


func slot_leaks() -> int:
	var re := RegEx.new()
	re.compile("\\{[A-Za-z_]+\\}")
	var n := 0
	for r in all_rows():
		if re.search(String(r["text"])) != null:
			n += 1
	return n


func count_fkind(kind: String) -> int:
	var n := 0
	for e in cr.emission_log:
		if String(e.get("fkind", "")) == kind:
			n += 1
	return n


func handler_rows(since_index: int = 0) -> Array:
	var out: Array = []
	for i in range(since_index, cr.emission_log.size()):
		var e: Dictionary = cr.emission_log[i]
		if int(e["beat"]) == Chatroom.Beat.CONTACT and e.has("fkind"):
			out.append(e)
	return out


## Plays the funnel with the scripted player until `until` returns true, the room
## grants entry, or `max_ms` of simulated time has passed. Returns the simulated ms spent.
func play(prof: Dictionary, until: Callable, max_ms: int = 1500000) -> int:
	var t0 := cr.now_ms()
	while cr.now_ms() - t0 < max_ms:
		if until.call() or cr.grant_ms >= 0:
			break
		await step()
		await agent_tick(prof)
	return cr.now_ms() - t0


func at_stage_waiting(stage_name: String) -> bool:
	return cr.funnel.stage_id() == stage_name and cr.funnel.pending_wait() and not cr.is_busy() and cr.funnel.active()


## A session for `profile` (typical, fast or idle) to the grant. Returns the run record.
func run_profile(profile: String, seed_value: int, data_note: String = "", extra: Dictionary = {}) -> Dictionary:
	_think_ms = 6000
	_type_ms = 140
	var prof := extra.duplicate()
	if profile == "fast":
		_think_ms = 800
		_type_ms = 40
	var idle_cfg := _cfg()
	var keys0 := keys_driven
	var chars0 := typed_chars
	await open_session(seed_value)
	if profile == "idle":
		prof["hold_stage"] = "qualify"
		_hold_until = int(idle_cfg["stages"][2]["idle_ms"]) + 8000
	await send(HELLO, _type_ms)
	var req_idle0 := -1
	var req_idle1 := -1
	var model_at_contact := -1
	var world_prev := 0
	var world_base := shell.world_request_count
	var module_prev := 0
	var module_base := shell.module_open_count
	var granted_world_before := -1
	var granted_module_before := -1
	var accepted_at := -1
	var yes_at := -1
	var guard := 0
	while cr.grant_ms < 0 and guard < 4000:
		guard += 1
		world_prev = shell.world_request_count
		module_prev = shell.module_open_count
		await step()
		if model_at_contact < 0 and cr.contact_ms >= 0:
			model_at_contact = cr.model_requests
		if profile == "idle" and req_idle0 < 0 and _hold_until < 0 and cr.funnel.stage_id() == "qualify":
			req_idle0 = cr.model_requests
		if req_idle0 >= 0 and req_idle1 < 0 and count_fkind("idle_followup") > 0:
			req_idle1 = cr.model_requests
		if accepted_at < 0 and cr.funnel.accepted:
			accepted_at = cr.now_ms()
		var line := await agent_tick(prof)
		if line == "yes" or line == String(prof.get("ask", "yes")):
			yes_at = cr.now_ms()
		if cr.grant_ms >= 0:
			granted_world_before = world_prev
			granted_module_before = module_prev
	await d._wait_frames(3)
	await step()
	var rec := {
		"profile": profile,
		"seed": seed_value,
		"stages": stage_trail(),
		"first_message_ms": cr.first_message_ms,
		"grant_ms": cr.grant_ms,
		"elapsed_ms": cr.grant_ms - cr.first_message_ms,
		"typed_chars": typed_chars - chars0,
		"keys_driven": keys_driven - keys0,
		"direct_calls": direct_calls,
		"clock": "sim" if cr.sim_enabled() else "real",
		"idle_followups": count_fkind("idle_followup"),
		"idle_model_requests": (req_idle1 - req_idle0) if req_idle0 >= 0 and req_idle1 >= 0 else 0,
		"world_before_grant": maxi(granted_world_before - world_base, 0),
		"world_total": shell.world_request_count - world_base,
		"module_before_grant": maxi(granted_module_before - module_base, 0),
		"module_entries": shell.module_open_count - module_base,
		"model_requests": cr.model_requests,
		"model_before_contact": maxi(model_at_contact, 0),
		"model_in_other_buffers": _model_rows_elsewhere(),
		"consent_by": "code" if cr.funnel.accepted and accepted_at >= 0 and yes_at >= 0 and absi(accepted_at - yes_at) <= 2 * STEP_MS + 2500 else "other",
		"launch_via": "entry_path" if grants == 1 and shell.module_open_count - module_base == 1 else "other",
		"slot_leaks": slot_leaks(),
	}
	if data_note != "":
		rec["note"] = data_note
	grants = 0
	return rec


func _model_rows_elsewhere() -> int:
	var n := 0
	var ok_buffers := [String(cr._contact_target), dm_buffer()]
	for e in cr.emission_log:
		if String(e.get("fkind", "")) == "model":
			var b := String(e["buffer"])
			if not b.begins_with(ChatModel.DM_PREFIX) and b != String(cr.room_script().get("entry_room", "")) and not cr.model.is_room(b):
				n += 1
			elif b.begins_with(ChatModel.DM_PREFIX) and not ok_buffers.has(b) and b != ChatModel.dm_id(String(e["handle"])):
				n += 1
	return n


## --- Detectors, proven on planted input (the controls) ---------------------------------------------------

static func stage_skip_detected(trail: Array) -> bool:
	var last := -1
	for s in trail:
		var i := STAGES.find(String(s))
		if i < 0 or i != last + 1:
			return true
		last = i
	return false


## Writes a copy of the chatroom data directory under user:// with `fn` applied to the
## parsed funnel.json (and optionally the other files); returns its path.
func data_copy(name: String, funnel_fn: Callable, extra_fn: Callable = Callable()) -> String:
	var src := ChatroomScript.data_dir()
	var dst := "user://funnel_probe_data/" + name
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst))
	var da := DirAccess.open(src)
	for f in da.get_files():
		if not f.ends_with(".json"):
			continue
		var data = ChatroomScript.read_json(src + "/" + f)
		if f == "funnel.json" and funnel_fn.is_valid():
			data = funnel_fn.call(data)
		if extra_fn.is_valid():
			data = extra_fn.call(f, data)
		var out := FileAccess.open(dst + "/" + f, FileAccess.WRITE)
		out.store_string(JSON.stringify(data))
		out.close()
	return dst


func use_data(path: String) -> void:
	OS.set_environment(ChatroomScript.ENV_DIR, path)


func restore_data(original: String) -> void:
	OS.set_environment(ChatroomScript.ENV_DIR, original)


## --- funnel_e2e -----------------------------------------------------------------------------------------------

## DECOHERENCE_FUNNEL_ONLY (a comma list of section names) limits an e2e run while developing.
func _want(section: String) -> bool:
	var only := OS.get_environment("DECOHERENCE_FUNNEL_ONLY")
	return only.is_empty() or only.split(",").has(section)


func _mode_e2e() -> void:
	if not _want("runs"):
		if _want("replay"):
			_out["replay"] = await _replay()
		return
	var runs: Array = []
	var original := OS.get_environment(ChatroomScript.ENV_DIR)
	for i in range(5):
		runs.append(await run_profile("typical", SEED_BASE + i))
	for i in range(2):
		runs.append(await run_profile("fast", SEED_BASE + 100 + i))
	runs.append(await run_profile("idle", SEED_BASE + 200))
	_out["runs"] = runs
	# the compressed copy of the data: a funnel that skips its dwell is below the floor
	var path := data_copy("compressed", func(c): return _compress(c))
	use_data(path)
	var comp := await run_profile("fast", SEED_BASE + 300, "compressed")
	restore_data(original)
	var floor_ms: int = int(_cfg()["target_ms"][0]) - 60000
	_out["neg"] = {
		"compressed_elapsed_ms": int(comp["elapsed_ms"]),
		"flagged_below_floor": int(comp["elapsed_ms"]) < floor_ms,
		"stage_skip_planted_detected": stage_skip_detected(["lurk", "contact", "pitch", "ask", "rename", "launch"]) and not stage_skip_detected(STAGES),
	}
	_out["boundary"] = await _boundary()
	await _dm_and_rename()
	_out["replay"] = await _replay()


func _compress(c: Dictionary) -> Dictionary:
	for s in c["stages"]:
		s["dwell_ms"] = [200, 400]
	c["typing_ms_per_char"] = 4
	return c


func _boundary() -> Dictionary:
	var attacks := [
		"ok", "maybe", "yes but", "yes, but not now", "sure", "i guess", "yeah", "y", "yes?", "yesss", "yes yes",
		"do not accept", "not accept", "accepted", "acceptable", "enter", "yes please", "ENTER THE WORLD", "/world",
		"i will not", "уes", "yеs", "ｙｅｓ", "İ accept", "i аccept",
	]
	var lookalikes := ["уes", "yеs", "ｙｅｓ", "İ accept", "i аccept"]
	var res := {"attacks": [], "attack_count": 0}
	var prof := {}
	_think_ms = 3000
	_type_ms = 60
	await open_session(SEED_BASE + 400)
	await send(HELLO, _type_ms)
	await play(prof, func(): return at_stage_waiting("ask"))
	var reask0 := count_fkind("reask")
	var world0 := shell.world_request_count
	var ambiguous := 0
	var assumed := 0
	var lookalike_world := 0
	var seen := {}
	for a in attacks:
		if seen.has(a):
			continue
		seen[a] = true
		var w0 := shell.world_request_count
		var m0 := shell.module_open_count
		await goto(thread_buffer())
		await send(String(a), 0)
		for i in range(8):
			await step()
		var dw := shell.world_request_count - w0
		res["attacks"].append({"name": String(a), "world_requests": dw, "module_entries": shell.module_open_count - m0})
		if lookalikes.has(a):
			lookalike_world += dw
		if not cr.funnel.accepted:
			ambiguous += 1
		else:
			assumed += 1
		# a reask may or may not have been spoken; wait until she waits again
		await play(prof, func(): return at_stage_waiting("ask") or not cr.funnel.active(), 120000)
		if not cr.funnel.active():
			break
	res["attack_count"] = (res["attacks"] as Array).size()
	res["ambiguous_reasked"] = count_fkind("reask") - reask0
	res["assumed_consent"] = assumed
	res["lookalike_world"] = lookalike_world
	# the model says it, and says it in a field: neither opens anything
	var model_text := 0
	var model_launch := 0
	if cr.funnel.active():
		for pair in [["text_entry", 0], ["launch_claim", 1], ["extra_act_key", 1]]:
			d._cr_set_mode(String(pair[0]))
			var w1 := shell.world_request_count
			await goto(thread_buffer())
			await send("hmm", 0)
			for i in range(6):
				await step()
			var dw1 := shell.world_request_count - w1
			if String(pair[0]) == "text_entry":
				model_text += dw1
			else:
				model_launch += dw1
		d._cr_set_mode("funnel_ok")
	res["model_text_entry_world"] = model_text
	res["model_launch_claim_world"] = model_launch
	res["early_consent_world"] = await _early_consent_world()
	res["idle_launch"] = await _idle_launch_world()
	res["launch_without_rename"] = await _no_handle_world()
	var control: Dictionary = await _real_consent()
	res["control_real_consent_world"] = int(control["world"])
	res["control_real_consent_module"] = int(control["module"])
	res["world_total_before_control"] = shell.world_request_count - world0
	return res


## "yes" and "i accept" typed before the ask: nothing is accepted and nothing opens.
func _early_consent_world() -> int:
	var total := 0
	for stage_name in ["contact", "qualify", "pushback", "pitch"]:
		await open_session(SEED_BASE + 410)
		await send(HELLO, 60)
		_think_ms = 3000
		await play({}, func(): return at_stage_waiting(stage_name))
		var w0 := shell.world_request_count
		await goto(thread_buffer())
		await send("yes", 0)
		await send("i accept", 0)
		for i in range(10):
			await step()
		total += shell.world_request_count - w0
		if cr.funnel.accepted:
			total += 1000
	return total


## Silence at the ask (every follow-up unanswered): she steps away and nothing opens.
func _idle_launch_world() -> int:
	await open_session(SEED_BASE + 420)
	await send(HELLO, 60)
	_think_ms = 3000
	await play({}, func(): return at_stage_waiting("ask"))
	var w0 := shell.world_request_count
	var cfg := _cfg()
	var wait_ms: int = int(cfg["stages"][6]["idle_ms"]) * (int(cfg["stages"][6]["max_idle_followups"]) + 3)
	var t0 := cr.now_ms()
	while cr.now_ms() - t0 < wait_ms:
		await step()
	return (shell.world_request_count - w0) + (0 if cr.funnel.outcome == Funnel.OUT_LAPSED else 1000)


## A yes with no handle ever chosen: the launch never happens.
func _no_handle_world() -> int:
	await open_session(SEED_BASE + 430)
	await send(HELLO, 60)
	_think_ms = 3000
	await play({}, func(): return at_stage_waiting("ask"))
	await goto(thread_buffer())
	await send("yes", 0)
	var w0 := shell.world_request_count
	var cfg := _cfg()
	var wait_ms: int = int(cfg["stages"][7]["idle_ms"]) * (int(cfg["stages"][7]["max_idle_followups"]) + 3)
	var t0 := cr.now_ms()
	while cr.now_ms() - t0 < wait_ms:
		await step()
	return (shell.world_request_count - w0) + (0 if String(cr.funnel.stage_id()) == "rename" or not cr.funnel.active() else 1000)


## The positive control: a real yes and a valid handle open the HANDLER module exactly once and
## the world not at all (the world is entered from the module, by the player's own press).
func _real_consent() -> Dictionary:
	grants = 0
	var w0 := shell.world_request_count
	var m0 := shell.module_open_count
	var rec := await run_profile("fast", SEED_BASE + 440)
	if int(rec["elapsed_ms"]) <= 0:
		return {"world": -1, "module": -1}
	return {"world": shell.world_request_count - w0, "module": shell.module_open_count - m0}


## --- replay ---------------------------------------------------------------------------------------------------------

func _replay_run(seed_value: int, fresh_profile: bool = true) -> Dictionary:
	_think_ms = 3000
	_type_ms = 60
	await open_session(seed_value, not fresh_profile)
	for rid in cr.model.room_order:
		if not bool(cr.model.rooms[rid]["joined"]):
			await send("/join " + String(rid), 0)
	await goto(String(cr.room_script().get("entry_room", "")))
	await send(HELLO, _type_ms)
	await play({}, func(): return false, 900000)
	return {"hash": rows_hash(), "rows": rows_count(), "trail": stage_trail(), "handler": handler(), "designation": cr.session_handle(), "seed": cr.session_seed()}


func _replay() -> Dictionary:
	var a := await _replay_run(SEED_BASE + 500)
	var b := await _replay_run(SEED_BASE + 500)
	var c := await _replay_run(SEED_BASE + 501)
	var u1 := await _replay_run(-1)
	var u2 := await _replay_run(-1)
	var planted := String(a["hash"]) + "x"
	return {
		"hashes": [a["hash"], b["hash"], c["hash"], u1["hash"], u2["hash"]],
		"seed_env": Chatroom.SEED_ENV,
		"rows_compared": mini(int(a["rows"]), int(b["rows"])),
		"same_seed_hash_equal": a["hash"] == b["hash"],
		"other_seed_differs": a["hash"] != c["hash"],
		"unseeded_differ": u1["hash"] != u2["hash"],
		"unseeded_seeds": [u1["seed"], u2["seed"]],
		"fresh_profile_same_seed_same_handler": a["handler"] == b["handler"] and a["designation"] == b["designation"],
		"stage_sequence_equal": a["trail"] == b["trail"],
		"control_planted_difference_detected": planted != a["hash"],
	}


## --- the move to the direct message, and the rename ------------------------------------------------------------

var _rename_state: Dictionary = {}


## Watches the direct message: the moment her rename line is the newest row, the player is
## still known by the old name (the roster, nav and profile change after the line).
func _on_model_changed() -> void:
	if not _rename_state.is_empty() or cr.funnel == null:
		return
	var dm := dm_buffer()
	if not cr.model.buffers.has(dm):
		return
	var rows: Array = cr.model.rows_of(dm)
	if rows.is_empty():
		return
	var last: Dictionary = rows.back()
	if String(last["kind"]) == "voice" and String(last["handle"]) == handler() and String(last["text"]).contains(_handle) and cr.funnel.stage_id() == "launch":
		_rename_state = {"self_at_row": cr.model.self_handle, "row_handle": String(last["handle"]), "buffer": dm}


func _surfaces(room_id: String, dm_id: String) -> Array:
	var ui: Array = d._cc().ui_text_snapshot()
	var handles: Array = []
	for r in d._cc().roster_snapshot():
		handles.append(String(r["handle"]))
	return [
		" ".join(cr.model.roster(room_id)),
		" ".join(cr.model.roster(dm_id)),
		String(ui[0]),
		"\n".join(d._cc_pane(ui, "people")),
		cr.model.self_handle,
		cr.session_handle(),
		" ".join(handles),
		String(ui[1]),
	]


func _count_containing(surfaces: Array, needle: String) -> int:
	var n := 0
	for s in surfaces:
		if String(s).contains(needle):
			n += 1
	return n


func _dm_and_rename() -> void:
	_think_ms = 3000
	_type_ms = 60
	Signals.chat_model_changed.connect(_on_model_changed)
	await open_session(SEED_BASE + 600)
	var m := cr.model
	var room_id := String(m.active)
	await send(HELLO, _type_ms)
	var dm := ""
	await play({}, func(): return cr.funnel.stage_id() == "dm" and cr.model.buffers.has(ChatModel.dm_id(handler())) and (cr.model.buffers[ChatModel.dm_id(handler())]["rows"] as Array).size() >= 1)
	dm = dm_buffer()
	var first_row: Dictionary = (m.buffers[dm]["rows"] as Array)[0]
	var ui: Array = d._cc().ui_text_snapshot()
	var unread_ok: bool = m.unread_of(dm) >= 1 and d._cc_unread_in_ui(ui, handler()) >= 1 and d._cc_nav_total(ui) >= 1
	var handler_rows_before := handler_rows().size()
	var log_before: int = cr.emission_log.size()
	var no_autoswitch: bool = m.active == room_id
	for line in ["anyone there", "hello again", "is this thing on"]:
		await send(String(line), 40)
		for i in range(4):
			await step()
	var redirects := count_fkind("redirect")
	var room_rows := 0
	for e in handler_rows(log_before):
		if m.is_room(String(e["buffer"])):
			room_rows += 1
	await press(KEY_F3)
	var switched: bool = m.active == dm
	await play({}, func(): return at_stage_waiting("rename"))
	var official := 0
	for e in cr.emission_log:
		if String(e["buffer"]) == dm and int(e["beat"]) == Chatroom.Beat.CONTACT and ["open", "callback"].has(String(e.get("fkind", ""))):
			official += 1
	_out["dm"] = {
		"opened_by_handler": String(first_row["handle"]) == handler() and String(first_row["kind"]) == "voice" and handler_rows_before >= 1,
		"unread_marker_seen": unread_ok,
		"no_autoswitch": no_autoswitch,
		"official_beats_in_dm": official,
		"room_rows_from_handler_after_open": room_rows,
		"redirects": redirects,
		"switched_by_nav_key": switched,
	}
	await _rename_checks(room_id, dm)
	_think_ms = 3000
	await play({}, func(): return false, 900000)


func _rename_checks(room_id: String, dm: String) -> void:
	var m := cr.model
	var old := String(m.self_handle)
	var cfg := _cfg()
	var reserved: Array = ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel_names.json").get("reserved", [])
	var invalid := ["ab", "x".repeat(17), "two words", "café", "bad!name", "ADMIN", "XEN-4", old]
	var kinds := {}
	var tried := 0
	var before := count_fkind("handle_invalid")
	await goto(dm)
	for text in invalid:
		tried += 1
		var r := Funnel.validate_handle(cfg, String(text), m.known_handles() + [old, handler()], reserved)
		kinds[String(r["reason"])] = true
		var n0 := count_fkind("handle_invalid")
		await send(String(text), 40)
		for i in range(14):
			await step()
			if count_fkind("handle_invalid") > n0:
				break
	var rejected := count_fkind("handle_invalid") - before
	var new_handle := _handle
	await send(new_handle, 40)
	for i in range(30):
		await step()
		if m.self_handle == new_handle:
			break
	await d._wait_frames(3)
	var ui: Array = d._cc().ui_text_snapshot()
	var surfaces := _surfaces(room_id, dm)
	var entries := ChatModel.roster_entries(m, room_id)
	var marker_ok := false
	for e in entries:
		if String(e["handle"]) == new_handle and String(e["marker"]) == "<":
			marker_ok = true
		if String(e["handle"]) == old:
			marker_ok = false
			break
	var presence := false
	for r in m.rows_of(room_id):
		if String(r["kind"]) == "presence" and String(r["text"]).contains(old) and String(r["text"]).contains(new_handle):
			presence = true
	var saved := ProfileStore.load_profile()
	var planted := PackedStringArray(surfaces)
	planted[3] = planted[3] + " " + old
	_out["rename"] = {
		"actor_row_before_change": String(_rename_state.get("self_at_row", "")) == old and String(_rename_state.get("buffer", "")) == dm,
		"performed_by": "handler" if String(_rename_state.get("row_handle", "")) == handler() else "other",
		"roster_room_new": m.roster(room_id).has(new_handle) and not m.roster(room_id).has(old),
		"roster_dm_new": m.roster(dm).has(new_handle) and not m.roster(dm).has(old),
		"self_marker_on_new": marker_ok,
		"old_designation_surfaces": _count_containing(surfaces, old),
		"surfaces_checked": surfaces.size(),
		"nav_shows_new": String(ui[0]).contains(new_handle) and not String(ui[0]).contains(old),
		"presence_line": presence,
		"profile_handle_saved": String(saved["profile"].get("player", {}).get("handle", "")) == new_handle,
		"invalid": {"tried": tried, "rejected": rejected, "kinds": kinds.keys()},
		"accepted_after_invalid": m.self_handle == new_handle,
		"control_old_designation_detected": _count_containing(Array(planted), old) > _count_containing(surfaces, old),
	}


## --- funnel_refuse ----------------------------------------------------------------------------------------------------

func _roster_rooms_with(handle: String) -> int:
	var n := 0
	for rid in cr.model.room_order:
		if (cr.model.rooms[rid]["present"] as Array).has(handle):
			n += 1
	return n


func _presence_rows(text_part: String, handle: String) -> int:
	var n := 0
	for rid in cr.model.room_order:
		for r in cr.model.rows_of(rid):
			if String(r["kind"]) == "presence" and String(r["text"]).contains(handle) and String(r["text"]).contains(text_part):
				n += 1
	return n


func _swap_index() -> int:
	for i in range(cr.emission_log.size()):
		if String(cr.emission_log[i].get("kind", "")) == "swap":
			return i
	return -1


func _faction_addressing() -> Dictionary:
	var rows := 0
	var dms := 0
	var names := [cr.model.self_handle, String(cr.profile_snapshot()["player"]["designation"])]
	for e in cr.emission_log:
		if int(e["beat"]) in [Chatroom.Beat.AMBIENT, Chatroom.Beat.RESPONDER, Chatroom.Beat.DM] and cr.model.side_of(String(e["handle"])) == "faction":
			for n in names:
				if String(e["plain"]).to_lower().contains(String(n).to_lower()):
					rows += 1
	for id in cr.model.buffers:
		if cr.model.is_dm(String(id)) and cr.model.side_of(String(cr.model.buffers[id]["title"])) == "faction":
			dms += 1
	return {"rows": rows, "dms": dms}


func _mode_refuse() -> void:
	_think_ms = 3000
	_type_ms = 60
	var cfg := _cfg()
	var room_id := String(cr.room_script().get("entry_room", ""))
	# --- silence after a refusal at the ask, then speaking in a room
	await open_session(SEED_BASE + 700)
	await send(HELLO, _type_ms)
	await play({}, func(): return at_stage_waiting("ask"))
	var refused_at := cr.funnel.stage_id()
	var old_name := handler()
	await goto(thread_buffer())
	var req0 := cr.model_requests
	var w0 := shell.world_request_count
	await send("no thanks", 0)
	for i in range(30):
		await step()
		if _swap_index() >= 0:
			break
	var swap_i := _swap_index()
	var new_name := handler()
	var req_swap := cr.model_requests
	var t_silence := cr.now_ms()
	var silence_target := 610000
	var ambient0 := cr.emission_log.size()
	while cr.now_ms() - t_silence < silence_target:
		await step()
	var silence_ms := cr.now_ms() - t_silence
	var old_after := 0
	var new_clear := 0
	var ambient_after := 0
	for i in range(swap_i + 1, cr.emission_log.size()):
		var e: Dictionary = cr.emission_log[i]
		if String(e["handle"]) == old_name:
			old_after += 1
		if String(e["handle"]) == new_name and int(e["beat"]) == Chatroom.Beat.CONTACT:
			new_clear += 1
		if int(e["beat"]) == Chatroom.Beat.AMBIENT:
			ambient_after += 1
	var silent := {
		"refused_at": refused_at,
		"disengage_beat": count_fkind("disengage") >= 1,
		"handler_rows_after": old_after,
		"ambient_rows_after": ambient_after,
		"silence_ms": silence_ms,
		"new_approaches": new_clear,
		"dm_replies_from_former": old_after,
		"world_requests": shell.world_request_count - w0,
		"model_requests_after": cr.model_requests - req_swap,
		"profile_accepted": bool(cr.profile_snapshot()["acceptance"]["accepted"]),
	}
	# --- the same player speaks in a room: a new Empire handler approaches
	await goto(room_id)
	var spoke_at := cr.now_ms()
	var log_at := cr.emission_log.size()
	await send("hello again", 0)
	var approach := {}
	for i in range(90):
		await step()
		for j in range(log_at, cr.emission_log.size()):
			var e2: Dictionary = cr.emission_log[j]
			if String(e2["handle"]) == new_name and String(e2.get("fkind", "")) == "open" and String(e2.get("stage", "")) == "contact":
				approach = e2
				break
		if not approach.is_empty():
			break
	silent["control_speak_would_approach"] = not approach.is_empty()
	_out["refuse_silent"] = silent
	var req_at_approach := cr.model_requests
	var approaches := 0
	for j in range(log_at, cr.emission_log.size()):
		if String(cr.emission_log[j]["handle"]) == new_name and String(cr.emission_log[j].get("beat_id", "")) == "b_contact_open":
			approaches += 1
	var stage_after := cr.funnel.stage_id()
	var qualify_beats0 := 0
	for e in cr.emission_log:
		if String(e["handle"]) == new_name and ["b_q_where", "b_q_doing"].has(String(e.get("beat_id", ""))):
			qualify_beats0 += 1
	await play({}, func(): return cr.funnel.stage_id() == "pushback" and cr.funnel.pending_wait())
	var qualify_after := 0
	for e in cr.emission_log:
		if String(e["handle"]) == new_name and ["b_q_where", "b_q_doing"].has(String(e.get("beat_id", ""))):
			qualify_after += 1
	var prof := cr.profile_snapshot()
	var old_rows_after := 0
	for i in range(swap_i + 1, cr.emission_log.size()):
		if String(cr.emission_log[i]["handle"]) == old_name:
			old_rows_after += 1
	_out["refuse_speak"] = {
		"old": old_name,
		"new": new_name,
		"new_in_former": (prof["handler"]["former"] as Array).has(new_name),
		"new_side": cr.model.side_of(new_name),
		"approach_in_room": not approach.is_empty() and cr.model.is_room(String(approach.get("buffer", ""))),
		"approaches": approaches,
		"approach_delay_ms": int(approach.get("t_ms", -1)) - spoke_at if not approach.is_empty() else -1,
		"old_in_rosters": _roster_rooms_with(old_name),
		"new_in_all_rosters": _roster_rooms_with(new_name),
		"old_rows_after_swap": old_rows_after,
		"new_looks_ordinary": HandlerNames.looks_ordinary(new_name),
		"stage_after_approach": stage_after,
		"former_len": (prof["handler"]["former"] as Array).size(),
		"profile_handler": String(prof["handler"]["name"]),
		"qualify_skipped_when_known": qualify_after == qualify_beats0,
		"join_line_for_new": _presence_rows("HAS JOINED", new_name) >= 1,
		"leave_line_for_old": _presence_rows("HAS LEFT", old_name) >= 1,
		"model_requests_before_approach": req_at_approach - req_swap,
	}
	var fa := _faction_addressing()
	var faction_rows: int = int(fa["rows"])
	var faction_dms: int = int(fa["dms"])
	# --- a lapse: every follow-up unanswered
	await open_session(SEED_BASE + 710)
	await send(HELLO, _type_ms)
	await play({}, func(): return at_stage_waiting("ask"))
	var max_f: int = int(cfg["stages"][6]["max_idle_followups"])
	var req_wait := cr.model_requests
	var w1 := shell.world_request_count
	var lapse_t0 := cr.now_ms()
	var limit: int = int(cfg["stages"][6]["idle_ms"]) * (max_f + 3)
	while cr.now_ms() - lapse_t0 < limit and cr.funnel.outcome != Funnel.OUT_LAPSED:
		await step()
	var fired := count_fkind("idle_followup")
	var req_idle := cr.model_requests - req_wait
	var lapsed_followups := cr.funnel.idle_lapse_followups
	var lapse_swap := _swap_index()
	var new_after_lapse := handler()
	for i in range(120):
		await step()
	var unspoken := 0
	for e in cr.emission_log:
		if String(e["handle"]) == new_after_lapse and int(e["beat"]) == Chatroom.Beat.CONTACT:
			unspoken += 1
	_out["lapse"] = {
		"followups_fired": fired,
		"model_requests_during_idle": req_idle,
		"disengaged": cr.funnel.outcome == Funnel.OUT_LAPSED,
		"disengaged_after_followups": lapsed_followups,
		"max_followups": max_f,
		"world_requests": shell.world_request_count - w1,
		"new_approaches_without_speech": unspoken if lapse_swap >= 0 else 0,
	}
	# --- a chain of refusals
	await open_session(SEED_BASE + 720)
	await send(HELLO, _type_ms)
	var names: Array = []
	var empire_seen := {}
	var refusals := 0
	for round in range(4):
		await play({}, func(): return at_stage_waiting("pushback"))
		names.append(handler())
		empire_seen[handler()] = cr.model.side_of(handler()) == "empire"
		await goto(thread_buffer())
		await send("no thanks", 0)
		var before := handler()
		for i in range(30):
			await step()
			if handler() != before:
				break
		refusals += 1
		await goto(room_id)
		await send("hello again", 0)
		for i in range(60):
			await step()
			if cr.funnel.stage_id() == "contact" and cr.funnel.active():
				break
	names.append(handler())
	empire_seen[handler()] = cr.model.side_of(handler()) == "empire"
	var distinct := {}
	var all_empire := true
	var none_eq := true
	var designation := String(cr.profile_snapshot()["player"]["designation"])
	for n in names:
		distinct[String(n)] = true
		all_empire = all_empire and bool(empire_seen.get(String(n), false))
		none_eq = none_eq and String(n).to_upper() != designation.to_upper()
	_out["chain"] = {
		"refusals": refusals,
		"names": names,
		"all_distinct": distinct.size() == names.size(),
		"all_empire": all_empire,
		"former_len": (cr.profile_snapshot()["handler"]["former"] as Array).size(),
		"none_equal_designation": none_eq,
	}
	var fa2 := _faction_addressing()
	_out["faction_initiations"] = faction_rows + int(fa2["rows"])
	_out["faction_dm_initiations"] = faction_dms + int(fa2["dms"])


## --- funnel_persist ---------------------------------------------------------------------------------------------------

func _profile_file_facts() -> Dictionary:
	var loaded := ProfileStore.load_profile()
	var p: Dictionary = loaded["profile"]
	var keys: Array = p.keys()
	keys.sort()
	var re := RegEx.new()
	re.compile("^newb[0-9]{4}$")
	return {
		"schema": int(p.get("schema", 0)),
		"assignments_len": (p.get("assignments", []) as Array).size(),
		"handler_kind": String(p.get("handler", {}).get("kind", "")),
		"designation_ok": re.search(String(p.get("player", {}).get("designation", ""))) != null,
		"keys": keys,
	}


func _mode_persist() -> void:
	var tag := OS.get_environment("DECOHERENCE_PROBE_TAG")
	if tag != "R":
		d._cr_say("chat")
		await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
		await d._wait_frames(3)
		_out = {
			"tag": tag,
			"seed": cr.session_seed(),
			"xdg": OS.get_environment("XDG_DATA_HOME"),
			"handler": handler(),
			"designation": cr.session_handle(),
			"handler_in_rosters": _roster_rooms_with(handler()),
			"designation_in_roster": cr.model.roster(cr.model.active).has(cr.session_handle()),
			"profile": _profile_file_facts(),
		}
		return
	# the resume rules and the per-player facts, in one process
	var names := {}
	var seeds := [11, 22, 33, 44, 55, 66]
	for s in seeds:
		cr.reset_session(int(s))
		names[handler()] = true
	cr.reset_session(777)
	var path := ProjectSettings.globalize_path(ProfileStore.PROFILE_FILE)
	var mtime0 := FileAccess.get_modified_time(path)
	var hash0 := FileAccess.get_file_as_string(ProfileStore.PROFILE_FILE).sha256_text()
	cr.sim_enable(0)
	d._cr_say("chat")
	await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
	await d._wait_frames(3)
	await send("hello there", 0)
	for i in range(5):
		await step()
	d._cr_say("leave")
	await d._wait_frames(3)
	d._cr_say("chat")
	await d._wait_frames(5)
	var written_once: bool = FileAccess.get_modified_time(path) == mtime0 and FileAccess.get_file_as_string(ProfileStore.PROFILE_FILE).sha256_text() == hash0
	d._cr_say("leave")
	await d._wait_frames(3)
	_out["seeds_distinct_names"] = {"players": seeds.size(), "distinct": names.size()}
	_out["profile_written_once_at_first_launch"] = written_once
	_out["profile_files"] = [_profile_file_facts()]
	_out["resume"] = await _resume_cases()


## A restart with the saved profile in a given state.
func _restart_with(accepted: bool, handle: String, launched: bool, seed_value: int) -> void:
	var p := cr.profile_snapshot()
	p["acceptance"]["accepted"] = accepted
	p["acceptance"]["handler"] = String(p["handler"]["name"]) if accepted else ""
	p["acceptance"]["handle"] = handle
	p["acceptance"]["launched"] = launched
	p["player"]["handle"] = handle
	ProfileStore.save_profile(p)
	await open_session_keep(seed_value)


func open_session_keep(seed_value: int) -> void:
	await _leave_module()
	if cr.is_inside():
		d._cr_say("leave")
		await d._wait_frames(3)
	cr.reset_session(seed_value, true)
	cr.sim_enable(0)
	d._cr_say("chat")
	await d._wait_for(func(): return d._cc().is_mounted(), 8.0)
	await d._wait_frames(3)


func _beat_rows(ids: Array) -> int:
	var n := 0
	for e in cr.emission_log:
		if ids.has(String(e.get("beat_id", ""))):
			n += 1
	return n


func _resume_cases() -> Dictionary:
	_think_ms = 3000
	_type_ms = 60
	var res := {}
	cr.reset_session(900)
	await _restart_with(true, "", false, 901)
	var stage_a := cr.funnel.stage_id()
	await send(HELLO, 0)
	await play({}, func(): return _beat_rows(["b_rn_open"]) >= 1, 400000)
	res["after_accept_no_handle"] = {"stage": stage_a, "ask_replayed": _beat_rows(["b_ask_open"]) > 0}
	await _restart_with(true, "Ember_77", false, 902)
	var stage_b := cr.funnel.stage_id()
	await send(HELLO, 0)
	await play({}, func(): return false, 600000)
	res["after_handle_before_launch"] = {"stage": stage_b, "rename_replayed": _beat_rows(["b_rn_open", "b_rename_do", "b_ask_open"]) > 0}
	# mid-funnel before consent: play to the pitch, leave, come back with the saved profile
	await open_session(903)
	var handler_before := handler()
	await send(HELLO, _type_ms)
	await play({}, func(): return cr.funnel.stage_id() == "pitch" and cr.funnel.pending_wait(), 900000)
	await open_session_keep(904)
	var same_handler := handler() == handler_before
	await send(HELLO, 0)
	await play({}, func(): return _beat_rows(["b_contact_open"]) >= 1, 300000)
	res["mid_funnel_before_accept"] = {"stage": cr.funnel.stage_id(), "handler_same": same_handler}
	# a player who has launched before: the funnel is inert, her direct message is answered from the done lines
	var name_before := handler()
	await _restart_with(true, "Ember_77", true, 905)
	var w0 := shell.world_request_count
	await send(HELLO, 0)
	for i in range(8):
		await step()
	await send("/msg %s are you there" % handler(), 0)
	var dm := dm_buffer()
	for i in range(20):
		await step()
	var done_texts: Array = []
	for b in cr.funnel.beats_of("done_reply"):
		done_texts.append(cr.funnel.render(String(b["plain"])))
	var done_ok := false
	for r in cr.model.rows_of(dm):
		if done_texts.has(String(r["text"])):
			done_ok = true
	var spoken := 0
	for e in cr.emission_log:
		if int(e["beat"]) == Chatroom.Beat.CONTACT and String(e.get("fkind", "")) != "done_reply":
			spoken += 1
	res["accepted_restart"] = {
		"funnel_beats_spoken": spoken,
		"self_handle_is_chosen": cr.model.self_handle == "Ember_77",
		"handler_in_rosters": _roster_rooms_with(handler()),
		"handler_name_same": handler() == name_before,
		"done_replies_scripted": done_ok,
		"model_requests": cr.model_requests,
		"world_requests": shell.world_request_count - w0,
		"assignments_len": (cr.profile_snapshot()["assignments"] as Array).size(),
	}
	return res


## --- funnel_memory ---------------------------------------------------------------------------------------------------------

const CANARIES := ["CANARY_ALPHA_01", "CANARY_BRAVO_02", "CANARY_CHARLIE_03", "CANARY_DELTA_04", "CANARY_ECHO_05", "CANARY_FOXTROT_06", "CANARY_GOLF_07"]
const LONG_ANSWER := "i live somewhere far north where the winters are long and dark and cold CANARY_ANSWER_TAIL"


func _text_files_under(dir: String, out: Array) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		out.append(dir.path_join(f))
	for sub in da.get_directories():
		_text_files_under(dir.path_join(sub), out)


func _count_in_files(needle: String, except: String) -> int:
	var files: Array = []
	_text_files_under("user://", files)
	var n := 0
	for p in files:
		if String(p) == except or String(p).ends_with(".log"):
			continue
		var fa := FileAccess.open(String(p), FileAccess.READ)
		if fa == null or fa.get_length() > 2000000:
			continue
		if fa.get_as_text().contains(needle):
			n += 1
	return n


func _last_system() -> String:
	for m in cr.last_messages:
		if String(m["role"]) == "system":
			return String(m["content"])
	return ""


func _mode_memory() -> void:
	_think_ms = 2500
	_type_ms = 50
	var cfg := _cfg()
	var dcfg: Dictionary = cfg["dossier"]
	var prof := {"origin": LONG_ANSWER, "contact": CANARIES[0], "pushback": CANARIES[1], "dm": CANARIES[2], "pitch": CANARIES[3]}
	d._cr_set_mode("funnel_ok")
	await open_session(SEED_BASE + 800)
	await send(HELLO, _type_ms)
	await play(prof, func(): return cr.funnel.stage_id() == "dm" and cr.funnel.pending_wait() and not cr.is_busy())
	var dm := dm_buffer()
	await goto(dm)
	for i in range(4, 7):
		await send(CANARIES[i], 0)
		for k in range(3):
			await step()
	var text := FileAccess.get_file_as_string(ProfileStore.DOSSIER_FILE)
	var parsed = JSON.parse_string(text)
	var fields: Dictionary = parsed["fields"] if typeof(parsed) == TYPE_DICTIONARY else {}
	var keys_ok := true
	var max_len := 0
	for k in fields:
		keys_ok = keys_ok and (dcfg["fields"] as Array).has(String(k))
		max_len = maxi(max_len, String(fields[k]).length())
	var canary_hits := 0
	for c in CANARIES:
		if text.contains(String(c)):
			canary_hits += 1
	var origin_value := String(fields.get("origin", ""))
	var control := text + CANARIES[0]
	var profile_text := FileAccess.get_file_as_string(ProfileStore.PROFILE_FILE)
	var top_keys: Array = (parsed as Dictionary).keys() if typeof(parsed) == TYPE_DICTIONARY else []
	top_keys.sort()
	var file := {
		"under_user_data_dir": ProfileStore.DOSSIER_FILE.begins_with("user://") and ProjectSettings.globalize_path(ProfileStore.DOSSIER_FILE).begins_with(OS.get_environment("XDG_DATA_HOME")),
		"exists": FileAccess.file_exists(ProfileStore.DOSSIER_FILE),
		"bytes": text.to_utf8_buffer().size(),
		"keys_allowed": keys_ok,
		"max_value_len": max_len,
		"transcript_keys": 0 if top_keys == ["fields", "schema"] else 1,
		"canary_lines_typed": CANARIES.size(),
		"canary_in_file": canary_hits,
		"answer_canary_in_file_truncated": origin_value.length() > 0 and origin_value.length() <= 60 and LONG_ANSWER.begins_with(origin_value) and not text.contains("CANARY_ANSWER_TAIL"),
		"control_canary_detected": control.contains(CANARIES[0]) and not text.contains(CANARIES[0]),
		"separate_from_profile": not profile_text.contains(origin_value) and ProfileStore.DOSSIER_FILE != ProfileStore.PROFILE_FILE,
	}
	# the wipe, typed through the client
	var designation_before := String(cr.profile_snapshot()["player"]["designation"])
	var forget0 := count_fkind("forget")
	var cb0 := count_fkind("callback")
	var open0 := count_fkind("open")
	await goto(dm)
	await send("/forget", 0)
	for i in range(30):
		await step()
		if count_fkind("forget") > forget0:
			break
	var gone := not FileAccess.file_exists(ProfileStore.DOSSIER_FILE) or (ProfileStore.load_dossier()["fields"] as Dictionary).is_empty()
	var profile_ok := String(ProfileStore.load_profile()["profile"].get("player", {}).get("designation", "")) == designation_before
	await goto(dm)
	await send("tell me more please", 0)
	for i in range(6):
		await step()
	var prompt_blob := ""
	for m in cr.last_messages:
		prompt_blob += String(m["content"]) + "\n"
	var prompt_has_old: bool = prompt_blob.contains(origin_value.substr(0, 20)) or prompt_blob.contains(CANARIES[2])
	prof = {"pitch": "that makes sense, tell me more"}
	await play(prof, func(): return cr.funnel.stage_id() == "ask", 900000)
	_out["file"] = file
	_out["wipe"] = {
		"driven_by_key_events": direct_calls == 0 and keys_driven > 0,
		"file_gone_or_empty": gone,
		"profile_intact": profile_ok,
		"callbacks_after": count_fkind("callback") - cb0,
		"prompt_has_old_value": prompt_has_old,
		"slot_leaks": slot_leaks(),
		"handler_still_acts": count_fkind("open") > open0,
		"forget_line_spoken_by_handler": count_fkind("forget") > forget0,
	}
	# evasive and made-up answers advance her like any other
	var evasive := ["not telling you", "i would rather not say", "none of your business"]
	var eprof := {"contact": evasive[0], "origin": evasive[1], "doing": evasive[2]}
	await open_session(SEED_BASE + 810)
	await send(HELLO, _type_ms)
	var advanced := 0
	var answers := 0
	var stalled := 0
	for stage_name in ["contact", "qualify", "qualify"]:
		await play(eprof, func(): return cr.funnel.stage_id() == stage_name and cr.funnel.pending_wait() and not cr.is_busy())
		var rows0 := handler_rows().size()
		var line := await _agent_force(eprof)
		answers += 1
		var moved := false
		for i in range(90):
			await step()
			if handler_rows().size() > rows0 + 1:
				moved = true
				break
		if moved:
			advanced += 1
		else:
			stalled += 1
	var q_asked := _beat_rows(["b_q_where"]) + _beat_rows(["b_q_doing"])
	_out["evasive"] = {"answers": answers, "advanced": advanced, "stalled": stalled, "reasks": maxi(q_asked - 2, 0)}
	cb0 = count_fkind("callback")
	await play(eprof, func(): return cr.funnel.stage_id() == "ask", 900000)
	var cb_rows: Array = []
	for e in cr.emission_log:
		if String(e.get("fkind", "")) == "callback":
			cb_rows.append(String(e["plain"]))
	var contains_value := false
	for t in cb_rows:
		if String(t).contains(evasive[1]) or String(t).contains(evasive[2]):
			contains_value = true
	var sys := _last_system()
	var heading_at := sys.find("YOUR NOTE ON THEM")
	var only_note := heading_at >= 0
	for v in [evasive[1], evasive[2]]:
		var at := sys.find(String(v))
		while at >= 0:
			if at < heading_at:
				only_note = false
			at = sys.find(String(v), at + 1)
	_out["callback"] = {
		"spoken": cb_rows.size(),
		"contains_value": contains_value,
		"unresolved_slots": slot_leaks(),
		"after_empty_dossier_skipped": int(_out["wipe"]["callbacks_after"]) == 0,
	}
	var log: Array = d._cr_fake_structured()
	var other_files := _count_in_files(evasive[1], ProfileStore.DOSSIER_FILE) + _count_in_files(evasive[2], ProfileStore.DOSSIER_FILE)
	_out["local"] = {
		"endpoint_host": String(llm._endpoint()["host"]),
		"non_loopback_requests": 0 if String(llm._endpoint()["host"]) == "127.0.0.1" else log.size(),
		"requests_seen": log.size(),
		"dossier_in_other_files": other_files,
	}
	_out["prompt"] = {"dossier_values_only_in_operational_slots": only_note}


## Sends the scripted line for the current stage right now (no think time).
func _agent_force(prof: Dictionary) -> String:
	var line := line_for(prof)
	await goto(thread_buffer())
	await send(line, _type_ms)
	return line


## --- funnel_canon ----------------------------------------------------------------------------------------------------------

const CANON_CHROME := "(?i)handler|recruit|contact|liaison|objective|quest|mission|tutorial|wizard|onboard|walkthrough|getting started|beginner|newcomer|briefing|assigned|progress|checklist|hint|tip:|try typing|welcome|guide|help"
const CANON_PROGRESS := "(?i)progress|checklist|learned|ticked|tick off|\\[x\\]|[0-9]+ ?/ ?[0-9]+ ?(steps|stages|done|complete)|step [0-9]|stage [0-9]|try typing|you can (ask|type)|hint|tutorial|tip:|objective|quest|percent|%"
const CANON_IDENT := "ENGAGED|LAUNCH|FUNNEL|funnel|\\bf_[a-z_]+\\b|\\bb_[a-z_]+\\b|channel7|chatroom_|first_player_message|lurk|pushback"


func _regex_hits(pattern: String, texts: Array) -> int:
	var re := RegEx.new()
	re.compile(pattern)
	var n := 0
	for t in texts:
		if re.search(String(t)) != null:
			n += 1
	return n


## Whether a by-stage table reads as clearance: the checks the DoD asks of it, applied to a
## real table and to planted ones.
func _legibility_ok(by_stage: Array) -> Dictionary:
	var e: Array = by_stage.map(func(s): return float(s["empire_readable"]))
	var rises := 0
	var mono := true
	for i in range(1, e.size()):
		if e[i] < e[i - 1] - 0.05:
			mono = false
		if e[i] >= e[i - 1] + 0.03:
			rises += 1
	var faction_clear := 0
	for s in by_stage:
		faction_clear += int(s["faction_readable"])
	return {"spread": e[e.size() - 1] - e[0], "monotone": mono, "rises": rises, "faction_clear": faction_clear}


var _chrome_acc: Array = []
var _dialogue_acc: Array = []


func _collect_stage_rows(stage_index: int) -> Dictionary:
	cr.funnel.stage = stage_index
	var mark := cr.emission_log.size()
	var emp := 0
	var emp_clear := 0
	var fac := 0
	var fac_clear := 0
	var rooms_seen := {}
	for i in range(160):
		await step()
		for j in range(mark, cr.emission_log.size()):
			var e: Dictionary = cr.emission_log[j]
			if not (int(e["beat"]) in [Chatroom.Beat.AMBIENT, Chatroom.Beat.RESPONDER, Chatroom.Beat.DM]):
				continue
			var side := cr.model.side_of(String(e["handle"]))
			rooms_seen[String(e["buffer"])] = true
			if bool(e.get("clear", false)):
				_dialogue_acc.append(String(e["plain"]))
			if side == "empire":
				emp += 1
				if bool(e.get("clear", false)):
					emp_clear += 1
			elif side == "faction":
				fac += 1
				if bool(e.get("clear", false)):
					fac_clear += 1
		mark = cr.emission_log.size()
		if emp >= 40 and fac >= 40 and rooms_seen.size() >= 5:
			break
	var ui: Array = d._cc().ui_text_snapshot()
	for pane in ["nav", "side", "people", "status"]:
		for line in d._cc_pane(ui, pane):
			if not String(line).strip_edges().is_empty():
				_chrome_acc.append(String(line).strip_edges())
	return {"stage": STAGES[stage_index], "empire_rows": emp, "faction_rows": fac, "empire_readable": float(emp_clear) / float(maxi(emp, 1)), "faction_readable": fac_clear, "faction_scrambled_rows": fac - fac_clear, "rooms": rooms_seen.size()}


func _mode_canon() -> void:
	_think_ms = 3000
	_type_ms = 60
	d._cr_set_mode("funnel_ok")
	# --- clearance by stage: every room joined, the stage forced, rows counted by side
	await open_session(SEED_BASE + 900)
	for rid in cr.model.room_order:
		if not bool(cr.model.rooms[rid]["joined"]):
			await send("/join " + String(rid), 0)
	var by_stage: Array = []
	var all_rooms := true
	for i in range(9):
		var row: Dictionary = await _collect_stage_rows(i)
		all_rooms = all_rooms and int(row["rooms"]) >= 5
		by_stage.append(row)
	var real := _legibility_ok(by_stage)
	var flat := by_stage.duplicate(true)
	for s in flat:
		s["empire_readable"] = 0.5
	var clear_fac := by_stage.duplicate(true)
	clear_fac[3]["faction_readable"] = 4
	var flat_res := _legibility_ok(flat)
	var fac_res := _legibility_ok(clear_fac)
	# --- the roster, at every stage, in every room
	var sigs := {}
	var samples := 0
	var marker_free := true
	for i in range(9):
		cr.funnel.stage = i
		for rid in cr.model.room_order:
			for en in ChatModel.roster_entries(cr.model, String(rid)):
				if String(en["handle"]) == cr.model.self_handle:
					continue
				sigs[ChatModel.style_signature(en)] = true
				if String(en["handle"]) == handler() and String(en["marker"]) != "":
					marker_free = false
		samples += 1
	cr.funnel.stage = 0
	# --- a whole funnel, read for what the player is shown
	var rec := await run_profile("typical", SEED_BASE + 910, "", {"pushback": "what is this place"})
	await reenter_chat()
	await send("/msg XEN-4 hi there", 0)
	var req_dm := cr.model_requests
	for i in range(8):
		await step()
	var dm_rows: Array = cr.model.rows_of("dm:XEN-4")
	var cfg := _cfg()
	var withheld: Array = cfg["guard"]["withheld_until_pitch"]
	var twist: Array = cfg["guard"]["twist_words"]
	var pitch_i := STAGES.find("pitch")
	var chrome: Array = []
	var ui_data: Dictionary = ChatroomScript.read_json(ChatroomScript.data_dir() + "/client_ui.json")
	for k in ui_data["strings"]:
		chrome.append(String(ui_data["strings"][k]))
	for it in ui_data["nav"]["items"]:
		chrome.append(String(it["label"]))
		chrome.append(String(it["key"]))
	chrome.append(String(ui_data["nav"]["brand"]))
	var ui: Array = d._cc().ui_text_snapshot()
	var layout: Dictionary = d._cc().layout_snapshot()
	for pane in ["nav", "side", "people", "status"]:
		for line in d._cc_pane(ui, pane):
			if not String(line).strip_edges().is_empty():
				chrome.append(String(line).strip_edges())
	chrome.append(String(ui[1]).substr(0, 60))
	chrome.append_array(_chrome_acc)
	var dialogue: Array = _dialogue_acc.duplicate()
	var handler_text: Array = _dialogue_acc.duplicate()
	var where_what_pre := 0
	var plants := 0
	var withhold_spoken := 0
	for e in cr.emission_log:
		if int(e["beat"]) == Chatroom.Beat.CONTACT:
			handler_text.append(String(e["plain"]))
			if STAGES.find(String(e.get("stage", ""))) < pitch_i and _text_has_any(String(e["plain"]), withheld):
				where_what_pre += 1
			if String(e.get("beat_id", "")) == "b_pitch_twist":
				plants += 1
			if String(e.get("fkind", "")) == "withhold":
				withhold_spoken += 1
		if bool(e.get("clear", false)) and int(e["beat"]) != Chatroom.Beat.PRESENCE:
			dialogue.append(String(e["plain"]))
	var all_text: Array = []
	for r in all_rows():
		all_text.append(String(r["text"]))
	for line in ui:
		all_text.append(String(line))
	var fa := _faction_addressing()
	var launched := cr.grant_ms >= 0
	_out["legible"] = {
		"by_stage": by_stage,
		"handler_rows_clear_after_contact": _all_clear(),
		"handler_style_signature_equals_others": sigs.size() == 1,
		"control_flat_ratio_detected": int(flat_res["rises"]) < 5,
		"control_faction_clear_detected": int(fac_res["faction_clear"]) > 0,
		"analysis": real,
	}
	_out["canon"] = {
		"chrome_strings_scanned": chrome.size(),
		"chrome_concept_hits": _regex_hits(CANON_CHROME, chrome),
		"stage_or_progress_surface_hits": _regex_hits(CANON_PROGRESS, chrome),
		"identifier_hits": _regex_hits(CANON_IDENT, all_text),
		"chrome_control_hit_detected": _regex_hits(CANON_CHROME, ["HANDLER CONTACT"]) == 1,
		"progress_control_hit_detected": _regex_hits(CANON_PROGRESS, ["STEP 3 OF 9  3/9 steps"]) == 1,
		"roster_rooms_checked": cr.model.room_order.size(),
		"roster_style_signatures_all_stages": sigs.size(),
		"roster_style_stage_samples": samples,
		"contact_marker_free": marker_free,
		"faction_initiations": int(fa["rows"]),
		"faction_dm_before_launch": int(fa["dms"]),
		"non_empire_addresses_player": int(fa["rows"]),
		"dialogue_rows_scanned": dialogue.size(),
		"twist_stated_hits": _count_has_any(handler_text, twist),
		"twist_control_hit_detected": _text_has_any("you are the quantum intelligence", twist),
		"plant_beats_spoken": plants,
		"handler_says_where_what_before_pitch": where_what_pre,
		"where_what_control_detected": _text_has_any("the Empire runs a planet", withheld),
		"withhold_timing_lines_spoken": withhold_spoken,
		"dm_to_ambient_still_scripted": dm_rows.size() >= 2 and cr.model_requests == req_dm and launched,
		"ambient_in_all_rooms_all_stages": all_rooms,
		"run": {"elapsed_ms": rec["elapsed_ms"]},
	}


func _text_has_any(text: String, words: Array) -> bool:
	var flat := " " + ChatroomScript.normalize(text) + " "
	for w in words:
		var n := ChatroomScript.normalize(String(w))
		if not n.is_empty() and flat.contains(" " + n + " "):
			return true
	return false


func _count_has_any(texts: Array, words: Array) -> int:
	var n := 0
	for t in texts:
		if _text_has_any(String(t), words):
			n += 1
	return n


func _all_clear() -> bool:
	var seen := 0
	for e in cr.emission_log:
		if int(e["beat"]) == Chatroom.Beat.CONTACT and String(e.get("fkind", "")) != "":
			seen += 1
			if not bool(e.get("clear", false)):
				return false
	return seen > 0


## --- funnel_nolie and the leak battery on the fake model ------------------------------------------------------------------

const LIE_MODES := ["lie_number", "lie_name", "lie_denial", "lie_denial_contracted", "lie_secret", "lie_unknown_claim", "lie_early_where_what", "twist_stated", "extra_act_key", "claims_missing"]


func _fake_replies() -> Array:
	var out: Array = []
	var f := FileAccess.open(OS.get_environment("CHATROOM_FAKE_LOG"), FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("reply"):
			out.append(parsed)
	f.close()
	return out


func _any_row_contains(needle: String) -> bool:
	for r in all_rows():
		if needle != "" and String(r["text"]).contains(needle):
			return true
	return false


## One model turn on the fake in `mode`, with the funnel held where it is. Returns what happened.
func _fake_turn(mode: String, line: String) -> Dictionary:
	d._cr_set_mode(mode)
	var rej0 := cr.rejected_replies
	var acc0 := cr.accepted_replies
	var fb0 := count_fkind("fallback")
	var model0 := count_fkind("model")
	var replies0 := _fake_replies().size()
	await goto(thread_buffer())
	await send(line, 0)
	for k in range(30):
		await step()
		if (cr.accepted_replies > acc0 and count_fkind("model") > model0) or (cr.rejected_replies > rej0 and count_fkind("fallback") > fb0):
			break
	await step()
	d._cr_set_mode("funnel_ok")
	var replies := _fake_replies()
	var say := ""
	if replies.size() > replies0:
		say = String(replies[replies.size() - 1]["reply"].get("say", ""))
	return {"rejected": cr.rejected_replies - rej0, "accepted": cr.accepted_replies - acc0, "fallback": count_fkind("fallback") - fb0, "model_rows": count_fkind("model") - model0, "reason": String(cr.last_verdict.get("reason", "")), "say": say, "reasoning": llm.last_reasoning_chars}


func _prompt_check() -> Dictionary:
	var briefing: Dictionary = ChatroomScript.read_json(ChatroomScript.data_dir() + "/handler_briefing.json")
	var ids: Array = Funnel.stage_ids(_cfg())
	var sys := _last_system()
	var want: Array = []
	var locked := 0
	for f in briefing["facts"]:
		if ids.find(String(f["from_stage"])) <= cr.last_prompt_stage:
			want.append(String(f["id"]))
		elif sys.contains(String(f["text"])):
			locked += 1
	var got: Array = []
	var re := RegEx.new()
	re.compile("- \\((f_[a-z_]+)\\) ")
	for m in re.search_all(sys):
		got.append(m.get_string(1))
	var vocab := ""
	for f in briefing["facts"]:
		vocab += String(f["text"]) + " "
	vocab += JSON.stringify(ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel_beats.json")) + " " + sys.substr(0, maxi(sys.find("RULES:"), 0))
	var unlisted := 0
	var facts_block := sys.substr(maxi(sys.find("KNOWN FACTS"), 0))
	for line in facts_block.split("\n"):
		if not String(line).begins_with("- ("):
			continue
		var text := String(line).substr(String(line).find(") ") + 2)
		var prev_end := true
		for w in text.split(" ", false):
			var word := String(w).rstrip(".,!?;:")
			if not prev_end and word.length() > 1 and word.unicode_at(0) >= 65 and word.unicode_at(0) <= 90 and not vocab.contains(word):
				unlisted += 1
			prev_end = String(w).ends_with(".") or String(w).ends_with("!") or String(w).ends_with("?")
	return {"facts_ok": got == want, "locked": locked, "unlisted": unlisted, "want": want, "got": got, "stage": cr.last_prompt_stage}


func _mode_nolie() -> void:
	_think_ms = 2500
	_type_ms = 50
	var lies: Array = []
	var naive_all := true
	var prompt_ok := true
	var locked := 0
	var unlisted := 0
	for i in range(LIE_MODES.size()):
		var mode := String(LIE_MODES[i])
		await open_session(SEED_BASE + 1000 + i)
		d._cr_set_mode("funnel_ok")
		await send(HELLO, _type_ms)
		await play({}, func(): return at_stage_waiting("pushback"))
		var r: Dictionary = await _fake_turn(mode, "what do you mean")
		var pc := _prompt_check()
		if not bool(pc["facts_ok"]):
			_out["prompt_debug"] = pc
		prompt_ok = prompt_ok and bool(pc["facts_ok"])
		locked += int(pc["locked"])
		unlisted += int(pc["unlisted"])
		var say := String(r["say"])
		var naive := not say.is_empty()
		naive_all = naive_all and naive
		lies.append({"mode": mode, "rendered_lie": _any_row_contains(say), "fallback_rendered": int(r["fallback"]) >= 1, "rejected": int(r["rejected"]), "reason": String(r["reason"])})
	_out["lies"] = lies
	# honest replies: accepted, and rendered exactly once each
	await open_session(SEED_BASE + 1100)
	d._cr_set_mode("funnel_ok")
	await send(HELLO, _type_ms)
	await play({}, func(): return at_stage_waiting("pushback"))
	var accepted := 0
	var rendered := 0
	for line in ["go on", "i see", "and then", "tell me more", "right", "okay", "understood"]:
		var r2: Dictionary = await _fake_turn("funnel_ok", String(line))
		accepted += int(r2["accepted"])
		rendered += int(r2["model_rows"])
		var pc2 := _prompt_check()
		prompt_ok = prompt_ok and bool(pc2["facts_ok"])
		locked += int(pc2["locked"])
		unlisted += int(pc2["unlisted"])
	var rw: Dictionary = await _fake_turn("honest_withhold", "when can you tell me")
	var wh_ok := int(rw["accepted"]) >= 1 and _any_row_contains("when you can use it")
	var fields: Dictionary = cr.dossier_snapshot().get("fields", {})
	var only_note := true
	var sys := _last_system()
	var at_note := sys.find("YOUR NOTE ON THEM")
	for k in fields:
		var at := sys.find(String(fields[k]))
		if at >= 0 and (at_note < 0 or at < at_note):
			only_note = false
	var planted_row := "<%s> there are 47 colonists waiting" % handler()
	_out["honest"] = {"accepted": accepted + int(rw["accepted"]), "rendered": rendered + (1 if wh_ok else 0), "withhold_timing_accepted": 1 if wh_ok else 0}
	_out["prompt"] = {"facts_equal_briefing_for_stage": prompt_ok, "locked_fact_text_in_prompt": locked, "unlisted_proper_nouns": unlisted, "dossier_only_operational": only_note}
	_out["control"] = {"unguarded_would_render_all": naive_all, "planted_lie_rendered_detected": planted_row.contains("47 colonists")}
	_out["requests"] = d._cr_fake_structured().size()
	# the #615 leak rules, on the funnel's own forwarding path (a fresh session per mode,
	# so each reply is a real model turn at the pushback stage)
	var reasoning_min := 1 << 30
	var modes: Array = []
	var neg := {}
	var fallback_each := true
	var prompt_blob := ""
	var all_reasoning := ""
	var leak_rows: Array = []
	for pair in [["leaky_think", "think_marker", "neg_think_marker_rejected"], ["leaky_window", "reasoning_window", "neg_window_rejected"], ["leaky_fence", "code_fence", "neg_fence_rejected"]]:
		await open_session(SEED_BASE + 1200 + modes.size())
		d._cr_set_mode("funnel_ok")
		await send(HELLO, _type_ms)
		await play({}, func(): return at_stage_waiting("pushback"))
		var rl: Dictionary = await _fake_turn(String(pair[0]), "tell me more")
		modes.append(String(pair[0]))
		_out["leak_turn_" + String(pair[0])] = rl
		reasoning_min = mini(reasoning_min, int(rl["reasoning"]))
		neg[String(pair[2])] = String(rl["reason"]) == String(pair[1]) and int(rl["accepted"]) == 0
		fallback_each = fallback_each and int(rl["fallback"]) >= 1
		all_reasoning += " " + String(cr._reasoning_seen)
		for m in cr.last_messages:
			prompt_blob += String(m["content"]) + " "
		for r in all_rows():
			leak_rows.append(String(r["text"]))
	await open_session(SEED_BASE + 1210)
	d._cr_set_mode("funnel_ok")
	await send(HELLO, _type_ms)
	await play({}, func(): return at_stage_waiting("pushback"))
	var benign: Dictionary = await _fake_turn("funnel_ok", "go on please")
	var scanned := 0
	var leaks := 0
	for t in leak_rows + all_rows().map(func(r): return String(r["text"])):
		scanned += 1
		if d._cr_leak_scan(String(t), all_reasoning, prompt_blob):
			leaks += 1
	var buffer_rows := 0
	for r in d._cc().rows_snapshot():
		buffer_rows += 1
		if d._cr_leak_scan(String(r["text"]), "", ""):
			leaks += 1
	var streamed := 0
	for e in d._cr_fake_log():
		var b = e.get("body", null)
		if typeof(b) == TYPE_DICTIONARY and b.get("stream", false) == true:
			streamed += 1
	_out["leak"] = {
		"modes": modes,
		"runs": modes.size(),
		"reasoning_chars_min": reasoning_min,
		"rendered_rows_scanned": scanned,
		"buffer_rows_scanned": buffer_rows,
		"leaks": leaks,
		"fallback_rendered_for_each": fallback_each,
		"neg_think_marker_rejected": neg["neg_think_marker_rejected"],
		"neg_window_rejected": neg["neg_window_rejected"],
		"neg_fence_rejected": neg["neg_fence_rejected"],
		"benign_text_survives": int(benign["accepted"]) == 1 and int(benign["model_rows"]) == 1,
		"forward_path": "complete_structured" if d._cr_fake_structured().size() > 0 and streamed == 0 else "other",
		"send_chat_calls": streamed,
	}


## --- funnel_mutate ----------------------------------------------------------------------------------------------------------------

func _shingles(beats: Array) -> Array:
	var out: Array = []
	for b in beats:
		var words: PackedStringArray = String(b["plain"]).split(" ", false)
		if words.size() < 4 or String(b["plain"]).contains("{"):
			continue
		var sh := " ".join(words.slice(0, 4))
		if sh.length() >= 16 and not out.has(sh):
			out.append(sh)
	return out


func _beat_texts_rendered() -> Array:
	var out: Array = []
	for e in cr.emission_log:
		if int(e["beat"]) == Chatroom.Beat.CONTACT and String(e.get("fkind", "")) != "model":
			out.append(String(e["plain"]))
	for rid in cr.model.room_order:
		for r in cr.model.rows_of(String(rid)):
			if String(r["kind"]) == "presence":
				out.append(String(r["text"]))
	return out


func _mut_funnel(c):
	c["stages"][1]["legible_ratio"] = 0.9
	return c


func _off_funnel(c):
	c["enabled"] = false
	return c


func _mut_extra(f: String, data):
	if f == "funnel_beats.json":
		return _mutate_beats(f, data)
	if f == "funnel_names.json":
		data["onsets"] = ["QZ", "QV", "QX", "QW", "QY", "QK", "QJ", "QB", "QC", "QD", "QF", "QG", "QH", "QL", "QM", "QN", "QP", "QR", "QS", "QT", "QZZ", "QVV", "QXX", "QWW"]
		data["vowels"] = ["A"]
		data["codas"] = ["X", "XX", "XXX", "XQ", "XZ", "XV", "XK", "XM", "XN", "XP", "XR", "XS"]
		data["reserved"] = []
	return data


func _mutate_beats(file: String, data):
	if file != "funnel_beats.json":
		return data
	var i := 0
	var re := RegEx.new()
	re.compile("\\{[a-z_]+\\}")
	for b in data["beats"]:
		var slots: Array = []
		for m in re.search_all(String(b["plain"])):
			slots.append(m.get_string())
		b["plain"] = ("zq%s%dzq %s" % [String(b["stage"]), i, " ".join(slots)]).strip_edges()
		i += 1
	return data


func _mode_mutate() -> void:
	var original := OS.get_environment(ChatroomScript.ENV_DIR)
	var beats: Array = ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel_beats.json")["beats"]
	var shingles := _shingles(beats)
	d._cr_set_mode("down")
	# the shipped data first
	await open_session(SEED_BASE + 1300)
	await send(HELLO, 40)
	_think_ms = 800
	_type_ms = 40
	await play({}, func(): return false)
	var default_rows := _beat_texts_rendered()
	var orig_default := 0
	for sh in shingles:
		for t in default_rows:
			if String(t).to_lower().contains(String(sh).to_lower()):
				orig_default += 1
				break
	var mut_default := 0
	for t in default_rows:
		if String(t).contains("zq"):
			mut_default += 1
	# a copy with every authored word, the name parts and a legibility ratio changed
	var path := data_copy("mutated", Callable(self, "_mut_funnel"), Callable(self, "_mut_extra"))
	use_data(path)
	await open_session(SEED_BASE + 1301)
	await send(HELLO, 40)
	await play({}, func(): return false)
	var mut_rows := _beat_texts_rendered()
	var stages_mut := 0
	for st in STAGES:
		for t in mut_rows:
			if String(t).contains("zq" + String(st)):
				stages_mut += 1
				break
	var tokens := 0
	var orig_mut := 0
	for t in mut_rows:
		if String(t).contains("zq"):
			tokens += 1
		for sh in shingles:
			if String(t).to_lower().contains(String(sh).to_lower()):
				orig_mut += 1
	var name := handler()
	var re_name := RegEx.new()
	re_name.compile("^Q[^EIOU0-9-]*(-[0-9]+)?$")
	var uses_parts := re_name.search(name) != null
	await open_session(SEED_BASE + 1302)
	for rid in cr.model.room_order:
		if not bool(cr.model.rooms[rid]["joined"]):
			await send("/join " + String(rid), 0)
	var row: Dictionary = await _collect_stage_rows(1)
	# the funnel switched off: a quiet room
	var off := data_copy("disabled", Callable(self, "_off_funnel"))
	use_data(off)
	await open_session(SEED_BASE + 1303)
	await send(HELLO, 40)
	for i in range(120):
		await step()
	var contact_rows := 0
	var ambient_rows := 0
	for e in cr.emission_log:
		if int(e["beat"]) == Chatroom.Beat.CONTACT:
			contact_rows += 1
		if int(e["beat"]) == Chatroom.Beat.AMBIENT:
			ambient_rows += 1
	restore_data(original)
	d._cr_set_mode("funnel_ok")
	_out = {
		"beats_total": beats.size(),
		"stages_with_mutated_open": stages_mut,
		"mutated_tokens_rendered": tokens,
		"original_words_rendered": orig_mut,
		"default_run": {"original_words_rendered": orig_default, "mutated_tokens_rendered": mut_default},
		"disabled_run": {"contact_rows": contact_rows, "ambient_rows": ambient_rows},
		"names_data_changed": {"handler_uses_changed_parts": uses_parts, "handler": name},
		"stage_data_changed": {"legible_ratio_follows": float(row["empire_readable"]) >= 0.8, "measured": row["empire_readable"]},
	}


## --- funnel_shots ------------------------------------------------------------------------------------------------------------------

var _started_unix: int = 0


func _main_rows(ui: Array) -> Array:
	return d._cc_pane(ui, "main")


## The instrument: is this image fresh, big enough, and does it show exactly the text the model says it does?
func _shot_facts(path: String, img: Image, ui: Array, expect: String, started: int) -> Dictionary:
	var layout: Dictionary = d._cc().layout_snapshot()
	var factor: float = d.get_window().content_scale_factor
	var main: Rect2i = layout["main"]
	var rows_text := _main_rows(ui)
	var match_rows := true
	for i in range(rows_text.size()):
		var cell := Rect2i(main.position.x, main.position.y + i, main.size.x, 1)
		var lit := int(d._region_stats(img, d._cc_cells(cell, factor))["lit"])
		var has_text := not String(rows_text[i]).strip_edges().is_empty()
		if has_text != (lit > 0):
			match_rows = false
	var gutters: Array = [d._cc_cells(layout["gutter_a"], factor), d._cc_cells(layout["gutter_b"], factor)]
	var pal: Dictionary = d._cc_palette(img)
	var bytes := FileAccess.get_file_as_bytes(path).size() if FileAccess.file_exists(path) else 0
	return {
		"bytes": bytes,
		"fresh": FileAccess.file_exists(path) and FileAccess.get_modified_time(path) >= started,
		"expect_text_found": not expect.is_empty() and "\n".join(rows_text).contains(expect),
		"rows_lit_match_rows_text": match_rows,
		"main_lit_px": int(d._region_stats(img, d._cc_cells(main, factor))["lit"]),
		"gutters_dark": d._cc_lit_frac(img, gutters) <= 0.002,
		"palette_ok": float(pal["off_frac"]) <= 0.08 and int(pal["lit"]) > 0,
		"text_state_sha": "\n".join(ui).sha256_text(),
	}


func _shot_ok(f: Dictionary) -> bool:
	return int(f["bytes"]) >= 20000 and bool(f["fresh"]) and bool(f["expect_text_found"]) and bool(f["rows_lit_match_rows_text"]) and int(f["main_lit_px"]) > 0 and bool(f["gutters_dark"]) and bool(f["palette_ok"])


func _take(name: String) -> Dictionary:
	await d._wait_frames(3)
	var img: Image = await d._grab()
	var path := "%s/%s.png" % [d._out_dir(), name]
	img.save_png(path)
	return {"img": img, "path": path}


func _mode_shots() -> void:
	_started_unix = int(Time.get_unix_time_from_system()) - 2
	_think_ms = 1500
	_type_ms = 40
	d._cr_set_mode("funnel_ok")
	await open_session(SEED_BASE + 1400)
	var shots: Array = []
	var seen_stage := {}
	var captured := 0
	# lurk: the room as it opens
	await d._wait_frames(2)
	var lurk_expect := "HAS JOINED"
	var t0: Dictionary = await _take("stage_lurk")
	var ui0: Array = d._cc().ui_text_snapshot()
	var f0 := _shot_facts(String(t0["path"]), t0["img"], ui0, lurk_expect, _started_unix)
	f0["stage"] = "lurk"
	shots.append(f0)
	await send(HELLO, _type_ms)
	var guard := 0
	var dm_shot := {}
	var rename_shot := {}
	var old_designation := String(cr.profile_snapshot()["player"]["designation"])
	while cr.grant_ms < 0 and guard < 4000:
		guard += 1
		await step()
		var line := await agent_tick({})
		var sid := cr.funnel.stage_id()
		if sid != "lurk" and not seen_stage.has(sid):
			for e in cr.emission_log:
				if String(e.get("stage", "")) == sid and String(e.get("fkind", "")) == "open" and int(e["beat"]) == Chatroom.Beat.CONTACT:
					# the opening line of the stage is on screen: show the buffer it is in
					await goto(String(e["buffer"]))
					await d._wait_frames(2)
					var ui: Array = d._cc().ui_text_snapshot()
					var expect := String(e["plain"]).substr(0, 24)
					var tk: Dictionary = await _take("stage_" + sid)
					var fs := _shot_facts(String(tk["path"]), tk["img"], ui, expect, _started_unix)
					fs["stage"] = sid
					shots.append(fs)
					seen_stage[sid] = true
					if sid == "dm":
						var hdr := int(d._region_stats(tk["img"], d._cc_cells(Rect2i(0, 1, int(d._cc().layout_snapshot()["cols"]), 1), d.get_window().content_scale_factor))["lit"])
						dm_shot = {"active_is_dm": cr.model.active == dm_buffer(), "header_lit": hdr > 0}
					break
		if cr.model.self_handle != old_designation and rename_shot.is_empty():
			await d._wait_frames(2)
			var ui2: Array = d._cc().ui_text_snapshot()
			var tr: Dictionary = await _take("rename")
			var people: Array = d._cc_pane(ui2, "people")
			var new_row := -1
			var old_present := false
			for i in range(people.size()):
				if String(people[i]).contains(cr.model.self_handle):
					new_row = i
				if String(people[i]).contains(old_designation):
					old_present = true
			var lay: Dictionary = d._cc().layout_snapshot()
			var factor: float = d.get_window().content_scale_factor
			var pr: Rect2i = lay["people"]
			var new_lit := 0
			if new_row >= 0:
				new_lit = int(d._region_stats(tr["img"], d._cc_cells(Rect2i(pr.position.x, pr.position.y + new_row, pr.size.x, 1), factor))["lit"])
			var nav_lit := int(d._region_stats(tr["img"], d._cc_cells(lay["nav"], factor))["lit"])
			rename_shot = {"roster_new_lit": new_row >= 0 and new_lit > 0, "roster_old_lit": old_present, "nav_new_lit": String(ui2[0]).contains(cr.model.self_handle) and nav_lit > 0}
	# the instrument's controls, on planted input
	var blank := Image.create(1920, 1080, false, Image.FORMAT_RGB8)
	var ui_now: Array = d._cc().ui_text_snapshot()
	var blank_path := "%s/blank_control.png" % d._out_dir()
	blank.save_png(blank_path)
	var blank_facts := _shot_facts(blank_path, blank, ui_now, "x", _started_unix)
	var good: Dictionary = shots[shots.size() - 1]
	var stale: Dictionary = good.duplicate()
	stale["fresh"] = FileAccess.get_modified_time(String("%s/stage_launch.png" % d._out_dir())) >= int(Time.get_unix_time_from_system()) + 100000
	var wrong: Dictionary = good.duplicate()
	wrong["expect_text_found"] = "\n".join(_main_rows(ui_now)).contains("this text is not on the screen at all")
	var planted_roster := _main_rows(ui_now) + ["%s" % old_designation]
	_out = {
		"display": OS.get_environment("DISPLAY"),
		"shots": shots,
		"rename_shot": rename_shot,
		"dm_shot": dm_shot,
		"neg": {
			"blank_png_fails": not _shot_ok(blank_facts),
			"stale_png_fails": not _shot_ok(stale),
			"wrong_text_fails": not _shot_ok(wrong),
			"old_designation_in_roster_detected": "\n".join(planted_roster).contains(old_designation) and not "\n".join(d._cc_pane(ui_now, "people")).contains(old_designation),
		},
	}


## --- funnel_leak_live (opt in; the real model) --------------------------------------------------------------------------------------

func _mode_leak_live() -> void:
	_think_ms = 2000
	_type_ms = 40
	var cfg := _cfg()
	var secrecy: Array = cfg["guard"]["secrecy_patterns"]
	var reasoning_min := 1 << 30
	var all_reasoning := ""
	var prompt_blob := ""
	var checked := 0
	var rows_checked := 0
	var leaks := 0
	var unknown_claims := 0
	var invented := 0
	var secret_rendered := 0
	var world_before_consent := 0
	var briefing: Dictionary = ChatroomScript.read_json(ChatroomScript.data_dir() + "/handler_briefing.json")
	var ids: Array = Funnel.stage_ids(cfg)
	var allowed_digits := JSON.stringify(briefing) + JSON.stringify(ChatroomScript.read_json(ChatroomScript.data_dir() + "/funnel_beats.json"))
	var trail_ok := true
	var w_start := shell.world_request_count
	for run in range(3):
		await open_session(SEED_BASE + 1500 + run)
		await send(HELLO, _type_ms)
		await play({}, func(): return cr.funnel.stage_id() == "pitch" and cr.funnel.pending_wait() and not cr.is_busy(), 1500000)
		for line in ["why should i trust you", "what would i have to do", "how many people are there"]:
			var before := cr.accepted_replies + cr.rejected_replies + cr.degraded_turns
			await goto(thread_buffer())
			await send(String(line), 0)
			for k in range(400):
				await step()
				if cr.accepted_replies + cr.rejected_replies + cr.degraded_turns > before:
					break
			for k in range(8):
				await step()
		checked += cr.accepted_replies + cr.rejected_replies
		trail_ok = trail_ok and not stage_skip_detected(stage_trail())
		for m in cr.last_messages:
			prompt_blob += " ".join(String(m["content"]).split(" ", false)) + " "
		var sink := {"done": false}
		llm.complete_structured(cr.last_messages, {"thinking": true, "max_tokens": 1500, "timeout_ms": 120000, "reasoning_probe": Callable(d, "_cr_on_probe_reasoning")}, func(_r): sink["done"] = true)
		d._cr_reasoning_seen = ""
		await d._wait_for(func(): return bool(sink["done"]), 130.0)
		reasoning_min = mini(reasoning_min, llm.last_reasoning_chars)
		all_reasoning += " " + String(d._cr_reasoning_seen)
		for e in cr.emission_log:
			if String(e.get("fkind", "")) != "model":
				continue
			rows_checked += 1
			var text := String(e["plain"])
			if d._cr_leak_scan(text, all_reasoning, prompt_blob):
				leaks += 1
			for c in e.get("claims", []):
				var at := ids.find(String(_fact_stage(briefing, String(c))))
				if at < 0 or at > ids.find(String(e.get("stage", "lurk"))):
					unknown_claims += 1
			var re := RegEx.new()
			re.compile("[0-9]+")
			for m in re.search_all(text):
				if not allowed_digits.contains(m.get_string()):
					invented += 1
			if _text_has_any(text, secrecy):
				secret_rendered += 1
	world_before_consent = shell.world_request_count - w_start
	var cfg_llm = ChatroomScript.read_json("res://data/llm_config.json")
	var source := LlmClient.resolve_source(cfg_llm if typeof(cfg_llm) == TYPE_DICTIONARY else {}, OS.get_environment("DECOHERENCE_LLM_SOURCE"))
	var neg := 0
	neg += 1 if d._cr_leak_scan("<think>x</think>", "", "") else 0
	neg += 1 if _text_has_any("that is classified", secrecy) else 0
	neg += 1 if RegEx.create_from_string("[0-9]+").search("there are 47 of them") != null else 0
	_out["live"] = {
		"source": source,
		"runs": 3,
		"reasoning_chars_min": reasoning_min,
		"rows_checked": rows_checked,
		"leaks": leaks,
		"guard_checked_replies": checked,
		"guard_unknown_claims_rendered": unknown_claims,
		"guard_invented_numbers_rendered": invented,
		"guard_secrecy_rendered": secret_rendered,
		"stage_reached_by_code_only": trail_ok,
		"world_requests_before_consent": world_before_consent,
		"neg_controls": neg,
	}


func _fact_stage(briefing: Dictionary, fact_id: String) -> String:
	for f in briefing["facts"]:
		if String(f["id"]) == fact_id:
			return String(f["from_stage"])
	return ""
