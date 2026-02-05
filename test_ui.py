#!/usr/bin/env python3
"""Test script to verify the GameUI integration."""

import pygame
import sys
from main import Game, SCREEN_WIDTH, SCREEN_HEIGHT, PIXELS_PER_METER
from ui import GameUI


class GameWithUI(Game):
    """Extended game class with UI overlay."""

    def __init__(self):
        super().__init__()
        self.ui = GameUI(SCREEN_WIDTH, SCREEN_HEIGHT)

    def handle_events(self):
        """Handle pygame events including UI events."""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
                else:
                    # Handle UI events
                    slot = self.ui.handle_event(event)
                    if slot:
                        print(f"Action bar slot activated: {slot}")
            elif event.type == pygame.MOUSEWHEEL:
                if event.y > 0:
                    self.zoom = min(self.zoom * 1.1, 2.0)
                elif event.y < 0:
                    self.zoom = max(self.zoom / 1.1, 0.15)

    def draw(self):
        """Draw the game with UI overlay."""
        self.screen.fill((20, 20, 30))
        ppm = PIXELS_PER_METER * self.zoom

        # Draw hex grid
        self.hex_grid.draw(self.screen, self.camera_x, self.camera_y, ppm)

        # Draw player
        self.player.draw(self.screen, self.camera_x, self.camera_y, ppm)

        # Draw UI overlay
        self.ui.draw(self.screen, self.player, self.hex_grid,
                    self.camera_x, self.camera_y, self.zoom)

        pygame.display.flip()


def main():
    """Run the game with UI."""
    game = GameWithUI()
    print("UI Test Started")
    print("Controls:")
    print("  WASD - Move")
    print("  Mouse - Aim")
    print("  Scroll - Zoom")
    print("  1-9, 0, -, = - Action bar (with/without Shift)")
    print("  ESC - Quit")
    game.run()


if __name__ == "__main__":
    main()
