extends RefCounted
class_name HandlerNames

## The player's designation and the generated Empire handler name (Spec #573).
## Pure functions of a seed and the syllable lists in funnel_names.json: no clock,
## no engine randomness, no file access. A name is one or two syllables (onset,
## vowel, coda) in upper case with an optional -NN suffix, so it reads like the
## other voices in the room. It never repeats a voice already known to the
## player (the static cast, the designation, a reserved word, an earlier handler).

const DESIGNATION_PREFIX := "newb"
const MIN_LETTERS := 3


## "newb" plus exactly four digits, drawn from the seed.
static func designation(seed_value: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x3a7c91d5
	return "%s%04d" % [DESIGNATION_PREFIX, rng.randi_range(0, 9999)]


## One name for this seed that is not in `avoid` (compared on the letter part and
## on the whole string, ASCII upper case) and not a reserved word.
static func generate(parts: Dictionary, seed_value: int, avoid: Array = []) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x51ed270b
	var banned := {}
	for a in avoid:
		var up := String(a).to_upper()
		banned[up] = true
		banned[letters_of(up)] = true
	for r in parts.get("reserved", []):
		banned[String(r).to_upper()] = true
	var last := ""
	for attempt in range(400):
		var name := _draw(parts, rng)
		last = name
		if not banned.has(name) and not banned.has(letters_of(name)):
			return name
	# The lists are never this crowded; keep the answer deterministic and distinct anyway.
	var n := 1
	while banned.has(last + "-" + str(n)):
		n += 1
	return last + "-" + str(n)


static func _draw(parts: Dictionary, rng: RandomNumberGenerator) -> String:
	var max_len := int(parts.get("max_len", 11))
	var word := ""
	for guard in range(300):
		var syllables := 1 if rng.randf() < 0.15 else 2
		word = ""
		for i in range(syllables):
			word += _syllable(parts, rng)
		if word.length() >= MIN_LETTERS and word.length() <= max_len:
			break
	if word.length() > max_len:
		word = word.substr(0, max_len)
	# A one-syllable name always carries a suffix: the short unsuffixed names are few
	# enough that two players could draw the same one.
	if word.length() <= 5 or rng.randf() < float(parts.get("suffix_share", 0.5)):
		word += "-" + str(rng.randi_range(1, int(parts.get("suffix_max", 99))))
	return word


static func _syllable(parts: Dictionary, rng: RandomNumberGenerator) -> String:
	var onsets: Array = parts["onsets"]
	var vowels: Array = parts["vowels"]
	var codas: Array = parts["codas"]
	return String(onsets[rng.randi_range(0, onsets.size() - 1)]) + String(vowels[rng.randi_range(0, vowels.size() - 1)]) + String(codas[rng.randi_range(0, codas.size() - 1)])


## The letters before any -NN suffix.
static func letters_of(name: String) -> String:
	var at := name.find("-")
	return name if at < 0 else name.substr(0, at)


## True when the name looks like the voices already in the room: upper-case
## letters, then an optional hyphen and one or two digits.
static func looks_ordinary(name: String) -> bool:
	var re := RegEx.new()
	re.compile("^[A-Z]{3,11}(-[0-9]{1,2})?$")
	return re.search(name) != null


## Every word the lists can produce within max_len letters, enumerated once:
## {enumerated: how many were generated, distinct: how many different ones, longest}.
static func enumerate_words(parts: Dictionary) -> Dictionary:
	var max_len := int(parts.get("max_len", 11))
	var syl := PackedStringArray()
	for o in parts["onsets"]:
		for v in parts["vowels"]:
			for c in parts["codas"]:
				syl.append(String(o) + String(v) + String(c))
	var words := PackedStringArray()
	for sy in syl:
		if sy.length() <= max_len:
			words.append(sy)
	for a in syl:
		for b in syl:
			if a.length() + b.length() <= max_len:
				words.append(a + b)
	var enumerated := words.size()
	words.sort()
	var distinct := 0
	var longest := 0
	var prev := ""
	for w in words:
		if w != prev:
			distinct += 1
			longest = maxi(longest, w.length())
			prev = w
	return {"enumerated": enumerated, "distinct": distinct, "longest": longest}


## How many distinct names the lists can produce (letter part within max_len,
## times the suffix choices): a measured count, not a product that ambiguous
## concatenations would overstate.
static func space(parts: Dictionary) -> int:
	return int(enumerate_words(parts)["distinct"]) * (1 + int(parts.get("suffix_max", 99)))
