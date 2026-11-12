extends RefCounted
class_name ChatModel

## Pure state and rules of the chat client (Spec #562): rooms and their
## presence, the buffers (one per joined room and per open direct message), the
## unread counters, the input history ring, command parsing, name completion and
## row formatting. No scene, no font, no clock, no model: every function here is
## a plain function of its arguments, so the unit harness drives it directly.
##
## Who may reach the model is decided by `route_for` below, in code. The words
## the player sees come from the data files, not from this file.

const MAX_ROWS := 500
const MAX_INPUT := 200
const MIN_ROSTER := 4
const HISTORY_MAX := 50
const DM_PREFIX := "dm:"
const KIND_ROOM := "room"
const KIND_DM := "dm"

## Row kinds. Only voice and action rows count as unread.
const ROW_VOICE := "voice"
const ROW_SELF := "self"
const ROW_ACTION := "action"
const ROW_PRESENCE := "presence"
const ROW_SYSTEM := "system"

## Bare words that leave the client (also accepted with a leading slash).
const LEAVE_WORDS := ["leave", "exit", "quit"]
const VERBS := ["join", "part", "list", "who", "msg", "me", "clear"]

var self_handle: String = ""
var rooms: Dictionary = {}
var room_order: Array = []
var buffers: Dictionary = {}
var active: String = ""

var _history: Array = []
var _history_i: int = -1
var _history_stash: String = ""
var _seq: int = 0


## --- Setup --------------------------------------------------------------------

## Builds the rooms and buffers from the loaded script and opens the entry room.
func setup(script: Dictionary, handle: String, entry_id: String) -> void:
	self_handle = handle
	rooms = {}
	room_order = []
	buffers = {}
	active = ""
	_history = []
	_history_i = -1
	for r in script.get("rooms", []):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var rid := String(r.get("id", ""))
		var handles: Array = []
		for v in r.get("voices", []):
			handles.append(String(v.get("handle", "")))
		rooms[rid] = {
			"id": rid,
			"name": String(r.get("name", rid)),
			"title": String(r.get("title", rid)),
			"topic": String(r.get("topic", "")),
			"voices": handles,
			"present": handles.duplicate(),
			"joined": false,
		}
		room_order.append(rid)
		buffers[rid] = _new_buffer(rid, KIND_ROOM, String(r.get("name", rid)))
	if rooms.has(entry_id):
		join(entry_id)
		active = entry_id


static func _new_buffer(id: String, kind: String, title: String) -> Dictionary:
	return {"id": id, "kind": kind, "title": title, "rows": [], "unread": 0, "scroll": 0, "draft": "", "open": false}


## --- Buffers --------------------------------------------------------------------

static func dm_id(handle: String) -> String:
	return DM_PREFIX + handle


func is_dm(buffer_id: String) -> bool:
	return buffers.has(buffer_id) and String(buffers[buffer_id]["kind"]) == KIND_DM


func is_room(buffer_id: String) -> bool:
	return rooms.has(buffer_id)


func is_open(buffer_id: String) -> bool:
	return buffers.has(buffer_id) and bool(buffers[buffer_id]["open"])


## Ids of the open buffers in navigation order: joined rooms in data order, then
## the open direct messages in alphabetical order of the other party.
func open_order() -> Array:
	var out: Array = []
	for rid in room_order:
		if bool(rooms[rid]["joined"]):
			out.append(rid)
	var dms: Array = []
	for id in buffers:
		if String(buffers[id]["kind"]) == KIND_DM and bool(buffers[id]["open"]):
			dms.append(String(id))
	dms.sort()
	out.append_array(dms)
	return out


## True when the room was newly joined; joining a joined room changes nothing.
func join(room_id: String) -> bool:
	if not rooms.has(room_id) or bool(rooms[room_id]["joined"]):
		return false
	rooms[room_id]["joined"] = true
	buffers[room_id]["open"] = true
	return true


## True when the buffer was closed. The last open buffer is never closed.
func part(buffer_id: String) -> bool:
	if not is_open(buffer_id) or open_order().size() <= 1:
		return false
	var order := open_order()
	var at := order.find(buffer_id)
	if rooms.has(buffer_id):
		rooms[buffer_id]["joined"] = false
	buffers[buffer_id]["open"] = false
	buffers[buffer_id]["unread"] = 0
	if active == buffer_id:
		var rest := open_order()
		active = String(rest[clampi(at - 1, 0, rest.size() - 1)])
		buffers[active]["unread"] = 0
	return true


## True when the direct message was newly opened (it keeps its old rows).
func open_dm(handle: String) -> bool:
	var id := dm_id(handle)
	if not buffers.has(id):
		buffers[id] = _new_buffer(id, KIND_DM, handle)
	if bool(buffers[id]["open"]):
		return false
	buffers[id]["open"] = true
	return true


func switch_to(buffer_id: String) -> bool:
	if not is_open(buffer_id):
		return false
	active = buffer_id
	buffers[buffer_id]["unread"] = 0
	return true


## Next (+1) or previous (-1) open buffer, wrapping around.
func cycle(direction: int) -> void:
	var order := open_order()
	if order.is_empty():
		return
	var at := order.find(active)
	switch_to(String(order[posmod(at + direction, order.size())]))


## Jumps to the n-th open buffer (1-based); false when there is none.
func jump(n: int) -> bool:
	var order := open_order()
	if n < 1 or n > order.size():
		return false
	return switch_to(String(order[n - 1]))


func set_draft(buffer_id: String, text: String) -> void:
	if buffers.has(buffer_id):
		buffers[buffer_id]["draft"] = text


func draft_of(buffer_id: String) -> String:
	return String(buffers[buffer_id]["draft"]) if buffers.has(buffer_id) else ""


## --- Rows and unread -----------------------------------------------------------------

## Appends one row. A row that lands in a closed direct message reopens it. The
## active buffer never counts unread; a scrolled-back view keeps its place.
func add_row(buffer_id: String, row: Dictionary) -> void:
	if not buffers.has(buffer_id):
		return
	var b: Dictionary = buffers[buffer_id]
	if String(b["kind"]) == KIND_DM and not bool(b["open"]):
		b["open"] = true
	b["rows"].append(row)
	while b["rows"].size() > MAX_ROWS:
		b["rows"].pop_front()
	if int(b["scroll"]) > 0:
		b["scroll"] = mini(int(b["scroll"]) + 1, b["rows"].size() - 1)
	var kind := String(row.get("kind", ROW_SYSTEM))
	if buffer_id != active and bool(b["open"]) and (kind == ROW_VOICE or kind == ROW_ACTION):
		b["unread"] = int(b["unread"]) + 1
		_seq += 1
		b["seq"] = _seq


func rows_of(buffer_id: String) -> Array:
	return buffers[buffer_id]["rows"] if buffers.has(buffer_id) else []


func clear_rows(buffer_id: String) -> void:
	if buffers.has(buffer_id):
		buffers[buffer_id]["rows"] = []
		buffers[buffer_id]["scroll"] = 0


func unread_of(buffer_id: String) -> int:
	return int(buffers[buffer_id]["unread"]) if buffers.has(buffer_id) else 0


## The number the MESSAGES label carries: unread rows across the direct messages.
func unread_total() -> int:
	var n := 0
	for id in buffers:
		if String(buffers[id]["kind"]) == KIND_DM and bool(buffers[id]["open"]):
			n += int(buffers[id]["unread"])
	return n


## The newest-opened direct message that has unread rows, or "".
func newest_unread_dm() -> String:
	var best := ""
	var best_seq := -1
	for id in buffers:
		var b: Dictionary = buffers[id]
		if String(b["kind"]) == KIND_DM and bool(b["open"]) and int(b["unread"]) > 0 and int(b.get("seq", 0)) > best_seq:
			best = String(id)
			best_seq = int(b.get("seq", 0))
	return best


func scroll_by(buffer_id: String, delta: int) -> void:
	if not buffers.has(buffer_id):
		return
	var cap: int = maxi(buffers[buffer_id]["rows"].size() - 1, 0)
	buffers[buffer_id]["scroll"] = clampi(int(buffers[buffer_id]["scroll"]) + delta, 0, cap)


func scroll_live(buffer_id: String) -> void:
	if buffers.has(buffer_id):
		buffers[buffer_id]["scroll"] = 0


## --- People and presence -----------------------------------------------------------------

## Every handle that appears in any room, sorted.
func known_handles() -> Array:
	var seen := {}
	for rid in room_order:
		for h in rooms[rid]["voices"]:
			seen[String(h)] = true
	var out: Array = seen.keys()
	out.sort()
	return out


## The roster of a room (the player included once, when joined), sorted. For a
## direct message: the player and the other party.
func roster(buffer_id: String) -> Array:
	var out: Array = []
	if rooms.has(buffer_id):
		out = rooms[buffer_id]["present"].duplicate()
		if bool(rooms[buffer_id]["joined"]):
			out.append(self_handle)
	elif is_dm(buffer_id):
		out = [self_handle, String(buffers[buffer_id]["title"])]
	out.sort()
	return out


## Roster size the directory shows: present voices, plus the player when joined.
func member_count(room_id: String) -> int:
	if not rooms.has(room_id):
		return 0
	return rooms[room_id]["present"].size() + (1 if bool(rooms[room_id]["joined"]) else 0)


func directory() -> Array:
	var out: Array = []
	for rid in room_order:
		var r: Dictionary = rooms[rid]
		out.append({"id": rid, "name": r["name"], "topic": r["topic"], "count": member_count(rid), "joined": bool(r["joined"])})
	return out


## One scripted join or leave in a room, drawn from `rng`; the roster never falls
## below MIN_ROSTER. Returns {kind: "join"|"leave", handle} or {}.
func presence_step(room_id: String, rng: RandomNumberGenerator) -> Dictionary:
	if not rooms.has(room_id):
		return {}
	var r: Dictionary = rooms[room_id]
	var present: Array = r["present"]
	var absent: Array = []
	for h in r["voices"]:
		if not present.has(h):
			absent.append(h)
	var size := present.size() + (1 if bool(r["joined"]) else 0)
	var leave := false
	if absent.is_empty():
		leave = true
	elif size > MIN_ROSTER:
		leave = rng.randf() < 0.5
	if leave:
		if size <= MIN_ROSTER or present.is_empty():
			return {}
		var gone: String = String(present[rng.randi_range(0, present.size() - 1)])
		present.erase(gone)
		return {"kind": "leave", "handle": gone}
	var back: String = String(absent[rng.randi_range(0, absent.size() - 1)])
	present.append(back)
	return {"kind": "join", "handle": back}


## The people pane rows of a buffer: {handle, marker, tone}. Only the player's own
## row carries a marker, and every row has the same tone; the client maps a tone
## to a colour. Nobody else is styled, ordered or marked differently.
static func roster_entries(m: ChatModel, buffer_id: String) -> Array:
	var out: Array = []
	for h in m.roster(buffer_id):
		out.append({"handle": String(h), "marker": "<" if String(h) == m.self_handle else "", "tone": "normal"})
	return out


## What a roster row looks like, as one comparable string.
static func style_signature(entry: Dictionary) -> String:
	return "%s|%s" % [String(entry.get("tone", "")), String(entry.get("marker", ""))]


## Marks `handle` present in the room; true when that is a change.
func set_present(room_id: String, handle: String) -> bool:
	if not rooms.has(room_id) or not rooms[room_id]["voices"].has(handle) or rooms[room_id]["present"].has(handle):
		return false
	rooms[room_id]["present"].append(handle)
	return true


## Exact, ASCII case-insensitive match against the known handles; "" when none.
func find_handle(name: String) -> String:
	var low := _ascii_lower(name.strip_edges())
	if low.is_empty():
		return ""
	for h in known_handles():
		if _ascii_lower(String(h)) == low:
			return String(h)
	return ""


## A room id from what the player typed: the id, the short name, or the number.
func room_id_for(arg: String) -> String:
	var key := _ascii_lower(arg).replace(" ", "").replace("#", "")
	if key.is_empty():
		return ""
	if key.is_valid_int():
		key = "channel" + key
	for rid in room_order:
		if _ascii_lower(String(rid)) == key or _ascii_lower(String(rooms[rid]["name"])).replace(" ", "") == key:
			return String(rid)
	return ""


## --- Input history ---------------------------------------------------------------------------

func history_push(text: String) -> void:
	_history_i = -1
	_history_stash = ""
	if text.strip_edges().is_empty():
		return
	if not _history.is_empty() and String(_history[_history.size() - 1]) == text:
		return
	_history.append(text)
	while _history.size() > HISTORY_MAX:
		_history.pop_front()


## One step back through the lines sent; `current` is kept for the way forward.
func history_prev(current: String) -> String:
	if _history.is_empty():
		return current
	if _history_i == -1:
		_history_stash = current
		_history_i = _history.size() - 1
	else:
		_history_i = maxi(_history_i - 1, 0)
	return String(_history[_history_i])


func history_next() -> String:
	if _history_i == -1:
		return _history_stash
	if _history_i < _history.size() - 1:
		_history_i += 1
		return String(_history[_history_i])
	_history_i = -1
	return _history_stash


func history_size() -> int:
	return _history.size()


## --- Pure rules ------------------------------------------------------------------------------

## Lower-cases ASCII letters only; every other character is untouched.
static func _ascii_lower(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c >= 65 and c <= 90:
			c += 32
		out += char(c)
	return out


static func _is_ascii(s: String) -> bool:
	for i in range(s.length()):
		if s.unicode_at(i) > 127:
			return false
	return true


## Parses one line: {kind, name, body}. kind is "text" (an ordinary line),
## "empty", "quit" (a leave word), "join", "part", "list", "who", "msg", "me",
## "clear" or "unknown" (starts with a slash, is not a known verb). A verb with
## any non-ASCII or punctuation character is unknown: ASCII letters only, folded
## in code, never by the engine's own lower-casing.
static func parse_command(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"kind": "empty", "name": "", "body": ""}
	var flat := " ".join(t.replace("\t", " ").split(" ", false))
	if _is_ascii(flat) and LEAVE_WORDS.has(_ascii_lower(flat)):
		return {"kind": "quit", "name": "", "body": ""}
	if not t.begins_with("/"):
		return {"kind": "text", "name": "", "body": t}
	var parts := flat.split(" ", false)
	var verb := String(parts[0]).substr(1)
	var ok := not verb.is_empty()
	for i in range(verb.length()):
		var c := verb.unicode_at(i)
		if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
			ok = false
	if not ok:
		return {"kind": "unknown", "name": "", "body": ""}
	verb = _ascii_lower(verb)
	if LEAVE_WORDS.has(verb):
		return {"kind": "quit", "name": "", "body": ""}
	if not VERBS.has(verb):
		return {"kind": "unknown", "name": "", "body": ""}
	var rest := flat.substr(String(parts[0]).length()).strip_edges()
	var name := ""
	var body := rest
	if verb == "msg":
		name = rest.split(" ", false)[0] if not rest.is_empty() else ""
		body = rest.substr(name.length()).strip_edges()
	elif verb == "join":
		name = rest
		body = ""
	return {"kind": verb, "name": name, "body": body}


## True when this line, once delivered, is a sent message: an ordinary non-empty
## line, a /me with text, or a /msg with a name and a body. Commands never are.
static func counts_as_message(text: String) -> bool:
	var p := parse_command(text)
	match String(p["kind"]):
		"text":
			return true
		"me":
			return not String(p["body"]).is_empty()
		"msg":
			return not String(p["name"]).is_empty() and not String(p["body"]).is_empty()
	return false


## Which path a line takes (code decides, never the model): a client command,
## the single model-backed thread, or a scripted voice. `state` is
## {reached: bool, threads: Array of buffer ids}. A line is on the model-backed
## thread only when that thread has started and the line is typed in one of its
## buffers.
static func route_for(buffer: String, text: String, state: Dictionary) -> String:
	var kind := String(parse_command(text)["kind"])
	if kind != "text":
		return ChatroomScript.ROUTE_COMMAND
	if bool(state.get("reached", false)) and (state.get("threads", []) as Array).has(buffer):
		return ChatroomScript.ROUTE_CONTACT
	return ChatroomScript.ROUTE_SCRIPTED


## The first name in `names` (sorted) that starts with `prefix`, ASCII case
## folded; `index` cycles through several matches. "" when none.
static func complete_nick(prefix: String, names: Array, index: int = 0) -> String:
	if prefix.is_empty():
		return ""
	var low := _ascii_lower(prefix)
	var hits: Array = []
	var sorted_names := names.duplicate()
	sorted_names.sort()
	for n in sorted_names:
		if _ascii_lower(String(n)).begins_with(low):
			hits.append(String(n))
	if hits.is_empty():
		return ""
	return String(hits[posmod(index, hits.size())])


## The text of a row without its timestamp.
static func plain_line(row: Dictionary) -> String:
	var kind := String(row.get("kind", ROW_SYSTEM))
	var text := String(row.get("text", ""))
	match kind:
		ROW_VOICE, ROW_SELF:
			return "<%s> %s" % [String(row.get("handle", "")), text]
		ROW_ACTION:
			return "* %s %s" % [String(row.get("handle", "")), text]
	return text


## One row as display lines of at most `width` cells: "[HH:MM] <HANDLE> body",
## wrapped at word boundaries with continuation lines indented, long words split.
static func format_row(row: Dictionary, width: int) -> Array:
	var prefix := "[%s] " % String(row.get("t", "00:00"))
	var avail := maxi(width, 8)
	var kind := String(row.get("kind", ROW_SYSTEM))
	var indent := prefix.length()
	if kind == ROW_VOICE or kind == ROW_SELF:
		indent += String(row.get("handle", "")).length() + 3
	var pad := " ".repeat(mini(indent, avail / 3))
	var lines: Array = []
	var cur := ""
	for w in (prefix + plain_line(row)).split(" ", false):
		var word := String(w)
		if cur.is_empty():
			cur = word
		elif cur.length() + 1 + word.length() <= avail:
			cur += " " + word
		else:
			lines.append(cur)
			cur = pad + word
		while cur.length() > avail:
			lines.append(cur.substr(0, avail))
			cur = pad + cur.substr(avail)
	if not cur.is_empty():
		lines.append(cur)
	if lines.is_empty():
		lines.append(prefix.strip_edges())
	return lines
