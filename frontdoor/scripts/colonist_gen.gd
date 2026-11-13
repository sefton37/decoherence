extends RefCounted
class_name ColonistGen

## The colonist generator of the HANDLER module (Spec #575, design rows 218 and 219).
##
## Pure functions over three arguments: a seed, the tables (colonist_tables.json) and
## the rules (colonist_rules.json). Candidate values are DRAWN from the tables with a
## seeded generator, the rules accept or reject each draw, and a rejected draw is made
## again (bounded by rules.max_attempts). Nothing here reads a file, a clock, the
## network, a model or the global random state, and no authored word is spelled in
## this file: every word of a colonist comes from a table entry or from a template.
##
## A dossier is {template_version, seed, fields, src}. `fields` holds the 22 values the
## rules name; `src` says where each one came from (a table and an index, a range, a
## derivation, a rule, the profile, or an assembly of numbered templates).
##
## `validate` re-checks a finished dossier and returns the ids of the rules it breaks.
## Strict mode also re-derives the bio and checks every table value against the table
## (fresh colonists, the fuzz and the negative controls); lenient mode checks only what
## must hold for a stored colonist, so a later edit of an authored word never changes a
## player's colonist (`ensure`).

const RULE_IDS := ["age", "years", "profession_age", "hub_kind", "trait_exclusion", "trait_count", "slot", "bio", "intimate_set", "intimate_len", "service", "specialization", "field_set", "src"]
const INTIMATE_FIELDS := ["relationship_status", "orientation", "history_band", "private_line"]
const SLOT_RE := "\\{[A-Za-z_0-9]+\\}"

static var _slot_regex: RegEx = null


## A stable seed from the two persisted names: a hash prefix, never the engine's string hash.
static func seed_for(designation: String, handler_name: String) -> int:
	var h := (designation + "|" + handler_name).sha256_text()
	return h.substr(0, 12).hex_to_int()


static func field_ids(rules: Dictionary) -> Array:
	var out: Array = []
	for fd in rules.get("fields", []):
		out.append(String(fd["id"]))
	return out


## --- tables -------------------------------------------------------------------------------------------

## The list a table path names: "hubs", "traits" or "intimate.orientation".
static func table_list(tables: Dictionary, path: String) -> Array:
	var parts := path.split(".")
	var cur: Variant = tables
	for p in parts:
		if typeof(cur) != TYPE_DICTIONARY or not (cur as Dictionary).has(p):
			return []
		cur = cur[p]
	return cur if typeof(cur) == TYPE_ARRAY else []


## The text a table entry shows: a string as it is, an object by its name or label.
static func table_entry_text(tables: Dictionary, path: String, index: int) -> String:
	var list := table_list(tables, path)
	if index < 0 or index >= list.size():
		return ""
	var e: Variant = list[index]
	if typeof(e) == TYPE_DICTIONARY:
		return String(e.get("name", e.get("label", "")))
	return String(e)


static func _index_of_text(tables: Dictionary, path: String, text: String) -> int:
	var list := table_list(tables, path)
	for i in range(list.size()):
		if table_entry_text(tables, path, i) == text:
			return i
	return -1


static func _entry_by_text(tables: Dictionary, path: String, text: String) -> Dictionary:
	var i := _index_of_text(tables, path, text)
	if i < 0:
		return {}
	var e: Variant = table_list(tables, path)[i]
	return e if typeof(e) == TYPE_DICTIONARY else {}


static func _regex() -> RegEx:
	if _slot_regex == null:
		_slot_regex = RegEx.new()
		_slot_regex.compile(SLOT_RE)
	return _slot_regex


static func slots_of(text: String) -> Array:
	var out: Array = []
	for m in _regex().search_all(text):
		var s := m.get_string()
		out.append(s.substr(1, s.length() - 2))
	return out


## --- generation ---------------------------------------------------------------------------------------------

## {ok, dossier, rejects, attempts}. `rejects` counts, per rule id, the draws that rule threw away.
static func generate_ex(seed_value: int, tables: Dictionary, rules: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cap := int(rules.get("max_attempts", 40))
	var rejects := {}
	for id in RULE_IDS:
		rejects[id] = 0
	var attempts := 0
	var f := {}
	var src := {}
	var fail := {"ok": false, "dossier": {}, "rejects": rejects, "attempts": attempts}

	f["given_name"] = _pick(rng, tables, "given_names", f, src, "given_name")
	f["family_name"] = _pick(rng, tables, "family_names", f, src, "family_name")
	var amin := int(rules["age"]["min"])
	var age := -1
	for i in range(cap):
		attempts += 1
		var a := rng.randi_range(int(rules["age"]["candidate_min"]), int(rules["age"]["max"]))
		if a < amin:
			rejects["age"] += 1
			continue
		age = a
		break
	if age < 0:
		return fail
	f["age"] = age
	src["age"] = {"kind": "range", "rule": "age"}
	f["gender"] = _pick(rng, tables, "gender", f, src, "gender")
	var hub_index := rng.randi_range(0, table_list(tables, "hubs").size() - 1)
	f["hub"] = table_entry_text(tables, "hubs", hub_index)
	src["hub"] = {"kind": "table", "table": "hubs", "index": hub_index}
	var hub_kind := String((table_list(tables, "hubs")[hub_index] as Dictionary).get("kind", ""))
	var years := -1
	var arrival := int(rules["years_resident"]["arrival_age_min"])
	for i in range(cap):
		attempts += 1
		var y := rng.randi_range(0, age - arrival + int(rules["years_resident"]["candidate_margin"]))
		if y < int(rules["years_resident"]["min"]) or y > age - arrival:
			rejects["years"] += 1
			continue
		years = y
		break
	if years < 0:
		return fail
	f["years_resident"] = years
	src["years_resident"] = {"kind": "range", "rule": "years"}
	var prof_index := -1
	var profs := table_list(tables, "professions")
	for i in range(cap):
		attempts += 1
		var pi := rng.randi_range(0, profs.size() - 1)
		var p: Dictionary = profs[pi]
		if age < int(p["min_age"]):
			rejects["profession_age"] += 1
			continue
		if not (p["hub_kinds"] as Array).has(hub_kind):
			rejects["hub_kind"] += 1
			continue
		prof_index = pi
		break
	if prof_index < 0:
		return fail
	f["profession"] = table_entry_text(tables, "professions", prof_index)
	src["profession"] = {"kind": "table", "table": "professions", "index": prof_index}
	f["education"] = _pick(rng, tables, "education", f, src, "education")
	f["service_status"] = String(rules["service"]["status"])
	src["service_status"] = {"kind": "rule", "rule": "service"}
	f["specialization"] = String(rules["service"]["specialization"])
	src["specialization"] = {"kind": "rule", "rule": "specialization"}
	f["handler_of_record"] = String(ctx.get("handler", ""))
	src["handler_of_record"] = {"kind": "profile", "from": "handler.name"}
	f["assisted_by"] = String(ctx.get("handle", ""))
	src["assisted_by"] = {"kind": "profile", "from": "player.handle"}
	var traits := table_list(tables, "traits")
	var chosen: Array = []
	for k in range(int(rules["trait_count"])):
		var got := -1
		for i in range(cap):
			attempts += 1
			var ti := rng.randi_range(0, traits.size() - 1)
			if chosen.has(ti):
				rejects["trait_count"] += 1
				continue
			var clash := false
			for c in chosen:
				if (traits[ti]["excludes"] as Array).has(String(traits[c]["label"])) or (traits[c]["excludes"] as Array).has(String(traits[ti]["label"])):
					clash = true
			if clash:
				rejects["trait_exclusion"] += 1
				continue
			got = ti
			break
		if got < 0:
			return fail
		chosen.append(got)
		f["trait_%d" % (k + 1)] = table_entry_text(tables, "traits", got)
		src["trait_%d" % (k + 1)] = {"kind": "table", "table": "traits", "index": got}
	f["family"] = _pick(rng, tables, "family", f, src, "family")
	for fld in INTIMATE_FIELDS:
		f[fld] = _pick(rng, tables, "intimate." + fld, f, src, fld)
	f["colonist_id"] = String(rules["id_prefix"]) + "%06X" % rng.randi_range(0, 0xFFFFFF)
	src["colonist_id"] = {"kind": "derived", "rule": "colonist_id"}
	# the bio: one numbered template per part, drawn among those whose slots and conditions hold
	var parts: Array = []
	var templates := table_list(tables, "bio_templates")
	for part in rules["bio_parts"]:
		var pool: Array = []
		for t in templates:
			if String(t["part"]) == String(part):
				pool.append(t)
		var picked := {}
		for i in range(cap):
			attempts += 1
			var t: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
			if not template_eligible(t, f, tables):
				rejects["slot"] += 1
				continue
			picked = t
			break
		if picked.is_empty():
			return fail
		parts.append({"part": String(part), "template": String(picked["id"])})
	src["bio"] = {"kind": "assembly", "parts": parts}
	var d := {"template_version": int(rules["template_version"]), "seed": seed_value, "fields": f, "src": src}
	f["bio"] = render_bio(d, tables)
	return {"ok": true, "dossier": _ordered(d, rules), "rejects": rejects, "attempts": attempts}


static func generate(seed_value: int, tables: Dictionary, rules: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var g := generate_ex(seed_value, tables, rules, ctx)
	return g["dossier"] if bool(g.get("ok", false)) else {}


static func _pick(rng: RandomNumberGenerator, tables: Dictionary, path: String, f: Dictionary, src: Dictionary, field: String) -> String:
	var n := table_list(tables, path).size()
	var i := rng.randi_range(0, n - 1)
	src[field] = {"kind": "table", "table": path, "index": i}
	return table_entry_text(tables, path, i)


## The fields in the order the rules name them, so two dossiers compare as text.
static func _ordered(d: Dictionary, rules: Dictionary) -> Dictionary:
	var f: Dictionary = d["fields"]
	var src: Dictionary = d["src"]
	var of := {}
	var os := {}
	for id in field_ids(rules):
		of[id] = f[id]
		os[id] = src[id]
	return {"template_version": d["template_version"], "seed": d["seed"], "fields": of, "src": os}


## --- bio ------------------------------------------------------------------------------------------------------------

## The value a slot takes from the colonist's own fields; "" when it does not resolve.
static func slot_value(slot: String, f: Dictionary, tables: Dictionary) -> String:
	match slot:
		"given_name", "family_name", "hub", "profession", "trait_1", "trait_2", "trait_3", "family":
			return String(f.get(slot, ""))
		"age":
			return str(int(f["age"])) if f.has("age") else ""
		"years":
			return str(int(f["years_resident"])) if f.has("years_resident") else ""
		"they", "them", "their", "They", "Them", "Their":
			var g := _entry_by_text(tables, "gender", String(f.get("gender", "")))
			var key := slot.to_lower()
			if g.is_empty() or not g.has(key):
				return ""
			var word := String(g[key])
			return word.substr(0, 1).to_upper() + word.substr(1) if slot != key else word
	return ""


## A template may be used when every slot in it resolves and every field it requires holds one of the allowed values.
static func template_eligible(t: Dictionary, f: Dictionary, tables: Dictionary) -> bool:
	for slot in slots_of(String(t["text"])):
		if slot_value(slot, f, tables).is_empty():
			return false
	var req: Dictionary = t.get("requires", {})
	for k in req:
		if not (req[k] as Array).has(String(f.get(k, ""))):
			return false
	return true


static func _template_by_id(tables: Dictionary, id: String) -> Dictionary:
	for t in table_list(tables, "bio_templates"):
		if String(t["id"]) == id:
			return t
	return {}


## The bio as the stored template ids and the colonist's own fields assemble it.
static func render_bio(d: Dictionary, tables: Dictionary) -> String:
	var f: Dictionary = d.get("fields", {})
	var parts: Array = d.get("src", {}).get("bio", {}).get("parts", [])
	var sentences: Array = []
	for p in parts:
		var t := _template_by_id(tables, String(p.get("template", "")))
		if t.is_empty():
			return ""
		var text := String(t["text"])
		for slot in slots_of(text):
			text = text.replace("{" + slot + "}", slot_value(slot, f, tables))
		sentences.append(text)
	return " ".join(PackedStringArray(sentences))


## --- validation -----------------------------------------------------------------------------------------------

## The ids of the rules `d` breaks (empty when it is sound). See the header for strict and lenient.
static func validate(d: Dictionary, tables: Dictionary, rules: Dictionary, strict: bool = true) -> Array:
	var v: Array = []
	if typeof(d.get("fields", null)) != TYPE_DICTIONARY or typeof(d.get("src", null)) != TYPE_DICTIONARY:
		return ["field_set"]
	var f: Dictionary = d["fields"]
	var src: Dictionary = d["src"]
	for id in field_ids(rules):
		if not f.has(id) or (typeof(f[id]) == TYPE_STRING and String(f[id]).is_empty()):
			_add(v, "field_set")
	if v.has("field_set"):
		return v
	# Fail closed: a stored age or residence that is not a number is invalid (never coerced).
	for k in ["age", "years_resident"]:
		if typeof(f[k]) != TYPE_INT and typeof(f[k]) != TYPE_FLOAT:
			_add(v, "age" if k == "age" else "years")
			return v
	var age := int(f["age"])
	if age < int(rules["age"]["min"]) or age > int(rules["age"]["max"]):
		_add(v, "age")
	var years := int(f["years_resident"])
	if years < int(rules["years_resident"]["min"]) or years > age - int(rules["years_resident"]["arrival_age_min"]):
		_add(v, "years")
	var prof := _entry_by_text(tables, "professions", String(f["profession"]))
	var hub := _entry_by_text(tables, "hubs", String(f["hub"]))
	if not prof.is_empty():
		if age < int(prof["min_age"]):
			_add(v, "profession_age")
		if not hub.is_empty() and not (prof["hub_kinds"] as Array).has(String(hub.get("kind", ""))):
			_add(v, "hub_kind")
	var labels: Array = [String(f["trait_1"]), String(f["trait_2"]), String(f["trait_3"])]
	if labels[0] == labels[1] or labels[0] == labels[2] or labels[1] == labels[2]:
		_add(v, "trait_count")
	for a in labels:
		var ea := _entry_by_text(tables, "traits", a)
		for b in labels:
			if not ea.is_empty() and (ea["excludes"] as Array).has(b):
				_add(v, "trait_exclusion")
	if String(f["service_status"]) != String(rules["service"]["status"]):
		_add(v, "service")
	if String(f["specialization"]) != String(rules["service"]["specialization"]):
		_add(v, "specialization")
	for fld in INTIMATE_FIELDS:
		if String(f[fld]).length() > int(rules["intimate_max_len"]):
			_add(v, "intimate_len")
		if strict and not (table_list(tables, "intimate." + fld)).has(String(f[fld])):
			_add(v, "intimate_set")
	var bio := String(f["bio"])
	if bio.is_empty() or _regex().search(bio) != null:
		_add(v, "slot")
	if strict:
		for fd in rules["fields"]:
			var id := String(fd["id"])
			if not src.has(id) or typeof(src[id]) != TYPE_DICTIONARY:
				_add(v, "src")
			elif String(fd["src_kind"]) == "table":
				var s: Dictionary = src[id]
				if String(s.get("kind", "")) != "table" or table_entry_text(tables, String(s.get("table", "")), int(s.get("index", -1))) != String(f[id]):
					_add(v, "src")
		var parts: Array = src.get("bio", {}).get("parts", [])
		if render_bio(d, tables) != bio:
			_add(v, "bio")
		for p in parts:
			var t := _template_by_id(tables, String(p.get("template", "")))
			if t.is_empty() or not template_eligible(t, f, tables):
				_add(v, "slot")
	return v


static func _add(list: Array, id: String) -> void:
	if not list.has(id):
		list.append(id)


## --- the store rule -----------------------------------------------------------------------------------------

## The colonist a profile carries, generated when it has none and replaced only when what it
## has fails (lenient) validation. {profile, regenerated, cleared_acceptance}. A regeneration
## clears `acceptance.mission_accepted`, because the mission accepted was another colonist's.
## Unknown keys everywhere in the profile survive.
static func ensure(profile: Dictionary, tables: Dictionary, rules: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var p: Dictionary = profile.duplicate(true)
	var stored: Array = p.get("assignments", []) if typeof(p.get("assignments", null)) == TYPE_ARRAY else []
	var keep := stored.size() == int(rules.get("count", 1)) and typeof(stored[0]) == TYPE_DICTIONARY and validate(stored[0], tables, rules, false).is_empty()
	if keep:
		return {"profile": p, "regenerated": false, "cleared_acceptance": false}
	var designation := String(p["player"]["designation"])
	var handler_name := String(p["handler"]["name"])
	var c := ctx.duplicate()
	if c.is_empty():
		var handle := String(p["player"].get("handle", ""))
		c = {"handler": handler_name, "handle": handle if not handle.is_empty() else designation}
	var g := generate_ex(seed_for(designation, handler_name), tables, rules, c)
	if not bool(g.get("ok", false)):
		return {"profile": p, "regenerated": false, "cleared_acceptance": false}
	p["assignments"] = [g["dossier"]]
	var cleared := false
	var acc: Dictionary = p["acceptance"]
	if bool(acc.get("mission_accepted", false)):
		acc.erase("mission_accepted")
		cleared = true
	return {"profile": p, "regenerated": true, "cleared_acceptance": cleared}
