# The HANDLER module

The HANDLER module is where the funnel in the chat ends. A player who has joined the Empire
handler's program under a handle they chose lands on one screen: the one colonist they were
assigned, laid out flat on the left, their own file on the right, and a single button at the
bottom that accepts the mission and enters the world.

Everything the player reads here is **draft** placeholder content for the author's pen. The
keys, the rule ids and the shapes of the data files are the contract; the words, the names and
the numbers are stand-ins.

## Where it sits

- The chat's funnel ends in `Chatroom._launch_interim()`. It marks the profile launched,
  makes sure the player has a colonist, and emits `chatroom_entry_granted`. That signal keeps
  its name; it now means "entry to the module". The shell re-checks `Chatroom.entry_allowed()`
  and opens the module (`ShellController.State.HANDLER`). Nothing launches the world from the
  chat any more.
- `modules.json` carries the entry `handler` with `locked_until: handler_unlocked`. While the
  funnel is unfinished the module is absent from `dir`, from `help` and from the router's list
  of modules, and typing `handler` is refused like any unknown command. It unlocks with
  `acceptance.launched`.
- The screen needs no model. It opens, scrolls and launches with the model down.
- Files: `frontdoor/scripts/colonist_gen.gd` (generator and validator), `handler_view.gd` (what
  the panes say), `handler_layout.gd` (where they sit), `handler_screen.gd` (the drawing control,
  focus, scroll, keys and the click), and the data under `frontdoor/data/handler/`.

## The colonist: generation rules

`ColonistGen.generate(seed, tables, rules)` is a pure function. The seed is a hash of the
player's designation and handler name (both persisted), so a player always gets the same colonist
and two players differ. There is no global random state, no clock and no model, and a model never
writes a fact about a colonist.

A candidate value is drawn from `colonist_tables.json`; the rules in `colonist_rules.json`
accept or reject it and the draw is repeated (bounded by `max_attempts`):

- adults only (the age minimum is 21), and the years on the planet cannot exceed the age minus
  the arrival age;
- the prior service work has a minimum age and must fit the kind of hub;
- the three traits are distinct and none excludes another (the exclusions are symmetric);
- the biography is an assembly of numbered templates, one per part, and a template is used only
  when every slot in it resolves and every field it requires holds an allowed value.

The dossier has 22 fields in six sections (identity, placement, service, personal, biography,
intimate details). Every field carries its source: a table and an index, a range, a derivation, a
rule, the profile or an assembly of templates. The service status is a volunteer, and the homestead
specialization stays unassigned, because the player chooses it at the start of the game.

`ColonistGen.validate` re-checks a finished dossier and returns the ids of the rules it breaks.
The intimate details are closed, neutral categories, each at most 60 characters; explicit wording
is the author's to write into the tables.

## The dossier is frozen

The dossier is stored whole in `profile.json` under `assignments[0]`, with `template_version`.
Once stored it is frozen: a later edit of the data never changes a player's colonist, because the
world will have to agree with it. It is replaced only when it fails validation, and an acceptance
of the old one is cleared at the same time. Unknown keys anywhere in the profile survive.

## The profile pane

The right pane shows nine fields, all labelled from `handler_ui.json`: the handle, the former
designation, the status, the handler's name and kind, the former handlers, what the player said in
the chat about where they are from and what they were doing (or the "not on file" string after a
`/forget`), and the assigned colonist. It shows no hardware or entanglement facts. Player values are
never formatted into a template, so braces and long words in an answer stay literal.

## Controls and the Launch button

The keys are named in `handler_ui.json`. Tab and Shift+Tab move the focus between the dossier, the
profile and Launch. Up, Down, PageUp, PageDown, Home and End scroll the focused pane, and the wheel
scrolls the pane under the pointer. Enter or Space on a focused Launch accepts; so does a click on the
button. Backspace returns to the shell prompt (Esc opens the pause menu). The initial focus is the dossier, so a stray Enter (the one
that ended the chat) does nothing; a held key repeats nothing but scrolling. F11 and Alt+Enter belong
to the boot controller and never accept. There is no decline control and no help legend.

## The launch seam

Pressing Launch is the acceptance of the mission. The screen emits `handler_launch_requested` and
reads back what happened; it knows no destination. The shell records `acceptance.mission_accepted`
first, then calls `ShellController.enter_route(route_id, assignment_id)`. The route id comes from
`launch_route.json` (today `world_entry`, whose `kind` is `world`), and only the routes the shell knows
resolve; an unknown route is refused with a status line. A later spec that builds the cutscene and the
first homestead adds a route and changes `route` in that file. Pressing Launch again after a successful
hand-off is inert until the world closes; pressing it after the acceptance re-enters the same route and
the acceptance record stays single.

## Resume

If the player quits after finishing the funnel and before accepting the mission, the next boot lands in
the module, not in the chat. After the mission is accepted the boot lands in the shell as before, and
typing `handler` reopens the module in its accepted state. A profile written before this module existed
(launched, with no colonist) gets its colonist the first time the module opens. A damaged profile is moved
aside and replaced, and the shell comes up.

## Data files (all draft)

Every file below is marked `"draft": true`, and a check pins it.

| File | Holds |
|---|---|
| `colonist_tables.json` | hubs, names, genders, professions, education, family, traits, the closed intimate sets and the biography templates |
| `colonist_rules.json` | the rule numbers, the section order, the 22 fields and where each comes from |
| `handler_ui.json` | every word the screen draws itself, and the key table |
| `launch_route.json` | the route id and the routes the shell can enter |

## Tests

The words and numbers the tests read are the draft ones; nothing in a test spells an authored word.

`tests/verify_colonist_unit.sh` runs the generator, the validator, the store rule, the view and the layout
headless. `tests/verify_handler.sh` drives the real frontdoor off-screen with every action a real key or
mouse event, against a loopback fake model, and always on a scratch user data directory: it refuses a
user data directory under the real one.
