# Dotfiles

My personal dotfiles managed with GNU Stow.

## Structure

- Install all configurations:
   ```bash
   make install
   ```
   
   Or install specific packages:
   ```bash
   stow -t ~ packages/vim     # Install only vim config
   stow -t ~ packages/tmux    # Install only tmux config
   ```

## Package Management

- Each tool's configuration lives in its own package directory under `packages/`
- Files in each package directory mirror the structure of your home directory
- Stow automatically creates symlinks from the package directory to your home directory
