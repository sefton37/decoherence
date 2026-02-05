import pygame
import math
import sys

# Constants
SCREEN_WIDTH = 1280
SCREEN_HEIGHT = 720
PIXELS_PER_METER = 100  # base scale: 100 pixels = 1 meter at zoom 1.0
FPS = 60

# Zoom settings
DEFAULT_ZOOM = 0.5   # start 2x more zoomed out than base
MIN_ZOOM = 0.15      # max zoom out
MAX_ZOOM = 2.0       # max zoom in
ZOOM_SPEED = 1.1     # multiplier per scroll notch

# Hexagon properties (1 meter vertex-to-vertex across opposite vertices)
HEX_CIRCUMRADIUS = 0.5  # meters (center to vertex)
HEX_SIDE = HEX_CIRCUMRADIUS  # regular hexagon: side length = circumradius

# Player properties
PLAYER_LENGTH = 0.25  # meters (front to back)
PLAYER_WIDTH = 0.5    # meters (side to side)
PLAYER_SPEED = 1.5    # meters per second

# Colors
BG_COLOR = (20, 20, 30)
HEX_FILL_COLOR = (40, 45, 55)
HEX_BORDER_COLOR = (70, 80, 100)
PLAYER_COLOR = (60, 140, 60)
PLAYER_BORDER_COLOR = (80, 180, 80)
PLAYER_FRONT_COLOR = (255, 255, 255)


def world_to_screen(world_x, world_y, camera_x, camera_y, ppm):
    """Convert world coordinates (meters) to screen coordinates (pixels)."""
    screen_x = (world_x - camera_x) * ppm + SCREEN_WIDTH / 2
    screen_y = (world_y - camera_y) * ppm + SCREEN_HEIGHT / 2
    return screen_x, screen_y


def screen_to_world(screen_x, screen_y, camera_x, camera_y, ppm):
    """Convert screen coordinates (pixels) to world coordinates (meters)."""
    world_x = (screen_x - SCREEN_WIDTH / 2) / ppm + camera_x
    world_y = (screen_y - SCREEN_HEIGHT / 2) / ppm + camera_y
    return world_x, world_y


class HexGrid:
    """Flat-top hexagonal grid."""

    def __init__(self):
        # For flat-top hexagon:
        # Width (point to point) = 2 * circumradius = 1m
        # Height (flat to flat) = sqrt(3) * circumradius
        self.circumradius = HEX_CIRCUMRADIUS
        self.width = 2 * self.circumradius  # 1 meter
        self.height = math.sqrt(3) * self.circumradius  # ~0.866 meters

        # Spacing for hex grid (flat-top)
        self.horiz_spacing = self.width * 0.75  # 3/4 of width
        self.vert_spacing = self.height

    def get_hex_vertices(self, center_x, center_y):
        """Get the 6 vertices of a flat-top hexagon at the given center."""
        vertices = []
        for i in range(6):
            # Flat-top: start at 0 degrees (pointing right)
            angle = math.radians(60 * i)
            vx = center_x + self.circumradius * math.cos(angle)
            vy = center_y + self.circumradius * math.sin(angle)
            vertices.append((vx, vy))
        return vertices

    def get_visible_hexes(self, camera_x, camera_y, ppm):
        """Get hex centers that are visible on screen."""
        # Calculate visible area in world coordinates with padding
        padding = 2  # extra hexes beyond screen edge
        half_width_m = (SCREEN_WIDTH / 2) / ppm + padding
        half_height_m = (SCREEN_HEIGHT / 2) / ppm + padding

        min_x = camera_x - half_width_m
        max_x = camera_x + half_width_m
        min_y = camera_y - half_height_m
        max_y = camera_y + half_height_m

        hexes = []

        # Calculate column range
        col_start = int(min_x / self.horiz_spacing) - 1
        col_end = int(max_x / self.horiz_spacing) + 2

        for col in range(col_start, col_end):
            # Calculate row range
            row_start = int(min_y / self.vert_spacing) - 1
            row_end = int(max_y / self.vert_spacing) + 2

            for row in range(row_start, row_end):
                # Flat-top hex grid: odd columns are offset by half height
                cx = col * self.horiz_spacing
                cy = row * self.vert_spacing
                if col % 2 == 1:
                    cy += self.vert_spacing / 2

                hexes.append((cx, cy, col, row))

        return hexes

    def draw(self, screen, camera_x, camera_y, ppm):
        """Draw the hex grid."""
        visible_hexes = self.get_visible_hexes(camera_x, camera_y, ppm)

        for (cx, cy, col, row) in visible_hexes:
            # Get vertices in world coordinates
            vertices_world = self.get_hex_vertices(cx, cy)

            # Convert to screen coordinates
            vertices_screen = [
                world_to_screen(vx, vy, camera_x, camera_y, ppm)
                for (vx, vy) in vertices_world
            ]

            # Draw filled hexagon
            pygame.draw.polygon(screen, HEX_FILL_COLOR, vertices_screen)
            # Draw border
            pygame.draw.polygon(screen, HEX_BORDER_COLOR, vertices_screen, 2)


class Player:
    """Player represented as a rectangle with front indicator."""

    def __init__(self, x, y):
        self.x = x  # meters
        self.y = y  # meters
        self.angle = 0  # radians, 0 = facing right
        self.length = PLAYER_LENGTH  # front to back
        self.width = PLAYER_WIDTH    # side to side
        self.speed = PLAYER_SPEED

    def get_corners(self):
        """Get the 4 corners of the player rectangle in world coordinates."""
        # Rectangle centered on player position
        # Length is along the facing direction, width is perpendicular
        half_length = self.length / 2
        half_width = self.width / 2

        # Local corners (before rotation)
        # Front is in positive x direction (local)
        local_corners = [
            (half_length, -half_width),   # front-right
            (half_length, half_width),    # front-left
            (-half_length, half_width),   # back-left
            (-half_length, -half_width),  # back-right
        ]

        # Rotate and translate to world coordinates
        cos_a = math.cos(self.angle)
        sin_a = math.sin(self.angle)

        world_corners = []
        for (lx, ly) in local_corners:
            wx = self.x + lx * cos_a - ly * sin_a
            wy = self.y + lx * sin_a + ly * cos_a
            world_corners.append((wx, wy))

        return world_corners

    def get_front_line(self):
        """Get the front line endpoints in world coordinates."""
        half_length = self.length / 2
        half_width = self.width / 2

        # Front line in local coordinates
        local_front = [
            (half_length, -half_width),  # front-right
            (half_length, half_width),   # front-left
        ]

        cos_a = math.cos(self.angle)
        sin_a = math.sin(self.angle)

        world_front = []
        for (lx, ly) in local_front:
            wx = self.x + lx * cos_a - ly * sin_a
            wy = self.y + lx * sin_a + ly * cos_a
            world_front.append((wx, wy))

        return world_front

    def face_towards(self, target_x, target_y):
        """Rotate to face towards a target point (world coordinates)."""
        dx = target_x - self.x
        dy = target_y - self.y
        if dx != 0 or dy != 0:
            self.angle = math.atan2(dy, dx)

    def move(self, forward, right, dt):
        """
        Move the player.
        forward: -1 to 1 (W/S)
        right: -1 to 1 (A/D, negative = left)
        dt: delta time in seconds
        """
        # Forward direction
        fx = math.cos(self.angle)
        fy = math.sin(self.angle)

        # Right direction (perpendicular to forward)
        rx = math.cos(self.angle + math.pi / 2)
        ry = math.sin(self.angle + math.pi / 2)

        # Combined movement direction
        move_x = forward * fx + right * rx
        move_y = forward * fy + right * ry

        # Normalize if moving diagonally
        magnitude = math.sqrt(move_x * move_x + move_y * move_y)
        if magnitude > 0:
            move_x /= magnitude
            move_y /= magnitude

            # Apply movement
            self.x += move_x * self.speed * dt
            self.y += move_y * self.speed * dt

    def draw(self, screen, camera_x, camera_y, ppm):
        """Draw the player."""
        # Get corners in screen coordinates
        corners_world = self.get_corners()
        corners_screen = [
            world_to_screen(wx, wy, camera_x, camera_y, ppm)
            for (wx, wy) in corners_world
        ]

        # Draw filled rectangle
        pygame.draw.polygon(screen, PLAYER_COLOR, corners_screen)
        # Draw border
        pygame.draw.polygon(screen, PLAYER_BORDER_COLOR, corners_screen, 2)

        # Draw front line
        front_world = self.get_front_line()
        front_screen = [
            world_to_screen(wx, wy, camera_x, camera_y, ppm)
            for (wx, wy) in front_world
        ]
        pygame.draw.line(screen, PLAYER_FRONT_COLOR,
                        front_screen[0], front_screen[1], 3)


class Game:
    """Main game class."""

    def __init__(self):
        pygame.init()
        self.screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
        pygame.display.set_caption("Decoherence")
        self.clock = pygame.time.Clock()
        self.running = True

        # Game objects
        self.hex_grid = HexGrid()
        self.player = Player(0, 0)  # Start at origin

        # Camera follows player
        self.camera_x = 0
        self.camera_y = 0

        # Zoom
        self.zoom = DEFAULT_ZOOM

    def handle_events(self):
        """Handle pygame events."""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
            elif event.type == pygame.MOUSEWHEEL:
                if event.y > 0:
                    self.zoom = min(self.zoom * ZOOM_SPEED, MAX_ZOOM)
                elif event.y < 0:
                    self.zoom = max(self.zoom / ZOOM_SPEED, MIN_ZOOM)

    def update(self, dt):
        """Update game state."""
        # Get keyboard input for movement
        keys = pygame.key.get_pressed()
        forward = 0
        right = 0

        if keys[pygame.K_w]:
            forward += 1
        if keys[pygame.K_s]:
            forward -= 1
        if keys[pygame.K_d]:
            right += 1
        if keys[pygame.K_a]:
            right -= 1

        # Get mouse position and make player face it
        ppm = PIXELS_PER_METER * self.zoom
        mouse_x, mouse_y = pygame.mouse.get_pos()
        target_x, target_y = screen_to_world(mouse_x, mouse_y,
                                              self.camera_x, self.camera_y, ppm)
        self.player.face_towards(target_x, target_y)

        # Move player
        self.player.move(forward, right, dt)

        # Camera follows player
        self.camera_x = self.player.x
        self.camera_y = self.player.y

    def draw(self):
        """Draw the game."""
        self.screen.fill(BG_COLOR)
        ppm = PIXELS_PER_METER * self.zoom

        # Draw hex grid
        self.hex_grid.draw(self.screen, self.camera_x, self.camera_y, ppm)

        # Draw player
        self.player.draw(self.screen, self.camera_x, self.camera_y, ppm)

        pygame.display.flip()

    def run(self):
        """Main game loop."""
        while self.running:
            dt = self.clock.tick(FPS) / 1000.0  # Delta time in seconds

            self.handle_events()
            self.update(dt)
            self.draw()

        pygame.quit()
        sys.exit()


def main():
    game = Game()
    game.run()


if __name__ == "__main__":
    main()
