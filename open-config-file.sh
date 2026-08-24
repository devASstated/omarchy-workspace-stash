#!/bin/bash
# Opens a Hyprland config file at the line matching $2 (falling back to
# end-of-file), preferring Neovim and falling back to Omarchy's own config
# editor. Same mechanism io.github.ilyazar.btop's open-keybindings.sh uses,
# generalized to take the target file and search pattern as arguments
# instead of being hardcoded to one file — this plugin needs it for both
# bindings.lua (keyboard) and input.lua (gestures).
set -euo pipefail

target_file="${1:?usage: open-config-file.sh <file> <search-pattern> [app-id]}"
search_pattern="${2:?usage: open-config-file.sh <file> <search-pattern> [app-id]}"
app_id="${3:-io.github.devASstated.workspace-stash-config}"
target_line=1

if [[ -r $target_file ]]; then
  target_line=$(awk -v pat="$search_pattern" '
    { if (tolower($0) ~ tolower(pat)) { print NR; exit } }
  ' "$target_file")

  if [[ -z $target_line ]]; then
    target_line=$(awk 'END { print NR + 1 }' "$target_file")
  fi
fi

if command -v nvim >/dev/null 2>&1; then
  exec omarchy-launch-tui --app-id="$app_id" \
    nvim "+$target_line" "$target_file"
fi

exec omarchy-launch-config-editor "$target_file"
