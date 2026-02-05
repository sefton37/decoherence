import pygame
import math

# ============================================================================
# CONSTANTS
# ============================================================================

# Color Palette - Retro Cyan/Orange Theme
CYAN = (0, 255, 255)
CYAN_DIM = (0, 128, 128)
CYAN_DARK = (0, 64, 64)
ORANGE = (255, 140, 0)
ORANGE_DIM = (128, 70, 0)
PURPLE = (180, 100, 255)
PURPLE_DIM = (90, 50, 128)
GREEN = (0, 255, 100)
PANEL_BG = (8, 8, 16)
SLOT_BG = (14, 16, 28)
SLOT_BG_PRESSED = (20, 24, 40)

# Panel Dimensions
PANEL_SIZE = 160
ACTION_BAR_WIDTH = 960
ACTION_BAR_HEIGHT = 160
ACTION_BAR_COLS = 12
ACTION_BAR_ROWS = 2
CELL_SIZE = 80

# Font Sizes
FONT_TINY = 16
FONT_SMALL = 20
FONT_MEDIUM = 24

# Minimap Settings
MINIMAP_RADIUS = 15.0  # meters around camera
MINIMAP_INNER_MARGIN = 8

# Corner Accent Size
CORNER_SIZE = 8

# Action Bar Key Mapping
TOP_ROW_KEYS = [
    pygame.K_1, pygame.K_2, pygame.K_3, pygame.K_4, pygame.K_5, pygame.K_6,
    pygame.K_7, pygame.K_8, pygame.K_9, pygame.K_0, pygame.K_MINUS, pygame.K_EQUALS
]

TOP_ROW_LABELS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=']
BOTTOM_ROW_LABELS = ['!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+']


# ============================================================================
# GAME UI CLASS
# ============================================================================

class GameUI:
    """Retro 1980s computing-style HUD overlay for Decoherence game."""

    def __init__(self, screen_width, screen_height):
        """Initialize all panels, fonts, and scanline overlay."""
        self.screen_width = screen_width
        self.screen_height = screen_height

        # Initialize fonts (no antialiasing for pixel-crisp look)
        self.font_tiny = pygame.font.Font(None, FONT_TINY)
        self.font_small = pygame.font.Font(None, FONT_SMALL)
        self.font_medium = pygame.font.Font(None, FONT_MEDIUM)

        # Panel rectangles (flush to screen edges)
        self.minimap_rect = pygame.Rect(0, 0, PANEL_SIZE, PANEL_SIZE)
        self.stats_rect = pygame.Rect(0, screen_height - PANEL_SIZE, PANEL_SIZE, PANEL_SIZE)
        self.action_bar_rect = pygame.Rect(PANEL_SIZE, screen_height - ACTION_BAR_HEIGHT,
                                           ACTION_BAR_WIDTH, ACTION_BAR_HEIGHT)
        self.info_rect = pygame.Rect(screen_width - PANEL_SIZE, screen_height - PANEL_SIZE,
                                     PANEL_SIZE, PANEL_SIZE)

        # Stats (default all full)
        self.health = 1.0
        self.stamina = 1.0
        self.focus = 1.0

        # Action bar state
        self.active_slot = None  # (row, col) tuple

        # Create CRT scanline overlay (once at init)
        self.scanline_surface = self._create_scanline_overlay()

    def _create_scanline_overlay(self):
        """Create a screen-sized surface with horizontal scanlines."""
        surface = pygame.Surface((self.screen_width, self.screen_height), pygame.SRCALPHA)
        for y in range(0, self.screen_height, 3):
            pygame.draw.line(surface, (0, 0, 0, 20), (0, y), (self.screen_width, y), 1)
        return surface

    def _draw_corner_accents(self, screen, rect):
        """Draw orange L-shaped corner accents on all 4 corners of a rectangle."""
        # Top-left
        pygame.draw.line(screen, ORANGE,
                        (rect.left, rect.top),
                        (rect.left + CORNER_SIZE, rect.top), 2)
        pygame.draw.line(screen, ORANGE,
                        (rect.left, rect.top),
                        (rect.left, rect.top + CORNER_SIZE), 2)

        # Top-right
        pygame.draw.line(screen, ORANGE,
                        (rect.right - 1, rect.top),
                        (rect.right - CORNER_SIZE - 1, rect.top), 2)
        pygame.draw.line(screen, ORANGE,
                        (rect.right - 1, rect.top),
                        (rect.right - 1, rect.top + CORNER_SIZE), 2)

        # Bottom-left
        pygame.draw.line(screen, ORANGE,
                        (rect.left, rect.bottom - 1),
                        (rect.left + CORNER_SIZE, rect.bottom - 1), 2)
        pygame.draw.line(screen, ORANGE,
                        (rect.left, rect.bottom - 1),
                        (rect.left, rect.bottom - CORNER_SIZE - 1), 2)

        # Bottom-right
        pygame.draw.line(screen, ORANGE,
                        (rect.right - 1, rect.bottom - 1),
                        (rect.right - CORNER_SIZE - 1, rect.bottom - 1), 2)
        pygame.draw.line(screen, ORANGE,
                        (rect.right - 1, rect.bottom - 1),
                        (rect.right - 1, rect.bottom - CORNER_SIZE - 1), 2)

    def _draw_minimap(self, screen, player, hex_grid, camera_x, camera_y):
        """Draw the minimap panel (top-left)."""
        # Background
        pygame.draw.rect(screen, PANEL_BG, self.minimap_rect)

        # Label
        label = self.font_tiny.render("SCAN", False, ORANGE)
        screen.blit(label, (self.minimap_rect.x + 4, self.minimap_rect.y + 2))

        # Inner map area (with margin for label and borders)
        map_area = pygame.Rect(
            self.minimap_rect.x + MINIMAP_INNER_MARGIN,
            self.minimap_rect.y + MINIMAP_INNER_MARGIN + 12,
            self.minimap_rect.width - 2 * MINIMAP_INNER_MARGIN,
            self.minimap_rect.height - 2 * MINIMAP_INNER_MARGIN - 12
        )

        # Dark background for map area
        pygame.draw.rect(screen, (4, 4, 8), map_area)

        # Calculate scale for minimap (world meters to screen pixels)
        scale = min(map_area.width, map_area.height) / (2 * MINIMAP_RADIUS)
        map_center_x = map_area.centerx
        map_center_y = map_area.centery

        # Create a clipping surface for the map area
        clip_surface = pygame.Surface((map_area.width, map_area.height))
        clip_surface.fill((4, 4, 8))

        # Draw hex positions within radius
        # Calculate visible hex range
        col_start = int((camera_x - MINIMAP_RADIUS) / hex_grid.horiz_spacing) - 1
        col_end = int((camera_x + MINIMAP_RADIUS) / hex_grid.horiz_spacing) + 2
        row_start = int((camera_y - MINIMAP_RADIUS) / hex_grid.vert_spacing) - 1
        row_end = int((camera_y + MINIMAP_RADIUS) / hex_grid.vert_spacing) + 2

        for col in range(col_start, col_end):
            for row in range(row_start, row_end):
                # Calculate hex center position
                cx = col * hex_grid.horiz_spacing
                cy = row * hex_grid.vert_spacing
                if col % 2 == 1:
                    cy += hex_grid.vert_spacing / 2

                # Check if within radius
                dx = cx - camera_x
                dy = cy - camera_y
                dist = math.sqrt(dx * dx + dy * dy)

                if dist <= MINIMAP_RADIUS:
                    # Convert to minimap coordinates
                    map_x = int(dx * scale)
                    map_y = int(dy * scale)

                    # Draw single pixel (relative to clip surface)
                    clip_x = map_x + map_area.width // 2
                    clip_y = map_y + map_area.height // 2

                    if 0 <= clip_x < map_area.width and 0 <= clip_y < map_area.height:
                        clip_surface.set_at((clip_x, clip_y), CYAN_DARK)

        # Draw player position and direction
        player_dx = player.x - camera_x
        player_dy = player.y - camera_y
        player_map_x = int(player_dx * scale) + map_area.width // 2
        player_map_y = int(player_dy * scale) + map_area.height // 2

        # Player dot (2px radius)
        if 0 <= player_map_x < map_area.width and 0 <= player_map_y < map_area.height:
            pygame.draw.circle(clip_surface, ORANGE, (player_map_x, player_map_y), 2)

            # Direction line (4px long)
            dir_x = int(player_map_x + 4 * math.cos(player.angle))
            dir_y = int(player_map_y + 4 * math.sin(player.angle))
            pygame.draw.line(clip_surface, ORANGE,
                           (player_map_x, player_map_y),
                           (dir_x, dir_y), 1)

        # Blit the clipped surface to screen
        screen.blit(clip_surface, map_area.topleft)

        # Border and accents
        pygame.draw.rect(screen, CYAN, self.minimap_rect, 2)
        self._draw_corner_accents(screen, self.minimap_rect)

    def _draw_stat_bar(self, screen, x, y, width, label, value, color, color_dim):
        """Draw a single stat bar with label, value, and progress bar."""
        # Label and value on same line
        text = self.font_tiny.render(f"{label}: {int(value * 100)}", False, CYAN)
        screen.blit(text, (x, y))

        # Progress bar below
        bar_y = y + 16
        bar_height = 12

        # Dark background
        bar_bg_rect = pygame.Rect(x, bar_y, width, bar_height)
        pygame.draw.rect(screen, (2, 2, 4), bar_bg_rect)

        # Filled portion
        filled_width = int(width * max(0, min(1, value)))
        if filled_width > 0:
            fill_rect = pygame.Rect(x, bar_y, filled_width, bar_height)
            pygame.draw.rect(screen, color_dim, fill_rect)

            # Bright 1px top line glow
            pygame.draw.line(screen, color,
                           (x, bar_y),
                           (x + filled_width, bar_y), 1)

        # Border
        pygame.draw.rect(screen, CYAN_DARK, bar_bg_rect, 1)

    def _draw_stats_panel(self, screen):
        """Draw the stats panel (bottom-left)."""
        # Background
        pygame.draw.rect(screen, PANEL_BG, self.stats_rect)

        # Label
        label = self.font_tiny.render("STATUS", False, ORANGE)
        screen.blit(label, (self.stats_rect.x + 4, self.stats_rect.y + 2))

        # Three stat bars
        bar_x = self.stats_rect.x + 10
        bar_width = self.stats_rect.width - 20
        bar_spacing = 40

        # HP
        self._draw_stat_bar(screen, bar_x, self.stats_rect.y + 25, bar_width,
                          "HP", self.health, ORANGE, ORANGE_DIM)

        # Stamina
        self._draw_stat_bar(screen, bar_x, self.stats_rect.y + 25 + bar_spacing, bar_width,
                          "ST", self.stamina, CYAN, CYAN_DIM)

        # Focus
        self._draw_stat_bar(screen, bar_x, self.stats_rect.y + 25 + 2 * bar_spacing, bar_width,
                          "FC", self.focus, PURPLE, PURPLE_DIM)

        # Border and accents
        pygame.draw.rect(screen, CYAN, self.stats_rect, 2)
        self._draw_corner_accents(screen, self.stats_rect)

    def _draw_action_bar(self, screen):
        """Draw the action bar (bottom-middle, 12x2 grid)."""
        # Background
        pygame.draw.rect(screen, PANEL_BG, self.action_bar_rect)

        # Get current key state
        keys = pygame.key.get_pressed()
        mods = pygame.key.get_mods()
        shift_held = mods & pygame.KMOD_SHIFT

        # Draw cells
        for row in range(ACTION_BAR_ROWS):
            for col in range(ACTION_BAR_COLS):
                cell_x = self.action_bar_rect.x + col * CELL_SIZE
                cell_y = self.action_bar_rect.y + row * CELL_SIZE
                cell_rect = pygame.Rect(cell_x, cell_y, CELL_SIZE, CELL_SIZE)

                # Check if this key is pressed
                key_pressed = False
                if col < len(TOP_ROW_KEYS):
                    if row == 0 and keys[TOP_ROW_KEYS[col]] and not shift_held:
                        key_pressed = True
                    elif row == 1 and keys[TOP_ROW_KEYS[col]] and shift_held:
                        key_pressed = True

                # Cell background (brighter if pressed)
                bg_color = SLOT_BG_PRESSED if key_pressed else SLOT_BG
                pygame.draw.rect(screen, bg_color, cell_rect)

                # Cell border (orange if active slot, dark cyan otherwise)
                border_color = ORANGE if self.active_slot == (row, col) else CYAN_DARK
                pygame.draw.rect(screen, border_color, cell_rect, 1)

                # Key label in top-left corner
                if row == 0:
                    label_text = TOP_ROW_LABELS[col]
                else:
                    label_text = BOTTOM_ROW_LABELS[col]

                label = self.font_tiny.render(label_text, False, CYAN_DIM)
                screen.blit(label, (cell_x + 3, cell_y + 2))

        # Outer border
        pygame.draw.rect(screen, CYAN, self.action_bar_rect, 2)

    def _draw_info_panel(self, screen, player, zoom):
        """Draw the info panel (bottom-right)."""
        # Background
        pygame.draw.rect(screen, PANEL_BG, self.info_rect)

        # Label
        label = self.font_tiny.render("SYSTEM", False, ORANGE)
        screen.blit(label, (self.info_rect.x + 4, self.info_rect.y + 2))

        # Player info
        info_x = self.info_rect.x + 8
        info_y = self.info_rect.y + 25
        line_height = 18

        # X coordinate
        x_text = self.font_tiny.render(f"X:{player.x:+.1f}", False, CYAN)
        screen.blit(x_text, (info_x, info_y))

        # Y coordinate
        y_text = self.font_tiny.render(f"Y:{player.y:+.1f}", False, CYAN)
        screen.blit(y_text, (info_x, info_y + line_height))

        # Heading (convert radians to degrees)
        degrees = (math.degrees(player.angle) % 360)
        hdg_text = self.font_tiny.render(f"HDG:{degrees:03.0f}", False, CYAN)
        screen.blit(hdg_text, (info_x, info_y + 2 * line_height))

        # Zoom
        zoom_text = self.font_tiny.render(f"ZM:{zoom:.1f}x", False, CYAN)
        screen.blit(zoom_text, (info_x, info_y + 3 * line_height))

        # Divider line
        divider_y = self.info_rect.bottom - 30
        pygame.draw.line(screen, CYAN_DARK,
                        (self.info_rect.x + 8, divider_y),
                        (self.info_rect.right - 8, divider_y), 1)

        # Status
        status_text = self.font_tiny.render("ONLINE", False, GREEN)
        screen.blit(status_text, (info_x, divider_y + 6))

        # Border and accents
        pygame.draw.rect(screen, CYAN, self.info_rect, 2)
        self._draw_corner_accents(screen, self.info_rect)

    def handle_event(self, event):
        """
        Handle KEYDOWN events for action bar.
        Returns (row, col) tuple if a slot was activated, None otherwise.
        """
        if event.type == pygame.KEYDOWN:
            # Check if it's one of the action bar keys
            if event.key in TOP_ROW_KEYS:
                col = TOP_ROW_KEYS.index(event.key)
                row = 1 if event.mod & pygame.KMOD_SHIFT else 0
                self.active_slot = (row, col)
                return (row, col)

        return None

    def update_stats(self, health, stamina, focus):
        """Set stat bar values (0.0 to 1.0)."""
        self.health = health
        self.stamina = stamina
        self.focus = focus

    def draw(self, screen, player, hex_grid, camera_x, camera_y, zoom):
        """Draw all UI panels and scanline overlay."""
        # Draw minimap
        self._draw_minimap(screen, player, hex_grid, camera_x, camera_y)

        # Draw stats panel
        self._draw_stats_panel(screen)

        # Draw action bar
        self._draw_action_bar(screen)

        # Draw info panel
        self._draw_info_panel(screen, player, zoom)

        # Draw CRT scanline overlay
        screen.blit(self.scanline_surface, (0, 0))
