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
-- Optional power-user binding: SUPER + CTRL + M
--
-- Always stashes, regardless of current stash state — unlike SUPER+M this
-- never restores. Useful for cumulative keyboard-driven stashing across
-- several workspaces before restoring them all at once elsewhere:
--
--   Workspace 1 -> SUPER+CTRL+M -> add its windows
--   Workspace 3 -> SUPER+CTRL+M -> add its windows
--   Workspace 7 -> SUPER+M      -> restore everything here
--
-- Same conflict caveat as SUPER+M: check `omarchy menu keybindings --print`
-- first. SUPER+CTRL+M was chosen over SUPER+ALT+M (an earlier revision of
-- this doc) after confirming SUPER+SHIFT+ALT+M is Omarchy's default Music
-- TUI launcher and SUPER+SHIFT+M is its default Music/Spotify launcher —
-- SUPER+CTRL+M avoids both, and reads as a natural pairing with SUPER+M.
-- This is just another thin adapter over the same stash() IPC call used
-- everywhere else — there is no separate "cumulative stash" operation.
-- ---------------------------------------------------------------------------

hl.bind(
  "SUPER + CTRL + M",
  hl.dsp.exec_cmd([[omarchy-shell -q workspace-stash stash]]),
  { description = "Stash current workspace (cumulative)" }
)

-- ---------------------------------------------------------------------------
-- Optional: bulk workspace-move — SUPER + CTRL + SHIFT + 1-9, 0 for 10
--
-- Moves every eligible window on the current workspace onto workspace N,
-- preserving their layout best-effort, and leaves you exactly where you
-- were — it never switches your view there. This is a separate operation
-- from the stash above: it never reads or restores the stash, and it never
-- touches special:workspace-stash. If workspace N already has windows, the
-- moved set merges in normally rather than replacing anything.
--
-- Same conflict caveat as the bindings above: check
-- `omarchy menu keybindings --print` first. SUPER+CTRL+SHIFT+<digit> was
-- chosen after confirming every other 2- and 3-modifier digit combo
-- (SUPER+<digit>, SUPER+SHIFT+<digit>, SUPER+ALT+<digit>,
-- SUPER+SHIFT+ALT+<digit>, SUPER+CTRL+<digit>) is already claimed by an
-- Omarchy default. Uses `code:` key names the same way Omarchy's own
-- workspace bindings do, so key 0 maps to workspace 10.
-- ---------------------------------------------------------------------------

for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  hl.bind(
    "SUPER + CTRL + SHIFT + " .. key,
    hl.dsp.exec_cmd("omarchy-shell -q workspace-stash moveTo " .. tostring(workspace)),
    { description = "Move workspace to workspace " .. workspace }
  )
end

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
