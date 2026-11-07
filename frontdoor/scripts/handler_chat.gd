extends Node
class_name HandlerChat

## Drives the LLM-powered Empire Handler conversation (Spec #370). Consumes
## data/handler_persona.json's injected_facts to build the one system
## message sent once per session (conversation history is otherwise kept
## purely in-memory for the process's lifetime -- no save/persistence, per
## the spec's out-of-scope fence on saves). Listens for
## Signals.submit_player_line, streams partial/delta token output into the
## shared TerminalGrid via LlmClient.send_chat(), and emits
## Signals.handler_reply_complete once a full reply has arrived.

const PERSONA_PATH := "res://frontdoor/data/handler_persona.json"

var _terminal: TerminalGrid = null
var _llm: LlmClient = null
var _history: Array = []
var _busy: bool = false


## Wires this node to the shared TerminalGrid + LlmClient instances
## (boot_controller.gd calls this once during _ready()) and loads the
## persona system prompt + injected facts.
func setup(terminal_grid: TerminalGrid, llm_client: LlmClient) -> void:
	_terminal = terminal_grid
	_llm = llm_client
	_load_persona()
	if not Signals.submit_player_line.is_connected(_on_submit_player_line):
		Signals.submit_player_line.connect(_on_submit_player_line)


func _load_persona() -> void:
	var f := FileAccess.open(PERSONA_PATH, FileAccess.READ)
	if f == null:
		_history = []
		return
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		_history = []
		return
	var system_prompt: String = data.get("system_prompt", "")
	var injected_facts: Array = data.get("injected_facts", [])
	var facts_block := "KNOWN FACTS (ground truth -- never contradict or elaborate beyond these):\n"
	for i in range(injected_facts.size()):
		facts_block += "%d. %s\n" % [i + 1, injected_facts[i]]
	var full_system: String = system_prompt + "\n\n" + facts_block
	_history = [{"role": "system", "content": full_system}]


## Fires whenever a line of player input is submitted -- by a real Enter
## keypress in the terminal input line, or by probe_driver.gd simulating
## one. Both paths funnel through this identical handler.
func _on_submit_player_line(text: String) -> void:
	if _busy or _terminal == null or _llm == null:
		return
	_busy = true
	_history.append({"role": "user", "content": text})
	_terminal.begin_stream_line(Palette.TEAL)
	_llm.send_chat(_history, Callable(self, "_on_delta"), Callable(self, "_on_done"))


## Streamed content delta -- only ever message.content, never
## message.reasoning_content (LlmClient guarantees this at the source).
func _on_delta(piece: String) -> void:
	_terminal.append_stream_delta(piece)


func _on_done(full_text: String) -> void:
	_terminal.end_stream_line()
	_history.append({"role": "assistant", "content": full_text})
	_busy = false
	Signals.handler_reply_complete.emit(full_text)
