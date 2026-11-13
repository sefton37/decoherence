extends RefCounted
class_name HandlerView

## The view model of the HANDLER screen (Spec #575): what the two panes say, as data,
## and how a pane's entries wrap into rows of a given width. Pure: no node, no file, no
## clock and no randomness. Every label comes from handler_ui.json, every colonist value
## from the stored dossier, and every player value from the saved profile and the
## handler's dossier file; a value is never formatted into a template, so braces and
## long words in a player's answer stay literal.

const LABEL_MAX := 26


## The pane contents for `profile` (its first assignment is the colonist) under `ui` and `rules`.
## {title, handle, pane_titles, dossier: [{section, label, rows: [{id, label, value}]}],
## profile: [{id, label, value}], launch_label, accepted, status}.
static func build(profile: Dictionary, player_fields: Dictionary, ui: Dictionary, rules: Dictionary) -> Dictionary:
	var colonist: Dictionary = {}
	var assigned: Variant = profile.get("assignments", [])
	if typeof(assigned) == TYPE_ARRAY and (assigned as Array).size() > 0 and typeof(assigned[0]) == TYPE_DICTIONARY:
		colonist = assigned[0]
	var f: Dictionary = colonist.get("fields", {})
	var labels: Dictionary = ui.get("field_labels", {})
	var values: Dictionary = ui.get("value_labels", {})
	var sections: Array = []
	for s in rules.get("sections", []):
		var sid := String(s["id"])
		var rows: Array = []
		for fd in rules.get("fields", []):
			if String(fd["section"]) != sid:
				continue
			var id := String(fd["id"])
			var raw := _show(f[id]) if f.has(id) else ""
			var shown := String(values.get(raw, raw))
			rows.append({"id": id, "label": String(labels.get(id, "")), "value": shown if not shown.is_empty() else String(ui.get("not_on_file", ""))})
		sections.append({"section": sid, "label": String(ui.get("section_labels", {}).get(sid, "")), "rows": rows})
	var accepted := ProfileStore.mission_accepted(profile)
	var pv: Dictionary = ui.get("profile_values", {})
	var pl: Dictionary = ui.get("profile_labels", {})
	var player: Dictionary = profile.get("player", {})
	var handler: Dictionary = profile.get("handler", {})
	var former: Array = handler.get("former", []) if typeof(handler.get("former", null)) == TYPE_ARRAY else []
	var not_on_file := String(ui.get("not_on_file", ""))
	var origin := String(player_fields.get("origin", ""))
	var doing := String(player_fields.get("doing", ""))
	var former_names: Array = []
	for n in former:
		former_names.append(String(n))
	var prow := func(id: String, value: String) -> Dictionary:
		return {"id": id, "label": String(pl.get(id, "")), "value": value if not value.is_empty() else not_on_file}
	var profile_rows: Array = [
		prow.call("handle", String(player.get("handle", ""))),
		prow.call("former_designation", String(player.get("designation", ""))),
		prow.call("status", String(pv.get("status_accepted", "")) if accepted else String(pv.get("status_pending", ""))),
		prow.call("handler_name", String(handler.get("name", ""))),
		prow.call("handler_kind", String(pv.get("kind_empire", ""))),
		prow.call("former_handlers", ", ".join(PackedStringArray(former_names)) if not former_names.is_empty() else String(pv.get("none", ""))),
		prow.call("origin", origin),
		prow.call("doing", doing),
		prow.call("colonist", (String(f.get("given_name", "")) + " " + String(f.get("family_name", ""))).strip_edges()),
	]
	return {
		"title": String(ui.get("title", "")),
		"handle": String(player.get("handle", "")),
		"pane_titles": ui.get("pane_titles", {}),
		"dossier": sections,
		"profile": profile_rows,
		"launch_label": String(ui.get("launch_label", "")),
		"accepted": accepted,
		"status": String(ui.get("accepted_status", "")) if accepted else String(ui.get("pending_status", "")),
	}


## `text` cut into rows of at most `width` characters at spaces; a word longer than a row is broken.
static func wrap_text(text: String, width: int) -> Array:
	var rows: Array = []
	var w := maxi(width, 1)
	var cur := ""
	for word in text.split(" ", false):
		var token := String(word)
		while token.length() > w:
			if not cur.is_empty():
				rows.append(cur)
				cur = ""
			rows.append(token.substr(0, w))
			token = token.substr(w)
		if token.is_empty():
			continue
		if cur.is_empty():
			cur = token
		elif cur.length() + 1 + token.length() <= w:
			cur += " " + token
		else:
			rows.append(cur)
			cur = token
	if not cur.is_empty() or rows.is_empty():
		rows.append(cur)
	return rows


## A stored number back as it reads: a whole number that went through JSON as a float shows without its decimal.
static func _show(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT and is_equal_approx(float(v), floorf(float(v))):
		return str(int(v))
	return str(v)


## Side by side needs the longest label to fit in half the pane; a narrower pane stacks each field instead.
static func _stacked(entries: Array, width: int) -> bool:
	var m := 0
	for e in entries:
		m = maxi(m, String(e["label"]).length())
	return m + 2 > width / 2 or m + 2 > LABEL_MAX


static func _label_width(entries: Array, width: int) -> int:
	var m := 0
	for e in entries:
		m = maxi(m, String(e["label"]).length())
	return mini(m + 2, mini(LABEL_MAX, maxi(width / 2, 4)))


## One field as rows. Side by side: the label padded to `label_w`, then the wrapped value, continuation
## rows indented. Stacked: the label on its own row, then the value indented by two.
static func _field_rows(id: String, label: String, value: String, label_w: int, width: int, stacked: bool) -> Array:
	var out: Array = []
	if stacked:
		out.append({"t": (label + ":").substr(0, width), "kind": "label", "id": id, "label_w": 0})
		for chunk in wrap_text(value, maxi(width - 2, 1)):
			out.append({"t": "  " + String(chunk), "kind": "value", "id": id, "label_w": 2})
		return out
	var chunks := wrap_text(value, maxi(width - label_w, 1))
	for i in range(chunks.size()):
		var head := (label + ":").substr(0, label_w - 1).rpad(label_w) if i == 0 else " ".repeat(label_w)
		out.append({"t": head + String(chunks[i]), "kind": "field" if i == 0 else "cont", "id": id, "label_w": label_w})
	return out


## The dossier pane's rows for a pane `width` cells wide: a heading per section, its fields, a blank row between sections.
static func dossier_lines(view: Dictionary, width: int) -> Array:
	var all_rows: Array = []
	for s in view["dossier"]:
		all_rows.append_array(s["rows"])
	var lw := _label_width(all_rows, width)
	var stacked := _stacked(all_rows, width)
	var out: Array = []
	var first := true
	for s in view["dossier"]:
		if not first:
			out.append({"t": "", "kind": "blank", "id": ""})
		first = false
		for h in wrap_text(String(s["label"]), width):
			out.append({"t": String(h), "kind": "section", "id": String(s["section"])})
		for r in s["rows"]:
			out.append_array(_field_rows(String(r["id"]), String(r["label"]), String(r["value"]), lw, width, stacked))
	return out


static func profile_lines(view: Dictionary, width: int) -> Array:
	var lw := _label_width(view["profile"], width)
	var stacked := _stacked(view["profile"], width)
	var out: Array = []
	for r in view["profile"]:
		out.append_array(_field_rows(String(r["id"]), String(r["label"]), String(r["value"]), lw, width, stacked))
	return out


static func max_scroll(line_count: int, view_rows: int) -> int:
	return maxi(line_count - view_rows, 0)
