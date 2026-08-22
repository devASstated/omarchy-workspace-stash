-- Workspace Stash — example Hyprland bindings.
--
-- This file is documentation, not an installer: nothing in this plugin ever
-- edits your Hyprland config, and this file is never sourced automatically.
-- Copy the blocks you want into your own ~/.config/hypr/bindings.lua and
-- ~/.config/hypr/input.lua, then:
--
--   hyprctl reload
--   hyprctl configerrors
--
-- Every binding below only shells out to the plugin's own IPC target
-- ("workspace-stash") via omarchy-shell; there is no second implementation
-- of stash/restore logic in Lua.

-- ---------------------------------------------------------------------------
-- Keyboard toggle — published default: SUPER + M
--
-- Before adding this, confirm SUPER + M is not already bound to something
-- else on your system:
--
--   omarchy menu keybindings --print
--
-- If it is, bind a different key instead of replacing the existing action.
-- Add to ~/.config/hypr/bindings.lua:
-- ---------------------------------------------------------------------------

hl.bind(
  "SUPER + M",
  hl.dsp.exec_cmd([[omarchy-shell -q workspace-stash toggle]]),
  { description = "Toggle workspace stash" }
)

-- ---------------------------------------------------------------------------
-- Optional power-user binding: SUPER + ALT + M
--
-- Always stashes, regardless of current stash state — unlike SUPER+M this
-- never restores. Useful for cumulative keyboard-driven stashing across
-- several workspaces before restoring them all at once elsewhere:
--
--   Workspace 1 -> SUPER+ALT+M -> add its windows
--   Workspace 3 -> SUPER+ALT+M -> add its windows
--   Workspace 7 -> SUPER+M     -> restore everything here
--
-- Same conflict caveat as SUPER+M: check `omarchy menu keybindings --print`
-- first (SUPER+SHIFT+M is already Omarchy's default Music/Spotify launcher,
-- which is why that combo is avoided here). This is just another thin
-- adapter over the same stash() IPC call used everywhere else — there is no
-- separate "cumulative stash" operation.
-- ---------------------------------------------------------------------------

hl.bind(
  "SUPER + ALT + M",
  hl.dsp.exec_cmd([[omarchy-shell -q workspace-stash stash]]),
  { description = "Stash current workspace (cumulative)" }
)

-- ---------------------------------------------------------------------------
-- Gestures — published default: 3 fingers
--
-- IMPORTANT: check ~/.config/hypr/input.lua for an existing 3-finger
-- vertical/up/down gesture before adding these — Omarchy's own defaults
-- often bind a 3-finger vertical swipe to the scratchpad special workspace.
-- If you already have one, change or remove it yourself first; this plugin
-- will not detect or resolve that conflict for you.
--
-- Add to ~/.config/hypr/input.lua. Change `fingers = 3` to `fingers = 4` if
-- you'd rather reserve three fingers for something else — everything else
-- about the behavior stays identical.
-- ---------------------------------------------------------------------------

hl.gesture({
  fingers = 3,
  direction = "down",
  action = function() hl.dispatch(hl.dsp.exec_cmd("omarchy-shell -q workspace-stash stash")) end,
})

hl.gesture({
  fingers = 3,
  direction = "up",
  action = function() hl.dispatch(hl.dsp.exec_cmd("omarchy-shell -q workspace-stash restore")) end,
})
