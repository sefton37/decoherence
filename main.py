import pygame
import math
import sys

from ui import GameUI

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

# Voxel properties (1m x 1m 2D voxels)
VOXEL_SIZE = 1.0  # meters per voxel side

# Player properties
PLAYER_LENGTH = 0.25  # meters (front to back)
PLAYER_WIDTH = 0.5    # meters (side to side)
PLAYER_SPEED = 1.5    # meters per second

# Colors
BG_COLOR = (20, 20, 30)
VOXEL_FILL_COLOR = (40, 45, 55)
VOXEL_BORDER_COLOR = (70, 80, 100)
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


class VoxelGrid:
    """2D voxel grid with 1m x 1m cells."""

    def __init__(self):
        self.cell_size = VOXEL_SIZE  # 1 meter per cell

    def get_visible_voxels(self, camera_x, camera_y, ppm):
        """Get voxel grid coordinates visible on screen."""
        # Calculate visible area in world coordinates with 1-cell padding
        half_width_m = (SCREEN_WIDTH / 2) / ppm + self.cell_size
        half_height_m = (SCREEN_HEIGHT / 2) / ppm + self.cell_size

        min_x = camera_x - half_width_m
        max_x = camera_x + half_width_m
        min_y = camera_y - half_height_m
        max_y = camera_y + half_height_m

        # Snap to grid boundaries
        col_start = int(math.floor(min_x / self.cell_size))
        col_end = int(math.ceil(max_x / self.cell_size))
        row_start = int(math.floor(min_y / self.cell_size))
        row_end = int(math.ceil(max_y / self.cell_size))

        voxels = []
        for col in range(col_start, col_end):
            for row in range(row_start, row_end):
                # World position of voxel's top-left corner
                wx = col * self.cell_size
                wy = row * self.cell_size
                voxels.append((wx, wy, col, row))

        return voxels

    def draw(self, screen, camera_x, camera_y, ppm):
        """Draw the voxel grid."""
        visible = self.get_visible_voxels(camera_x, camera_y, ppm)
        size_px = self.cell_size * ppm

        for (wx, wy, col, row) in visible:
            sx, sy = world_to_screen(wx, wy, camera_x, camera_y, ppm)
            rect = pygame.Rect(sx, sy, size_px, size_px)

            pygame.draw.rect(screen, VOXEL_FILL_COLOR, rect)
            pygame.draw.rect(screen, VOXEL_BORDER_COLOR, rect, 1)


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
        self.voxel_grid = VoxelGrid()
        self.player = Player(0, 0)  # Start at origin

        # Camera follows player
        self.camera_x = 0
        self.camera_y = 0

        # Zoom
        self.zoom = DEFAULT_ZOOM

        # UI overlay
        self.ui = GameUI(SCREEN_WIDTH, SCREEN_HEIGHT)

    def handle_events(self):
        """Handle pygame events."""
        for event in pygame.event.get():
            self.ui.handle_event(event)
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

        # Draw voxel grid
        self.voxel_grid.draw(self.screen, self.camera_x, self.camera_y, ppm)

        # Draw player
        self.player.draw(self.screen, self.camera_x, self.camera_y, ppm)

        # Draw UI overlay
        self.ui.draw(self.screen, self.player, self.voxel_grid,
                     self.camera_x, self.camera_y, self.zoom)

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
