extends RefCounted
class_name Palette

## Teal-dominant / orange-highlight palette (Spec #370 aesthetic constraint).
## Teal is the terminal's default/base color for ordinary lines. Orange is
## reserved for emphasis, warnings, and Q-Ent branding beats -- it must never
## become the dominant color of a screen.

const TEAL := Color(0.16, 0.85, 0.78)
const ORANGE := Color(0.95, 0.55, 0.15)

## Dimmer variants for scrollback lines that have aged out of the current
## beat, and a near-black background tone for panels/overlays.
const TEAL_DIM := Color(0.08, 0.42, 0.39)
const ORANGE_DIM := Color(0.55, 0.32, 0.10)
const BG := Color(0.02, 0.05, 0.05)

## Terminal text (Spec #541 D6): a tint of TEAL, brighter than the chrome so the
## conversation reads ahead of the OS dressing. TerminalGrid remaps TEAL rows to
## this at draw time; the chrome keeps TEAL / TEAL_DIM.
const TEAL_BRIGHT := Color(0.55, 1.0, 0.93)
