extends Node
class_name OllamaClient

## Talks to a LOCALLY-running Ollama daemon over its native /api/chat
## endpoint only -- never Ollama's OpenAI-compatibility endpoint, which (per
## project memory) silently ignores options.num_ctx. Every request below
## sets num_ctx explicitly on this native endpoint instead.
##
## Streaming (send_chat) uses the low-level HTTPClient, polled every frame
## via `await get_tree().process_frame` -- NOT the high-level HTTPRequest
## node, which buffers the whole response and cannot surface incremental
## deltas as they arrive (Risk 1).

## Emitted once check_model_ready() has resolved (success or exhausted
## retries) -- boot_controller.gd awaits this during the "gate":"model_ready"
## boot stage.
signal model_ready(success: bool)

const HOST := "127.0.0.1"
const PORT := 11434
const MODEL_NAME := "qwen3:4b"
const NUM_CTX := 8192
const READY_POLL_INTERVAL_SEC := 2.0
const READY_MAX_TRIES := 30


## Polls /api/tags for MODEL_NAME, then issues a single 1-token warm-up
## /api/chat call (forces Ollama to actually load the model into VRAM) so
## the FIRST real streamed request that follows is fast. Retries on a
## bounded interval rather than hanging silently forever or crashing if the
## model is missing or Ollama is unreachable -- the honest-theater gate
## (Risk 6 / DOD-14) must eventually resolve one way or the other.
func check_model_ready() -> void:
	for _try_index in range(READY_MAX_TRIES):
		var tags = await _http_get_json("/api/tags")
		if typeof(tags) == TYPE_DICTIONARY and tags.has("models"):
			var found := false
			for m in tags["models"]:
				if typeof(m) == TYPE_DICTIONARY and m.get("name", "") == MODEL_NAME:
					found = true
					break
			if found:
				var warm_body := {
					"model": MODEL_NAME,
					"messages": [{"role": "user", "content": "hi"}],
					"stream": false,
					"think": true,
					"options": {"num_ctx": NUM_CTX, "num_predict": 1},
				}
				await _http_post_json("/api/chat", warm_body)
				model_ready.emit(true)
				return
		await get_tree().create_timer(READY_POLL_INTERVAL_SEC).timeout
	model_ready.emit(false)


## Streams a chat completion via the native /api/chat endpoint with
## "stream": true and "think": true. Per this project's own live testing,
## "think": true correctly separates reasoning (message.thinking) from the
## final answer (message.content); ONLY message.content deltas are ever
## passed to on_delta/on_done -- message.thinking is read and discarded,
## never rendered, logged, or forwarded anywhere.
func send_chat(messages: Array, on_delta: Callable, on_done: Callable) -> void:
	var client := HTTPClient.new()
	var err := client.connect_to_host(HOST, PORT)
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
		"model": MODEL_NAME,
		"messages": messages,
		"stream": true,
		"think": true,
		"options": {"num_ctx": NUM_CTX},
	})
	var headers := PackedStringArray(["Content-Type: application/json"])
	err = client.request(HTTPClient.METHOD_POST, "/api/chat", headers, body)
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
		# NDJSON: split on newlines, keep the last (possibly partial)
		# fragment buffered for the next tick.
		var split_lines := pending.split("\n")
		pending = split_lines[split_lines.size() - 1]
		for i in range(split_lines.size() - 1):
			var line := split_lines[i].strip_edges()
			if line.is_empty():
				continue
			var parsed = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
			if parsed.has("message") and typeof(parsed["message"]) == TYPE_DICTIONARY:
				var msg: Dictionary = parsed["message"]
				# Only .content is ever surfaced -- .thinking is
				# intentionally never read into on_delta/on_done.
				if msg.has("content"):
					var piece: String = msg["content"]
					if piece != "":
						accumulated += piece
						on_delta.call(piece)
			if parsed.get("done", false):
				on_done.call(accumulated)
				return
	on_done.call(accumulated)


## Internal one-shot GET helper (readiness poll only -- NOT used for the
## streaming path above, which needs frame-polled incremental reads).
func _http_get_json(path: String):
	var client := HTTPClient.new()
	if client.connect_to_host(HOST, PORT) != OK:
		return null
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return null
	if client.request(HTTPClient.METHOD_GET, path, PackedStringArray()) != OK:
		return null
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			body.append_array(chunk)
		else:
			await get_tree().process_frame
	return JSON.parse_string(body.get_string_from_utf8())


## Internal one-shot POST helper (warm-up call only).
func _http_post_json(path: String, payload: Dictionary):
	var client := HTTPClient.new()
	if client.connect_to_host(HOST, PORT) != OK:
		return null
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return null
	var headers := PackedStringArray(["Content-Type: application/json"])
	var body_str := JSON.stringify(payload)
	if client.request(HTTPClient.METHOD_POST, path, headers, body_str) != OK:
		return null
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().process_frame
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			body.append_array(chunk)
		else:
			await get_tree().process_frame
	return JSON.parse_string(body.get_string_from_utf8())
