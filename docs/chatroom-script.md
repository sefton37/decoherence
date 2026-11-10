# Chatroom script format

The chatroom is data. Every spoken word lives in four files under
`frontdoor/data/chatroom/`; none of it is in code. The shipped words are
placeholders (each file says `"draft": true`). The keys and types are the
contract; the words are yours to rewrite. To try a copy of the directory without
touching the shipped one, set `DECOHERENCE_CHATROOM_DIR` to it. To replay a
session exactly, set `DECOHERENCE_CHATROOM_SEED` to an integer (otherwise every
session draws a fresh seed).

What the player sees: `chat` opens a channel of untranslated traffic. Nothing
tells them what to do. When they send their first message, a scripted voice
answers it, and shortly after one more ordinary voice in the room reaches out
in clear text. From then on that voice talks to the player through the local
model, but only about what the player's own questions have unlocked.

## room_script.json: the room

`entry_room` names the one room that is played. Each room has `id`, `title`,
`banner` (the lines printed on entry), `voices` (`id` plus `handle`, an
ordinary handle like `WREN-22`), and the blocks below.

## ambient: the background traffic

`ambient.lines` are `{voice, plain}`; `plain` is what the voice "says" before it
is scrambled (at most 80 characters). Delivery is randomized but replayable:

- `randomize.order` is `shuffle_bag`: every line is used once, in a shuffled
  order, before any line repeats.
- `randomize.timing` is `uniform_in_range`: the gap between lines is uniform in
  `interval_ms` (`[min, max]`). The first line appears at once.
- `randomize.scramble_seed` is `per_emission`: each emission is scrambled with
  its own seed, so a repeated line looks different the second time.
- `max_per_minute` caps the rate; the planner raises an interval just enough to
  keep to it, and the script is rejected if the cap cannot be met inside the
  range.
- `rate_after_contact` (between 0 and 1) slows the traffic once the contact has
  reached out, by dividing the pace by that factor.

Give the voice that will become the contact at least two ambient lines, so
nothing marks them out before they speak to the player.

## scramble: how the traffic is made unreadable

`scramble.pools` picks glyph sets (`box`, `block`, `braille`). Every non-space
character of a line becomes a glyph, consistently within one emission, so the
text reads as code. Spaces and length are kept. `legible_ratio` (0 to 1) lets
that share of characters through; 1 is plain text. `seed` is `per_session`.

## reveal_words: words that stay legible

`scramble.reveal_words` is a list of words that are left in clear text inside
scrambled lines. The shipped list is empty: nothing in the room is a signpost.

## responders: the answers before the contact

`responders` answer the player's messages while the room is all there is. Each
has `id`, `match_any` (whole words or phrases, case-insensitive), `voice` and
`plain`. `fallback_responses` rotate when nothing matches. Answers are
scrambled like everything else in the room.

## handler_trigger: when the contact reaches out

`handler_trigger.on` is `first_player_message`: only the first non-empty
message the player sends counts. Typing without sending, an empty line, or
waiting never does. `contact_delay_ms` is the `[min, max]` delay before the
contact line, and `contact_line` is `{voice, plain}`, spoken in clear text.
The contact's `voice` must be one of the room's ordinary voices.

## accept_commands, leave_commands and the other strings

The `handler` block holds `accept_commands` (exact words that take the player
through once the offer stands; matched in plain ASCII, so look-alike characters
fail), `leave_commands` (words that return to the shell), `offer_fallback_line`
(spoken by code if the model has not made the offer within the grace turns),
`degrade_line` (shown when the link drops mid-conversation) and `leave_line`.
Nothing on screen advertises the accept or leave words.

## handler_briefing.json: facts, ask_keywords and say_keywords

`facts` are the only things the contact may state. Each has `id`, `text`
(at most 220 characters), `source` (where the fact comes from in canon:
`handler_persona#1` to `#8`, `lore/charter.md#1.3`, `lore/charter.md#1.4` or
`lore/narrative.md`), `ask_keywords` and `say_keywords`.

- A fact unlocks only when the player's own line contains one of its
  `ask_keywords` (matched at the start of a word, so `entangle` matches
  `entanglement`). At most `max_new_facts_per_turn` unlock per turn. The code
  never volunteers a fact.
- A fact counts as credited when the contact's accepted reply, while the fact
  was unlocked, contains one of its `say_keywords`.
- `prompt_rules` are the standing rules put in front of the model every turn.

## readiness.json: what clears the player to enter

Status `TABLED`: the condition is a placeholder, to be defined. The mechanism is
fixed: the player is ready when every id in `required_facts` is credited and at
least `min_player_turns` lines have been sent to the contact. The next turn
carries the offer instruction; if the model has not offered within
`offer_grace_turns` more turns, code speaks `offer_fallback_line`. A model
offer before the player is ready is downgraded to nothing, and the player must
still type an accept word; the model never opens the world.

With the placeholder values a player who never asks about the required facts is
never offered entry. Shrinking `required_facts` (an empty list means only
`min_player_turns` has to pass) lowers the bar. The loader refuses a file that
is not marked `TABLED`, that carries `stall_turns`, or that names a fact that
does not exist.

## contact_persona.json: the contact's voice

`system_prompt` is the voice (an ordinary person on the channel, played
completely straight) and `fallback_say` is the line shown when a model reply is
rejected. Lore enters the model only through the briefing facts.
