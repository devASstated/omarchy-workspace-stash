# Workspace Stash development rules

Read `docs/FEATURES.md` before making architectural or behavioral changes.

Current development target: V1.

Do not implement V2 features unless explicitly requested.

Priorities:

1. Preserve the behavior defined in FEATURES.md.
2. Prefer native Quattro/Quickshell/Hyprland facilities.
3. Keep runtime architecture event-driven and minimal.
4. No polling loops.
5. No daemon or persistent state unless the project specification is deliberately revised.
6. Gesture bindings and keyboard bindings are input adapters only.
7. Core stash/restore behavior must have one authoritative implementation.
8. Do not silently overwrite user configuration.
9. Keep the project suitable for public distribution as an Omarchy plugin.
10. All git actions should be requested and never be performed without user review - present the git message along with summary of what was implemented before requesting for a git commit action 
