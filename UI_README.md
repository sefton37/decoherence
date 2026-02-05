# Decoherence UI System

## Overview

The Decoherence UI is a retro 1980s-style HUD overlay built for Pygame. It combines a cyan/orange color palette, scanline effects, and corner-accented panels to create a computing terminal aesthetic reminiscent of early vector graphics displays.

The UI is non-blocking, always visible, and provides four functional panels: minimap scanner, player status, action bar, and system info.

## Layout

```
┌──────────┐                                                       ┌──────────┐
│  SCAN    │  (160x160px, top-left)                              │          │
│  ┌────┐  │                                                       │          │
│  │ :: │  │  Minimap shows hex grid within 15m radius           │          │
│  │ :█ │  │  Orange dot = player, orange line = facing          │          │
│  └────┘  │                                                       │          │
└──────────┘                                                       └──────────┘

     ...                          MAIN VIEWPORT                         ...

┌──────────┬────────────────────────────────────────────────────┬──────────┐
│ STATUS   │            ACTION BAR (12x2 grid)                 │ SYSTEM   │
│          │                                                    │          │
│ HP: 100  │  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐ │ X:+0.0   │
│ ========─│  │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │ 0 │ - │ = │ │ Y:+0.0   │
│          │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤ │ HDG:000  │
│ ST: 100  │  │ ! │ @ │ # │ $ │ % │ ^ │ & │ * │ ( │ ) │ _ │ + │ │ ZM:1.0x  │
│ ========─│  └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘ │          │
│          │                                                    │ ONLINE   │
│ FC: 100  │  160px tall, 960px wide, 80px cells               │          │
│ ========─│                                                    └──────────┘
└──────────┴────────────────────────────────────────────────────┘
160x160px                   (bottom-middle)                      160x160px
(bottom-left)                                                 (bottom-right)
```

## Panel Descriptions

### 1. Minimap (SCAN)
- **Position:** Top-left corner (0, 0)
- **Size:** 160×160px
- **Shows:** Hex grid within 15m radius of camera
- **Elements:**
  - Dark background with cyan dark hex markers (single pixels)
  - Orange player dot (2px radius) with direction line (4px)
  - Cyan border with orange L-shaped corner accents

### 2. Stats Panel (STATUS)
- **Position:** Bottom-left corner (0, screen_height - 160)
- **Size:** 160×160px
- **Shows:** Three stat bars (HP, Stamina, Focus)
- **Each bar:**
  - Label and percentage value
  - Dark background with colored fill
  - 1px bright top line for glow effect
  - HP = orange, Stamina = cyan, Focus = purple

### 3. Action Bar
- **Position:** Bottom-middle (160, screen_height - 160)
- **Size:** 960×160px (12 columns × 2 rows, 80px cells)
- **Interaction:** Keyboard slots for abilities/items
- **Visual states:**
  - Default: Dark slot background (14, 16, 28)
  - Pressed: Brighter background (20, 24, 40)
  - Active: Orange border (default is dark cyan)
- **Key labels:** Top-left corner of each cell

### 4. Info Panel (SYSTEM)
- **Position:** Bottom-right corner (screen_width - 160, screen_height - 160)
- **Size:** 160×160px
- **Shows:**
  - Player X/Y coordinates (meters, 1 decimal)
  - Heading in degrees (0-359)
  - Current zoom level
  - Status indicator (default: "ONLINE" in green)

## Color Constants

All colors are defined at the top of `ui.py`. Modify these to change the theme:

```python
# Primary Theme
CYAN = (0, 255, 255)          # Bright accents, text, borders
CYAN_DIM = (0, 128, 128)      # Subdued text, labels
CYAN_DARK = (0, 64, 64)       # Minimap hexes, dividers

ORANGE = (255, 140, 0)        # Panel corner accents, labels, HP bar
ORANGE_DIM = (128, 70, 0)     # HP bar fill

PURPLE = (180, 100, 255)      # Focus bar bright
PURPLE_DIM = (90, 50, 128)    # Focus bar fill

GREEN = (0, 255, 100)         # Status indicators

# Backgrounds
PANEL_BG = (8, 8, 16)         # Panel backgrounds
SLOT_BG = (14, 16, 28)        # Action bar slot default
SLOT_BG_PRESSED = (20, 24, 40) # Action bar slot when key pressed
```

## Keyboard Mappings

Action bar uses the top number row with shift modifier:

| Row | Keys | Shift Required |
|-----|------|----------------|
| Top row | `1 2 3 4 5 6 7 8 9 0 - =` | No |
| Bottom row | `! @ # $ % ^ & * ( ) _ +` | Yes |

**Behavior:**
- Pressing a key activates the corresponding slot
- The activated slot gets an orange border
- `handle_event()` returns `(row, col)` tuple on activation
- Holding a key makes the slot background brighter

## Public API Reference

### `GameUI(screen_width, screen_height)`
Initialize the UI system.

**Parameters:**
- `screen_width` (int): Window width in pixels
- `screen_height` (int): Window height in pixels

**Example:**
```python
ui = GameUI(1280, 720)
```

---

### `handle_event(event) -> tuple | None`
Process pygame events for action bar input.

**Parameters:**
- `event` (pygame.Event): Event from `pygame.event.get()`

**Returns:**
- `(row, col)` tuple if an action bar key was pressed
- `None` otherwise

**Example:**
```python
for event in pygame.event.get():
    slot = ui.handle_event(event)
    if slot:
        row, col = slot
        print(f"Activated slot {row},{col}")
```

---

### `update_stats(health, stamina, focus)`
Set the three stat bar values.

**Parameters:**
- `health` (float): 0.0 to 1.0
- `stamina` (float): 0.0 to 1.0
- `focus` (float): 0.0 to 1.0

**Example:**
```python
ui.update_stats(health=0.75, stamina=1.0, focus=0.5)
```

---

### `draw(screen, player, hex_grid, camera_x, camera_y, zoom)`
Render all UI panels and scanline overlay.

**Parameters:**
- `screen` (pygame.Surface): Target surface
- `player` (Player): Player object with `.x`, `.y`, `.angle`
- `hex_grid` (HexGrid): Hex grid object with `.horiz_spacing`, `.vert_spacing`
- `camera_x` (float): Camera X position in world meters
- `camera_y` (float): Camera Y position in world meters
- `zoom` (float): Current zoom level

**Example:**
```python
ui.draw(screen, player, hex_grid, camera_x, camera_y, zoom)
```

## Customization Guide

### Changing Panel Sizes

Edit the constants at the top of `ui.py`:

```python
PANEL_SIZE = 160          # Minimap, stats, info panel size (square)
ACTION_BAR_WIDTH = 960    # Action bar width
ACTION_BAR_HEIGHT = 160   # Action bar height
ACTION_BAR_COLS = 12      # Number of columns
ACTION_BAR_ROWS = 2       # Number of rows
CELL_SIZE = 80            # Individual cell size (must be WIDTH/COLS)
```

**Important:** If you change `ACTION_BAR_COLS`, you must also update the key mappings:
- `TOP_ROW_KEYS` list (pygame key constants)
- `TOP_ROW_LABELS` list (string labels)
- `BOTTOM_ROW_LABELS` list (shift+key labels)

### Changing Colors

1. Modify color constants at top of `ui.py`
2. Colors are used consistently:
   - Panel borders: `CYAN` (2px)
   - Corner accents: `ORANGE` (L-shapes)
   - Panel backgrounds: `PANEL_BG`
   - Labels: `ORANGE` for panel headers, `CYAN` for data

### Changing Minimap Radius

Edit `MINIMAP_RADIUS` constant:

```python
MINIMAP_RADIUS = 15.0  # meters around camera
```

Larger values show more area but reduce detail.

### Adding Action Bar Icons/Items

The action bar currently shows only key labels. To add item icons or text:

1. Create a 24-item data structure (12×2 slots):
   ```python
   self.action_bar_items = [
       [None] * 12,  # Top row
       [None] * 12   # Bottom row
   ]
   ```

2. Modify `_draw_action_bar()` to render item data:
   ```python
   # Inside the cell loop, after drawing the cell background:
   item = self.action_bar_items[row][col]
   if item:
       # Draw item icon or text centered in cell
       pass
   ```

### Changing Scanline Effect

Modify `_create_scanline_overlay()`:

```python
# Current: every 3 pixels, alpha 20
for y in range(0, self.screen_height, 3):
    pygame.draw.line(surface, (0, 0, 0, 20), (0, y), (self.screen_width, y), 1)

# Alternatives:
# Thicker scanlines: change step from 3 to 2
# Darker: change alpha from 20 to 40
# No scanlines: return empty surface
```

## Integration with main.py

The UI integrates at four points in `main.py`:

### 1. Initialization (Game.__init__)
```python
self.ui = GameUI(SCREEN_WIDTH, SCREEN_HEIGHT)
```

### 2. Event Handling (Game.handle_events)
```python
for event in pygame.event.get():
    self.ui.handle_event(event)
    # ... other event handling
```

### 3. State Updates (optional, not currently used)
```python
# In Game.update() or elsewhere:
self.ui.update_stats(health=0.8, stamina=0.6, focus=1.0)
```

### 4. Rendering (Game.draw)
```python
# After drawing world objects, before display.flip():
self.ui.draw(self.screen, self.player, self.hex_grid,
             self.camera_x, self.camera_y, self.zoom)
```

The UI is drawn last so it overlays the game world.

## Technical Notes

### Font Rendering
Fonts use `antialiasing=False` for pixel-crisp appearance:
```python
self.font_tiny = pygame.font.Font(None, 16)  # Second param = False is default
```

### Minimap Clipping
The minimap draws to an intermediate surface before blitting to prevent hex markers from appearing outside the map area. This ensures clean borders.

### Action Bar State
The action bar reads keyboard state directly via `pygame.key.get_pressed()` to show visual feedback while keys are held. This is separate from `handle_event()` which fires once per keypress.

### Performance
- Scanline overlay is created once at initialization, not every frame
- Minimap only renders hexes within radius (not entire grid)
- All rendering is immediate mode (no retained surfaces per panel)

At 60 FPS on 1280×720, UI rendering is negligible (<1ms per frame).
