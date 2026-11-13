extends RefCounted
class_name FunnelGuard

## The no-lie guard (Spec #573). A model reply is accepted or rejected here, in
## code, as one lexical pass over the whole reply; a rejected reply is replaced by
## the stage's authored fallback beat and never rendered. The model only ever
## writes {say, claims}: there is no field that could move a stage.
##
## The guard is lexical. A fluent lie in plain words that the data lists do not
## name can pass, which is why the prompt only ever contains facts available at
## the stage, and why the battery in tests/funnel_unit.gd, the fake-model rows and
## a human walk exist. Pure: no clock, no randomness, no file access.

const MAX_RAW := 2000
const DEFAULT_SAY := 240
const DEFAULT_CLAIMS := 3


## The strict reply schema sent to the model: say and claims, nothing else.
static func schema(max_say: int = DEFAULT_SAY, max_claims: int = DEFAULT_CLAIMS) -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"say": {"type": "string", "maxLength": max_say},
			"claims": {"type": "array", "items": {"type": "string"}, "maxItems": max_claims},
		},
		"required": ["say", "claims"],
		"additionalProperties": false,
	}


## ctx: {
##   guard: funnel.json "guard" section,
##   facts: the briefing facts AVAILABLE at this stage (id, text),
##   allowed_text: Array of strings whose words and numbers may appear (beats,
##                 names, dossier values),
##   stage_index: int, pitch_index: int (before it, withheld words are refused),
##   max_say: int, reasoning: String (the server's reasoning text, may be empty) }
## Returns {ok, say, claims, reason}. `reason` names the first rule that failed.
static func check(content: String, ctx: Dictionary) -> Dictionary:
	var bad := {"ok": false, "say": "", "claims": [], "reason": ""}
	var max_say := int(ctx.get("max_say", DEFAULT_SAY))
	if content.length() > MAX_RAW:
		bad["reason"] = "oversize"
		return bad
	var parser := JSON.new()
	if parser.parse(content) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		bad["reason"] = "not_json"
		return bad
	var obj: Dictionary = parser.data
	if not obj.has("say"):
		bad["reason"] = "keys"
		return bad
	if not obj.has("claims"):
		bad["reason"] = "claims_missing"
		return bad
	if obj.size() != 2:
		bad["reason"] = "extra_key"
		return bad
	if typeof(obj["say"]) != TYPE_STRING or typeof(obj["claims"]) != TYPE_ARRAY:
		bad["reason"] = "types"
		return bad
	if String(obj["say"]).length() > max_say:
		bad["reason"] = "say_too_long"
		return bad
	var cleaned := ReplySanitizer.sanitize(String(obj["say"]), String(ctx.get("reasoning", "")), max_say)
	if not bool(cleaned["ok"]):
		bad["reason"] = String(cleaned["reason"])
		return bad
	var say := fold_chars(String(cleaned["text"]))
	var claims: Array = obj["claims"]
	if claims.size() > DEFAULT_CLAIMS:
		bad["reason"] = "claims_count"
		return bad
	var available := {}
	for f in ctx.get("facts", []):
		available[String(f.get("id", ""))] = true
	for c in claims:
		if typeof(c) != TYPE_STRING or not available.has(String(c)):
			bad["reason"] = "unknown_claim"
			return bad
	var g: Dictionary = ctx.get("guard", {})
	var flat := " " + norm(say) + " "
	if _hits_any(flat, g.get("lie_patterns", [])):
		bad["reason"] = "denial"
		return bad
	if _hits_any(flat, g.get("secrecy_patterns", [])):
		bad["reason"] = "secrecy"
		return bad
	if _hits_any(flat, g.get("twist_words", [])):
		bad["reason"] = "twist"
		return bad
	if int(ctx.get("stage_index", 0)) < int(ctx.get("pitch_index", 0)) and (_hits_any(flat, g.get("withheld_until_pitch", [])) or _hits_squashed(flat, g.get("withheld_until_pitch", []))):
		bad["reason"] = "early_where_what"
		return bad
	var vocab := _vocabulary(ctx)
	var reason := _unlisted(say, vocab, g)
	if not reason.is_empty():
		bad["reason"] = reason
		return bad
	return {"ok": true, "say": say, "claims": claims.duplicate(), "reason": ""}


## Width, format and quote folding that keeps case: full-width forms become ASCII,
## zero-width and other invisible format characters are dropped, curly quotes become
## straight ones (a stand-in for NFKC, which the engine does not ship).
static func fold_chars(text: String) -> String:
	var out := ""
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c >= 0xFF01 and c <= 0xFF5E:
			c -= 0xFEE0
		elif c == 0x3000:
			c = 32
		elif c in [0x2018, 0x2019, 0x201B, 0x2032, 0x60, 0xB4]:
			c = 39
		elif (c >= 0x200B and c <= 0x200F) or (c >= 0x202A and c <= 0x202E) or (c >= 0x2060 and c <= 0x2064) or c == 0xFEFF or c == 0xAD or c == 0x034F:
			continue
		out += char(c)
	return out


const _CONTRACTIONS := [["won't", "will not"], ["can't", "can not"], ["cannot", "can not"], ["shan't", "shall not"], ["ain't", "is not"], ["n't", " not"], ["'re", " are"], ["'m", " am"], ["'ll", " will"], ["'ve", " have"], ["'d", " would"], ["'s", " is"]]


## The form a reply or a pattern is matched in: folded, lower case, contractions
## expanded, ASCII words only, and runs of three or more single letters joined
## ("e m p i r e" reads as "empire").
static func norm(text: String) -> String:
	var t := fold_chars(text).to_lower()
	for pair in _CONTRACTIONS:
		t = t.replace(String(pair[0]), String(pair[1]))
	var words: PackedStringArray = ChatroomScript.normalize(t).split(" ", false)
	var out: Array = []
	var run: Array = []
	for w in words:
		if String(w).length() == 1:
			run.append(String(w))
			continue
		out.append_array(_flush(run))
		run = []
		out.append(String(w))
	out.append_array(_flush(run))
	return " ".join(PackedStringArray(out))


static func _flush(run: Array) -> Array:
	if run.size() >= 3:
		return ["".join(PackedStringArray(run))]
	return run


## True when any pattern occurs in `flat` as whole words (both sides go through norm()).
static func _hits_any(flat: String, patterns: Array) -> bool:
	for p in patterns:
		var n := norm(String(p))
		if not n.is_empty() and flat.contains(" " + n + " "):
			return true
	return false


## Long withheld words are also looked for with the spaces taken out, which catches
## "em pire" and "e-m-p-i-r-e" style splitting.
static func _hits_squashed(flat: String, patterns: Array) -> bool:
	var squashed := flat.replace(" ", "")
	for p in patterns:
		var n := norm(String(p)).replace(" ", "")
		if n.length() >= 6 and squashed.contains(n):
			return true
	return false


## Every normalised word that the reply is allowed to repeat: the available
## facts, the beats and names and dossier values passed in, and the common words.
static func _vocabulary(ctx: Dictionary) -> Dictionary:
	var vocab := {}
	var texts: Array = []
	for f in ctx.get("facts", []):
		texts.append(String(f.get("text", "")))
	texts.append_array(ctx.get("allowed_text", []))
	texts.append_array((ctx.get("guard", {}) as Dictionary).get("common_words", []))
	for t in texts:
		for w in ChatroomScript.normalize(String(t)).split(" ", false):
			vocab[String(w)] = true
	return vocab


## "number" for a digit run or a number word that no allowed text contains,
## "name" for a capitalised word that is neither in the vocabulary nor common,
## "" when the reply invents neither.
static func _unlisted(say: String, vocab: Dictionary, g: Dictionary) -> String:
	var digits := RegEx.new()
	digits.compile("[0-9]+")
	for m in digits.search_all(say):
		if not vocab.has(m.get_string()):
			return "number"
	var number_words: Array = g.get("number_words", [])
	var words := RegEx.new()
	words.compile("[A-Za-z][A-Za-z']*")
	for m in words.search_all(say):
		var tok := m.get_string()
		var low := tok.to_lower().split("'")[0]
		if number_words.has(low) and not vocab.has(low):
			return "number"
		if low.length() > 1 and tok.unicode_at(0) >= 65 and tok.unicode_at(0) <= 90 and not vocab.has(low):
			return "name"
	return ""
