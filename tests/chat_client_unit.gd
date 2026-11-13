extends SceneTree

## Unit tests for the Spec #562 chat client core: ChatLayout and ChatModel (no
## scene, no model, no GPU). Run via tests/verify_chat_client_unit.sh. Output
## contract (parsed by the DoD):
##   CHATCLIENT_UNIT_OK <name>          one per passing unit
##   CHATCLIENT_UNIT_FAIL <name>: <why>   any failure (script exits 1)
##   CHATCLIENT_NEGCTL_OK <name>        negative controls: the check DOES catch breakage
##   CHATCLIENT_FUZZ trials=<n> contact_hits=<n> scripted_hits=<n> dm_hits=<n> contact_outside=<n>
##
## Each negative control feeds a deliberately broken input or stub to the SAME
## check the real code passed, and requires the check to fail.

var _failed: int = 0
var _script: Dictionary = {}
var _ui: Dictionary = {}

const SIZES := [[1280, 720], [1920, 1080], [1920, 1080]]
const CONCEPT := "(?i)handler|recruit|contact|liaison|objective|quest|mission|tutorial|wizard|onboard|walkthrough|getting started|beginner|newcomer|briefing|assigned|progress|checklist|hint|tip:|try typing|welcome|guide|help"


func _init() -> void:
	var s = ChatroomScript.read_json("res://frontdoor/data/chatroom/room_script.json")
	var u = ChatroomScript.read_json("res://frontdoor/data/chatroom/client_ui.json")
	_ok("real_data_loads", typeof(s) == TYPE_DICTIONARY and typeof(u) == TYPE_DICTIONARY, "room_script.json or client_ui.json unreadable")
	if typeof(s) != TYPE_DICTIONARY or typeof(u) != TYPE_DICTIONARY:
		quit(1)
		return
	_script = ChatroomScript.with_handler(s, "PAL-5")
	_ui = u
	_layout_units()
	_data_units()
	_buffer_units()
	_unread_and_dm_units()
	_route_units()
	_text_units()
	_roster_and_presence_units()
	_stream_filter_units()
	_fuzz()
	quit(1 if _failed > 0 else 0)


func _ok(name: String, cond: bool, why: String = "") -> void:
	if cond:
		print("CHATCLIENT_UNIT_OK " + name)
	else:
		_failed += 1
		print("CHATCLIENT_UNIT_FAIL %s: %s" % [name, why])


func _neg(name: String, caught: bool) -> void:
	if caught:
		print("CHATCLIENT_NEGCTL_OK " + name)
	else:
		_failed += 1
		print("CHATCLIENT_UNIT_FAIL negctl_%s: the broken stub was NOT caught" % name)


func _model() -> ChatModel:
	var m := ChatModel.new()
	m.setup(_script, "newb4821", String(_script["entry_room"]))
	return m


func _row(kind: String, handle: String, text: String) -> Dictionary:
	return {"kind": kind, "handle": handle, "text": text, "t": "21:14", "clear": false}


## --- Layout ------------------------------------------------------------------

func _layout_ok(l: Dictionary) -> bool:
	var rects := ChatLayout.rect_list(l)
	return ChatLayout.overlap_count(rects) == 0 and ChatLayout.out_of_bounds_count(rects, int(l["cols"]), int(l["rows"])) == 0


func _layout_units() -> void:
	var l1 := ChatLayout.compute(1280, 720)
	_ok("layout_1280x720_grid", int(l1["cols"]) == 128 and int(l1["rows"]) == 36 and String(l1["tier"]) == "full", str(l1["cols"]))
	_ok("layout_1280x720_columns", (l1["side"] as Rect2i).size.x == 26 and (l1["main"] as Rect2i).size.x == 76 and (l1["people"] as Rect2i).size.x == 24, "side/main/people")
	var l2 := ChatLayout.compute(1920, 1080)
	_ok("layout_1920x1080_grid", int(l2["cols"]) == 192 and int(l2["rows"]) == 54, str(l2["cols"]))
	var logical := Vector2i(Vector2(3840, 2160) / UiScale.factor_for(Vector2i(3840, 2160)))
	var l3 := ChatLayout.compute(logical.x, logical.y)
	_ok("layout_3840x2160_is_content_scaled", logical == Vector2i(1920, 1080) and int(l3["cols"]) == 192 and int(l3["rows"]) == 54, str(logical))
	var all_clean := true
	var budget := true
	for sz in SIZES:
		var l := ChatLayout.compute(int(sz[0]), int(sz[1]))
		all_clean = all_clean and _layout_ok(l)
		var widths: int = (l["side"] as Rect2i).size.x + (l["gutter_a"] as Rect2i).size.x + (l["main"] as Rect2i).size.x + (l["gutter_b"] as Rect2i).size.x + (l["people"] as Rect2i).size.x
		budget = budget and widths == int(l["cols"])
	_ok("layout_no_overlap_in_bounds", all_clean, "a game-size layout overlaps or leaves the grid")
	_ok("layout_column_budget_sums_to_cols", budget, "pane widths do not add up")
	var low := ChatLayout.compute(1000, 600)
	_ok("layout_reduced_tier_below_min", String(low["tier"]) == "reduced" and (low["side"] as Rect2i).size.x == 0 and (low["people"] as Rect2i).size.x == 0 and _layout_ok(low), String(low["tier"]))
	_ok("layout_tier_for_boundaries", ChatLayout.tier_for(1200, 700) == "full" and ChatLayout.tier_for(1199, 700) == "reduced" and ChatLayout.tier_for(1200, 699) == "reduced", "tier boundary")
	_ok("layout_gutters_one_cell", (l1["gutter_a"] as Rect2i).size.x == 1 and (l1["gutter_b"] as Rect2i).size.x == 1, "gutter width")
	_ok("layout_status_and_input_rows", (l1["status"] as Rect2i).position.y == 34 and (l1["input"] as Rect2i).position.y == 35, "status/input row")
	# negative controls for the layout checker
	var bad := ChatLayout.compute(1920, 1080)
	var shifted: Rect2i = bad["main"]
	bad["main"] = Rect2i(shifted.position.x - 5, shifted.position.y, shifted.size.x, shifted.size.y)
	_neg("layout_checker_overlap", ChatLayout.overlap_count(ChatLayout.rect_list(bad)) > 0)
	var off := ChatLayout.compute(1920, 1080)
	off["people"] = Rect2i(190, 2, 24, 50)
	_neg("layout_checker_out_of_bounds", ChatLayout.out_of_bounds_count(ChatLayout.rect_list(off), 192, 54) > 0)


## --- Data tables -------------------------------------------------------------

func _data_units() -> void:
	var items: Array = _ui["nav"]["items"]
	var keys_ok := items.size() >= 4 and items.size() <= 6
	for it in items:
		keys_ok = keys_ok and String(it["key"]).begins_with("F") and not String(it["label"]).is_empty()
	_ok("nav_items_have_f_keys", keys_ok, "nav table")
	var k: Dictionary = _ui["keys"]
	_ok("keys_table_complete", k.size() >= 17 and k["send"] == "Enter" and k["buffer_next"] == "Ctrl+N" and k["buffer_jump"] == "Alt+1..9" and k["quit"] == "Ctrl+Q", "key table")
	var fullscreen_free := true
	for v in k.values():
		if v == "F11" or v == "Alt+Enter":
			fullscreen_free = false
	_ok("keys_never_rebind_fullscreen", fullscreen_free, "F11 or Alt+Enter bound")
	var m := _model()
	_ok("rooms_from_data", m.room_order.size() >= 5 and m.active == String(_script["entry_room"]) and m.open_order() == [m.active], str(m.room_order))
	_ok("directory_counts_match_roster", _directory_ok(m), "directory count")


func _directory_ok(m: ChatModel) -> bool:
	for e in m.directory():
		if int(e["count"]) != m.member_count(String(e["id"])):
			return false
		if bool(e["joined"]) and not m.roster(String(e["id"])).has(m.self_handle):
			return false
	return true


## --- Buffers -----------------------------------------------------------------

func _buffer_units() -> void:
	var m := _model()
	_ok("join_new_room", m.join("channel3") and m.open_order() == ["channel7", "channel3"], str(m.open_order()))
	_ok("join_is_idempotent", not m.join("channel3") and m.open_order().size() == 2, "second join changed the order")
	_ok("join_unknown_refused", not m.join("nowhere"), "joined a room that does not exist")
	m.join("channel12")
	m.switch_to("channel12")
	_ok("part_moves_active_to_neighbour", m.part("channel12") and m.active == "channel3" and m.open_order() == ["channel7", "channel3"], m.active)
	m.part("channel3")
	_ok("part_last_buffer_refused", not m.part("channel7") and m.open_order() == ["channel7"], "closed the last open buffer")
	m.join("channel3")
	m.join("channel19")
	m.switch_to("channel7")
	m.cycle(1)
	var fwd := m.active
	m.cycle(-1)
	m.cycle(-1)
	_ok("cycle_wraps_both_ways", fwd == "channel3" and m.active == "channel19", "%s %s" % [fwd, m.active])
	_ok("jump_by_number", m.jump(1) and m.active == "channel7" and m.jump(3) and m.active == "channel19" and not m.jump(9), m.active)
	m.set_draft("channel7", "half a line")
	m.switch_to("channel3")
	_ok("draft_kept_per_buffer", m.draft_of("channel7") == "half a line" and m.draft_of("channel3") == "", "draft")
	_ok("room_id_resolution", m.room_id_for("channel3") == "channel3" and m.room_id_for("3") == "channel3" and m.room_id_for("#Channel 12") == "channel12" and m.room_id_for("zz").is_empty(), "room id")
	# the scrollback cap and the sticky scroll
	var n := _model()
	for i in range(ChatModel.MAX_ROWS + 20):
		n.add_row("channel7", _row("voice", "XEN-4", "row %d" % i))
	_ok("scrollback_capped_oldest_dropped", n.rows_of("channel7").size() == ChatModel.MAX_ROWS and String(n.rows_of("channel7")[0]["text"]) == "row 20", str(n.rows_of("channel7").size()))
	n.scroll_by("channel7", 10)
	n.add_row("channel7", _row("voice", "XEN-4", "late"))
	_ok("scrolled_view_keeps_place", int(n.buffers["channel7"]["scroll"]) == 11, str(n.buffers["channel7"]["scroll"]))
	n.scroll_live("channel7")
	_ok("scroll_live_resets", int(n.buffers["channel7"]["scroll"]) == 0, "scroll")


## --- Unread and direct messages -----------------------------------------------

func _unread_ok(m: ChatModel) -> bool:
	m.add_row(m.active, _row("voice", "XEN-4", "on the active buffer"))
	return m.unread_of(m.active) == 0


func _unread_stub_counts_active(m: ChatModel) -> bool:
	# a deliberately broken counter that also counts the active buffer
	m.buffers[m.active]["unread"] = int(m.buffers[m.active]["unread"]) + 1
	return m.unread_of(m.active) == 0


func _unread_and_dm_units() -> void:
	var m := _model()
	m.join("channel3")
	m.add_row("channel3", _row("voice", "XEN-4", "one"))
	m.add_row("channel3", _row("voice", "NUL-9", "two"))
	_ok("unread_increments_when_away", m.unread_of("channel3") == 2, str(m.unread_of("channel3")))
	m.add_row("channel3", _row("presence", "", "-- THRESH HAS JOINED"))
	_ok("unread_ignores_presence_rows", m.unread_of("channel3") == 2, str(m.unread_of("channel3")))
	m.switch_to("channel3")
	_ok("unread_clears_on_view", m.unread_of("channel3") == 0, "unread")
	_ok("unread_never_counts_active", _unread_ok(m), "active buffer counted")
	_neg("unread_checker_catches_active_counter", not _unread_stub_counts_active(_model()))
	m.open_dm("NUL-9")
	m.open_dm("XEN-4")
	m.add_row("dm:NUL-9", _row("voice", "NUL-9", "psst"))
	m.add_row("dm:XEN-4", _row("voice", "XEN-4", "psst"))
	m.add_row("dm:XEN-4", _row("voice", "XEN-4", "psst again"))
	_ok("unread_total_is_dm_sum", m.unread_total() == 3 and m.unread_of("dm:XEN-4") == 2, str(m.unread_total()))
	_ok("newest_unread_dm", m.newest_unread_dm() == "dm:XEN-4", m.newest_unread_dm())
	_ok("dm_open_is_idempotent", not m.open_dm("NUL-9") and m.open_order().filter(func(id): return String(id).begins_with("dm:")).size() == 2, "dm opened twice")
	_ok("dm_order_alphabetical", m.open_order() == ["channel7", "channel3", "dm:NUL-9", "dm:XEN-4"], str(m.open_order()))
	m.switch_to("dm:NUL-9")
	m.part("dm:NUL-9")
	_ok("dm_close_keeps_history", m.rows_of("dm:NUL-9").size() == 1 and not m.is_open("dm:NUL-9"), "rows lost on close")
	m.add_row("dm:NUL-9", _row("voice", "NUL-9", "you closed me"))
	_ok("incoming_row_reopens_closed_dm", m.is_open("dm:NUL-9") and m.unread_of("dm:NUL-9") == 1 and m.rows_of("dm:NUL-9").size() == 2, "dm did not reopen")
	_ok("dm_roster_is_two_people", m.roster("dm:XEN-4") == ["XEN-4", "newb4821"], str(m.roster("dm:XEN-4")))


## --- Routing, commands, first message ---------------------------------------------

func _oracle(buffer: String, text: String, reached: bool, threads: Array) -> String:
	# an independent statement of the rule, written from the shape of the line
	var t := text.strip_edges()
	if t.is_empty() or t.begins_with("/"):
		return ChatroomScript.ROUTE_COMMAND
	var flat := " ".join(t.replace("\t", " ").split(" ", false)).to_lower()
	if flat == "leave" or flat == "exit" or flat == "quit":
		return ChatroomScript.ROUTE_COMMAND
	if reached and threads.has(buffer):
		return ChatroomScript.ROUTE_CONTACT
	return ChatroomScript.ROUTE_SCRIPTED


func _route_units() -> void:
	var st := {"reached": true, "threads": ["channel7", "dm:PAL-5"]}
	var cold := {"reached": false, "threads": ["channel7"]}
	_ok("route_table_contact_buffers", ChatModel.route_for("channel7", "hello there", st) == "contact" and ChatModel.route_for("dm:PAL-5", "hello there", st) == "contact", "contact route")
	_ok("route_table_other_buffers_scripted", ChatModel.route_for("channel3", "hello there", st) == "scripted" and ChatModel.route_for("dm:NUL-9", "hello there", st) == "scripted", "scripted route")
	_ok("route_table_before_reach_scripted", ChatModel.route_for("channel7", "hello there", cold) == "scripted", "route before reach")
	_ok("route_table_commands", ChatModel.route_for("channel7", "/join 3", st) == "command" and ChatModel.route_for("channel7", "leave", st) == "command" and ChatModel.route_for("channel7", "   ", st) == "command" and ChatModel.route_for("channel7", "/nonsense", st) == "command", "command route")
	_ok("first_message_counts", ChatModel.counts_as_message("hello") and ChatModel.counts_as_message("/me waves") and ChatModel.counts_as_message("/msg XEN-4 hi"), "a sent message did not count")
	_ok("first_message_ignores_non_messages", not ChatModel.counts_as_message("") and not ChatModel.counts_as_message("   ") and not ChatModel.counts_as_message("/join 3") and not ChatModel.counts_as_message("/msg XEN-4") and not ChatModel.counts_as_message("/me") and not ChatModel.counts_as_message("/who") and not ChatModel.counts_as_message("/clear") and not ChatModel.counts_as_message("/zzz"), "a non-message counted")
	_ok("parse_command_verbs", _verbs_ok(), "verb table")
	_ok("parse_command_msg_args", String(ChatModel.parse_command("/msg  xen-4   hi  there")["name"]) == "xen-4" and String(ChatModel.parse_command("/msg xen-4 hi there")["body"]) == "hi there" and String(ChatModel.parse_command("/join  channel 3")["name"]) == "channel 3", "msg args")
	_ok("parse_command_nonascii_rejected", _nonascii_ok(), "a non-ASCII look-alike parsed as a command or leave word")
	_ok("parse_command_punctuation_rejected", String(ChatModel.parse_command("/join.")["kind"]) == "unknown" and String(ChatModel.parse_command("/me!")["kind"]) == "unknown" and String(ChatModel.parse_command("leave!")["kind"]) == "text" and String(ChatModel.parse_command("/ join")["kind"]) == "unknown", "punctuation")
	_ok("complete_nick_prefix", ChatModel.complete_nick("xe", ["XEN-4", "NUL-9"]) == "XEN-4" and ChatModel.complete_nick("n", ["XEN-4", "NUL-9"]) == "NUL-9" and ChatModel.complete_nick("zz", ["XEN-4"]) == "" and ChatModel.complete_nick("", ["XEN-4"]) == "", "nick completion")
	_ok("complete_nick_cycles", ChatModel.complete_nick("t", ["THRESH", "TIDE-2"], 0) == "THRESH" and ChatModel.complete_nick("t", ["THRESH", "TIDE-2"], 1) == "TIDE-2" and ChatModel.complete_nick("t", ["THRESH", "TIDE-2"], 2) == "THRESH", "nick cycle")
	# the real matcher passes both checks; a stub that folds Unicode, and one that ignores punctuation, do not
	var words := ["i accept", "accept", "enter"]
	_ok("matcher_rejects_lookalikes_and_punctuation", _matcher_strict(func(t): return ChatroomScript.matches_command(words, t)), "the real matcher folded a look-alike or ignored punctuation")
	_neg("command_matcher_unicode_fold_stub", not _matcher_strict(func(t): return t.strip_edges().to_lower() in words))
	_neg("command_matcher_punctuation_stub", not _matcher_strict(func(t): return _letters_only(t) in words))
	_neg("concept_regex_catches_planted_word", _concept_hits(["a quest for the Handler"]) > 0)
	_ok("concept_regex_clean_on_real_ui", _concept_hits(_ui_strings()) == 0, "a concept word in client_ui.json")


func _verbs_ok() -> bool:
	for v in ["join", "part", "list", "who", "msg", "me", "clear"]:
		if String(ChatModel.parse_command("/" + v + " x")["kind"]) != v or String(ChatModel.parse_command("/" + v.to_upper() + " x")["kind"]) != v:
			return false
	for w in ["leave", "exit", "quit", "/leave", "/exit", "/quit", "QUIT"]:
		if String(ChatModel.parse_command(w)["kind"]) != "quit":
			return false
	return String(ChatModel.parse_command("hello")["kind"]) == "text" and String(ChatModel.parse_command("")["kind"]) == "empty"


func _nonascii_ok() -> bool:
	# dotted capital I, Cyrillic e, full-width letters: none may be a verb or a leave word
	for s in ["İ leave", "lеave", "ｌｅａｖｅ", "/jóin 3", "/ｊoin 3", "/mе hi"]:
		var k := String(ChatModel.parse_command(s)["kind"])
		if k != "text" and k != "unknown":
			return false
	return String(ChatModel.parse_command("/join 3")["kind"]) == "join"


## The two things a command matcher must refuse: the dotted capital I (which the
## engine's own lower-casing folds to a plain i) and trailing punctuation.
func _matcher_strict(matcher: Callable) -> bool:
	return matcher.call("accept") and matcher.call("  Accept ") and not matcher.call("\u0130 accept") and not matcher.call("accept.") and not matcher.call("enter!")


func _letters_only(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if (c >= 97 and c <= 122) or c == 32:
			out += char(c)
	return out.strip_edges()


func _ui_strings() -> Array:
	var out: Array = [String(_ui["nav"]["brand"])]
	for it in _ui["nav"]["items"]:
		out.append(String(it["label"]))
	for v in _ui["strings"].values():
		out.append(String(v))
	return out


func _concept_hits(texts: Array) -> int:
	var re := RegEx.new()
	re.compile(CONCEPT)
	var n := 0
	for t in texts:
		if re.search(String(t)) != null:
			n += 1
	return n


## --- Text, history, rows --------------------------------------------------------------

func _wrap_ok(rows: Array, width: int) -> bool:
	for line in rows:
		if String(line).length() > width:
			return false
	return true


func _text_units() -> void:
	var m := _model()
	m.history_push("one")
	m.history_push("two")
	m.history_push("two")
	_ok("history_dedups_repeat", m.history_size() == 2, str(m.history_size()))
	var a := m.history_prev("draft")
	var b := m.history_prev("draft")
	var c := m.history_prev("draft")
	_ok("history_ring_walks_back", a == "two" and b == "one" and c == "one", "%s %s %s" % [a, b, c])
	var d := m.history_next()
	var e := m.history_next()
	_ok("history_forward_restores_draft", d == "two" and e == "draft", "%s %s" % [d, e])
	var h := ChatModel.new()
	for i in range(ChatModel.HISTORY_MAX + 10):
		h.history_push("line %d" % i)
	_ok("history_capped", h.history_size() == ChatModel.HISTORY_MAX, str(h.history_size()))
	var long_row := {"kind": "voice", "handle": "OBL-17", "text": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega", "t": "09:05"}
	var ok_wrap := true
	for width in [20, 40, 76, 100, 164]:
		ok_wrap = ok_wrap and _wrap_ok(ChatModel.format_row(long_row, width), width)
	_ok("rows_wrap_within_width", ok_wrap, "a formatted row is wider than its pane")
	var giant := {"kind": "voice", "handle": "XEN-4", "text": "x".repeat(300), "t": "09:05"}
	_ok("rows_split_giant_words", _wrap_ok(ChatModel.format_row(giant, 76), 76), "an unbroken word overflowed")
	_neg("wrap_checker_catches_overlong_row", not _wrap_ok(["[09:05] <XEN-4> " + "y".repeat(90)], 76))
	var lines := ChatModel.format_row(_row("voice", "XEN-4", "hello"), 76)
	var re := RegEx.new()
	re.compile("^\\[[0-9]{2}:[0-9]{2}\\] ")
	_ok("row_timestamp_shape", re.search(String(lines[0])) != null and String(lines[0]) == "[21:14] <XEN-4> hello", String(lines[0]))
	_ok("row_kinds_render", String(ChatModel.format_row(_row("presence", "", "-- THRESH HAS JOINED"), 76)[0]) == "[21:14] -- THRESH HAS JOINED" and String(ChatModel.format_row(_row("action", "newb4821", "waves"), 76)[0]) == "[21:14] * newb4821 waves" and String(ChatModel.format_row(_row("self", "newb4821", "hi"), 76)[0]) == "[21:14] <newb4821> hi", "row kinds")


## --- Roster and presence ----------------------------------------------------------------

func _roster_sorted_once(m: ChatModel, room_id: String) -> bool:
	var r: Array = m.roster(room_id)
	var sorted_r := r.duplicate()
	sorted_r.sort()
	return r == sorted_r and r.count(m.self_handle) == 1


func _roster_tone_uniform(entries: Array, who: String) -> bool:
	var seen := {}
	for e in entries:
		if String(e["handle"]) != m_self():
			seen[ChatModel.style_signature(e)] = true
		if String(e["handle"]) == who and String(e["marker"]) != "":
			return false
	return seen.size() == 1


func m_self() -> String:
	return "newb4821"


func _presence_floor() -> Dictionary:
	var m := _model()
	for rid in m.room_order:
		m.join(String(rid))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var min_size := 99
	var joins := 0
	var leaves := 0
	for i in range(3000):
		var rid := String(m.room_order[i % m.room_order.size()])
		var ev := m.presence_step(rid, rng)
		if String(ev.get("kind", "")) == "join":
			joins += 1
		elif String(ev.get("kind", "")) == "leave":
			leaves += 1
		min_size = mini(min_size, m.roster(rid).size())
	return {"min": min_size, "joins": joins, "leaves": leaves}


func _roster_and_presence_units() -> void:
	var m := _model()
	for rid in m.room_order:
		m.join(String(rid))
	var sorted_ok := true
	for rid in m.room_order:
		sorted_ok = sorted_ok and _roster_sorted_once(m, String(rid))
	_ok("roster_sorted_self_once_every_room", sorted_ok, "a roster is unsorted or lists the player twice")
	var uniform := true
	var contact_handle := String(ChatroomScript.slot_voice(ChatroomScript.entry_room(_script)).get("handle", ""))
	for rid in m.room_order:
		uniform = uniform and _roster_tone_uniform(ChatModel.roster_entries(m, String(rid)), contact_handle)
	_ok("roster_style_uniform_for_everyone_else", uniform, "roster rows differ in style")
	var marked := ChatModel.roster_entries(m, "channel7")
	for e in marked:
		if String(e["handle"]) == contact_handle:
			e["tone"] = "marked"
	_neg("style_checker_catches_marked_row", not _roster_tone_uniform(marked, contact_handle))
	_ok("roster_marks_only_self", _only_self_marked(ChatModel.roster_entries(m, "channel7")), "marker on a row other than the player")
	_ok("contact_never_first_or_last_at_start", _middle_everywhere(m, contact_handle), "contact sorts to an edge of a roster")
	_ok("contact_not_unique_in_room_pattern", _pattern_ok(m, contact_handle), "the contact is the only handle present in every room")
	var pf := _presence_floor()
	_ok("presence_roster_never_below_four", int(pf["min"]) >= ChatModel.MIN_ROSTER, str(pf))
	_ok("presence_both_directions_occur", int(pf["joins"]) > 20 and int(pf["leaves"]) > 20, str(pf))


func _only_self_marked(entries: Array) -> bool:
	var marked := 0
	for e in entries:
		if String(e["marker"]) != "":
			marked += 1
			if String(e["handle"]) != m_self():
				return false
	return marked == 1


func _middle_everywhere(m: ChatModel, handle: String) -> bool:
	for rid in m.room_order:
		var r: Array = m.roster(String(rid))
		if r.find(handle) <= 0 or r.find(handle) >= r.size() - 1:
			return false
	return true


func _pattern_ok(m: ChatModel, handle: String) -> bool:
	var counts := {}
	for rid in m.room_order:
		for h in m.rooms[rid]["voices"]:
			counts[h] = int(counts.get(h, 0)) + 1
	var same := 0
	for h in counts:
		if h != handle and int(counts[h]) == int(counts[handle]):
			same += 1
	return same >= 2


## --- The stream-side think filter (#615) ----------------------------------------------------

func _run_filter(chunks: Array) -> String:
	var st := LlmClient.new_stream_filter()
	var out := ""
	for c in chunks:
		out += LlmClient.filter_stream_piece(st, String(c))
	return out + LlmClient.filter_stream_flush(st)


func _stream_filter_units() -> void:
	_ok("stream_filter_drops_inline_span", _run_filter(["<think>plan it</think>Hello", " there."]) == "Hello there.", _run_filter(["<think>plan it</think>Hello", " there."]))
	_ok("stream_filter_tag_split_across_chunks", _run_filter(["Hi <th", "ink>secret</th", "ink> there"]) == "Hi  there", _run_filter(["Hi <th", "ink>secret</th", "ink> there"]))
	_ok("stream_filter_case_insensitive", _run_filter(["a <THINK>x</Think> b"]) == "a  b", _run_filter(["a <THINK>x</Think> b"]))
	_ok("stream_filter_keeps_ordinary_text", _run_filter(["I think ", "the thinker ", "is thinking, so be it."]) == "I think the thinker is thinking, so be it.", "benign text changed")
	_ok("stream_filter_keeps_lone_angle_fragment", _run_filter(["a <th"]) == "a <th" and _run_filter(["x < y"]) == "x < y", "a harmless fragment was eaten")
	_ok("stream_filter_drops_unterminated_span", _run_filter(["ok <think>never closed", " and more"]) == "ok ", _run_filter(["ok <think>never closed", " and more"]))
	_ok("stream_filter_drops_stray_closing_tag", _run_filter(["a </think> b"]) == "a  b", _run_filter(["a </think> b"]))
	_ok("stream_filter_two_spans", _run_filter(["<think>a</think>X<think>b</think>Y"]) == "XY", _run_filter(["<think>a</think>X<think>b</think>Y"]))
	# negative control: a pass-through that does not filter is caught by the same expectation
	var passthrough := "".join(PackedStringArray(["<think>plan it</think>Hello", " there."]))
	_neg("stream_filter_raw_passthrough_is_caught", passthrough != "Hello there.")


## --- Fuzz of the route function ------------------------------------------------------------

func _shape_text(rng: RandomNumberGenerator, shape: int) -> String:
	var words := ["hello", "anyone here", "what is this", "ok", "accept", "enter", "who", "xen-4 are you there"]
	var verbs := ["join 3", "part", "list", "who", "msg xen-4 hi", "me waves", "clear", "quit", "leave", "exit", "zzz", "join", "msg"]
	match shape:
		0:
			return String(words[rng.randi_range(0, words.size() - 1)])
		1:
			return "/" + String(verbs[rng.randi_range(0, verbs.size() - 1)])
		2:
			return String(["leave", "exit", "quit", "  leave  ", "QUIT"][rng.randi_range(0, 4)])
		3:
			return String(["", "   ", "\t"][rng.randi_range(0, 2)])
		4:
			return String(["İ accept", "lеave", "/ｊoin 3", "accept.", "/join.", "enter!"][rng.randi_range(0, 5)])
		5:
			return "say /join 3 to me"
	return "x"


func _outside(trials: Array, router: Callable) -> int:
	var n := 0
	for t in trials:
		var got: String = router.call(t["buffer"], t["text"], t["state"])
		if got == ChatroomScript.ROUTE_CONTACT and not (bool(t["state"]["reached"]) and (t["state"]["threads"] as Array).has(t["buffer"])):
			n += 1
	return n


func _fuzz() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 562
	var buffers := ["channel7", "channel3", "channel12", "channel19", "channel4", "dm:PAL-5", "dm:NUL-9", "dm:XEN-4", "dm:OBL-17"]
	var trials: Array = []
	for i in range(4000):
		var threads: Array = []
		for b in buffers:
			if rng.randf() < 0.25:
				threads.append(b)
		trials.append({
			"buffer": String(buffers[rng.randi_range(0, buffers.size() - 1)]),
			"text": _shape_text(rng, rng.randi_range(0, 5)),
			"state": {"reached": rng.randf() < 0.6, "threads": threads},
		})
	var contact_hits := 0
	var scripted_hits := 0
	var dm_hits := 0
	var wrong := 0
	for t in trials:
		var got := ChatModel.route_for(t["buffer"], t["text"], t["state"])
		if got != _oracle(t["buffer"], t["text"], bool(t["state"]["reached"]), t["state"]["threads"]):
			wrong += 1
		if got == ChatroomScript.ROUTE_CONTACT:
			contact_hits += 1
		elif got == ChatroomScript.ROUTE_SCRIPTED:
			scripted_hits += 1
		if String(t["buffer"]).begins_with("dm:") and got != ChatroomScript.ROUTE_COMMAND:
			dm_hits += 1
	var outside := _outside(trials, ChatModel.route_for)
	_ok("route_matches_oracle_on_every_trial", wrong == 0, "%d of %d trials disagree with the oracle" % [wrong, trials.size()])
	# a router that sends every ordinary line to the model-backed thread must be caught by the same counter
	var greedy := func(_b: String, text: String, _s: Dictionary) -> String:
		return ChatroomScript.ROUTE_COMMAND if ChatModel.route_for("", text, {}) == ChatroomScript.ROUTE_COMMAND else ChatroomScript.ROUTE_CONTACT
	_neg("route_stub_sends_everything_to_the_thread", _outside(trials, greedy) > 0)
	print("CHATCLIENT_FUZZ trials=%d contact_hits=%d scripted_hits=%d dm_hits=%d contact_outside=%d" % [trials.size(), contact_hits, scripted_hits, dm_hits, outside])
