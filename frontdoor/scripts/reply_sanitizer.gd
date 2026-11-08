extends RefCounted
class_name ReplySanitizer

## Display gate for the model's `say` line (Spec #519). The `say` text is
## display-only: it is never parsed, executed, or re-routed. This gate makes
## it a single clean line, or rejects it outright so the shell prints a
## template line instead.
##
## Rejected (ok=false) when the text contains a think marker, a code fence,
## or any REASON_WINDOW-character window of the model's reasoning stream
## (a leak of chain-of-thought into content). Control characters and ANSI
## escape sequences are stripped; whitespace collapses to single spaces.

const REASON_WINDOW := 24
const DEFAULT_MAX := 120


## Returns {ok: bool, text: String, reason: String}. `reasoning` is the raw
## reasoning text when the caller has it (tests, thinking-enabled runs);
## empty otherwise.
static func sanitize(say: String, reasoning: String = "", max_chars: int = DEFAULT_MAX) -> Dictionary:
	var lowered := say.to_lower()
	if lowered.contains("<think") or lowered.contains("</think"):
		return {"ok": false, "text": "", "reason": "think_marker"}
	if say.contains("```"):
		return {"ok": false, "text": "", "reason": "code_fence"}
	if reasoning.length() >= REASON_WINDOW:
		var flat_say := _collapse(say)
		var flat_reason := _collapse(reasoning)
		for i in range(0, flat_reason.length() - REASON_WINDOW + 1):
			if flat_say.contains(flat_reason.substr(i, REASON_WINDOW)):
				return {"ok": false, "text": "", "reason": "reasoning_window"}
	var cleaned := _collapse(_strip_escapes(say))
	if cleaned.length() > max_chars:
		cleaned = cleaned.substr(0, max_chars).strip_edges()
	if cleaned.is_empty():
		return {"ok": false, "text": "", "reason": "empty"}
	return {"ok": true, "text": cleaned, "reason": ""}


## Removes ANSI CSI/OSC escape sequences (ESC followed by up to the final
## byte) before control characters are dropped.
static func _strip_escapes(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		var c := s.unicode_at(i)
		if c == 27:
			i += 1
			if i < s.length() and (s[i] == "[" or s[i] == "]"):
				i += 1
				while i < s.length():
					var f := s.unicode_at(i)
					i += 1
					if (f >= 64 and f <= 126) or f == 7:
						break
			continue
		out += char(c)
		i += 1
	return out


## Control characters -> space, runs of whitespace -> one space, trimmed.
static func _collapse(s: String) -> String:
	var out := ""
	var last_space := true
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c < 32 or c == 127 or c == 32:
			if not last_space:
				out += " "
				last_space = true
			continue
		out += char(c)
		last_space = false
	return out.strip_edges()
