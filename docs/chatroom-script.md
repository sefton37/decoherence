# Chatroom script format

The chatroom is data. Every spoken word lives in the files under
`frontdoor/data/chatroom/`; none of it is in code. The shipped words are
placeholders (each file says `"draft": true`). The keys and types are the
contract; the words are yours to rewrite. To try a copy of the directory without
touching the shipped one, set `DECOHERENCE_CHATROOM_DIR` to it. To replay a
session exactly, set `DECOHERENCE_CHATROOM_SEED` to an integer (otherwise every
session draws a fresh seed).

What the player sees: `chat` opens a channel of encrypted traffic, and the player
is a lurker named `newb` plus four digits. Nothing tells them what to do. When
they send their first message, a scripted voice answers it, and shortly after one
more ordinary voice in the room, their handler, reaches out in clear text and
leads a conversation through the funnel below. Code owns every stage; the local
model only writes the words between the authored lines.

## room_script.json: the room

`entry_room` names the room the player starts in. Each room has `id`, `title`,
`banner` (the lines printed on entry), `voices` and the blocks below. A voice is
`id`, `handle` and a hidden `side` (`empire` or `faction`; never drawn). Exactly
one voice per room carries `"slot": "handler"` and the handle `{HANDLER}`: it is
replaced at session build by the generated name, so the same person sits in every
room and in the ambient lines. Every room needs at least two Empire voices besides
her and at least two faction voices.

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

Give the handler's voice at least two ambient lines per room, so nothing marks
her out before she speaks to the player. While she is working with the player her
own ambient traffic stops.

## scramble: how the traffic is made unreadable

`scramble.pools` picks glyph classes. The shipped set is `box`, `box_heavy`,
`block`, `block_fine`, `punct`, `symbol`, `digit` and `letterlike`, about 180
glyphs, every one present in the chat font (`braille` is a valid pool name but is
not in that font, so it is not shipped). No class holds an ASCII letter.

Ambient lines, scripted answers and direct-message replies are scrambled by
`scramble.shape`, which does not keep the plain line's length: the plain line
only seeds the characters, and each emission draws its own shape from the knobs.
A length class (`length_classes`: a very short burst of 1 to 4 tokens, a mid
line, or a long multi-clause line that wraps), a token-length range
(`token_len_ranges`), one to three glyph classes (`class_count_weights`,
`class_weights`), and a class per token (`lead_class_share`). Long lines get a
clause mark (`clause_marks`) every `clause_tokens` tokens. `max_chars` caps a
line. `speaker` gives each handle its own tendencies, hashed from the handle
(`salt`), the same rule for everyone: `length_bias_spread` leans a handle toward
bursts or long lines, `affinity_boost` favours one glyph class, `habit_share` is
how often it keeps its usual token length. Nobody has a hand-set profile, and the
handler is not given one.

The scramble is canon: Q-Ent was breached, the factions talk encrypted, and the
Empire allows it. As the player's clearance rises, the rows of Empire voices come
through in clear text for a growing share (`legible_ratio` per stage in
`funnel.json`); rows of the other factions never do.

`tests/verify_scramble_stats.sh` measures a seeded sample against the pre-change
scrambler and checks every glyph against the font. Topics keep the older
`scramble()`: every non-space character becomes a glyph from the pools,
consistently within one emission, length and spaces kept. `legible_ratio` (0 to
1) lets that share of characters through; 1 is plain text, and a ratio above 0
turns the shaped scramble off. `seed` is `per_session`.

## reveal_words: words that stay legible

`scramble.reveal_words` is a list of words that are left in clear text inside
scrambled lines. The shipped list is empty: nothing in the room is a signpost.

## responders: the answers before the contact

`responders` answer the player's messages while the room is all there is. Each
has `id`, `match_any` (whole words or phrases, case-insensitive), `voice` and
`plain`. `fallback_responses` rotate when nothing matches. Answers are
scrambled like everything else in the room.

## handler: the leave words and the plain strings

The `handler` block holds `leave_commands` (words that return to the shell),
`degrade_line` (shown when the link drops mid-conversation) and `leave_line`.
Nothing on screen advertises the leave words.

## funnel.json: the funnel's mechanics

`stages` is the ordered list `lurk`, `contact`, `qualify`, `pushback`, `dm`,
`pitch`, `ask`, `rename`, `launch`. Per stage: `legible_ratio` (the share of an
Empire voice's rows that read at that stage; it only rises, 0 at lurk, at least
0.9 at launch), `dwell_ms` (`[min, max]` pause before her next authored line),
`idle_ms` (silence before an idle follow-up) and `max_idle_followups` (after the
last one goes unanswered she steps away, as for a refusal; `advance_on_idle`
moves on instead). `faction_legible_ratio` is 0. `target_ms` is the five to eight
minutes the run should take, `typing_ms_per_char` is how long every line of hers
is "typed" before it appears, `consent_yes` and `refuse` are the whole-message and
leading-phrase words code reads (ASCII only; a look-alike never matches),
`handle` holds the rules for the chosen handle, `dossier` caps her note, and
`guard` holds the lists the no-lie guard reads. `enabled: false` turns the whole
funnel off and leaves a quiet room.

## funnel_beats.json: every authored line

`beats` are `{id, stage, kind, plain}`. Kinds: `open` (the stage's own lines, in
file order; `wait: true` holds the stage for the player's reply, `asks` names the
note field the reply fills), `callback` (uses `{origin}` or `{doing}`; skipped
when the note has no value), `withhold` (a timing line, `until` names the stage;
never a secrecy line), `redirect`, `idle_followup`, `reask`, `handle_invalid`,
`rename_do`, `launch`, `disengage`, `done_reply`, `forget` and `ack` (the line
spoken when the model's reply is rejected). Placeholders: `{designation}`,
`{handler}`, `{handle}`, `{origin}`, `{doing}`. A beat with `plants: "twist"`
quietly plants the twist; nothing ever states it.

## funnel_names.json: the handler's generated name

`onsets`, `vowels` and `codas` (upper case) build one or two syllables, with an
optional `-NN` suffix up to `suffix_max`. The name is drawn from the first-launch
seed, saved, never equal to a static voice, the player's designation, a reserved
word or an earlier handler of the same player.

## profile: what is saved about the player

`user://profile.json` holds `schema`, `player` (`designation`, `handle`),
`handler` (`name`, `kind: empire`, `former`), `acceptance` (`accepted`,
`handler`, `handle`, `launched`) and an empty `assignments` list that the handler
module builds on. It is written atomically; unknown top-level keys survive a round
trip; a damaged file is moved aside, never destroyed. A restart after consent but
before a handle resumes at `rename`; after the handle at `launch`; mid-funnel
before consent restarts at `contact` with the same handler; after the launch the
funnel is inert and her direct message is answered from the `done_reply` lines.

## dossier and forget: her note on the player

`user://handler_dossier.json` is `{schema, fields}` with the field names from
`funnel.json` (each value at most 60 characters, the file at most 2048 bytes).
Only the qualify answers fill it, an evasive or made-up answer is stored like any
other, and there is no transcript. Callbacks use it. Typing `/forget` deletes the
file and the model's short history; the profile is untouched. The dossier follows
the player across handlers and never leaves the machine except as prompt text to
the local model.

## handler_briefing.json: facts and prompt rules

`facts` are the only things she may state. Each has `id`, `text` (at most 220
characters), `source` and `from_stage`: a fact is placed in the prompt only once
that stage has been reached. A fact that names the Empire, the planet, the
colony or a homestead stays at `pitch` or later. `prompt_rules` are the standing
rules put in front of the model every turn; they ask for a `{say, claims}` reply
and for withholding as timing ("when you can use it"), never as secrecy.

## The no-lie guard

Every model reply is checked in code before it is shown: exact keys `say` and
`claims`; claims only name facts available at the stage; no number, name, false
denial, secrecy claim, twist line, think marker, code fence or echo of the
reasoning; before the pitch none of the withheld words. A rejected reply is
replaced by the stage's `ack` beat. The guard is lexical, so a human walk is the
last gate.

## contact_persona.json: the handler's voice

`system_prompt` is the voice (an Empire handler played completely straight, who
never lies and only withholds by timing) and `fallback_say` is the line shown
when no `ack` beat exists. Lore enters the model only through the briefing facts.

## Rooms and topic: several rooms, one line each

`room_script.json` carries five rooms (`channel7`, `channel3`, `channel12`,
`channel19`, `channel4`); `entry_room` is the one the player starts in. Besides
the keys above each room has `name` (the short label the sidebar and the
directory show, such as `CHANNEL 3`) and `topic` (one line, at most 60
characters; keep it under about 28 so it fits the header at the narrowest game
size). The topic is never shown in plain text: the header and the directory
draw it scrambled, with a seed fixed for the session so it does not flicker.
Every room needs at least 5 voices, 12 ambient lines, 4 responders and 2
fallbacks. Ambient traffic runs only in rooms the player has joined; the other
rooms only shift their member count.

## presence: who is in a room

A room starts with its whole cast present. Per room, a seeded clock fires every
18 to 42 seconds and either removes a present voice or brings an absent one
back, never letting the roster (the player included) fall below 4. In a joined
room this shows as `-- NAME HAS JOINED` or `-- NAME HAS LEFT`; in a room the
player has not joined it only changes the count. A voice that is absent but has
an ambient line due arrives first, then speaks. The agents pane is the roster
sorted alphabetically; only the player's own row carries a marker (`<`) and
every other row, the handler's included, has the same colour, shape and rules.
The handler sits in every room under one handle, speaks at least twice in each
room's ambient lines, and at least two other handles are present in as many
rooms, so her presence pattern is not unique. The player starts as `newb` plus
four digits and takes the handle they choose at the rename.

## dm_script.json: direct-message replies

`reply_delay_ms` is the `[min, max]` delay before a reply (between 800 and 6000
ms; the shipped range is 1200 to 4000), `silence_ratio` is the chance an
ordinary person does not answer (0 means everyone answers), and `replies` maps
every handle except the handler's to a pool of at least 3 `{plain}` lines (at
most 80 characters). A reply is picked from a shuffle bag, scrambled like room
traffic, and arrives in that person's window even if the player closed it in the
meantime (which reopens it with an unread count). The handler has no pool: her
side of a direct message is the funnel. No reply from this file ever reaches the model.

## client_ui.json: nav labels, keys, commands, strings

`nav.brand` is the name at the left of the bar and `nav.items` is the list of
`{label, key, action}` (4 to 6 entries; labels are 2 to 15 capital letters and
carry no exit, close or start word). `keys` binds every client action to a key
string (`Enter`, `Up`, `Down`, `Tab`, `PageUp`, `PageDown`, `Esc`, `F1` to
`F12`, with `Ctrl+` and `Alt+` prefixes; `Alt+1..9` is the jump range). The
fullscreen keys F11 and Alt+Enter are never rebound or typed. `commands` lists
the slash-command verbs the client parses; there is deliberately no help verb.
`strings` holds every fixed line the client draws itself (refusals, join and
leave lines with a `{name}` slot, list and who lines); none may explain the
client or name a key.

## keys: the keybindings as shipped

Enter sends; Up and Down walk the input history (or move the selection in an
open list); Tab completes a name from the room's agents; Ctrl+N and Ctrl+P move
to the next and previous buffer; Alt+1 to Alt+9 jump to the n-th; PageUp and
PageDown scroll back and forward and Ctrl+End returns to live; F1 focuses the
room list, F2 opens the directory, F3 opens the newest unread direct message
(else focuses the list), F4 focuses the agents list (Enter opens a direct
message); Esc closes the open list; Ctrl+W closes the current direct message or
leaves the current room; Ctrl+Q leaves the client. The bare words `leave`,
`exit` and `quit` (and the same with a slash) still leave. Slash commands:
`/join`, `/part`, `/list`, `/who`, `/msg`, `/me`, `/clear`, `/forget`, `/quit`. An unknown
command gets a plain refusal line and no suggestion.

## directory: the room list

F2 draws one row per room in the data: the short name, the live member count and
the topic scrambled. Up and Down move the selection (it wraps), Enter joins the
selected room and Esc closes the list. A room that was left is still listed.
The directory is data-driven: add a room to `room_script.json` and it appears.
The handler is not singled out in any row.

## Routing: what may reach the model

Code decides. A line is a command, a scripted line, or a line on the single
model-backed thread. The thread starts once the handler has spoken and covers
only the buffer where she spoke and her own direct message (from the direct
message stage on, only that); every other room and every direct message to an
ordinary person stays scripted. The first sent message anywhere (a room line,
`/me`, a `/msg` with a body) starts the contact timer once; commands, empty lines
and unsent typing never do. A clear yes is read in code at the ask stage and
nowhere else; the model has no field that could open the world, and the single
launch is `Chatroom._launch_interim()`.
